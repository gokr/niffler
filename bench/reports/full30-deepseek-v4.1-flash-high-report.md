# bench report — full30-deepseek-v4.1-flash-high

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4.1-flash | niffler | t01-roman | pass | 8.5 | 1 | 16.8k | 3.8k | 578 | 12.4k/0 | 0.0000 | 32/1 |
| deepseek-v4.1-flash | niffler | t02-jsonrepair | pass | 22.2 | 1 | 54.0k | 4.7k | 3.1k | 46.2k/0 | 0.0000 | 85/1 |
| deepseek-v4.1-flash | niffler | t03-ringbuffer | pass | 35.1 | 1 | 40.3k | 3.0k | 2.4k | 34.9k/0 | 0.0000 | 20/4 |
| deepseek-v4.1-flash | niffler | t04-csvbugfix | pass | 10.6 | 1 | 21.2k | 2.7k | 888 | 17.7k/0 | 0.0000 | 3/3 |
| deepseek-v4.1-flash | niffler | t05-todostore | pass | 18.4 | 1 | 16.8k | 2.2k | 835 | 13.7k/0 | 0.0000 | 19/4 |
| deepseek-v4.1-flash | niffler | t06-stackvm | pass | 47.5 | 1 | 128.5k | 7.2k | 10.5k | 110.8k/0 | 0.0000 | 194/78 |
| deepseek-v4.1-flash | niffler | t07-validate | pass | 29.5 | 1 | 22.3k | 3.0k | 1.9k | 17.4k/0 | 0.0000 | 17/8 |
| deepseek-v4.1-flash | niffler | t08-logsum | pass | 54.8 | 1 | 219.1k | 10.5k | 8.3k | 200.2k/0 | 0.0000 | 78/3 |
| deepseek-v4.1-flash | niffler | t09-poolrace | pass | 53 | 1 | 37.7k | 4.6k | 1.5k | 31.6k/0 | 0.0000 | 6/1 |
| deepseek-v4.1-flash | niffler | t10-iniparse | pass | 20 | 1 | 36.2k | 3.7k | 1.5k | 31.0k/0 | 0.0000 | 8/7 |
| deepseek-v4.1-flash | niffler | t11-asyncbugs | pass | 17.6 | 1 | 17.9k | 2.6k | 784 | 14.5k/0 | 0.0000 | 6/4 |
| deepseek-v4.1-flash | niffler | t12-refactor | pass | 8.9 | 1 | 17.1k | 2.6k | 673 | 13.8k/0 | 0.0000 | 2/4 |
| deepseek-v4.1-flash | niffler | t13-batchrename | pass | 34.5 | 1 | 105.1k | 12.3k | 2.9k | 90.0k/0 | 0.0000 | 27/27 |
| deepseek-v4.1-flash | niffler | t14-todosweep | pass | 31.7 | 1 | 37.7k | 4.0k | 2.0k | 31.7k/0 | 0.0000 | 18/0 |
| deepseek-v4.1-flash | niffler | t15-pollstats | pass | 117.7 | 1 | 299.5k | 12.7k | 14.9k | 271.9k/0 | 0.0000 | 1/0 |
| deepseek-v4.1-flash | niffler | t16-apisum | pass | 102.5 | 1 | 52.9k | 4.7k | 1.7k | 46.6k/0 | 0.0000 | 23/0 |
| deepseek-v4.1-flash | niffler | t17-doccheck | pass | 64.5 | 1 | 96.0k | 3.5k | 8.0k | 84.5k/0 | 0.0000 | 205/0 |
| deepseek-v4.1-flash | niffler | t18-lruttl | pass | 18 | 1 | 34.4k | 3.6k | 2.4k | 28.4k/0 | 0.0000 | 127/12 |
| deepseek-v4.1-flash | niffler | t19-tokbucket | pass | 28.2 | 1 | 23.2k | 3.1k | 1.4k | 18.7k/0 | 0.0000 | 28/13 |
| deepseek-v4.1-flash | niffler | t20-jsonpatch | pass | 53.4 | 1 | 159.3k | 6.6k | 10.0k | 142.7k/0 | 0.0000 | 187/10 |
| deepseek-v4.1-flash | niffler | t21-wireproto | pass | 33.3 | 1 | 42.7k | 4.2k | 3.8k | 34.7k/0 | 0.0000 | 67/8 |
| deepseek-v4.1-flash | niffler | t22-cronnext | pass | 25.2 | 1 | 44.3k | 4.8k | 4.5k | 34.9k/0 | 0.0000 | 109/12 |
| deepseek-v4.1-flash | niffler | t23-mergesched | pass | 31.7 | 1 | 43.5k | 3.5k | 3.3k | 36.7k/0 | 0.0000 | 77/4 |
| deepseek-v4.1-flash | niffler | t24-editops | pass | 80 | 1 | 273.4k | 7.3k | 13.3k | 252.8k/0 | 0.0000 | 119/11 |
| deepseek-v4.1-flash | niffler | t25-shardmap | pass | 60.5 | 1 | 30.4k | 3.5k | 1.8k | 25.1k/0 | 0.0000 | 81/16 |
| deepseek-v4.1-flash | niffler | t26-logfilter | pass | 42 | 1 | 77.1k | 7.2k | 9.0k | 60.9k/0 | 0.0000 | 256/4 |
| deepseek-v4.1-flash | niffler | t27-tarpeek | pass | 119.2 | 1 | 535.9k | 14.1k | 15.8k | 506.0k/0 | 0.0000 | 99/1 |
| deepseek-v4.1-flash | niffler | t28-docbackfill | pass | 152.6 | 1 | 217.3k | 15.3k | 10.8k | 191.2k/0 | 0.0000 | 18/9 |
| deepseek-v4.1-flash | niffler | t29-logrollup | pass | 105.9 | 1 | 40.7k | 3.9k | 2.0k | 34.8k/0 | 0.0000 | 436/0 |
| deepseek-v4.1-flash | niffler | t30-ifacedrift | pass | 24.3 | 1 | 73.0k | 7.7k | 2.8k | 62.5k/0 | 0.0000 | 48/48 |
| deepseek-v4.1-flash | pi | t01-roman | pass | 7 | 1 | 10.6k | 2.8k | 559 | 7.3k/0 | 0.0008 | 13/1 |
| deepseek-v4.1-flash | pi | t02-jsonrepair | pass | 13 | 1 | 18.5k | 2.7k | 2.1k | 13.7k/0 | 0.0017 | 89/1 |
| deepseek-v4.1-flash | pi | t03-ringbuffer | pass | 12.7 | 1 | 15.3k | 2.5k | 1.1k | 11.8k/0 | 0.0011 | 17/4 |
| deepseek-v4.1-flash | pi | t04-csvbugfix | pass | 10.3 | 1 | 16.6k | 3.1k | 960 | 12.5k/0 | 0.0011 | 3/3 |
| deepseek-v4.1-flash | pi | t05-todostore | pass | 9 | 1 | 15.5k | 3.0k | 888 | 11.6k/0 | 0.0010 | 16/4 |
| deepseek-v4.1-flash | pi | t06-stackvm | pass | 31.7 | 1 | 49.0k | 6.5k | 7.6k | 34.8k/0 | 0.0057 | 144/36 |
| deepseek-v4.1-flash | pi | t07-validate | pass | 12.4 | 1 | 19.8k | 3.1k | 2.2k | 14.6k/0 | 0.0018 | 11/6 |
| deepseek-v4.1-flash | pi | t08-logsum | pass | 21.2 | 1 | 39.8k | 4.0k | 3.0k | 32.8k/0 | 0.0025 | 75/5 |
| deepseek-v4.1-flash | pi | t09-poolrace | pass | 11.2 | 1 | 16.9k | 3.2k | 1.2k | 12.5k/0 | 0.0012 | 7/4 |
| deepseek-v4.1-flash | pi | t10-iniparse | pass | 17.8 | 1 | 24.4k | 3.1k | 1.9k | 19.3k/0 | 0.0017 | 6/5 |
| deepseek-v4.1-flash | pi | t11-asyncbugs | pass | 8.8 | 1 | 11.1k | 2.8k | 1.5k | 6.8k/0 | 0.0014 | 6/5 |
| deepseek-v4.1-flash | pi | t12-refactor | pass | 6.9 | 1 | 12.4k | 2.7k | 783 | 8.8k/0 | 0.0009 | 2/4 |
| deepseek-v4.1-flash | pi | t13-batchrename | pass | 6.2 | 1 | 14.0k | 3.6k | 617 | 9.7k/0 | 0.0009 | 27/27 |
| deepseek-v4.1-flash | pi | t14-todosweep | pass | 9.6 | 1 | 13.1k | 2.9k | 1.1k | 9.1k/0 | 0.0011 | 18/0 |
| deepseek-v4.1-flash | pi | t15-pollstats | pass | 9.6 | 1 | 17.7k | 2.7k | 889 | 14.1k/0 | 0.0010 | 1/0 |
| deepseek-v4.1-flash | pi | t16-apisum | pass | 10.3 | 1 | 13.9k | 2.7k | 612 | 10.6k/0 | 0.0008 | 21/0 |
| deepseek-v4.1-flash | pi | t17-doccheck | pass | 29.9 | 1 | 63.0k | 4.2k | 4.8k | 54.0k/0 | 0.0037 | 55/0 |
| deepseek-v4.1-flash | pi | t18-lruttl | pass | 12 | 1 | 20.4k | 4.0k | 2.1k | 14.2k/0 | 0.0019 | 101/12 |
| deepseek-v4.1-flash | pi | t19-tokbucket | pass | 11.4 | 1 | 22.7k | 3.9k | 1.8k | 17.0k/0 | 0.0017 | 29/11 |
| deepseek-v4.1-flash | pi | t20-jsonpatch | pass | 40.7 | 1 | 76.0k | 5.9k | 9.0k | 61.1k/0 | 0.0065 | 230/10 |
| deepseek-v4.1-flash | pi | t21-wireproto | pass | 12.6 | 1 | 21.3k | 4.2k | 2.3k | 14.7k/0 | 0.0021 | 65/8 |
| deepseek-v4.1-flash | pi | t22-cronnext | pass | 22.5 | 1 | 32.5k | 4.9k | 4.6k | 23.0k/0 | 0.0035 | 101/12 |
| deepseek-v4.1-flash | pi | t23-mergesched | pass | 24.4 | 1 | 29.3k | 3.6k | 4.8k | 20.9k/0 | 0.0035 | 74/4 |
| deepseek-v4.1-flash | pi | t24-editops | pass | 39 | 1 | 56.5k | 4.8k | 8.5k | 43.1k/0 | 0.0060 | 127/11 |
| deepseek-v4.1-flash | pi | t25-shardmap | pass | 11.2 | 1 | 17.6k | 3.7k | 1.5k | 12.4k/0 | 0.0015 | 83/16 |
| deepseek-v4.1-flash | pi | t26-logfilter | pass | 38.9 | 1 | 50.2k | 7.3k | 9.0k | 33.9k/0 | 0.0066 | 230/4 |
| deepseek-v4.1-flash | pi | t27-tarpeek | pass | 36.6 | 1 | 67.6k | 8.3k | 7.5k | 51.7k/0 | 0.0059 | 76/3 |
| deepseek-v4.1-flash | pi | t28-docbackfill | pass | 10 | 1 | 24.3k | 6.1k | 1.2k | 17.0k/0 | 0.0017 | 18/9 |
| deepseek-v4.1-flash | pi | t29-logrollup | pass | 5.5 | 1 | 9.0k | 2.6k | 620 | 5.8k/0 | 0.0008 | 436/0 |
| deepseek-v4.1-flash | pi | t30-ifacedrift | pass | 10.3 | 1 | 27.9k | 6.1k | 983 | 20.9k/0 | 0.0016 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4.1-flash | niffler | 30/30 | 48 | 93.8k | 5.7k | 83.3k | 4.8k | 80/10 |
| deepseek-v4.1-flash | pi | 30/30 | 17 | 27.6k | 4.0k | 20.7k | 2.9k | 71/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
