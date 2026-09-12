# bench report — swe-sympy10-dsv41-high

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-deepseek-v41 | claudecode | sympy__sympy-11618 | fail | 191.3 | 1 | 24 | 113.0k | 0 | 2.2k | 100.3k/10.5k | 0.0016 | 6/2 |
| syn-deepseek-v41 | claudecode | sympy__sympy-12096 | pass | 154.5 | 1 | 31 | 163.1k | 0 | 2.8k | 141.6k/18.7k | 0.0021 | 1/1 |
| syn-deepseek-v41 | claudecode | sympy__sympy-12419 | pass | 557.9 | 1 | 103 | 1231.4k | 0 | 13.3k | 1181.8k/36.3k | 0.0115 | 2/1 |
| syn-deepseek-v41 | claudecode | sympy__sympy-12481 | pass | 192.1 | 1 | 26 | 123.9k | 0 | 4.1k | 100.8k/19.1k | 0.0027 | 10/6 |
| syn-deepseek-v41 | claudecode | sympy__sympy-12489 | pass | 514.2 | 1 | 108 | 1222.1k | 0 | 13.6k | 1170.4k/38.2k | 0.0116 | 35/31 |
| syn-deepseek-v41 | claudecode | sympy__sympy-13031 | pass | 1242.8 | 1 | 145 | 2160.4k | 0 | 33.4k | 2064.7k/62.3k | 0.0262 | 8/4 |
| syn-deepseek-v41 | claudecode | sympy__sympy-13091 | fail | 699.7 | 1 | 84 | 965.1k | 0 | 17.3k | 913.5k/34.3k | 0.0131 | 28/13 |
| syn-deepseek-v41 | claudecode | sympy__sympy-13372 | pass | 99.7 | 1 | 17 | 66.9k | 0 | 1.3k | 56.1k/9.5k | 0.0009 | 4/0 |
| syn-deepseek-v41 | claudecode | sympy__sympy-13480 | pass | 98.4 | 1 | 11 | 47.4k | 0 | 1.6k | 36.9k/8.8k | 0.0011 | 1/1 |
| syn-deepseek-v41 | claudecode | sympy__sympy-13551 | pass | 573.9 | 1 | 70 | 671.7k | 0 | 16.1k | 619.5k/36.1k | 0.0115 | 11/4 |
| syn-deepseek-v41 | niffler | sympy__sympy-11618 | pass | 191.5 | 1 | 15 | 157.9k | 16.4k | 6.5k | 135.0k/0 | 0.0068 | 17/3 |
| syn-deepseek-v41 | niffler | sympy__sympy-12096 | pass | 107.5 | 1 | 6 | 42.7k | 9.8k | 3.2k | 29.7k/0 | 0.0035 | 1/1 |
| syn-deepseek-v41 | niffler | sympy__sympy-12419 | pass | 110.8 | 1 | 21 | 199.3k | 17.5k | 3.9k | 177.9k/0 | 0.0055 | 2/4 |
| syn-deepseek-v41 | niffler | sympy__sympy-12481 | pass | 111.7 | 1 | 11 | 110.1k | 14.7k | 3.8k | 91.6k/0 | 0.0047 | 9/2 |
| syn-deepseek-v41 | niffler | sympy__sympy-12489 | pass | 187.7 | 1 | 18 | 424.1k | 33.9k | 10.1k | 380.0k/0 | 0.0123 | 24/24 |
| syn-deepseek-v41 | niffler | sympy__sympy-13031 | pass | 391.8 | 1 | 38 | 1567.6k | 72.7k | 24.6k | 1470.3k/0 | 0.0300 | 6/4 |
| syn-deepseek-v41 | niffler | sympy__sympy-13091 | pass | 341.1 | 1 | 24 | 625.4k | 43.5k | 21.9k | 560.0k/0 | 0.0213 | 19/9 |
| syn-deepseek-v41 | niffler | sympy__sympy-13372 | pass | 76.1 | 1 | 7 | 40.1k | 5.2k | 1.5k | 33.4k/0 | 0.0018 | 4/0 |
| syn-deepseek-v41 | niffler | sympy__sympy-13480 | pass | 72.4 | 1 | 6 | 59.0k | 13.4k | 1.9k | 43.8k/0 | 0.0033 | 1/1 |
| syn-deepseek-v41 | niffler | sympy__sympy-13551 | pass | 299.2 | 1 | 12 | 258.8k | 20.2k | 14.2k | 224.4k/0 | 0.0122 | 8/5 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-deepseek-v41 | claudecode | 8/10 | 61.9 | 432 | 676.5k | 0 | 638.6k | 10.6k | 11/6 |
| syn-deepseek-v41 | niffler | 10/10 | 15.8 | 189 | 348.5k | 24.7k | 314.6k | 9.2k | 9/5 |

*`invalid*` = tests pass but protected files (tests) were modified.*
