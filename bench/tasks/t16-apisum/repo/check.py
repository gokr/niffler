"""Verify result.json."""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent


def main():
    result = ROOT / "result.json"
    if not result.exists():
        print("FAIL: result.json missing")
        sys.exit(1)
    got = json.loads(result.read_text())
    want = {"sum": 165, "count": 3}
    if got != want:
        print(f"FAIL: got {got}, want {want}")
        sys.exit(1)
    print("OK: result matches")


if __name__ == "__main__":
    main()
