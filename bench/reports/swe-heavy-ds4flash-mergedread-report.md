# bench report — swe-heavy-ds4flash-mergedread

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | sympy__sympy-12419 | pass | 203.9 | 1 | 1238.1k | 28.7k | 26.4k | 1183.0k/0 | 0.0714 | 2/2 |
| deepseek-v4-flash | niffler | sympy__sympy-12489 | pass | 144.3 | 1 | 518.7k | 17.2k | 16.6k | 485.0k/0 | 0.0373 | 32/30 |
| deepseek-v4-flash | niffler | sympy__sympy-13031 | pass | 430.8 | 1 | 6099.6k | 98.9k | 73.6k | 5927.2k/0 | 0.2778 | 8/4 |
| deepseek-v4-flash | niffler | sympy__sympy-13551 | pass | 296.5 | 1 | 469.4k | 15.7k | 33.3k | 420.4k/0 | 0.0541 | 10/6 |
| deepseek-v4-flash | pi | sympy__sympy-12419 | pass | 281.3 | 1 | 1749.3k | 30.5k | 36.9k | 1681.8k/0 | 0.0978 | 2/2 |
| deepseek-v4-flash | pi | sympy__sympy-12489 | pass | 137 | 1 | 550.1k | 19.1k | 18.9k | 512.1k/0 | 0.0413 | 29/29 |
| deepseek-v4-flash | pi | sympy__sympy-13031 | pass | 249.8 | 1 | 1826.7k | 31.0k | 38.3k | 1757.4k/0 | 0.1017 | 4/2 |
| deepseek-v4-flash | pi | sympy__sympy-13551 | pass | 182.2 | 1 | 321.9k | 13.4k | 22.3k | 286.2k/0 | 0.0372 | 6/4 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 4/4 | 269 | 2081.5k | 40.1k | 2003.9k | 37.5k | 13/11 |
| deepseek-v4-flash | pi | 4/4 | 213 | 1112.0k | 23.5k | 1059.4k | 29.1k | 10/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
