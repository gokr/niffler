#!/usr/bin/env python3
"""Simulate a whole consolidation round against the current MANUAL, before applying.

Round 1 taught two things the hard way: anchors are only proven *within* a batch
(each child checks its own set against a MANUAL no sibling had edited), and a
row's `new_string` can leak drafting apparatus into the manual's prose. Both are
whole-round properties, so they cannot be checked by the child that wrote the
row — this runs on the parent side, on the frozen revision, and refuses to pass
until the round applies cleanly.

What it checks, in id order (the order apply_edits.py uses):
  1. every apply row's `old_string` occurs exactly once in the MANUAL, and still
     does after the earlier rows in the round have been applied (collisions);
  2. no duplicate ids across the round's files;
  3. no drafting apparatus in `new_string` — ledger ids (A123), phrases like
     "this row", "the auditor", "batch-open", mentions of a supersession. The
     manual never carries process notes; round 1 shipped one and it had to be
     repaired by hand;
  4. the MANUAL revision is the one the round was verified against (compares
     edits/anchor-revision.txt), warning loudly when it has moved.

Usage: simulate_round.py [glob ...]        (default: batch-open2-*.json)
Exit: 0 when the round applies cleanly, 1 otherwise.
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANUAL = os.path.abspath(os.path.join(HERE, "..", "..", "MANUAL.md"))

# Phrases that belong to the audit's process, never to the manual's prose.
META = [
    r"\bA\d{3}\b", r"\bthis row\b", r"\bthe row's\b", r"\bthat row\b",
    r"\bthe auditor\b", r"\bbatch-open", r"\bsuperseded\b", r"\boverrode\b",
    r"\bfirst draft\b", r"\bledger\b",
]


def load_round(globs):
    rows, dupes = [], []
    seen = {}
    for pat in globs:
        for path in sorted(glob.glob(os.path.join(HERE, "edits", pat))):
            name = os.path.basename(path)
            try:
                data = json.load(open(path, encoding="utf-8"))
            except Exception as exc:  # a half-written file is a real failure
                print("!! %s is not valid JSON: %s" % (name, exc))
                continue
            for r in data:
                rid = r.get("id", "?")
                if rid in seen:
                    dupes.append("%s in %s and %s" % (rid, seen[rid], name))
                seen[rid] = name
                r["_file"] = name
                rows.append(r)
    return rows, dupes


def main(argv):
    globs = argv or ["batch-open2-*.json"]
    text = open(MANUAL, encoding="utf-8").read()
    before = len(text.splitlines())
    rows, dupes = load_round(globs)
    todo = sorted([r for r in rows if r.get("status") == "apply"],
                  key=lambda r: r.get("id", ""))

    print("round: %s  ->  %d rows, %d to apply" % (", ".join(globs), len(rows), len(todo)))
    problems = 0

    # 4. revision check
    rev = os.path.join(HERE, "edits", "anchor-revision.txt")
    if os.path.exists(rev):
        want = None
        for line in open(rev, encoding="utf-8"):
            if line.startswith("sha256:"):
                want = line.split(":", 1)[1].strip()
        import hashlib
        got = hashlib.sha256(text.encode()).hexdigest()
        if want and got != want:
            print("WARNING: the MANUAL has moved since the round was verified")
            print("   expected %s\n   current  %s" % (want[:16], got[:16]))
            print("   anchors are quotes, so this is usually harmless — but the")
            print("   round's verdict below is against the text as it is NOW.")
        else:
            print("revision: matches %s (unchanged)" % (want or "?")[:16])

    # A batch file written seconds ago is a child still appending to it: the
    # verdict below would be about a revision of the round that no longer
    # exists, and the failures it reports are not real yet.
    import time
    fresh = [os.path.basename(p) for p in
             sum([glob.glob(os.path.join(HERE, "edits", g)) for g in globs], [])
             if time.time() - os.path.getmtime(p) < 120]
    if fresh:
        print("!! still being written (modified <120s ago): %s" % ", ".join(fresh))
        print("   a child is mid-flight; treat any FAILED row below as provisional")
        problems += 1

    if dupes:
        print("!! duplicate ids: %s" % "; ".join(dupes[:5]))
        problems += len(dupes)

    # 3. leakage in the proposed prose
    for r in todo:
        new = r.get("new_string", "") or ""
        hits = sorted({m.lower() for p in META for m in re.findall(p, new, re.I)})
        if hits:
            print("!! %s (%s): new_string carries drafting apparatus: %s"
                  % (r.get("id"), r["_file"], ", ".join(hits)))
            problems += 1

    # 1. the round, applied in id order
    fails = []
    for r in todo:
        old = r.get("old_string", "") or ""
        new = r.get("new_string", "") or ""
        if not old or not new:
            fails.append((r.get("id"), r["_file"], "empty anchor"))
            continue
        n = text.count(old)
        if n != 1:
            fails.append((r.get("id"), r["_file"], "occurs %d times" % n))
            continue
        text = text.replace(old, new, 1)
    after = len(text.splitlines())

    print("apply: %d/%d rows land cleanly; MANUAL %d -> %d lines (%+d)"
          % (len(todo) - len(fails), len(todo), before, after, after - before))
    for rid, fn, why in fails:
        print("   FAILED %s (%s): %s" % (rid, fn, why))
    problems += len(fails)
    if problems:
        print("\n%d problem(s) — the round is not ready to apply" % problems)
        return 1
    print("\nclean: ready to apply with apply_edits.py")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
