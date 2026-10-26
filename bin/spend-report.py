#!/usr/bin/env python3
"""What Claude Code spent, read from the local transcripts.

  bin/spend-report.py                         the last 7 days: totals, sessions, subagents
  bin/spend-report.py --since 2026-10-23T19:00 --until 2026-10-26T08:00
  bin/spend-report.py --since 24h --tick-prompt "comms-hub tick" --max-ticks 3
  bin/spend-report.py --since 7d --turns      every turn: what started it and what it cost

Every assistant record in ~/.claude/projects/**/*.jsonl (subagents' included) is
counted once, by message id and request id, and priced at PRICES below: API list
prices in USD. On a subscription they are what the usage would have cost at those
prices, not a bill. An advisor consulted inside a call is priced at its own model,
from the call's `usage.iterations`; the call's top-level usage leaves it out.

Each call splits into input, output, cache read and cache write. A rewrite is a
call, after a transcript's first, that wrote at least half of a context of 20k
tokens or more: the cache had expired or changed under it. Away spend is what ran
when no prompt had been typed in any session for --away minutes, such as a loop's
ticks overnight or a subagent still running after you left.

Exit status: 0; 1 when a --max-* limit is passed (each printed as ALERT); 2 on a
bad argument.
"""
import argparse, bisect, collections, datetime as dt, glob, json, os, re, sys

PRICED = '2026-10-06'
# model: input, output, cache read, in USD per million tokens. A cache write costs
# 1.25x input with the 5-minute TTL and 2x with the 1-hour one; fast mode doubles all.
PRICES = {
    'claude-fable-5-1': (10, 50, 0.25), 'claude-mythos-5-1': (10, 50, 0.25),
    'claude-fable-5': (10, 50, 1.00), 'claude-mythos-5': (10, 50, 1.00),
    'claude-opus-5-5': (4, 20, 0.20), 'claude-opus-5': (5, 25, 0.50),
    'claude-opus-4-8': (5, 25, 0.50), 'claude-opus-4-7': (5, 25, 0.50), 'claude-opus-4-6': (5, 25, 0.50),
    'claude-sonnet-5-5': (2, 10, 0.20), 'claude-sonnet-5': (2, 10, 0.20), 'claude-sonnet-4-6': (3, 15, 0.30),
    'claude-haiku-5-5': (0.10, 0.50, 0.01), 'claude-haiku-4-5': (1, 5, 0.10),
}
# Claude Haiku 5.5 costs more once the prompt passes 100k tokens.
TIERS = {'claude-haiku-5-5': (100_000, (0.50, 2.50, 0.05))}
BUCKETS = ('input', 'output', 'read', 'write')
REWRITE_MIN = 20_000


def when(s, now):
    """`7d`, `24h`, `90m`, or an ISO date or time (local when it names no zone)."""
    m = re.fullmatch(r'(\d+)([dhm])', s)
    if m:
        return now - dt.timedelta(**{dict(d='days', h='hours', m='minutes')[m[2]]: int(m[1])})
    t = dt.datetime.fromisoformat(s)
    return t if t.tzinfo else t.astimezone()


def stamp(s):
    try:
        return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        return None


def price(model, usage, prices):
    """Cost of one usage block, split into BUCKETS; None when the model is not in the table."""
    model = re.sub(r'-\d{8}$', '', model or '')
    if model not in prices:
        return None
    i, o, r = prices[model]
    cw = usage.get('cache_creation_input_tokens') or 0
    ctx = (usage.get('input_tokens') or 0) + cw + (usage.get('cache_read_input_tokens') or 0)
    if model in TIERS and ctx > TIERS[model][0]:
        i, o, r = TIERS[model][1]
    if usage.get('speed') == 'fast':
        i, o, r = 2 * i, 2 * o, 2 * r
    w1 = (usage.get('cache_creation') or {}).get('ephemeral_1h_input_tokens') or 0
    return {'input': (usage.get('input_tokens') or 0) * i / 1e6,
            'output': (usage.get('output_tokens') or 0) * o / 1e6,
            'read': (usage.get('cache_read_input_tokens') or 0) * r / 1e6,
            'write': ((cw - w1) * 1.25 + w1 * 2) * i / 1e6}


def call_cost(model, usage, prices, unpriced):
    """The call's own cost and its advisor's, each split into BUCKETS."""
    own, adv = dict.fromkeys(BUCKETS, 0.0), dict.fromkeys(BUCKETS, 0.0)
    for it in usage.get('iterations') or [dict(usage, type='message')]:
        is_adv = it.get('type') == 'advisor_message'
        m = it.get('model') if is_adv else model
        c = price(m, dict(it, speed=usage.get('speed')), prices)
        if c is None:
            unpriced[m or '?'] += 1
            continue
        for k in BUCKETS:
            (adv if is_adv else own)[k] += c[k]
    return own, adv


def where(path, root):
    """(session id, agent id or '', project dir) of a transcript."""
    rel = os.path.relpath(path, root).split(os.sep)
    stem = os.path.basename(path)[:-len('.jsonl')]
    if len(rel) >= 4 and rel[-2] == 'subagents':
        return rel[-3], stem[len('agent-'):] if stem.startswith('agent-') else stem, rel[0]
    return stem, '', rel[0]


def human(d):
    if d.get('isMeta') or d.get('isCompactSummary'):
        return False
    return (d.get('origin') or {}).get('kind') == 'human' or d.get('turnOrigin') == 'human'


def prompt_of(d):
    """(kind, text) of a user record that starts a turn, or None for a tool result."""
    c = (d.get('message') or {}).get('content')
    if isinstance(c, list):
        if not c or not isinstance(c[0], dict) or c[0].get('type') == 'tool_result':
            return None
        c = ' '.join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    if not isinstance(c, str) or d.get('isMeta') or d.get('isCompactSummary'):
        return None
    kind = (d.get('origin') or {}).get('kind') or d.get('turnOrigin') or 'unknown'
    return kind, ' '.join(c.split())


def load(root, oldest):
    """Every transcript written since `oldest`: calls, prompts, agent types."""
    best, prompts, agents = {}, collections.defaultdict(list), {}
    for path in sorted(glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True)):
        try:
            if os.path.getmtime(path) < oldest.timestamp():
                continue
            fh = open(path, errors='replace')
        except OSError:
            continue
        sid, aid, project = where(path, root)
        if aid:
            try:
                agents[(sid, aid)] = json.load(open(path[:-len('.jsonl')] + '.meta.json')).get('agentType') or ''
            except (OSError, ValueError):
                agents[(sid, aid)] = ''
        with fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                t = stamp(d.get('timestamp'))
                if t is None:
                    continue
                if d.get('type') == 'user' and not aid:
                    p = prompt_of(d)
                    if p:
                        prompts[sid].append((t, p[0], p[1], human(d)))
                    continue
                m = d.get('message') if d.get('type') == 'assistant' else None
                if not isinstance(m, dict) or not m.get('id') or not isinstance(m.get('usage'), dict):
                    continue
                key = (m['id'], d.get('requestId'))
                # A streamed message is logged once per content block; the last
                # one carries the final output count.
                if key in best and (m['usage'].get('output_tokens') or 0) < (best[key]['usage'].get('output_tokens') or 0):
                    continue
                best[key] = {'t': t, 'model': m.get('model'), 'usage': m['usage'], 'sid': sid, 'aid': aid,
                             'project': project, 'path': path}
    for v in prompts.values():
        v.sort(key=lambda p: p[0])
    return list(best.values()), prompts, agents


def add(acc, c):
    for k in BUCKETS:
        acc[k] += c[k]


def total(acc):
    return sum(acc[k] for k in BUCKETS)


def share(acc):
    t = total(acc)
    return round(100 * acc['write'] / t) if t else 0


def report(args, now):
    since, until = when(args.since, now), when(args.until, now) if args.until else now
    away = dt.timedelta(minutes=args.away)
    calls, prompts, agents = load(args.root, since - away)
    prices = dict(PRICES)
    if args.prices:
        prices.update({k: tuple(v) for k, v in json.load(open(args.prices)).items()})
    typed = sorted(p[0] for ps in prompts.values() for p in ps if p[3])
    starts = {sid: [p[0] for p in ps] for sid, ps in prompts.items()}
    unpriced = collections.Counter()
    calls.sort(key=lambda c: (c['path'], c['t']))
    seen_path, rows = set(), []
    for c in calls:
        u = c['usage']
        cw = u.get('cache_creation_input_tokens') or 0
        ctx = (u.get('input_tokens') or 0) + cw + (u.get('cache_read_input_tokens') or 0)
        c['rewrite'] = c['path'] in seen_path and ctx >= REWRITE_MIN and cw * 2 >= ctx
        seen_path.add(c['path'])
        c['ctx'] = ctx
        if not since <= c['t'] < until:
            continue
        c['own'], c['adv'] = call_cost(c['model'], u, prices, unpriced)
        i = bisect.bisect_right(typed, c['t'])
        c['away'] = i == 0 or c['t'] - typed[i - 1] > away
        rows.append(c)

    def acc():
        return dict.fromkeys(BUCKETS, 0.0)

    tot, adv, away_acc = acc(), acc(), acc()
    sessions = collections.defaultdict(lambda: {'cost': acc(), 'calls': 0, 'rewrites': 0, 'away': 0.0, 'project': ''})
    subs = collections.defaultdict(lambda: {'cost': acc(), 'calls': 0, 'rewrites': 0, 'away': 0.0, 'first': None})
    turns = collections.defaultdict(lambda: {'cost': acc(), 'calls': 0, 'ctx': 0})
    for c in rows:
        both = {k: c['own'][k] + c['adv'][k] for k in BUCKETS}
        add(tot, c['own'])
        add(adv, c['adv'])
        if c['away']:
            add(away_acc, both)
        s = sessions[c['sid']]
        s['project'] = s['project'] or c['project']
        for r in [s] + ([subs[(c['sid'], c['aid'])]] if c['aid'] else []):
            add(r['cost'], both)
            r['calls'] += 1
            r['rewrites'] += c['rewrite']
            r['away'] += total(both) if c['away'] else 0
        if c['aid']:
            sub = subs[(c['sid'], c['aid'])]
            sub['first'] = min(sub['first'] or c['t'], c['t'])
            continue
        j = bisect.bisect_right(starts.get(c['sid'], []), c['t']) - 1
        if j >= 0:
            tr = turns[(c['sid'], j)]
            add(tr['cost'], both)
            tr['calls'] += 1
            tr['ctx'] = max(tr['ctx'], c['ctx'])

    alerts, out = [], []
    grand = {k: tot[k] + adv[k] for k in BUCKETS}
    loc = lambda t: t.astimezone().strftime('%Y-%m-%d %H:%M')
    out.append(f"window {loc(since)} to {loc(until)} (local); {len({c['path'] for c in rows})} transcripts, "
               f"{len(rows)} calls; API list prices of {PRICED}, USD")
    out.append(f"total ${total(grand):.2f}: input ${tot['input']:.2f}, output ${tot['output']:.2f}, "
               f"cache read ${tot['read']:.2f}, cache write ${tot['write']:.2f} ({share(grand)}% writes), "
               f"advisor ${total(adv):.2f}")
    if unpriced:
        out.append('unpriced, so left out of every total: ' + ', '.join(f'{m} ({n} calls)' for m, n in unpriced.most_common()))
    out.append(f"away (no prompt typed in the {args.away} min before): ${total(away_acc):.2f} "
               f"in {sum(c['away'] for c in rows)} calls")
    if args.max_away is not None and total(away_acc) > args.max_away:
        alerts.append(f"away spend ${total(away_acc):.2f} is over --max-away ${args.max_away:.2f}")

    out.append('\nsessions: cost, calls, write share, rewrites, spent away, session, project')
    for sid, s in sorted(sessions.items(), key=lambda kv: -total(kv[1]['cost']))[:args.top]:
        out.append(f"  ${total(s['cost']):8.2f} {s['calls']:5d} {share(s['cost']):3d}% {s['rewrites']:3d} "
                   f"${s['away']:7.2f}  {sid[:8]}  {s['project']}")
    out.append('\nsubagents: cost, calls, write share, rewrites, spent away, started, session/agent, type')
    for (sid, aid), s in sorted(subs.items(), key=lambda kv: -total(kv[1]['cost']))[:args.top]:
        out.append(f"  ${total(s['cost']):8.2f} {s['calls']:5d} {share(s['cost']):3d}% {s['rewrites']:3d} "
                   f"${s['away']:7.2f}  {loc(s['first'])}  {sid[:8]}/{aid[:8]}  {agents.get((sid, aid), '')}")
    for (sid, aid), s in subs.items():
        if args.max_write_share is not None and total(s['cost']) >= 1 and share(s['cost']) > args.max_write_share:
            alerts.append(f"subagent {sid[:8]}/{aid[:8]} spent {share(s['cost'])}% of ${total(s['cost']):.2f} "
                          f"on cache writes, over --max-write-share {args.max_write_share}%")
    for key, s in list(sessions.items()) + list(subs.items()):
        if args.max_rewrites is not None and s['rewrites'] > args.max_rewrites:
            name = key if isinstance(key, str) else '/'.join(k[:8] for k in key)
            alerts.append(f"{name[:17]} rewrote its context {s['rewrites']} times, over --max-rewrites {args.max_rewrites}")

    listed = []
    for (sid, j), tr in turns.items():
        t, kind, text, _ = prompts[sid][j]
        if args.tick_prompt and args.tick_prompt not in text:
            continue
        listed.append((t, sid, kind, text, tr))
    listed.sort(key=lambda x: x[0])
    if args.tick_prompt:
        cost = sum(total(x[4]['cost']) for x in listed)
        n = len(listed)
        out.append(f"\nticks whose prompt contains {args.tick_prompt!r}: {n}, ${cost:.2f}"
                   + (f", ${cost / n:.2f} and {sum(x[4]['calls'] for x in listed) / n:.1f} calls a tick, "
                      f"largest context {max(x[4]['ctx'] for x in listed) // 1000}k" if n else ''))
        if args.max_ticks is not None and cost > args.max_ticks:
            alerts.append(f"ticks cost ${cost:.2f}, over --max-ticks ${args.max_ticks:.2f}")
    if args.turns:
        out.append('\nturns: started, cost, calls, write share, largest context, session, started by, prompt')
        for t, sid, kind, text, tr in listed:
            out.append(f"  {loc(t)} ${total(tr['cost']):7.2f} {tr['calls']:4d} {share(tr['cost']):3d}% "
                       f"{tr['ctx'] // 1000:4d}k  {sid[:8]}  {kind}  {text[:40]}")
    out.extend(f'ALERT: {a}' for a in alerts)
    if args.json:
        print(json.dumps({'since': since.isoformat(), 'until': until.isoformat(), 'priced': PRICED,
                          'calls': len(rows), 'total': grand, 'advisor': adv, 'away': away_acc,
                          'unpriced': dict(unpriced), 'alerts': alerts,
                          'sessions': sessions,
                          'subagents': {'/'.join(k): {**v, 'first': v['first'] and v['first'].isoformat()}
                                        for k, v in subs.items()},
                          'turns': [{'start': t.isoformat(), 'session': sid, 'kind': kind, 'calls': tr['calls'],
                                     'ctx': tr['ctx'], 'cost': tr['cost']} for t, sid, kind, _, tr in listed]},
                         indent=1))
    else:
        print('\n'.join(out))
    return 1 if alerts else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--since', default='7d', help='7d, 24h, 90m or an ISO time (default 7d)')
    ap.add_argument('--until', help='the window end, as --since (default now)')
    ap.add_argument('--root', default=os.path.expanduser('~/.claude/projects'))
    ap.add_argument('--away', type=int, default=60, metavar='MIN',
                    help='minutes after the last typed prompt that spend counts as away (default 60)')
    ap.add_argument('--tick-prompt', metavar='TEXT', help='count the turns whose prompt contains TEXT as ticks')
    ap.add_argument('--turns', action='store_true', help='list each turn (only the ticks, with --tick-prompt)')
    ap.add_argument('--top', type=int, default=10, help='rows per table (default 10)')
    ap.add_argument('--prices', metavar='FILE', help='JSON {model: [input, output, cache read]} over the table')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--max-away', type=float, metavar='USD')
    ap.add_argument('--max-ticks', type=float, metavar='USD')
    ap.add_argument('--max-write-share', type=int, metavar='PCT', help='for a subagent that cost $1 or more')
    ap.add_argument('--max-rewrites', type=int, metavar='N', help='for any one session or subagent')
    args = ap.parse_args(argv)
    try:
        return report(args, dt.datetime.now().astimezone())
    except ValueError as e:
        print(f'spend-report: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
