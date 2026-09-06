# bench report — full17-pi-max-86000a0

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | pi | t01-roman | pass | 5.6 | 1 | 10.6k | 2.6k | 493 | 7.6k/0 | 0.0015 | 20/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 112.8 | 1 | 106.6k | 3.9k | 15.1k | 87.6k/0 | 0.0208 | 146/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 14.3 | 1 | 16.7k | 2.4k | 1.3k | 12.9k/0 | 0.0025 | 15/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 9.3 | 1 | 19.0k | 2.8k | 1.1k | 15.1k/0 | 0.0025 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | error | 1.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t06-stackvm | error | 1.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t07-validate | error | 1.1 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t08-logsum | error | 1.6 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t09-poolrace | error | 1.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t10-iniparse | error | 2.9 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t11-asyncbugs | error | 1.1 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t12-refactor | error | 1.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t13-batchrename | error | 1.2 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t14-todosweep | error | 1 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t15-pollstats | error | 1.2 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t16-apisum | error | 2 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | pi | t17-doccheck | error | 1 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| glm-5.3-flash | pi | t01-roman | pass | 51.1 | 1 | 12.1k | 10.5k | 530 | 1.0k/0 | 0.0000 | 13/1 |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 112.5 | 1 | 18.8k | 15.2k | 2.6k | 1.0k/0 | 0.0000 | 80/1 |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 72.9 | 1 | 20.8k | 19.9k | 885 | 0/0 | 0.0000 | 14/4 |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 94.1 | 1 | 20.7k | 19.7k | 1.0k | 0/0 | 0.0000 | 3/3 |
| glm-5.3-flash | pi | t05-todostore | pass | 106 | 1 | 16.8k | 15.2k | 1.5k | 0/0 | 0.0000 | 14/4 |
| glm-5.3-flash | pi | t06-stackvm | pass | 1417.4 | 1 | 39.3k | 12.6k | 9.8k | 17.0k/0 | 0.0000 | 187/68 |
| glm-5.3-flash | pi | t07-validate | pass | 212.9 | 1 | 30.9k | 27.1k | 3.8k | 0/0 | 0.0000 | 23/13 |
| glm-5.3-flash | pi | t08-logsum | pass | 361.6 | 1 | 40.8k | 25.6k | 6.3k | 9.0k/0 | 0.0000 | 89/4 |
| glm-5.3-flash | pi | t09-poolrace | pass | 108.9 | 1 | 32.4k | 24.8k | 1.8k | 5.8k/0 | 0.0000 | 6/1 |
| glm-5.3-flash | pi | t10-iniparse | pass | 160 | 1 | 27.7k | 17.3k | 3.9k | 6.5k/0 | 0.0000 | 8/5 |
| glm-5.3-flash | pi | t11-asyncbugs | pass | 34.8 | 1 | 15.5k | 7.9k | 1.6k | 6.0k/0 | 0.0000 | 6/4 |
| glm-5.3-flash | pi | t12-refactor | pass | 25.1 | 1 | 16.9k | 8.4k | 829 | 7.7k/0 | 0.0000 | 2/4 |
| glm-5.3-flash | pi | t13-batchrename | pass | 13.4 | 1 | 11.3k | 7.3k | 315 | 3.7k/0 | 0.0000 | 27/27 |
| glm-5.3-flash | pi | t14-todosweep | pass | 20.1 | 1 | 12.7k | 3.3k | 442 | 9.0k/0 | 0.0000 | 18/0 |
| glm-5.3-flash | pi | t15-pollstats | pass | 20.4 | 1 | 15.4k | 5.9k | 673 | 8.8k/0 | 0.0000 | 1/0 |
| glm-5.3-flash | pi | t16-apisum | pass | 23.2 | 1 | 15.3k | 4.2k | 602 | 10.4k/0 | 0.0000 | 28/0 |
| glm-5.3-flash | pi | t17-doccheck | pass | 97.4 | 1 | 36.1k | 19.6k | 3.9k | 12.5k/0 | 0.0000 | 112/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | pi | 4/17 | 9 | 9.0k | 688 | 7.2k | 1.1k | 11/1 |
| glm-5.3-flash | pi | 17/17 | 172 | 22.6k | 14.4k | 5.8k | 2.4k | 37/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
