# bench report — full17-thinkmax-86000a0

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | codewhale | t01-roman | pass | 6.8 | 1 | 36.8k | 20.7k | 559 | 15.6k/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | codewhale | t02-jsonrepair | pass | 33 | 1 | 55.0k | 28.3k | 4.1k | 22.7k/0 | 0.0000 | 63/1 | - |
| deepseek-v4-flash | codewhale | t03-ringbuffer | pass | 11.9 | 1 | 39.2k | 21.8k | 719 | 16.6k/0 | 0.0000 | 16/4 | - |
| deepseek-v4-flash | codewhale | t04-csvbugfix | pass | 7.7 | 1 | 38.7k | 21.7k | 620 | 16.4k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | codewhale | t05-todostore | pass | 7.3 | 1 | 39.6k | 22.3k | 628 | 16.6k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | codewhale | t06-stackvm | pass | 89.7 | 1 | 156.5k | 76.9k | 12.0k | 67.6k/0 | 0.0000 | 173/51 | - |
| deepseek-v4-flash | codewhale | t07-validate | pass | 14.8 | 1 | 44.3k | 24.3k | 1.6k | 18.4k/0 | 0.0000 | 4/8 | - |
| deepseek-v4-flash | codewhale | t08-logsum | pass | 31.9 | 1 | 220.2k | 112.8k | 3.6k | 103.8k/0 | 0.0000 | 55/3 | - |
| deepseek-v4-flash | codewhale | t09-poolrace | pass | 13.7 | 1 | 57.4k | 31.3k | 1.1k | 25.0k/0 | 0.0000 | 9/2 | - |
| deepseek-v4-flash | codewhale | t10-iniparse | pass | 39.2 | 1 | 101.1k | 52.8k | 2.8k | 45.4k/0 | 0.0000 | 5/6 | - |
| deepseek-v4-flash | codewhale | t11-asyncbugs | pass | 11.5 | 1 | 44.7k | 24.5k | 1.4k | 18.7k/0 | 0.0000 | 5/10 | - |
| deepseek-v4-flash | codewhale | t12-refactor | pass | 11.9 | 1 | 55.0k | 29.6k | 1.4k | 24.1k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | codewhale | t13-batchrename | pass | 5.2 | 1 | 27.1k | 15.9k | 416 | 10.8k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | codewhale | t14-todosweep | pass | 10.9 | 1 | 43.8k | 24.2k | 1.2k | 18.4k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | codewhale | t15-pollstats | pass | 5.1 | 1 | 26.5k | 15.7k | 372 | 10.5k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | codewhale | t16-apisum | pass | 8.9 | 1 | 40.8k | 22.8k | 765 | 17.3k/0 | 0.0000 | 20/0 | - |
| deepseek-v4-flash | codewhale | t17-doccheck | pass | 84.7 | 1 | 436.4k | 217.3k | 10.2k | 208.9k/0 | 0.0000 | 105/0 | - |
| deepseek-v4-flash | niffler | t01-roman | pass | 7.1 | 1 | 16.0k | 4.2k | 559 | 11.3k/0 | 0.0000 | 20/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 44.4 | 1 | 65.0k | 2.7k | 5.7k | 56.6k/0 | 0.0000 | 90/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 27.9 | 1 | 26.1k | 1.6k | 2.8k | 21.8k/0 | 0.0000 | 17/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 10.2 | 1 | 22.9k | 2.5k | 823 | 19.6k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 12.3 | 1 | 24.3k | 3.0k | 1.1k | 20.2k/0 | 0.0000 | 19/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 102.2 | 1 | 126.2k | 6.9k | 15.5k | 103.8k/0 | 0.0000 | 184/73 | - |
| deepseek-v4-flash | niffler | t07-validate | pass | 44.8 | 1 | 55.8k | 4.2k | 5.8k | 45.8k/0 | 0.0000 | 24/8 | - |
| deepseek-v4-flash | niffler | t08-logsum | pass | 52.2 | 1 | 110.1k | 5.7k | 6.6k | 97.8k/0 | 0.0000 | 60/2 | - |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 9.5 | 1 | 22.0k | 2.4k | 638 | 18.9k/0 | 0.0000 | 8/4 | - |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 38.1 | 1 | 33.0k | 2.4k | 4.1k | 26.5k/0 | 0.0000 | 6/5 | - |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 15.9 | 1 | 33.0k | 2.9k | 2.3k | 27.8k/0 | 0.0000 | 6/6 | - |
| deepseek-v4-flash | niffler | t12-refactor | pass | 14.7 | 1 | 37.6k | 3.3k | 1.6k | 32.8k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 11.6 | 1 | 44.5k | 6.1k | 966 | 37.4k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 37 | 1 | 86.7k | 7.9k | 4.9k | 73.9k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 9.7 | 1 | 26.1k | 2.0k | 806 | 23.3k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | niffler | t16-apisum | pass | 8.4 | 1 | 20.4k | 1.8k | 532 | 18.0k/0 | 0.0000 | 24/0 | - |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 95.5 | 1 | 172.1k | 5.9k | 12.1k | 154.1k/0 | 0.0000 | 140/0 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 11.9 | 1 | 38.7k | 6.1k | 1.1k | 31.6k/0 | 0.0000 | 13/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 76.2 | 1 | 114.5k | 7.1k | 9.5k | 97.9k/0 | 0.0000 | 91/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 14.4 | 1 | 34.3k | 3.0k | 985 | 30.3k/0 | 0.0000 | 14/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 17 | 1 | 39.6k | 3.4k | 950 | 35.2k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 8.8 | 1 | 26.6k | 2.1k | 750 | 23.8k/0 | 0.0000 | 18/4 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 716.5 | 1 | 271.5k | 22.0k | 16.7k | 232.8k/0 | 0.0000 | 152/43 | 3/0/0 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 22.5 | 1 | 52.8k | 11.0k | 2.4k | 39.4k/0 | 0.0000 | 10/8 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 29.6 | 1 | 47.2k | 16.6k | 3.7k | 26.9k/0 | 0.0000 | 54/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 13.6 | 1 | 36.7k | 9.8k | 1.0k | 25.9k/0 | 0.0000 | 8/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 41.3 | 1 | 63.6k | 11.4k | 4.8k | 47.4k/0 | 0.0000 | 7/8 | 2/1/1 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 15.1 | 1 | 40.2k | 4.4k | 1.9k | 33.9k/0 | 0.0000 | 7/6 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 15.1 | 1 | 44.3k | 3.6k | 1.8k | 38.9k/0 | 0.0000 | 2/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 25.4 | 1 | 65.9k | 8.9k | 3.8k | 53.2k/0 | 0.0000 | 27/27 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 68.2 | 1 | 247.1k | 14.1k | 7.9k | 225.2k/0 | 0.0000 | 18/0 | 1/1/1 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 10.6 | 1 | 26.7k | 2.1k | 950 | 23.7k/0 | 0.0000 | 1/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 9.5 | 1 | 26.8k | 2.2k | 567 | 24.1k/0 | 0.0000 | 26/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 116.6 | 1 | 190.4k | 7.3k | 15.1k | 168.1k/0 | 0.0000 | 163/0 | 2/0/0 |
| deepseek-v4-flash | opencode | t01-roman | pass | 15.6 | 1 | 87.9k | 17.7k | 593 | 69.6k/0 | 0.0028 | 19/1 | - |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 152.8 | 1 | 503.0k | 23.4k | 4.3k | 475.3k/0 | 0.0083 | 105/1 | - |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 22.3 | 1 | 89.6k | 16.2k | 700 | 72.7k/0 | 0.0027 | 17/4 | - |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 23.9 | 1 | 108.9k | 16.6k | 546 | 91.8k/0 | 0.0028 | 3/3 | - |
| deepseek-v4-flash | opencode | t05-todostore | pass | 19.5 | 1 | 109.5k | 16.8k | 818 | 91.9k/0 | 0.0028 | 16/4 | - |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 149.3 | 1 | 392.7k | 22.4k | 3.3k | 367.1k/0 | 0.0095 | 135/45 | - |
| deepseek-v4-flash | opencode | t07-validate | pass | 32.8 | 1 | 132.8k | 16.9k | 1.1k | 114.7k/0 | 0.0034 | 11/12 | - |
| deepseek-v4-flash | opencode | t08-logsum | pass | 38.7 | 1 | 224.0k | 18.5k | 1.8k | 203.6k/0 | 0.0040 | 49/2 | - |
| deepseek-v4-flash | opencode | t09-poolrace | pass | 22.3 | 1 | 90.8k | 16.3k | 678 | 73.9k/0 | 0.0027 | 4/1 | - |
| deepseek-v4-flash | opencode | t10-iniparse | pass | 60.1 | 1 | 166.0k | 17.9k | 1.3k | 146.8k/0 | 0.0040 | 6/5 | - |
| deepseek-v4-flash | opencode | t11-asyncbugs | pass | 26.7 | 1 | 95.7k | 17.2k | 1.0k | 77.4k/0 | 0.0033 | 7/6 | - |
| deepseek-v4-flash | opencode | t12-refactor | pass | 24.9 | 1 | 132.8k | 17.2k | 809 | 114.8k/0 | 0.0032 | 2/4 | - |
| deepseek-v4-flash | opencode | t13-batchrename | pass | 13.1 | 1 | 78.0k | 18.8k | 447 | 58.8k/0 | 0.0029 | 27/27 | - |
| deepseek-v4-flash | opencode | t14-todosweep | pass | 15.5 | 1 | 73.5k | 16.5k | 530 | 56.4k/0 | 0.0027 | 18/0 | - |
| deepseek-v4-flash | opencode | t15-pollstats | pass | 17.2 | 1 | 88.2k | 15.7k | 407 | 72.1k/0 | 0.0026 | 1/0 | - |
| deepseek-v4-flash | opencode | t16-apisum | pass | 22.1 | 1 | 91.0k | 16.5k | 648 | 73.9k/0 | 0.0027 | 10/0 | - |
| deepseek-v4-flash | opencode | t17-doccheck | pass | 38.9 | 1 | 195.5k | 17.5k | 1.5k | 176.5k/0 | 0.0035 | 42/0 | - |
| glm-5.3-flash | codewhale | t01-roman | pass | 78.8 | 1 | 24.1k | 23.3k | 716 | 0/0 | 0.0000 | 36/1 | - |
| glm-5.3-flash | codewhale | t02-jsonrepair | pass | 825 | 1 | 43.2k | 41.1k | 2.1k | 0/0 | 0.0000 | 123/1 | - |
| glm-5.3-flash | codewhale | t03-ringbuffer | pass | 218.6 | 1 | 29.0k | 27.1k | 1.9k | 0/0 | 0.0000 | 14/4 | - |
| glm-5.3-flash | codewhale | t04-csvbugfix | pass | 68 | 1 | 32.4k | 31.8k | 582 | 0/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | codewhale | t05-todostore | pass | 46.9 | 1 | 20.8k | 20.3k | 525 | 0/0 | 0.0000 | 18/4 | - |
| glm-5.3-flash | codewhale | t06-stackvm | pass | 51.3 | 1 | 104.3k | 57.0k | 2.3k | 45.0k/0 | 0.0000 | 117/22 | - |
| glm-5.3-flash | codewhale | t07-validate | pass | 51.4 | 1 | 41.3k | 24.3k | 1.9k | 15.1k/0 | 0.0000 | 14/12 | - |
| glm-5.3-flash | codewhale | t08-logsum | pass | 106.2 | 1 | 127.5k | 68.0k | 4.4k | 55.1k/0 | 0.0000 | 63/5 | - |
| glm-5.3-flash | codewhale | t09-poolrace | pass | 30.6 | 1 | 35.7k | 21.3k | 727 | 13.7k/0 | 0.0000 | 13/5 | - |
| glm-5.3-flash | codewhale | t10-iniparse | pass | 48 | 1 | 66.6k | 37.2k | 1.2k | 28.2k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | codewhale | t11-asyncbugs | pass | 29.9 | 1 | 43.2k | 22.9k | 980 | 19.3k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | codewhale | t12-refactor | pass | 17 | 1 | 39.9k | 21.0k | 378 | 18.5k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | codewhale | t13-batchrename | pass | 8.2 | 1 | 18.2k | 10.1k | 119 | 8.1k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | codewhale | t14-todosweep | pass | 13.8 | 1 | 29.9k | 16.2k | 230 | 13.5k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | codewhale | t15-pollstats | pass | 14.3 | 1 | 27.7k | 14.7k | 276 | 12.7k/0 | 0.0000 | 5/0 | - |
| glm-5.3-flash | codewhale | t16-apisum | pass | 21 | 1 | 40.3k | 21.3k | 301 | 18.7k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | codewhale | t17-doccheck | pass | 220.5 | 1 | 223.7k | 116.6k | 10.1k | 97.0k/0 | 0.0000 | 140/0 | - |
| glm-5.3-flash | niffler | t01-roman | pass | 86.2 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 19/1 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 304 | 1 | 72.9k | 56.0k | 3.5k | 13.4k/0 | 0.0000 | 84/1 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 103.8 | 1 | 21.6k | 20.0k | 1.6k | 0/0 | 0.0000 | 17/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 38 | 1 | 19.9k | 19.4k | 450 | 0/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 99.5 | 1 | 20.0k | 19.0k | 954 | 0/0 | 0.0000 | 19/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 234.6 | 1 | 57.4k | 17.2k | 9.3k | 30.8k/0 | 0.0000 | 150/40 | - |
| glm-5.3-flash | niffler | t07-validate | pass | 55.9 | 1 | 26.0k | 11.8k | 1.7k | 12.5k/0 | 0.0000 | 5/4 | - |
| glm-5.3-flash | niffler | t08-logsum | pass | 155.4 | 1 | 37.3k | 25.7k | 2.4k | 9.2k/0 | 0.0000 | 51/2 | - |
| glm-5.3-flash | niffler | t09-poolrace | pass | 37.3 | 1 | 17.9k | 5.9k | 661 | 11.3k/0 | 0.0000 | 4/1 | - |
| glm-5.3-flash | niffler | t10-iniparse | pass | 162.1 | 1 | 43.3k | 11.5k | 6.0k | 25.8k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 27.1 | 1 | 23.0k | 10.8k | 689 | 11.5k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | niffler | t12-refactor | pass | 36.9 | 1 | 19.6k | 6.4k | 828 | 12.4k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | niffler | t13-batchrename | pass | 40.5 | 1 | 33.6k | 16.4k | 689 | 16.5k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | niffler | t14-todosweep | pass | 62.2 | 1 | 41.5k | 16.8k | 2.1k | 22.5k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | niffler | t15-pollstats | pass | 42.8 | 1 | 31.0k | 4.2k | 942 | 25.9k/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | niffler | t16-apisum | pass | 26.8 | 1 | 15.4k | 4.1k | 583 | 10.8k/0 | 0.0000 | 25/0 | - |
| glm-5.3-flash | niffler | t17-doccheck | pass | 116.5 | 1 | 68.9k | 13.8k | 4.4k | 50.7k/0 | 0.0000 | 136/0 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 85 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 20/1 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 218.5 | 1 | 55.3k | 39.8k | 3.4k | 12.2k/0 | 0.0000 | 80/1 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 68.5 | 1 | 32.7k | 25.8k | 887 | 6.0k/0 | 0.0000 | 17/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 69.7 | 1 | 38.4k | 25.4k | 828 | 12.2k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 181.7 | 1 | 43.3k | 35.0k | 2.3k | 6.0k/0 | 0.0000 | 16/4 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t06-stackvm | timeout | 35100.8 | 1 | 18.9k | 12.7k | 160 | 6.0k/0 | 0.0000 | 0/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 32185.7 | 1 | 129.1k | 21.1k | 6.1k | 101.9k/0 | 0.0000 | 7/11 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 254.1 | 1 | 55.9k | 19.5k | 2.5k | 34.0k/0 | 0.0000 | 82/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 56.1 | 1 | 44.1k | 9.7k | 1.5k | 33.0k/0 | 0.0000 | 9/2 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 73.9 | 1 | 38.7k | 6.1k | 1.9k | 30.7k/0 | 0.0000 | 6/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 47 | 1 | 43.8k | 9.8k | 1.5k | 32.5k/0 | 0.0000 | 6/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 45.2 | 1 | 27.1k | 8.6k | 1.3k | 17.2k/0 | 0.0000 | 2/4 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 43.9 | 1 | 55.5k | 11.5k | 1.2k | 42.8k/0 | 0.0000 | 27/27 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 29.7 | 1 | 31.5k | 11.6k | 747 | 19.1k/0 | 0.0000 | 18/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 351.4 | 1 | 626.2k | 32.7k | 9.9k | 583.6k/0 | 0.0000 | 1/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 798.4 | 1 | 899.9k | 69.6k | 21.3k | 809.0k/0 | 0.0000 | 20/0 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 167.2 | 1 | 62.8k | 23.0k | 3.4k | 36.4k/0 | 0.0000 | 112/0 | 2/0/0 |
| glm-5.3-flash | opencode | t01-roman | pass | 175.1 | 1 | 80.7k | 44.5k | 386 | 35.8k/0 | 0.0040 | 13/1 | - |
| glm-5.3-flash | opencode | t02-jsonrepair | timeout | 1810.3 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 | - |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 59 | 1 | 86.7k | 33.0k | 739 | 52.9k/0 | 0.0035 | 16/4 | - |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 80.6 | 1 | 82.7k | 42.0k | 384 | 40.3k/0 | 0.0039 | 3/3 | - |
| glm-5.3-flash | opencode | t05-todostore | pass | 102.7 | 1 | 101.7k | 42.8k | 647 | 58.2k/0 | 0.0044 | 17/4 | - |
| glm-5.3-flash | opencode | t06-stackvm | timeout | 1810.4 | 1 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 | - |
| glm-5.3-flash | opencode | t07-validate | pass | 103.4 | 1 | 108.3k | 35.0k | 751 | 72.5k/0 | 0.0044 | 12/8 | - |
| glm-5.3-flash | opencode | t08-logsum | pass | 88.6 | 1 | 92.8k | 27.1k | 997 | 64.7k/0 | 0.0047 | 51/2 | - |
| glm-5.3-flash | opencode | t09-poolrace | pass | 62.6 | 1 | 87.7k | 13.7k | 667 | 73.3k/0 | 0.0032 | 8/1 | - |
| glm-5.3-flash | opencode | t10-iniparse | pass | 61.4 | 1 | 89.6k | 25.8k | 737 | 63.1k/0 | 0.0043 | 9/6 | - |
| glm-5.3-flash | opencode | t11-asyncbugs | pass | 70.6 | 1 | 156.7k | 17.6k | 762 | 138.4k/0 | 0.0048 | 4/5 | - |
| glm-5.3-flash | opencode | t12-refactor | pass | 54.7 | 1 | 122.3k | 20.0k | 610 | 101.6k/0 | 0.0042 | 2/4 | - |
| glm-5.3-flash | opencode | t13-batchrename | pass | 46.1 | 1 | 72.7k | 6.2k | 247 | 66.2k/0 | 0.0020 | 27/27 | - |
| glm-5.3-flash | opencode | t14-todosweep | pass | 36.9 | 1 | 68.0k | 5.3k | 361 | 62.4k/0 | 0.0019 | 18/0 | - |
| glm-5.3-flash | opencode | t15-pollstats | pass | 46.4 | 1 | 102.5k | 19.6k | 335 | 82.6k/0 | 0.0038 | 1/0 | - |
| glm-5.3-flash | opencode | t16-apisum | pass | 46.5 | 1 | 85.7k | 16.6k | 420 | 68.7k/0 | 0.0031 | 14/0 | - |
| glm-5.3-flash | opencode | t17-doccheck | pass | 222.9 | 1 | 240.6k | 31.8k | 2.4k | 206.3k/0 | 0.0091 | 128/0 | - |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | codewhale | 17/17 | 23 | 86.1k | 44.9k | 38.6k | 2.6k | 32/7 |
| deepseek-v4-flash | niffler | 17/17 | 32 | 54.2k | 3.9k | 46.4k | 3.9k | 38/8 |
| deepseek-v4-flash | niffler-expert | 17/17 | 71 | 80.4k | 7.9k | 68.1k | 4.3k | 36/7 |
| deepseek-v4-flash | opencode | 17/17 | 41 | 156.5k | 17.8k | 137.5k | 1.2k | 28/7 |
| glm-5.3-flash | codewhale | 17/17 | 109 | 55.8k | 33.8k | 20.3k | 1.7k | 37/6 |
| glm-5.3-flash | niffler | 17/17 | 96 | 32.3k | 15.2k | 14.9k | 2.2k | 34/6 |
| glm-5.3-flash | niffler-expert | 16/17 | 4105 | 129.6k | 21.3k | 104.9k | 3.5k | 25/4 |
| glm-5.3-flash | opencode | 15/17 | 287 | 92.9k | 22.4k | 69.8k | 617 | 19/4 |

*`invalid*` = tests pass but protected files (tests) were modified.*
