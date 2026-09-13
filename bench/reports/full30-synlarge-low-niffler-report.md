# bench report — full30-synlarge-low-niffler

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| syn-large | niffler | t01-roman | pass | 15.3 | 1 | 4 | 10.6k | 5.0k | 354 | 5.2k/0 | 0.0011 | — | 13/1 |
| syn-large | niffler | t02-jsonrepair | pass | 40.5 | 1 | 5 | 15.6k | 5.7k | 601 | 9.3k/0 | 0.0015 | — | 58/10 |
| syn-large | niffler | t03-ringbuffer | pass | 44.6 | 1 | 4 | 11.7k | 3.3k | 414 | 8.0k/0 | 0.0010 | — | 15/4 |
| syn-large | niffler | t04-csvbugfix | pass | 37.6 | 1 | 5 | 14.6k | 1.3k | 207 | 13.1k/0 | 0.0008 | — | 3/3 |
| syn-large | niffler | t05-todostore | pass | 34.8 | 1 | 4 | 11.2k | 3.3k | 324 | 7.6k/0 | 0.0010 | — | 16/15 |
| syn-large | niffler | t06-stackvm | pass | 58.2 | 1 | 5 | 26.2k | 7.5k | 2.1k | 16.7k/0 | 0.0028 | — | 120/71 |
| syn-large | niffler | t07-validate | pass | 56 | 1 | 4 | 14.5k | 4.3k | 384 | 9.9k/0 | 0.0012 | — | 7/8 |
| syn-large | niffler | t08-logsum | pass | 39.6 | 1 | 7 | 25.2k | 4.9k | 650 | 19.6k/0 | 0.0018 | — | 42/2 |
| syn-large | niffler | t09-poolrace | pass | 44.2 | 1 | 4 | 11.0k | 3.1k | 211 | 7.6k/0 | 0.0009 | — | 4/1 |
| syn-large | niffler | t10-iniparse | pass | 59.2 | 1 | 8 | 30.0k | 2.6k | 564 | 26.8k/0 | 0.0018 | — | 8/5 |
| syn-large | niffler | t11-asyncbugs | pass | 81.2 | 1 | 10 | 41.6k | 5.5k | 1.2k | 34.9k/0 | 0.0028 | — | 7/6 |
| syn-large | niffler | t12-refactor | pass | 51.7 | 1 | 4 | 12.1k | 3.5k | 317 | 8.3k/0 | 0.0010 | — | 2/4 |
| syn-large | niffler | t13-batchrename | pass | 17.9 | 1 | 3 | 8.1k | 976 | 100 | 7.0k/0 | 0.0005 | — | 27/27 |
| syn-large | niffler | t14-todosweep | pass | 13.2 | 1 | 3 | 8.7k | 1.3k | 102 | 7.3k/0 | 0.0005 | — | 18/0 |
| syn-large | niffler | t15-pollstats | pass | 19.3 | 1 | 4 | 10.3k | 707 | 219 | 9.4k/0 | 0.0006 | — | 1/0 |
| syn-large | niffler | t16-apisum | pass | 27.2 | 1 | 4 | 10.8k | 836 | 163 | 9.8k/0 | 0.0006 | — | 13/0 |
| syn-large | niffler | t17-doccheck | pass | 47.7 | 1 | 8 | 28.7k | 1.9k | 805 | 26.0k/0 | 0.0017 | — | 75/0 |
| syn-large | niffler | t18-lruttl | pass | 64.7 | 1 | 5 | 19.3k | 1.4k | 1.1k | 16.8k/0 | 0.0014 | — | 79/12 |
| syn-large | niffler | t19-tokbucket | pass | 59.2 | 1 | 7 | 31.3k | 3.8k | 745 | 26.8k/0 | 0.0020 | — | 20/7 |
| syn-large | niffler | t20-jsonpatch | pass | 65.6 | 1 | 6 | 29.7k | 6.2k | 1.6k | 21.9k/0 | 0.0026 | — | 117/20 |
| syn-large | niffler | t21-wireproto | pass | 67.5 | 1 | 5 | 22.1k | 4.7k | 1.0k | 16.3k/0 | 0.0019 | — | 53/8 |
| syn-large | niffler | t22-cronnext | pass | 75.3 | 1 | 9 | 56.9k | 5.9k | 1.9k | 49.2k/0 | 0.0038 | — | 98/17 |
| syn-large | niffler | t23-mergesched | pass | 70.4 | 1 | 6 | 21.4k | 1.4k | 1.0k | 18.9k/0 | 0.0015 | — | 71/7 |
| syn-large | niffler | t24-editops | pass | 53.1 | 1 | 5 | 20.2k | 2.7k | 927 | 16.6k/0 | 0.0015 | — | 62/14 |
| syn-large | niffler | t25-shardmap | pass | 53.1 | 1 | 5 | 19.5k | 1.9k | 969 | 16.7k/0 | 0.0014 | — | 84/16 |
| syn-large | niffler | t26-logfilter | pass | 78.4 | 1 | 8 | 45.7k | 7.1k | 2.6k | 36.0k/0 | 0.0038 | — | 234/4 |
| syn-large | niffler | t27-tarpeek | pass | 76.6 | 1 | 4 | 20.2k | 3.5k | 959 | 15.7k/0 | 0.0016 | — | 63/1 |
| syn-large | niffler | t28-docbackfill | pass | 39.8 | 1 | 5 | 16.2k | 1.6k | 502 | 14.1k/0 | 0.0011 | — | 18/9 |
| syn-large | niffler | t29-logrollup | pass | 26.3 | 1 | 3 | 8.3k | 1.1k | 252 | 7.0k/0 | 0.0006 | — | 436/0 |
| syn-large | niffler | t30-ifacedrift | pass | 20.6 | 1 | 4 | 12.5k | 1.6k | 266 | 10.6k/0 | 0.0008 | — | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| syn-large | niffler | 30/30 | 5.3 | 48 | 20.5k | 3.3k | 16.4k | 754 | 0.0458 | 0.0000 | 60/11 |

*`invalid*` = tests pass but protected files (tests) were modified.*
