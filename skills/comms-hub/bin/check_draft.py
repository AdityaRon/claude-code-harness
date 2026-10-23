#!/usr/bin/env python3
"""The Slack send gate. Run it on the exact file you will send, then send in the
same turn.

  check_draft.py FILE (--reply TS | --top-level) [--asks LOGIN...] [--answers TS...]
                                                   shape, live PR state, send mode; records a pass
  check_draft.py FILE --assert-fresh [--max-age S]  the bytes are the ones that passed, recently
  check_draft.py FILE --record-sent ID [--replies BEFORE AFTER]
                                                   after sending: keep a copy, log it, retire the pass
  check_draft.py --scheduled                       scheduled messages not yet posted, with the copy to re-gate

A reply that answers several messages threads under the newest of them: name
them all with --answers, and --reply must be the newest (six of seven answers
once landed in the wrong thread). After a reply is sent, --record-sent needs
the parent's reply count re-read before and after, and refuses one that did
not move: the send tool says OK either way.

Live state: a line that links a merged or closed PR and calls it awaiting,
pending or open fails. A line that asks for a review fails when the addressee,
named with --asks (their GitHub login), has a standing approval at the PR's
current head: a review ask once went out minutes after the approval. It is the
addressee's own review that counts, not the PR's decision: another reviewer's
approval failed an ask once. An ask with no --asks fails, so it cannot slip by.
Exit 0 pass, 1 the draft fails a rule, 2 usage or config, 3 live state unknown.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

PR_URL = re.compile(r"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
SLACK_LINK = re.compile(r"<(https?://[^|>\s]+)(?:\|[^>]*)?>")
MD_LINK = re.compile(r"\[[^\]]*\]\((https?://[^)\s]+)\)")
BARE_URL = re.compile(r"https?://[^\s,;)\]>]+")
PR_REF = re.compile(r"(?<![\w/#&])(?:[\w.-]+/[\w.-]+#\d+|#\d+\b|\bPR[\s-]*#?\d+\b|\bpull request\s+#?\d+\b)", re.I)
CODE = re.compile(r"```.*?```|`[^`\n]*`", re.S)
TS = re.compile(r"\d{10}\.\d{6}")
TOKEN = re.compile(r"\b(?:xox[abposr]-[\w-]{10,}|gh[pousr]_\w{30,}|github_pat_\w{30,}|AKIA[0-9A-Z]{16}|sk-[\w-]{30,})")
MAX_AGE = 300
EM_DASH = chr(0x2014)
AWAITING = re.compile(r"\b(?:awaiting|waiting (?:on|for)|pending (?:review|approval|merge)|still open|unmerged|"
                      r"not (?:yet )?merged|needs? (?:a )?review|(?:ready|open|up) for review)\b", re.I)
ASK = re.compile(r"\b(?:ptal|please (?:review|take a look|have a look)|(?:could|can|would) you (?:please )?"
                 r"(?:review|take a look|have a look|look at)|mind (?:reviewing|taking a look)|"
                 r"(?:a |your )?review (?:please|when you (?:can|get a chance|have a minute))|"
                 r"review request|requesting (?:a |your )?review|ready for (?:your |a )?review)\b", re.I)


def ts_key(ts: str) -> tuple[int, int]:
    sec, _, frac = ts.partition(".")
    return int(sec), int(frac or 0)


def shape_problems(text: str) -> list[str]:
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if EM_DASH in line:
            out.append(f"line {n}: em dash")
        if line.lstrip().startswith(">"):
            out.append(f"line {n}: starts with '>' (Slack renders a quote)")
    for m in CODE.finditer(text):
        if ">" in m.group(0):
            out.append(f"line {text.count(chr(10), 0, m.start()) + 1}: '>' inside a code span")
    # Links first, so a reference inside link text or a URL is not flagged.
    rest = BARE_URL.sub(" ", MD_LINK.sub(" ", SLACK_LINK.sub(" ", text)))
    for m in PR_REF.finditer(rest):
        out.append(f"PR reference {m.group(0)!r} is not a link")
    if TOKEN.search(text):
        out.append("a token-shaped string: no secrets in a message")
    return out


def linked_prs(text: str) -> list[tuple[str, str, int]]:
    seen = []
    for m in PR_URL.finditer(text):
        k = (m.group(1), m.group(2), int(m.group(3)))
        if k not in seen:
            seen.append(k)
    return seen


def live_state(gh: hub.Gh, prs) -> tuple[list[str], bool, dict[tuple, dict]]:
    lines, ok, live = [], True, {}
    for owner, repo, n in prs:
        ref = f"{owner}/{repo}#{n}"
        try:
            d = gh.json(["pr", "view", str(n), "--repo", f"{owner}/{repo}", "--json",
                         "state,isDraft,headRefOid,mergeStateStatus,reviewDecision,reviews"])
        except hub.GhError as e:
            lines.append(f"{ref} UNKNOWN ({e})")
            ok = False
            continue
        head = d.get("headRefOid") or "?"
        d["standing"] = {k.lower(): v for k, v in hub.standing_reviews(d.get("reviews") or []).items()}
        approved = [f"{k}@{((r.get('commit') or {}).get('oid') or '?')[:7]}"
                    for k, r in sorted(d["standing"].items()) if r.get("state") == "APPROVED"]
        live[(owner, repo, n)] = d
        lines.append(f"{ref} state={d.get('state')} draft={'yes' if d.get('isDraft') else 'no'} "
                     f"head={head[:7]} merge={d.get('mergeStateStatus')} "
                     f"review={d.get('reviewDecision') or 'NONE'} approved-by={','.join(approved) or '-'}")
    return lines, ok, live


def claim_problems(text: str, live: dict[tuple, dict], asks: list[str]) -> list[str]:
    """Lines whose words no longer match the linked PR's live state."""
    out = []
    every = linked_prs(text)
    for n, line in enumerate(text.splitlines(), 1):
        here = linked_prs(line)
        for pr in here:
            d = live.get(pr)
            if not d:
                continue
            m = AWAITING.search(line)
            if d.get("state") in ("MERGED", "CLOSED") and m:
                out.append(f"line {n}: calls {d['state'].lower()} {pr[0]}/{pr[1]}#{pr[2]} {m.group(0)!r}")
        if not ASK.search(line):
            continue
        for pr in here or every:
            ref = f"{pr[0]}/{pr[1]}#{pr[2]}"
            d = live.get(pr)
            if not d:
                continue
            if not asks:
                out.append(f"line {n}: asks for a review of {ref}; name the addressee with --asks LOGIN "
                           "so their own review can be checked")
                continue
            for login in asks:
                r = d["standing"].get(login.lower())
                if not r:
                    continue
                oid = (r.get("commit") or {}).get("oid")
                if r["state"] == "APPROVED" and oid in (None, d.get("headRefOid")):
                    out.append(f"line {n}: asks {login} to review {ref}, which they approved "
                               f"{r.get('submittedAt')} at the current head")
    return out


def stamp_path(cfg, path: str):
    d = hub.state_dir(cfg) / "gate"
    d.mkdir(exist_ok=True)
    return d / (hub.sha256(os.path.realpath(path).encode())[:16] + ".json")


def gate(args, cfg, gh) -> int:
    data = open(args.file, "rb").read()
    text = data.decode("utf-8")
    for ts in [args.reply] * bool(args.reply) + args.answers:
        if not TS.fullmatch(ts):
            print(f"FAIL: {ts!r} is not a Slack ts (1234567890.123456)")
            return 2
    target = f"reply:{args.reply}" if args.reply else "top-level"
    problems = shape_problems(text)
    if args.answers and args.reply != max(args.answers, key=ts_key):
        problems.append(f"--reply {args.reply} is not the newest message the draft answers "
                        f"({max(args.answers, key=ts_key)}): a combined reply threads under the newest")
    lines, known, live = live_state(gh, linked_prs(text))
    problems += claim_problems(text, live, args.asks)
    print(f"target: {target}")
    for line in lines:
        print(f"pr: {line}")
    mode, post = hub.send_plan(cfg, hub.now())
    if mode == "live":
        print("send: live")
    else:
        print(f"send: schedule post_at={post.isoformat()} epoch={int(post.timestamp())} "
              "(scheduled messages cannot be edited through the API: hold it instead if a fold-in is expected)")
    for p in problems:
        print(f"FAIL: {p}")
    if problems:
        return 1
    if not known:
        print("BLOCKED: a linked PR's live state is unknown; the claims cannot be checked")
        return 3
    stamp = {"path": os.path.realpath(args.file), "sha256": hub.sha256(data),
             "passed_at": hub.now().timestamp(), "target": target, "send": mode,
             "post_at": post.isoformat() if post else None, "prs": lines, "asks": args.asks}
    stamp_path(cfg, args.file).write_text(json.dumps(stamp, indent=1))
    print(f"PASS sha256={stamp['sha256'][:12]}: send this file in the same turn, after --assert-fresh")
    return 0


def read_stamp(cfg, path):
    p = stamp_path(cfg, path)
    if not p.is_file():
        return None, p
    return json.loads(p.read_text()), p


def assert_fresh(args, cfg) -> int:
    stamp, _ = read_stamp(cfg, args.file)
    if not stamp:
        print("STALE: no gate pass recorded for this file")
        return 1
    if stamp.get("sent_id"):
        print(f"STALE: this pass was already sent as {stamp['sent_id']}")
        return 1
    if hub.sha256(open(args.file, "rb").read()) != stamp["sha256"]:
        print("STALE: the file changed since the gate passed; run the gate again")
        return 1
    age = hub.now().timestamp() - stamp["passed_at"]
    if age > args.max_age or age < 0:
        print(f"STALE: the pass is {age:.0f}s old (limit {args.max_age}s); run the gate again")
        return 1
    print(f"FRESH {age:.0f}s target={stamp['target']} send={stamp['send']}"
          + (f" post_at={stamp['post_at']}" if stamp.get("post_at") else ""))
    return 0


def record_sent(args, cfg) -> int:
    stamp, p = read_stamp(cfg, args.file)
    data = open(args.file, "rb").read()
    if not stamp or stamp.get("sent_id") or hub.sha256(data) != stamp["sha256"]:
        print("FAIL: no unsent gate pass for these bytes; nothing recorded")
        return 1
    if stamp["target"].startswith("reply:") and not args.replies:
        print("FAIL: a reply is confirmed by its parent's reply count: re-read the thread and pass "
              "--replies BEFORE AFTER (the send tool says OK either way); nothing recorded")
        return 1
    if args.replies:
        before, after = args.replies
        if after <= before:
            print(f"FAIL: the parent's reply count did not move ({before} -> {after}): the reply did not land "
                  "where the send tool said; nothing recorded")
            return 1
    day = hub.local_now(cfg).strftime("%Y-%m-%d")
    d = hub.state_dir(cfg) / "sent" / day
    d.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^\w.-]", "_", args.record_sent)
    shutil.copyfile(args.file, d / f"{safe}.md")
    stamp["sent_id"] = args.record_sent
    stamp["sent_copy"] = str(d / f"{safe}.md")
    p.write_text(json.dumps(stamp, indent=1))
    verb = "scheduled" if stamp["send"] == "schedule" else "sent"
    hub.append_log(cfg, f"{verb} {args.record_sent} target={stamp['target']} sha256={stamp['sha256'][:12]}")
    print(f"recorded {verb} {args.record_sent}: sent/{day}/{safe}.md")
    return 0


def list_scheduled(cfg) -> int:
    """Scheduled messages whose post_at is still ahead: each can be gated again
    from its sent copy and withdrawn before it posts."""
    now = hub.now()
    rows = []
    for p in sorted((hub.state_dir(cfg) / "gate").glob("*.json")):
        s = json.loads(p.read_text())
        if s.get("send") != "schedule" or not s.get("sent_id"):
            continue
        if hub.parse_time(s.get("post_at")) <= now:
            continue
        rows.append(f"{s['sent_id']} post_at={s['post_at']} target={s['target']} copy={s.get('sent_copy') or '?'}"
                    + (f" asks={','.join(s['asks'])}" if s.get("asks") else ""))
    print(f"scheduled: {len(rows)} pending")
    for r in rows:
        print(r)
    return 0


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--scheduled", action="store_true")
    ap.add_argument("--reply", metavar="TS")
    ap.add_argument("--top-level", action="store_true")
    ap.add_argument("--asks", nargs="+", default=[], metavar="LOGIN",
                    help="the GitHub login(s) of whoever the draft asks for a review")
    ap.add_argument("--answers", nargs="+", default=[], metavar="TS",
                    help="the parent ts of every message a combined reply answers")
    ap.add_argument("--assert-fresh", action="store_true")
    ap.add_argument("--max-age", type=int, default=MAX_AGE)
    ap.add_argument("--record-sent", metavar="ID")
    ap.add_argument("--replies", nargs=2, type=int, metavar=("BEFORE", "AFTER"),
                    help="the parent's reply count re-read before and after the send")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        cfg = hub.load_config(args.config)
    except hub.ConfigError as e:
        print(f"config: {e}")
        return 2
    if args.scheduled:
        return list_scheduled(cfg)
    if not args.file or not os.path.isfile(args.file):
        print(f"no such file: {args.file}")
        return 2
    if args.assert_fresh:
        return assert_fresh(args, cfg)
    if args.record_sent:
        return record_sent(args, cfg)
    if bool(args.reply) == bool(args.top_level):
        print("say where it goes: exactly one of --reply TS or --top-level")
        return 2
    return gate(args, cfg, gh or hub.Gh())


if __name__ == "__main__":
    sys.exit(main())
