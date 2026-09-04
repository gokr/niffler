# bench report — full17-flat-fc2f5d4

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 11.3 | 1 | 14.5k | 3.4k | 418 | 10.8k/0 | 0.0000 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 21 | 1 | 27.0k | 4.3k | 2.2k | 20.5k/0 | 0.0000 | 16/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 14.4 | 1 | 28.4k | 2.1k | 996 | 25.2k/0 | 0.0000 | 13/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11.9 | 1 | 34.6k | 2.1k | 860 | 31.6k/0 | 0.0000 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 17.4 | 1 | 50.0k | 3.6k | 1.7k | 44.7k/0 | 0.0000 | 20/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 49.8 | 1 | 71.4k | 6.9k | 7.4k | 57.1k/0 | 0.0000 | 178/39 |
| deepseek-v4-flash | niffler | t07-validate | pass | 20.7 | 1 | 39.7k | 3.9k | 2.7k | 33.2k/0 | 0.0000 | 14/9 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 19.5 | 1 | 45.8k | 2.8k | 2.3k | 40.7k/0 | 0.0000 | 54/2 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 9.4 | 1 | 17.5k | 1.7k | 616 | 15.2k/0 | 0.0000 | 4/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 29 | 1 | 25.5k | 3.1k | 1.1k | 21.4k/0 | 0.0000 | 6/7 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 14.1 | 1 | 25.0k | 2.6k | 1.2k | 21.2k/0 | 0.0000 | 5/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 17.6 | 1 | 23.7k | 2.6k | 788 | 20.4k/0 | 0.0000 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 12.6 | 1 | 29.8k | 1.3k | 529 | 27.9k/0 | 0.0000 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 8.7 | 1 | 23.6k | 3.0k | 302 | 20.4k/0 | 0.0000 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 28.4 | 1 | 45.8k | 4.8k | 608 | 40.3k/0 | 0.0000 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 12.7 | 1 | 22.8k | 1.9k | 875 | 20.0k/0 | 0.0000 | 12/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 14.7 | 1 | 134.3k | 9.3k | 4.4k | 120.6k/0 | 0.0000 | 59/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 24.5 | 1 | 12.3k | 6.2k | 270 | 5.9k/0 | 0.0000 | 13/1 |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 43.2 | 1 | 17.7k | 8.3k | 469 | 9.0k/0 | 0.0000 | 45/11 |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 28.3 | 1 | 13.6k | 4.7k | 481 | 8.4k/0 | 0.0000 | 13/4 |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 42.1 | 1 | 13.7k | 2.2k | 196 | 11.4k/0 | 0.0000 | 3/3 |
| glm-5.3-flash | niffler | t05-todostore | pass | 28.7 | 1 | 18.5k | 2.4k | 444 | 15.7k/0 | 0.0000 | 16/4 |
| glm-5.3-flash | niffler | t06-stackvm | pass | 116.6 | 1 | 58.9k | 7.8k | 3.6k | 47.6k/0 | 0.0000 | 155/48 |
| glm-5.3-flash | niffler | t07-validate | pass | 49.7 | 1 | 12.4k | 5.1k | 495 | 6.8k/0 | 0.0000 | 15/11 |
| glm-5.3-flash | niffler | t08-logsum | pass | 162.3 | 1 | 98.7k | 13.0k | 2.3k | 83.3k/0 | 0.0000 | 47/3 |
| glm-5.3-flash | niffler | t09-poolrace | pass | 150.3 | 1 | 13.5k | 4.7k | 432 | 8.4k/0 | 0.0000 | 4/1 |
| glm-5.3-flash | niffler | t10-iniparse | pass | 95.9 | 1 | 18.5k | 3.1k | 413 | 15.0k/0 | 0.0000 | 6/5 |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 60.1 | 1 | 42.4k | 13.9k | 878 | 27.6k/0 | 0.0000 | 7/6 |
| glm-5.3-flash | niffler | t12-refactor | pass | 76.9 | 1 | 18.1k | 8.6k | 330 | 9.1k/0 | 0.0000 | 2/4 |
| glm-5.3-flash | niffler | t13-batchrename | pass | 27.5 | 1 | 9.2k | 3.8k | 120 | 5.2k/0 | 0.0000 | 27/27 |
| glm-5.3-flash | niffler | t14-todosweep | pass | 47.3 | 1 | 13.9k | 1.6k | 133 | 12.2k/0 | 0.0000 | 18/0 |
| glm-5.3-flash | niffler | t15-pollstats | pass | 22.3 | 1 | 12.4k | 1.2k | 179 | 11.0k/0 | 0.0000 | 1/0 |
| glm-5.3-flash | niffler | t16-apisum | pass | 28.4 | 1 | 13.1k | 1.7k | 173 | 11.2k/0 | 0.0000 | 11/0 |
| glm-5.3-flash | niffler | t17-doccheck | pass | 38.7 | 1 | 59.6k | 10.3k | 894 | 48.4k/0 | 0.0000 | 40/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 17/17 | 18 | 38.8k | 3.5k | 33.6k | 1.7k | 26/7 |
| glm-5.3-flash | niffler | 17/17 | 61 | 26.3k | 5.8k | 19.8k | 695 | 25/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
