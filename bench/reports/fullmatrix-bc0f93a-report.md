# bench report — fullmatrix-bc0f93a

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 7.2 | 1 | 25.8k | 5.7k | 565 | 19.6k/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 57.4 | 1 | 51.8k | 5.7k | 7.2k | 38.9k/0 | 0.0000 | 61/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 12.4 | 1 | 33.4k | 5.5k | 720 | 27.1k/0 | 0.0000 | 19/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 8.9 | 1 | 32.5k | 5.4k | 809 | 26.2k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 8.2 | 1 | 34.4k | 6.2k | 682 | 27.5k/0 | 0.0000 | 17/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 63.5 | 1 | 108.7k | 10.9k | 8.6k | 89.2k/0 | 0.0000 | 117/23 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 10.8 | 1 | 28.6k | 9.2k | 744 | 18.7k/0 | 0.0000 | 13/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 47.7 | 1 | 95.2k | 13.6k | 5.3k | 76.3k/0 | 0.0000 | 62/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 14 | 1 | 40.7k | 6.8k | 709 | 33.2k/0 | 0.0000 | 15/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 10.9 | 1 | 43.8k | 6.6k | 588 | 36.6k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 12.4 | 1 | 38.8k | 6.8k | 980 | 31.0k/0 | 0.0000 | 21/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 67.1 | 1 | 201.9k | 20.8k | 9.4k | 171.6k/0 | 0.0000 | 194/69 | 2/0/0 |
| deepseek-v4-flash | opencode | t01-roman | pass | 17.7 | 1 | 71.3k | 15.7k | 678 | 54.9k/0 | 0.0025 | 13/1 | - |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 23.6 | 1 | 109.2k | 16.7k | 951 | 91.5k/0 | 0.0029 | 52/1 | - |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 28.6 | 1 | 111.4k | 16.5k | 1.1k | 93.8k/0 | 0.0030 | 15/4 | - |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 19.5 | 1 | 107.8k | 16.2k | 527 | 91.1k/0 | 0.0027 | 3/3 | - |
| deepseek-v4-flash | opencode | t05-todostore | pass | 20.6 | 1 | 110.9k | 16.9k | 1.1k | 92.9k/0 | 0.0029 | 16/4 | - |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 126.6 | 1 | 278.4k | 22.0k | 4.5k | 251.9k/0 | 0.0088 | 148/64 | - |
| deepseek-v4-flash | pi | t01-roman | pass | 7.5 | 1 | 10.5k | 1.7k | 697 | 8.1k/0 | 0.0015 | 29/1 | - |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 105.7 | 1 | 118.9k | 3.5k | 14.6k | 100.9k/0 | 0.0204 | 168/1 | - |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 15.6 | 1 | 18.3k | 2.5k | 1.3k | 14.5k/0 | 0.0026 | 15/4 | - |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 12.4 | 1 | 19.6k | 2.4k | 1.2k | 16.0k/0 | 0.0025 | 3/3 | - |
| deepseek-v4-flash | pi | t05-todostore | pass | 8.8 | 1 | 15.9k | 2.9k | 909 | 12.2k/0 | 0.0022 | 19/4 | - |
| deepseek-v4-flash | pi | t06-stackvm | pass | 97.3 | 1 | 113.0k | 6.5k | 15.6k | 90.9k/0 | 0.0222 | 150/48 | - |
| glm-5.3-flash | niffler | t01-roman | pass | 21.5 | 1 | 22.4k | 5.9k | 240 | 16.3k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 35.8 | 1 | 24.2k | 13.1k | 522 | 10.6k/0 | 0.0000 | 47/13 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 31 | 1 | 24.8k | 1.9k | 448 | 22.5k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.4 | 1 | 23.4k | 1.3k | 199 | 21.9k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 19.8 | 1 | 22.9k | 1.3k | 413 | 21.2k/0 | 0.0000 | 19/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 94.4 | 1 | 126.5k | 8.8k | 3.7k | 113.9k/0 | 0.0000 | 162/51 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 19.6 | 1 | 30.0k | 13.7k | 303 | 16.0k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 27.2 | 1 | 37.1k | 2.9k | 576 | 33.7k/0 | 0.0000 | 54/11 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 25.4 | 1 | 24.1k | 1.6k | 488 | 22.1k/0 | 0.0000 | 14/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 23.4 | 1 | 30.8k | 2.0k | 255 | 28.5k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 24.9 | 1 | 38.6k | 3.2k | 496 | 34.9k/0 | 0.0000 | 19/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 74.8 | 1 | 92.1k | 7.6k | 2.9k | 81.6k/0 | 0.0000 | 147/46 | 2/0/0 |
| glm-5.3-flash | opencode | t01-roman | pass | 41.4 | 1 | 83.3k | 25.6k | 419 | 57.3k/0 | 0.0049 | 13/1 | - |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 128 | 1 | 108.9k | 16.9k | 883 | 91.1k/0 | 0.0060 | 71/1 | - |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 65.6 | 1 | 103.7k | 14.1k | 734 | 88.8k/0 | 0.0044 | 13/4 | - |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 46.7 | 1 | 102.7k | 13.6k | 452 | 88.6k/0 | 0.0041 | 3/3 | - |
| glm-5.3-flash | opencode | t05-todostore | pass | 52.8 | 1 | 103.0k | 5.4k | 705 | 96.8k/0 | 0.0034 | 17/4 | - |
| glm-5.3-flash | opencode | t06-stackvm | pass | 216.4 | 1 | 120.6k | 18.6k | 2.6k | 99.4k/0 | 0.0086 | 159/72 | - |
| glm-5.3-flash | pi | t01-roman | pass | 16.2 | 1 | 7.3k | 3.6k | 263 | 3.5k/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 19.1 | 1 | 11.6k | 4.5k | 600 | 6.5k/0 | 0.0000 | 49/1 | - |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 33 | 1 | 11.5k | 8.6k | 494 | 2.4k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 10 | 1 | 8.5k | 3.6k | 176 | 4.7k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | pi | t05-todostore | pass | 13.3 | 1 | 8.6k | 2.8k | 437 | 5.3k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | pi | t06-stackvm | pass | 39.3 | 1 | 19.4k | 9.8k | 2.4k | 7.2k/0 | 0.0000 | 170/47 | - |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 26 | 47.8k | 6.6k | 38.1k | 3.1k | 39/6 |
| deepseek-v4-flash | niffler-expert | 6/6 | 27 | 74.8k | 10.7k | 61.2k | 2.9k | 51/14 |
| deepseek-v4-flash | opencode | 6/6 | 39 | 131.5k | 17.3k | 112.7k | 1.5k | 41/13 |
| deepseek-v4-flash | pi | 6/6 | 41 | 49.4k | 3.2k | 40.4k | 5.7k | 64/10 |
| glm-5.3-flash | niffler | 6/6 | 37 | 40.7k | 5.4k | 34.4k | 921.6666666666666 | 43/13 |
| glm-5.3-flash | niffler-expert | 6/6 | 33 | 42.1k | 5.2k | 36.1k | 842.3333333333334 | 42/12 |
| glm-5.3-flash | opencode | 6/6 | 92 | 103.7k | 15.7k | 87.0k | 964 | 46/14 |
| glm-5.3-flash | pi | 6/6 | 22 | 11.1k | 5.5k | 4.9k | 724.6666666666666 | 44/10 |

*`invalid*` = tests pass but protected files (tests) were modified.*
