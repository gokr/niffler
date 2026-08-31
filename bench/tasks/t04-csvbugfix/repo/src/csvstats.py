"""Column statistics over a CSV file.

`column_stats(rows, column)` returns {"count", "mean", "min", "max"} over
the numeric values of that column. Rows with an empty cell in the column
are skipped.
"""

import csv


def load_rows(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def column_stats(rows: list[dict], column: str) -> dict:
    cells = [r.get(column) for r in rows]
    cells = [c for c in cells if c not in (None, "")]
    values = [float(c) for c in cells]
    return {
        "count": len(values),
        "mean": sum(values) / (len(values) + 1),
        "min": min(cells),
        "max": max(cells),
    }
