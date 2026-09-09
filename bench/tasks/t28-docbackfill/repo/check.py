"""Normative spec: every .go file in alpha/, beta/, gamma/ must carry its
package's exact doc comment as the FIRST line, directly above the package
clause, exactly once. The comment text is fixed per package (see README.md):
  alpha: %s
  beta:  %s
  gamma: %s
Files that already carried it must be byte-identical apart from nothing at all;
files that lacked it (or carried a drifted variant) must now carry the exact line.
""" % (
    "alpha-comment", "beta-comment", "gamma-comment")
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent
COMMENTS = {
    "alpha": "// Package alpha provides weighted moving-average primitives.",
    "beta":  "// Package beta implements deterministic token-bucket rate limiting.",
    "gamma": "// Package gamma scores text similarity with set metrics.",
}

bad = []
for pkg, want in sorted(COMMENTS.items()):
    for f in sorted((ROOT / pkg).glob("*.go")):
        lines = f.read_text().splitlines()
        if not lines or lines[0] != want:
            bad.append(f"{f.relative_to(ROOT)}: first line is not the exact doc comment")
        elif len(lines) < 2 or not lines[1].startswith(f"package {pkg}"):
            bad.append(f"{f.relative_to(ROOT)}: doc comment is not directly above the package clause")
        elif lines.count(want) != 1:
            bad.append(f"{f.relative_to(ROOT)}: doc comment appears more than once")
if bad:
    print("doccheck FAILED:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print(f"doccheck ok: {sum(len(list((ROOT / p).glob('*.go'))) for p in COMMENTS)} files carry their package doc comment")
