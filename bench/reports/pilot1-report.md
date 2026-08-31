# bench report — pilot1

| model | harness | task | verdict | time (s) | rounds | tok in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 9.4 | 1 | 36.1k | 572 | 0/0 | 0.0000 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 69.7 | 1 | 176.9k | 7.9k | 0/0 | 0.0000 | 76/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 20.5 | 1 | 48.4k | 1.2k | 0/0 | 0.0000 | 14/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 14.3 | 1 | 60.1k | 1.4k | 0/0 | 0.0000 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 10.3 | 1 | 48.7k | 850 | 0/0 | 0.0000 | 16/4 |
| deepseek-v4-flash | opencode | t01-roman | pass | 19.3 | 1 | 15.7k | 678 | 54.8k/0 | 0.0025 | 19/1 |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 36.9 | 1 | 16.2k | 1.1k | 77.7k/0 | 0.0034 | 85/1 |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 30.5 | 1 | 16.5k | 1.0k | 92.8k/0 | 0.0029 | 16/4 |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 29 | 1 | 16.3k | 660 | 109.3k/0 | 0.0029 | 3/3 |
| deepseek-v4-flash | opencode | t05-todostore | pass | 21.6 | 1 | 16.6k | 742 | 73.9k/0 | 0.0028 | 18/4 |
| deepseek-v4-flash | pi | t01-roman | pass | 8.4 | 1 | 2.6k | 432 | 7.2k/0 | 0.0014 | 13/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 59.2 | 1 | 3.1k | 7.1k | 44.4k/0 | 0.0102 | 92/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 15.5 | 1 | 2.5k | 1.3k | 12.4k/0 | 0.0025 | 17/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 16.6 | 1 | 2.7k | 1.5k | 17.2k/0 | 0.0030 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 10.9 | 1 | 2.7k | 990 | 12.3k/0 | 0.0022 | 19/4 |
| glm-5.3-flash | niffler | t01-roman | pass | 10.2 | 1 | 43.3k | 549 | 0/0 | 0.0000 | 19/1 |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 53.7 | 1 | 65.4k | 6.7k | 0/0 | 0.0000 | 94/1 |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 17.6 | 1 | 46.0k | 1.0k | 0/0 | 0.0000 | 13/4 |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 12 | 1 | 62.6k | 753 | 0/0 | 0.0000 | 3/3 |
| glm-5.3-flash | niffler | t05-todostore | pass | 10.6 | 1 | 46.5k | 753 | 0/0 | 0.0000 | 16/4 |
| glm-5.3-flash | opencode | t01-roman | pass | 27.2 | 1 | 83.0k | 434 | 0/0 | 0.0110 | 15/1 |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 36.8 | 1 | 104.6k | 733 | 0/0 | 0.0144 | 64/1 |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 27.3 | 1 | 84.2k | 595 | 0/0 | 0.0112 | 15/4 |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 22 | 1 | 85.5k | 370 | 0/0 | 0.0113 | 3/3 |
| glm-5.3-flash | opencode | t05-todostore | pass | 25.1 | 1 | 101.5k | 561 | 0/0 | 0.0135 | 16/4 |
| glm-5.3-flash | pi | t01-roman | pass | 9 | 1 | 11.2k | 498 | 0/0 | 0.0000 | 13/1 |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 99 | 1 | 143.8k | 8.6k | 0/0 | 0.0000 | 120/1 |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 14.4 | 1 | 11.7k | 525 | 0/0 | 0.0000 | 13/4 |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 8.7 | 1 | 11.3k | 449 | 0/0 | 0.0000 | 3/3 |
| glm-5.3-flash | pi | t05-todostore | pass | 11.5 | 1 | 12.2k | 485 | 0/0 | 0.0000 | 16/4 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok in | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 5/5 | 25 | 74.0k | 2.4k | 24/3 |
| deepseek-v4-flash | opencode | 5/5 | 27 | 16.3k | 854.6 | 28/3 |
| deepseek-v4-flash | pi | 5/5 | 22 | 2.7k | 2.3k | 29/3 |
| glm-5.3-flash | niffler | 5/5 | 21 | 52.8k | 1.9k | 29/3 |
| glm-5.3-flash | opencode | 5/5 | 28 | 91.8k | 538.6 | 23/3 |
| glm-5.3-flash | pi | 5/5 | 29 | 38.0k | 2.1k | 33/3 |

*`invalid*` = tests pass but protected files (tests) were modified.*
