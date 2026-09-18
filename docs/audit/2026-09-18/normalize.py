#!/usr/bin/env python3
"""Normalize the 2026-09-18 docs-audit reports into one worklist.

Input: the reports in this directory (two shapes — the ``- MANUAL: … | CODE: …
| FIX: …`` row format used by most, and the numbered ``DELTA list`` prose format
used by fetch/git/expert/processes). Output: ``worklist.tsv`` (one row per
finding) plus ``worklist-summary.md`` (counts by section and class).

The reports cite MANUAL line numbers from the 2324-line revision; MANUAL.md has
since moved, so the section is the stable anchor and the line numbers are only
hints. Sections are mapped onto the current ``## `` headings of MANUAL.md.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MANUAL = os.path.join(ROOT, "docs", "MANUAL.md")

REPORTS = [
    "mechanisms-full.md",
    "mechanisms.md",
    "mechanisms-sessions.md",
    "mechanisms-obs.md",
    "config.md",
    "components/agent.md",
    "components/bash.md",
    "components/edit.md",
    "components/expert.md",
    "components/fabric.md",
    "components/fetch.md",
    "components/git.md",
    "components/llm.md",
    "components/lsp.md",
    "components/mcp.md",
    "components/models.md",
    "components/plugins.md",
    "components/processes.md",
    "components/provider.md",
    "components/repomap.md",
    "components/skills.md",
]

ROW = re.compile(r"^- (MANUAL|CODE|FIX|FILE|DOC):?\s*(.*)$")
ROW_FIX = re.compile(r"^(.*?)\s*\|\s*CODE:\s*(.*?)\s*\|\s*FIX:\s*(.*)$")
NUM = re.compile(r"^(\d+)\.\s+(.*)$")
HEAD = re.compile(r"^##\s+(.*)$")
SECT_LINES = re.compile(
    r"\s*\((?:\d+[\s,–-]*)+lines?\)\s*$"
    r"|\s*\(\d+[–-]\d+\)\s*$"
    r"|\s*\(lines? [\d,\s–-]+\)\s*$"
    r"|\s*\((?:MANUAL|manual)[^)]*\)\s*$"
    r"|\s*\bMANUAL\s+\d+(?:[–,-]\d+)?\b.*$"
    r"|\s*\((?:old )?lines?\b[^)]*\)\s*$"
)


def strip_fmt(s):
    return s.replace("**", "").replace("`", "").strip()


def sections_of(manual):
    """Current MANUAL.md headings in order: [(line, title)]."""
    out = []
    with open(manual, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            m = HEAD.match(line)
            if m:
                out.append((n, strip_fmt(m.group(1))))
    return out


def norm_section(s):
    s = strip_fmt(s)
    s = re.sub(r"^§+", "", s)
    s = SECT_LINES.sub("", s)
    s = s.split(" — ")[0].split(" - ")[0]
    s = re.sub(r"\s+", " ", s).strip(" ,;:")
    return s


def key(s):
    return re.sub(r"[^a-z0-9]+", "", norm_section(s).lower())


def map_section(raw, current):
    """Map a report section name onto a current MANUAL heading (best effort)."""
    k = key(raw)
    if not k:
        return "", ""
    for line, title in current:
        if key(title) == k:
            return title, str(line)
    for line, title in current:
        a, b = key(title), k
        core = a[3:] if a.startswith("the") else a
        if core and (core in b or b in a):
            return title, str(line)
    return norm_section(raw), ""


def classify(section, fix, manual="", kind="row"):
    f = fix.lower()
    s = section.lower()
    text = (fix or manual).lower()
    if re.search(r"\bfix:\s*none\b", f) or f.strip() in ("none", "none."):
        return "verified"
    if kind == "num" and not fix:
        if "wrong claim" in text or "does not exist" in text or "dead" in text:
            return "wrong"
        if "code bug" in text or "unreferenced" in text:
            return "code-bug?"
        return "doc-edit"
    if not fix and not manual:
        return "prose"
    if "code bug" in f or "implement" in f or "either " in f and " or " in f:
        return "code-bug?"
    if re.match(r"^\(z\)", s) or "pointer" in f or "trim" in f:
        return "trim"
    if re.match(r"^\(x\)", s):
        return "wrong"
    if re.match(r"^\(y\)", s):
        return "missing"
    if not fix:
        return "delta"
    return "doc-edit"


def parse_report(path):
    """Yield dicts: section, manual, code, fix, dup, kind."""
    rel = os.path.relpath(path, HERE)
    component = rel.startswith("components/")
    section = "component: " + os.path.basename(rel)[:-3] if component else ""
    subsection = ""
    numbered = re.compile(r"^[1-9]\.\s")
    pending = []
    rows = []
    pending_kind = "row"

    def flush():
        if not pending:
            return
        text = " ".join(pending).strip()
        pending.clear()
        m = ROW_FIX.match(text)
        if m:
            manual, code, fix = m.group(1), m.group(2), m.group(3)
        else:
            parts = text.split(" | ")
            manual = parts[0] if parts else text
            code = parts[1] if len(parts) > 1 else ""
            fix = parts[2] if len(parts) > 2 else ""
        if pending_kind == "num" and not fix:
            manual, code, fix = text, "", ""
        dup = ""
        for m2 in re.finditer(r"`?\[dup\]`?\s*([A-Za-z0-9_.\-§ ]+)?", manual + " " + fix):
            dup = (m2.group(1) or "").strip()
        rows.append(
            {
                "source": rel,
                "section": section,
                "subsection": subsection,
                "manual": manual.strip(),
                "code": code.strip(),
                "fix": fix.strip(),
                "dup": dup,
                "kind": pending_kind,
            }
        )

    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for line in lines:
        m = HEAD.match(line)
        if m:
            flush()
            title = strip_fmt(m.group(1))
            if numbered.match(title) or title.startswith("### "):
                subsection = title  # prose heading inside a report
            else:
                subsection = ""
                if not component or not title.lower().startswith("audit"):
                    section = title if not component else section
            continue
        if line.startswith("- ") and re.match(r"^- (MANUAL|CODE|FIX)\b", line):
            flush()
            pending_kind = "row"
            pending.append(line[2:].strip())
            continue
        if pending and (line.startswith("  ") or line.startswith("\t")):
            pending.append(line.strip())
            continue
        if pending:
            flush()
        m = NUM.match(line)
        if m and section:
            flush()
            pending_kind = "num"
            pending.append(m.group(2).strip())
            continue
    flush()
    return rows


QUOTE = re.compile(r'"([^"]{18,240})"')
BACKTICK = re.compile(r"`([^`]{14,240})`")


def manual_index(path):
    """Current MANUAL.md: (lines, [(line, title)]) for text re-anchoring."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    return lines, sections_of(path)


def reanchor(row, mlines, mheads):
    """Find the quoted MANUAL text in the CURRENT manual.

    Line numbers in the reports refer to the 2324-line revision; a quoted
    string is the durable anchor. Returns (section_title, heading_line,
    hit_line) or ("", "", "").
    """
    text = row["manual"] + " " + row["fix"]
    cands = QUOTE.findall(text) + BACKTICK.findall(text)
    cands = [re.sub(r"\s+", " ", c).strip() for c in cands]
    cands = [c for c in cands if len(c) >= 18 and not c.startswith(("--", "NIF_", "http"))]
    cands.sort(key=len, reverse=True)
    for cand in cands:
        needle = re.sub(r"\s+", " ", cand)
        for i, line in enumerate(mlines):
            if needle.lower() in re.sub(r"\s+", " ", line).lower():
                title, hline = "", ""
                for hl, ht in mheads:
                    if hl <= i + 1:
                        title, hline = ht, hl
                return title, str(hline), str(i + 1)
    return "", "", ""


def main():
    current = sections_of(MANUAL)
    mlines, mheads = manual_index(MANUAL)
    out = []
    seq = 0
    for rep in REPORTS:
        path = os.path.join(HERE, rep)
        if not os.path.exists(path):
            print("missing report:", rep, file=sys.stderr)
            continue
        for r in parse_report(path):
            seq += 1
            title, line = map_section(r["section"], current)
            anchor_title, anchor_head, anchor_line = reanchor(r, mlines, mheads)
            cls = classify(r["section"], r["fix"], r["manual"], r["kind"])
            if r["kind"] == "row" and not r["fix"] and not r["code"] and not r["manual"]:
                cls = "prose"
            if anchor_title and r["source"].startswith("components/"):
                target = anchor_title
            elif anchor_title:
                target = anchor_title or title
            else:
                target = title
            out.append(
                {
                    "id": "A%03d" % seq,
                    "source": r["source"],
                    "group": r["section"],
                    "target": target,
                    "target_line": anchor_line or line,
                    "class": cls,
                    "manual": r["manual"],
                    "code": r["code"],
                    "fix": r["fix"],
                    "dup": r["dup"],
                }
            )

    fields = ["id", "source", "group", "target", "target_line", "class", "dup", "manual", "code", "fix"]
    with open(os.path.join(HERE, "worklist.tsv"), "w", encoding="utf-8") as fh:
        fh.write("\t".join(fields) + "\n")
        for r in out:
            fh.write(
                "\t".join(
                    re.sub(r"\s+", " ", str(r[f])).replace("\t", " ") for f in fields
                )
                + "\n"
            )

    by_class = {}
    by_section = {}
    for r in out:
        by_class[r["class"]] = by_class.get(r["class"], 0) + 1
        tgt = r["target"] or r["group"] or "(unmapped)"
        by_section.setdefault(tgt, {}).setdefault(r["class"], 0)
        by_section[tgt][r["class"]] += 1

    # Per-section slices: one file per MANUAL heading, so a section can be
    # worked (or delegated to a subagent) on its own.
    secdir = os.path.join(HERE, "sections")
    os.makedirs(secdir, exist_ok=True)
    for name in os.listdir(secdir):
        os.remove(os.path.join(secdir, name))
    slices = {}
    for r in out:
        tgt = r["target"] or r["group"] or "unmapped"
        slices.setdefault(tgt, []).append(r)
    for tgt, rows in slices.items():
        slug = re.sub(r"[^a-z0-9]+", "-", tgt.lower()).strip("-") or "unmapped"
        with open(os.path.join(secdir, slug + ".md"), "w", encoding="utf-8") as fh:
            fh.write("# Worklist slice: %s\n\n" % tgt)
            fh.write("From `worklist.tsv` (%d rows). `class` is one of\n" % len(rows))
            fh.write("verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`\n")
            fh.write("text is the report's quote; its line numbers are the OLD (2324-line)\n")
            fh.write("revision and are hints only.\n\n")
            for r in rows:
                fh.write("## %s (%s%s)\n" % (r["id"], r["class"], ", dup:" + r["dup"] if r["dup"] else ""))
                fh.write("source: `%s`\n\n" % r["source"])
                fh.write("- MANUAL: %s\n" % r["manual"])
                if r["code"]:
                    fh.write("- CODE: %s\n" % r["code"])
                if r["fix"]:
                    fh.write("- FIX: %s\n" % r["fix"])
                fh.write("\n")

    with open(os.path.join(HERE, "worklist-summary.md"), "w", encoding="utf-8") as fh:
        fh.write("# docs-audit worklist — summary\n\n")
        fh.write("Generated by `normalize.py` from the reports in this directory.\n\n")
        fh.write("Classes: `verified` (no change needed), `doc-edit`, `wrong`, `missing`,\n")
        fh.write("`trim` (pointer recommendation), `code-bug?` (the fix is in the code),\n")
        fh.write("`delta` (a finding stated as prose, no `FIX:` line), `prose` (parser\n")
        fh.write("noise — ignore).\n\n")
        fh.write("## By class\n\n")
        for c, n in sorted(by_class.items(), key=lambda kv: -kv[1]):
            fh.write("- %s: %d\n" % (c, n))
        fh.write("\n## By MANUAL section (re-anchored on current MANUAL.md)\n\n")
        for s, counts in sorted(by_section.items(), key=lambda kv: -sum(kv[1].values())):
            total = sum(counts.values())
            detail = ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()))
            fh.write("- **%s** — %d (%s)\n" % (s or "(unmapped)", total, detail))
    print("rows:", len(out), "classes:", by_class)


if __name__ == "__main__":
    main()
