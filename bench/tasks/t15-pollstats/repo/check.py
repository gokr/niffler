"""Verify stats.json against the values generator.py produces for seeds
1..12."""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent


def main():
    values = []
    for seed in range(1, 13):
        out = subprocess.run(
            ["python3", "generator.py", str(seed)],
            cwd=ROOT, capture_output=True, text=True, check=True)
        values.append(float(out.stdout.strip()))
    want = {
        "min": round(min(values), 2),
        "max": round(max(values), 2),
        "mean": round(sum(values) / len(values), 2),
    }
    stats = ROOT / "stats.json"
    if not stats.exists():
        print("FAIL: stats.json missing")
        sys.exit(1)
    got = json.loads(stats.read_text())
    for key in ("min", "max", "mean"):
        if round(got.get(key), 2) != round(want[key], 2):
            print(f"FAIL: {key}: got {got.get(key)}, want {want[key]}")
            sys.exit(1)
    print("OK: stats match")


if __name__ == "__main__":
    main()
