# bench report — swe-13031-grepcap

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | sympy__sympy-13031 | pass | 468 | 1 | 76 | 4740.0k | 59.2k | 82.0k | 4598.8k/0 | 0.2390 | 8/4 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 1/1 | 76.0 | 468 | 4740.0k | 59.2k | 4598.8k | 82.0k | 8/4 |

*`invalid*` = tests pass but protected files (tests) were modified.*
