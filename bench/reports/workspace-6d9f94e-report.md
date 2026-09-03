# bench report — workspace-6d9f94e

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 9.6 | 1 | 44.9k | 11.1k | 732 | 33.0k/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 114.7 | 1 | 273.3k | 13.7k | 16.3k | 243.3k/0 | 0.0000 | 135/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 19.5 | 1 | 62.5k | 10.8k | 1.6k | 50.0k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 12.9 | 1 | 75.5k | 11.6k | 1.1k | 62.7k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 19.5 | 1 | 66.9k | 11.6k | 2.5k | 52.7k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 96.7 | 1 | 146.1k | 15.5k | 15.3k | 115.3k/0 | 0.0000 | 151/48 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 12.3 | 1 | 62.1k | 15.0k | 614 | 46.5k/0 | 0.0000 | 19/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 57.3 | 1 | 153.1k | 17.5k | 6.5k | 129.0k/0 | 0.0000 | 62/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 18.6 | 1 | 65.4k | 12.6k | 904 | 51.8k/0 | 0.0000 | 14/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 15.6 | 1 | 69.9k | 15.6k | 1.8k | 52.5k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 13.4 | 1 | 74.6k | 11.9k | 1.0k | 61.7k/0 | 0.0000 | 19/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 107.2 | 1 | 185.2k | 17.2k | 15.5k | 152.4k/0 | 0.0000 | 125/20 | 2/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 37.4 | 1 | 52.2k | 28.9k | 323 | 23.0k/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 84.9 | 1 | 57.6k | 7.2k | 2.1k | 48.3k/0 | 0.0000 | 76/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 44.2 | 1 | 54.2k | 5.0k | 516 | 48.6k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 41.7 | 1 | 55.9k | 5.3k | 447 | 50.2k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 48 | 1 | 53.9k | 4.1k | 495 | 49.3k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 300.7 | 1 | 115.6k | 52.3k | 12.4k | 50.9k/0 | 0.0000 | 157/61 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 49.8 | 1 | 69.8k | 26.8k | 481 | 42.4k/0 | 0.0000 | 19/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 138.4 | 1 | 69.5k | 10.2k | 4.6k | 54.7k/0 | 0.0000 | 87/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 69.6 | 1 | 57.3k | 3.5k | 616 | 53.2k/0 | 0.0000 | 21/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 33.5 | 1 | 58.6k | 5.6k | 455 | 52.5k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 38.5 | 1 | 60.2k | 4.3k | 698 | 55.2k/0 | 0.0000 | 16/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 287.9 | 1 | 127.2k | 35.3k | 12.9k | 79.0k/0 | 0.0000 | 116/49 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 45 | 111.5k | 12.4k | 92.9k | 6.3k | 57/10 |
| deepseek-v4-flash | niffler-expert | 6/6 | 37 | 101.7k | 15.0k | 82.3k | 4.4k | 40/6 |
| glm-5.3-flash | niffler | 6/6 | 93 | 64.9k | 17.1k | 45.1k | 2.7k | 47/12 |
| glm-5.3-flash | niffler-expert | 6/6 | 103 | 73.8k | 14.3k | 56.2k | 3.3k | 44/10 |

*`invalid*` = tests pass but protected files (tests) were modified.*
