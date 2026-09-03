# bench report — thinking-low-1f8fa30

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 12.6 | 1 | 25.2k | 6.3k | 652 | 18.3k/0 | 0.0000 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 47.7 | 1 | 48.6k | 7.3k | 5.3k | 36.0k/0 | 0.0000 | 95/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 14.1 | 1 | 33.8k | 5.5k | 966 | 27.4k/0 | 0.0000 | 17/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 13.5 | 1 | 40.5k | 5.6k | 1.1k | 33.8k/0 | 0.0000 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9.7 | 1 | 40.4k | 6.2k | 726 | 33.5k/0 | 0.0000 | 21/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 58.1 | 1 | 187.5k | 12.2k | 8.1k | 167.2k/0 | 0.0000 | 149/65 |
| glm-5.3-flash | niffler | t01-roman | pass | 22.4 | 1 | 16.3k | 5.6k | 286 | 10.4k/0 | 0.0000 | 13/1 |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 470.4 | 2 | 271.7k | 25.6k | 7.7k | 238.3k/0 | 0.0000 | 58/11 |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 23.6 | 1 | 17.0k | 6.2k | 402 | 10.4k/0 | 0.0000 | 14/4 |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 21.1 | 1 | 23.5k | 1.3k | 209 | 22.0k/0 | 0.0000 | 3/3 |
| glm-5.3-flash | niffler | t05-todostore | pass | 20 | 1 | 17.2k | 6.4k | 431 | 10.4k/0 | 0.0000 | 17/4 |
| glm-5.3-flash | niffler | t06-stackvm | pass | 66.3 | 1 | 59.7k | 5.2k | 2.1k | 52.4k/0 | 0.0000 | 132/44 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 26 | 62.7k | 7.2k | 52.7k | 2.8k | 50/13 |
| glm-5.3-flash | niffler | 6/6 | 104 | 67.6k | 8.4k | 57.3k | 1.9k | 40/11 |

*`invalid*` = tests pass but protected files (tests) were modified.*
