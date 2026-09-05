# bench report — full17-thinklow-86000a0

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | codewhale | t01-roman | pass | 5.5 | 1 | 34.0k | 19.2k | 463 | 14.3k/0 | 0.0000 | 8/1 | - |
| deepseek-v4-flash | codewhale | t02-jsonrepair | pass | 23 | 1 | 96.5k | 50.7k | 2.8k | 43.0k/0 | 0.0000 | 60/1 | - |
| deepseek-v4-flash | codewhale | t03-ringbuffer | pass | 10.3 | 1 | 38.8k | 21.7k | 906 | 16.3k/0 | 0.0000 | 14/4 | - |
| deepseek-v4-flash | codewhale | t04-csvbugfix | pass | 7.4 | 1 | 49.8k | 27.3k | 755 | 21.8k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | codewhale | t05-todostore | pass | 7.5 | 1 | 38.9k | 22.0k | 660 | 16.3k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | codewhale | t06-stackvm | pass | 26.3 | 1 | 124.8k | 65.1k | 4.1k | 55.6k/0 | 0.0000 | 96/11 | - |
| deepseek-v4-flash | codewhale | t07-validate | pass | 16.4 | 1 | 47.3k | 25.5k | 2.2k | 19.6k/0 | 0.0000 | 15/9 | - |
| deepseek-v4-flash | codewhale | t08-logsum | pass | 15.9 | 1 | 63.3k | 31.6k | 1.8k | 30.0k/0 | 0.0000 | 81/3 | - |
| deepseek-v4-flash | codewhale | t09-poolrace | pass | 10 | 1 | 38.4k | 21.5k | 787 | 16.1k/0 | 0.0000 | 4/1 | - |
| deepseek-v4-flash | codewhale | t10-iniparse | pass | 133.6 | 1 | 921.3k | 473.8k | 8.9k | 438.7k/0 | 0.0000 | 0/0 | - |
| deepseek-v4-flash | codewhale | t11-asyncbugs | pass | 11.8 | 1 | 60.9k | 30.6k | 1.4k | 28.9k/0 | 0.0000 | 0/0 | - |
| deepseek-v4-flash | codewhale | t12-refactor | pass | 11.5 | 1 | 58.6k | 29.4k | 1.1k | 28.0k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | codewhale | t13-batchrename | pass | 6.1 | 1 | 25.9k | 15.4k | 290 | 10.2k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | codewhale | t14-todosweep | pass | 13.6 | 1 | 56.3k | 31.0k | 831 | 24.4k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | codewhale | t15-pollstats | pass | 10.1 | 1 | 45.7k | 25.1k | 571 | 20.1k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | codewhale | t16-apisum | pass | 9.1 | 1 | 38.3k | 21.5k | 611 | 16.1k/0 | 0.0000 | 12/0 | - |
| deepseek-v4-flash | codewhale | t17-doccheck | pass | 10.3 | 1 | 55.2k | 30.2k | 933 | 24.1k/0 | 0.0000 | 38/0 | - |
| deepseek-v4-flash | niffler | t01-roman | pass | 5.5 | 1 | 13.7k | 3.5k | 428 | 9.7k/0 | 0.0000 | 22/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 39.5 | 1 | 42.2k | 4.7k | 5.2k | 32.4k/0 | 0.0000 | 58/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 10.6 | 1 | 21.5k | 1.8k | 1.0k | 18.7k/0 | 0.0000 | 17/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 6.3 | 1 | 20.7k | 2.2k | 576 | 17.9k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 12.7 | 1 | 36.5k | 3.3k | 1.8k | 31.4k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 54.3 | 1 | 115.5k | 6.9k | 7.8k | 100.7k/0 | 0.0000 | 179/53 | - |
| deepseek-v4-flash | niffler | t07-validate | pass | 18.3 | 1 | 37.8k | 3.9k | 2.5k | 31.4k/0 | 0.0000 | 16/11 | - |
| deepseek-v4-flash | niffler | t08-logsum | pass | 34 | 1 | 66.2k | 3.9k | 4.9k | 57.5k/0 | 0.0000 | 70/3 | - |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 14.7 | 1 | 19.0k | 1.7k | 653 | 16.6k/0 | 0.0000 | 4/1 | - |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 25.9 | 1 | 28.7k | 2.3k | 1.6k | 24.8k/0 | 0.0000 | 6/5 | - |
| deepseek-v4-flash | niffler | t11-asyncbugs | fail | 54.2 | 6 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 | - |
| deepseek-v4-flash | niffler | t12-refactor | pass | 8.5 | 1 | 46.6k | 4.8k | 1.8k | 39.9k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 9.3 | 1 | 28.0k | 4.3k | 556 | 23.2k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 23.3 | 1 | 40.7k | 3.3k | 2.5k | 34.9k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 10.2 | 1 | 15.4k | 1.3k | 435 | 13.7k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | niffler | t16-apisum | pass | 8.7 | 1 | 13.8k | 1.4k | 472 | 11.9k/0 | 0.0000 | 23/0 | - |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 29.4 | 1 | 58.4k | 3.3k | 3.3k | 51.7k/0 | 0.0000 | 40/0 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 8.9 | 1 | 27.4k | 10.3k | 1.1k | 16.0k/0 | 0.0000 | 20/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 31.1 | 1 | 26.1k | 4.4k | 3.4k | 18.3k/0 | 0.0000 | 73/1 | 0/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 10.5 | 1 | 33.2k | 9.0k | 722 | 23.4k/0 | 0.0000 | 17/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 11.7 | 1 | 36.4k | 3.1k | 1.2k | 32.1k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 12.2 | 1 | 49.2k | 4.7k | 1.6k | 42.9k/0 | 0.0000 | 18/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 56.8 | 1 | 92.1k | 8.4k | 9.3k | 74.4k/0 | 0.0000 | 126/24 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 16.6 | 1 | 46.0k | 4.2k | 2.4k | 39.4k/0 | 0.0000 | 9/9 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 48.8 | 1 | 89.6k | 14.5k | 3.6k | 71.4k/0 | 0.0000 | 55/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 18 | 1 | 56.2k | 10.7k | 1.8k | 43.8k/0 | 0.0000 | 7/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 21.3 | 1 | 42.6k | 4.1k | 1.3k | 37.1k/0 | 0.0000 | 5/6 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 13.2 | 1 | 40.1k | 9.5k | 1.4k | 29.2k/0 | 0.0000 | 5/10 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 8.1 | 1 | 20.8k | 1.4k | 601 | 18.8k/0 | 0.0000 | 2/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 12.2 | 1 | 47.5k | 5.2k | 864 | 41.3k/0 | 0.0000 | 27/27 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 15.5 | 1 | 48.5k | 6.6k | 1.8k | 40.2k/0 | 0.0000 | 18/0 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 8.8 | 1 | 25.1k | 2.1k | 492 | 22.5k/0 | 0.0000 | 1/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 9.4 | 1 | 20.5k | 1.5k | 449 | 18.6k/0 | 0.0000 | 17/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 32.9 | 1 | 81.9k | 7.4k | 4.9k | 69.6k/0 | 0.0000 | 69/0 | 2/0/0 |
| deepseek-v4-flash | opencode | t01-roman | pass | 10.8 | 1 | 68.9k | 17.2k | 544 | 51.2k/0 | 0.0027 | 13/1 | - |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 18.8 | 1 | 90.0k | 17.9k | 890 | 71.2k/0 | 0.0030 | 54/1 | - |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 16.4 | 1 | 106.9k | 16.1k | 871 | 90.0k/0 | 0.0027 | 14/4 | - |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 13.8 | 1 | 87.8k | 15.8k | 520 | 71.4k/0 | 0.0026 | 3/3 | - |
| deepseek-v4-flash | opencode | t05-todostore | pass | 16.5 | 1 | 90.7k | 16.6k | 897 | 73.2k/0 | 0.0028 | 20/4 | - |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 54.3 | 1 | 148.2k | 21.5k | 3.2k | 123.5k/0 | 0.0053 | 141/46 | - |
| deepseek-v4-flash | opencode | t07-validate | pass | 29.3 | 1 | 117.9k | 18.1k | 1.1k | 98.7k/0 | 0.0037 | 23/9 | - |
| deepseek-v4-flash | opencode | t08-logsum | pass | 35.5 | 1 | 175.6k | 17.8k | 1.7k | 156.2k/0 | 0.0036 | 45/2 | - |
| deepseek-v4-flash | opencode | t09-poolrace | pass | 20.6 | 1 | 106.9k | 16.3k | 656 | 90.0k/0 | 0.0027 | 5/2 | - |
| deepseek-v4-flash | opencode | t10-iniparse | pass | 33 | 1 | 74.7k | 16.9k | 915 | 57.0k/0 | 0.0028 | 6/5 | - |
| deepseek-v4-flash | opencode | t11-asyncbugs | pass | 68.2 | 2 | 361.5k | 19.8k | 2.5k | 339.2k/0 | 0.0049 | 0/0 | - |
| deepseek-v4-flash | opencode | t12-refactor | pass | 19.2 | 1 | 110.8k | 16.8k | 968 | 93.1k/0 | 0.0030 | 2/4 | - |
| deepseek-v4-flash | opencode | t13-batchrename | pass | 20.1 | 1 | 76.4k | 17.9k | 391 | 58.1k/0 | 0.0028 | 27/27 | - |
| deepseek-v4-flash | opencode | t14-todosweep | pass | 16.6 | 1 | 54.1k | 16.4k | 428 | 37.2k/0 | 0.0026 | 18/0 | - |
| deepseek-v4-flash | opencode | t15-pollstats | pass | 20.1 | 1 | 108.0k | 16.1k | 782 | 91.1k/0 | 0.0027 | 1/0 | - |
| deepseek-v4-flash | opencode | t16-apisum | pass | 17.7 | 1 | 91.1k | 16.6k | 809 | 73.7k/0 | 0.0028 | 21/0 | - |
| deepseek-v4-flash | opencode | t17-doccheck | pass | 42.7 | 1 | 225.5k | 17.6k | 1.9k | 206.0k/0 | 0.0040 | 58/0 | - |
| glm-5.3-flash | codewhale | t01-roman | pass | 19.1 | 1 | 33.7k | 19.2k | 336 | 14.1k/0 | 0.0000 | 19/1 | - |
| glm-5.3-flash | codewhale | t02-jsonrepair | pass | 57.9 | 1 | 41.7k | 24.2k | 2.1k | 15.4k/0 | 0.0000 | 51/1 | - |
| glm-5.3-flash | codewhale | t03-ringbuffer | pass | 28.5 | 1 | 36.2k | 21.5k | 526 | 14.1k/0 | 0.0000 | 18/4 | - |
| glm-5.3-flash | codewhale | t04-csvbugfix | pass | 21.4 | 1 | 33.9k | 20.3k | 290 | 13.4k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | codewhale | t05-todostore | pass | 23.4 | 1 | 40.7k | 21.6k | 515 | 18.6k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | codewhale | t06-stackvm | pass | 114.1 | 1 | 179.8k | 95.9k | 5.5k | 78.4k/0 | 0.0000 | 146/36 | - |
| glm-5.3-flash | codewhale | t07-validate | pass | 42.2 | 1 | 57.9k | 35.2k | 1.5k | 21.2k/0 | 0.0000 | 11/8 | - |
| glm-5.3-flash | codewhale | t08-logsum | pass | 84.3 | 1 | 153.9k | 80.5k | 2.2k | 71.2k/0 | 0.0000 | 59/3 | - |
| glm-5.3-flash | codewhale | t09-poolrace | pass | 47.8 | 1 | 58.7k | 32.7k | 1.1k | 24.9k/0 | 0.0000 | 6/1 | - |
| glm-5.3-flash | codewhale | t10-iniparse | pass | 106.4 | 2 | 82.0k | 49.9k | 2.5k | 29.6k/0 | 0.0000 | 0/0 | - |
| glm-5.3-flash | codewhale | t11-asyncbugs | pass | 38.5 | 1 | 45.1k | 22.7k | 1.1k | 21.4k/0 | 0.0000 | 5/10 | - |
| glm-5.3-flash | codewhale | t12-refactor | pass | 34.2 | 1 | 53.5k | 26.8k | 522 | 26.2k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | codewhale | t13-batchrename | pass | 19.3 | 1 | 24.2k | 15.6k | 296 | 8.3k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | codewhale | t14-todosweep | pass | 41.7 | 1 | 47.7k | 25.5k | 960 | 21.2k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | codewhale | t15-pollstats | pass | 20.5 | 1 | 27.1k | 14.4k | 176 | 12.5k/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | codewhale | t16-apisum | pass | 53.9 | 1 | 20.1k | 19.7k | 438 | 0/0 | 0.0000 | 20/0 | - |
| glm-5.3-flash | codewhale | t17-doccheck | pass | 406.2 | 1 | 98.5k | 71.2k | 4.9k | 22.4k/0 | 0.0000 | 46/0 | - |
| glm-5.3-flash | niffler | t01-roman | pass | 17.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 47.3 | 1 | 17.2k | 4.3k | 845 | 12.0k/0 | 0.0000 | 84/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 31.8 | 1 | 16.1k | 6.6k | 462 | 9.0k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.4 | 1 | 12.4k | 1.8k | 202 | 10.4k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 20.9 | 1 | 12.2k | 4.3k | 404 | 7.4k/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 179.6 | 1 | 177.3k | 17.9k | 5.3k | 154.1k/0 | 0.0000 | 185/55 | - |
| glm-5.3-flash | niffler | t07-validate | pass | 51 | 1 | 25.6k | 14.2k | 554 | 10.8k/0 | 0.0000 | 6/11 | - |
| glm-5.3-flash | niffler | t08-logsum | pass | 35.1 | 1 | 76.3k | 24.9k | 1.3k | 50.0k/0 | 0.0000 | 51/2 | - |
| glm-5.3-flash | niffler | t09-poolrace | pass | 24.5 | 1 | 11.4k | 3.7k | 214 | 7.4k/0 | 0.0000 | 5/1 | - |
| glm-5.3-flash | niffler | t10-iniparse | pass | 34.4 | 1 | 16.8k | 7.8k | 421 | 8.6k/0 | 0.0000 | 9/8 | - |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 45.4 | 1 | 28.2k | 12.4k | 486 | 15.3k/0 | 0.0000 | 6/11 | - |
| glm-5.3-flash | niffler | t12-refactor | pass | 58.3 | 1 | 17.9k | 17.6k | 282 | 0/0 | 0.0000 | 6/2 | - |
| glm-5.3-flash | niffler | t13-batchrename | pass | 40 | 1 | 9.0k | 8.8k | 121 | 0/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | niffler | t14-todosweep | pass | 99.3 | 1 | 12.9k | 12.6k | 316 | 0/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | niffler | t15-pollstats | pass | 92.5 | 1 | 11.8k | 11.5k | 275 | 0/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | niffler | t16-apisum | pass | 312.5 | 1 | 25.5k | 25.1k | 348 | 0/0 | 0.0000 | 12/0 | - |
| glm-5.3-flash | niffler | t17-doccheck | pass | 208 | 1 | 23.7k | 22.7k | 954 | 0/0 | 0.0000 | 28/0 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 21 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 13/4 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 67.1 | 1 | 44.7k | 20.5k | 2.5k | 21.7k/0 | 0.0000 | 71/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 33.2 | 1 | 28.9k | 14.0k | 652 | 14.3k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 29.8 | 1 | 28.2k | 8.1k | 285 | 19.8k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 22.8 | 1 | 25.0k | 4.9k | 480 | 19.6k/0 | 0.0000 | 19/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 124 | 1 | 84.8k | 13.0k | 3.4k | 68.3k/0 | 0.0000 | 156/34 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 31.8 | 1 | 38.8k | 8.8k | 674 | 29.4k/0 | 0.0000 | 9/7 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 27.8 | 1 | 241.5k | 53.3k | 4.8k | 183.4k/0 | 0.0000 | 47/2 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 26.4 | 1 | 24.7k | 4.7k | 366 | 19.6k/0 | 0.0000 | 4/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 53.2 | 1 | 53.6k | 34.8k | 1.1k | 17.7k/0 | 0.0000 | 6/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 47.4 | 1 | 38.7k | 13.3k | 675 | 24.7k/0 | 0.0000 | 6/11 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 71.9 | 1 | 35.4k | 22.7k | 607 | 12.2k/0 | 0.0000 | 2/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 32.8 | 1 | 25.9k | 13.6k | 122 | 12.2k/0 | 0.0000 | 27/27 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 66.7 | 1 | 25.5k | 13.2k | 210 | 12.0k/0 | 0.0000 | 18/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 43.2 | 1 | 14.7k | 8.3k | 368 | 6.0k/0 | 0.0000 | 1/0 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 234.4 | 1 | 24.7k | 12.2k | 551 | 12.0k/0 | 0.0000 | 9/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 825.3 | 1 | 263.2k | 142.4k | 7.3k | 113.5k/0 | 0.0000 | 31/0 | 2/1/1 |
| glm-5.3-flash | opencode | t01-roman | pass | 29.8 | 1 | 65.4k | 31.2k | 343 | 33.9k/0 | 0.0039 | 13/1 | - |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 37.9 | 1 | 85.1k | 20.9k | 720 | 63.5k/0 | 0.0035 | 61/1 | - |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 37.8 | 1 | 66.6k | 20.1k | 468 | 46.0k/0 | 0.0030 | 16/4 | - |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 34.5 | 1 | 83.1k | 4.2k | 252 | 78.7k/0 | 0.0021 | 3/3 | - |
| glm-5.3-flash | opencode | t05-todostore | pass | 30 | 1 | 66.6k | 20.2k | 481 | 45.9k/0 | 0.0031 | 14/4 | - |
| glm-5.3-flash | opencode | t06-stackvm | pass | 80.8 | 1 | 122.7k | 25.0k | 3.0k | 94.7k/0 | 0.0052 | 151/54 | - |
| glm-5.3-flash | opencode | t07-validate | pass | 35.3 | 1 | 69.6k | 21.2k | 438 | 47.9k/0 | 0.0032 | 7/8 | - |
| glm-5.3-flash | opencode | t08-logsum | pass | 66.9 | 1 | 141.6k | 18.9k | 822 | 121.9k/0 | 0.0046 | 45/2 | - |
| glm-5.3-flash | opencode | t09-poolrace | pass | 38.7 | 1 | 65.9k | 16.7k | 330 | 48.8k/0 | 0.0021 | 4/1 | - |
| glm-5.3-flash | opencode | t10-iniparse | pass | 56.1 | 1 | 102.8k | 17.8k | 496 | 84.5k/0 | 0.0027 | 6/7 | - |
| glm-5.3-flash | opencode | t11-asyncbugs | pass | 99.2 | 1 | 222.4k | 20.4k | 1.4k | 200.6k/0 | 0.0049 | 0/0 | - |
| glm-5.3-flash | opencode | t12-refactor | pass | 29.3 | 1 | 66.8k | 15.7k | 356 | 50.8k/0 | 0.0020 | 2/4 | - |
| glm-5.3-flash | opencode | t13-batchrename | pass | 49.7 | 1 | 99.7k | 20.3k | 182 | 79.2k/0 | 0.0028 | 27/27 | - |
| glm-5.3-flash | opencode | t14-todosweep | pass | 30 | 1 | 50.7k | 4.5k | 212 | 46.0k/0 | 0.0011 | 18/0 | - |
| glm-5.3-flash | opencode | t15-pollstats | pass | 40.3 | 1 | 83.3k | 20.2k | 363 | 62.7k/0 | 0.0026 | 1/0 | - |
| glm-5.3-flash | opencode | t16-apisum | pass | 34.2 | 1 | 82.3k | 19.9k | 384 | 62.0k/0 | 0.0025 | 12/0 | - |
| glm-5.3-flash | opencode | t17-doccheck | pass | 83.9 | 1 | 155.6k | 20.2k | 895 | 134.5k/0 | 0.0038 | 39/0 | - |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | codewhale | 17/17 | 19 | 105.5k | 55.4k | 48.4k | 1.7k | 23/4 |
| deepseek-v4-flash | niffler | 16/17 | 21 | 35.6k | 3.1k | 30.4k | 2.1k | 30/7 |
| deepseek-v4-flash | niffler-expert | 17/17 | 20 | 46.1k | 6.3k | 37.6k | 2.2k | 28/6 |
| deepseek-v4-flash | opencode | 17/17 | 27 | 123.2k | 17.4k | 104.7k | 1.1k | 27/6 |
| glm-5.3-flash | codewhale | 17/17 | 68 | 60.9k | 35.1k | 24.3k | 1.5k | 26/6 |
| glm-5.3-flash | niffler | 17/17 | 78 | 29.1k | 11.6k | 16.8k | 735 | 28/8 |
| glm-5.3-flash | niffler-expert | 17/17 | 103 | 58.7k | 22.8k | 34.5k | 1.4k | 26/6 |
| glm-5.3-flash | opencode | 17/17 | 48 | 95.9k | 18.7k | 76.6k | 653 | 25/7 |

*`invalid*` = tests pass but protected files (tests) were modified.*
