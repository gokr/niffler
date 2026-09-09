"""Normative spec for summary.json.

Recomputes the expected roll-up from logs/ and compares summary.json to it
BYTE-FOR-BYTE. Canonical form (see README.md): files sorted by name; entry
keys in the order name, lines, levels, first, last; levels always contains
all four keys DEBUG, INFO, WARN, ERROR in that order; 2-space indent; single
trailing newline.
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent
LEVELS = ["DEBUG", "INFO", "WARN", "ERROR"]

def expected():
    files = []
    for p in sorted((ROOT / "logs").glob("*.log")):
        lines = p.read_text().splitlines()
        levels = {lv: 0 for lv in LEVELS}
        for ln in lines:
            levels[ln.split()[1]] += 1
        files.append({
            "name": p.name,
            "lines": len(lines),
            "levels": levels,
            "first": lines[0].split()[0],
            "last": lines[-1].split()[0],
        })
    return {"files": files}

want = json.dumps(expected(), indent=2) + "\n"
sp = ROOT / "summary.json"
if not sp.exists():
    print("rollup FAILED: summary.json is missing")
    sys.exit(1)
got = sp.read_text()
if got != want:
    gl, wl = got.splitlines(), want.splitlines()
    n = next((i for i in range(min(len(gl), len(wl))) if gl[i] != wl[i]), min(len(gl), len(wl)))
    print(f"rollup FAILED: summary.json differs from the expected roll-up at line {n + 1}")
    print(f"  got:  {gl[n] if n < len(gl) else '<eof>'}")
    print(f"  want: {wl[n] if n < len(wl) else '<eof>'}")
    sys.exit(1)
print(f"rollup ok: {len(json.loads(got)['files'])} files summarized")
