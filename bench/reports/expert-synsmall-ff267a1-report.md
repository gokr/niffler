# bench report — expert-synsmall-ff267a1

| model | harness | task | verdict | time (s) | rounds | tok in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 19.9 | 1 | 55.9k | 614 | 0/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 171.1 | 1 | 155.1k | 5.7k | 0/0 | 0.0000 | 91/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 42.7 | 1 | 102.3k | 1.5k | 0/0 | 0.0000 | 17/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 19.8 | 1 | 72.0k | 1.1k | 0/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 11.8 | 1 | 72.5k | 996 | 0/0 | 0.0000 | 17/4 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 59.6 | 1 | 65.6k | 6.7k | 3.2k/0 | 0.0000 | 19/1 | 5/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 260.7 | 1 | 292.7k | 26.3k | 28.2k/0 | 0.0000 | 83/1 | 14/4/1 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 36.8 | 1 | 85.9k | 6.1k | 11.3k/0 | 0.0000 | 17/4 | 7/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 38.3 | 1 | 100.7k | 4.7k | 10.2k/0 | 0.0000 | 3/3 | 6/3/1 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 34.9 | 1 | 83.0k | 4.9k | 7.6k/0 | 0.0000 | 25/4 | 5/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 36.6 | 1 | 66.2k | 510 | 0/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 86.6 | 1 | 86.2k | 3.6k | 0/0 | 0.0000 | 90/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 45.3 | 1 | 81.1k | 783 | 0/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 45.4 | 1 | 92.0k | 1.2k | 0/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 29.1 | 1 | 67.7k | 677 | 0/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 110.6 | 1 | 153.0k | 9.4k | 21.6k/0 | 0.0000 | 15/1 | 11/1/1 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 121 | 1 | 102.1k | 7.5k | 9.5k/0 | 0.0000 | 87/1 | 6/1/1 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 109.7 | 1 | 106.8k | 13.3k | 15.3k/0 | 0.0000 | 21/4 | 8/2/1 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 104.5 | 1 | 109.2k | 12.8k | 18.6k/0 | 0.0000 | 3/3 | 10/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 97.5 | 1 | 85.6k | 8.9k | 12.6k/0 | 0.0000 | 16/4 | 8/1/1 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok in | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 5/5 | 53 | 91.5k | 2.0k | 29/3 |
| deepseek-v4-flash | niffler-expert | 5/5 | 86 | 125.6k | 9.7k | 29/3 |
| glm-5.3-flash | niffler | 5/5 | 49 | 78.7k | 1.3k | 27/3 |
| glm-5.3-flash | niffler-expert | 5/5 | 109 | 111.3k | 10.4k | 28/3 |

*`invalid*` = tests pass but protected files (tests) were modified.*
