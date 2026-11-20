#!/usr/bin/env python3
"""What each guard and rule in shadow mode would have decided, and what happened to the call.

hooks/lib/shadow.sh lists the guards and rules on trial (#237). Each writes what it would have
decided to ~/.claude/logs/shadow.log and decides nothing. This joins those lines on tool_use_id
to the auto-mode denials in the audit log (PermissionDenied), to the Bash guards' timing log, and
to how each call's permission resolved in the transcripts (bin/permission-friction.py reads
them), then counts per guard and rule. docs/shadow-mode.md says how step 9 reads it.

Counts and tool_use_ids only: never a command or a reason, since a reason can quote the command.

  tools/shadow-report.py               # the last 14 days, markdown to stdout
  tools/shadow-report.py --days 30
  tools/shadow-report.py --since 2026-10-19T08:00:00Z
"""
import argparse, collections, datetime as dt, importlib.util, json, os, re, sys

# hooknames.py and permission-friction.py install from bin/, beside this tools/ folder.
BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bin')
sys.path.insert(0, BIN)
from hooknames import add_window, read_timing, window  # noqa: E402

HOME = os.path.expanduser('~')

# Each call lands in exactly one of these, so a row's outcomes add up to its asks and denies.
OUTCOMES = [
    ('classifier', 'Classifier denied'),        # auto mode refused it with a verdict ([Category])
    ('no_verdict', 'Denied, no verdict'),       # auto mode refused it without one: not cover
    ('prompt_yes', 'Rule prompt approved'),     # a native ask rule had Claude Code ask a human
    ('prompt_no', 'Rule prompt rejected'),
    ('prompt_other', 'Other prompt'),           # asked for another reason (a safety check), or not recorded
    ('native_deny', 'Native deny'),             # a deny rule or a built-in check refused it
    ('live_guard', 'Live guard'),               # a guard still live asked or denied the same call
    ('ran_rule', 'Ran: allow rule'),
    ('ran_classifier', 'Ran: classifier'),
    ('ran_other', 'Ran: other'),                # mode, or the transcript does not say how
    ('no_outcome', 'No outcome'),               # no transcript result in the window
    ('no_id', 'No id'),                         # the payload had no tool_use_id
]
DENIED = re.compile(r'^(\S+) \| DENIED \| [^|]*? \| id=(\S*) mode=(\S*) \| (.*)$')


def friction():
    spec = importlib.util.spec_from_file_location('permission_friction', os.path.join(BIN, 'permission-friction.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def ts(s):
    try:
        return dt.datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except ValueError:
        return None


def shadow_lines(path, cut):
    """One entry per call, guard and rule: the first line, as the hook writes one a guard a call."""
    rows, bad = {}, 0
    for p in (path + '.1', path):
        try:
            f = open(p, encoding='utf-8', errors='replace')
        except OSError:
            continue
        with f:
            for n, line in enumerate(f):
                try:
                    d = json.loads(line)
                    t = ts(d['ts'])
                except (ValueError, KeyError, TypeError):
                    bad += 1
                    continue
                if not t or t < cut:
                    continue
                uid = d.get('tool_use_id') or ''
                key = (uid or f'{p}:{n}', d.get('guard') or '?', d.get('rule') or '?')
                rows.setdefault(key, dict(t=t, uid=uid, guard=key[1], rule=key[2], would=d.get('would'),
                                          mode=d.get('permission_mode') or ''))
    return list(rows.values()), bad


def denials(path, cut):
    """tool_use_id -> True when auto mode's denial carried a classifier verdict."""
    out = {}
    for p in [path + f'.{i}' for i in (5, 4, 3, 2, 1)] + [path]:
        try:
            f = open(p, encoding='utf-8', errors='replace')
        except OSError:
            continue
        with f:
            for line in f:
                m = DENIED.match(line.rstrip('\n'))
                if not m or not m[2]:
                    continue
                t = ts(m[1])
                if not t or t < cut:
                    continue
                parts = m[4].rsplit(' | ', 2)   # target, reason, dir: the target can hold ` | `
                why = parts[-2] if len(parts) == 3 else ''
                out[m[2]] = why.startswith('[')
    return out


def outcome(r, denied, timing, results, asks, hblocks):
    uid = r['uid']
    if not uid:
        return 'no_id'
    if uid in denied:
        return 'classifier' if denied[uid] else 'no_verdict'
    res = results.get(uid)
    pd = (res or {}).get('pd') or {}
    code = str(pd.get('reasonCode') or '')
    if (any(d in ('ask', 'deny') for _, _, _, d in timing.get(uid, [])) or asks.get(uid) or hblocks.get(uid)
            or code.startswith('hook:') or pd.get('source') == 'hook'):
        return 'live_guard'
    if res is None:
        return 'no_outcome'
    kind = res.get('kind')
    if kind == 'automode-unavailable' or (pd.get('decision') == 'reject' and code.startswith('classifier:') and 'unavailable' in code):
        return 'no_verdict'
    if kind == 'automode-blocked' or (pd.get('decision') == 'reject' and pd.get('reasonType') == 'classifier'):
        return 'classifier'
    if str(pd.get('source') or '').startswith('user'):
        if not code.startswith('rule:'):
            return 'prompt_other'
        return 'prompt_yes' if pd.get('decision') == 'accept' else 'prompt_no'
    if kind in ('user-rejected', 'cancelled'):
        return 'prompt_other'
    if pd.get('decision') == 'reject' or kind == 'permission-rule':
        return 'native_deny'
    if pd.get('decision') == 'accept' and pd.get('reasonType') in ('rule', 'subcommandResults'):
        return 'ran_rule'
    if pd.get('decision') == 'accept' and pd.get('reasonType') == 'classifier':
        return 'ran_classifier'
    return 'ran_other'


def render(rows, words, now, nbad, ndenied, nfiles, shadow_path):
    per = collections.defaultdict(lambda: dict(ask=0, deny=0, not_auto=0, ids=collections.defaultdict(list),
                                               **{k: 0 for k, _ in OUTCOMES}))
    for r in rows:
        c = per[(r['guard'], r['rule'])]
        c['ask' if r['would'] == 'ask' else 'deny'] += 1
        c['not_auto'] += r['mode'] != 'auto'
        c[r['out']] += 1
        if r['uid']:
            c['ids'][r['out']].append(r['uid'])
    head = ['Guard', 'Rule', 'Would ask', 'Would deny', 'Not in auto mode'] + [t for _, t in OUTCOMES]
    L = [f'# Shadow report: {"the " if words.startswith("last") else ""}{words}', '',
         f"{len(rows)} shadowed decisions from {len({r['uid'] for r in rows if r['uid']})} calls, read from "
         f"{shadow_path.replace(HOME, '~')} up to {now:%Y-%m-%d %H:%M} UTC"
         + (f", {nbad} unreadable lines skipped" if nbad else '') + '.',
         f'Joined on tool_use_id to {ndenied} auto-mode denials in the audit log, the Bash guards\' timing log, '
         f'and {nfiles} transcript files.', '',
         '| ' + ' | '.join(head) + ' |', '|---|---|' + '---:|' * (len(head) - 2)]
    tot = collections.Counter()
    for (g, rule), c in sorted(per.items()):
        cells = [c['ask'], c['deny'], c['not_auto']] + [c[k] for k, _ in OUTCOMES]
        tot.update(dict(zip(head[2:], cells)))
        L.append(f'| {g} | {rule} | ' + ' | '.join(str(x) for x in cells) + ' |')
    L.append('| **all** | | ' + ' | '.join(str(tot[h]) for h in head[2:]) + ' |')
    L += ['', 'Each decision is in one outcome column, so a row\'s outcomes add up to its asks and denies. '
          '"Not in auto mode" counts those made with no classifier running, whatever happened next.', '',
          '## tool_use_ids by outcome', '']
    for (g, rule), c in sorted(per.items()):
        if not c['ids']:
            continue
        L.append(f'### {g} {rule}')
        for k, t in OUTCOMES:
            if c['ids'].get(k):
                L.append(f"- {t}: {', '.join(sorted(c['ids'][k]))}")
        L.append('')
    return '\n'.join(L).rstrip('\n') + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    add_window(ap, 14, int)
    a = ap.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    cut, words = window(a, now)
    shadow_path = os.path.expanduser(os.environ.get('CLAUDE_SHADOW_LOG') or '~/.claude/logs/shadow.log')
    audit_path = os.path.expanduser(os.environ.get('CLAUDE_AUDIT_LOG') or '~/.claude/logs/audit.log')
    rows, nbad = shadow_lines(shadow_path, cut)
    denied = denials(audit_path, cut)
    files, _, results, asks, hblocks, _, _ = friction().collect(cut)
    timing = read_timing()
    for r in rows:
        r['out'] = outcome(r, denied, timing, results, asks, hblocks)
    sys.stdout.write(render(rows, words, now, nbad, len(denied), len(files), shadow_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
