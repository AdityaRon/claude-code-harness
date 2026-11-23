#!/usr/bin/env python3
"""The three largest costs on this machine, from the harness's own local tools.

  python3 ~/.claude/harness-checkup.py              the last 7 days, as text a skill can read
  python3 ~/.claude/harness-checkup.py --days 30 --json

Runs, from beside this file (installed: ~/.claude; in the clone: bin/):
  spend-report.py --json             cache rewrites after a lapsed TTL, by cause
  permission-friction.py --json      time calls were held by a prompt that was then approved
  hook-latency.py --total --json     the slowest Bash guard's p95 (bash-guards' timing log)
  disk-space.py report --json        what the job folders hold
  memory-verify.sh --offline --json  each memory index against its load limit, and its findings

Each cost is measured against a line: the one session-start already warns at where there is one,
else one set in LINES below. They are ranked by measured / line, and that multiplier is printed
with the value, its n and its window.

It reads numbers from each tool's JSON and prints only those and fixed words: never prompt or chat
text, never a dollar amount (spend shows as a share), never a tool's own output. It clones
nothing, installs nothing and uses no network: memory-verify runs --offline, and disk-space is
pointed at `false` for `claude agents`, so job liveness reads unknown (sizes do not need it).

Each step prints its name and seconds on stderr as it ends (`spend-report 141 s`), and --json
carries them as `steps`; stdout is unchanged. Nothing is cached between runs.

Exit status: 0; 2 on a bad argument. A tool that fails is named, with its exit status, and its
cost is left out of the ranking.
"""
import argparse, datetime as dt, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser('~')
# key: (line, unit, where the line comes from)
LINES = {
    'ttl-gap': (10.0, '% of cache-write tokens', 'set here: a compaction must rewrite, a lapsed TTL need not'),
    'asks': (1.0, 'h a day', 'set here'),
    'guard': (1000.0, 'ms', "session-start's guard warning, CLAUDE_GUARD_P90_WARN_MS"),
    'jobs': (50.0, 'GB', "session-start's job folder warning, CLAUDE_DISK_WARN_JOBS_GB"),
    'memory': (100.0, '% of its load limit', "Claude Code's 200 lines or 25,000 bytes"),
}
TIMEOUT = 600


def run(name, argv, env=None):
    """(parsed JSON or None, why not). A tool's stdout and stderr are never printed."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT, env=env, errors='replace')
    except (OSError, subprocess.SubprocessError) as e:
        return None, f'{name} did not run ({type(e).__name__})'
    out = p.stdout
    if name == 'memory-verify':   # one JSON object a line; exit 1 and 2 report findings
        if p.returncode not in (0, 1, 2):
            return None, f'{name} exited {p.returncode}'
        rows = []
        for ln in out.splitlines():
            try:
                rows.append(json.loads(ln))
            except ValueError:
                pass
        return rows, ''
    if p.returncode != 0:
        return None, f'{name} exited {p.returncode}'
    try:
        return json.loads(out), ''
    except ValueError:
        return None, f'{name} printed no JSON'


def tool(name):
    return os.path.join(HERE, name)


def py(name, *args):
    return [sys.executable, tool(name), *args]


def cost(key, name, value, n, window, source, detail=''):
    line, unit, why = LINES[key]
    return {'key': key, 'name': name, 'value': value, 'unit': unit, 'line': line, 'line_source': why,
            'x': value / line, 'n': n, 'window': window, 'source': source, 'detail': detail}


def ttl_gap(d, window):
    rc = d['rewrite_causes']
    written = sum(g['written'] for g in rc.values())
    gap = {k: sum(g[k]['calls'] for g in rc.values()) for k in ('ttl-gap', 'compaction', 'other')}
    toks = sum(g['ttl-gap']['tokens'] for g in rc.values())
    share = 100.0 * toks / written if written else 0.0
    per = ', '.join(f"{label} {100.0 * g['ttl-gap']['tokens'] / g['written']:.0f}%"
                    for label, g in (('main sessions', rc['main']), ('subagents', rc['subagents'])) if g['written'])
    return cost('ttl-gap', 'cache rewrites after a lapsed TTL', share,
                f"{gap['ttl-gap']:,} of {sum(gap.values()):,} rewrites in {d['calls']:,} calls", window,
                'spend-report.py', per or 'no cache writes')


def asks(d, days, window):
    """Each group's approved prompts times its median hold: a few prompts left for hours while no one
    was at the keyboard carry the plain sum (on one Mac, 11 of 284 made 47 of its 83 hours), and
    should not carry the rank. A hold runs from the call to its result, so it holds the run time too."""
    groups = [(w.get('asks') or 0, w.get('ask_p50') or 0, w.get('ask_total_h') or 0) for w in d['waits'].values()]
    groups += [(g['count'], g.get('wait_p50_s') or 0, g.get('wait_total_h') or 0) for g in d['prompt_approved']]
    n = sum(c for c, _, _ in groups)
    hours = sum(c * p50 for c, p50, _ in groups) / 3600
    held = sum(t for _, _, t in groups)
    return cost('asks', 'calls held by prompts that were then approved, count x median hold', hours / days,
                f"{n:,} approved prompts of {d['totals']['tool_calls']:,} tool calls", window, 'permission-friction.py',
                f'held from call to result, run time included; {held:.1f} h summed, which a few long holds carry')


def guard(d, window):
    """From bash-guards' timing log, which has every Bash call; hook records cover only the calls a hook answered."""
    rows = [g for g in d.get('guards') or [] if g.get('p95') is not None]
    if not rows:
        return None
    g = max(rows, key=lambda r: r['p95'])
    return cost('guard', 'slowest Bash guard, p95 per call', float(g['p95']), f"{g['n']:,} calls", window,
                'hook-latency.py', f"{g['guard']}, from bash-guards' timing log")


def jobs(d):
    gb = (d.get('total_bytes') or 0) / 1e9
    big = len(d.get('transcripts') or [])
    return cost('jobs', 'job folders on disk', gb, f"{len(d.get('jobs') or [])} folders", 'now', 'disk-space.py report',
                f'{big} transcripts at or over CLAUDE_TRANSCRIPT_WARN_MB')


def limits():
    """(max lines, max bytes) from hooks/lib/memory-limits.sh, beside this file or in the clone."""
    lines, chars = 200, 25000
    for p in (os.path.join(HERE, 'hooks', 'lib', 'memory-limits.sh'),
              os.path.join(HERE, '..', 'hooks', 'lib', 'memory-limits.sh')):
        try:
            text = open(p).read()
        except OSError:
            continue
        m = re.search(r'MEMORY_MAX_LINES="\$\{MEMORY_INDEX_MAX_LINES:-(\d+)\}"', text)
        c = re.search(r'MEMORY_MAX_BYTES="\$\{MEMORY_INDEX_MAX_CHARS:-(\d+)\}"', text)
        lines = int(os.environ.get('MEMORY_INDEX_MAX_LINES') or (m and m[1]) or lines)
        chars = int(os.environ.get('MEMORY_INDEX_MAX_CHARS') or (c and c[1]) or chars)
        break
    return lines, chars


def memory(rows, projects):
    max_lines, max_chars = limits()
    worst, stores = 0.0, 0
    for name in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        idx = os.path.join(projects, name, 'memory', 'MEMORY.md')
        try:
            data = open(idx, 'rb').read()
        except OSError:
            continue
        stores += 1
        worst = max(worst, 100.0 * data.count(b'\n') / max_lines, 100.0 * len(data) / max_chars)
    if not stores:
        return None
    need = [r for r in rows if r.get('status') in ('STALE', 'TRIAGE', 'ORPHAN', 'OVERSIZE')]
    offline = sum(r.get('status') == 'SKIP' and r.get('detail', '').endswith('offline') for r in rows)
    return cost('memory', 'the largest memory index', worst, f'{stores} stores', 'now',
                'memory-verify.sh --offline',
                f'{len(need)} findings need attention; {offline} GitHub claims not checked, offline')


def gather(days):
    now = dt.datetime.now(dt.timezone.utc)
    window = f"last {days:g} days, {(now - dt.timedelta(days=days)):%Y-%m-%d} to {now:%Y-%m-%d}"
    projects = os.path.join(HOME, '.claude', 'projects')
    # No __pycache__ beside the installed tools: the checkup writes nothing.
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    jobs_env = dict(env, CLAUDE_CLI_BIN=shutil.which('false') or '/usr/bin/false')
    costs, errors = [], []
    steps = [
        ('spend-report', py('spend-report.py', '--since', f'{days:g}d', '--top', '0', '--json'), env,
         lambda d: ttl_gap(d, window)),
        ('permission-friction', py('permission-friction.py', '--days', f'{days:g}', '--json'), env,
         lambda d: asks(d, days, window)),
        ('hook-latency', py('hook-latency.py', '--days', f'{days:g}', '--total', '--json'), env,
         lambda d: guard(d, window)),
        ('disk-space', py('disk-space.py', 'report', '--json'), jobs_env, jobs),
        ('memory-verify', ['bash', tool('memory-verify.sh'), '--offline', '--json'], env,
         lambda rows: memory(rows, projects)),
    ]
    timings = []
    for name, argv, env, read in steps:
        began = time.monotonic()
        d, why = run(name, argv, env)
        took = time.monotonic() - began
        # Progress goes to stderr only: stdout is the report, or the --json a caller parses.
        print(f'{name} {took:.0f} s', file=sys.stderr, flush=True)
        timings.append({'name': name, 'seconds': round(took, 1)})
        if d is None:
            errors.append(why)
            continue
        try:
            c = read(d)
        except (KeyError, TypeError, ValueError, ZeroDivisionError) as e:
            errors.append(f'{name}: its JSON is not the shape this reads ({type(e).__name__})')
            continue
        if c:
            costs.append(c)
        else:
            errors.append(f'{name}: nothing to measure in the window')
    costs.sort(key=lambda c: -c['x'])
    return {'generated': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'days': days, 'costs': costs, 'errors': errors,
            'steps': timings}


def number(v, unit):
    if unit.startswith('%'):
        return f'{v:.0f}{unit}'
    return f'{v:,.0f} {unit}' if unit == 'ms' else f'{v:.1f} {unit}'


def text(r):
    out = [f"harness-checkup, {r['generated']}: the three largest costs on this machine, "
           'ranked by measured / line']
    top, rest = r['costs'][:3], r['costs'][3:]
    for i, c in enumerate(top, 1):
        out.append(f"{i}. {c['name']}: {number(c['value'], c['unit'])}, {c['x']:.1f}x the line of "
                   f"{number(c['line'], c['unit'][:1] if c['unit'].startswith('%') else c['unit'])} ({c['line_source']})")
        out.append(f"   n = {c['n']}; {c['window']}; {c['source']}; {c['detail']}")
    if len(top) < 3:
        out.append(f'Only {len(top)} of 5 costs could be measured.')
    if rest:
        out.append('Below these: ' + '; '.join(f"{c['name']} {c['x']:.2f}x" for c in rest) + '.')
    for e in r['errors']:
        out.append(f'Not measured: {e}.')
    return '\n'.join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--days', type=int, default=7, help='the window for spend, prompts and guard times (default 7)')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args(argv)
    if not a.days > 0:
        ap.error('--days must be above 0')
    r = gather(a.days)
    print(json.dumps(r, indent=1) if a.json else text(r))
    return 0


if __name__ == '__main__':
    sys.exit(main())
