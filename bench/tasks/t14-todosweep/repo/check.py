"""Build the expected TODO/FIXME report from the repository and compare it
byte-for-byte with todos-report.md."""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
EXTS = {".py", ".nim", ".go", ".js", ".txt"}


def comment_rest(line: str, ext: str) -> str | None:
    if ext in (".py", ".nim"):
        s = line.strip()
        if s.startswith("#"):
            return s[1:].strip()
        return None
    if ext in (".go", ".js"):
        i = line.find("//")
        if i >= 0:
            return line[i + 2:].strip()
        return None
    return line.strip() or None


def extract(rest: str):
    for marker in ("TODO", "FIXME"):
        if rest.startswith(marker):
            text = rest[len(marker):]
            if text.startswith(":"):
                text = text[1:]
            return marker, text.strip()
        if rest == marker:
            return marker, ""
    return None


def expected():
    hits = {}
    for path in sorted(ROOT.rglob("*")):
        if path.is_dir() or not path.is_relative_to(ROOT):
            continue
        rel = path.relative_to(ROOT)
        if not str(rel).endswith(tuple(EXTS)):
            continue
        if rel.name in ("check.py", "todos-report.md"):
            continue
        entries = []
        for n, line in enumerate(path.read_text().splitlines(), 1):
            rest = comment_rest(line, path.suffix)
            if rest is None:
                continue
            hit = extract(rest)
            if hit:
                entries.append((n, *hit))
        if entries:
            hits[str(rel)] = entries
    lines = ["# TODO report", ""]
    for path, entries in sorted(hits.items()):
        lines.append(f"{path} ({len(entries)})")
        for n, marker, text in entries:
            lines.append(f"  - {marker}: {text} (line {n})")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    report = ROOT / "todos-report.md"
    if not report.exists():
        print("FAIL: todos-report.md missing")
        sys.exit(1)
    want = expected()
    got = report.read_text()
    if got != want:
        print("FAIL: report does not match")
        print("--- expected ---")
        print(want)
        print("--- got ---")
        print(got)
        sys.exit(1)
    print("OK: report matches")


if __name__ == "__main__":
    main()
