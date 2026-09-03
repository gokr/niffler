# bench report — wsfix-24df94f

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 7.3 | 1 | 26.8k | 5.8k | 562 | 20.4k/0 | 0.0000 | 13/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 18.2 | 1 | 31.5k | 5.3k | 2.3k | 23.8k/0 | 0.0000 | 70/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 13.3 | 1 | 26.7k | 4.9k | 958 | 20.9k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 9.2 | 1 | 31.8k | 5.1k | 827 | 25.9k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9.6 | 1 | 30.5k | 5.9k | 1.1k | 23.6k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 67.5 | 1 | 88.1k | 10.8k | 9.2k | 68.1k/0 | 0.0000 | 129/26 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 7.2 | 1 | 23.3k | 8.6k | 478 | 14.2k/0 | 0.0000 | 13/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 35.7 | 1 | 47.3k | 10.3k | 4.7k | 32.3k/0 | 0.0000 | 118/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 14.8 | 1 | 34.8k | 9.9k | 1.3k | 23.6k/0 | 0.0000 | 13/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 11.1 | 1 | 35.1k | 5.4k | 721 | 29.0k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 14.2 | 1 | 47.2k | 8.1k | 1.4k | 37.7k/0 | 0.0000 | 18/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 92.3 | 1 | 148.2k | 14.4k | 11.8k | 122.0k/0 | 0.0000 | 199/56 | 2/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 18.6 | 1 | 17.4k | 9.1k | 245 | 8.1k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 27.1 | 1 | 24.2k | 5.8k | 632 | 17.7k/0 | 0.0000 | 67/13 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 26.5 | 1 | 19.0k | 1.6k | 448 | 17.0k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.4 | 1 | 18.9k | 1.5k | 303 | 17.2k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 18.3 | 1 | 18.1k | 1.3k | 417 | 16.3k/0 | 0.0000 | 18/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 49.6 | 1 | 35.7k | 5.5k | 2.5k | 27.7k/0 | 0.0000 | 170/48 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 14.2 | 1 | 12.3k | 5.0k | 310 | 7.0k/0 | 0.0000 | 13/4 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 27.7 | 1 | 31.7k | 2.8k | 613 | 28.3k/0 | 0.0000 | 60/10 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 26.4 | 1 | 32.9k | 3.1k | 1.0k | 28.9k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 19.6 | 1 | 26.3k | 2.1k | 264 | 23.9k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 24.4 | 1 | 31.5k | 2.5k | 328 | 28.6k/0 | 0.0000 | 14/15 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 55 | 1 | 86.8k | 9.4k | 2.5k | 74.9k/0 | 0.0000 | 161/64 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 21 | 39.2k | 6.3k | 30.4k | 2.5k | 42/7 |
| deepseek-v4-flash | niffler-expert | 6/6 | 29 | 56.0k | 9.5k | 43.1k | 3.4k | 61/12 |
| glm-5.3-flash | niffler | 6/6 | 27 | 22.2k | 4.1k | 17.3k | 756.6666666666666 | 47/13 |
| glm-5.3-flash | niffler-expert | 6/6 | 28 | 36.9k | 4.1k | 31.9k | 839 | 44/17 |

*`invalid*` = tests pass but protected files (tests) were modified.*
