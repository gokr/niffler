#!/usr/bin/env python3
"""Split the still-open ledger rows into balanced batches (one per subagent).

Round 1 (`partition.py`) sliced the *whole* worklist into `batch-N.txt`; this
slices only what `status.py` still reports as open, so a second round can be
launched without disturbing the first round's record. Verdicts already recorded
in `edits/batch-*.json` and ids in `edits/applied-ids.txt` are excluded, exactly
as `status.py` counts them.

Usage: partition_open.py [--batches N] [--round NAME]
Writes batch-<NAME>-<i>.txt (one MANUAL-section list per batch) plus
batches-<NAME>.md (the human-readable plan).
"""

import glob
import json
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BATCHES = 8
DEFAULT_ROUND = "open2"


def parse_args(argv):
    batches, name = DEFAULT_BATCHES, DEFAULT_ROUND
    i = 0
    while i < len(argv):
        if argv[i] == "--batches" and i + 1 < len(argv):
            batches = int(argv[i + 1]); i += 2
        elif argv[i] == "--round" and i + 1 < len(argv):
            name = argv[i + 1]; i += 2
        else:
            i += 1
    return batches, name


def load_rows():
    rows = {}
    with open(os.path.join(HERE, "worklist.tsv"), encoding="utf-8") as fh:
        next(fh)
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 10:
                # target = the MANUAL section (the stable anchor); group is the
                # report's own heading, used when target could not be mapped.
                rows[f[0]] = {"id": f[0], "group": f[2], "target": f[3], "cls": f[5]}
    return rows


def load_state():
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
    return verdict, applied


def main(argv):
    nbatches, round_name = parse_args(argv)
    rows = load_rows()
    verdict, applied = load_state()

    # open = no verdict yet, plus the verdicts that still owe work (apply rows
    # whose anchors were superseded and unclear rows are re-decided by hand).
    open_rows = {rid: r for rid, r in rows.items()
                 if rid not in applied and verdict.get(rid, "") not in
                 ("skip", "already", "code")}

    by_section = defaultdict(list)
    for rid, r in sorted(open_rows.items()):
        by_section[r["target"] or r["group"]].append((rid, r["cls"]))

    # Greedy balancing, largest section first — the same shape as round 1, so a
    # child's slice is a handful of whole MANUAL sections and its edit set stays
    # reviewable.
    order = sorted(by_section.items(), key=lambda kv: -len(kv[1]))
    batches = [[] for _ in range(nbatches)]
    totals = [0] * nbatches
    for sec, ids in order:
        i = totals.index(min(totals))
        batches[i].append((sec, ids))
        totals[i] += len(ids)

    for i, b in enumerate(batches, 1):
        with open(os.path.join(HERE, "batch-%s-%d.txt" % (round_name, i)),
                  "w", encoding="utf-8") as fh:
            for sec, ids in b:
                fh.write("%s\t%d\t%s\n" % (sec, len(ids),
                                           ",".join(rid for rid, _ in ids)))

    with open(os.path.join(HERE, "batches-%s.md" % round_name), "w",
              encoding="utf-8") as fh:
        fh.write("# Consolidation batches — round `%s`\n\n" % round_name)
        fh.write("The still-open rows `status.py` reports, split into %d balanced "
                 "batches (one subagent each). Each child writes "
                 "`edits/batch-%s-<N>.json` and validates every anchor itself; "
                 "the parent applies them with `apply_edits.py` after simulating "
                 "the whole round in id order.\n\n" % (nbatches, round_name))
        total = sum(totals)
        fh.write("Total open rows: %d\n\n" % total)
        classes = Counter(c for _, ids in open_rows.items() for _, c in [])
        for i, b in enumerate(batches, 1):
            fh.write("## batch-%s-%d (%d rows)\n\n" % (round_name, i, totals[i - 1]))
            for sec, ids in b:
                klasses = Counter(c for _, c in ids)
                fh.write("- `%s` — %d rows (%s)\n" % (
                    sec, len(ids), ", ".join("%s %d" % (k, v)
                                             for k, v in klasses.most_common())))
            fh.write("\n")
        fh.write("## Class census (all open rows)\n\n")
        for k, v in Counter(r["cls"] for r in open_rows.values()).most_common():
            fh.write("- %s: %d\n" % (k, v))
    print("open rows: %d across %d sections -> %d batches" %
          (len(open_rows), len(by_section), nbatches))
    for i, t in enumerate(totals, 1):
        print("  batch-%s-%d: %d rows" % (round_name, i, t))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
