# bench report — diet-glm-3e995a8

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| glm-5.3-flash | niffler | t01-roman | pass | 13.8 | 1 | 7.5k | 7.3k | 218 | 0/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 29.4 | 1 | 22.0k | 3.2k | 557 | 18.2k/0 | 0.0000 | 50/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 28.5 | 1 | 17.5k | 1.4k | 428 | 15.6k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.1 | 1 | 17.0k | 1.4k | 178 | 15.4k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 27.4 | 1 | 22.0k | 5.3k | 322 | 16.3k/0 | 0.0000 | 17/15 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 130.2 | 1 | 81.3k | 8.6k | 4.6k | 68.2k/0 | 0.0000 | 165/60 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 27.3 | 1 | 23.7k | 16.7k | 357 | 6.7k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 33.6 | 1 | 29.4k | 4.4k | 628 | 24.3k/0 | 0.0000 | 61/13 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 29.5 | 1 | 24.7k | 7.4k | 595 | 16.7k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 29.3 | 1 | 28.4k | 5.4k | 316 | 22.7k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 22.9 | 1 | 23.6k | 5.5k | 381 | 17.7k/0 | 0.0000 | 16/15 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 59.3 | 1 | 36.9k | 6.5k | 2.6k | 27.8k/0 | 0.0000 | 152/43 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| glm-5.3-flash | niffler | 6/6 | 42 | 27.9k | 4.5k | 22.3k | 1.1k | 44/15 |
| glm-5.3-flash | niffler-expert | 6/6 | 34 | 27.8k | 7.7k | 19.3k | 804.6666666666666 | 43/14 |

*`invalid*` = tests pass but protected files (tests) were modified.*
