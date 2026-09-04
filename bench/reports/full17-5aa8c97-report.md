# bench report — full17-5aa8c97

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 9.6 | 1 | 23.0k | 5.1k | 562 | 17.3k/0 | 0.0000 | 20/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 47.4 | 1 | 104.9k | 4.9k | 4.9k | 95.1k/0 | 0.0000 | 86/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 13.2 | 1 | 22.1k | 2.0k | 617 | 19.5k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11.4 | 1 | 29.4k | 2.1k | 1.1k | 26.2k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 10.1 | 1 | 25.0k | 1.9k | 745 | 22.4k/0 | 0.0000 | 25/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 113.8 | 1 | 111.9k | 6.7k | 12.4k | 92.8k/0 | 0.0000 | 146/43 | - |
| deepseek-v4-flash | niffler | t07-validate | pass | 28.8 | 1 | 36.9k | 2.1k | 3.5k | 31.4k/0 | 0.0000 | 22/8 | - |
| deepseek-v4-flash | niffler | t08-logsum | pass | 26.4 | 1 | 59.2k | 3.4k | 3.1k | 52.7k/0 | 0.0000 | 55/4 | - |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 14.3 | 1 | 23.6k | 2.1k | 1.2k | 20.4k/0 | 0.0000 | 4/1 | - |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 20.6 | 1 | 31.1k | 2.6k | 1.5k | 27.0k/0 | 0.0000 | 7/6 | - |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 19.5 | 1 | 26.3k | 2.0k | 2.2k | 22.1k/0 | 0.0000 | 6/7 | - |
| deepseek-v4-flash | niffler | t12-refactor | pass | 12.4 | 1 | 25.5k | 1.7k | 1.0k | 22.8k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 9 | 1 | 15.3k | 1.4k | 345 | 13.6k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 18.8 | 1 | 39.2k | 2.4k | 1.6k | 35.2k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 13.4 | 1 | 25.7k | 1.6k | 686 | 23.4k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | niffler | t16-apisum | pass | 11.5 | 1 | 20.8k | 1.7k | 524 | 18.6k/0 | 0.0000 | 23/0 | - |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 49.6 | 1 | 122.1k | 4.7k | 4.7k | 112.8k/0 | 0.0000 | 35/0 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 11.1 | 1 | 25.4k | 8.3k | 871 | 16.3k/0 | 0.0000 | 13/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 38.8 | 1 | 48.5k | 8.8k | 4.8k | 34.9k/0 | 0.0000 | 103/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 16.1 | 1 | 32.7k | 3.1k | 1.3k | 28.3k/0 | 0.0000 | 17/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 10.2 | 1 | 30.8k | 2.3k | 650 | 27.8k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 10.3 | 1 | 28.3k | 2.8k | 818 | 24.7k/0 | 0.0000 | 21/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 67 | 1 | 82.0k | 8.4k | 8.9k | 64.8k/0 | 0.0000 | 119/23 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 32.1 | 1 | 38.3k | 6.5k | 3.0k | 28.7k/0 | 0.0000 | 12/8 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 23.5 | 1 | 51.3k | 4.7k | 2.2k | 44.4k/0 | 0.0000 | 48/2 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 15 | 1 | 37.0k | 3.6k | 1.4k | 32.0k/0 | 0.0000 | 13/6 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 36.3 | 1 | 48.4k | 6.7k | 3.0k | 38.7k/0 | 0.0000 | 9/7 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 16.4 | 1 | 38.6k | 4.0k | 1.7k | 32.9k/0 | 0.0000 | 7/5 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 13.7 | 1 | 37.8k | 3.6k | 1.4k | 32.8k/0 | 0.0000 | 2/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 8.6 | 1 | 28.7k | 2.8k | 461 | 25.5k/0 | 0.0000 | 27/27 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 28.5 | 1 | 53.7k | 5.6k | 2.3k | 45.8k/0 | 0.0000 | 18/0 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 8.7 | 1 | 20.0k | 1.5k | 432 | 18.0k/0 | 0.0000 | 1/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 14.2 | 1 | 31.7k | 3.5k | 623 | 27.6k/0 | 0.0000 | 27/0 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 41.3 | 1 | 112.2k | 5.2k | 3.6k | 103.4k/0 | 0.0000 | 39/0 | 2/0/0 |
| glm-5.3-flash | niffler | t01-roman | pass | 34.7 | 1 | 20.2k | 4.5k | 375 | 15.3k/0 | 0.0000 | 17/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 39.2 | 1 | 19.6k | 10.3k | 901 | 8.4k/0 | 0.0000 | 69/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 38.9 | 1 | 19.0k | 2.7k | 776 | 15.6k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.3 | 1 | 14.1k | 2.8k | 167 | 11.1k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 23.4 | 1 | 13.8k | 1.3k | 393 | 12.1k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 77.2 | 1 | 61.7k | 9.0k | 2.7k | 50.0k/0 | 0.0000 | 171/60 | - |
| glm-5.3-flash | niffler | t07-validate | pass | 37.6 | 1 | 28.8k | 15.6k | 495 | 12.7k/0 | 0.0000 | 14/12 | - |
| glm-5.3-flash | niffler | t08-logsum | pass | 45.4 | 1 | 29.8k | 11.1k | 636 | 18.0k/0 | 0.0000 | 48/3 | - |
| glm-5.3-flash | niffler | t09-poolrace | pass | 24.7 | 1 | 13.7k | 4.7k | 390 | 8.6k/0 | 0.0000 | 4/1 | - |
| glm-5.3-flash | niffler | t10-iniparse | pass | 125.3 | 1 | 75.7k | 19.5k | 2.0k | 54.2k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 80.7 | 1 | 42.2k | 11.8k | 818 | 29.6k/0 | 0.0000 | 6/11 | - |
| glm-5.3-flash | niffler | t12-refactor | pass | 36.8 | 1 | 26.7k | 11.1k | 395 | 15.2k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | niffler | t13-batchrename | pass | 25.3 | 1 | 9.4k | 3.7k | 109 | 5.6k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | niffler | t14-todosweep | pass | 14.1 | 1 | 10.9k | 5.2k | 126 | 5.5k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | niffler | t15-pollstats | pass | 23.5 | 1 | 16.6k | 4.9k | 294 | 11.4k/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | niffler | t16-apisum | pass | 24.2 | 1 | 12.7k | 7.0k | 176 | 5.6k/0 | 0.0000 | 11/0 | - |
| glm-5.3-flash | niffler | t17-doccheck | pass | 174.9 | 1 | 128.7k | 39.8k | 3.3k | 85.6k/0 | 0.0000 | 140/0 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 22.9 | 1 | 21.4k | 8.6k | 343 | 12.4k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 77.6 | 1 | 65.8k | 16.2k | 1.8k | 47.8k/0 | 0.0000 | 63/11 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 28.3 | 1 | 21.8k | 1.7k | 557 | 19.5k/0 | 0.0000 | 13/4 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 20.8 | 1 | 22.1k | 2.9k | 246 | 18.9k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 20.7 | 1 | 21.7k | 2.0k | 482 | 19.1k/0 | 0.0000 | 16/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 62.8 | 1 | 56.5k | 12.6k | 2.3k | 41.6k/0 | 0.0000 | 120/37 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 44.8 | 1 | 41.6k | 11.8k | 800 | 29.1k/0 | 0.0000 | 7/9 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 42.2 | 1 | 38.2k | 15.7k | 688 | 21.8k/0 | 0.0000 | 45/2 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 26.5 | 1 | 26.1k | 10.3k | 415 | 15.4k/0 | 0.0000 | 4/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 39.3 | 1 | 32.4k | 2.9k | 577 | 28.9k/0 | 0.0000 | 6/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 55.9 | 1 | 55.0k | 21.2k | 722 | 33.2k/0 | 0.0000 | 6/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 40.1 | 1 | 35.1k | 13.2k | 579 | 21.3k/0 | 0.0000 | 2/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 14.1 | 1 | 13.8k | 4.6k | 148 | 9.0k/0 | 0.0000 | 27/27 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 16.4 | 1 | 14.5k | 5.4k | 144 | 9.0k/0 | 0.0000 | 18/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 19.3 | 1 | 13.1k | 3.9k | 185 | 9.0k/0 | 0.0000 | 1/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 20.7 | 1 | 22.2k | 9.3k | 248 | 12.7k/0 | 0.0000 | 11/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 44 | 1 | 32.4k | 12.1k | 979 | 19.3k/0 | 0.0000 | 56/0 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 17/17 | 25 | 43.7k | 2.9k | 38.4k | 2.4k | 29/7 |
| deepseek-v4-flash | niffler-expert | 17/17 | 23 | 43.8k | 4.8k | 36.9k | 2.2k | 28/6 |
| glm-5.3-flash | niffler | 17/17 | 50 | 32.0k | 9.7k | 21.4k | 825.6470588235294 | 33/8 |
| glm-5.3-flash | niffler-expert | 17/17 | 35 | 31.4k | 9.1k | 21.6k | 656.4705882352941 | 24/7 |

*`invalid*` = tests pass but protected files (tests) were modified.*
