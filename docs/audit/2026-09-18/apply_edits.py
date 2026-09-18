#!/usr/bin/env python3
"""Apply a subagent edit set to docs/MANUAL.md.

Reads edits/batch-<N>.json (the shape the consolidation children produce),
validates EVERY row before touching anything — an `old_string` must occur
exactly once — and only then applies the `apply` rows in id order. Applies are
exact-string replacements, so the result is byte-identical to applying the same
pairs one at a time; a validation failure aborts the whole batch with nothing
written.

Usage: apply_edits.py batch-7.json [batch-8.json ...]
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MANUAL = os.path.join(ROOT, "docs", "MANUAL.md")


def main(paths):
    with open(MANUAL, encoding="utf-8") as fh:
        text = fh.read()
    ledger_path = os.path.join(HERE, "edits", "applied-ids.txt")
    done_ids = set()
    if os.path.exists(ledger_path):
        with open(ledger_path, encoding="utf-8") as fh:
            done_ids = {l.strip() for l in fh if l.strip()}
    rows = []
    for p in paths:
        with open(os.path.join(HERE, "edits", p), encoding="utf-8") as fh:
            rows.extend(json.load(fh))

    todo = [r for r in rows if r.get("status") == "apply" and r["id"] not in done_ids]
    todo.sort(key=lambda r: r["id"])

    # ---- validate -----------------------------------------------------------
    problems = []
    for r in todo:
        old, new = r.get("old_string", ""), r.get("new_string", "")
        if not old or not new:
            problems.append("%s: empty old_string/new_string" % r["id"])
            continue
        n = text.count(old)
        if n == 0:
            problems.append("%s: old_string not found" % r["id"])
        elif n > 1:
            problems.append("%s: old_string occurs %d times" % (r["id"], n))
        if old == new:
            problems.append("%s: no-op edit" % r["id"])
    if problems:
        print("ABORT — %d validation problems, nothing written:" % len(problems))
        for p in problems:
            print("  " + p)
        return 2

    # ---- apply --------------------------------------------------------------
    log = []
    for r in todo:
        before = len(text)
        text = text.replace(r["old_string"], r["new_string"], 1)
        log.append("%s %s  %+d bytes  %s" % (
            r["id"], r.get("slice", "?"), len(text) - before,
            (r.get("reason", "") or "")[:80]))
    with open(MANUAL, "w", encoding="utf-8") as fh:
        fh.write(text)
    with open(ledger_path, "a", encoding="utf-8") as fh:
        for r in todo:
            fh.write(r["id"] + "\n")

    name = "+".join(os.path.basename(p).replace(".json", "") for p in paths)
    out = os.path.join(HERE, "edits", "applied-%s.log" % name)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("# applied %s\n\n" % name)
        fh.write("rows applied: %d of %d in the set(s)\n\n" % (len(todo), len(rows)))
        fh.write("\n".join(log) + "\n")
    print("applied %d rows -> %s" % (len(todo), os.path.relpath(out, ROOT)))
    for line in log:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
