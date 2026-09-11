# bench report — swe-sympy10-ds41

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4.1-flash | niffler | sympy__sympy-11618 | fail | 92.1 | 1 | 17 | 214.5k | 11.2k | 7.4k | 195.8k/0 | 0.0067 | 21/3 |
| deepseek-v4.1-flash | niffler | sympy__sympy-12096 | pass | 52.9 | 1 | 7 | 23.4k | 2.1k | 1.3k | 20.0k/0 | 0.0012 | 1/1 |
| deepseek-v4.1-flash | niffler | sympy__sympy-12419 | pass | 239.6 | 1 | 55 | 1214.4k | 25.1k | 29.3k | 1160.1k/0 | 0.0248 | 2/5 |
| deepseek-v4.1-flash | niffler | sympy__sympy-12481 | pass | 109.2 | 1 | 16 | 256.9k | 13.2k | 10.6k | 233.1k/0 | 0.0090 | 10/6 |
| deepseek-v4.1-flash | niffler | sympy__sympy-12489 | pass | 181.3 | 1 | 36 | 773.4k | 20.3k | 17.3k | 735.7k/0 | 0.0157 | 25/25 |
| deepseek-v4.1-flash | niffler | sympy__sympy-13031 | pass | 324.4 | 1 | 77 | 2771.2k | 35.6k | 43.5k | 2692.1k/0 | 0.0395 | 8/4 |
| deepseek-v4.1-flash | niffler | sympy__sympy-13091 | fail | 264.1 | 1 | 55 | 1914.8k | 31.3k | 39.4k | 1844.1k/0 | 0.0339 | 25/10 |
| deepseek-v4.1-flash | niffler | sympy__sympy-13372 | pass | 120.9 | 1 | 8 | 45.9k | 5.0k | 1.8k | 39.2k/0 | 0.0019 | 4/0 |
| deepseek-v4.1-flash | niffler | sympy__sympy-13480 | pass | 94.2 | 1 | 8 | 50.1k | 5.3k | 2.1k | 42.8k/0 | 0.0022 | 1/1 |
| deepseek-v4.1-flash | niffler | sympy__sympy-13551 | pass | 258.4 | 1 | 41 | 1321.8k | 28.4k | 34.2k | 1259.1k/0 | 0.0286 | 13/0 |
| deepseek-v4.1-flash | pi | sympy__sympy-11618 | fail | 53.8 | 1 | 7 | 35.6k | 4.5k | 3.7k | 27.4k/0 | 0.0030 | 5/2 |
| deepseek-v4.1-flash | pi | sympy__sympy-12096 | pass | 62.2 | 1 | 6 | 20.5k | 3.1k | 1.6k | 15.7k/0 | 0.0015 | 1/1 |
| deepseek-v4.1-flash | pi | sympy__sympy-12419 | pass | 190 | 1 | 37 | 1009.2k | 24.9k | 26.7k | 957.6k/0 | 0.0226 | 2/5 |
| deepseek-v4.1-flash | pi | sympy__sympy-12481 | pass | 81.9 | 1 | 10 | 85.7k | 7.8k | 5.0k | 73.0k/0 | 0.0044 | 9/6 |
| deepseek-v4.1-flash | pi | sympy__sympy-12489 | pass | 145.2 | 1 | 26 | 489.8k | 18.6k | 16.4k | 454.8k/0 | 0.0140 | 26/26 |
| deepseek-v4.1-flash | pi | sympy__sympy-13031 | pass | 356.3 | 1 | 85 | 3694.0k | 39.9k | 53.6k | 3600.5k/0 | 0.0489 | 8/4 |
| deepseek-v4.1-flash | pi | sympy__sympy-13091 | fail | 233.8 | 1 | 38 | 1418.0k | 30.0k | 35.7k | 1352.3k/0 | 0.0300 | 10/4 |
| deepseek-v4.1-flash | pi | sympy__sympy-13372 | pass | 54.6 | 1 | 4 | 15.6k | 3.4k | 1.3k | 10.9k/0 | 0.0013 | 4/0 |
| deepseek-v4.1-flash | pi | sympy__sympy-13480 | pass | 68 | 1 | 9 | 46.7k | 4.5k | 3.0k | 39.2k/0 | 0.0026 | 1/1 |
| deepseek-v4.1-flash | pi | sympy__sympy-13551 | pass | 233.4 | 1 | 16 | 399.5k | 14.7k | 37.6k | 347.3k/0 | 0.0258 | 10/5 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4.1-flash | niffler | 8/10 | 32.0 | 174 | 858.6k | 17.8k | 822.2k | 18.7k | 11/6 |
| deepseek-v4.1-flash | pi | 8/10 | 23.8 | 148 | 721.5k | 15.1k | 687.9k | 18.5k | 8/5 |

*`invalid*` = tests pass but protected files (tests) were modified.*

## Corrections

- **niffler/sympy__sympy-13372** replaced from `swe-13372-ds41-fixed`: edit tool wedged by stale persisted seen-state after the resumed/aborted run (E_STALE x4); re-run on the fixed build: 226.1k -> 45.9k tokens, 21 -> 8 turns
