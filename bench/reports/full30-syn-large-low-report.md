# bench report — full30-syn-large-low

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| syn-large | niffler | t01-roman | pass | 35.6 | 1 | 11.7k | 5.6k | 230 | 5.9k/0 | 0.0012 | 13/4 |
| syn-large | niffler | t02-jsonrepair | pass | 55.8 | 1 | 20.5k | 3.6k | 580 | 16.3k/0 | 0.0015 | 57/12 |
| syn-large | niffler | t03-ringbuffer | pass | 41.7 | 1 | 17.1k | 5.9k | 847 | 10.4k/0 | 0.0017 | 13/4 |
| syn-large | niffler | t04-csvbugfix | pass | 32.8 | 1 | 9.2k | 3.4k | 293 | 5.5k/0 | 0.0009 | 3/3 |
| syn-large | niffler | t05-todostore | pass | 24.1 | 1 | 11.7k | 993 | 234 | 10.5k/0 | 0.0007 | 16/15 |
| syn-large | niffler | t06-stackvm | pass | 74.9 | 1 | 74.4k | 10.6k | 3.2k | 60.5k/0 | 0.0056 | 150/40 |
| syn-large | niffler | t07-validate | pass | 142.8 | 1 | 59.7k | 9.5k | 1.8k | 48.5k/0 | 0.0042 | 7/5 |
| syn-large | niffler | t08-logsum | pass | 109.2 | 1 | 20.8k | 4.2k | 570 | 16.1k/0 | 0.0016 | 49/2 |
| syn-large | niffler | t09-poolrace | pass | 44 | 1 | 11.2k | 3.1k | 168 | 8.0k/0 | 0.0009 | 4/1 |
| syn-large | niffler | t10-iniparse | pass | 38 | 1 | 14.2k | 4.0k | 552 | 9.7k/0 | 0.0013 | 8/7 |
| syn-large | niffler | t11-asyncbugs | pass | 57.9 | 1 | 31.8k | 3.5k | 588 | 27.7k/0 | 0.0019 | 6/11 |
| syn-large | niffler | t12-refactor | pass | 110.4 | 1 | 56.8k | 5.6k | 1.4k | 49.9k/0 | 0.0035 | 8/2 |
| syn-large | niffler | t13-batchrename | pass | 12.9 | 1 | 15.9k | 1.4k | 190 | 14.3k/0 | 0.0009 | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 27.3 | 1 | 12.0k | 6.2k | 96 | 5.6k/0 | 0.0012 | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 29.7 | 1 | 15.4k | 6.5k | 277 | 8.7k/0 | 0.0015 | 1/0 |
| syn-large | niffler | t16-apisum | pass | 32.7 | 1 | 15.2k | 3.6k | 192 | 11.4k/0 | 0.0011 | 12/0 |
| syn-large | niffler | t17-doccheck | pass | 37.5 | 1 | 20.3k | 1.4k | 456 | 18.4k/0 | 0.0012 | 34/0 |
| syn-large | niffler | t18-lruttl | pass | 45.2 | 1 | 15.4k | 5.5k | 1.1k | 8.8k/0 | 0.0017 | 100/12 |
| syn-large | niffler | t19-tokbucket | pass | 41 | 1 | 16.6k | 4.8k | 502 | 11.3k/0 | 0.0014 | 23/18 |
| syn-large | niffler | t20-jsonpatch | pass | 57.7 | 1 | 29.9k | 3.7k | 2.0k | 24.3k/0 | 0.0025 | 137/15 |
| syn-large | niffler | t21-wireproto | pass | 60.6 | 1 | 17.4k | 2.2k | 760 | 14.4k/0 | 0.0013 | 70/31 |
| syn-large | niffler | t22-cronnext | pass | 81.9 | 1 | 101.4k | 10.3k | 2.0k | 89.2k/0 | 0.0061 | 86/17 |
| syn-large | niffler | t23-mergesched | pass | 81.2 | 1 | 13.3k | 907 | 720 | 11.6k/0 | 0.0010 | 60/7 |
| syn-large | niffler | t24-editops | pass | 53.1 | 1 | 28.1k | 3.0k | 1.5k | 23.6k/0 | 0.0021 | 64/12 |
| syn-large | niffler | t25-shardmap | pass | 64.3 | 1 | 16.8k | 4.5k | 732 | 11.6k/0 | 0.0015 | 81/30 |
| syn-large | niffler | t26-logfilter | pass | 71.5 | 1 | 39.1k | 3.9k | 1.9k | 33.3k/0 | 0.0029 | 177/4 |
| syn-large | niffler | t27-tarpeek | pass | 91.6 | 1 | 60.6k | 6.6k | 1.4k | 52.6k/0 | 0.0038 | 71/1 |
| syn-large | niffler | t28-docbackfill | pass | 67.1 | 1 | 12.8k | 1.6k | 267 | 10.9k/0 | 0.0008 | 18/9 |
| syn-large | niffler | t29-logrollup | pass | 28.4 | 1 | 9.9k | 1.2k | 238 | 8.4k/0 | 0.0006 | 436/0 |
| syn-large | niffler | t30-ifacedrift | pass | 32.8 | 1 | 24.0k | 2.4k | 312 | 21.3k/0 | 0.0014 | 48/48 |
| syn-large | pi | t28-docbackfill | pass | 26.1 | 1 | 11.7k | 2.5k | 510 | 8.6k/0 | 0.0010 | 18/9 |
| syn-large | pi | t29-logrollup | pass | 12.1 | 1 | 4.5k | 1.6k | 314 | 2.6k/0 | 0.0005 | 436/0 |
| syn-large | pi | t30-ifacedrift | pass | 14.8 | 1 | 5.5k | 2.5k | 273 | 2.8k/0 | 0.0006 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 30/30 | 56 | 26.8k | 4.3k | 21.6k | 833 | 60/11 |
| syn-large | pi | 3/3 | 18 | 7.2k | 2.2k | 4.7k | 366 | 167/19 |

*`invalid*` = tests pass but protected files (tests) were modified.*
