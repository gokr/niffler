# bench report — reads-t2830-syn-large-low-2e2d3dc

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t28-docbackfill | pass | 16.9 | 1 | 4 | 12.2k | 5.4k | 303 | 6.5k/0 | 0.0012 | 18/9 |
| syn-large | niffler | t29-logrollup | pass | 34.7 | 1 | 3 | 7.6k | 2.7k | 239 | 4.6k/0 | 0.0007 | 436/0 |
| syn-large | niffler | t30-ifacedrift | pass | 31.1 | 1 | 4 | 11.7k | 3.4k | 279 | 8.1k/0 | 0.0010 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 3/3 | 3.7 | 28 | 10.5k | 3.8k | 6.4k | 274 | 167/19 |

*`invalid*` = tests pass but protected files (tests) were modified.*
