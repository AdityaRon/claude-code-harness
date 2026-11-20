#!/usr/bin/env python3
"""Synthetic Claude Code transcripts for the suites, written at test time. No JSONL corpus
is committed, and none of it comes from a real transcript.

  python3 tests/lib/transcripts.py PROJECTS [--base now|ISO] [--canary TEXT]

writes one project under PROJECTS (a ~/.claude/projects) and prints what it planted, as
JSON. --base is the first record's time (default: two hours ago, so windows counted back
from now hold every record). The corpus holds:

  - a main session, its cache writes 1 h, whose first call is streamed as two records
    under one message id (the second carries the final output count);
  - a Bash call a guard asked on, with its PreToolUse hook record (durationMs) and result;
  - a scheduled fire (isMeta with a scheduledFireId) 77 min after the last call, whose
    first call rewrites the context: past the 1 h TTL;
  - a compact_boundary and its isCompactSummary record, then a call that rewrites;
  - a subagent file with a .meta.json, its writes 5 min, and a rewrite 7 min after the
    call before;
  - the canary at the start of every prompt and of the compact summary, so a report that
    prints prompt or chat text, even its first 40 characters, prints the canary.

Suites import the record helpers too (sys.path.insert(0, 'tests/lib')).
"""
import argparse, datetime as dt, json, os, sys

UTC = dt.timezone.utc
CANARY = 'CANARY-7f3a91c2'
TICK = 'loop tick'
SESSION, AGENT, PROJECT = 'sess-main', 'sub1', 'proj'


def stamp(t):
    """A datetime, or an ISO string as it is, as Claude Code writes timestamps."""
    if isinstance(t, str):
        return t
    return t.astimezone(UTC).strftime('%Y-%m-%dT%H:%M:%S.') + '%03dZ' % (t.microsecond // 1000)


def user(t, text, kind='human', **extra):
    """A prompt. kind None leaves out origin, as a scheduled fire's record does."""
    d = {'type': 'user', 'timestamp': stamp(t), 'message': {'role': 'user', 'content': text}}
    if kind:
        d['origin'] = {'kind': kind}
    d.update(extra)
    return d


def scheduled(t, text, fire='fire-1', **extra):
    """A /loop or cron fire, as Claude Code records one: isMeta, a scheduledFireId, no origin."""
    return user(t, text, None, isMeta=True, scheduledFireId=fire, **extra)


def usage(out=0, read=0, w5=0, w1=0, inp=0, **extra):
    u = {'input_tokens': inp, 'output_tokens': out, 'cache_read_input_tokens': read,
         'cache_creation_input_tokens': w5 + w1,
         'cache_creation': {'ephemeral_5m_input_tokens': w5, 'ephemeral_1h_input_tokens': w1}}
    u.update(extra)
    return u


def asst(t, mid, model='claude-opus-5-5', out=0, read=0, w5=0, w1=0, inp=0, content=None, rec=None, **extra):
    """One assistant record: message `mid`, request req-`mid`; usage extras (speed, iterations) in **extra."""
    m = {'id': mid, 'model': model, 'usage': usage(out, read, w5, w1, inp, **extra)}
    if content is not None:
        m['content'] = content
    d = {'type': 'assistant', 'timestamp': stamp(t), 'requestId': 'req-' + mid, 'message': m}
    d.update(rec or {})
    return d


def streamed(t, mid, blocks, outs, **kw):
    """One message logged once per content block, as Claude Code streams it: same id, rising output."""
    return [asst(t + dt.timedelta(seconds=i) if not isinstance(t, str) else t, mid, out=o, content=[b], **kw)
            for i, (b, o) in enumerate(zip(blocks, outs))]


def tool_use(uid, name, inp):
    return {'type': 'tool_use', 'id': uid, 'name': name, 'input': inp}


def tool_result(t, uid, text='ok', err=False, **extra):
    d = {'type': 'user', 'timestamp': stamp(t),
         'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': uid, 'content': text,
                                                  'is_error': err}]}}
    d.update(extra)
    return d


def hook(t, uid, command, ms, event='PreToolUse', tool='Bash', decision=None, reason=''):
    """A hook record: Claude Code writes one when the hook printed or failed."""
    at = {'type': 'hook_success', 'hookName': f'{event}:{tool}', 'hookEvent': event, 'command': command,
          'toolUseID': uid, 'durationMs': ms}
    if decision:
        at['stdout'] = json.dumps({'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': decision,
                                                          'permissionDecisionReason': reason}})
    return {'type': 'attachment', 'timestamp': stamp(t), 'attachment': at}


def boundary(t, trigger='auto'):
    return {'type': 'system', 'subtype': 'compact_boundary', 'timestamp': stamp(t), 'level': 'info',
            'content': 'Conversation compacted', 'compactMetadata': {'trigger': trigger}}


def write(path, rows):
    """One record a line, as compact as Claude Code writes them: disk-space.py counts compactions
    by the bytes `"subtype":"compact_boundary"`."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in rows))


def corpus(projects, base, canary=CANARY):
    """Write the corpus the module docstring lists under PROJECTS; return what it planted."""
    m = lambda minutes: base + dt.timedelta(minutes=minutes)
    ctx = {'sessionId': SESSION, 'cwd': '/work/proj', 'sessionKind': 'interactive'}
    with_ctx = lambda d: {**d, **ctx}
    K = 1000
    cmd = 'curl -s https://example.invalid/status'
    main = [with_ctx(r) for r in [
        user(m(0), f'{canary} fix the build'),
        # The first call, streamed: a text block, then the tool_use with the final output count.
        *streamed(m(0.2), 'm1', [{'type': 'text', 'text': 'Checking.'},
                                 tool_use('toolu_1', 'Bash', {'command': cmd, 'description': 'status'})],
                  [40, 400], w1=30 * K),
        hook(m(0.25), 'toolu_1', '~/.claude/hooks/network-guard.sh', 120, decision='ask',
             reason='network-guard: a request to example.invalid is outside the allowlist.'),
        tool_result(m(1), 'toolu_1', 'ok'),
        asst(m(1.1), 'm2', out=50, read=30 * K, w1=2 * K),
        # 77 min after the last call: past the 1 h TTL, so this tick's first call rewrites.
        scheduled(m(78), f'{canary} {TICK}'),
        asst(m(78.1), 'm3', out=60, w1=40 * K),
        boundary(m(90)),
        user(m(90), f'{canary} summary of the conversation so far', None, isCompactSummary=True),
        asst(m(91), 'm4', out=70, w1=25 * K),
    ]]
    sub = [{**r, 'sessionId': SESSION, 'isSidechain': True} for r in [
        user(m(20), f'{canary} review the diff', None),
        asst(m(21), 's1', model='claude-haiku-5-5', out=30, w5=30 * K),
        asst(m(23), 's2', model='claude-haiku-5-5', out=30, read=30 * K),
        # 7 min after the call before: past the 5 min TTL.
        asst(m(30), 's3', model='claude-haiku-5-5', out=30, w5=35 * K),
    ]]
    main_path = os.path.join(projects, PROJECT, SESSION + '.jsonl')
    sub_path = os.path.join(projects, PROJECT, SESSION, 'subagents', f'agent-{AGENT}.jsonl')
    write(main_path, main)
    write(sub_path, sub)
    with open(sub_path[:-len('.jsonl')] + '.meta.json', 'w') as f:
        json.dump({'agentType': 'reviewer'}, f)
    return {'canary': canary, 'tick_prompt': TICK, 'base': stamp(base), 'session': SESSION, 'agent': AGENT,
            'files': [main_path, sub_path], 'calls': 7, 'records': len(main) + len(sub), 'streamed': 1,
            'scheduled': 1, 'compact_boundaries': 1, 'subagents': 1, 'guard_asks': 1, 'hook_records': 1,
            'tool_calls': 1, 'canary_records': 4, 'ttl': {main_path: '1h', sub_path: '5m'},
            'rewrites': {'ttl-gap': 2, 'compaction': 1, 'other': 0}}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('projects')
    ap.add_argument('--base', default='now', help='the first record\'s time: an ISO time, or now (two hours ago)')
    ap.add_argument('--canary', default=CANARY)
    a = ap.parse_args(argv)
    if a.base == 'now':
        base = dt.datetime.now(UTC).replace(microsecond=0) - dt.timedelta(hours=2)
    else:
        base = dt.datetime.fromisoformat(a.base.replace('Z', '+00:00'))
        base = base if base.tzinfo else base.replace(tzinfo=UTC)
    print(json.dumps(corpus(a.projects, base, a.canary), indent=1))


if __name__ == '__main__':
    sys.exit(main())
