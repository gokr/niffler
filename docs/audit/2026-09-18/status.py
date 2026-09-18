#!/usr/bin/env python3
"""Ledger status: what is applied, decided, or still open.

Merges worklist.tsv (every finding), edits/batch-*.json (each child's verdict)
and edits/applied-ids.txt (what actually landed in docs/MANUAL.md), and prints
counts plus the still-open ids grouped by MANUAL section.

Usage: status.py [--open]
"""

import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    rows = {}
    with open(os.path.join(HERE, "worklist.tsv"), encoding="utf-8") as fh:
        next(fh)
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 10:
                rows[f[0]] = {"id": f[0], "source": f[1], "group": f[2],
                              "target": f[3], "class": f[5], "manual": f[7]}

    verdict = {}
    for path in sorted(glob.glob(os.path.join(HERE, "edits", "batch-*.json"))):
        with open(path, encoding="utf-8") as fh:
            for r in json.load(fh):
                verdict[r["id"]] = r.get("status", "?")

    applied = set()
    led = os.path.join(HERE, "edits", "applied-ids.txt")
    if os.path.exists(led):
        with open(led, encoding="utf-8") as fh:
            applied = {l.strip() for l in fh if l.strip()}

    counts = Counter()
    open_by_section = defaultdict(list)
    for rid, r in sorted(rows.items()):
        v = verdict.get(rid)
        if rid in applied:
            counts["applied"] += 1
        elif v == "apply":
            counts["queued-not-applied"] += 1
            open_by_section[r["target"] or r["group"]].append(rid + " (verdict:apply)")
        elif v == "code":
            counts["code"] += 1
        elif v == "unclear":
            counts["unclear"] += 1
            open_by_section[r["target"] or r["group"]].append(rid + " (unclear)")
        elif v in ("skip", "already"):
            counts["decided:" + v] += 1
        else:
            counts["open"] += 1
            open_by_section[r["target"] or r["group"]].append(rid + " [" + r["class"] + "]")

    print("ledger rows: %d" % len(rows))
    for k, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print("  %-22s %d" % (k, n))

    if "--open" in sys.argv:
        print("\nstill open, by section:")
        for sec, ids in sorted(open_by_section.items(), key=lambda kv: -len(kv[1])):
            print("  %-45s %2d  %s" % (sec[:45], len(ids), ", ".join(ids[:6]) +
                                       (" …" if len(ids) > 6 else "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
