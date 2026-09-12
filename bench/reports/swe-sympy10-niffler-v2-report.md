# bench report — swe-sympy10-niffler-v2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | sympy__sympy-11618 | pass | 82.8 | 1 | 9 | 39.8k | 7.4k | 1.7k | 30.7k/0 | 0.0032 | 6/2 |
| syn-large | niffler | sympy__sympy-12096 | pass | 107.2 | 1 | 6 | 19.1k | 5.1k | 537 | 13.4k/0 | 0.0016 | 1/1 |
| syn-large | niffler | sympy__sympy-12419 | pass | 137.1 | 1 | 19 | 239.9k | 27.1k | 2.5k | 210.3k/0 | 0.0137 | 2/7 |
| syn-large | niffler | sympy__sympy-12481 | pass | 160.7 | 1 | 10 | 45.6k | 7.1k | 1.9k | 36.6k/0 | 0.0035 | 3/2 |
| syn-large | niffler | sympy__sympy-12489 | fail | 120.7 | 1 | 13 | 103.3k | 11.8k | 2.6k | 89.0k/0 | 0.0066 | 21/21 |
| syn-large | niffler | sympy__sympy-13031 | pass | 851.2 | 1 | 65 | 4329.5k | 90.3k | 31.5k | 4207.7k/0 | 0.1976 | 8/4 |
| syn-large | niffler | sympy__sympy-13091 | fail | 810.9 | 1 | 8 | 65.2k | 24.9k | 803 | 39.4k/0 | 0.0057 | 1/1 |
| syn-large | niffler | sympy__sympy-13372 | pass | 91.4 | 1 | 8 | 63.6k | 9.8k | 1.1k | 52.7k/0 | 0.0041 | 4/0 |
| syn-large | niffler | sympy__sympy-13480 | pass | 59.9 | 1 | 4 | 15.2k | 4.5k | 318 | 10.4k/0 | 0.0012 | 1/1 |
| syn-large | niffler | sympy__sympy-13551 | pass | 176.8 | 1 | 13 | 117.3k | 12.8k | 7.9k | 96.6k/0 | 0.0097 | 13/0 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 8/10 | 15.5 | 260 | 503.9k | 20.1k | 478.7k | 5.1k | 6/4 |

*`invalid*` = tests pass but protected files (tests) were modified.*
