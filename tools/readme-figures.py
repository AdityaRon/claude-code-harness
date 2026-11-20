#!/usr/bin/env python3
"""README.md's numbers and figures, from docs/data/readme-numbers.json.

The JSON holds every number the README's generated blocks and the SVGs in
docs/figures/ show. Its summary rows are entered by hand, each with where it
was measured. Its series are read from CHANGELOG.md, from the release the JSON
cites down to v1.0.0, so a newer release's entry changes nothing here: the
README cites one named release and is refreshed by hand (move cited_release,
then --write). Stdlib only, and Python 3.9, macOS's /usr/bin/python3.

  python3 tools/readme-figures.py --write   # series from CHANGELOG.md, then README blocks and SVGs
  python3 tools/readme-figures.py --check   # exit 1 naming each file --write would change
"""
import argparse
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
DATA = "docs/data/readme-numbers.json"
README = "README.md"
CHANGELOG = "CHANGELOG.md"
FIGURES = "docs/figures"

ENTRY_RE = re.compile(r"^## (v\d+\.\d+\.\d+) \((\d{4}-\d{2}-\d{2})\)\s*$")
BASE_RE = re.compile(r"^### Benchmark vs (v\d+\.\d+\.\d+)\s*$")
RUN_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z), (.+?), python [\d.]+\. ")
PAIR_RE = re.compile(r"^([\d.]+) → ([\d.]+)")


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def pair(cell, what):
    m = PAIR_RE.match(cell)
    if not m:
        raise SystemExit("readme-figures: no base → head pair in %s: %r" % (what, cell))
    return float(m.group(1)), float(m.group(2))


def entries(text, cited):
    """CHANGELOG entries from `cited` down to the oldest, oldest first."""
    out, cur = [], None
    for line in text.splitlines():
        m = ENTRY_RE.match(line)
        if m:
            cur = {"release": m.group(1), "date": m.group(2), "lines": []}
            out.append(cur)
        elif cur is not None:
            cur["lines"].append(line)
    names = [e["release"] for e in out]
    if cited not in names:
        raise SystemExit("readme-figures: %s has no entry for %s" % (CHANGELOG, cited))
    return list(reversed(out[names.index(cited):]))


def bench(entry):
    """The entry's first benchmark run: its Bash row, and bash-guards.sh's execs row."""
    lines, base, run, bash, execs = entry["lines"], None, None, None, None
    for i, line in enumerate(lines):
        m = BASE_RE.match(line)
        if m and base is None:
            base = m.group(1)
        m = RUN_RE.match(line)
        if m and bash is None:
            run = (m.group(1), m.group(2), "together" if "launched together" in line else "one at a time")
        if line.startswith("| Bash |") and bash is None:
            bash = cells(line)
        if "| execs per payload |" in line and execs is None:
            for row in lines[i + 1:]:
                if not row.startswith("|"):
                    break
                if row.startswith("| bash-guards.sh |"):
                    execs = cells(row)
                    break
    skipped = any("benchmark skipped" in line for line in lines)
    return base, run, bash, execs, skipped


def extract(changelog, cited, anchor):
    """The series the charts and evidence tables show, read from CHANGELOG.md."""
    runs, execs, skipped, prev = [], [], [], None
    for e in entries(changelog, cited):
        base, run, bash, ex, was_skipped = bench(e)
        rel = e["release"]
        if bash is None:
            if was_skipped:
                skipped.append(rel)
            prev = rel
            continue
        if base != prev:
            raise SystemExit("readme-figures: %s is benchmarked against %s, not the release before it (%s)"
                             % (rel, base, prev))
        if run is None:
            raise SystemExit("readme-figures: %s has a Bash row but no run line above it" % rel)
        p50 = pair(bash[2], rel + " Bash p50")
        p95 = pair(bash[4], rel + " Bash p95")
        runs.append({
            "release": rel, "date": e["date"], "vs": base, "bash_payloads": int(bash[1]),
            "p50_ms": list(p50), "p95_ms": list(p95),
            "run_at": run[0], "runner": run[1], "hooks_launched": run[2],
        })
        if ex is not None:
            b, h = pair(ex[2], rel + " bash-guards.sh execs")
            execs.append({"release": rel, "date": e["date"], "vs": base, "payloads": int(ex[1]),
                          "execs_per_payload": [b, h], "run_at": run[0], "runner": run[1]})
        prev = rel
    names = [r["release"] for r in runs]
    if anchor not in names:
        raise SystemExit("readme-figures: the index anchor %s has no Bash row" % anchor)
    # Each release's ratio is head over base from one run on one runner; chained,
    # they compare releases measured on different runners. The anchor is 100.
    cum50, cum95, c50, c95 = [], [], 1.0, 1.0
    for r in runs:
        c50 *= r["p50_ms"][1] / r["p50_ms"][0]
        c95 *= r["p95_ms"][1] / r["p95_ms"][0]
        cum50.append(c50)
        cum95.append(c95)
    a = names.index(anchor)
    first = runs[0]
    index = [{"release": first["vs"], "p50": round(100.0 / cum50[a], 1), "p95": round(100.0 / cum95[a], 1)}]
    for i, r in enumerate(runs):
        index.append({"release": r["release"], "p50": round(100.0 * cum50[i] / cum50[a], 1),
                      "p95": round(100.0 * cum95[i] / cum95[a], 1)})
    return {
        "source": "%s, the first benchmark run of each entry from v1.0.0 to %s" % (CHANGELOG, cited),
        "bash_wait_runs": runs,
        "bash_wait_index": index,
        "not_benchmarked": skipped,
        "bash_guards_execs": execs,
    }


# ---------------------------------------------------------------- README blocks

def fmt(v):
    if isinstance(v, str):
        return v
    return ("%d" % v) if isinstance(v, int) else repr(v)


def measured(row):
    return row["measured"].format(**{k: fmt(v) for k, v in row["values"].items()})


def links(pairs):
    return ", ".join("[%s](%s)" % (label, href) for label, href in pairs)


def ms(p, places=1):
    return "%.*f → %.*f" % (places, p[0], places, p[1])


def block_summary(d):
    out = ["| What | Measured | n | Where and when | Details |", "|---|---|---|---|---|"]
    for r in d["summary"]:
        out.append("| **%s** | %s | %s | %s; %s | %s |" % (r["what"], measured(r), r["n"], r["environment"], r["date"],
                                                          links(r["details"])))
    return "\n".join(out)


def block_sources(d):
    out = ["| Row | Source | Command |", "|---|---|---|"]
    for r in d["summary"]:
        out.append("| %s | %s | %s |" % (r["what"], r["source"], r["command"]))
    return "\n".join(out)


def block_wait_table(d):
    s = d["series"]
    idx = {i["release"]: i for i in s["bash_wait_index"]}
    first = s["bash_wait_index"][0]
    out = ["<details><summary>Every release's Bash row, and the index it gives</summary>", "",
           "| Release | vs | Bash payloads | p50 wait, ms | p95 wait, ms | p50 index | p95 index | Hooks launched | Runner |",
           "|---|---|---:|---|---|---:|---:|---|---|",
           "| %s | | | | | %s | %s | | |" % (first["release"], first["p50"], first["p95"])]
    for r in s["bash_wait_runs"]:
        i = idx[r["release"]]
        out.append("| %s | %s | %d | %s | %s | %s | %s | %s | %s |" % (
            r["release"], r["vs"], r["bash_payloads"], ms(r["p50_ms"]), ms(r["p95_ms"]),
            i["p50"], i["p95"], r["hooks_launched"], r["runner"]))
    out += ["", "Not benchmarked, because `hooks/` and `config/settings.json` were unchanged: %s." %
            ", ".join(s["not_benchmarked"]), "", "</details>"]
    return "\n".join(out)


def block_execs_table(d):
    out = ["<details><summary>bash-guards.sh execs per payload, by release</summary>", "",
           "| Release | vs | payloads | execs per payload | Runner |", "|---|---|---:|---|---|"]
    for r in d["series"]["bash_guards_execs"]:
        out.append("| %s | %s | %d | %s | %s |" % (r["release"], r["vs"], r["payloads"],
                                                  ms(r["execs_per_payload"], 2), r["runner"]))
    out += ["", "</details>"]
    return "\n".join(out)


def picture(name, alt, width):
    return "\n".join([
        "<picture>",
        '  <source media="(prefers-color-scheme: dark)" srcset="%s/%s-dark.svg">' % (FIGURES, name),
        '  <img alt="%s" src="%s/%s-light.svg" width="%d">' % (escape(alt, {'"': "&quot;"}), FIGURES, name, width),
        "</picture>"])


def wait_alt(d):
    s = d["series"]
    i = s["bash_wait_index"]
    lo = min(i, key=lambda x: x["p50"])
    return ("Line chart of a Bash call's wait for the guards by release, as a chained index with %s at 100. "
            "p50 runs from %s at %s to %s at %s, lowest %s at %s; p95 from %s to %s. "
            "Each step is one release's same-run ratio on one CI runner, from %s; n is %d to %d Bash payloads a run. "
            "From v1.4.0 the benchmark launches the hooks together; earlier ratios ran them one at a time."
            % (d["index_anchor"], i[0]["p50"], i[0]["release"], i[-1]["p50"], i[-1]["release"], lo["p50"],
               lo["release"], i[0]["p95"], i[-1]["p95"], CHANGELOG,
               min(r["bash_payloads"] for r in s["bash_wait_runs"]),
               max(r["bash_payloads"] for r in s["bash_wait_runs"])))


def execs_alt(d):
    e = d["series"]["bash_guards_execs"]
    return ("Chart of bash-guards.sh execs per payload by release, %s to %s: %s on the release before %s, "
            "%s at %s, with the corpus growing from %d to %d payloads along the way. From the launches tables in %s."
            % (e[0]["release"], e[-1]["release"], "%.2f" % e[0]["execs_per_payload"][0], e[0]["release"],
               "%.2f" % e[-1]["execs_per_payload"][1], e[-1]["release"], e[0]["payloads"], e[-1]["payloads"],
               CHANGELOG))


def wait_caption(d):
    s = d["series"]
    return ("Each point chains one release's ratio, head over base from its entry's first run on one CI runner, "
            "onto the one before; milliseconds differ by runner and are not compared across releases. Source: %s, "
            "the first Bash row of each entry, %s to %s; n = %d to %d Bash payloads a run. %d releases "
            "changed no hook file, were not benchmarked and are left out. From v1.4.0 the benchmark launches the "
            "hooks together; earlier ratios ran them one at a time, so the chain crosses a change in what wait means."
            % (CHANGELOG, s["bash_wait_index"][0]["release"], d["cited_release"],
               min(r["bash_payloads"] for r in s["bash_wait_runs"]),
               max(r["bash_payloads"] for r in s["bash_wait_runs"]), len(s["not_benchmarked"])))


def execs_caption(d):
    e = d["series"]["bash_guards_execs"]
    return ("Execs are execve calls past bash-guards.sh's own bash, each payload run once under strace -f. "
            "On the same corpus the count matched across runners, so these compare across releases where "
            "the corpus did not change. Source: %s launches tables, %s (the first) to %s; n = %d to %d payloads a run. "
            "Per-shape budgets: tests/guard-execs.test.sh."
            % (CHANGELOG, e[0]["release"], d["cited_release"],
               min(r["payloads"] for r in e), max(r["payloads"] for r in e)))


def wait_source(d):
    s = d["series"]
    return ("Source: %s, the first Bash row of each entry, %s to %s. n = %d to %d Bash payloads a run, the "
            "entry's first run; each step is head over base on one runner, chained."
            % (CHANGELOG, s["bash_wait_index"][0]["release"], d["cited_release"],
               min(r["bash_payloads"] for r in s["bash_wait_runs"]),
               max(r["bash_payloads"] for r in s["bash_wait_runs"])))


def execs_source(d):
    e = d["series"]["bash_guards_execs"]
    return ("Source: %s launches tables, %s to %s, each payload once under strace -f. n = %d to %d payloads a run, "
            "the entry's first run." % (CHANGELOG, e[0]["release"], d["cited_release"],
                                      min(r["payloads"] for r in e), max(r["payloads"] for r in e)))


def blocks(d):
    return {
        "hero": picture("hero", hero_alt(guards()), 880),
        "summary": block_summary(d),
        "figure-wait": picture("bash-wait-index", wait_alt(d), 880) + "\n\n" + wait_caption(d),
        "table-wait": block_wait_table(d),
        "figure-execs": picture("bash-guards-execs", execs_alt(d), 880) + "\n\n" + execs_caption(d),
        "table-execs": block_execs_table(d),
        "sources": block_sources(d),
    }


def fill(readme, generated):
    for name, body in generated.items():
        begin, end = "<!-- readme-figures:%s:begin -->" % name, "<!-- readme-figures:%s:end -->" % name
        if readme.count(begin) != 1 or readme.count(end) != 1:
            raise SystemExit("readme-figures: %s needs exactly one %s ... %s pair" % (README, begin, end))
        head, rest = readme.split(begin)
        _, tail = rest.split(end)
        readme = head + begin + "\n" + body + "\n" + end + tail
    return readme


# ---------------------------------------------------------------- SVG

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
THEMES = {
    "light": {"bg": "#ffffff", "border": "#d0d7de", "ink": "#1f2328", "muted": "#59636e",
              "grid": "#e4e8ec", "axis": "#8c959f", "s1": "#2a78d6", "s2": "#eb6834"},
    "dark": {"bg": "#0d1117", "border": "#30363d", "ink": "#e6edf3", "muted": "#9198a1",
             "grid": "#21262d", "axis": "#6e7681", "s1": "#3987e5", "s2": "#d95926"},
}


def n(x):
    return ("%.1f" % x).rstrip("0").rstrip(".")


class Svg:
    def __init__(self, w, h, title, desc, t):
        self.w, self.h, self.t = w, h, t
        self.parts = [
            '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" '
            'aria-labelledby="t d" font-family="%s">' % (w, h, w, h, escape(FONT, {'"': "&quot;"})),
            '<title id="t">%s</title>' % escape(title),
            '<desc id="d">%s</desc>' % escape(desc),
            '<rect x="0.5" y="0.5" width="%d" height="%d" rx="6" fill="%s" stroke="%s"/>' % (w - 1, h - 1, t["bg"], t["border"]),
        ]

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=13, fill=None, weight=None, anchor=None, rotate=None):
        attrs = 'x="%s" y="%s" font-size="%d" fill="%s"' % (n(x), n(y), size, fill or self.t["ink"])
        if weight:
            attrs += ' font-weight="%s"' % weight
        if anchor:
            attrs += ' text-anchor="%s"' % anchor
        if rotate is not None:
            attrs += ' transform="rotate(%s %s %s)"' % (n(rotate), n(x), n(y))
        self.add("<text %s>%s</text>" % (attrs, escape(s)))

    def line(self, x1, y1, x2, y2, stroke, width=1, dash=None, cap=None):
        a = 'x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"' % (n(x1), n(y1), n(x2), n(y2), stroke, n(width))
        if dash:
            a += ' stroke-dasharray="%s"' % dash
        if cap:
            a += ' stroke-linecap="%s"' % cap
        self.add("<line %s/>" % a)

    def done(self):
        return "\n".join(self.parts + ["</svg>"]) + "\n"


def wrap(s, size, width):
    """Lines of s that fit width at size, by a 0.55 em average glyph."""
    per = max(10, int(width / (size * 0.55)))
    out, cur = [], ""
    for word in s.split():
        if cur and len(cur) + 1 + len(word) > per:
            out.append(cur)
            cur = word
        else:
            cur = (cur + " " + word) if cur else word
    if cur:
        out.append(cur)
    return out


def ticks(lo, hi, step):
    a = int(lo // step) * step
    b = int(-(-hi // step)) * step
    return [a + i * step for i in range(int((b - a) / step) + 1)]


def marker(svg, x, y, shape, color, hollow=False):
    t = svg.t
    fill = t["bg"] if hollow else color
    ring = "2" if hollow else "1.5"
    if shape == "square":
        svg.add('<rect x="%s" y="%s" width="9" height="9" rx="1.5" fill="%s" stroke="%s" stroke-width="%s"/>'
                % (n(x - 4.5), n(y - 4.5), fill, color if hollow else t["bg"], ring))
    else:
        svg.add('<circle cx="%s" cy="%s" r="%s" fill="%s" stroke="%s" stroke-width="%s"/>'
                % (n(x), n(y), "4.5" if hollow else "5", fill, color if hollow else t["bg"], ring))


def chart_wait(d, theme):
    t = THEMES[theme]
    s = d["series"]
    idx = s["bash_wait_index"]
    runs = {r["release"]: r for r in s["bash_wait_runs"]}
    W, L, R, T = 880, 64, 116, 112
    PH = 250
    cap_lines = wrap(wait_source(d), 13, W - 48)
    H = T + 14 + PH + 72 + 26 + (len(cap_lines) - 1) * 18 + 22
    svg = Svg(W, H, "Bash call wait for the guards, by release (chained index, %s = 100)" % d["index_anchor"],
              wait_alt(d), t)
    svg.text(24, 32, "A Bash call's wait for the guards, by release", size=17, weight="600")
    svg.text(24, 54, "Chained index, %s = 100. Lower is faster." % d["index_anchor"], size=13, fill=t["muted"])
    # Legend: two series, each with its marker, and the corpus marker.
    lx, ly = 24, 80
    for label, color, shape in (("p50 wait", t["s1"], "circle"), ("p95 wait", t["s2"], "square")):
        svg.line(lx, ly, lx + 22, ly, color, 2.5, cap="round")
        marker(svg, lx + 11, ly, shape, color)
        svg.text(lx + 30, ly + 4.5, label, size=13)
        lx += 30 + len(label) * 7.2 + 22
    svg.line(lx + 4, ly - 8, lx + 4, ly + 8, t["axis"], 1, dash="2 3")
    svg.text(lx + 12, ly + 4.5, "corpus grew to N Bash payloads", size=13)
    lx += 12 + 30 * 7 + 22
    svg.line(lx + 4, ly - 8, lx + 4, ly + 8, t["muted"], 1.5, dash="6 3")
    svg.text(lx + 12, ly + 4.5, "hooks launched together from here", size=13)
    vals = [v for i in idx for v in (i["p50"], i["p95"])]
    ys = ticks(min(vals) - 1, max(vals) + 1, 10)
    x0, x1, y0, y1 = L, W - R, T + 14, T + 14 + PH
    def X(k):
        return x0 + (x1 - x0) * k / (len(idx) - 1)
    def Y(v):
        return y1 - (y1 - y0) * (v - ys[0]) / (ys[-1] - ys[0])
    for v in ys:
        svg.line(x0, Y(v), x1, Y(v), t["grid"], 1)
        svg.text(x0 - 8, Y(v) + 4, "%d" % v, size=13, fill=t["muted"], anchor="end")
    svg.text(18, (y0 + y1) / 2, "index (%s = 100)" % d["index_anchor"], size=13, fill=t["muted"], anchor="middle",
             rotate=-90)
    svg.line(x0, Y(100), x1, Y(100), t["axis"], 1)
    # Corpus growth and the change of method: vertical rules with short labels.
    prev_n, prev_m, stagger = None, None, 0
    for k, i in enumerate(idx):
        r = runs.get(i["release"])
        if r is None:
            continue
        if prev_n is not None and r["bash_payloads"] != prev_n:
            svg.line(X(k), y0, X(k), y1, t["axis"], 1, dash="2 3")
            svg.text(X(k), y0 - 4 - 13 * (stagger % 2), "%d" % r["bash_payloads"], size=11, fill=t["muted"], anchor="middle")
            stagger += 1
        if prev_m is not None and r["hooks_launched"] != prev_m:
            svg.line(X(k), y0, X(k), y1, t["muted"], 1.5, dash="6 3")
        prev_n, prev_m = r["bash_payloads"], r["hooks_launched"]
    for key, color, shape in (("p95", t["s2"], "square"), ("p50", t["s1"], "circle")):
        pts = " ".join("%s,%s" % (n(X(k)), n(Y(i[key]))) for k, i in enumerate(idx))
        svg.add('<polyline points="%s" fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round"/>' % (pts, color))
        for k, i in enumerate(idx):
            marker(svg, X(k), Y(i[key]), shape, color)
    # Direct labels at the right end, in ink, beside the last marker.
    last = idx[-1]
    a, b = Y(last["p50"]), Y(last["p95"])
    if abs(a - b) < 16:
        a, b = (a - 8, b + 8) if a <= b else (a + 8, b - 8)
    svg.text(x1 + 12, a + 4.5, "p50 %s" % last["p50"], size=13, weight="600")
    svg.text(x1 + 12, b + 4.5, "p95 %s" % last["p95"], size=13, weight="600")
    for k, i in enumerate(idx):
        svg.text(X(k) + 4, y1 + 14, i["release"], size=12, fill=t["muted"], anchor="end", rotate=-50)
    svg.text((x0 + x1) / 2, y1 + 72, "release (only those whose hook files changed)", size=13, fill=t["muted"],
             anchor="middle")
    yc = y1 + 72 + 26
    for k, ln in enumerate(cap_lines):
        svg.text(24, yc + k * 18, ln, size=13, fill=t["muted"])
    return svg.done()


def chart_execs(d, theme):
    t = THEMES[theme]
    e = d["series"]["bash_guards_execs"]
    W, L, R, T, PH = 880, 64, 40, 100, 220
    cap_lines = wrap(execs_source(d), 13, W - 48)
    H = T + 20 + PH + 70 + (len(cap_lines) - 1) * 18 + 22
    svg = Svg(W, H, "bash-guards.sh execs per payload, by release", execs_alt(d), t)
    svg.text(24, 32, "Processes bash-guards.sh starts per payload, by release", size=17, weight="600")
    svg.text(24, 54, "execve calls per payload. Each release is measured against the one before, in one run.",
             size=13, fill=t["muted"])
    lx, ly = 24, 80
    marker(svg, lx + 5, ly, "circle", t["s1"], hollow=True)
    svg.text(lx + 16, ly + 4.5, "release before, same run", size=13)
    lx += 16 + 24 * 7.2 + 22
    marker(svg, lx + 5, ly, "circle", t["s1"])
    svg.text(lx + 16, ly + 4.5, "this release", size=13)
    lx += 16 + 12 * 7.2 + 22
    svg.line(lx + 4, ly - 8, lx + 4, ly + 8, t["axis"], 1, dash="2 3")
    svg.text(lx + 12, ly + 4.5, "corpus changed", size=13)
    vals = [v for r in e for v in r["execs_per_payload"]]
    ys = ticks(min(vals) - 0.5, max(vals) + 0.5, 1)
    x0, x1, y0, y1 = L, W - R, T + 20, T + 20 + PH
    slot = (x1 - x0) / len(e)
    def Y(v):
        return y1 - (y1 - y0) * (v - ys[0]) / (ys[-1] - ys[0])
    for v in ys:
        svg.line(x0, Y(v), x1, Y(v), t["grid"], 1)
        svg.text(x0 - 8, Y(v) + 4, "%d" % v, size=13, fill=t["muted"], anchor="end")
    svg.text(18, (y0 + y1) / 2, "execs per payload", size=13, fill=t["muted"], anchor="middle", rotate=-90)
    prev = None
    for k, r in enumerate(e):
        cx = x0 + slot * (k + 0.5)
        bx, hx = cx - slot * 0.22, cx + slot * 0.22
        b, h = r["execs_per_payload"]
        if prev is not None:
            px, ph, pn = prev
            if pn == r["payloads"] and ph == b:
                svg.line(px, Y(ph), bx, Y(b), t["axis"], 1.5)
            else:
                mx = (px + bx) / 2
                svg.line(mx, y0, mx, y1, t["axis"], 1, dash="2 3")
                svg.text(mx, y0 - 6, "%d → %d payloads" % (pn, r["payloads"]), size=12, fill=t["muted"], anchor="middle")
        svg.line(bx, Y(b), hx, Y(h), t["s1"], 2.5, cap="round")
        marker(svg, bx, Y(b), "circle", t["s1"], hollow=True)
        marker(svg, hx, Y(h), "circle", t["s1"])
        if prev is None or prev[1] != b:
            svg.text(bx - 9, Y(b) + 4.5, "%.2f" % b, size=12, fill=t["muted"], anchor="end")
        svg.text(hx, Y(h) + (20 if h < b else -12), "%.2f" % h, size=13, weight="600", anchor="middle")
        svg.text(cx, y1 + 22, r["release"], size=13, fill=t["muted"], anchor="middle")
        prev = (hx, h, r["payloads"])
    svg.text((x0 + x1) / 2, y1 + 44, "release (launches tables start at %s)" % e[0]["release"], size=13,
             fill=t["muted"], anchor="middle")
    yc = y1 + 70
    for k, ln in enumerate(cap_lines):
        svg.text(24, yc + k * 18, ln, size=13, fill=t["muted"])
    return svg.done()


SESSION_HOOKS = (("session-start", "at session start"), ("pre-compact", "before compaction"),
                 ("memory-lint", "after a memory write"), ("audit", "every event, logged"))


def guards():
    """The Bash guards bash-guards.sh forks, in its order, and the session hooks the hero shows."""
    m = re.search(r"^BG_GUARDS=\((.*)\)$", (ROOT / "hooks/bash-guards.sh").read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit("readme-figures: no BG_GUARDS=(...) line in hooks/bash-guards.sh")
    for name, _ in SESSION_HOOKS:
        if not (ROOT / "hooks" / (name + ".sh")).exists():
            raise SystemExit("readme-figures: hooks/%s.sh is gone; the hero still draws it" % name)
    return m.group(1).split()


def hero_alt(names):
    return ("Diagram of one Bash call, left to right. The call goes to bash-guards, a dispatcher that parses it "
            "once with jq and forks the %d Bash guards in parallel: %s. Their answers merge, deny over ask over "
            "allow, and a deny ends the call there. Otherwise it goes on to Claude Code's permission rules, then to "
            "auto mode's classifier, which decides by judgment what no guard or rule names. A separate lane below "
            "holds the session hooks, which are off the Bash path: %s."
            % (len(names), ", ".join(names[:-1]) + " and " + names[-1],
               ", ".join("%s (%s)" % h for h in SESSION_HOOKS)))


def box(svg, x, y, w, h, lines, fill=None, stroke=None, dash=None, rx=8):
    t = svg.t
    a = 'x="%s" y="%s" width="%s" height="%s" rx="%d" fill="%s" stroke="%s" stroke-width="1.5"' % (
        n(x), n(y), n(w), n(h), rx, fill or t["box"], stroke or t["border"])
    if dash:
        a += ' stroke-dasharray="%s"' % dash
    svg.add("<rect %s/>" % a)
    step = 17
    top = y + h / 2 - (len(lines) - 1) * step / 2 + 4.5
    for k, (text, size, weight, color) in enumerate(lines):
        svg.text(x + w / 2, top + k * step, text, size=size, fill=color or t["ink"], weight=weight, anchor="middle")


def arrow(svg, x1, y1, x2, y2, color, width=1.5):
    svg.add('<path d="M%s %s L%s %s" stroke="%s" stroke-width="%s" fill="none" marker-end="url(#head)"/>'
            % (n(x1), n(y1), n(x2), n(y2), color, n(width)))


def chart_hero(names, theme):
    t = dict(THEMES[theme])
    t["box"] = "#f6f8fa" if theme == "light" else "#161b22"
    W, H = 880, 404
    svg = Svg(W, H, "One Bash call through the harness", hero_alt(names), t)
    svg.add('<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="%s"/></marker></defs>' % t["axis"])
    svg.text(24, 32, "One Bash call, left to right", size=17, weight="600")
    mid = 172
    ink, muted, accent = t["ink"], t["muted"], t["s1"]
    # The call, and the dispatcher's one parse.
    box(svg, 16, mid - 30, 92, 60, [("Bash call", 15, "600", None), ("from Claude", 13, None, muted)])
    box(svg, 132, mid - 42, 126, 84, [("bash-guards", 15, "600", None), ("one jq parse,", 13, None, muted),
                                      ("then a fork", 13, None, muted), ("per guard", 13, None, muted)],
        stroke=accent)
    arrow(svg, 108, mid, 130, mid, t["axis"])
    # The guards, in parallel.
    gx, gw, gh, gap = 292, 140, 26, 6
    top = mid - (len(names) * (gh + gap) - gap) / 2
    svg.text(gx + gw / 2, top - 12, "%d guards, in parallel" % len(names), size=14, fill=muted, anchor="middle")
    for k, name in enumerate(names):
        y = top + k * (gh + gap)
        box(svg, gx, y, gw, gh, [(name, 14, None, None)], rx=6)
        spread = (k - (len(names) - 1) / 2) * 9
        arrow(svg, 258, mid + spread, gx - 2, y + gh / 2, t["axis"], 1.2)
        arrow(svg, gx + gw, y + gh / 2, 466, mid + spread, t["axis"], 1.2)
    # The merge, then Claude Code.
    box(svg, 468, mid - 42, 146, 84, [("deny > ask > allow", 14, "600", None), ("strongest answer", 13, None, muted),
                                      ("wins; a deny", 13, None, muted), ("ends the call", 13, None, muted)],
        stroke=accent)
    arrow(svg, 614, mid, 640, mid, t["axis"])
    box(svg, 642, mid - 86, 222, 172, [], stroke=t["border"])
    svg.text(753, mid - 62, "Claude Code", size=15, weight="600", anchor="middle")
    box(svg, 656, mid - 46, 194, 46, [("permission rules", 14, "600", None), ("deny, ask, allow lists", 13, None, muted)],
        fill=t["bg"], rx=6)
    arrow(svg, 753, mid, 753, mid + 14, t["axis"])
    box(svg, 656, mid + 16, 194, 46, [("auto mode classifier", 14, "600", None),
                                      ("the rest, by judgment", 13, None, muted)], fill=t["bg"], rx=6)
    # The session hooks, off the Bash path.
    ly, lh = 318, 66
    box(svg, 16, ly, 848, lh, [], fill=t["bg"], dash="5 4")
    svg.text(30, ly + 29, "Session hooks", size=14, weight="600")
    svg.text(30, ly + 47, "off the Bash path", size=13, fill=muted)
    px, pw = 192, 156
    for k, (name, when) in enumerate(SESSION_HOOKS):
        box(svg, px + k * (pw + 12), ly + 12, pw, lh - 24, [(name, 14, "600", None), (when, 13, None, muted)], rx=6)
    return svg.done()


def figures(d):
    out = {}
    names = guards()
    for theme in ("light", "dark"):
        out["%s/hero-%s.svg" % (FIGURES, theme)] = chart_hero(names, theme)
        out["%s/bash-wait-index-%s.svg" % (FIGURES, theme)] = chart_wait(d, theme)
        out["%s/bash-guards-execs-%s.svg" % (FIGURES, theme)] = chart_execs(d, theme)
    return out


# ---------------------------------------------------------------- main

def build():
    data_text = (ROOT / DATA).read_text(encoding="utf-8")
    d = json.loads(data_text)
    d["series"] = extract((ROOT / CHANGELOG).read_text(encoding="utf-8"), d["cited_release"], d["index_anchor"])
    files = {DATA: json.dumps(d, indent=2, ensure_ascii=False) + "\n"}
    files[README] = fill((ROOT / README).read_text(encoding="utf-8"), blocks(d))
    files.update(figures(d))
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="write the JSON's series, README.md's blocks and the SVGs")
    g.add_argument("--check", action="store_true", help="exit 1 naming each file --write would change")
    args = ap.parse_args()
    files = build()
    stale = []
    for rel, text in files.items():
        p = ROOT / rel
        old = p.read_text(encoding="utf-8") if p.exists() else None
        if old == text:
            continue
        stale.append(rel)
        if args.write:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
    known = set(files)
    orphans = sorted(str(p.relative_to(ROOT)) for p in (ROOT / FIGURES).glob("*.svg")
                     if str(p.relative_to(ROOT)) not in known) if (ROOT / FIGURES).is_dir() else []
    if args.write:
        print("readme-figures: wrote %s" % (", ".join(stale) if stale else "nothing; all current"))
        for o in orphans:
            print("readme-figures: %s is not one this tool writes" % o)
        return 0
    for rel in stale:
        print("readme-figures: %s differs from what --write makes" % rel)
    for o in orphans:
        print("readme-figures: %s is not one this tool writes" % o)
    return 1 if stale or orphans else 0


if __name__ == "__main__":
    sys.exit(main())
