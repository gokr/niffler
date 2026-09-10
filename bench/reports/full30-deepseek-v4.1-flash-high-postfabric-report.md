# bench report — full30-deepseek-v4.1-flash-high-postfabric

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4.1-flash | niffler | t01-roman | pass | 6.4 | 1 | 11.4k | 1.4k | 462 | 9.6k/0 | 0.0000 | 30/1 |
| deepseek-v4.1-flash | niffler | t02-jsonrepair | pass | 30.5 | 1 | 52.9k | 3.7k | 3.2k | 46.0k/0 | 0.0000 | 92/1 |
| deepseek-v4.1-flash | niffler | t03-ringbuffer | pass | 41.1 | 1 | 25.8k | 2.1k | 1.4k | 22.3k/0 | 0.0000 | 19/4 |
| deepseek-v4.1-flash | niffler | t04-csvbugfix | pass | 25.5 | 1 | 21.3k | 2.6k | 548 | 18.2k/0 | 0.0000 | 3/3 |
| deepseek-v4.1-flash | niffler | t05-todostore | pass | 19.1 | 1 | 21.8k | 2.8k | 844 | 18.2k/0 | 0.0000 | 19/4 |
| deepseek-v4.1-flash | niffler | t06-stackvm | pass | 66.9 | 1 | 172.7k | 7.2k | 11.7k | 153.7k/0 | 0.0000 | 216/64 |
| deepseek-v4.1-flash | niffler | t07-validate | pass | 73.6 | 1 | 41.4k | 4.5k | 2.0k | 34.8k/0 | 0.0000 | 12/8 |
| deepseek-v4.1-flash | niffler | t08-logsum | pass | 46.6 | 1 | 73.0k | 4.7k | 4.2k | 64.1k/0 | 0.0000 | 84/5 |
| deepseek-v4.1-flash | niffler | t09-poolrace | pass | 42.8 | 1 | 20.1k | 1.9k | 932 | 17.3k/0 | 0.0000 | 10/4 |
| deepseek-v4.1-flash | niffler | t10-iniparse | pass | 38.1 | 1 | 45.3k | 3.9k | 2.9k | 38.5k/0 | 0.0000 | 8/7 |
| deepseek-v4.1-flash | niffler | t11-asyncbugs | pass | 35.7 | 1 | 29.7k | 3.2k | 1.4k | 25.1k/0 | 0.0000 | 7/5 |
| deepseek-v4.1-flash | niffler | t12-refactor | pass | 21.6 | 1 | 26.4k | 3.9k | 714 | 21.8k/0 | 0.0000 | 2/4 |
| deepseek-v4.1-flash | niffler | t13-batchrename | pass | 21.1 | 1 | 30.9k | 4.8k | 764 | 25.3k/0 | 0.0000 | 27/27 |
| deepseek-v4.1-flash | niffler | t14-todosweep | pass | 26.1 | 1 | 34.2k | 3.2k | 2.0k | 28.9k/0 | 0.0000 | 18/0 |
| deepseek-v4.1-flash | niffler | t15-pollstats | pass | 36.1 | 1 | 38.7k | 8.3k | 2.7k | 27.6k/0 | 0.0000 | 1/0 |
| deepseek-v4.1-flash | niffler | t16-apisum | pass | 28.9 | 1 | 13.6k | 2.2k | 525 | 10.9k/0 | 0.0000 | 22/0 |
| deepseek-v4.1-flash | niffler | t17-doccheck | pass | 73 | 1 | 172.7k | 5.2k | 11.1k | 156.4k/0 | 0.0000 | 181/0 |
| deepseek-v4.1-flash | niffler | t18-lruttl | pass | 89.8 | 1 | 56.3k | 4.4k | 4.3k | 47.6k/0 | 0.0000 | 122/12 |
| deepseek-v4.1-flash | niffler | t19-tokbucket | pass | 33 | 1 | 17.9k | 3.3k | 991 | 13.6k/0 | 0.0000 | 24/11 |
| deepseek-v4.1-flash | niffler | t20-jsonpatch | pass | 73 | 1 | 232.2k | 7.2k | 13.0k | 212.0k/0 | 0.0000 | 268/13 |
| deepseek-v4.1-flash | niffler | t21-wireproto | pass | 87.2 | 1 | 46.0k | 4.1k | 3.9k | 38.0k/0 | 0.0000 | 73/8 |
| deepseek-v4.1-flash | niffler | t22-cronnext | pass | 49.6 | 1 | 46.9k | 4.5k | 5.3k | 37.1k/0 | 0.0000 | 96/17 |
| deepseek-v4.1-flash | niffler | t23-mergesched | pass | 40.1 | 1 | 25.9k | 3.3k | 1.8k | 20.7k/0 | 0.0000 | 82/4 |
| deepseek-v4.1-flash | niffler | t24-editops | pass | 63.7 | 1 | 94.9k | 4.4k | 10.5k | 80.0k/0 | 0.0000 | 125/6 |
| deepseek-v4.1-flash | niffler | t25-shardmap | pass | 67.1 | 1 | 28.6k | 3.5k | 1.6k | 23.4k/0 | 0.0000 | 81/16 |
| deepseek-v4.1-flash | niffler | t26-logfilter | pass | 78.2 | 1 | 198.2k | 7.4k | 13.2k | 177.5k/0 | 0.0000 | 350/4 |
| deepseek-v4.1-flash | niffler | t27-tarpeek | pass | 126.3 | 1 | 337.9k | 15.3k | 10.1k | 312.6k/0 | 0.0000 | 86/1 |
| deepseek-v4.1-flash | niffler | t28-docbackfill | pass | 85.2 | 1 | 70.0k | 6.8k | 2.4k | 60.8k/0 | 0.0000 | 18/9 |
| deepseek-v4.1-flash | niffler | t29-logrollup | pass | 46.8 | 1 | 59.3k | 5.9k | 2.2k | 51.2k/0 | 0.0000 | 436/0 |
| deepseek-v4.1-flash | niffler | t30-ifacedrift | pass | 45.5 | 1 | 74.3k | 8.7k | 2.3k | 63.4k/0 | 0.0000 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4.1-flash | niffler | 30/30 | 51 | 70.7k | 4.8k | 61.9k | 4.0k | 85/10 |

*`invalid*` = tests pass but protected files (tests) were modified.*
