#!/usr/bin/env python3
"""Permission friction from local Claude Code transcripts.

Joins every tool call in ~/.claude/projects/**/*.jsonl to how its permission
resolved: a harness guard asked (and the human approved / rejected), a guard
blocked, a deny rule fired, the auto-mode classifier blocked or gave no
verdict, or Claude Code refused on its own. Cross-checks guard asks against
the harness audit log.

An approved prompt raised by Claude Code itself (not a hook) leaves no trace in
the transcript, so it is not counted.

  bin/permission-friction.py --days 49 --out DIR   # DIR/report.md + DIR/friction.json
  bin/permission-friction.py --days 49             # report to stdout
  bin/permission-friction.py --replay hooks/       # also re-run recorded asks/blocks through these guards
"""
import argparse, collections, datetime as dt, glob, json, os, re, shlex, subprocess, sys

HOME = os.path.expanduser('~')
CLAUDE = os.path.join(HOME, '.claude')
PROJECTS = os.path.join(CLAUDE, 'projects')
AUDIT = [os.path.join(CLAUDE, 'logs', f) for f in ('audit.log.1', 'audit.log')]
SETTINGS = os.path.join(CLAUDE, 'settings.json')
HOOKS = os.path.join(CLAUDE, 'hooks')

# Machine-local masks, one per line: `<regex>` or `<regex> => <replacement>`. Kept out of
# the repo because the names worth masking (tenant ids, customer names) are site-specific.
MASK_FILE = os.path.join(CLAUDE, 'permission-friction.masks')


def load_masks():
    out = []
    if os.path.exists(MASK_FILE):
        for line in open(MASK_FILE):
            line = line.rstrip('\n')
            if line.strip() and not line.lstrip().startswith('#'):
                rx, _, rep = line.partition(' => ')
                out.append((re.compile(rx.strip()), rep.strip() or '<MASKED>'))
    return out + [
        (re.compile(r'(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+'), 'Bearer <MASKED>'),
        (re.compile(r'(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|authorization)(["\']?\s*[:=]\s*["\']?)[^\s"\'&,;]+'), r'\1\2<MASKED>'),
        (re.compile(r'(://)[^/\s:@]+:[^/\s@]+@'), r'\1<MASKED>@'),
        (re.compile(r'\b(ghp|gho|ghs|github_pat|xox[abpr]|sk|AKIA)[-_A-Za-z0-9]{12,}'), '<TOKEN>'),
        (re.compile(r'[\w.+-]+@[\w-]+\.[\w.]+'), '<EMAIL>'),
        (re.compile(r'[A-Za-z0-9+/=_-]{48,}'), '<LONG>'),
        (re.compile(re.escape(HOME)), '~'),
    ]


MASKS = load_masks()


def mask(s, n=200):
    s = str(s)
    for rx, rep in MASKS:
        s = rx.sub(rep, s)
    s = ' '.join(s.split())
    return s if len(s) <= n else s[:n] + '…'


def ts(s):
    try:
        return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception:
        return None


def text_of(content):
    if isinstance(content, list):
        return ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
    return str(content or '')


# ---- command tokenizing -------------------------------------------------------

HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1([^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)
OPS = {';', '&&', '||', '|', '&', '(', ')', ';;', '|&'}
WRAPPERS = {'env', 'nohup', 'timeout', 'time', 'command', 'caffeinate', 'xargs', 'sudo', 'nice', 'exec', 'builtin'}
KEYWORDS = {'do', 'then', 'else', 'elif', '!', '{'}
SKIP_SEG = {'for', 'while', 'until', 'if', 'case', 'done', 'fi', 'esac', '}', 'function', 'select', 'in'}
TWO_WORD = {'git', 'gh', 'kubectl', 'docker', 'npm', 'pnpm', 'yarn', 'poetry', 'uv', 'tsh', 'cargo', 'go', 'brew',
            'claude', 'helm', 'aws', 'gcloud', 'az', 'make', 'bazel', 'terraform', 'security'}
VALUE_FLAGS = {'-C', '-c', '--context', '-n', '--namespace', '--request-timeout', '-R', '--repo', '-o', '--git-dir', '--work-tree'}
INTERP = re.compile(r'^(python[0-9.]*|node|ruby|perl|php|bash|sh|zsh|deno|bun)$')
INLINE_FLAG = re.compile(r'^(-[A-Za-z]*[ce]|--eval|--exec|-r|-|-p|--print|-E)$')
NOISE = {'cd', 'echo', 'printf', 'true', 'false', 'set', 'export', 'head', 'tail', 'sort', 'wc', 'cat', 'grep', 'sed', 'awk',
         'uniq', 'jq', 'tr', 'cut', 'date', 'sleep', 'ls', 'mkdir', 'test', '[', '[[', 'local', 'return', 'exit', 'source', '.',
         'read', 'shift', 'paste', 'column', 'tee', 'basename', 'dirname', 'wait', 'break', 'continue', ':', 'unset'}


def segments(cmd):
    """Simple commands in a Bash string, heredoc bodies removed, as token lists."""
    s = HEREDOC.sub(lambda m: ' __HEREDOC__ ' + m.group(3), cmd or '')
    s = re.sub(r'\d*>&\d*-?|&>>?', ' ', s).replace('\n', ' ; ')
    try:
        lex = shlex.shlex(s, posix=True, punctuation_chars=';&|()')
        lex.whitespace_split = True
        lex.commenters = ''
        toks = list(lex)
    except ValueError:
        toks = s.split()
    segs, cur = [], []
    for t in toks:
        if t in OPS or (t and set(t) <= set(';&|()')):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    out = []
    for seg in segs:
        while seg and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=', seg[0]) or seg[0] in KEYWORDS):
            seg = seg[1:]
        while seg and seg[0] in WRAPPERS:
            seg = seg[1:]
            while seg and (seg[0].startswith('-') or re.match(r'^\d+[smhd]?$', seg[0]) or re.match(r'^[A-Za-z_]\w*=', seg[0])):
                seg = seg[1:]
        if not seg or seg[0] in SKIP_SEG or seg[0].endswith('()') or seg[0] == '__HEREDOC__':
            continue
        out.append(seg)
    return out


def word(toks):
    w = toks[0]
    if '/.claude/skills/' in w or w.startswith('~/.claude/skills/'):
        return 'skill:' + os.path.basename(w)
    if '/.claude/jobs/' in w or '$T/' in w or '$CLAUDE_JOB_DIR' in w:
        return 'job-tmp-script'
    if '/' in w:
        w = os.path.basename(w)
    if not re.match(r'^[\w.+-]+$', w):
        return None
    if w in TWO_WORD:
        rest, skip = [], False
        for t in toks[1:]:
            if skip:
                skip = False; continue
            if t in VALUE_FLAGS:
                skip = True; continue
            if t.startswith('-'):
                continue
            rest.append(t); break
        if rest and re.match(r'^[\w-]+$', rest[0]):
            return f'{w} {rest[0]}'
    return w


def shape(cmd):
    """Command family: the commands that decide permission, minus pipeline glue."""
    words = [w for w in (word(t) for t in segments(cmd)) if w]
    core = [w for w in words if w not in NOISE] or words
    return mask(' | '.join(list(dict.fromkeys(core))[:4]) or '(empty)')


def interp_kind(cmd):
    """How a command trips interpreter-guard's long-script ask."""
    for seg in segments(cmd):
        if not INTERP.match(os.path.basename(seg[0])):
            continue
        args = seg[1:]
        if '__HEREDOC__' in args or (args and args[0] == '-' and '<' in ' '.join(args)):
            return 'heredoc into interpreter'
        if any(INLINE_FLAG.match(a) for a in args[:3]):
            return 'inline -c/-e code'
    if re.search(r'(python[0-9.]*|node|ruby|perl|bash|sh|zsh)\s+-\s*<<', cmd or ''):
        return 'heredoc into interpreter'
    return 'no inline code in the interpreter\'s own command'


# ---- rule / guard attribution -------------------------------------------------

def deny_rules():
    try:
        return json.load(open(SETTINGS)).get('permissions', {}).get('deny', [])
    except Exception:
        return []


def deny_hit(cmd, rules):
    for seg in segments(cmd):
        s = ' '.join(seg)
        for r in rules:
            m = re.match(r'^Bash\((.*)\)$', r)
            if not m:
                continue
            pat = m.group(1)
            pat = pat[:-2] if pat.endswith(':*') else pat
            rx = '^' + r'\s+'.join(r'\S+(?:\s+\S+)*?' if p == '*' else re.escape(p) for p in pat.split()) + r'(\s|$)'
            if re.match(rx, s):
                return r
    return None


def rm_target(cmd):
    """Where an `rm -rf` that hit the deny rule pointed: the session's job tmp, /tmp, a relative path, or elsewhere."""
    kinds = set()
    for seg in segments(cmd):
        if seg[0] != 'rm' or not any(re.match(r'^-[a-zA-Z]*r[a-zA-Z]*f|^-[a-zA-Z]*f[a-zA-Z]*r', a) for a in seg[1:]):
            continue
        for a in (x for x in seg[1:] if not x.startswith('-')):
            if '/.claude/jobs/' in a or re.match(r'^"?\$\{?(CLAUDE_JOB_DIR|T|J|D|S|W|WT|TMP)\b', a):
                kinds.add('job tmp')
            elif a.startswith(('/tmp/', '/private/tmp/')):
                kinds.add('/tmp')
            elif not a.startswith(('/', '~', '$')):
                kinds.add('relative path')
            else:
                kinds.add('other')
    return ' + '.join(sorted(kinds)) or 'unparsed'


def guard_messages():
    """Literal fragment of each emit_deny message -> guard script, read from the installed hooks."""
    out = []
    for f in glob.glob(os.path.join(HOOKS, '*.sh')):
        # Literal runs of 12+ chars inside any "Blocked: ..." string, before or after an interpolated $VAR.
        for m in re.finditer(r'"Blocked: ([^"]+)"', open(f, errors='replace').read()):
            for frag in re.split(r'\$\{?\w+\}?', m.group(1)):
                if len(frag.strip()) >= 12:
                    out.append((frag.strip()[:36], os.path.basename(f)[:-3]))
    return out


def guard_for(text, msgs):
    for frag, g in msgs:
        if frag in text:
            return g
    return 'unattributed hook'


def week(d):
    return (d - dt.timedelta(days=d.weekday())).strftime('%Y-%m-%d')


def pct(xs, q):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(q * len(xs)))]) if xs else None


# ---- collection ---------------------------------------------------------------

def collect(cut):
    uses, results, asks, hblocks, kind = {}, {}, collections.defaultdict(list), collections.defaultdict(list), {}
    files = [p for p in glob.glob(os.path.join(PROJECTS, '**', '*.jsonl'), recursive=True)
             if os.path.getmtime(p) >= cut.timestamp()]
    for p in files:
        for line in open(p, errors='replace'):
            if '"tool_use' not in line and 'toolUseID' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = ts(d.get('timestamp', ''))
            if not t or t < cut:
                continue
            sid = d.get('sessionId')
            if d.get('sessionKind'):
                kind[sid] = d['sessionKind']
            msg = d.get('message') or {}
            if d.get('type') == 'assistant' and isinstance(msg.get('content'), list):
                for c in msg['content']:
                    if c.get('type') == 'tool_use' and c['id'] not in uses:
                        uses[c['id']] = dict(tool=c.get('name'), input=c.get('input') or {}, t=t, sid=sid)
            elif d.get('type') == 'user' and isinstance(msg.get('content'), list):
                for c in msg['content']:
                    if c.get('type') == 'tool_result' and c['tool_use_id'] not in results:
                        results[c['tool_use_id']] = dict(t=t, err=bool(c.get('is_error')), text=text_of(c.get('content')),
                                                         kind=d.get('toolDenialKind'))
            elif d.get('type') == 'attachment':
                at = d.get('attachment') or {}
                if at.get('hookEvent') != 'PreToolUse' or not at.get('toolUseID'):
                    continue
                if at.get('type') == 'hook_success':
                    try:
                        hs = json.loads(at.get('stdout') or '{}').get('hookSpecificOutput') or {}
                    except Exception:
                        continue
                    if hs.get('permissionDecision') in ('ask', 'deny'):
                        asks[at['toolUseID']].append((hs['permissionDecision'], os.path.basename(str(at.get('command')))[:-3],
                                                      hs.get('permissionDecisionReason', '')))
                elif at.get('type') == 'hook_blocking_error':
                    be = at.get('blockingError') or {}
                    hblocks[at['toolUseID']].append(os.path.basename(str(be.get('command'))).replace('.sh', ''))
    return files, uses, results, asks, hblocks, kind


def classify(uses, results, asks, hblocks, kind, rules, msgs):
    events, baseline = [], collections.defaultdict(list)
    for uid, u in uses.items():
        r = results.get(uid)
        inp = u['input']
        if u['tool'] == 'Bash':
            cmd = inp.get('command') or ''
        elif u['tool'].startswith('mcp__'):
            cmd = u['tool'] + ' ' + json.dumps({k: v for k, v in inp.items() if isinstance(v, (str, int)) and len(str(v)) < 60})
        else:
            cmd = inp.get('file_path') or inp.get('url') or inp.get('description') or ''
        ev = dict(id=uid, tool=u['tool'], input=inp, t=u['t'], sid=u['sid'], kind=kind.get(u['sid'], '?'), cmd=cmd,
                  shape=shape(cmd) if u['tool'] == 'Bash' else u['tool'])
        a_ = [x for x in asks.get(uid, []) if x[0] == 'ask']
        dny = [x for x in asks.get(uid, []) if x[0] == 'deny']
        rk, rt = (r or {}).get('kind'), (r or {}).get('text', '')
        hooky = r and r['err'] and re.search(r'(hook error: |^|\n)Blocked: |PreToolUse:\w+ hook error', rt)
        if a_:
            ev.update(cat='guard_ask', guard='+'.join(sorted({x[1] for x in a_})), reason=a_[0][2])
            ev['outcome'] = ('no_result' if not r else 'rejected' if rk in ('user-rejected', 'cancelled')
                             else 'blocked_after_ask' if rk or hooky else 'approved')
            if r:
                ev['wait_s'] = (r['t'] - u['t']).total_seconds()
            if 'interpreter-guard' in ev['guard'] and ev['reason'].startswith('Long inline'):
                ev['interp_kind'] = interp_kind(cmd)
        elif dny or hblocks.get(uid) or hooky:
            g = dny[0][1] if dny else hblocks[uid][0] if hblocks.get(uid) else guard_for(rt, msgs)
            ev.update(cat='hook_block', guard=g, reason=re.sub(r'^.*?Blocked: ', '', dny[0][2] if dny else rt, flags=re.S))
        elif rk == 'permission-rule':
            ev.update(cat='deny_rule', guard=deny_hit(cmd, rules) or 'no Bash deny rule matched', reason=rt)
            if ev['guard'] == 'Bash(rm -rf:*)':
                ev['rm_target'] = rm_target(cmd)
        elif rk == 'automode-blocked':
            m = re.search(r'Reason: \[([^\]]+)\]', rt)
            ev.update(cat='classifier_block', guard=m.group(1) if m else '(unlabelled)', reason=rt)
        elif rk == 'automode-unavailable':
            ev.update(cat='classifier_unavailable', guard='no verdict', reason=rt)
        elif rk in ('user-rejected', 'cancelled'):
            ev.update(cat='prompt_rejected', guard=rk, reason=rt)
        elif r and r['err'] and 'is isolated in the worktree' in rt:
            ev.update(cat='builtin_block', guard='worktree isolation', reason=rt)
        elif r and r['err'] and rt.startswith('<tool_use_error>Blocked'):
            ev.update(cat='builtin_block', guard='sleep-then-command' if 'sleep' in rt[:40] else 'builtin', reason=rt)
        else:
            if u['tool'] == 'Bash' and r:
                baseline[ev['kind']].append((r['t'] - u['t']).total_seconds())
            continue
        rs = re.sub(r'^.*?Blocked:\s*', '', ev['reason'], flags=re.S)
        rs = re.sub(r'\d+', 'N', rs)
        ev['reason_key'] = mask(re.split(r'(?<=[a-z\])])[.:;]\s', rs)[0], 110)
        events.append(ev)
    return events, baseline


def streaks_of(uses, events):
    by_sess = collections.defaultdict(list)
    for uid, u in uses.items():
        by_sess[u['sid']].append((u['t'], uid))
    ev = {e['id']: e for e in events}
    out = []
    for sid, us in by_sess.items():
        cur = []
        for _, uid in sorted(us):
            e = ev.get(uid)
            if e and not (e['cat'] == 'guard_ask' and e['outcome'] == 'approved'):
                cur.append(e)
            else:
                if len(cur) >= 3:
                    out.append(cur)
                cur = []
        if len(cur) >= 3:
            out.append(cur)
    return out


def audit_counts(cut):
    """GUARD decisions from the audit log. A burst of 10+ for one guard and target in one
    minute is a test suite run against the live log, counted apart."""
    rows = []
    for f in AUDIT:
        if not os.path.exists(f):
            continue
        for line in open(f, errors='replace'):
            parts = line.split(' | ')
            if len(parts) > 4 and parts[1] == 'GUARD':
                t = ts(parts[0])
                if t and t >= cut:
                    rows.append((t, parts[2], parts[3], parts[4]))
    burst = collections.Counter((t.strftime('%Y-%m-%dT%H:%M'), g, tgt) for t, _, g, tgt in rows)
    c, tests = collections.Counter(), collections.Counter()
    for t, dec, g, tgt in rows:
        (tests if burst[(t.strftime('%Y-%m-%dT%H:%M'), g, tgt)] >= 10 else c)[(dec, g)] += 1
    return c, tests, min((r[0] for r in rows), default=None)


# ---- summary ------------------------------------------------------------------

def summarize(events, uses, baseline, streaks, audit, audit_tests, audit_first, cut, now, rules, nfiles):
    C = collections.Counter
    tools = C(u['tool'] for u in uses.values())
    cats = C(e['cat'] for e in events)
    weekly = collections.defaultdict(C)
    for e in events:
        weekly[week(e['t'])][e['cat'] + ('_' + e['outcome'] if e['cat'] == 'guard_ask' else '')] += 1
    bash_weeks = C(week(u['t']) for u in uses.values() if u['tool'] == 'Bash')

    def group(evs, key='guard', n=20, samples=3):
        out = []
        for g, cnt in C(e[key] for e in evs).most_common(n):
            ge = [e for e in evs if e[key] == g]
            row = dict(key=g, count=cnt, sessions=len({e['sid'] for e in ge}),
                       reasons=C(e['reason_key'] for e in ge).most_common(5),
                       shapes=C(e['shape'] for e in ge).most_common(8),
                       samples=[mask(e['cmd'], 220) for e in ge[:: max(1, len(ge) // samples)][:samples]])
            if any(e['cat'] == 'guard_ask' for e in ge):
                row['outcomes'] = dict(C(e['outcome'] for e in ge))
                w = [e['wait_s'] for e in ge if e.get('outcome') == 'approved' and 'wait_s' in e]
                row['wait_p50_s'], row['wait_p90_s'], row['wait_total_h'] = pct(w, .5), pct(w, .9), round(sum(w) / 3600, 1)
            out.append(row)
        return out

    asks = [e for e in events if e['cat'] == 'guard_ask']
    ask_reasons = []
    for (g, rk), cnt in C((e['guard'], e['reason_key']) for e in asks).most_common(25):
        ge = [e for e in asks if e['guard'] == g and e['reason_key'] == rk]
        ask_reasons.append(dict(guard=g, reason=rk, count=cnt, sessions=len({e['sid'] for e in ge}),
                                outcomes=dict(C(e['outcome'] for e in ge)),
                                shapes=C(e['shape'] for e in ge).most_common(8),
                                samples=[mask(e['cmd'], 220) for e in ge[:: max(1, len(ge) // 3)][:3]]))
    hosts = collections.defaultdict(C)
    for e in asks:
        if 'network-guard' not in e['guard']:
            continue
        m = re.search(r'\bto (\S+?)(?: is outside|\.\s|\.?$| on this machine)', e['reason'])
        h = m.group(1).rstrip('.;,)"\'') if m else ('(no scheme in URL)' if 'no http' in e['reason'] else '(no host in reason)')
        sends = bool(re.search(r'sending data|mutating request', e['reason']))
        hosts[h]['data' if sends else 'get'] += 1
        hosts[h][e['outcome']] += 1
    net_hosts = sorted(({'host': mask(h, 80), 'asks': c['get'] + c['data'], 'get': c['get'], 'data': c['data'],
                         'approved': c['approved'], 'loopback': bool(re.match(r'^(localhost|127\.|::1|0\.0\.0\.0)', h))}
                        for h, c in hosts.items()), key=lambda r: -r['asks'])
    il = [e for e in asks if 'interp_kind' in e]
    interp = []
    for k, cnt in C(e['interp_kind'] for e in il).most_common():
        ge = [e for e in il if e['interp_kind'] == k]
        interp.append(dict(kind=k, count=cnt, approved=sum(e['outcome'] == 'approved' for e in ge),
                           len_p50=pct([len(e['cmd']) for e in ge], .5), shapes=C(e['shape'] for e in ge).most_common(8),
                           samples=[mask(e['cmd'], 220) for e in ge[:: max(1, len(ge) // 4)][:4]]))
    waits = {}
    for k in sorted({e['kind'] for e in asks}):
        w = [e['wait_s'] for e in asks if e['kind'] == k and e['outcome'] == 'approved' and 'wait_s' in e]
        b = baseline.get(k, [])
        waits[k] = dict(asks=len(w), ask_p50=pct(w, .5), ask_p90=pct(w, .9), ask_total_h=round(sum(w) / 3600, 1),
                        no_prompt_bash_p50=pct(b, .5), no_prompt_bash_p90=pct(b, .9), no_prompt_bash_n=len(b))
    overlap = C()
    for e in asks:
        if audit_first and e['t'] >= audit_first:
            overlap[e['guard']] += 1
    audit_ask = C({g: n for (dec, g), n in audit.items() if dec == 'ask'})
    audit_deny = C({g: n for (dec, g), n in audit.items() if dec == 'deny'})
    hb_overlap = C(e['guard'] for e in events if e['cat'] == 'hook_block' and audit_first and e['t'] >= audit_first)
    by = lambda c: [e for e in events if e['cat'] == c]
    return dict(
        window=dict(start=cut.isoformat(timespec='minutes'), end=now.isoformat(timespec='minutes'), transcript_files=nfiles),
        totals=dict(tool_calls=sum(tools.values()), bash_calls=tools.get('Bash', 0), tools=tools.most_common(12),
                    sessions=len({u['sid'] for u in uses.values()}), friction_events=len(events), by_category=cats.most_common(),
                    session_kinds=C(e['kind'] for e in events).most_common()),
        weekly=[dict(week=w, bash_calls=bash_weeks.get(w, 0), **weekly[w]) for w in sorted(set(weekly) | set(bash_weeks))],
        guard_asks=group(asks), ask_reasons=ask_reasons, interpreter_long_script=interp, waits=waits, network_hosts=net_hosts,
        hook_blocks=group(by('hook_block')), deny_rules=group(by('deny_rule')),
        rm_rf_targets=C(e['rm_target'] for e in events if 'rm_target' in e).most_common(),
        classifier_blocks=group(by('classifier_block'), samples=4), classifier_unavailable=cats.get('classifier_unavailable', 0),
        builtin=group(by('builtin_block')), prompt_rejected=group(by('prompt_rejected')),
        streaks=dict(count=len(streaks), longest=max((len(s) for s in streaks), default=0),
                     top=[dict(len=len(s), start=s[0]['t'].isoformat(timespec='minutes'),
                               cats=C(f"{e['cat']}:{e['guard']}" for e in s).most_common(3))
                          for s in sorted(streaks, key=len, reverse=True)[:8]]),
        audit_crosscheck=dict(audit_first=str(audit_first), ask=[(g, n, overlap.get(g, 0)) for g, n in audit_ask.most_common()],
                              deny=[(g, n, hb_overlap.get(g, 0)) for g, n in audit_deny.most_common()],
                              test_bursts=[(f"{g} {dec}", n) for (dec, g), n in audit_tests.most_common()]),
        deny_rules_configured=rules,
    )


# ---- render -------------------------------------------------------------------

def render(d):
    L = []
    w, t = d['window'], d['totals']
    L.append('# Claude Code permission friction\n')
    L.append(f"Window {w['start']} to {w['end']} (UTC). Source: {w['transcript_files']} transcript files under "
             "`~/.claude/projects` (main sessions and subagents), cross-checked against `~/.claude/logs/audit.log*`. "
             "Produced by `bin/permission-friction.py` in claude-code-harness.\n")
    L.append(f"{t['tool_calls']} tool calls ({t['bash_calls']} Bash) across {t['sessions']} sessions. "
             f"{t['friction_events']} calls met a permission decision other than a silent allow.\n")
    meaning = dict(guard_ask='harness guard returned `ask`: a human prompt',
                   hook_block='harness guard denied (model must rework the command)',
                   deny_rule='`permissions.deny` rule matched: hard deny, no prompt',
                   classifier_block='auto-mode classifier blocked',
                   classifier_unavailable='classifier gave no verdict (transient)',
                   builtin_block='Claude Code built-in refusal (sleep-then-command, worktree isolation)',
                   prompt_rejected='human rejected a prompt Claude Code raised itself')
    L.append('| category | calls | meaning |\n|---|---:|---|')
    for c, n in t['by_category']:
        L.append(f'| {c} | {n} | {meaning.get(c, "")} |')
    L.append('\n## Weekly\n')
    cols = ['bash_calls', 'guard_ask_approved', 'guard_ask_rejected', 'hook_block', 'deny_rule', 'classifier_block',
            'classifier_unavailable', 'builtin_block']
    L.append('| week of | ' + ' | '.join(cols) + ' |\n|---|' + '---:|' * len(cols))
    for r in d['weekly']:
        L.append(f"| {r['week']} | " + ' | '.join(str(r.get(c, 0)) for c in cols) + ' |')

    L.append('\n## 1. Guard asks (the prompts you answered)\n')
    L.append('| guard | asks | outcomes | sessions | approved wait p50 / p90 (s) | approved wait total (h) |\n|---|---:|---|---:|---|---:|')
    for g in d['guard_asks']:
        L.append(f"| {g['key']} | {g['count']} | {g['outcomes']} | {g['sessions']} | {g['wait_p50_s']} / {g['wait_p90_s']} | {g['wait_total_h']} |")
    L.append('\nWait is tool_use to tool_result, so it includes run time. For scale, Bash calls that met no permission decision:\n')
    L.append('| session kind | approved asks | ask wait p50 / p90 (s) | ask wait total (h) | no-prompt Bash p50 / p90 (s) |\n|---|---:|---|---:|---|')
    for k, v in d['waits'].items():
        L.append(f"| {k} | {v['asks']} | {v['ask_p50']} / {v['ask_p90']} | {v['ask_total_h']} | {v['no_prompt_bash_p50']} / {v['no_prompt_bash_p90']} (n={v['no_prompt_bash_n']}) |")

    L.append('\n### 1a. interpreter-guard "Long inline script": what actually tripped it\n')
    L.append('The ask fires on `hooks/interpreter-guard.sh` line ~178: an interpreter word followed by 120+ characters and then any '
             'inline-style flag (`-c`, `-e`, ` - `, ...), or an inline flag followed by 200+ characters. The span can cross `&&`, `;`, `|`.\n')
    L.append('| how it tripped | asks | approved | median command length |\n|---|---:|---:|---:|')
    for r in d['interpreter_long_script']:
        L.append(f"| {r['kind']} | {r['count']} | {r['approved']} | {r['len_p50']} |")
    for r in d['interpreter_long_script']:
        L.append(f"\n**{r['kind']}**: families " + ', '.join(f'`{s}` {n}' for s, n in r['shapes']))
        for s in r['samples']:
            L.append(f'- `{s}`')

    L.append('\n### 1b. network-guard asks by host (candidates for this machine\'s `CLAUDE_NET_ALLOWLIST`)\n')
    L.append('The allowlist only silences GETs; a request that sends data still asks.\n')
    L.append('| host | asks | GET | sends data | approved | loopback |\n|---|---:|---:|---:|---:|---|')
    for r in d['network_hosts']:
        L.append(f"| {r['host']} | {r['asks']} | {r['get']} | {r['data']} | {r['approved']} | {'yes' if r['loopback'] else ''} |")

    L.append('\n### 1c. Every guard ask reason\n')
    for r in d['ask_reasons']:
        L.append(f"- **{r['guard']}**: {r['reason']} | {r['count']} asks, {r['sessions']} sessions, {r['outcomes']}")
        L.append('  - families: ' + ', '.join(f'`{s}` {n}' for s, n in r['shapes']))
        for s in r['samples']:
            L.append(f'  - `{s}`')

    sections = (('2. Guard blocks (hook denied, no prompt)', 'hook_blocks'),
                ('3. Deny-rule hits (`permissions.deny`)', 'deny_rules'),
                ('4. Auto-mode classifier blocks', 'classifier_blocks'),
                ('5. Claude Code built-in refusals', 'builtin'),
                ('6. Rejected prompts raised by Claude Code itself', 'prompt_rejected'))
    for title, key in sections:
        L.append(f'\n## {title}\n')
        if key == 'classifier_blocks':
            L.append(f"Plus {d['classifier_unavailable']} calls where the classifier gave no verdict.\n")
        if key == 'deny_rules':
            L.append('`rm -rf` targets of the `Bash(rm -rf:*)` hits: ' + ', '.join(f'{k} {n}' for k, n in d['rm_rf_targets']) + '\n')
        for g in d[key]:
            L.append(f"- **{g['key']}**: {g['count']} calls, {g['sessions']} sessions")
            for rk, n in g['reasons'][:4]:
                L.append(f'  - reason ({n}): {rk}')
            L.append('  - families: ' + ', '.join(f'`{s}` {n}' for s, n in g['shapes'][:6]))
            for s in g['samples']:
                L.append(f'  - `{s}`')

    s = d['streaks']
    L.append(f"\n## 7. Block streaks\n\n{s['count']} runs of 3+ consecutive unapproved friction events in one session (longest {s['longest']}).\n")
    for x in s['top']:
        L.append(f"- {x['len']} in a row from {x['start']}: " + ', '.join(f'{k} x{n}' for k, n in x['cats']))
    a = d['audit_crosscheck']
    L.append(f"\n## 8. Cross-check against the harness audit log\n\nGUARD lines in the audit log begin {a['audit_first']}; counts from then on.\n")
    L.append('| guard | decision | audit.log | transcripts |\n|---|---|---:|---:|')
    for g, n, m in a['ask']:
        L.append(f'| {g} | ask | {n} | {m} |')
    for g, n, m in a['deny']:
        L.append(f'| {g} | deny | {n} | {m} |')
    if a['test_bursts']:
        L.append('\nExcluded as test-suite bursts (10+ identical guard decisions in one minute): '
                 + ', '.join(f'{k} {n}' for k, n in a['test_bursts']))
    L.append('\n## Configured deny rules\n\n' + ', '.join(f'`{r}`' for r in d['deny_rules_configured']))
    L.append('\n## Blind spots\n\n'
             '- An approved prompt raised by Claude Code itself (not a hook) leaves no transcript record; only rejections show.\n'
             '- Wait includes the command\'s own run time; compare with the no-prompt baseline.\n'
             '- Transcript asks can exceed audit asks where a subagent transcript repeats a parent call, and fall short where a session file was deleted.\n'
             '- Commands, hosts and command families are masked (tokens, secret values, URL credentials, emails, long blobs, plus ~/.claude/permission-friction.masks) and truncated; masking is pattern-based.\n')
    return '\n'.join(L) + '\n'


def decide(hook, tool, inp, extra_env=None):
    """Run one PreToolUse guard on a recorded call: its decision, or allow when it is silent."""
    payload = json.dumps(dict(tool_name=tool, tool_input=inp, hook_event_name='PreToolUse', cwd=HOME, permission_mode='auto'))
    # Out of the real audit log, and blind to this machine's allowlists unless a case sets one.
    env = {**os.environ, 'CLAUDE_AUDIT_LOG': os.devnull, 'CLAUDE_NET_ALLOWLIST': '',
           'CLAUDE_LOCAL_SETTINGS_DIR': os.devnull, **(extra_env or {})}
    try:
        p = subprocess.run(['bash', hook], input=payload, capture_output=True, text=True, env=env, timeout=30)
    except subprocess.TimeoutExpired:
        return 'timeout'
    if p.returncode == 2:
        return 'deny'
    if p.returncode != 0:
        return 'error'
    try:
        return (json.loads(p.stdout or '{}').get('hookSpecificOutput') or {}).get('permissionDecision') or 'allow'
    except (ValueError, AttributeError):
        return 'error'


def replay(events, hooks_dir):
    """Re-run every recorded guard ask and guard block through the guards in hooks_dir."""
    rank = dict(error=4, deny=3, ask=2, timeout=1, allow=0)
    rows = collections.defaultdict(collections.Counter)
    for e in events:
        if e['cat'] not in ('guard_ask', 'hook_block') or e['guard'] == 'unattributed hook':
            continue
        now = [decide(os.path.join(hooks_dir, g + '.sh'), e['tool'], e['input'])
               for g in e['guard'].split('+') if os.path.exists(os.path.join(hooks_dir, g + '.sh'))]
        if not now:
            continue
        rk = re.sub(r"'[^']*'?", "'…'", e['reason_key'])
        rk = re.sub(r'\b(to|from) \S+ is outside', r'\1 <host> is outside', rk)
        rk = re.sub(r'(request body\) to|request \(POST/PUT/PATCH/DELETE\) to) .*', r'\1 <host>', rk)
        rk = re.sub(r'^kubectl (get|describe) \S+ puts', r'kubectl \1 <kinds> puts', rk)
        key = f"{e['cat']} | {e['guard']} | {e.get('interp_kind') or rk[:80]}"
        rows[key][max(now, key=rank.get)] += 1
    return [dict(key=k, total=sum(c.values()), **c) for k, c in sorted(rows.items(), key=lambda kv: -sum(kv[1].values()))]


def run_cases(path, hooks_dir):
    """One line per case: id, decision now, the decision it should have, and a mark where they differ.
    Exit 1 when any case with a `want` disagrees, so a fix can be checked in one command."""
    bad = 0
    for line in open(path):
        if not line.strip():
            continue
        c = json.loads(line)
        got = decide(os.path.join(hooks_dir, c['guard'] + '.sh'), c['tool'], c['input'], c.get('env'))
        want = c.get('want')
        miss = want and got != want
        bad += bool(miss)
        print(f"{'MISS' if miss else 'ok  '}  {c['id']:40} now={got:6} want={want or '(policy: decide)'}")
    print(f"{bad} case(s) differ from want")
    return 1 if bad else 0


def render_replay(rows, hooks_dir):
    L = [f'\n## 9. Replay: the same calls through `{hooks_dir}`\n',
         "Each recorded guard ask or block, re-run through that directory's guard script(s) with the recorded tool input "
         '(cwd = $HOME, so guards that inspect repo state answer approximately).\n',
         '| was | total | now allow | now ask | now deny | guard error |\n|---|---:|---:|---:|---:|---:|']
    for r in rows:
        L.append(f"| {r['key']} | {r['total']} | {r.get('allow', 0)} | {r.get('ask', 0)} | {r.get('deny', 0)} | {r.get('error', 0)} |")
    return '\n'.join(L) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=49)
    ap.add_argument('--out', help='directory for report.md and friction.json (default: report to stdout)')
    ap.add_argument('--replay', metavar='HOOKS_DIR', help="re-run recorded asks/blocks through the guards in HOOKS_DIR (e.g. a branch's hooks/)")
    ap.add_argument('--cases', metavar='JSONL', nargs='?',
                    const=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'docs', 'permission-friction-cases.jsonl'),
                    help='with --replay: run these cases (default: the shipped cases file) instead of transcripts')
    a = ap.parse_args()
    if a.cases:
        if not a.replay:
            ap.error('--cases needs --replay HOOKS_DIR')
        return run_cases(a.cases, os.path.abspath(a.replay))
    now = dt.datetime.now(dt.timezone.utc)
    cut = now - dt.timedelta(days=a.days)
    rules = deny_rules()
    files, uses, results, asks, hblocks, kind = collect(cut)
    events, baseline = classify(uses, results, asks, hblocks, kind, rules, guard_messages())
    audit, audit_tests, audit_first = audit_counts(cut)
    data = summarize(events, uses, baseline, streaks_of(uses, events), audit, audit_tests, audit_first, cut, now, rules, len(files))
    md = render(data)
    if a.replay:
        data['replay'] = replay(events, os.path.abspath(a.replay))
        md += render_replay(data['replay'], a.replay)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        json.dump(data, open(os.path.join(a.out, 'friction.json'), 'w'), indent=1, default=str)
        open(os.path.join(a.out, 'report.md'), 'w').write(md)
        print(f'wrote {a.out}/report.md and friction.json ({len(events)} friction events)')
    else:
        sys.stdout.write(md)


if __name__ == '__main__':
    sys.exit(main())
