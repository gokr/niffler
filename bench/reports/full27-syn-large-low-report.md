# bench report — full27-syn-large-low

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t01-roman | pass | 36.3 | 1 | 15.0k | 3.1k | 332 | 11.6k/0 | 0.0011 | 19/1 |
| syn-large | niffler | t02-jsonrepair | pass | 53.5 | 1 | 20.4k | 3.9k | 589 | 15.9k/0 | 0.0015 | 48/10 |
| syn-large | niffler | t03-ringbuffer | pass | 39.5 | 1 | 16.9k | 3.4k | 827 | 12.6k/0 | 0.0014 | 13/4 |
| syn-large | niffler | t04-csvbugfix | pass | 169.7 | 1 | 17.2k | 4.0k | 398 | 12.7k/0 | 0.0013 | 3/3 |
| syn-large | niffler | t05-todostore | pass | 103.1 | 1 | 12.6k | 5.9k | 439 | 6.3k/0 | 0.0013 | 18/4 |
| syn-large | niffler | t06-stackvm | pass | 202 | 1 | 138.0k | 17.9k | 4.3k | 115.9k/0 | 0.0094 | 139/37 |
| syn-large | niffler | t07-validate | pass | 145.2 | 1 | 19.7k | 10.3k | 967 | 8.4k/0 | 0.0024 | 19/7 |
| syn-large | niffler | t08-logsum | pass | 54.1 | 1 | 17.7k | 1.6k | 546 | 15.6k/0 | 0.0011 | 43/3 |
| syn-large | niffler | t09-poolrace | pass | 27 | 1 | 11.8k | 3.2k | 371 | 8.2k/0 | 0.0010 | 4/1 |
| syn-large | niffler | t10-iniparse | pass | 65.3 | 1 | 14.0k | 6.1k | 539 | 7.4k/0 | 0.0015 | 5/6 |
| syn-large | niffler | t11-asyncbugs | pass | 82.1 | 1 | 31.9k | 5.9k | 891 | 25.1k/0 | 0.0023 | 6/11 |
| syn-large | niffler | t12-refactor | pass | 56.6 | 1 | 15.0k | 1.2k | 242 | 13.6k/0 | 0.0008 | 2/4 |
| syn-large | niffler | t13-batchrename | pass | 52.6 | 1 | 8.2k | 680 | 129 | 7.4k/0 | 0.0005 | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 19.4 | 1 | 9.3k | 4.5k | 105 | 4.6k/0 | 0.0009 | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 26.2 | 1 | 8.1k | 743 | 148 | 7.2k/0 | 0.0005 | 1/0 |
| syn-large | niffler | t16-apisum | pass | 22.9 | 1 | 11.7k | 1.1k | 168 | 10.4k/0 | 0.0007 | 12/0 |
| syn-large | niffler | t17-doccheck | pass | 50.3 | 1 | 49.4k | 2.4k | 1.3k | 45.8k/0 | 0.0028 | 31/0 |
| syn-large | niffler | t18-lruttl | pass | 34.6 | 1 | 19.9k | 3.8k | 1.1k | 14.9k/0 | 0.0017 | 84/12 |
| syn-large | niffler | t19-tokbucket | pass | 50.2 | 1 | 28.4k | 5.1k | 600 | 22.7k/0 | 0.0020 | 19/14 |
| syn-large | niffler | t20-jsonpatch | pass | 49.8 | 1 | 26.7k | 3.7k | 1.9k | 21.1k/0 | 0.0024 | 149/16 |
| syn-large | niffler | t21-wireproto | pass | 30.3 | 1 | 28.4k | 3.1k | 1.0k | 24.3k/0 | 0.0019 | 54/8 |
| syn-large | niffler | t22-cronnext | pass | 171.2 | 1 | 39.1k | 1.0k | 4.2k | 33.9k/0 | 0.0036 | 96/17 |
| syn-large | niffler | t23-mergesched | pass | 69.7 | 1 | 13.4k | 3.5k | 757 | 9.2k/0 | 0.0013 | 62/4 |
| syn-large | niffler | t24-editops | pass | 150.1 | 1 | 33.0k | 6.7k | 2.4k | 23.9k/0 | 0.0032 | 65/15 |
| syn-large | niffler | t25-shardmap | pass | 88.6 | 1 | 16.8k | 6.7k | 732 | 9.3k/0 | 0.0017 | 89/30 |
| syn-large | niffler | t26-logfilter | pass | 49.8 | 1 | 45.0k | 3.7k | 2.3k | 39.0k/0 | 0.0033 | 192/4 |
| syn-large | niffler | t27-tarpeek | pass | 75.2 | 1 | 70.2k | 6.5k | 1.6k | 62.1k/0 | 0.0042 | 59/2 |
| syn-large | pi | t01-roman | pass | 29.1 | 1 | 5.3k | 1.3k | 378 | 3.6k/0 | 0.0005 | 13/1 |
| syn-large | pi | t02-jsonrepair | pass | 69.1 | 1 | 17.3k | 3.7k | 1.5k | 12.1k/0 | 0.0018 | 122/1 |
| syn-large | pi | t03-ringbuffer | pass | 34.7 | 1 | 6.5k | 1.8k | 524 | 4.1k/0 | 0.0007 | 14/4 |
| syn-large | pi | t04-csvbugfix | pass | 132.8 | 1 | 6.2k | 2.0k | 246 | 4.0k/0 | 0.0006 | 3/3 |
| syn-large | pi | t05-todostore | pass | 59.1 | 1 | 6.5k | 2.8k | 536 | 3.2k/0 | 0.0008 | 16/4 |
| syn-large | pi | t06-stackvm | pass | 164.6 | 1 | 66.6k | 4.6k | 4.8k | 57.2k/0 | 0.0054 | 186/47 |
| syn-large | pi | t07-validate | pass | 99.5 | 1 | 15.8k | 4.0k | 741 | 11.0k/0 | 0.0014 | 7/6 |
| syn-large | pi | t08-logsum | pass | 74.9 | 1 | 15.7k | 4.1k | 758 | 10.9k/0 | 0.0014 | 47/2 |
| syn-large | pi | t09-poolrace | pass | 26.3 | 1 | 5.6k | 719 | 378 | 4.5k/0 | 0.0005 | 4/1 |
| syn-large | pi | t10-iniparse | pass | 77.9 | 1 | 10.5k | 3.1k | 492 | 6.9k/0 | 0.0010 | 6/5 |
| syn-large | pi | t11-asyncbugs | pass | 64.8 | 1 | 12.9k | 1.9k | 645 | 10.4k/0 | 0.0010 | 6/11 |
| syn-large | pi | t12-refactor | pass | 44.7 | 1 | 6.8k | 2.2k | 441 | 4.1k/0 | 0.0007 | 2/4 |
| syn-large | pi | t13-batchrename | pass | 15.5 | 1 | 3.6k | 1.4k | 165 | 2.0k/0 | 0.0004 | 27/27 |
| syn-large | pi | t14-todosweep | pass | 17.4 | 1 | 4.9k | 1.1k | 176 | 3.6k/0 | 0.0004 | 18/0 |
| syn-large | pi | t15-pollstats | pass | 20.7 | 1 | 5.2k | 923 | 356 | 4.0k/0 | 0.0005 | 1/0 |
| syn-large | pi | t16-apisum | pass | 47.9 | 1 | 7.8k | 1.2k | 307 | 6.3k/0 | 0.0006 | 12/0 |
| syn-large | pi | t17-doccheck | pass | 58 | 1 | 25.3k | 2.3k | 1.3k | 21.8k/0 | 0.0019 | 69/0 |
| syn-large | pi | t18-lruttl | pass | 40.5 | 1 | 9.1k | 2.8k | 1.1k | 5.2k/0 | 0.0012 | 96/10 |
| syn-large | pi | t19-tokbucket | pass | 448.6 | 2 | 39.4k | 3.2k | 2.8k | 33.3k/0 | 0.0032 | 19/8 |
| syn-large | pi | t20-jsonpatch | pass | 59.4 | 1 | 24.4k | 9.0k | 2.1k | 13.4k/0 | 0.0029 | 150/19 |
| syn-large | pi | t21-wireproto | pass | 28.7 | 1 | 14.5k | 4.0k | 1.1k | 9.4k/0 | 0.0015 | 56/8 |
| syn-large | pi | t22-cronnext | pass | 103.4 | 1 | 29.0k | 4.1k | 1.5k | 23.4k/0 | 0.0023 | 90/17 |
| syn-large | pi | t23-mergesched | pass | 32.4 | 1 | 7.6k | 1.8k | 873 | 4.9k/0 | 0.0009 | 67/4 |
| syn-large | pi | t24-editops | pass | 101.4 | 1 | 23.8k | 9.4k | 1.9k | 12.5k/0 | 0.0028 | 66/13 |
| syn-large | pi | t25-shardmap | pass | 25.8 | 1 | 11.0k | 2.1k | 983 | 8.0k/0 | 0.0011 | 76/16 |
| syn-large | pi | t26-logfilter | pass | 60.5 | 1 | 15.7k | 6.5k | 2.0k | 7.3k/0 | 0.0022 | 209/4 |
| syn-large | pi | t27-tarpeek | pass | 60.4 | 1 | 49.0k | 6.2k | 1.6k | 41.2k/0 | 0.0034 | 87/2 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 27/27 | 73 | 27.3k | 4.4k | 21.8k | 1.1k | 47/9 |
| syn-large | pi | 27/27 | 74 | 16.5k | 3.3k | 12.2k | 1.1k | 54/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
