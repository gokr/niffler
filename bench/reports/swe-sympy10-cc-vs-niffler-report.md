# bench report — swe-sympy10-cc-vs-niffler

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | claudecode | sympy__sympy-11618 | pass | 82.5 | 1 | 13 | 61.2k | 0 | 673 | 41.4k/19.2k | 0.0020 | 10/2 |
| syn-large | claudecode | sympy__sympy-12096 | pass | 133.8 | 1 | 15 | 63.9k | 0 | 2.2k | 42.2k/19.5k | 0.0028 | 5/1 |
| syn-large | claudecode | sympy__sympy-12419 | pass | 872.7 | 1 | 79 | 693.5k | 0 | 21.6k | 631.6k/40.4k | 0.0361 | 23/1 |
| syn-large | claudecode | sympy__sympy-12481 | pass | 102.4 | 1 | 19 | 76.1k | 0 | 854 | 64.5k/10.8k | 0.0030 | 1/4 |
| syn-large | claudecode | sympy__sympy-12489 | fail | 173.3 | 1 | 21 | 123.3k | 0 | 2.8k | 109.4k/11.1k | 0.0058 | 8/8 |
| syn-large | claudecode | sympy__sympy-13031 | pass | 826.8 | 1 | 129 | 1624.4k | 0 | 15.4k | 1541.1k/67.9k | 0.0693 | 6/4 |
| syn-large | claudecode | sympy__sympy-13091 | fail | 201.4 | 1 | 25 | 138.1k | 0 | 4.1k | 117.7k/16.3k | 0.0068 | 4/4 |
| syn-large | claudecode | sympy__sympy-13372 | pass | 82.8 | 1 | 8 | 27.9k | 0 | 667 | 13.9k/13.3k | 0.0009 | 4/0 |
| syn-large | claudecode | sympy__sympy-13480 | pass | 115.2 | 1 | 17 | 77.0k | 0 | 1.1k | 65.7k/10.2k | 0.0032 | 1/1 |
| syn-large | claudecode | sympy__sympy-13551 | pass | 512.8 | 1 | 29 | 246.1k | 0 | 9.3k | 221.2k/15.6k | 0.0135 | 13/7 |
| syn-large | niffler | sympy__sympy-11618 | fail | 56.5 | 1 | 6 | 19.8k | 6.0k | 382 | 13.5k/0 | 0.0016 | 2/1 |
| syn-large | niffler | sympy__sympy-12096 | pass | 88.8 | 1 | 9 | 169.1k | 24.2k | 1.5k | 143.4k/0 | 0.0101 | 4/1 |
| syn-large | niffler | sympy__sympy-12419 | fail | 81.4 | 1 | 9 | 35.4k | 4.5k | 1.1k | 29.8k/0 | 0.0024 | 2/4 |
| syn-large | niffler | sympy__sympy-12481 | fail | 101.4 | 1 | 14 | 55.5k | 8.6k | 1.1k | 45.9k/0 | 0.0037 | 4/8 |
| syn-large | niffler | sympy__sympy-12489 | pass | 154.4 | 1 | 22 | 343.4k | 23.8k | 3.8k | 315.9k/0 | 0.0181 | 22/22 |
| syn-large | niffler | sympy__sympy-13031 | pass | 1122.1 | 1 | 74 | 5930.4k | 202.9k | 53.6k | 5673.8k/0 | 0.2842 | 6/4 |
| syn-large | niffler | sympy__sympy-13091 | fail | 75.1 | 1 | 8 | 40.5k | 6.6k | 823 | 33.1k/0 | 0.0027 | 5/2 |
| syn-large | niffler | sympy__sympy-13372 | pass | 83.3 | 1 | 7 | 44.1k | 5.4k | 956 | 37.8k/0 | 0.0028 | 4/0 |
| syn-large | niffler | sympy__sympy-13480 | pass | 65.1 | 1 | 6 | 32.1k | 12.0k | 624 | 19.5k/0 | 0.0029 | 1/1 |
| syn-large | niffler | sympy__sympy-13551 | pass | 201.5 | 1 | 11 | 105.3k | 10.2k | 9.6k | 85.6k/0 | 0.0097 | 13/0 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-large | claudecode | 8/10 | 35.5 | 310 | 313.2k | 0 | 284.9k | 5.9k | 8/3 |
| syn-large | niffler | 6/10 | 16.6 | 203 | 677.6k | 30.4k | 639.8k | 7.3k | 6/4 |

*`invalid*` = tests pass but protected files (tests) were modified.*
