#!/usr/bin/env python3
"""Split the worklist slices into balanced batches (one per subagent)."""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SEC = os.path.join(HERE, "sections")
MINE = {"layout-of-a-running-system", "state-and-configuration"}
NBATCH = 8

slices = []
for name in sorted(os.listdir(SEC)):
    slug = name[:-3]
    with open(os.path.join(SEC, name), encoding="utf-8") as fh:
        n = len(re.findall(r"^## A", fh.read(), re.M))
    slices.append((slug, n))

slices.sort(key=lambda s: -s[1])
batches = [[] for _ in range(NBATCH)]
totals = [0] * NBATCH
for slug, n in slices:
    if slug in MINE:
        continue
    i = totals.index(min(totals))
    batches[i].append((slug, n))
    totals[i] += n

with open(os.path.join(HERE, "batches.md"), "w", encoding="utf-8") as fh:
    fh.write("# Consolidation batches\n\n")
    fh.write("One batch per subagent; each writes an edit set to `edits/batch-N.json`\n")
    fh.write("(plus `edits/batch-N.summary.md`) which the parent applies to `docs/MANUAL.md`.\n")
    fh.write("Handled by the parent: %s.\n\n" % ", ".join(sorted(MINE)))
    for i, b in enumerate(batches, 1):
        fh.write("## batch-%d (%d rows)\n\n" % (i, totals[i - 1]))
        for slug, n in b:
            fh.write("- `sections/%s.md` — %d rows\n" % (slug, n))
        fh.write("\n")
        with open(os.path.join(HERE, "batch-%d.txt" % i), "w", encoding="utf-8") as bf:
            for slug, n in b:
                bf.write("%s\t%d\n" % (slug, n))
print("batches:", [(i + 1, t) for i, t in enumerate(totals)])
