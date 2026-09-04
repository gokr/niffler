import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "examples" / "app.log"


def run_cli(*args):
    return subprocess.run(
        [sys.executable, "-m", "logsum", *args],
        cwd=ROOT, capture_output=True, text=True,
        env={"PYTHONPATH": str(ROOT / "src"), "PATH": "/usr/bin:/bin"},
    )


class TestLogsum(unittest.TestCase):
    def test_full_summary(self):
        r = run_cli(str(LOG))
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.strip().splitlines()
        self.assertEqual(lines[0], "total 9")
        self.assertIn("DEBUG 1", lines)
        self.assertIn("INFO 4", lines)
        self.assertIn("WARN 1", lines)
        self.assertIn("ERROR 3", lines)
        # top 3 by count, ties alphabetical
        self.assertEqual(
            lines[lines.index("top:") + 1:],
            ["  connection refused", "  request handled",
             "  disk usage high"])

    def test_level_filter(self):
        r = run_cli(str(LOG), "--level", "ERROR")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.strip().splitlines()
        self.assertEqual(lines[0], "total 3")
        self.assertEqual(lines[1], "ERROR 3")

    def test_after_filter(self):
        r = run_cli(str(LOG), "--after", "2026-01-01 10:00:05")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.strip().splitlines()
        self.assertEqual(lines[0], "total 4")

    def test_top_n(self):
        r = run_cli(str(LOG), "--top", "5")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout.strip().splitlines()) - 6, 5)

    def test_missing_file(self):
        r = run_cli(str(ROOT / "nope.log"))
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
