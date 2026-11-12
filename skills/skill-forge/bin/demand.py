#!/usr/bin/env python3
"""Find the operational questions that keep coming up, from Claude Code
transcripts and shell history, and rank them as candidates for a skill. Each
comes with its evidence (counts, example sessions by date), never the content.

  demand.py [--top N] [--since DAYS] [--transcripts DIR ...] [--history FILE ...]
            [--min-sessions 2] [--ignore PROG ...] [--skills DIR ...] [--include-undated] [--json]

Three kinds of candidate:
  sequence   the same 2 to 5 command steps, in order, in several sessions
  question   a prompt asked again, in other words, in several sessions; its steps
             are the commands run before the next prompt, at most 10, since a
             longer run is a task, not an answer. A prompt over 400 characters
             is a pasted brief, not a question, and is skipped. Prompts join one
             question when they share two content words (by stem) with any
             prompt already in it, and those are half the shorter one's words
  failing    one command that failed in several sessions
A command is cut to its shape, the program and its subcommands (`kubectl logs`),
so no argument, id, host or secret reaches the output. A subcommand counts only
once it recurs: the first in 2 sessions, the second in 3, so a pod or branch
name never becomes part of a shape. A script an interpreter runs stays in the
shape by name (`python discover.py`, `python <skill>/tool.py` under skills/),
since running a skill's engine is the clearest sign of a recurring question.
A heredoc body is data the command reads, not commands, unless it feeds a
shell; a newline inside quotes (`python -c "..."`) is part of the argument. A
prompt is cut to its content words, masked, at most 80 characters.

The window holds each command and prompt by its own timestamp, not its file's
age; the header says how many fell outside it. Shell history lines with no
timestamp cannot be placed, so they are left out and counted unless
--include-undated. A sequence whose steps are mostly re-login or session
checks (tsh, aws sso, gcloud auth, ...) is access friction: ranked apart, a
session to fix rather than a skill to write. A candidate whose steps run an
installed skill's engine says `covered by <skill>`.

score = sessions x steps x failure rate, with the failure rate smoothed to
(failures + 1) / (attempts + 2). Unsmoothed, a sequence that never failed
would score zero however often it ran; smoothed, it still ranks by how often
and how long, and one failure in two tries does not outrank ten in twenty.
Shell history records no exit codes, so its steps are attempts with no
failures, and history without timestamps is cut into windows of 50 commands.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask import EXIT_OK, Window, config_path, emit, header, masker, read_toml  # noqa: E402
from skill_lint import VENDORED  # noqa: E402

NOISE = {"cd", "echo", "printf", "sleep", "true", "false", "export", "set", "unset", "source", ".", "clear", "ls", "pwd",
         "exit", "date", "which", "command", "type", "history", "test", "[", "mkdir", "touch", "rm", "cp", "mv", "chmod", "open",
         "for", "case", "select", "function", "done", "fi", "esac", "}", "in", "read", "local", "return", "break", "continue"}
FILTERS = {"grep", "rg", "egrep", "jq", "yq", "head", "tail", "sort", "uniq", "wc", "cut", "awk", "sed", "tr", "less", "more",
           "cat", "tee", "xargs", "column", "fzf", "bat", "nl", "fold", "base64"}
# Skipped in front of a command; a shell keyword that opens a body is one too (`do kubectl get ...`).
WRAPPERS = {"sudo", "time", "env", "nohup", "exec", "builtin", "nice", "timeout",
            "do", "then", "else", "elif", "if", "while", "until", "!", "{"}
INTERPRETERS = re.compile(r"^(?:python[\d.]*|node|bash|sh|zsh|ruby|perl|deno|bun)$")
# Programs whose next words are subcommands. Anything else is cut to its name, so
# `pg_dump app` cannot turn a database name into part of a shape.
SUBCOMMANDS = set("""kubectl oc helm kustomize kind minikube istioctl linkerd argocd argo flux git gh glab docker podman
nerdctl aws gcloud gsutil bq az doctl oci terraform tofu pulumi vault op bw tsh boundary cloudflared npm pnpm yarn cargo
go make brew pip poetry uv systemctl launchctl temporal airflow dbt stripe heroku fly vercel ldcli flipt sentry-cli
datadog-ci dagster prefect aws-vault saml2aws""".split())
VALUE_FLAGS = {"-n", "--namespace", "--context", "--profile", "--region", "-o", "--output", "-f", "--file", "-l", "--selector",
               "--project", "-R", "--repo", "-C", "-p", "-u", "--user", "-d", "-h", "--host", "-U", "-H", "-X", "--since",
               "--tail", "-A", "-B", "-e", "--cluster", "--kubeconfig", "-w"}
VERB = re.compile(r"[a-z][a-z0-9-]{1,24}")
SCRIPT_RUNNERS = {"python", "node", "bash", "sh", "zsh", "ruby", "perl", "deno", "bun"}
RUN_WRAPPERS = {"uv", "poetry", "pipenv", "pdm"}       # `uv run tool.py`
INTERP_VALUE_FLAGS = {"-W", "-X", "-Q"}
SCRIPT = re.compile(r"\.(?:py|sh|js|ts|rb|pl)$")
SKILL_SCRIPT = re.compile(r"(?:^|/)skills/([\w.-]+)/(?:bin/)?([\w.-]+)$")
MODULE = re.compile(r"[A-Za-z_][\w.]{0,40}")
# Ported from hooks/config-guard.sh's drop_data_heredocs, not imported: this skill installs alone.
HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\2")
FEEDS_A_SHELL = re.compile(r"(?:^|[;&|(])[ \t]*(?:bash|sh|zsh|dash|ksh)(?:[ \t][^;&|]*)?$")
# Re-login and session checks: None means every subcommand is one. A tool that also
# does the work (tsh ssh, aws-vault exec) lists only its login subcommands, one or two words.
ACCESS = {"kinit": None, "kubelogin": None, "okta": None, "gimme-aws-creds": None,
          "tsh": {"login", "logout", "status", "kube login", "db login", "app login", "apps login"},
          "aws-vault": {"login", "clear", "remove", "rotate"}, "saml2aws": {"login", "configure"},
          "gcloud": {"auth"}, "aws": {"sso"}, "az": {"login", "account"},
          "vault": {"login"}, "gh": {"auth"}, "docker": {"login"}, "op": {"signin"}, "bw": {"login", "unlock"}}
VENDORED_HELPERS = set(VENDORED)
MAX_PROMPT = 400          # characters; a longer prompt is a pasted brief, not a question
MAX_QUESTION_STEPS = 10   # a longer run after a prompt is a task, not its answer
STOP = set("""a an the and or but if so of to in on at by for with from as is are was were be been being do does did
done this that these those it its i me my we our you your they them their can could would should will shall may
might must please pls why what how when where which who whom there here any some all just now again still also
get got make made check see look tell show give let know want need like into about over than then out up down
not no yes okay ok thanks thank hey hi let's lets one two""".split())


@dataclass
class Step:
    raw: tuple            # (program, first verb or "", second verb or "")
    attempts: int = 1
    fails: int = 0
    shape: str = ""


@dataclass
class Session:
    sid: str
    project: str
    date: str
    steps: list = field(default_factory=list)
    prompts: list = field(default_factory=list)   # (words, index of the first step after it)


REDIRECT = re.compile(r"\d*>&\d*-?|(?:&>>?|\d*>>?|<<-?|<)\s*[^\s;&|]+")


def drop_heredocs(cmd: str) -> str:
    """Heredoc bodies and their terminators out, unless the heredoc feeds a shell; an unterminated one runs to the end."""
    if "<<" not in cmd:
        return cmd
    out, term, dash, keep = [], None, False, False
    for line in cmd.split("\n"):
        if term is not None:
            if (line.lstrip("\t") if dash else line) == term:
                term = None
            elif keep:
                out.append(line)
            continue
        out.append(line)
        m = HEREDOC.search(line)
        if m:
            dash, term, keep = m.group(1) == "-", m.group(3), bool(FEEDS_A_SHELL.search(line[:m.start()]))
    return "\n".join(out)


def separate_lines(cmd: str) -> tuple[str, bool]:
    """Unquoted newlines become `;`; a quoted one stays in its argument. Comments go. Also says whether the quotes balance."""
    out, q, i, n = [], None, 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if ch == "\\" and q != "'" and i + 1 < n:
            out.append(" " if cmd[i + 1] == "\n" else cmd[i:i + 2])
            i += 2
            continue
        if q:
            q = None if ch == q else q
            out.append(ch)
        elif ch in "'\"":
            q = ch
            out.append(ch)
        elif ch == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|("):
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        else:
            out.append(" ; " if ch == "\n" else ch)
        i += 1
    return "".join(out), q is None


def tokens(cmd: str) -> list[str]:
    flat, balanced = separate_lines(drop_heredocs(cmd))
    if not balanced:   # a quote this does not model: the first line alone is the command
        flat, _ = separate_lines(cmd.split("\n", 1)[0])
    # `2>&1` would split on its `&` and make `1` a command; a redirection is never a step.
    flat = REDIRECT.sub(" ", flat)
    lex = shlex.shlex(flat, posix=True, punctuation_chars=";&|")
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError:
        return flat.split()


def pipelines(cmd: str) -> list[list[list[str]]]:
    """[[simple command tokens, ...] per pipeline] in run order."""
    out, pipe, simple = [], [], []
    for t in tokens(cmd):
        if t == "|":
            pipe.append(simple)
            simple = []
        elif t in (";", "&&", "||", "&", ";;", "|&"):
            pipe.append(simple)
            out.append(pipe)
            pipe, simple = [], []
        else:
            simple.append(t)
    pipe.append(simple)
    out.append(pipe)
    return [[s for s in p if s] for p in out if any(p)]


def raw_shape(simple: list[str]) -> tuple | None:
    i = 0
    while i < len(simple) and (re.match(r"^[A-Za-z_]\w*=", simple[i]) or simple[i] in WRAPPERS):
        i += 1
    if i >= len(simple):
        return None
    prog = os.path.basename(simple[i])
    if not re.fullmatch(r"[A-Za-z_.][A-Za-z0-9_.+-]{0,39}", prog) or prog in NOISE or prog.startswith("-"):
        return None
    rest = simple[i + 1:]
    if prog in RUN_WRAPPERS and rest[:1] == ["run"]:
        rest = rest[1:]
        prog, rest = (os.path.basename(rest[0]), rest[1:]) if rest and INTERPRETERS.match(os.path.basename(rest[0])) else ("python", rest)
    if SCRIPT.search(prog):   # a script run by its own path
        return ("python" if prog.endswith(".py") else "bash" if prog.endswith(".sh") else "run", script_label(simple[i]), "")
    if INTERPRETERS.match(prog):
        return (("python" if prog.startswith("python") else prog), interpreted(rest), "")
    verbs, j = [], 0
    while prog in SUBCOMMANDS and j < len(rest) and len(verbs) < 2:
        t = rest[j]
        if t.startswith("-"):
            j += 2 if ("=" not in t and t in VALUE_FLAGS) else 1
            continue
        if not VERB.fullmatch(t):
            break
        verbs.append(t)
        j += 1
    verbs += [""] * (2 - len(verbs))
    return (prog, verbs[0], verbs[1])


def script_label(path: str) -> str:
    m = SKILL_SCRIPT.search(path)
    return f"{m.group(1)}/{m.group(2)}" if m else os.path.basename(path)


def interpreted(rest: list[str]) -> str:
    """What an interpreter runs: a script's name, `-m module`, or "" for -c, stdin or nothing named."""
    j = 0
    while j < len(rest):
        t = rest[j]
        if t == "-m":
            return f"-m {rest[j + 1]}" if j + 1 < len(rest) and MODULE.fullmatch(rest[j + 1]) else ""
        if t in ("-c", "-"):
            return ""
        if t.startswith("-"):
            j += 2 if t in INTERP_VALUE_FLAGS else 1
            continue
        return script_label(t) if SCRIPT.search(t) else ""
    return ""


def step_of(pipe: list[list[str]]) -> tuple | None:
    for simple in pipe:
        r = raw_shape(simple)
        if r and r[0] not in FILTERS:
            return r
    return None


def add_command(s: Session, cmd: str, failed: bool, ignore: set) -> None:
    raws = [r for r in (step_of(p) for p in pipelines(cmd)) if r and r[0] not in ignore]
    for k, r in enumerate(raws):
        f = 1 if failed and k == len(raws) - 1 else 0
        if s.steps and s.steps[-1].raw == r:
            s.steps[-1].attempts += 1
            s.steps[-1].fails += f
        else:
            s.steps.append(Step(r, 1, f))


def words(text: str) -> tuple:
    text = re.sub(r"https?://\S+|\S*/\S+|`[^`]*`", " ", text[:300].lower())
    toks = [t for t in re.findall(r"[a-z][a-z'-]+", text) if t not in STOP and len(t) > 2]
    seen = []
    for t in toks:
        if t not in seen:
            seen.append(t)
    return tuple(seen)


def project_label(dirname: str) -> str:
    home = os.path.expanduser("~").replace("/", "-").replace(".", "-")
    return (dirname[len(home):] if dirname.startswith(home) else dirname).strip("-") or "home"


def when(ts) -> datetime | None:
    try:
        t = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else None


def read_transcripts(dirs: list[str], since: datetime, ignore: set, counts: dict | None = None) -> tuple[list[Session], int]:
    """Sessions from transcripts, each event kept only if its own timestamp is in the window.
    A file's age only rules a whole file out: a session resumed today still holds last month."""
    counts = counts if counts is not None else {}
    counts.setdefault("before", 0)
    sessions, bad = [], 0
    for d in dirs:
        for f in sorted(Path(d).expanduser().glob("*/*.jsonl")):
            try:
                if datetime.fromtimestamp(f.stat().st_mtime, timezone.utc) < since:
                    continue
                lines = f.read_text(errors="replace").splitlines()
            except OSError:
                bad += 1
                continue
            s = Session(f.stem[:8], project_label(f.parent.name), "")
            uses: dict = {}   # a command with no result never finished, and is left out
            for line in lines:
                try:
                    rec = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if not isinstance(rec, dict) or rec.get("isSidechain"):
                    continue
                t = when(rec.get("timestamp"))
                if t is not None and t < since:
                    counts["before"] += rec.get("type") in ("user", "assistant")
                    continue
                if not s.date and t is not None:
                    s.date = rec["timestamp"][:10]
                msg = rec.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                if rec.get("type") == "assistant" and isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash":
                            uses[c.get("id")] = (c.get("input") or {}).get("command", "")
                elif rec.get("type") == "user":
                    if isinstance(content, str):
                        texts = [content]
                    elif isinstance(content, list):
                        texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("tool_use_id") in uses:
                                body = c.get("content")
                                body = body if isinstance(body, str) else json.dumps(body)
                                failed = bool(c.get("is_error")) or bool(re.match(r"Exit code [1-9]", body or ""))
                                add_command(s, uses.pop(c.get("tool_use_id")), failed, ignore)
                    else:
                        texts = []
                    for t in texts:
                        if rec.get("isMeta") or not t.strip() or t.lstrip().startswith(("<", "[Request interrupted", "Caveat:")):
                            continue
                        w = words(t)
                        if len(w) >= 2 and len(t) <= MAX_PROMPT:
                            s.prompts.append((w, len(s.steps)))
            if s.steps or s.prompts:
                sessions.append(s)
    return sessions, bad


def read_history(files: list[str], since: datetime, ignore: set, include_undated: bool = False,
                 counts: dict | None = None) -> list[Session]:
    """Shell history in sessions: dated lines by their time, gaps over 30 minutes splitting them. A line
    with no timestamp cannot be placed in the window; it is counted and left out unless include_undated."""
    counts = counts if counts is not None else {}
    counts.setdefault("undated", 0)
    sessions = []
    for name in files:
        path = Path(name).expanduser()
        if not path.is_file():
            continue
        entries, ts, buf = [], None, ""
        for line in path.read_text(errors="replace").splitlines():
            if buf:
                buf += "\n" + line
            else:
                m = re.match(r"^: (\d+):\d+;(.*)$", line)
                if m:
                    ts, buf = int(m.group(1)), m.group(2)
                elif re.fullmatch(r"#\d{9,}", line):
                    ts = int(line[1:])
                    continue
                else:
                    buf = line
            if buf.endswith("\\"):
                buf = buf[:-1]
                continue
            entries.append((ts, buf))
            buf = ""
        dated = [e for e in entries if e[0] is not None]
        undated = [e for e in entries if e[0] is None]
        groups, cur, last = [], [], None
        for t, cmd in dated:
            if datetime.fromtimestamp(t, timezone.utc) < since:
                continue
            if last is not None and t - last > 1800:
                groups.append(cur)
                cur = []
            cur.append((t, cmd))
            last = t
        groups.append(cur)
        if include_undated:
            groups += [undated[i:i + 50] for i in range(0, len(undated), 50)]
        else:
            counts["undated"] += len(undated)
        for k, g in enumerate(groups):
            if not g:
                continue
            day = datetime.fromtimestamp(g[0][0], timezone.utc).strftime("%Y-%m-%d") if g[0][0] else "undated"
            s = Session(f"{path.name}#{k}", "shell history", day)
            for _, cmd in g:
                add_command(s, cmd, False, ignore)
            sessions.append(s)
    return sessions


def assign_shapes(sessions: list[Session]) -> None:
    """A subcommand joins a shape only once it recurs across sessions."""
    v1, v2 = defaultdict(set), defaultdict(set)
    for s in sessions:
        for st in s.steps:
            p, a, b = st.raw
            v1[(p, a)].add(s.sid)
            v2[(p, a, b)].add(s.sid)
    for s in sessions:
        for st in s.steps:
            p, a, b = st.raw
            parts = [p]
            if a and (p in SCRIPT_RUNNERS or len(v1[(p, a)]) >= 2):   # a script's name is not an id
                parts.append(a)
                if b and len(v2[(p, a, b)]) >= 3:
                    parts.append(b)
            st.shape = " ".join(parts)
        merged = []
        for st in s.steps:
            if merged and merged[-1].shape == st.shape:
                merged[-1].attempts += st.attempts
                merged[-1].fails += st.fails
            else:
                merged.append(st)
        s.steps = merged


def smoothed(fails: int, attempts: int) -> float:
    return (fails + 1) / (attempts + 2)


def stem(w: str) -> str:
    """Enough of an English stem that `slowly` meets `slow` and `nightly` meets `night`."""
    for suffix in ("ingly", "edly", "ing", "ly", "ed", "es", "s"):
        if w.endswith(suffix) and len(w) - len(suffix) >= 4:
            return w[:-len(suffix)]
    return w


def similar(a: set, b: set) -> bool:
    """Two prompts ask the same thing in other words: two content stems shared, half the shorter one's."""
    shared = len(a & b)
    return shared >= 2 and shared / min(len(a), len(b)) >= 0.5


def is_access(shape: str) -> bool:
    parts = shape.split()
    rule = ACCESS.get(parts[0], False) if parts else False
    return rule is None or (rule is not False and len(parts) > 1 and (parts[1] in rule or " ".join(parts[1:3]) in rule))


def installed_engines(dirs: list[str]) -> dict:
    """`skill/script` and, where only one skill has it, `script` -> the skill whose engine it is."""
    qual, base = {}, defaultdict(set)
    for d in dirs:
        for md in sorted(Path(d).expanduser().glob("*/SKILL.md")):
            root = md.parent
            for p in [*root.glob("*.py"), *root.glob("*.sh"), *root.glob("bin/*.py"), *root.glob("bin/*.sh")]:
                if p.name not in VENDORED_HELPERS and not p.name.startswith("test_"):
                    qual[f"{root.name}/{p.name}"] = root.name
                    base[p.name].add(root.name)
    return {**{b: next(iter(s)) for b, s in base.items() if len(s) == 1}, **qual}


def tag(c: dict, shapes: list[str], engines: dict) -> None:
    """access when most steps are re-login or session checks; covered_by when a step runs a skill's engine."""
    c["tag"] = "access" if c["kind"] != "question" and 2 * sum(map(is_access, shapes)) >= len(shapes) else ""
    c["covered_by"] = next((engines[p[1]] for p in (s.split() for s in shapes)
                            if len(p) == 2 and p[0] in SCRIPT_RUNNERS and p[1] in engines), "")


def candidates(sessions: list[Session], min_sessions: int, engines: dict | None = None) -> list[dict]:
    out = []
    seq: dict = defaultdict(lambda: {"sids": set(), "attempts": 0, "fails": 0, "examples": {}})
    for s in sessions:
        shapes = [st.shape for st in s.steps]
        seen = set()
        for n in range(2, 6):
            for i in range(len(shapes) - n + 1):
                key = tuple(shapes[i:i + n])
                if len(set(key)) < 2:
                    continue
                c = seq[key]
                c["attempts"] += sum(st.attempts for st in s.steps[i:i + n])
                c["fails"] += sum(st.fails for st in s.steps[i:i + n])
                if key not in seen:
                    seen.add(key)
                    c["sids"].add(s.sid)
                    c["examples"][s.sid] = (s.date, s.project)
    for key, c in seq.items():
        if len(c["sids"]) >= min_sessions:
            out.append({"kind": "sequence", "label": " → ".join(key), "steps": len(key), "_shapes": list(key), **_stats(c)})
    fail: dict = defaultdict(lambda: {"sids": set(), "attempts": 0, "fails": 0, "examples": {}})
    for s in sessions:
        for st in s.steps:
            c = fail[st.shape]
            c["attempts"] += st.attempts
            c["fails"] += st.fails
            if st.fails:
                c["sids"].add(s.sid)
                c["examples"][s.sid] = (s.date, s.project)
    for shape, c in fail.items():
        if len(c["sids"]) >= min_sessions:
            out.append({"kind": "failing", "label": shape, "steps": 1, "_shapes": [shape], **_stats(c)})
    clusters: list = []
    for s in sessions:
        for idx, (w, at) in enumerate(s.prompts):
            end = s.prompts[idx + 1][1] if idx + 1 < len(s.prompts) else len(s.steps)
            after = s.steps[at:end]
            ws = {stem(x) for x in w}
            home = next((c for c in clusters if any(similar(ws, m) for m in c["members"])), None)
            if home is None:
                home = {"members": [], "forms": Counter(), "sids": set(), "attempts": 0, "fails": 0, "examples": {},
                        "nsteps": [], "shapes": set()}
                clusters.append(home)
            home["members"].append(ws)
            home["shapes"] |= {st.shape for st in after}
            home["forms"][w] += 1
            home["sids"].add(s.sid)
            home["examples"][s.sid] = (s.date, s.project)
            home["attempts"] += sum(st.attempts for st in after)
            home["fails"] += sum(st.fails for st in after)
            home["nsteps"].append(len(after))
    for c in clusters:
        steps = min(MAX_QUESTION_STEPS, round(sum(c["nsteps"]) / len(c["nsteps"])))
        if len(c["sids"]) >= min_sessions and steps >= 1:   # a question no command answered gives a skill nothing to run
            label = " ".join(c["forms"].most_common(1)[0][0])
            out.append({"kind": "question", "label": label, "steps": steps, "_shapes": sorted(c["shapes"]), **_stats(c)})
    for c in out:
        c["score"] = round(c["sessions"] * c["steps"] * smoothed(c["failures"], c["attempts"]), 2)
        tag(c, c.pop("_shapes"), engines or {})
    out.sort(key=lambda c: (-c["score"], -c["sessions"], c["label"]))
    return drop_subsumed(out)


def _stats(c: dict) -> dict:
    ex = sorted(c["examples"].items(), key=lambda kv: kv[1][0], reverse=True)[:3]
    return {"sessions": len(c["sids"]), "attempts": c["attempts"], "failures": c["fails"],
            "examples": [f"{d or 'undated'} ({p}, {sid})" for sid, (d, p) in ex], "_sids": c["sids"]}


def drop_subsumed(ranked: list[dict]) -> list[dict]:
    """A sequence inside a higher-ranked one, seen in no session it was not, adds nothing."""
    kept = []
    for c in ranked:
        if c["kind"] == "sequence":
            parts = c["label"].split(" → ")
            if any(k["kind"] == "sequence" and c["_sids"] <= k["_sids"] and _contains(k["label"].split(" → "), parts) for k in kept):
                continue
        kept.append(c)
    return kept


def _contains(big: list, small: list) -> bool:
    return any(big[i:i + len(small)] == small for i in range(len(big) - len(small) + 1))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    whole = read_toml(config_path())
    cfg = whole.get("demand", {})
    # skill_dirs is set once, under [discover], and read by both; [demand] may override it.
    skill_dirs = cfg.get("skill_dirs") or whole.get("discover", {}).get("skill_dirs", ["~/.claude/skills"])
    p.add_argument("--top", type=int, default=cfg.get("top", 10))
    p.add_argument("--since", type=int, default=cfg.get("since_days", 60), help="days back")
    p.add_argument("--transcripts", action="append")
    p.add_argument("--history", action="append")
    p.add_argument("--min-sessions", type=int, default=2)
    p.add_argument("--ignore", action="append", default=None, help="a program to leave out, e.g. git (repeatable)")
    p.add_argument("--skills", action="append", metavar="DIR", help="where installed skills live (default ~/.claude/skills)")
    p.add_argument("--include-undated", action="store_true", help="count shell history lines that carry no timestamp")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=a.since)
    ignore = set(a.ignore if a.ignore is not None else cfg.get("ignore_programs", []))
    tdirs = a.transcripts or cfg.get("transcript_dirs", ["~/.claude/projects"])
    hfiles = a.history if a.history is not None else cfg.get("history_files", ["~/.zsh_history", "~/.bash_history"])
    counts: dict = {}
    sessions, bad = read_transcripts(tdirs, since, ignore, counts)
    hist = read_history(hfiles, since, ignore, a.include_undated, counts)
    allsess = sessions + hist
    assign_shapes(allsess)
    ranked = candidates(allsess, a.min_sessions, installed_engines(a.skills or skill_dirs))
    top = [c for c in ranked if c["tag"] != "access"][:a.top]
    access = [c for c in ranked if c["tag"] == "access"][:max(3, a.top // 3)]
    m = masker()
    for c in top + access:
        c.pop("_sids")
        c["label"] = m(c["label"])[:80]
        c["examples"] = [m(e) for e in c["examples"]]
    if a.json:
        emit(json.dumps(top + access, indent=2))
        return EXIT_OK
    projects = len({s.project for s in sessions})
    left_out = [f"{bad} unreadable transcript lines or files skipped"] if bad else []
    if counts["undated"]:
        left_out.append(f"{counts['undated']} shell-history lines with no timestamp left out (--include-undated counts them)")
    emit(header(target=f"{len(sessions)} transcript sessions in {projects} projects; {len(hist)} shell-history sessions",
                window=Window(since, now, bounds="each command and prompt by its own timestamp in [start, end]"),
                rows=len(top), partial="; ".join(left_out) or None))
    emit(f"# outside the window: {counts['before']} transcript events from resumed sessions, left out")
    emit("# score = sessions x steps x (failures + 1) / (attempts + 2)")
    for i, c in enumerate(top, 1):
        emit(f"{i:>2}. score {c['score']:<6} {c['kind']:<9} {c['label']}" + (f"  (covered by {c['covered_by']})" if c["covered_by"] else ""))
        emit(f"    {c['sessions']} sessions · {c['steps']} steps · {c['attempts']} attempts, {c['failures']} failed · e.g. {', '.join(c['examples'])}")
    if not top:
        emit(f"no candidate seen in {a.min_sessions}+ sessions; widen --since or lower --min-sessions")
    if access:
        emit("\n# access friction, ranked apart: re-login and session checks are a session to fix, not a skill to write")
        for i, c in enumerate(access, 1):
            emit(f"a{i}. score {c['score']:<6} {c['kind']:<9} {c['label']}")
            emit(f"    {c['sessions']} sessions · {c['attempts']} attempts, {c['failures']} failed · e.g. {', '.join(c['examples'])}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
