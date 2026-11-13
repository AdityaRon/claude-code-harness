#!/usr/bin/env python3
"""Where a heredoc starts, and where its body ends, as bash reads a script: a port of
hooks/lib/command.sh's HEREDOC_AWK (hd_scan, hd_word, hd_body, hd_bad_end, hd_end), not
imported: this skill installs alone. tests/heredoc-openers.test.sh holds the two together.
demand.py (counting the commands a session runs) and skill_lint.py (reading a shell
script's code apart from its comments and heredoc data) both use it.

  heredocs.py FILE    one letter a line, as this reads FILE: c code, o a heredoc opener,
                      b body, e terminator, u the line it cannot read (it stops there)
"""
from __future__ import annotations

import argparse
import re
import sys

HD_WORD = re.compile(r"[A-Za-z0-9_.-]+")
HD_SUB = re.compile(r"\$\(|`|[<>]\(")
# A body a shell runs: not lib.sh's hd_shell, on purpose: a guard keeps a body whenever its line names a
# shell (its safe side), while a counter keeps one only when a shell runs it, so a
# PR title or a path naming bash does not turn the body into counted commands.
SHELL_CMD = re.compile(r"(?:^|[;&|(`]|\$\()[ \t]*(?:(?:sudo|exec|command|nohup|env)(?:[ \t]+-\S+)*[ \t]+)*"
                       r"(?:[A-Za-z_]\w*=\S*[ \t]+)*(?:(?:/[\w.-]+)*/)?"
                       r"(?:(?:ba|z|da|k|fi|s)?sh|\$\{?SHELL\}?)(?=[ \t;&|)]|$)"
                       r"|(?:^|[;&|(`]|\$\()[ \t]*(?:eval|source|\.)[ \t]")


def _arith(s: str, i: int) -> int:
    """Where the (( at i closes as one )), or -1: bash reads ((cmd) ) as two subshells."""
    d, p = 0, -1
    for j in range(i, len(s)):
        if s[j] == "(":
            d += 1
        elif s[j] == ")":
            d -= 1
            if d == 1:
                p = j
            elif d == 0:
                return j if p == j - 1 else -1
    return -1


def _btq(s: str, i: int, c: str) -> bool:
    """Inside backticks: does the quote c at i hold a backtick, which ends the substitution?"""
    j = i + 1
    while j < len(s):
        if s[j] == "\\" and c == '"':
            j += 2
            continue
        if s[j] == c:
            return False
        if s[j] == "`":
            return True
        j += 1
    return False


def _word(s: str, i: int):
    """The delimiter after the << at i: (length from i, word, dash, quoted), or None."""
    j, dash, lit = i + 2, False, False
    if s[j:j + 1] == "-":
        dash, j = True, j + 1
    while s[j:j + 1] in (" ", "\t") and j < len(s):
        j += 1
    c = s[j:j + 1]
    if c in ("'", '"'):
        k = s.find(c, j + 1)
        if k < 0:
            return None
        w, j, lit = s[j + 1:k], k + 1, True
        if not w or (c == '"' and re.search(r"[\\$`]", w)):
            return None
    else:
        if c == "\\":
            lit, j = True, j + 1
        m = HD_WORD.match(s, j)
        if not m:
            return None
        w, j = m.group(), m.end()
    if s[j:j + 1] not in ("", " ", "\t", ";", "&", "|", "(", ")", "<", ">"):
        return None
    return j - i, w, dash, lit


class Heredocs:
    """Where a heredoc starts, as bash reads a line: a port of hooks/lib.sh's
    hd_scan, held to bash by tests/heredoc-openers.test.sh. Quote state carries
    over lines; scan() raises ValueError on a << it cannot read for certain."""

    def __init__(self):
        self.q, self.frames, self.bt, self.cont = "", [], False, False
        self.subseen = self.insub = False
        self.hbq, self.hbdep, self.tail = "", 0, ""   # hd_body's HB_Q, HB_DEP, HB_TAIL

    def body(self, s: str) -> bool:
        """One line of a body opened inside $( ), <( ) or backticks, through bash 3.2's
        substitution scanner (lib.sh's hd_body): True where it might end the substitution."""
        i, n = 0, len(s)
        while i < n:
            c = s[i]
            if self.hbq == "'":
                if c == "'":
                    self.hbq = ""
            elif self.hbq in ("`", "B"):
                if c == "\\":
                    i += 1
                elif c == "`":
                    self.hbq = '"' if self.hbq == "B" else ""
            elif self.hbq == '"':
                if c == "\\":
                    i += 1
                elif c == '"':
                    self.hbq = ""
                elif c == "`":
                    self.hbq = "B"
                elif c == "$" and s[i + 1:i + 2] in ("(", "{", "["):
                    return True
            elif c == "\\":
                i += 1
            elif c == "'":
                if i > 0 and s[i - 1] == "$":
                    return True
                self.hbq = "'"
            elif c in "\"`":
                self.hbq = c
            elif c == "(":
                self.hbdep += 1
            elif c == ")":
                self.hbdep -= 1
                if self.hbdep < 0:
                    return True
            elif c == "#" and (i == 0 or s[i - 1] in " \t"):
                return bool(re.search(r"[()'\"`\\]", s[i + 1:]))
            i += 1
        return False

    def scan(self, s: str):
        found, n, esc, i = None, len(s), -2, 0
        if self.tail and self.tail in s:   # a quote a body left open flips this line
            raise ValueError(s)
        while i < n:
            c = s[i]
            if self.q == "'":
                self.q = "" if c == "'" else self.q
                i += 1
                continue
            if self.q == "A":
                if c == "\\":
                    i += 1
                elif c == "'":
                    self.q = ""
                i += 1
                continue
            if c == "\\":
                esc, i = i + 1, i + 2
                continue
            if c == "$" and s[i + 1:i + 2] == "{":
                j = s.find("}", i + 2)
                if j < 0 or re.search(r"['\"`{]|<<|\$\(", s[i + 2:j]):
                    raise ValueError(s)
                i = j + 1
                continue
            if self.q == '"':
                if c == '"':
                    self.q = ""
                elif c == "`":
                    self.frames.append(['"', 0, True])
                    self.q = ""
                elif c == "$" and s[i + 1:i + 3] == "((":
                    i = _arith(s, i + 1)
                    if i < 0:
                        raise ValueError(s)
                elif c == "$" and s[i + 1:i + 2] == "(":
                    self.frames.append(['"', 1, False])
                    self.q, i = "", i + 1
                i += 1
                continue
            if self.frames and self.frames[-1][2] and c == "`":
                self.q = self.frames.pop()[0]
                i += 1
                continue
            if (self.bt or (self.frames and self.frames[-1][2])) and c in "\"'" and _btq(s, i, c):
                raise ValueError(s)
            if c == "'":
                j = i - 1
                while j >= 0 and s[j] == "$" and esc != j:
                    j -= 1
                self.q = "A" if (i - 1 - j) % 2 else "'"
            elif c == '"':
                self.q = '"'
            elif c == "`":
                self.bt = not self.bt
            elif c == "#" and esc != i - 1 and (not self.cont if i == 0 else s[i - 1] in " \t;&|()"):
                if not self.bt and not (self.frames and self.frames[-1][2]):
                    break
                j = s.find("`", i + 1)      # inside backticks the comment ends there
                if j < 0:
                    raise ValueError(s)
                i = j
                continue
            elif c == "(" and s[i + 1:i + 2] == "(":
                i = _arith(s, i)
                if i < 0:
                    raise ValueError(s)
            elif c == "$" and s[i + 1:i + 2] == "[":
                i = s.find("]", i)
                if i < 0:
                    raise ValueError(s)
            elif found and self.insub and c == ")":   # x=$(cat <<EOF) ends it here, in zsh too
                raise ValueError(s)
            elif self.frames and not self.frames[-1][2] and c in "()":
                self.frames[-1][1] += 1 if c == "(" else -1
                if self.frames[-1][1] == 0:
                    self.q = self.frames.pop()[0]
            elif (self.frames and not self.frames[-1][2] and s.startswith("case", i) and s[i + 4:i + 5] in (" ", "\t")
                  and (i == 0 or s[i - 1] in " \t;&|(")):
                raise ValueError(s)
            elif c == "<" and s[i + 1:i + 2] == "<":
                if s[i + 2:i + 3] == "<":
                    i += 2
                else:
                    w = None if self.bt or found or (self.frames and self.frames[-1][2]) else _word(s, i)
                    if not w:
                        raise ValueError(s)
                    found = w
                    self.hbq, self.hbdep = "", 0
                    self.insub = self.subseen or bool(HD_SUB.search(s, 0, i + 1))
                    if self.insub and (re.search(r"[()'\"`\\]", w[1]) or self.body(s[i + w[0]:])):
                        raise ValueError(s)
                    i += w[0] - 1
            i += 1
        self.cont = esc == n
        self.subseen = self.subseen or bool(HD_SUB.search(s)) or (self.cont and s[-2:-1] in ("$", "<", ">"))
        if found and (self.q or self.cont):
            raise ValueError(s)
        return found

    def body_line(self, s: str, term: str, dash: bool) -> bool:
        """One line of the body scan() found: True at its terminator. Raises ValueError where
        bash 3.2 may read it otherwise (lib.sh's hd_bad_end, then hd_end)."""
        t = s.lstrip("\t") if dash else s
        if self.tail and self.tail in s:   # a quote an earlier body left open
            raise ValueError(s)
        if t == term:
            if self.insub and self.hbq:
                self.tail = "`" if self.hbq == "B" else self.hbq
            elif self.insub and self.hbdep:
                raise ValueError(s)
            return True
        if self.insub and (t == term + ")" or self.body(s)):
            raise ValueError(s)
        return False


def roles(src: str) -> str:
    """One letter a line of SRC: c code, o opener, b body, e terminator, u unreadable (then stop)."""
    hd, term, dash, out = Heredocs(), None, False, ""
    for line in src.split("\n"):
        try:
            if term is not None:
                if hd.body_line(line, term, dash):
                    term, out = None, out + "e"
                else:
                    out += "b"
                continue
            found = hd.scan(line)
        except ValueError:
            return out + "u"
        if found:
            _, term, dash, _ = found
            out += "o"
        else:
            out += "c"
    return out


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file", help="a shell script")
    a = p.parse_args(argv)
    r = roles(open(a.file, encoding="utf-8", errors="replace").read())
    print(r)
    return 1 if r.endswith("u") else 0


if __name__ == "__main__":
    sys.exit(main())
