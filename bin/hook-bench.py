#!/usr/bin/env python3
"""Same-run A/B benchmark of two refs' PreToolUse hooks, with a release gate.

  bin/hook-bench.py                         # latest tag vs the working tree
  bin/hook-bench.py --base edbd1fa --head HEAD
  bin/hook-bench.py --gate --intended id1,id2 --md bench.md --json bench.json
  bin/hook-bench.py --corpus audit          # this machine's audit log; never publish

Every payload in the corpus is fed to each hook that would fire for it under
that side's config/settings.json (PreToolUse, command hooks, not async), one
hook at a time, both sides back to back, alternating which side goes first.
Wait is the slowest hook of a call, since Claude Code runs them in parallel;
CPU is the sum over the hooks that fired (user+system of the hook and every
process it waited for). Decisions are compared per payload: a change not named
with --intended fails the gate, as does a p50 or p95 wait that grows past the
limit AND the floor (both, so a 2 ms wobble on a 5 ms hook is not a failure).

Python, not bash: getrusage(RUSAGE_CHILDREN) is the only portable way to read a
child's CPU to the millisecond; bash and perl `times` round to clock ticks.
python3 is already required by bin/permission-friction.py.

Absolute numbers depend on the machine (process start cost varies 3x between
laptops), which is why both sides run in the same process on the same corpus
and only the comparison is reported as a verdict.
"""
import argparse, hashlib, io, json, os, platform, re, resource, shutil, statistics, subprocess, sys, tarfile, tempfile, time

RANK = {'allow': 0, 'ask': 2, 'deny': 3, 'error': 4}
CLASSES = {'Bash': 'Bash', 'Write': 'Write/Edit', 'Edit': 'Write/Edit', 'MultiEdit': 'Write/Edit',
           'NotebookEdit': 'Write/Edit', 'Read': 'Read/Grep', 'Grep': 'Read/Grep', 'WebFetch': 'WebFetch'}


def die(msg, rc=2):
    print(f'hook-bench: {msg}', file=sys.stderr)
    sys.exit(rc)


def git(repo, *args, check=True):
    p = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        die(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout.strip()


def extract_side(repo, ref, into):
    """hooks/ and config/settings.json of REF (or of the working tree) into a directory."""
    os.makedirs(into)
    if ref == 'worktree':
        shutil.copytree(os.path.join(repo, 'hooks'), os.path.join(into, 'hooks'))
        os.makedirs(os.path.join(into, 'config'))
        shutil.copy(os.path.join(repo, 'config', 'settings.json'), os.path.join(into, 'config', 'settings.json'))
        sha = git(repo, 'rev-parse', '--short', 'HEAD', check=False) or 'nogit'
        dirty = git(repo, 'status', '--porcelain', '--', 'hooks', 'config/settings.json', check=False)
        return {'ref': 'worktree', 'commit': sha + ('+' if dirty else ''), 'dir': into}
    p = subprocess.run(['git', '-C', repo, 'archive', '--format=tar', ref, '--', 'hooks', 'config/settings.json'],
                       capture_output=True)
    if p.returncode != 0:
        die(f'git archive {ref}: {p.stderr.decode().strip()}')
    with tarfile.open(fileobj=io.BytesIO(p.stdout)) as tf:
        tf.extractall(into)
    return {'ref': ref, 'commit': git(repo, 'rev-parse', '--short', ref), 'dir': into}


def hooks_for(side, tool):
    """Hook scripts that fire for TOOL under this side's settings, in registration order."""
    key = (side['dir'], tool)
    if key in side.setdefault('_cache', {}):
        return side['_cache'][key]
    with open(os.path.join(side['dir'], 'config', 'settings.json')) as f:
        cfg = json.load(f)
    out = []
    for entry in (cfg.get('hooks') or {}).get('PreToolUse') or []:
        m = entry.get('matcher') or ''
        if m not in ('', '*') and not re.fullmatch(m, tool):
            continue
        for h in entry.get('hooks') or []:
            if h.get('type') != 'command' or h.get('async'):
                continue
            name = os.path.basename(h.get('command', '').split()[0])
            path = os.path.join(side['dir'], 'hooks', name)
            if name and name not in [n for n, _ in out]:
                out.append((name, path if os.path.exists(path) else None))
    side['_cache'][key] = out
    return out


def run_hook(path, payload, env, cwd, timeout=30):
    """(wall ms, cpu ms, decision) for one hook on one payload."""
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    try:
        p = subprocess.run(['bash', path], input=payload, capture_output=True, env=env, cwd=cwd, timeout=timeout)
    except subprocess.TimeoutExpired:
        return timeout * 1000.0, 0.0, 'error'
    t1 = time.perf_counter()
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (r1.ru_utime - r0.ru_utime + r1.ru_stime - r0.ru_stime) * 1000.0
    if p.returncode == 2:
        dec = 'deny'
    elif p.returncode != 0:
        dec = 'error'
    else:
        out = p.stdout.decode('utf-8', 'replace').strip()
        if not out:
            dec = 'allow'
        else:
            try:
                dec = (json.loads(out).get('hookSpecificOutput') or {}).get('permissionDecision') or 'allow'
            except (ValueError, AttributeError):
                dec = 'error'
    return (t1 - t0) * 1000.0, cpu, dec if dec in RANK else 'error'


def run_call(side, row, env, cwd):
    """All hooks for one payload on one side: wait = max, cpu = sum, worst decision."""
    payload = json.dumps({'hook_event_name': 'PreToolUse', 'session_id': 'bench', 'tool_name': row['tool_name'],
                          'tool_input': row['tool_input'], 'cwd': cwd, 'permission_mode': 'auto'}).encode()
    e = dict(env)
    e.update({k: str(v) for k, v in (row.get('env') or {}).items()})
    per = {}
    worst, by = 'allow', ''
    for name, path in hooks_for(side, row['tool_name']):
        if path is None:
            per[name] = (0.0, 0.0, 'missing')
            continue
        w, c, d = run_hook(path, payload, e, cwd)
        per[name] = (w, c, d)
        if RANK[d] > RANK[worst]:
            worst, by = d, name
    return {'wait': max((v[0] for v in per.values()), default=0.0),
            'cpu': sum(v[1] for v in per.values()), 'decision': worst, 'by': by, 'hooks': per}


def load_corpus(spec, repo):
    if spec.startswith('audit'):
        path = spec.partition(':')[2] or os.path.expanduser('~/.claude/logs/audit.log')
        rows, seen = [], set()
        with open(path, errors='replace') as f:
            for n, line in enumerate(f, 1):
                parts = line.rstrip('\n').split(' | ', 2)
                if len(parts) < 3 or parts[1] != 'Bash':
                    continue
                cmd = parts[2].rsplit(' | ', 1)[0]
                if cmd in seen:
                    continue
                seen.add(cmd)
                rows.append({'id': f'audit:{n}', 'tool_name': 'Bash', 'tool_input': {'command': cmd}})
        return rows, path, True
    path = spec if os.path.isabs(spec) else os.path.join(repo, spec)
    rows = []
    with open(path) as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
    return rows, path, False


def pct(xs, q):
    s = sorted(xs)
    return s[max(0, int(-(-q * len(s) // 1)) - 1)] if s else 0.0


def stats(xs):
    return {'n': len(xs), 'p50': statistics.median(xs) if xs else 0.0, 'mean': statistics.fmean(xs) if xs else 0.0,
            'p95': pct(xs, 0.95), 'max': max(xs) if xs else 0.0}


def machine():
    cpu = ''
    if sys.platform == 'darwin':
        cpu = subprocess.run(['sysctl', '-n', 'machdep.cpu.brand_string'], capture_output=True, text=True).stdout.strip()
    elif os.path.exists('/proc/cpuinfo'):
        for line in open('/proc/cpuinfo'):
            if line.startswith('model name'):
                cpu = line.split(':', 1)[1].strip()
                break
    return {'os': f'{platform.system()} {platform.release()} {platform.machine()}', 'cpu': cpu,
            'python': platform.python_version()}


def start_cost(env, cwd):
    out = {}
    for label, cmd in (('bash -c :', ['bash', '-c', ':']), ('jq -n 1', ['jq', '-n', '1'])):
        ws = []
        for _ in range(20):
            t0 = time.perf_counter()
            subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, env=env, cwd=cwd)
            ws.append((time.perf_counter() - t0) * 1000.0)
        out[label] = statistics.median(ws)
    return out


def delta(a, b):
    if a <= 0:
        return 'n/a'
    d = (b - a) / a * 100.0
    return f'{d:+.0f}%'


def fmt_pair(a, b):
    return f'{a:.1f} → {b:.1f} ms ({delta(a, b)})'


def render_md(r):
    b, h = r['base'], r['head']
    L = [f"## Hook benchmark: {b['ref']} ({b['commit']}) vs {h['ref']} ({h['commit']})", '']
    m = r['machine']
    counts = ', '.join(f'{v} {k}' for k, v in r['corpus']['tools'].items())
    note = ' (local audit corpus, not for publishing)' if r['corpus']['local'] else ''
    L.append(f"{r['date']}, {m['os']}, {m['cpu'] or 'cpu n/a'}, python {m['python']}. "
             f"Corpus {r['corpus']['name']}{note}: {r['corpus']['count']} payloads ({counts})"
             f"{', x' + str(r['repeat']) if r['repeat'] > 1 else ''}, each run through both sides, "
             'alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in '
             'config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in '
             'parallel); CPU is the sum. Process start here: '
             + ', '.join(f'`{k}` {v:.1f} ms' for k, v in r['process_start_ms'].items())
             + ' (p50 of 20), so only same-run comparisons are meaningful.')
    L += ['', '| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |', '|---|---:|---|---|---|---|']
    for cls, c in r['classes'].items():
        bw, hw, bc, hc = c['base']['wait'], c['head']['wait'], c['base']['cpu'], c['head']['cpu']
        L.append(f"| {cls} | {bw['n']} | {fmt_pair(bw['p50'], hw['p50'])} | {fmt_pair(bw['mean'], hw['mean'])} | "
                 f"{fmt_pair(bw['p95'], hw['p95'])} | {fmt_pair(bc['mean'], hc['mean'])} |")
    L += ['', '| Hook | runs | wall p50 | wall p95 | CPU mean |', '|---|---:|---|---|---|']
    for name, hk in r['hooks'].items():
        bw, hw = hk.get('base'), hk.get('head')
        if bw and hw:
            L.append(f"| {name} | {bw['wall']['n']} | {fmt_pair(bw['wall']['p50'], hw['wall']['p50'])} | "
                     f"{fmt_pair(bw['wall']['p95'], hw['wall']['p95'])} | {fmt_pair(bw['cpu']['mean'], hw['cpu']['mean'])} |")
        else:
            side, s = ('base only', bw) if bw else ('head only', hw)
            L.append(f"| {name} | {s['wall']['n']} | {s['wall']['p50']:.1f} ms ({side}) | {s['wall']['p95']:.1f} ms | "
                     f"{s['cpu']['mean']:.1f} ms |")
    d = r['decisions']
    L += ['', f"Decisions: {d['same']} of {d['same'] + len(d['changed'])} payloads got the same answer on both sides."]
    if d['changed']:
        L += ['', '| Payload | base | head |', '|---|---|---|']
        for ch in d['changed']:
            who = '' if r['corpus']['local'] else f" `{ch['preview']}`"
            L.append(f"| {ch['id']}{who} | {ch['base']} ({ch['base_by'] or 'silent'}) | {ch['head']} ({ch['head_by'] or 'silent'}) |")
    g = r['gate']
    if g['enabled']:
        L += ['', ('Gate: passed' if g['passed'] else 'Gate: FAILED') +
              f" (p50 and p95 wait may not grow more than {g['limit_pct']:g}% and {g['floor_ms']:g} ms, "
              f"per class with at least {g['min_calls']} calls; every decision change must be intended)."]
        for f_ in g['failures']:
            L.append(f'- {f_}')
    return '\n'.join(L) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog='\n'.join(__doc__.split('\n\n')[1:]))
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--base', help='git ref (default: the latest tag)')
    ap.add_argument('--head', default='worktree', help="git ref, or 'worktree' (default) for hooks/ and config/ as on disk")
    ap.add_argument('--corpus', default='tests/bench-corpus.jsonl', help="JSONL file, or 'audit[:PATH]' for this machine's audit log")
    ap.add_argument('--quick', action='store_true', help='every third payload (CI)')
    ap.add_argument('--repeat', type=int, default=1, help='passes over the corpus')
    ap.add_argument('--gate', action='store_true', help='exit 1 on a regression or an unintended decision change')
    ap.add_argument('--intended', default='', help="payload ids whose decision may change, comma or space separated, or 'all'")
    ap.add_argument('--limit-pct', type=float, default=20.0, help='p50/p95 wait may grow by this much (default 20)')
    ap.add_argument('--floor-ms', type=float, default=5.0, help='and must also grow by this many ms (default 5)')
    ap.add_argument('--min-calls', type=int, default=20, help='gate only tool classes with at least this many calls (default 20)')
    ap.add_argument('--md', help='write the markdown report here (always printed to stdout)')
    ap.add_argument('--json', help='write the full result here')
    a = ap.parse_args()

    repo = os.path.abspath(a.repo)
    base = a.base or git(repo, 'describe', '--tags', '--abbrev=0', check=False)
    if not base:
        die('no tag to compare against; pass --base REF')
    rows, cpath, local = load_corpus(a.corpus, repo)
    if a.quick:
        rows = rows[::3]
    if not rows:
        die('empty corpus')
    ids = [r['id'] for r in rows]
    if len(set(ids)) != len(ids):
        die('duplicate payload ids in the corpus')

    tmp = tempfile.mkdtemp(prefix='cch-bench.', dir=os.environ.get('TMPDIR') or None)
    try:
        home = os.path.join(tmp, 'home')
        os.makedirs(os.path.join(home, '.claude'))
        env = dict(os.environ)
        # Out of the real audit log and blind to this machine's allowlists, local
        # settings and tunnels, so both sides decide on the payload alone.
        env.update({'HOME': home, 'CLAUDE_AUDIT_LOG': os.devnull, 'CLAUDE_NET_ALLOWLIST': '',
                    'CLAUDE_LOCAL_SETTINGS_DIR': os.path.join(tmp, 'no-local-settings'),
                    'CLAUDE_NET_TUNNEL_RE': '^cch-no-tunnel$', 'CLAUDE_STATE_DIR': os.path.join(tmp, 'state')})
        env.pop('CLAUDE_JOB_DIR', None)
        sides = {'base': extract_side(repo, base, os.path.join(tmp, 'base')),
                 'head': extract_side(repo, a.head, os.path.join(tmp, 'head'))}

        # Warm the page cache with one call per tool through both sides.
        seen = set()
        for row in rows:
            if row['tool_name'] in seen:
                continue
            seen.add(row['tool_name'])
            for s in sides.values():
                run_call(s, row, env, home)

        results = {'base': {}, 'head': {}}
        k = 0
        t_start = time.time()
        for _ in range(a.repeat):
            for row in rows:
                order = ('base', 'head') if k % 2 == 0 else ('head', 'base')
                k += 1
                for s in order:
                    results[s].setdefault(row['id'], []).append(run_call(sides[s], row, env, home))
        elapsed = time.time() - t_start

        classes, hooks = {}, {}
        for row in rows:
            cls = CLASSES.get(row['tool_name'], row['tool_name'])
            for s in ('base', 'head'):
                for call in results[s][row['id']]:
                    c = classes.setdefault(cls, {'base': {'wait': [], 'cpu': []}, 'head': {'wait': [], 'cpu': []}})
                    c[s]['wait'].append(call['wait']); c[s]['cpu'].append(call['cpu'])
                    for name, (w, cpu, d) in call['hooks'].items():
                        if d == 'missing':
                            continue
                        hk = hooks.setdefault(name, {})
                        hk.setdefault(s, {'wall': [], 'cpu': []})
                        hk[s]['wall'].append(w); hk[s]['cpu'].append(cpu)
        all_ = {'base': {'wait': [], 'cpu': []}, 'head': {'wait': [], 'cpu': []}}
        for c in classes.values():
            for s in ('base', 'head'):
                all_[s]['wait'] += c[s]['wait']; all_[s]['cpu'] += c[s]['cpu']
        classes['All'] = all_
        class_out = {cls: {s: {'wait': stats(c[s]['wait']), 'cpu': stats(c[s]['cpu'])} for s in ('base', 'head')}
                     for cls, c in classes.items()}
        hook_out = {name: {s: {'wall': stats(v['wall']), 'cpu': stats(v['cpu'])} for s, v in hk.items()}
                    for name, hk in sorted(hooks.items())}

        changed, same = [], 0
        for row in rows:
            b, h = results['base'][row['id']][-1], results['head'][row['id']][-1]
            if b['decision'] == h['decision']:
                same += 1
            else:
                cmd = row['tool_input'].get('command') or row['tool_input'].get('file_path') or row['tool_input'].get('url') or ''
                changed.append({'id': row['id'], 'base': b['decision'], 'head': h['decision'], 'base_by': b['by'],
                                'head_by': h['by'], 'preview': cmd.replace('\n', ' ')[:60]})

        intended = set(re.split(r'[,\s]+', a.intended.strip())) - {''}
        failures = []
        for cls, c in class_out.items():
            # A class of a few calls has a p95 that is its slowest call; one
            # 20 ms wobble there is not a regression.
            if cls == 'All' or c['base']['wait']['n'] < a.min_calls:
                continue
            for q in ('p50', 'p95'):
                bv, hv = c['base']['wait'][q], c['head']['wait'][q]
                if hv > bv * (1 + a.limit_pct / 100.0) and hv - bv > a.floor_ms:
                    failures.append(f'{cls} wait {q}: {bv:.1f} → {hv:.1f} ms ({delta(bv, hv)})')
        for ch in changed:
            if 'all' not in intended and ch['id'] not in intended:
                failures.append(f"decision changed without --intended: {ch['id']} {ch['base']} → {ch['head']}")

        report = {
            'date': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'machine': machine(),
            'base': {k_: sides['base'][k_] for k_ in ('ref', 'commit')}, 'head': {k_: sides['head'][k_] for k_ in ('ref', 'commit')},
            'corpus': {'name': 'audit log' if local else os.path.relpath(cpath, repo), 'count': len(rows), 'local': local,
                       'sha256': '' if local else hashlib.sha256(open(cpath, 'rb').read()).hexdigest(),
                       'tools': dict(sorted(((t, sum(1 for r in rows if r['tool_name'] == t)) for t in {r['tool_name'] for r in rows}),
                                            key=lambda kv: -kv[1]))},
            'repeat': a.repeat, 'quick': a.quick, 'elapsed_s': round(elapsed, 1),
            'process_start_ms': start_cost(env, home),
            'classes': class_out, 'hooks': hook_out,
            'decisions': {'same': same, 'changed': changed},
            'gate': {'enabled': a.gate, 'limit_pct': a.limit_pct, 'floor_ms': a.floor_ms, 'min_calls': a.min_calls,
                     'intended': sorted(intended), 'failures': failures, 'passed': not failures},
        }
        if not local:
            # The report is what a release publishes; the local corpus never is.
            report['decisions_detail'] = {rid: {s: results[s][rid][-1]['decision'] for s in ('base', 'head')} for rid in ids}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    md = render_md(report)
    sys.stdout.write(md)
    if a.md:
        with open(a.md, 'w') as f:
            f.write(md)
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(report, f, indent=1)
    if a.gate and failures:
        sys.exit(1)


if __name__ == '__main__':
    main()
