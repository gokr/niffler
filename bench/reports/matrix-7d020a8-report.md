# bench report — matrix-7d020a8

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 24.7 | 2 | 60.4k | 14.0k | 563 | 45.8k/0 | 0.0000 | 13/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 38.6 | 1 | 88.7k | 7.4k | 4.9k | 76.4k/0 | 0.0000 | 75/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 19.1 | 1 | 77.6k | 1.5k | 1.3k | 74.8k/0 | 0.0000 | 15/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 15 | 1 | 112.3k | 2.8k | 1.4k | 108.2k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 10.6 | 1 | 78.2k | 2.0k | 1.0k | 75.1k/0 | 0.0000 | 21/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 79.4 | 1 | 156.8k | 6.3k | 12.8k | 137.7k/0 | 0.0000 | 115/27 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 78 | 1 | 79.7k | 15.8k | 11.6k | 52.3k/0 | 0.0000 | 13/1 | 4/1/1 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 104 | 1 | 310.8k | 20.6k | 13.2k | 277.0k/0 | 0.0000 | 96/1 | 8/1/1 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 23.6 | 1 | 87.2k | 3.7k | 2.5k | 81.0k/0 | 0.0000 | 16/4 | 3/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 46.5 | 1 | 109.4k | 4.4k | 6.5k | 98.4k/0 | 0.0000 | 3/3 | 4/1/1 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 67.4 | 1 | 98.5k | 4.5k | 10.0k | 84.0k/0 | 0.0000 | 20/4 | 4/1/1 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 168.8 | 1 | 311.9k | 23.5k | 25.7k | 262.7k/0 | 0.0000 | 133/34 | 9/2/1 |
| deepseek-v4-flash | opencode | t01-roman | pass | 18.4 | 1 | 89.5k | 15.9k | 740 | 72.8k/0 | 0.0026 | 13/1 | - |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 63.2 | 1 | 101.6k | 16.1k | 996 | 84.5k/0 | 0.0044 | 80/1 | - |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 24.4 | 1 | 90.3k | 16.2k | 730 | 73.3k/0 | 0.0027 | 13/4 | - |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 20.8 | 1 | 90.2k | 16.4k | 494 | 73.3k/0 | 0.0027 | 3/3 | - |
| deepseek-v4-flash | opencode | t05-todostore | pass | 28.5 | 1 | 110.0k | 17.1k | 798 | 92.2k/0 | 0.0029 | 18/4 | - |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 101.9 | 1 | 210.6k | 21.2k | 3.1k | 186.2k/0 | 0.0075 | 98/11 | - |
| deepseek-v4-flash | pi | t01-roman | pass | 7 | 1 | 10.8k | 1.9k | 596 | 8.3k/0 | 0.0015 | 13/1 | - |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 38.3 | 1 | 41.0k | 2.8k | 5.1k | 33.2k/0 | 0.0075 | 75/1 | - |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 13.6 | 1 | 15.3k | 2.3k | 995 | 12.0k/0 | 0.0021 | 16/4 | - |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 10.4 | 1 | 19.5k | 2.8k | 1.0k | 15.7k/0 | 0.0024 | 3/3 | - |
| deepseek-v4-flash | pi | t05-todostore | pass | 8 | 1 | 14.8k | 2.7k | 677 | 11.4k/0 | 0.0019 | 21/4 | - |
| deepseek-v4-flash | pi | t06-stackvm | pass | 73.9 | 1 | 97.8k | 6.4k | 12.3k | 79.1k/0 | 0.0181 | 113/16 | - |
| glm-5.3-flash | niffler | t01-roman | pass | 43.7 | 1 | 71.0k | 19.5k | 546 | 50.9k/0 | 0.0000 | 19/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 110.7 | 1 | 82.9k | 34.5k | 4.3k | 44.2k/0 | 0.0000 | 77/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 41 | 1 | 73.5k | 9.9k | 783 | 62.8k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 37.6 | 1 | 88.1k | 4.9k | 681 | 82.6k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 32.9 | 1 | 73.2k | 4.3k | 669 | 68.2k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 254.4 | 1 | 259.8k | 42.5k | 13.3k | 204.0k/0 | 0.0000 | 151/57 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 132.6 | 1 | 119.5k | 23.9k | 14.4k | 81.2k/0 | 0.0000 | 21/1 | 7/3/1 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 88.3 | 1 | 96.1k | 18.6k | 8.4k | 69.0k/0 | 0.0000 | 77/1 | 6/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 95.3 | 1 | 106.6k | 6.8k | 8.7k | 91.0k/0 | 0.0000 | 18/4 | 5/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 68.8 | 1 | 100.3k | 4.3k | 4.7k | 91.3k/0 | 0.0000 | 3/3 | 5/1/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 151.3 | 1 | 126.1k | 12.6k | 14.7k | 98.8k/0 | 0.0000 | 18/4 | 8/3/1 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 376 | 1 | 212.7k | 28.8k | 19.0k | 164.9k/0 | 0.0000 | 149/75 | 9/1/1 |
| glm-5.3-flash | opencode | t01-roman | pass | 62.4 | 1 | 84.9k | 33.7k | 560 | 50.6k/0 | 0.0058 | 13/1 | - |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 128.4 | 1 | 108.4k | 38.3k | 1.3k | 68.8k/0 | 0.0080 | 99/1 | - |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 64.4 | 1 | 86.6k | 20.2k | 665 | 65.7k/0 | 0.0047 | 13/4 | - |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 65.6 | 1 | 87.8k | 35.9k | 400 | 51.5k/0 | 0.0063 | 3/3 | - |
| glm-5.3-flash | opencode | t05-todostore | pass | 103 | 1 | 104.7k | 50.4k | 798 | 53.6k/0 | 0.0082 | 18/4 | - |
| glm-5.3-flash | opencode | t06-stackvm | pass | 333.2 | 1 | 251.0k | 109.0k | 2.9k | 139.1k/0 | 0.0231 | 152/48 | - |
| glm-5.3-flash | pi | t01-roman | pass | 14.1 | 1 | 7.5k | 4.9k | 280 | 2.3k/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 26.1 | 1 | 10.9k | 4.6k | 970 | 5.3k/0 | 0.0000 | 117/1 | - |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 21.2 | 1 | 8.4k | 6.0k | 422 | 2.0k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 26.4 | 1 | 8.5k | 4.2k | 179 | 4.2k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | pi | t05-todostore | pass | 21 | 1 | 8.6k | 3.0k | 407 | 5.2k/0 | 0.0000 | 17/4 | - |
| glm-5.3-flash | pi | t06-stackvm | pass | 36.9 | 1 | 17.5k | 13.9k | 1.8k | 1.8k/0 | 0.0000 | 96/75 | - |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 31 | 95.7k | 5.7k | 86.3k | 3.7k | 40/7 |
| deepseek-v4-flash | niffler-expert | 6/6 | 81 | 166.2k | 12.1k | 142.6k | 11.6k | 47/8 |
| deepseek-v4-flash | opencode | 6/6 | 43 | 115.4k | 17.2k | 97.1k | 1.1k | 38/4 |
| deepseek-v4-flash | pi | 6/6 | 25 | 33.2k | 3.2k | 26.6k | 3.4k | 40/5 |
| glm-5.3-flash | niffler | 6/6 | 87 | 108.1k | 19.2k | 85.5k | 3.4k | 47/12 |
| glm-5.3-flash | niffler-expert | 6/6 | 152 | 126.9k | 15.8k | 99.4k | 11.7k | 48/15 |
| glm-5.3-flash | opencode | 6/6 | 126 | 120.6k | 47.9k | 71.6k | 1.1k | 50/10 |
| glm-5.3-flash | pi | 6/6 | 24 | 10.2k | 6.1k | 3.5k | 668.5 | 43/15 |

*`invalid*` = tests pass but protected files (tests) were modified.*

## Corrections

- **pi/glm-5.3-flash** replaced from `matrix-7d020a8-pi-glm-low`: original lane used Pi default thinking=off; model requires low|high|max; rerun with config thinking=low
