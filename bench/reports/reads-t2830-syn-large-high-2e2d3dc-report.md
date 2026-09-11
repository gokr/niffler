# bench report — reads-t2830-syn-large-high-2e2d3dc

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t28-docbackfill | pass | 59.6 | 1 | 8 | 50.0k | 14.9k | 2.7k | 32.5k/0 | 0.0049 | 18/9 |
| syn-large | niffler | t29-logrollup | pass | 73.1 | 1 | 3 | 9.8k | 5.7k | 442 | 3.6k/0 | 0.0012 | 436/0 |
| syn-large | niffler | t30-ifacedrift | pass | 112 | 1 | 8 | 73.3k | 14.1k | 3.1k | 56.2k/0 | 0.0059 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 3/3 | 6.3 | 82 | 44.4k | 11.5k | 30.8k | 2.1k | 167/19 |

*`invalid*` = tests pass but protected files (tests) were modified.*
