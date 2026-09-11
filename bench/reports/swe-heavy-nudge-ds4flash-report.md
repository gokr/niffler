# bench report — swe-heavy-nudge-ds4flash

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | sympy__sympy-12419 | pass | 527.9 | 1 | 80 | 4907.2k | 50.1k | 74.5k | 4782.6k/0 | 0.2330 | 2/5 |
| deepseek-v4-flash | niffler | sympy__sympy-12489 | pass | 238.9 | 1 | 49 | 1857.4k | 31.1k | 32.4k | 1793.9k/0 | 0.0959 | 31/29 |
| deepseek-v4-flash | niffler | sympy__sympy-13031 | pass | 510.9 | 1 | 81 | 4867.6k | 45.9k | 71.4k | 4750.3k/0 | 0.2274 | 8/4 |
| deepseek-v4-flash | niffler | sympy__sympy-13551 | pass | 149.3 | 1 | 16 | 325.6k | 15.9k | 15.5k | 294.3k/0 | 0.0304 | 7/5 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 4/4 | 56.5 | 357 | 2989.5k | 35.8k | 2905.3k | 48.4k | 12/11 |

*`invalid*` = tests pass but protected files (tests) were modified.*
