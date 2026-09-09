# bench report — full27-syn-large-high-trimmed

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t01-roman | pass | 25 | 1 | 18.3k | 4.6k | 540 | 13.2k/0 | 0.0015 | 19/1 |
| syn-large | niffler | t02-jsonrepair | pass | 112.5 | 1 | 37.7k | 5.8k | 6.0k | 25.9k/0 | 0.0049 | 107/1 |
| syn-large | niffler | t03-ringbuffer | pass | 105.4 | 1 | 14.0k | 4.7k | 626 | 8.6k/0 | 0.0014 | 16/4 |
| syn-large | niffler | t04-csvbugfix | pass | 62.2 | 1 | 17.4k | 5.2k | 607 | 11.6k/0 | 0.0015 | 3/3 |
| syn-large | niffler | t05-todostore | pass | 82.7 | 1 | 15.3k | 3.8k | 1.0k | 10.5k/0 | 0.0015 | 19/4 |
| syn-large | niffler | t06-stackvm | pass | 298.4 | 1 | 106.7k | 6.4k | 18.5k | 81.8k/0 | 0.0135 | 208/61 |
| syn-large | niffler | t07-validate | pass | 292 | 1 | 23.3k | 3.4k | 1.4k | 18.4k/0 | 0.0020 | 8/12 |
| syn-large | niffler | t08-logsum | pass | 103.8 | 1 | 27.9k | 5.9k | 4.1k | 18.0k/0 | 0.0037 | 77/3 |
| syn-large | niffler | t09-poolrace | pass | 96.9 | 1 | 22.0k | 4.6k | 935 | 16.5k/0 | 0.0018 | 4/1 |
| syn-large | niffler | t10-iniparse | pass | 65.8 | 1 | 24.9k | 4.5k | 1.6k | 18.8k/0 | 0.0022 | 6/5 |
| syn-large | niffler | t11-asyncbugs | pass | 60.8 | 1 | 14.3k | 3.4k | 846 | 10.1k/0 | 0.0013 | 4/5 |
| syn-large | niffler | t12-refactor | pass | 39 | 1 | 13.9k | 1.8k | 663 | 11.5k/0 | 0.0011 | 2/4 |
| syn-large | niffler | t13-batchrename | pass | 155.6 | 1 | 116.8k | 7.8k | 5.7k | 103.2k/0 | 0.0082 | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 165 | 1 | 25.0k | 3.2k | 1.3k | 20.5k/0 | 0.0020 | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 404.9 | 1 | 280.0k | 17.0k | 12.6k | 250.5k/0 | 0.0189 | 1/0 |
| syn-large | niffler | t16-apisum | pass | 415.6 | 1 | 16.3k | 1.7k | 411 | 14.2k/0 | 0.0010 | 24/0 |
| syn-large | niffler | t17-doccheck | pass | 219.5 | 1 | 87.9k | 4.7k | 11.0k | 72.3k/0 | 0.0091 | 164/0 |
| syn-large | niffler | t18-lruttl | pass | 242.3 | 1 | 41.8k | 6.0k | 3.5k | 32.3k/0 | 0.0040 | 124/12 |
| syn-large | niffler | t19-tokbucket | pass | 88.6 | 1 | 16.9k | 2.7k | 608 | 13.6k/0 | 0.0013 | 25/16 |
| syn-large | niffler | t20-jsonpatch | pass | 182.2 | 1 | 47.4k | 4.0k | 9.8k | 33.5k/0 | 0.0069 | 176/11 |
| syn-large | niffler | t21-wireproto | pass | 248.8 | 1 | 55.3k | 5.1k | 6.4k | 43.8k/0 | 0.0057 | 64/8 |
| syn-large | niffler | t22-cronnext | pass | 333 | 1 | 132.6k | 6.4k | 17.3k | 108.9k/0 | 0.0140 | 128/13 |
| syn-large | niffler | t23-mergesched | pass | 332.4 | 1 | 45.1k | 4.8k | 5.2k | 35.1k/0 | 0.0047 | 77/4 |
| syn-large | niffler | t24-editops | pass | 1283.4 | 1 | 48.5k | 13.5k | 10.2k | 24.8k/0 | 0.0081 | 100/6 |
| syn-large | niffler | t25-shardmap | pass | 998.4 | 1 | 24.5k | 4.7k | 1.0k | 18.8k/0 | 0.0020 | 85/16 |
| syn-large | niffler | t26-logfilter | pass | 328.6 | 1 | 44.0k | 19.5k | 9.8k | 14.7k/0 | 0.0084 | 214/4 |
| syn-large | niffler | t27-tarpeek | pass | 392.8 | 1 | 164.0k | 17.2k | 14.7k | 132.0k/0 | 0.0152 | 84/4 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 27/27 | 264 | 54.9k | 6.4k | 43.1k | 5.4k | 66/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
