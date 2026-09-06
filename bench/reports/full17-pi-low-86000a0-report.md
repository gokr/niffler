# bench report — full17-pi-low-86000a0

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | pi | t01-roman | pass | 10 | 1 | 18.2k | 2.4k | 1.1k | 14.7k/0 | 0.0023 | 31/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 40.7 | 1 | 56.9k | 3.2k | 5.3k | 48.5k/0 | 0.0082 | 114/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 14.3 | 1 | 15.3k | 2.5k | 1.0k | 11.8k/0 | 0.0022 | 16/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 10.3 | 1 | 14.6k | 2.4k | 847 | 11.3k/0 | 0.0020 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 9.3 | 1 | 15.7k | 2.9k | 950 | 11.8k/0 | 0.0022 | 18/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 54 | 1 | 87.7k | 6.7k | 8.3k | 72.7k/0 | 0.0134 | 107/56 |
| deepseek-v4-flash | pi | t07-validate | pass | 20.4 | 1 | 29.3k | 4.2k | 3.0k | 22.1k/0 | 0.0052 | 11/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 15.8 | 1 | 34.6k | 3.7k | 2.0k | 28.9k/0 | 0.0041 | 54/2 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 8.8 | 1 | 12.1k | 2.3k | 915 | 9.0k/0 | 0.0019 | 4/1 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 24.9 | 1 | 32.4k | 3.9k | 2.3k | 26.2k/0 | 0.0044 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 10.6 | 1 | 16.3k | 2.8k | 1.3k | 12.2k/0 | 0.0027 | 7/6 |
| deepseek-v4-flash | pi | t12-refactor | pass | 10.1 | 1 | 15.4k | 2.4k | 1.1k | 11.9k/0 | 0.0022 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 9.5 | 1 | 20.3k | 4.1k | 714 | 15.5k/0 | 0.0024 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 10.8 | 1 | 25.7k | 3.4k | 1.2k | 21.1k/0 | 0.0029 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 8.9 | 1 | 20.4k | 2.6k | 867 | 16.9k/0 | 0.0022 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 7.9 | 1 | 14.1k | 2.4k | 650 | 11.0k/0 | 0.0017 | 12/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 19.7 | 1 | 53.3k | 3.7k | 2.4k | 47.1k/0 | 0.0052 | 96/0 |
| glm-5.3-flash | pi | t01-roman | pass | 40.7 | 1 | 8.0k | 7.5k | 440 | 0/0 | 0.0000 | 15/1 |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 76.6 | 1 | 10.7k | 9.8k | 911 | 0/0 | 0.0000 | 59/1 |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 65.4 | 1 | 8.6k | 8.2k | 439 | 0/0 | 0.0000 | 13/4 |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 29.3 | 1 | 8.6k | 8.4k | 200 | 0/0 | 0.0000 | 3/3 |
| glm-5.3-flash | pi | t05-todostore | pass | 65 | 1 | 12.0k | 11.5k | 471 | 0/0 | 0.0000 | 19/4 |
| glm-5.3-flash | pi | t06-stackvm | pass | 237.2 | 1 | 55.3k | 42.8k | 3.6k | 9.0k/0 | 0.0000 | 138/55 |
| glm-5.3-flash | pi | t07-validate | pass | 57 | 1 | 16.0k | 15.5k | 483 | 0/0 | 0.0000 | 6/7 |
| glm-5.3-flash | pi | t08-logsum | pass | 64.6 | 1 | 23.4k | 22.6k | 745 | 0/0 | 0.0000 | 56/2 |
| glm-5.3-flash | pi | t09-poolrace | pass | 41.1 | 1 | 10.3k | 10.0k | 289 | 0/0 | 0.0000 | 4/1 |
| glm-5.3-flash | pi | t10-iniparse | pass | 64.4 | 1 | 15.8k | 15.3k | 536 | 0/0 | 0.0000 | 7/6 |
| glm-5.3-flash | pi | t11-asyncbugs | pass | 57.9 | 1 | 21.7k | 21.2k | 523 | 0/0 | 0.0000 | 6/11 |
| glm-5.3-flash | pi | t12-refactor | pass | 48.2 | 1 | 18.4k | 18.0k | 398 | 0/0 | 0.0000 | 2/4 |
| glm-5.3-flash | pi | t13-batchrename | pass | 15.7 | 1 | 5.3k | 5.2k | 95 | 0/0 | 0.0000 | 27/27 |
| glm-5.3-flash | pi | t14-todosweep | pass | 17.8 | 1 | 6.5k | 6.4k | 144 | 0/0 | 0.0000 | 18/0 |
| glm-5.3-flash | pi | t15-pollstats | pass | 17.6 | 1 | 5.5k | 5.4k | 167 | 0/0 | 0.0000 | 1/0 |
| glm-5.3-flash | pi | t16-apisum | pass | 23 | 1 | 7.7k | 7.6k | 168 | 0/0 | 0.0000 | 12/0 |
| glm-5.3-flash | pi | t17-doccheck | pass | 136.9 | 1 | 43.8k | 42.0k | 1.8k | 0/0 | 0.0000 | 48/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | pi | 17/17 | 17 | 28.4k | 3.3k | 23.1k | 2.0k | 31/7 |
| glm-5.3-flash | pi | 17/17 | 62 | 16.3k | 15.1k | 527 | 673 | 26/7 |

*`invalid*` = tests pass but protected files (tests) were modified.*
