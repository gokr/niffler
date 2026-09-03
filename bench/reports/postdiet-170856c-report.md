# bench report — postdiet-170856c

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 10.4 | 1 | 30.7k | 5.7k | 738 | 24.2k/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 23.3 | 1 | 33.2k | 5.8k | 2.8k | 24.6k/0 | 0.0000 | 52/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 13 | 1 | 22.6k | 5.0k | 907 | 16.6k/0 | 0.0000 | 16/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11 | 1 | 38.7k | 5.4k | 973 | 32.4k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 8.9 | 1 | 28.5k | 5.6k | 926 | 22.0k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 57.8 | 1 | 129.5k | 18.5k | 8.4k | 102.5k/0 | 0.0000 | 133/48 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 7.9 | 1 | 23.6k | 8.6k | 697 | 14.3k/0 | 0.0000 | 31/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 25.7 | 1 | 42.5k | 7.0k | 3.1k | 32.4k/0 | 0.0000 | 57/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 15.2 | 1 | 33.9k | 6.7k | 1.3k | 25.9k/0 | 0.0000 | 15/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 9.7 | 1 | 32.2k | 5.6k | 920 | 25.7k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 9.8 | 1 | 33.1k | 6.2k | 933 | 26.0k/0 | 0.0000 | 21/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 59.6 | 1 | 99.1k | 15.1k | 8.8k | 75.2k/0 | 0.0000 | 165/56 | 2/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 22.2 | 1 | 17.7k | 4.7k | 255 | 12.7k/0 | 0.0000 | 20/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 31.8 | 1 | 24.6k | 2.4k | 807 | 21.4k/0 | 0.0000 | 90/9 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 41 | 1 | 38.7k | 7.4k | 526 | 30.8k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 14 | 1 | 18.6k | 1.4k | 197 | 17.0k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 30.7 | 1 | 28.9k | 2.2k | 456 | 26.3k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 50.4 | 1 | 43.7k | 5.5k | 2.4k | 35.7k/0 | 0.0000 | 118/18 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 26.1 | 1 | 29.5k | 5.8k | 331 | 23.4k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 35.1 | 1 | 38.1k | 6.7k | 916 | 30.4k/0 | 0.0000 | 79/10 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 39.1 | 1 | 40.9k | 2.7k | 734 | 37.4k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 19.6 | 1 | 26.3k | 2.0k | 274 | 23.9k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 22 | 1 | 31.4k | 2.5k | 335 | 28.5k/0 | 0.0000 | 16/15 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 50.8 | 1 | 66.5k | 8.2k | 2.0k | 56.3k/0 | 0.0000 | 90/42 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 21 | 47.2k | 7.7k | 37.1k | 2.5k | 40/10 |
| deepseek-v4-flash | niffler-expert | 6/6 | 21 | 44.1k | 8.2k | 33.3k | 2.6k | 49/12 |
| glm-5.3-flash | niffler | 6/6 | 32 | 28.7k | 3.9k | 24.0k | 781.3333333333334 | 43/7 |
| glm-5.3-flash | niffler-expert | 6/6 | 32 | 38.8k | 4.7k | 33.3k | 771.8333333333334 | 36/13 |

*`invalid*` = tests pass but protected files (tests) were modified.*
