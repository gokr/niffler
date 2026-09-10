# bench report — full30-deepseek-v4.1-flash-low

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4.1-flash | niffler | t01-roman | pass | 6.2 | 1 | 10.8k | 1.2k | 411 | 9.2k/0 | 0.0000 | 22/1 |
| deepseek-v4.1-flash | niffler | t02-jsonrepair | pass | 17.4 | 1 | 26.5k | 2.5k | 2.6k | 21.4k/0 | 0.0000 | 100/1 |
| deepseek-v4.1-flash | niffler | t03-ringbuffer | pass | 15 | 1 | 23.3k | 2.4k | 806 | 20.1k/0 | 0.0000 | 17/4 |
| deepseek-v4.1-flash | niffler | t04-csvbugfix | pass | 7.9 | 1 | 15.9k | 2.0k | 548 | 13.3k/0 | 0.0000 | 3/3 |
| deepseek-v4.1-flash | niffler | t05-todostore | pass | 9.9 | 1 | 20.4k | 2.6k | 717 | 17.2k/0 | 0.0000 | 16/4 |
| deepseek-v4.1-flash | niffler | t06-stackvm | pass | 28.3 | 1 | 58.0k | 6.7k | 6.0k | 45.3k/0 | 0.0000 | 176/46 |
| deepseek-v4.1-flash | niffler | t07-validate | pass | 14.3 | 1 | 23.6k | 2.9k | 1.6k | 19.1k/0 | 0.0000 | 8/6 |
| deepseek-v4.1-flash | niffler | t08-logsum | pass | 21.6 | 1 | 45.1k | 4.0k | 2.7k | 38.4k/0 | 0.0000 | 89/4 |
| deepseek-v4.1-flash | niffler | t09-poolrace | pass | 12.1 | 1 | 15.6k | 1.9k | 713 | 12.9k/0 | 0.0000 | 7/4 |
| deepseek-v4.1-flash | niffler | t10-iniparse | pass | 16 | 1 | 26.3k | 3.5k | 1.3k | 21.6k/0 | 0.0000 | 6/5 |
| deepseek-v4.1-flash | niffler | t11-asyncbugs | pass | 12.6 | 1 | 18.5k | 2.6k | 994 | 14.8k/0 | 0.0000 | 6/4 |
| deepseek-v4.1-flash | niffler | t12-refactor | pass | 8 | 1 | 16.7k | 2.5k | 595 | 13.6k/0 | 0.0000 | 2/4 |
| deepseek-v4.1-flash | niffler | t13-batchrename | pass | 8.2 | 1 | 14.9k | 2.8k | 381 | 11.6k/0 | 0.0000 | 27/27 |
| deepseek-v4.1-flash | niffler | t14-todosweep | pass | 12.2 | 1 | 24.5k | 2.8k | 1.4k | 20.2k/0 | 0.0000 | 18/0 |
| deepseek-v4.1-flash | niffler | t15-pollstats | pass | 44.3 | 1 | 70.0k | 5.7k | 3.1k | 61.2k/0 | 0.0000 | 1/0 |
| deepseek-v4.1-flash | niffler | t16-apisum | pass | 29.3 | 1 | 13.0k | 2.1k | 369 | 10.5k/0 | 0.0000 | 20/0 |
| deepseek-v4.1-flash | niffler | t17-doccheck | pass | 27.8 | 1 | 38.9k | 4.0k | 2.8k | 32.1k/0 | 0.0000 | 36/0 |
| deepseek-v4.1-flash | niffler | t18-lruttl | pass | 24.3 | 1 | 50.8k | 3.7k | 4.0k | 43.1k/0 | 0.0000 | 126/12 |
| deepseek-v4.1-flash | niffler | t19-tokbucket | pass | 24.3 | 1 | 17.4k | 3.3k | 817 | 13.3k/0 | 0.0000 | 28/8 |
| deepseek-v4.1-flash | niffler | t20-jsonpatch | pass | 66.9 | 1 | 67.2k | 5.1k | 7.0k | 55.2k/0 | 0.0000 | 184/9 |
| deepseek-v4.1-flash | niffler | t21-wireproto | pass | 56.5 | 1 | 41.2k | 4.1k | 2.5k | 34.6k/0 | 0.0000 | 67/8 |
| deepseek-v4.1-flash | niffler | t22-cronnext | pass | 13.4 | 1 | 25.2k | 4.4k | 2.5k | 18.3k/0 | 0.0000 | 94/17 |
| deepseek-v4.1-flash | niffler | t23-mergesched | pass | 12.1 | 1 | 20.3k | 2.7k | 1.6k | 16.0k/0 | 0.0000 | 73/4 |
| deepseek-v4.1-flash | niffler | t24-editops | pass | 23.9 | 1 | 38.8k | 3.8k | 4.3k | 30.7k/0 | 0.0000 | 108/11 |
| deepseek-v4.1-flash | niffler | t25-shardmap | pass | 21.8 | 1 | 33.3k | 3.4k | 1.6k | 28.3k/0 | 0.0000 | 89/16 |
| deepseek-v4.1-flash | niffler | t26-logfilter | pass | 33.9 | 1 | 48.1k | 3.2k | 7.7k | 37.2k/0 | 0.0000 | 267/4 |
| deepseek-v4.1-flash | niffler | t27-tarpeek | pass | 76.6 | 1 | 268.7k | 10.2k | 10.7k | 247.8k/0 | 0.0000 | 97/1 |
| deepseek-v4.1-flash | niffler | t28-docbackfill | pass | 34.6 | 1 | 37.3k | 4.2k | 1.7k | 31.4k/0 | 0.0000 | 18/9 |
| deepseek-v4.1-flash | niffler | t29-logrollup | pass | 20.4 | 1 | 13.5k | 2.1k | 624 | 10.8k/0 | 0.0000 | 436/0 |
| deepseek-v4.1-flash | niffler | t30-ifacedrift | pass | 19.8 | 1 | 68.2k | 7.7k | 1.8k | 58.8k/0 | 0.0000 | 48/48 |
| deepseek-v4.1-flash | pi | t01-roman | pass | 6.7 | 1 | 10.4k | 2.5k | 520 | 7.4k/0 | 0.0007 | 13/1 |
| deepseek-v4.1-flash | pi | t02-jsonrepair | pass | 22.3 | 1 | 44.4k | 3.7k | 3.6k | 37.1k/0 | 0.0028 | 104/1 |
| deepseek-v4.1-flash | pi | t03-ringbuffer | pass | 12.8 | 1 | 14.3k | 2.3k | 934 | 11.0k/0 | 0.0009 | 15/4 |
| deepseek-v4.1-flash | pi | t04-csvbugfix | pass | 10.5 | 1 | 20.3k | 3.0k | 1.0k | 16.3k/0 | 0.0011 | 3/3 |
| deepseek-v4.1-flash | pi | t05-todostore | pass | 8.9 | 1 | 16.1k | 2.9k | 981 | 12.2k/0 | 0.0011 | 18/4 |
| deepseek-v4.1-flash | pi | t06-stackvm | pass | 31.8 | 1 | 64.4k | 6.8k | 6.1k | 51.6k/0 | 0.0048 | 185/42 |
| deepseek-v4.1-flash | pi | t07-validate | pass | 11.8 | 1 | 17.9k | 3.0k | 1.5k | 13.4k/0 | 0.0014 | 8/8 |
| deepseek-v4.1-flash | pi | t08-logsum | pass | 19.8 | 1 | 38.5k | 3.9k | 2.7k | 31.9k/0 | 0.0023 | 71/3 |
| deepseek-v4.1-flash | pi | t09-poolrace | pass | 8.2 | 1 | 11.0k | 2.6k | 561 | 7.8k/0 | 0.0007 | 7/4 |
| deepseek-v4.1-flash | pi | t10-iniparse | pass | 13.9 | 1 | 22.3k | 3.1k | 1.5k | 17.7k/0 | 0.0014 | 6/5 |
| deepseek-v4.1-flash | pi | t11-asyncbugs | pass | 10 | 1 | 17.1k | 3.0k | 1.2k | 12.9k/0 | 0.0012 | 5/10 |
| deepseek-v4.1-flash | pi | t12-refactor | pass | 6.9 | 1 | 11.6k | 2.6k | 624 | 8.3k/0 | 0.0008 | 2/4 |
| deepseek-v4.1-flash | pi | t13-batchrename | pass | 8.9 | 1 | 14.1k | 2.9k | 634 | 10.5k/0 | 0.0009 | 27/27 |
| deepseek-v4.1-flash | pi | t14-todosweep | pass | 9.4 | 1 | 16.8k | 3.1k | 947 | 12.8k/0 | 0.0011 | 18/0 |
| deepseek-v4.1-flash | pi | t15-pollstats | pass | 8.2 | 1 | 13.8k | 2.5k | 781 | 10.5k/0 | 0.0009 | 1/0 |
| deepseek-v4.1-flash | pi | t16-apisum | pass | 8.2 | 1 | 11.5k | 2.5k | 554 | 8.4k/0 | 0.0007 | 22/0 |
| deepseek-v4.1-flash | pi | t17-doccheck | pass | 25.7 | 1 | 54.2k | 4.2k | 3.4k | 46.6k/0 | 0.0028 | 91/0 |
| deepseek-v4.1-flash | pi | t18-lruttl | pass | 12.4 | 1 | 25.2k | 4.1k | 1.8k | 19.3k/0 | 0.0018 | 112/12 |
| deepseek-v4.1-flash | pi | t19-tokbucket | pass | 10.4 | 1 | 22.3k | 3.9k | 1.6k | 16.8k/0 | 0.0016 | 27/9 |
| deepseek-v4.1-flash | pi | t20-jsonpatch | pass | 31.8 | 1 | 39.1k | 5.1k | 7.0k | 27.0k/0 | 0.0050 | 225/12 |
| deepseek-v4.1-flash | pi | t21-wireproto | pass | 12.4 | 1 | 21.1k | 4.0k | 2.2k | 14.8k/0 | 0.0020 | 64/8 |
| deepseek-v4.1-flash | pi | t22-cronnext | pass | 24.9 | 1 | 31.3k | 4.9k | 5.1k | 21.4k/0 | 0.0039 | 92/17 |
| deepseek-v4.1-flash | pi | t23-mergesched | pass | 17.5 | 1 | 25.1k | 3.6k | 2.8k | 18.7k/0 | 0.0023 | 75/4 |
| deepseek-v4.1-flash | pi | t24-editops | pass | 29.2 | 1 | 48.6k | 4.4k | 5.4k | 38.8k/0 | 0.0040 | 106/11 |
| deepseek-v4.1-flash | pi | t25-shardmap | pass | 14 | 1 | 26.8k | 3.9k | 1.8k | 21.1k/0 | 0.0017 | 77/16 |
| deepseek-v4.1-flash | pi | t26-logfilter | pass | 40.8 | 1 | 71.3k | 4.7k | 10.0k | 56.6k/0 | 0.0069 | 310/4 |
| deepseek-v4.1-flash | pi | t27-tarpeek | pass | 41.2 | 1 | 162.4k | 11.3k | 6.2k | 144.9k/0 | 0.0058 | 83/1 |
| deepseek-v4.1-flash | pi | t28-docbackfill | pass | 9.5 | 1 | 18.6k | 3.5k | 1.0k | 14.1k/0 | 0.0012 | 18/9 |
| deepseek-v4.1-flash | pi | t29-logrollup | pass | 7.6 | 1 | 12.4k | 2.8k | 646 | 9.0k/0 | 0.0008 | 436/0 |
| deepseek-v4.1-flash | pi | t30-ifacedrift | pass | 8.6 | 1 | 29.7k | 7.0k | 847 | 21.9k/0 | 0.0016 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4.1-flash | niffler | 30/30 | 24 | 39.7k | 3.7k | 33.6k | 2.5k | 73/9 |
| deepseek-v4.1-flash | pi | 30/30 | 16 | 31.1k | 3.9k | 24.7k | 2.5k | 76/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
