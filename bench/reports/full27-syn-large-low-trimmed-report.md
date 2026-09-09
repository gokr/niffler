# bench report — full27-syn-large-low-trimmed

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t01-roman | pass | 10.1 | 1 | 8.6k | 4.0k | 250 | 4.3k/0 | 0.0009 | 13/4 |
| syn-large | niffler | t02-jsonrepair | pass | 81.4 | 1 | 53.1k | 9.6k | 2.1k | 41.4k/0 | 0.0041 | 79/10 |
| syn-large | niffler | t03-ringbuffer | pass | 90.2 | 1 | 9.2k | 2.5k | 436 | 6.3k/0 | 0.0008 | 13/4 |
| syn-large | niffler | t04-csvbugfix | pass | 40 | 1 | 12.1k | 3.0k | 229 | 8.9k/0 | 0.0009 | 3/3 |
| syn-large | niffler | t05-todostore | pass | 35.5 | 1 | 9.1k | 4.3k | 382 | 4.4k/0 | 0.0010 | 16/4 |
| syn-large | niffler | t06-stackvm | pass | 60.3 | 1 | 28.6k | 4.3k | 2.6k | 21.8k/0 | 0.0028 | 163/49 |
| syn-large | niffler | t07-validate | pass | 71.4 | 1 | 24.5k | 4.4k | 718 | 19.4k/0 | 0.0018 | 7/12 |
| syn-large | niffler | t08-logsum | pass | 43.7 | 1 | 16.9k | 1.9k | 556 | 14.4k/0 | 0.0011 | 42/2 |
| syn-large | niffler | t09-poolrace | pass | 29.4 | 1 | 8.5k | 2.3k | 354 | 5.8k/0 | 0.0008 | 15/12 |
| syn-large | niffler | t10-iniparse | pass | 32 | 1 | 14.2k | 1.9k | 406 | 11.8k/0 | 0.0010 | 9/6 |
| syn-large | niffler | t11-asyncbugs | pass | 43.5 | 1 | 16.5k | 2.2k | 510 | 13.8k/0 | 0.0011 | 6/17 |
| syn-large | niffler | t12-refactor | pass | 36.1 | 1 | 9.7k | 1.0k | 323 | 8.4k/0 | 0.0007 | 2/4 |
| syn-large | niffler | t13-batchrename | pass | 46.7 | 1 | 38.7k | 5.6k | 571 | 32.5k/0 | 0.0024 | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 41.6 | 1 | 9.1k | 1.4k | 165 | 7.6k/0 | 0.0006 | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 18.3 | 1 | 7.9k | 809 | 161 | 6.9k/0 | 0.0005 | 1/0 |
| syn-large | niffler | t16-apisum | pass | 27.8 | 1 | 11.1k | 1.1k | 178 | 9.9k/0 | 0.0006 | 14/0 |
| syn-large | niffler | t17-doccheck | pass | 67.9 | 1 | 45.9k | 2.9k | 1.8k | 41.2k/0 | 0.0030 | 73/0 |
| syn-large | niffler | t18-lruttl | pass | 75.5 | 1 | 11.8k | 1.2k | 973 | 9.6k/0 | 0.0011 | 85/12 |
| syn-large | niffler | t19-tokbucket | pass | 38.3 | 1 | 12.6k | 1.7k | 455 | 10.5k/0 | 0.0009 | 19/25 |
| syn-large | niffler | t20-jsonpatch | pass | 59.5 | 1 | 39.7k | 7.2k | 2.3k | 30.2k/0 | 0.0034 | 167/20 |
| syn-large | niffler | t21-wireproto | pass | 70.9 | 1 | 18.6k | 3.0k | 1.0k | 14.5k/0 | 0.0015 | 62/8 |
| syn-large | niffler | t22-cronnext | pass | 63.8 | 1 | 35.2k | 4.4k | 1.7k | 29.1k/0 | 0.0027 | 100/17 |
| syn-large | niffler | t23-mergesched | pass | 56.5 | 1 | 10.6k | 972 | 787 | 8.8k/0 | 0.0009 | 63/4 |
| syn-large | niffler | t24-editops | pass | 81.2 | 1 | 53.8k | 4.1k | 3.2k | 46.5k/0 | 0.0041 | 53/14 |
| syn-large | niffler | t25-shardmap | pass | 93.3 | 1 | 14.7k | 1.4k | 892 | 12.5k/0 | 0.0011 | 77/16 |
| syn-large | niffler | t26-logfilter | pass | 88.1 | 1 | 23.2k | 2.2k | 2.3k | 18.8k/0 | 0.0022 | 198/4 |
| syn-large | niffler | t27-tarpeek | pass | 106.9 | 1 | 34.0k | 3.9k | 1.3k | 28.8k/0 | 0.0024 | 51/1 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 27/27 | 56 | 21.4k | 3.1k | 17.3k | 988 | 51/10 |

*`invalid*` = tests pass but protected files (tests) were modified.*
