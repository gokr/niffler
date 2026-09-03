# bench report — batch-ds-wip

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 8 | 1 | 26.4k | 6.6k | 657 | 19.2k/0 | 0.0000 | 13/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 112 | 1 | 615.9k | 159.1k | 8.4k | 448.4k/0 | 0.0000 | 105/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 13.5 | 1 | 32.9k | 5.4k | 606 | 26.9k/0 | 0.0000 | 16/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 7 | 1 | 33.3k | 5.7k | 465 | 27.1k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 10.2 | 1 | 39.1k | 6.8k | 1.2k | 31.1k/0 | 0.0000 | 22/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 49.4 | 1 | 87.6k | 11.1k | 7.3k | 69.1k/0 | 0.0000 | 167/42 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 9.8 | 1 | 30.1k | 7.0k | 681 | 22.4k/0 | 0.0000 | 13/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 19.1 | 1 | 53.8k | 9.2k | 1.9k | 42.6k/0 | 0.0000 | 69/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 19.1 | 1 | 44.2k | 7.6k | 1.1k | 35.5k/0 | 0.0000 | 15/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 14.4 | 1 | 49.2k | 7.3k | 920 | 41.0k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 11.5 | 1 | 38.0k | 6.5k | 864 | 30.6k/0 | 0.0000 | 16/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 61 | 1 | 120.3k | 13.2k | 8.5k | 98.6k/0 | 0.0000 | 93/13 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 33 | 139.2k | 32.4k | 103.6k | 3.1k | 54/9 |
| deepseek-v4-flash | niffler-expert | 6/6 | 22 | 55.9k | 8.5k | 45.1k | 2.3k | 35/4 |

*`invalid*` = tests pass but protected files (tests) were modified.*
