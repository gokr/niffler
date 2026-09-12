# bench report — full30-claudecode-vs-niffler

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | claudecode | t01-roman | pass | 24.2 | 1 | 4 | 25.2k | 0 | 160 | 17.6k/7.5k | 0.0008 | 13/1 |
| syn-large | claudecode | t02-jsonrepair | pass | 38 | 1 | 8 | 36.6k | 0 | 546 | 20.7k/15.4k | 0.0011 | 69/1 |
| syn-large | claudecode | t03-ringbuffer | pass | 55.6 | 1 | 6 | 32.8k | 0 | 286 | 29.3k/3.3k | 0.0013 | 15/4 |
| syn-large | claudecode | t04-csvbugfix | pass | 31.5 | 1 | 10 | 39.1k | 0 | 193 | 29.5k/9.4k | 0.0013 | 3/3 |
| syn-large | claudecode | t05-todostore | pass | 38.8 | 1 | 6 | 33.1k | 0 | 287 | 25.1k/7.8k | 0.0011 | 16/4 |
| syn-large | claudecode | t06-stackvm | pass | 155.8 | 1 | 15 | 62.5k | 0 | 2.0k | 47.5k/13.0k | 0.0029 | 150/38 |
| syn-large | claudecode | t07-validate | pass | 49.5 | 1 | 13 | 54.4k | 0 | 581 | 39.6k/14.3k | 0.0019 | 14/9 |
| syn-large | claudecode | t08-logsum | pass | 66 | 1 | 18 | 81.6k | 0 | 729 | 75.8k/5.0k | 0.0034 | 50/2 |
| syn-large | claudecode | t09-poolrace | pass | 26.3 | 1 | 6 | 25.6k | 0 | 228 | 22.6k/2.8k | 0.0010 | 4/1 |
| syn-large | claudecode | t10-iniparse | pass | 43.9 | 1 | 10 | 40.8k | 0 | 504 | 32.1k/8.2k | 0.0015 | 6/5 |
| syn-large | claudecode | t11-asyncbugs | pass | 37.8 | 1 | 11 | 33.5k | 0 | 390 | 25.0k/8.1k | 0.0012 | 6/5 |
| syn-large | claudecode | t12-refactor | pass | 25.6 | 1 | 9 | 32.5k | 0 | 247 | 30.4k/1.8k | 0.0013 | 2/4 |
| syn-large | claudecode | t13-batchrename | pass | 20.3 | 1 | 6 | 26.7k | 0 | 201 | 24.6k/2.0k | 0.0011 | 27/27 |
| syn-large | claudecode | t14-todosweep | pass | 38.1 | 1 | 6 | 19.6k | 0 | 104 | 16.5k/3.1k | 0.0007 | 18/0 |
| syn-large | claudecode | t15-pollstats | pass | 26.1 | 1 | 7 | 31.6k | 0 | 152 | 18.3k/13.2k | 0.0008 | 1/0 |
| syn-large | claudecode | t16-apisum | pass | 31.6 | 1 | 7 | 32.1k | 0 | 197 | 30.3k/1.6k | 0.0013 | 21/0 |
| syn-large | claudecode | t17-doccheck | pass | 57.4 | 1 | 16 | 70.2k | 0 | 721 | 64.5k/5.0k | 0.0029 | 97/0 |
| syn-large | claudecode | t18-lruttl | pass | 52.9 | 1 | 9 | 43.6k | 0 | 618 | 34.4k/8.6k | 0.0017 | 100/12 |
| syn-large | claudecode | t19-tokbucket | pass | 29.6 | 1 | 6 | 26.5k | 0 | 323 | 23.2k/3.0k | 0.0011 | 25/16 |
| syn-large | claudecode | t20-jsonpatch | pass | 225.8 | 1 | 10 | 52.6k | 0 | 2.6k | 41.2k/8.8k | 0.0030 | 173/9 |
| syn-large | claudecode | t21-wireproto | pass | 98.6 | 1 | 12 | 45.6k | 0 | 1.3k | 40.5k/3.7k | 0.0023 | 61/8 |
| syn-large | claudecode | t22-cronnext | pass | 115.7 | 1 | 15 | 71.8k | 0 | 2.2k | 47.4k/22.2k | 0.0030 | 89/12 |
| syn-large | claudecode | t23-mergesched | pass | 32.4 | 1 | 6 | 26.5k | 0 | 433 | 21.4k/4.6k | 0.0011 | 72/4 |
| syn-large | claudecode | t24-editops | pass | 104.7 | 1 | 20 | 100.7k | 0 | 2.1k | 92.0k/6.6k | 0.0047 | 87/6 |
| syn-large | claudecode | t25-shardmap | pass | 58.4 | 1 | 9 | 50.1k | 0 | 520 | 43.4k/6.1k | 0.0020 | 78/16 |
| syn-large | claudecode | t26-logfilter | pass | 176.3 | 1 | 8 | 41.8k | 0 | 2.4k | 29.8k/9.6k | 0.0024 | 216/4 |
| syn-large | claudecode | t27-tarpeek | pass | 61.7 | 1 | 13 | 58.6k | 0 | 957 | 52.4k/5.3k | 0.0026 | 57/1 |
| syn-large | claudecode | t28-docbackfill | pass | 39.7 | 1 | 8 | 32.6k | 0 | 215 | 29.3k/3.1k | 0.0013 | 18/9 |
| syn-large | claudecode | t29-logrollup | pass | 31 | 1 | 7 | 26.3k | 0 | 229 | 18.2k/7.9k | 0.0008 | 436/0 |
| syn-large | claudecode | t30-ifacedrift | pass | 33.1 | 1 | 9 | 33.3k | 0 | 229 | 24.9k/8.1k | 0.0011 | 48/48 |
| syn-large | niffler | t01-roman | pass | 14.5 | 1 | 4 | 9.4k | 4.4k | 272 | 4.7k/0 | 0.0010 | 13/1 |
| syn-large | niffler | t02-jsonrepair | pass | 63.3 | 1 | 7 | 24.8k | 3.6k | 1.4k | 19.8k/0 | 0.0020 | 71/1 |
| syn-large | niffler | t03-ringbuffer | pass | 27.4 | 1 | 4 | 10.8k | 4.9k | 450 | 5.4k/0 | 0.0012 | 14/4 |
| syn-large | niffler | t04-csvbugfix | pass | 24.8 | 1 | 4 | 10.5k | 3.1k | 185 | 7.2k/0 | 0.0008 | 3/3 |
| syn-large | niffler | t05-todostore | pass | 14.6 | 1 | 4 | 10.5k | 3.0k | 400 | 7.1k/0 | 0.0009 | 16/4 |
| syn-large | niffler | t06-stackvm | pass | 289.1 | 1 | 33 | 340.4k | 11.0k | 7.7k | 321.6k/0 | 0.0184 | 118/40 |
| syn-large | niffler | t07-validate | pass | 116.3 | 1 | 7 | 27.0k | 6.8k | 745 | 19.5k/0 | 0.0022 | 10/9 |
| syn-large | niffler | t08-logsum | pass | 71.5 | 1 | 9 | 30.7k | 5.1k | 697 | 24.9k/0 | 0.0021 | 45/2 |
| syn-large | niffler | t09-poolrace | pass | 19.3 | 1 | 5 | 13.1k | 5.4k | 426 | 7.2k/0 | 0.0013 | 4/1 |
| syn-large | niffler | t10-iniparse | pass | 33.9 | 1 | 5 | 17.0k | 5.0k | 453 | 11.5k/0 | 0.0014 | 6/5 |
| syn-large | niffler | t11-asyncbugs | pass | 14 | 1 | 4 | 11.0k | 1.5k | 396 | 9.1k/0 | 0.0008 | 6/11 |
| syn-large | niffler | t12-refactor | pass | 35.9 | 1 | 9 | 27.5k | 1.9k | 518 | 25.1k/0 | 0.0016 | 2/4 |
| syn-large | niffler | t13-batchrename | pass | 10 | 1 | 3 | 7.4k | 819 | 90 | 6.5k/0 | 0.0004 | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 12 | 1 | 4 | 10.3k | 3.4k | 162 | 6.7k/0 | 0.0009 | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 15.6 | 1 | 4 | 10.3k | 3.0k | 187 | 7.1k/0 | 0.0008 | 1/0 |
| syn-large | niffler | t16-apisum | pass | 27.1 | 1 | 4 | 10.8k | 1.2k | 242 | 9.4k/0 | 0.0007 | 11/0 |
| syn-large | niffler | t17-doccheck | pass | 200.6 | 1 | 11 | 41.8k | 4.8k | 1.7k | 35.3k/0 | 0.0030 | 74/0 |
| syn-large | niffler | t18-lruttl | pass | 193.4 | 1 | 5 | 15.9k | 3.3k | 1.0k | 11.6k/0 | 0.0015 | 97/12 |
| syn-large | niffler | t19-tokbucket | pass | 18.7 | 1 | 4 | 11.9k | 1.4k | 511 | 10.0k/0 | 0.0009 | 23/18 |
| syn-large | niffler | t20-jsonpatch | pass | 204.7 | 1 | 26 | 233.9k | 8.8k | 3.6k | 221.4k/0 | 0.0120 | 164/12 |
| syn-large | niffler | t21-wireproto | pass | 42 | 1 | 6 | 26.5k | 3.1k | 1.2k | 22.1k/0 | 0.0019 | 58/8 |
| syn-large | niffler | t22-cronnext | pass | 133.9 | 1 | 9 | 49.4k | 11.5k | 2.6k | 35.3k/0 | 0.0044 | 91/17 |
| syn-large | niffler | t23-mergesched | pass | 25.8 | 1 | 4 | 12.0k | 945 | 831 | 10.2k/0 | 0.0010 | 59/4 |
| syn-large | niffler | t24-editops | pass | 29.6 | 1 | 6 | 22.7k | 2.4k | 1.0k | 19.3k/0 | 0.0016 | 66/14 |
| syn-large | niffler | t25-shardmap | pass | 36 | 1 | 5 | 16.4k | 1.2k | 882 | 14.3k/0 | 0.0012 | 73/16 |
| syn-large | niffler | t26-logfilter | pass | 70.1 | 1 | 8 | 38.8k | 3.4k | 1.9k | 33.5k/0 | 0.0028 | 190/4 |
| syn-large | niffler | t27-tarpeek | pass | 76.3 | 1 | 11 | 89.9k | 17.6k | 2.4k | 69.9k/0 | 0.0066 | 68/1 |
| syn-large | niffler | t28-docbackfill | pass | 29 | 1 | 4 | 11.3k | 4.2k | 262 | 6.8k/0 | 0.0010 | 18/9 |
| syn-large | niffler | t29-logrollup | pass | 17.8 | 1 | 5 | 14.4k | 1.8k | 373 | 12.2k/0 | 0.0009 | 436/0 |
| syn-large | niffler | t30-ifacedrift | pass | 26 | 1 | 4 | 11.9k | 1.6k | 223 | 10.0k/0 | 0.0008 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| syn-large | claudecode | 30/30 | 9.7 | 61 | 42.9k | 0 | 34.9k | 724 | 66/8 |
| syn-large | niffler | 30/30 | 7.3 | 63 | 38.9k | 4.3k | 33.5k | 1.1k | 61/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
