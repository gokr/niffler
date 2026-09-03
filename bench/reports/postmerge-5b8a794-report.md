# bench report — postmerge-5b8a794

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 11 | 1 | 32.0k | 6.4k | 901 | 24.7k/0 | 0.0000 | 13/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 12.2 | 1 | 96.7k | 9.1k | 3.4k | 84.2k/0 | 0.0000 | 76/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 14.6 | 1 | 69.3k | 6.9k | 1.4k | 60.9k/0 | 0.0000 | 16/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 6 | 1 | 77.0k | 7.0k | 944 | 69.1k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 11.7 | 1 | 36.6k | 6.8k | 937 | 28.9k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 44.2 | 1 | 97.1k | 11.6k | 6.0k | 79.6k/0 | 0.0000 | 111/14 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 10.9 | 1 | 29.6k | 9.0k | 734 | 19.8k/0 | 0.0000 | 15/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 10.8 | 1 | 65.2k | 9.9k | 3.8k | 51.5k/0 | 0.0000 | 83/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 27.1 | 1 | 90.2k | 11.9k | 2.2k | 76.1k/0 | 0.0000 | 19/4 | 2/1/1 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 9.3 | 1 | 75.7k | 10.9k | 1.7k | 63.1k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 13.6 | 1 | 44.8k | 8.3k | 1.1k | 35.5k/0 | 0.0000 | 18/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 61.4 | 1 | 187.0k | 13.8k | 7.6k | 165.6k/0 | 0.0000 | 141/37 | 2/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 25.8 | 1 | 22.0k | 5.7k | 283 | 15.9k/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 26.1 | 1 | 117.8k | 22.0k | 1.8k | 93.9k/0 | 0.0000 | 56/11 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 43 | 1 | 64.1k | 9.6k | 1.2k | 53.3k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 25.3 | 1 | 57.5k | 3.6k | 440 | 53.4k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 22.7 | 1 | 23.1k | 2.3k | 404 | 20.4k/0 | 0.0000 | 18/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 70.3 | 1 | 64.4k | 11.2k | 2.7k | 50.4k/0 | 0.0000 | 154/37 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 29.7 | 1 | 29.2k | 6.9k | 357 | 22.0k/0 | 0.0000 | 13/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 28.2 | 1 | 65.7k | 17.2k | 935 | 47.5k/0 | 0.0000 | 43/13 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 45.1 | 1 | 71.5k | 8.4k | 1.1k | 62.0k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 70.6 | 1 | 59.4k | 5.8k | 395 | 53.2k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 25.5 | 1 | 30.4k | 7.9k | 464 | 22.0k/0 | 0.0000 | 14/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 69.6 | 1 | 58.7k | 13.8k | 2.4k | 42.6k/0 | 0.0000 | 150/57 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 17 | 68.1k | 8.0k | 57.9k | 2.2k | 40/5 |
| deepseek-v4-flash | niffler-expert | 6/6 | 22 | 82.1k | 10.6k | 68.6k | 2.9k | 47/8 |
| glm-5.3-flash | niffler | 6/6 | 36 | 58.1k | 9.1k | 47.9k | 1.1k | 43/10 |
| glm-5.3-flash | niffler-expert | 6/6 | 45 | 52.5k | 10.0k | 41.5k | 936.8333333333334 | 39/14 |

*`invalid*` = tests pass but protected files (tests) were modified.*
