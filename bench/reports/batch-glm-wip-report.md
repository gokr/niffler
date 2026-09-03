# bench report — batch-glm-wip

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| glm-5.3-flash | niffler | t01-roman | pass | 23.6 | 1 | 23.0k | 11.6k | 242 | 11.1k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 26.8 | 1 | 25.0k | 3.1k | 607 | 21.2k/0 | 0.0000 | 68/12 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 29 | 1 | 24.6k | 2.0k | 451 | 22.1k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 26.6 | 1 | 29.7k | 2.3k | 210 | 27.2k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 25 | 1 | 30.4k | 2.3k | 263 | 27.8k/0 | 0.0000 | 14/15 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 104.1 | 1 | 103.4k | 8.8k | 3.4k | 91.2k/0 | 0.0000 | 127/37 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 27 | 1 | 29.3k | 18.2k | 286 | 10.8k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 102.2 | 1 | 123.6k | 11.3k | 2.1k | 110.3k/0 | 0.0000 | 73/11 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 38.8 | 1 | 38.6k | 3.1k | 799 | 34.7k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 25.7 | 1 | 37.0k | 2.6k | 294 | 34.1k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 25.9 | 1 | 30.6k | 2.2k | 474 | 28.0k/0 | 0.0000 | 19/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 84.3 | 1 | 80.0k | 9.6k | 3.9k | 66.5k/0 | 0.0000 | 124/27 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| glm-5.3-flash | niffler | 6/6 | 39 | 39.3k | 5.0k | 33.5k | 857.8333333333334 | 40/13 |
| glm-5.3-flash | niffler-expert | 6/6 | 51 | 56.5k | 7.8k | 47.4k | 1.3k | 41/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
