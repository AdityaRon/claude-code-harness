#!/usr/bin/env python3
"""Same-run A/B benchmark of two refs' PreToolUse hooks, with a release gate.

  tools/hook-bench.py                         # latest tag vs the working tree
  tools/hook-bench.py --base edbd1fa --head HEAD
  tools/hook-bench.py --gate --intended id1,id2 --md bench.md --json bench.json
  tools/hook-bench.py --corpus audit          # this machine's audit log; never publish
  tools/hook-bench.py --launches auto         # also count the processes each hook starts
  tools/hook-bench.py --gate --launches strace --intended-launches id1,id2

Every payload in the corpus is fed to the hooks that would fire for it under
that side's config/settings.json (PreToolUse, command hooks, not async), both
sides back to back, alternating which side goes first. A call's hooks are
launched together, as Claude Code does: wait is from the first launch to the
last exit, so hooks that share the machine's cores pay for it, and CPU is the
sum of each hook's own (user+system of the hook and every process it waited
for). The per-hook table runs each hook alone, so a hook's time there is not
its siblings'. --serial is the earlier model: each hook alone, and wait the
slowest of them, which scores separate hooks as if each had a core to itself. Decisions are compared per payload: a change not named
with --intended fails the gate, as does a p50 or p95 wait that grows past the
limit AND the floor (both, so a 2 ms wobble on a 5 ms hook is not a failure).

Python, not bash: getrusage(RUSAGE_CHILDREN) is the only portable way to read a
child's CPU to the millisecond; bash and perl `times` round to clock ticks.
python3 is already required by tools/permission-friction.py.

Absolute numbers depend on the machine (process start cost varies 3x between
laptops), which is why both sides run in the same process on the same corpus
and only the comparison is reported as a verdict.

--launches counts the processes each hook starts, per payload, in a pass of its
own after the timed ones, each hook run alone once. A machine whose endpoint
agent inspects every process start pays for each, so the count is a cost a
fast runner's clock does not show. strace (Linux): `strace -f` sees every
execve past the hook's own bash and every new process (clone, clone3, fork or
vfork without CLONE_THREAD), a $( ) included. shim (macOS, or Linux without
strace): a copy of each side's hooks whose lib.sh puts a folder of shims first
on PATH, one per name in lib.sh's PATH folders and this PATH, each logging its
name before it execs the real one. It sees execs found through PATH only: no
fork, and no program started by its full path. With --gate, a payload whose
hooks start more processes on head than on base (execs plus forks, summed over
its hooks) fails unless --intended-launches names it, and so does a payload a
side could not count.
"""
import argparse, concurrent.futures, glob, hashlib, io, json, os, platform, re, resource, shlex, shutil, signal, statistics, subprocess, sys, tarfile, tempfile, threading, time

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


TOGETHER = True   # a call's hooks launched at once, as Claude Code does; --serial turns it off
HOOK_TIMEOUT = 30.0   # seconds a hook may run; --hook-timeout


def decide(rc, stdout):
    if rc == 2:
        return 'deny'
    if rc != 0:
        return 'error'
    out = stdout.decode('utf-8', 'replace').strip()
    if not out:
        return 'allow'
    try:
        dec = (json.loads(out).get('hookSpecificOutput') or {}).get('permissionDecision') or 'allow'
    except (ValueError, AttributeError):
        return 'error'
    return dec if dec in RANK else 'error'


def run_together(hooks, payload, env, cwd, timeout=None):
    """A call's hooks launched at once, as Claude Code does: ({name: (ms to its end, cpu ms, decision)},
    ms from the first launch to the last end). A hook ends when it has exited and its stdout and stderr
    have closed, as run_hook counts it, so a background child holding them is waited for. Each hook runs
    in its own process group and is fed and drained on threads from its launch; past the timeout its
    whole group is killed and it is an error. CPU is its own wait4 rusage: itself and what it waited for."""
    timeout = HOOK_TIMEOUT if timeout is None else timeout
    t0 = time.perf_counter()
    deadline = t0 + timeout
    procs, threads, eof, outs, killed, exited = [], {}, {}, {}, set(), {}

    def feed(p):
        for step in (lambda: p.stdin.write(payload), p.stdin.close):
            try:
                step()
            except (BrokenPipeError, OSError, ValueError):
                pass

    def drain(key, f):
        outs[key] = f.read()
        eof[key] = time.perf_counter()

    for name, path in hooks:
        p = subprocess.Popen(['bash', path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=env, cwd=cwd, start_new_session=True)
        procs.append((name, p))
        threads[p.pid] = [threading.Thread(target=t, args=a, daemon=True)
                          for t, a in ((feed, (p,)), (drain, ((p.pid, 1), p.stdout)), (drain, ((p.pid, 2), p.stderr)))]
        for t in threads[p.pid]:
            t.start()

    def kill(pids):   # the whole group, and no poll(): only the wait4 below reaps
        for pid in pids:
            try:
                os.killpg(pid, signal.SIGKILL)
                killed.add(pid)
            except (ProcessLookupError, PermissionError):
                pass

    def unfinished():
        return [p.pid for _, p in procs if p.pid not in exited or any(t.is_alive() for t in threads[p.pid])]
    killer = threading.Timer(timeout, lambda: kill(unfinished()))
    killer.start()
    for _, p in procs:
        _, status, ru = os.wait4(p.pid, 0)
        p.returncode = os.waitstatus_to_exitcode(status)
        exited[p.pid] = (time.perf_counter(), (ru.ru_utime + ru.ru_stime) * 1000.0)
    for _, p in procs:
        for t in threads[p.pid]:
            t.join(max(0.0, deadline - time.perf_counter()))
    killer.cancel()
    kill([pid for pid in unfinished()])   # still holding a pipe at the deadline
    for ts in threads.values():
        for t in ts:
            t.join(1.0)
    per, last = {}, t0
    for name, p in procs:
        exit_t, cpu = exited[p.pid]
        if p.pid in killed or (p.pid, 1) not in eof or (p.pid, 2) not in eof:
            per[name] = (timeout * 1000.0, cpu, 'error')
            last = max(last, deadline)
        else:
            end = max(exit_t, eof[(p.pid, 1)], eof[(p.pid, 2)])
            last = max(last, end)
            per[name] = ((end - t0) * 1000.0, cpu,
                         'error' if p.returncode < 0 else decide(p.returncode, outs[(p.pid, 1)]))
        for f in (p.stdout, p.stderr):
            try:
                f.close()
            except OSError:
                pass
    return per, (last - t0) * 1000.0


def run_hook(path, payload, env, cwd, timeout=None):
    """(wall ms, cpu ms, decision) for one hook on one payload, to the close of its stdout and stderr.
    In its own process group, so a timeout kills what it left behind as well."""
    timeout = HOOK_TIMEOUT if timeout is None else timeout
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    p = subprocess.Popen(['bash', path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env, cwd=cwd, start_new_session=True)
    try:
        out, _ = p.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        p.communicate()
        return timeout * 1000.0, 0.0, 'error'
    t1 = time.perf_counter()
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (r1.ru_utime - r0.ru_utime + r1.ru_stime - r0.ru_stime) * 1000.0
    return (t1 - t0) * 1000.0, cpu, decide(p.returncode, out)

def run_call(side, row, env, cwd):
    """All hooks for one payload on one side: wait = max, cpu = sum, worst decision."""
    payload = json.dumps({'hook_event_name': 'PreToolUse', 'session_id': 'bench', 'tool_name': row['tool_name'],
                          'tool_input': row['tool_input'], 'cwd': cwd, 'permission_mode': 'auto'}).encode()
    e = dict(env)
    e.update({k: str(v) for k, v in (row.get('env') or {}).items()})
    per = {}
    worst, by = 'allow', ''
    hooks = hooks_for(side, row['tool_name'])
    wall = None
    together = {}
    if TOGETHER:
        together, wall = run_together([(n, p) for n, p in hooks if p is not None], payload, e, cwd)
    for name, path in hooks:
        if path is None:
            per[name] = (0.0, 0.0, 'missing')
            continue
        per[name] = run_hook(path, payload, e, cwd)   # alone, for the per-hook table
        d = together[name][2] if TOGETHER else per[name][2]
        if RANK[d] > RANK[worst]:
            worst, by = d, name
    if TOGETHER:
        return {'wait': wall, 'cpu': sum(v[1] for v in together.values()), 'decision': worst, 'by': by, 'hooks': per}
    return {'wait': max((v[0] for v in per.values()), default=0.0),
            'cpu': sum(v[1] for v in per.values()), 'decision': worst, 'by': by, 'hooks': per}


# ---- processes started (--launches) --------------------------------------------
PATH_LINE = re.compile(r'^export PATH="(?P<dirs>[^"\n]*)"[ \t]*$', re.M)
EXEC_OK = re.compile(r'^(execve|execveat)\(.*= 0$')
FORK = re.compile(r'^(clone|clone3|fork|vfork)\(.*= (\d+)$')


def strace_works():
    """strace is here and may trace (a container can refuse ptrace)."""
    if not shutil.which('strace'):
        return False
    d = tempfile.mkdtemp(prefix='cch-st.', dir=os.environ.get('TMPDIR') or None)
    try:
        p = subprocess.run(['strace', '-f', '-qq', '-e', 'trace=process', '-o', os.path.join(d, 'o'), 'true'],
                           capture_output=True, timeout=30)
        with open(os.path.join(d, 'o'), errors='replace') as f:
            return p.returncode == 0 and 'execve(' in f.read()
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        shutil.rmtree(d, ignore_errors=True)


def strace_counts(out_prefix):
    """(execs, forks) from `strace -ff -o PREFIX`'s files: successful execve or execveat past the
    hook's own, and clone, clone3, fork or vfork that made a process (a pid back, no CLONE_THREAD)."""
    execs = forks = 0
    for fn in glob.glob(glob.escape(out_prefix) + '.*'):
        with open(fn, errors='replace') as f:
            for line in f:
                line = line.rstrip()
                if EXEC_OK.match(line):
                    execs += 1
                    continue
                m = FORK.match(line)
                if m and int(m.group(2)) > 0 and 'CLONE_THREAD' not in line:
                    forks += 1
    # The first execve is the hook's own bash; with none, strace ran nothing and counted nothing.
    return (execs - 1, forks) if execs else None


def shim_side(side, into, shims):
    """A copy of SIDE whose lib.sh puts the shim folder first on PATH, as a side dict. lib.sh's
    own line puts the system folders first, before whatever PATH the hook was given."""
    shutil.copytree(side['dir'], into, symlinks=True)
    lib = os.path.join(into, 'hooks', 'lib.sh')
    try:
        text = open(lib).read()
    except OSError:
        die(f"--launches shim: {side['ref']} has no hooks/lib.sh to put the shims on PATH in")
    m = PATH_LINE.search(text)
    if not m:
        die(f"--launches shim: no `export PATH=\"...\"` line in {side['ref']}'s hooks/lib.sh, so a shim "
            'would not be first on PATH and its execs would not be counted')
    with open(lib, 'w') as f:
        f.write(text[:m.start()] + f'export PATH="{shims}:{m.group("dirs")}"' + text[m.end():])
    return {'ref': side['ref'], 'commit': side['commit'], 'dir': into, 'lib_dirs': m.group('dirs')}


def write_shims(shims, dir_lists):
    """One shim per name in these folders, the first folder's wins as on PATH. Returns how many."""
    os.makedirs(shims, exist_ok=True)
    seen = set()
    for d in dir_lists:
        if not d or '$' in d or not os.path.isdir(d):
            continue
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            real = os.path.join(d, n)
            if n in seen or '/' in n or '\n' in n or not os.path.isfile(real) or not os.access(real, os.X_OK):
                continue
            seen.add(n)
            with open(os.path.join(shims, n), 'w') as f:
                f.write(f'#!/bin/sh\nprintf \'%s\\n\' {shlex.quote(n)} >> "$CCH_LAUNCH_LOG"\nexec {shlex.quote(real)} "$@"\n')
            os.chmod(os.path.join(shims, n), 0o755)
    return len(seen)


def count_one(method, path, payload, env, cwd, work, bash):
    """(execs, forks) one hook started on one payload, run alone; forks is None under the shim.
    None when the run did not finish: a count never stands in for one it could not make."""
    os.makedirs(work)
    e = dict(env)
    if method == 'strace':
        cmd = ['strace', '-ff', '-qq', '-e', 'trace=process', '-o', os.path.join(work, 'st'), bash, path]
    else:
        e['CCH_LAUNCH_LOG'] = os.path.join(work, 'log')
        open(e['CCH_LAUNCH_LOG'], 'w').close()
        cmd = [bash, path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=e, cwd=cwd, start_new_session=True)
    try:
        p.communicate(payload, timeout=HOOK_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        p.communicate()
        return None
    if method == 'strace':
        if p.returncode != 0 and not glob.glob(glob.escape(os.path.join(work, 'st')) + '.*'):
            return None
        return strace_counts(os.path.join(work, 'st'))
    with open(e['CCH_LAUNCH_LOG'], errors='replace') as f:
        return sum(1 for line in f if line.strip()), None


def count_launches(method, rows, sides, env, cwd, tmp):
    """{'method', 'per_payload': {id: {side: {hook: [execs, forks] or None}}}, 'shims', 'elapsed_s'}."""
    t0 = time.time()
    bash = shutil.which('bash', path=env.get('PATH')) or 'bash'
    csides, nshims = sides, 0
    if method == 'shim':
        shims = os.path.join(tmp, 'shims')
        csides = {s: shim_side(sides[s], os.path.join(tmp, s + '-launches'), shims) for s in sides}
        lib_dirs = [d for s in ('base', 'head') for d in csides[s]['lib_dirs'].split(':')]
        nshims = write_shims(shims, lib_dirs + env.get('PATH', '').split(':'))
        env = dict(env, PATH=shims + ':' + env.get('PATH', ''))
    jobs = []
    for row in rows:
        payload = json.dumps({'hook_event_name': 'PreToolUse', 'session_id': 'bench', 'tool_name': row['tool_name'],
                              'tool_input': row['tool_input'], 'cwd': cwd, 'permission_mode': 'auto'}).encode()
        e = dict(env)
        e.update({k: str(v) for k, v in (row.get('env') or {}).items()})
        for s in ('base', 'head'):
            for name, path in hooks_for(csides[s], row['tool_name']):
                if path is not None:
                    jobs.append((row['id'], s, name, path, payload, e))
    per = {}
    with concurrent.futures.ThreadPoolExecutor(max(1, os.cpu_count() or 1)) as ex:
        futs = [(j, ex.submit(count_one, method, j[3], j[4], j[5], cwd, os.path.join(tmp, 'launch', str(i)), bash))
                for i, j in enumerate(jobs)]
        for (rid, s, name, _, _, _), fu in futs:
            per.setdefault(rid, {}).setdefault(s, {})[name] = (lambda c: list(c) if c else None)(fu.result())
    shutil.rmtree(os.path.join(tmp, 'launch'), ignore_errors=True)
    return {'method': method, 'per_payload': per, 'shims': nshims, 'elapsed_s': round(time.time() - t0, 1)}


def launch_total(per):
    """execs plus forks over one payload's hooks on one side, or None when one was not counted."""
    if any(c is None for c in per.values()):
        return None
    return sum(c[0] + (c[1] or 0) for c in per.values())


def launch_failures(la, intended):
    out = []
    for rid, sides in la['per_payload'].items():
        tb, th = launch_total(sides.get('base') or {}), launch_total(sides.get('head') or {})
        if tb is None or th is None:
            out.append(f"launches not counted on {'base' if tb is None else 'head'}: {rid}")
        elif th > tb and 'all' not in intended and rid not in intended:
            out.append(f'launches grew without --intended-launches: {rid} {tb} → {th}')
    return out


def launch_table(la):
    """Per hook and side: payloads, payloads not counted, execs and forks (total, mean), and the
    payloads where head started more or fewer than base."""
    hooks = {}
    for sides in la['per_payload'].values():
        for s, per in sides.items():
            for name, c in per.items():
                h = hooks.setdefault(name, {}).setdefault(s, {'n': 0, 'lost': 0, 'execs': 0, 'forks': 0})
                h['n'] += 1
                if c is None:
                    h['lost'] += 1
                    continue
                h['execs'] += c[0]
                h['forks'] += c[1] or 0
    for name, hk in hooks.items():
        more = fewer = 0
        for sides in la['per_payload'].values():
            b, h = (sides.get('base') or {}).get(name), (sides.get('head') or {}).get(name)
            if b is None or h is None:
                continue
            tb, th = b[0] + (b[1] or 0), h[0] + (h[1] or 0)
            more += th > tb
            fewer += th < tb
        hk['more'], hk['fewer'] = more, fewer
    return dict(sorted(hooks.items()))


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
    # `true` is the bare exec floor; a hook's own cost is its wall time past one `bash` start.
    true = shutil.which('true') or '/usr/bin/true'
    for label, cmd in (('true', [true]), ('bash -c :', ['bash', '-c', ':']), ('jq -n 1', ['jq', '-n', '1'])):
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


def render_launches(la):
    L = ['']
    if la['method'] == 'strace':
        L.append('Processes started: each hook run alone once per payload under `strace -f`. Execs are '
                 'execve calls past the hook\'s own bash; forks are new processes (clone, clone3, fork or vfork without '
                 'CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.')
    else:
        L.append('Processes started: execs found through PATH only, counted by a shim per name on '
                 f"hooks/lib.sh's PATH folders and this PATH ({la['shims']} shims). Forks and programs started by their full "
                 'path are not seen; `strace` on Linux sees both.')
    fk = la['method'] == 'strace'
    L += ['', '| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |',
          '|---|---:|---|---|---|---|---:|']
    mean = lambda h, k: h[k] / max(1, h['n'] - h['lost'])
    for name, hk in la['table'].items():
        b, h = hk.get('base'), hk.get('head')
        if not (b and h):
            s_, side = (b, 'base only') if b else (h, 'head only')
            L.append(f"| {name} | {s_['n']} ({side}) | {mean(s_, 'execs'):.2f} | "
                     + (f"{mean(s_, 'forks'):.2f}" if fk else 'n/a') + f" | {s_['execs'] + s_['forks']} | | {s_['lost']} |")
            continue
        L.append(f"| {name} | {b['n']} | {mean(b, 'execs'):.2f} → {mean(h, 'execs'):.2f} | "
                 + (f"{mean(b, 'forks'):.2f} → {mean(h, 'forks'):.2f}" if fk else 'n/a')
                 + f" | {b['execs'] + b['forks']} → {h['execs'] + h['forks']} | {hk['more']} / {hk['fewer']} | {b['lost'] + h['lost']} |")
    return L


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
             + ('config/settings.json, launched together as Claude Code does. Wait is from the first launch to the '
                'last exit, so hooks that share the cores pay for it; CPU is the sum of each hook\'s own. The per-hook '
                'table runs each hook alone. Process start here: ' if r.get('together') else
                'config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in '
                'parallel); CPU is the sum. Process start here: ')
             + ', '.join(f'`{k}` {v:.1f} ms' for k, v in r['process_start_ms'].items())
             + ' (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower '
             'pays it again for each process a hook starts: the last column is a hook\'s p50 past one `bash -c :`.')
    L += ['', '| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |', '|---|---:|---|---|---|---|']
    for cls, c in r['classes'].items():
        bw, hw, bc, hc = c['base']['wait'], c['head']['wait'], c['base']['cpu'], c['head']['cpu']
        L.append(f"| {cls} | {bw['n']} | {fmt_pair(bw['p50'], hw['p50'])} | {fmt_pair(bw['mean'], hw['mean'])} | "
                 f"{fmt_pair(bw['p95'], hw['p95'])} | {fmt_pair(bc['mean'], hc['mean'])} |")
    floor = r['process_start_ms'].get('bash -c :', 0.0)
    L += ['', '| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |', '|---|---:|---|---|---|---|']
    for name, hk in r['hooks'].items():
        bw, hw = hk.get('base'), hk.get('head')
        if bw and hw:
            L.append(f"| {name} | {bw['wall']['n']} | {fmt_pair(bw['wall']['p50'], hw['wall']['p50'])} | "
                     f"{fmt_pair(bw['wall']['p95'], hw['wall']['p95'])} | {fmt_pair(bw['cpu']['mean'], hw['cpu']['mean'])} | "
                     f"{bw['wall']['p50'] - floor:.1f} → {hw['wall']['p50'] - floor:.1f} ms |")
        else:
            side, s = ('base only', bw) if bw else ('head only', hw)
            L.append(f"| {name} | {s['wall']['n']} | {s['wall']['p50']:.1f} ms ({side}) | {s['wall']['p95']:.1f} ms | "
                     f"{s['cpu']['mean']:.1f} ms | {s['wall']['p50'] - floor:.1f} ms |")
    if r.get('launches'):
        L += render_launches(r['launches'])
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
              f"per class with at least {g['min_calls']} calls; every decision change must be intended"
              + ('; no payload\'s hooks may start more processes unless intended).' if r.get('launches') else ').')]
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
    ap.add_argument('--quick', action='store_true', help='every third payload (a quick local look; CI runs all)')
    ap.add_argument('--repeat', type=int, default=1, help='passes over the corpus')
    ap.add_argument('--hook-timeout', type=float, default=30.0, help='seconds a hook may run (default 30)')
    ap.add_argument('--serial', action='store_true',
                    help="the earlier model: each hook alone, wait the slowest (as if each had its own core)")
    ap.add_argument('--gate', action='store_true', help='exit 1 on a regression or an unintended decision change')
    ap.add_argument('--intended', default='', help="payload ids whose decision may change, comma or space separated, or 'all'")
    ap.add_argument('--intended-launches', default='',
                    help="payload ids whose hooks may start more processes, comma or space separated, or 'all' (with --launches)")
    ap.add_argument('--limit-pct', type=float, default=20.0, help='p50/p95 wait may grow by this much (default 20)')
    ap.add_argument('--floor-ms', type=float, default=5.0, help='and must also grow by this many ms (default 5)')
    ap.add_argument('--min-calls', type=int, default=20, help='gate only tool classes with at least this many calls (default 20)')
    ap.add_argument('--launches', choices=('off', 'auto', 'strace', 'shim'), default='off',
                    help='count the processes each hook starts, in a pass of its own: strace (Linux), shim (execs '
                         'through PATH only), or auto, strace where it works and shim elsewhere (default off)')
    ap.add_argument('--md', help='write the markdown report here (always printed to stdout)')
    ap.add_argument('--json', help='write the full result here')
    a = ap.parse_args()
    global TOGETHER, HOOK_TIMEOUT
    TOGETHER = not a.serial
    HOOK_TIMEOUT = a.hook_timeout

    repo = os.path.abspath(a.repo)
    method = a.launches
    if method == 'auto':
        method = 'strace' if strace_works() else 'shim'
    elif method == 'strace' and not strace_works():
        die('--launches strace: strace is not installed here, or may not trace')
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
        env.update({'HOME': home, 'CLAUDE_AUDIT_LOG': os.devnull, 'CLAUDE_SHADOW_LOG': os.devnull, 'CLAUDE_NET_ALLOWLIST': '',
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
        launches = None
        if method != 'off':
            launches = count_launches(method, rows, sides, env, home, tmp)
            launches['table'] = launch_table(launches)

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
                ti = row['tool_input']
                cmd = ti.get('command') or ti.get('file_path') or ti.get('url') or (ti.get('ws') or {}).get('url') or ''
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
        intended_l = set(re.split(r'[,\s]+', a.intended_launches.strip())) - {''}
        if launches:
            failures += launch_failures(launches, intended_l)

        report = {
            'date': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'machine': machine(),
            'base': {k_: sides['base'][k_] for k_ in ('ref', 'commit')}, 'head': {k_: sides['head'][k_] for k_ in ('ref', 'commit')},
            'corpus': {'name': 'audit log' if local else os.path.relpath(cpath, repo), 'count': len(rows), 'local': local,
                       'sha256': '' if local else hashlib.sha256(open(cpath, 'rb').read()).hexdigest(),
                       'tools': dict(sorted(((t, sum(1 for r in rows if r['tool_name'] == t)) for t in {r['tool_name'] for r in rows}),
                                            key=lambda kv: -kv[1]))},
            'repeat': a.repeat, 'together': TOGETHER, 'quick': a.quick, 'elapsed_s': round(elapsed, 1),
            'process_start_ms': start_cost(env, home),
            'classes': class_out, 'hooks': hook_out, 'launches': launches,
            'decisions': {'same': same, 'changed': changed},
            'gate': {'enabled': a.gate, 'limit_pct': a.limit_pct, 'floor_ms': a.floor_ms, 'min_calls': a.min_calls,
                     'intended': sorted(intended), 'intended_launches': sorted(intended_l), 'failures': failures, 'passed': not failures},
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
