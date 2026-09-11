# bench report — full30-deepseek-direct-high-reads-088826f

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 8.1 | 1 | 5 | 17.7k | 3.9k | 707 | 13.1k/0 | 0.0023 | 15/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 37.5 | 1 | 11 | 76.4k | 4.1k | 5.0k | 67.3k/0 | 0.0087 | 90/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 50.1 | 1 | 6 | 24.8k | 2.0k | 1.7k | 21.0k/0 | 0.0031 | 20/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 30.6 | 1 | 7 | 28.2k | 2.8k | 909 | 24.4k/0 | 0.0025 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 23.5 | 1 | 6 | 27.3k | 2.6k | 2.0k | 22.8k/0 | 0.0036 | 22/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 36.1 | 1 | 5 | 44.9k | 6.8k | 4.9k | 33.2k/0 | 0.0085 | 160/80 |
| deepseek-v4-flash | niffler | t07-validate | pass | 36 | 1 | 7 | 34.5k | 3.4k | 2.0k | 29.1k/0 | 0.0040 | 21/10 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 62.2 | 1 | 11 | 108.0k | 5.9k | 8.9k | 93.2k/0 | 0.0144 | 73/3 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 67.9 | 1 | 7 | 31.8k | 3.4k | 1.4k | 27.0k/0 | 0.0033 | 9/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 38.7 | 1 | 8 | 41.1k | 3.7k | 1.9k | 35.5k/0 | 0.0042 | 8/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 29 | 1 | 6 | 24.7k | 2.5k | 1.5k | 20.7k/0 | 0.0030 | 7/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 17.7 | 1 | 5 | 18.9k | 2.5k | 817 | 15.6k/0 | 0.0021 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 21.1 | 1 | 7 | 58.7k | 8.1k | 1.2k | 49.4k/0 | 0.0051 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 32.6 | 1 | 8 | 48.0k | 3.2k | 3.2k | 41.6k/0 | 0.0057 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 47.4 | 1 | 8 | 52.8k | 5.6k | 3.6k | 43.6k/0 | 0.0069 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 37.5 | 1 | 5 | 17.4k | 2.1k | 628 | 14.7k/0 | 0.0017 | 26/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 56 | 1 | 11 | 105.5k | 4.6k | 8.0k | 92.8k/0 | 0.0131 | 155/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 75.7 | 1 | 11 | 91.2k | 5.0k | 5.2k | 81.0k/0 | 0.0096 | 123/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 37.6 | 1 | 5 | 22.8k | 3.3k | 1.1k | 18.4k/0 | 0.0027 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 80.7 | 1 | 15 | 256.5k | 7.0k | 16.6k | 232.8k/0 | 0.0275 | 288/10 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 93.1 | 1 | 7 | 47.6k | 4.1k | 3.9k | 39.7k/0 | 0.0067 | 71/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 65.1 | 1 | 11 | 126.9k | 5.8k | 10.4k | 110.7k/0 | 0.0166 | 113/17 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 77.3 | 1 | 13 | 100.1k | 4.3k | 5.5k | 90.2k/0 | 0.0101 | 74/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 108.7 | 1 | 18 | 267.3k | 7.6k | 13.3k | 246.4k/0 | 0.0242 | 180/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 91.5 | 1 | 7 | 43.9k | 5.1k | 1.8k | 37.0k/0 | 0.0046 | 84/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 50.9 | 1 | 6 | 54.1k | 3.8k | 7.8k | 42.5k/0 | 0.0112 | 276/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 104.6 | 1 | 14 | 258.6k | 11.7k | 11.9k | 235.0k/0 | 0.0235 | 114/4 |
| deepseek-v4-flash | niffler | t28-docbackfill | error | 71.5 | 1 | 2 | 6.0k | 1.5k | 210 | 4.4k/0 | 0.0008 | 0/0 |
| deepseek-v4-flash | niffler | t29-logrollup | error | 2.7 | 1 | 0 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | error | 1.4 | 1 | 0 | 0 | 0 | 0 | 0/0 | 0.0000 | 0/0 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 27/30 | 7.7 | 50 | 67.9k | 4.2k | 59.4k | 4.2k | 67/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
