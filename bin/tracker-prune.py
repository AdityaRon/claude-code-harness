#!/usr/bin/env python3
"""Moves a tracker's settled rows into <name>-archive.md beside it, so the tracker stays small.

  tracker-prune.py FILE            dry run: bytes before and after for both files, counts, the
                                   first 40 rows (cut to 100 characters); writes nothing
  tracker-prune.py FILE --all      the same, every row
  tracker-prune.py FILE --write    moves them, under a `## YYYY-MM-DD` block (--date sets it)

A row moves when it is
  - a table row whose Status or State cell, without markup and a trailing date or (#n), is
    settled, closed or done in any case. "not done" is not; one that only starts with a word
    ("done?") is counted as a near miss and kept. A table with neither column is reported;
  - a top-level `- [x]` item, with its indented lines, unless one of them is an open `[ ]`;
  - a top-level bullet starting DONE:, CLOSED: or SETTLED:, bold or not, on the same terms.
Never prose, a heading, or anything in a code fence.

--write appends the block to the archive, checks the archive grew by exactly the block and ends
with it, checks FILE has not changed since it was read, then replaces FILE through a temp file in
its folder. A failure before the replace takes the block back out (an archive it created is
removed), so a row is in one file or both, never neither. Every line of FILE must be in the new
FILE or the block, as often as before. A new archive starts with a line saying to grep it, never
read it whole.

Refuses, writing nothing (exit 3): an unclosed code fence, a row in a status table whose cells do
not match its header, a FILE named *-archive.md, an archive that is not a regular file, a FILE that
is not UTF-8, or one that changed while this ran. A FILE reached through a symlink is rewritten at
its target, and the archive goes beside the path given, where memory-lint looks for it.
"""
import argparse
import collections
import datetime
import hashlib
import os
import re
import stat
import sys
import tempfile
import time

ROWS_SHOWN = 40
CUT = 100
KEYWORDS = ("settled", "closed", "done")
PAUSE_ENV = "CLAUDE_TRACKER_PRUNE_TEST_PAUSE"  # tests only: hold between the archive append and the re-check
FAULT_ENV = "CLAUDE_TRACKER_PRUNE_TEST_FAULT"  # tests only: drop-line or short-append, a bug the checks must catch

FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})")
HEADING = re.compile(r"^#{1,6}[ \t]")
DELIM_CELL = re.compile(r"^[ \t]*:?-+:?[ \t]*$")
CHECKED = re.compile(r"^[-*+][ \t]+\[[xX]\](?:[ \t]|$)")
KEYWORD_BULLET = re.compile(r"^[-*+][ \t]+((?:\*\*|__)?)(?:done|closed|settled)(?::\1|\1:)", re.I)
OPEN_CHILD = re.compile(r"^[ \t]+(?:[-*+]|\d+[.)])[ \t]+\[ \]")
MARKUP = re.compile(r"[*_`~]")
TRAIL = re.compile(r"[\s,;:.-]*(?:\(\s*(?:\d{4}-\d{2}-\d{2}|#\d+)\s*\)|\d{4}-\d{2}-\d{2}|#\d+)\s*$")
CELL_SPLIT = re.compile(r"(?<!\\)\|")


class Refuse(Exception):
    pass


def split_lines(data):
    """FILE's bytes as lines, each with its own ending; only \\n ends a line."""
    parts = data.split(b"\n")
    lines = [p + b"\n" for p in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines


def content(line):
    """A line without its ending, as the line balance compares it."""
    return line[:-1] if line.endswith(b"\n") else line


def cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return CELL_SPLIT.split(s)


def status_word(cell):
    s = MARKUP.sub("", cell).strip()
    while True:
        t = TRAIL.sub("", s)
        if t == s:
            break
        s = t
    return s.strip(" \t,;:.-").casefold()


def is_delim(line):
    s = line.strip()
    return s.startswith("|") and "-" in s and all(DELIM_CELL.match(c) for c in cells(line))


def fences(text):
    """Per line: inside a code fence (its markers included), and still open after it."""
    inside, open_after, fence, start = [], [], None, 0
    for i, line in enumerate(text):
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence, start = m.group(1), i
            inside.append(fence is not None)
        else:
            inside.append(True)
            s = line.strip()
            if s and set(s) == {fence[0]} and len(s) >= len(fence):
                fence = None
        open_after.append(fence is not None)
    if fence is not None:
        raise Refuse("line %d: a code fence opens and never closes" % (start + 1))
    return inside, open_after


Unit = collections.namedtuple("Unit", "kind first last heading table")


def plan(text):
    """What moves, what is kept and why. TEXT is FILE's lines without their endings."""
    inside, open_after = fences(text)
    units, open_child, spans_fence, no_status, near = [], [], [], [], []
    heading, i, n = None, 0, len(text)
    while i < n:
        line = text[i]
        if inside[i]:
            i += 1
            continue
        if HEADING.match(line):
            heading = i
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < n and not inside[i + 1] and is_delim(text[i + 1]):
            head = cells(line)
            col = next((k for k, c in enumerate(head) if MARKUP.sub("", c).strip().casefold() in ("status", "state")), None)
            j = i + 2
            while j < n and not inside[j] and text[j].lstrip().startswith("|"):
                if col is not None:
                    row = cells(text[j])
                    if len(row) != len(head):
                        raise Refuse("line %d: a row in a status table has %d cells, its header %d"
                                     % (j + 1, len(row), len(head)))
                    w = status_word(row[col])
                    if w in KEYWORDS:
                        units.append(Unit("table", j, j, heading, i))
                    elif w.startswith(KEYWORDS):
                        near.append(j)
                j += 1
            if col is None:
                no_status.append(i)
            i = j
            continue
        kind = "checked" if CHECKED.match(line) else "keyword" if KEYWORD_BULLET.match(line) else None
        if kind:
            last, j = i, i + 1
            while j < n:
                if not text[j].strip():
                    j += 1
                elif text[j][0] in " \t":
                    last, j = j, j + 1
                else:
                    break
            if any(OPEN_CHILD.match(text[k]) and not inside[k] for k in range(i + 1, last + 1)):
                open_child.append(i)
            elif open_after[last]:
                spans_fence.append(i)
            else:
                units.append(Unit(kind, i, last, heading, None))
            i = last + 1
            continue
        i += 1
    return units, {"open_child": open_child, "spans_fence": spans_fence, "no_status": no_status, "near": near}


def build_block(units, raw, text, date, fresh, tail):
    """The archive block as (bytes, generated) pairs. Generated lines are context: the date, a
    section heading, a table's header. TAIL is the archive's last byte, b"" when it is empty."""
    out = []
    nl = lambda b: b if b.endswith(b"\n") else b + b"\n"
    if fresh:
        out.append((b"# Archive: settled rows tracker-prune.py moved out. grep it, never read it whole.\n", True))
    elif tail and tail != b"\n":
        out.append((b"\n", True))
    out.append((b"\n## " + date.encode() + b"\n", True))
    prev = object()
    for u in units:
        key = (u.heading, u.table)
        if key != prev:
            out.append((b"\n", True))
            if u.heading is not None:
                out.append((b"### " + text[u.heading].lstrip("#").strip().encode() + b"\n", True))
            if u.table is not None:
                out.append((nl(raw[u.table]), True))
                out.append((nl(raw[u.table + 1]), True))
            prev = key
        for k in range(u.first, u.last + 1):
            out.append((nl(raw[k]), False))
    return out


def shown(lines):
    s = ", ".join(str(k + 1) for k in lines[:10])
    return s + (" and %d more" % (len(lines) - 10) if len(lines) > 10 else "")


def report_kept(why):
    parts = []
    if why["open_child"]:
        parts.append("%d done item(s) with an open [ ] under them (line %s)" % (len(why["open_child"]), shown(why["open_child"])))
    if why["spans_fence"]:
        parts.append("%d done item(s) a code fence runs out of (line %s)" % (len(why["spans_fence"]), shown(why["spans_fence"])))
    if why["no_status"]:
        parts.append("%d table(s) with no Status or State column (line %s)" % (len(why["no_status"]), shown(why["no_status"])))
    if why["near"]:
        parts.append("%d status(es) that start with settled, closed or done but are not one (line %s)"
                     % (len(why["near"]), shown(why["near"])))
    for p in parts:
        print("kept: " + p)


def cut(s):
    return s if len(s) <= CUT else s[:CUT - 1] + "…"


def pause():
    """Tests only: say the archive holds the block, then wait for the go-ahead file."""
    p = os.environ.get(PAUSE_ENV)
    if not p:
        return
    open(p + ".ready", "w").close()
    for _ in range(600):
        if os.path.exists(p):
            return
        time.sleep(0.1)
    raise Refuse("%s never appeared" % p)


def take_back(archive, old_size, created):
    """Takes the block back out of the archive, or removes the archive this run created."""
    try:
        if created:
            os.unlink(archive)
        else:
            os.truncate(archive, old_size)
        return ""
    except OSError as e:
        return " Could not take the block back out of %s (%s): its rows are in both files." % (archive, e)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], allow_abbrev=False)
    ap.add_argument("file", help="the tracker")
    ap.add_argument("--write", action="store_true", help="move the rows; without it, a dry run")
    ap.add_argument("--all", action="store_true", help="list every row, not the first %d" % ROWS_SHOWN)
    ap.add_argument("--date", help="the archive block's date, YYYY-MM-DD (default today)")
    a = ap.parse_args(argv)
    date = a.date or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        ap.error("--date takes YYYY-MM-DD")
    try:
        return run(a, date)
    except Refuse as e:
        print("tracker-prune: refused, nothing written: %s" % e, file=sys.stderr)
        return 3


def run(a, date):
    given = os.path.abspath(a.file)
    name = os.path.basename(given)
    if name.endswith("-archive.md"):
        raise Refuse("%s is an archive; name the tracker it came from" % name)
    slug = name[:-3] if name.endswith(".md") else name
    archive = os.path.join(os.path.dirname(given), slug + "-archive.md")
    aname = os.path.basename(archive)
    real = os.path.realpath(given)
    try:
        st = os.stat(real)
        if not stat.S_ISREG(st.st_mode):
            raise Refuse("%s is not a regular file" % a.file)
        with open(real, "rb") as f:
            data = f.read()
    except OSError as e:
        raise Refuse("cannot read %s: %s" % (a.file, e))
    digest = hashlib.sha256(data).digest()
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise Refuse("%s is not UTF-8 (byte %d)" % (name, e.start))
    raw = split_lines(data)
    text = [content(r).decode("utf-8").rstrip("\r") for r in raw]
    units, why = plan(text)

    try:
        ast = os.lstat(archive)
    except FileNotFoundError:
        ast = None
    except OSError as e:
        raise Refuse("cannot stat %s: %s" % (aname, e))
    if ast is not None and not stat.S_ISREG(ast.st_mode):
        raise Refuse("%s is not a regular file" % aname)
    old_size = ast.st_size if ast else 0
    tail = b""
    if old_size:
        with open(archive, "rb") as f:
            f.seek(old_size - 1)
            tail = f.read(1)

    moved = set(k for u in units for k in range(u.first, u.last + 1))
    kept = [r for k, r in enumerate(raw) if k not in moved]
    if os.environ.get(FAULT_ENV) == "drop-line" and kept:
        kept = kept[1:]
    new = b"".join(kept)
    pairs = build_block(units, raw, text, date, ast is None, tail)
    block = b"".join(b for b, _ in pairs)

    if not units:
        print("%s: nothing to move (%d bytes)." % (name, len(data)))
        report_kept(why)
        return 0

    kinds = collections.Counter(u.kind for u in units)
    print("%s: %d bytes now, %d after; %d rows to move (%d table, %d [x], %d DONE:/CLOSED:/SETTLED:)"
          % (name, len(data), len(new), len(units), kinds["table"], kinds["checked"], kinds["keyword"]))
    print("%s: %s, %d bytes after" % (aname, "%d bytes now" % old_size if ast else "new", old_size + len(block)))
    report_kept(why)

    # Every line of FILE is in the new FILE or the block, as often as before.
    old_c = collections.Counter(content(r) for r in raw)
    got_c = collections.Counter(content(r) for r in split_lines(new))
    got_c.update(content(b) for b, gen in pairs if not gen)
    if old_c != got_c:
        raise Refuse("the lines do not balance (%d lines before, %d after with the block); this is a bug"
                     % (sum(old_c.values()), sum(got_c.values())))

    if not a.write:
        rows = units if a.all else units[:ROWS_SHOWN]
        print("rows%s:" % ("" if a.all or len(units) <= ROWS_SHOWN
                           else " 1-%d of %d (--all lists every one)" % (ROWS_SHOWN, len(units))))
        for u in rows:
            more = u.last - u.first
            print("  L%-6d %s%s" % (u.first + 1, cut(text[u.first]), " (+%d lines)" % more if more else ""))
        print("dry run: nothing written. --write moves them.")
        return 0

    # 1. Append the block, and check the archive grew by exactly it and ends with it.
    created = ast is None
    flags = os.O_WRONLY | os.O_APPEND | (os.O_CREAT | os.O_EXCL if created else 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(archive, flags, 0o644)
    except OSError as e:
        raise Refuse("cannot open %s to append: %s" % (aname, e))
    try:
        try:
            body = block
            if os.environ.get(FAULT_ENV) == "short-append":
                body = b"".join(b for b, _ in pairs[:-1])
            os.write(fd, body)
            os.fsync(fd)
        finally:
            os.close(fd)
        with open(archive, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - len(block)))
            end = f.read()
        if size != old_size + len(block) or end != block:
            raise Refuse("%s is %d bytes after the append, not %d, or does not end with the block"
                         % (aname, size, old_size + len(block)))
        pause()
        # 2. FILE is what was read: an edit made meanwhile would be lost in the replace.
        with open(real, "rb") as f:
            if hashlib.sha256(f.read()).digest() != digest:
                raise Refuse("%s changed while this ran; run it again" % name)
        # 3. Replace FILE through a temp file in its folder, with its mode.
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix="." + os.path.basename(real) + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(new)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, stat.S_IMODE(st.st_mode))
            os.replace(tmp, real)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Refuse as e:
        raise Refuse(str(e) + take_back(archive, old_size, created))
    except BaseException as e:
        msg = take_back(archive, old_size, created)
        if isinstance(e, Exception):
            raise Refuse("%s: %s.%s" % (type(e).__name__, e, msg))
        raise
    try:
        dfd = os.open(os.path.dirname(real), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass
    print("moved %d rows: %s %d -> %d bytes, %s %d -> %d bytes, under ## %s."
          % (len(units), name, len(data), len(new), aname, old_size, old_size + len(block), date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
