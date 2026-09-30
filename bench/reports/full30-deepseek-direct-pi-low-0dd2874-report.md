# bench report — full30-dsf-low-0dd2874

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 7.8 | 1 | 5 | 21.2k | 4.1k | 616 | 16.5k/0 | 0.0021 | 0.0021 | 32/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 13.9 | 1 | 7 | 33.5k | 4.2k | 2.0k | 27.4k/0 | 0.0038 | 0.0038 | 117/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 8.8 | 1 | 5 | 20.7k | 1.9k | 737 | 18.0k/0 | 0.0016 | 0.0016 | 18/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 8.5 | 1 | 6 | 25.9k | 2.4k | 595 | 22.9k/0 | 0.0016 | 0.0016 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 6.6 | 1 | 5 | 21.3k | 2.2k | 622 | 18.4k/0 | 0.0015 | 0.0015 | 16/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 27.7 | 1 | 5 | 52.6k | 6.9k | 6.3k | 39.4k/0 | 0.0098 | 0.0098 | 143/31 |
| deepseek-v4-flash | niffler | t07-validate | pass | 8.3 | 1 | 5 | 23.5k | 2.7k | 1.2k | 19.6k/0 | 0.0023 | 0.0023 | 9/8 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 15.4 | 1 | 9 | 49.8k | 3.4k | 2.0k | 44.4k/0 | 0.0037 | 0.0037 | 66/2 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 12.2 | 1 | 6 | 33.7k | 4.1k | 824 | 28.8k/0 | 0.0024 | 0.0024 | 7/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 16 | 1 | 5 | 24.2k | 2.6k | 1.0k | 20.6k/0 | 0.0021 | 0.0021 | 6/5 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 17 | 1 | 8 | 41.8k | 3.5k | 1.0k | 37.2k/0 | 0.0025 | 0.0025 | 5/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 6.4 | 1 | 4 | 16.8k | 2.0k | 454 | 14.3k/0 | 0.0012 | 0.0012 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 7.8 | 1 | 6 | 36.1k | 4.4k | 649 | 31.1k/0 | 0.0023 | 0.0023 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 7.5 | 1 | 5 | 22.5k | 2.3k | 573 | 19.6k/0 | 0.0015 | 0.0015 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 19.4 | 1 | 9 | 58.4k | 5.3k | 1.8k | 51.3k/0 | 0.0040 | 0.0040 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 14.1 | 1 | 7 | 33.6k | 3.4k | 745 | 29.4k/0 | 0.0021 | 0.0021 | 21/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 15.9 | 1 | 8 | 46.5k | 2.7k | 2.3k | 41.5k/0 | 0.0039 | 0.0039 | 90/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 12 | 1 | 4 | 25.5k | 3.6k | 1.7k | 20.1k/0 | 0.0033 | 0.0033 | 112/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 7.1 | 1 | 4 | 21.9k | 3.5k | 952 | 17.4k/0 | 0.0023 | 0.0023 | 26/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 29.4 | 1 | 6 | 56.8k | 4.4k | 6.8k | 45.6k/0 | 0.0098 | 0.0098 | 199/9 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 9.7 | 1 | 4 | 21.4k | 3.2k | 1.8k | 16.4k/0 | 0.0032 | 0.0032 | 68/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 19.7 | 1 | 5 | 37.8k | 4.5k | 4.0k | 29.3k/0 | 0.0063 | 0.0063 | 102/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 15.1 | 1 | 7 | 42.9k | 3.4k | 2.5k | 37.0k/0 | 0.0043 | 0.0043 | 65/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 19.7 | 1 | 5 | 33.8k | 3.2k | 3.8k | 26.8k/0 | 0.0057 | 0.0057 | 100/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 11.9 | 1 | 5 | 30.2k | 3.4k | 1.3k | 25.5k/0 | 0.0027 | 0.0027 | 84/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 25.2 | 1 | 6 | 43.4k | 3.5k | 5.2k | 34.7k/0 | 0.0075 | 0.0075 | 240/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 62.1 | 1 | 19 | 258.9k | 10.4k | 8.3k | 240.3k/0 | 0.0145 | 0.0145 | 89/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 9 | 1 | 5 | 24.4k | 2.7k | 1.1k | 20.6k/0 | 0.0022 | 0.0022 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 12.5 | 1 | 7 | 34.2k | 2.7k | 1.2k | 30.3k/0 | 0.0024 | 0.0024 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 12 | 1 | 6 | 45.9k | 6.6k | 1.1k | 38.3k/0 | 0.0035 | 0.0035 | 48/48 |
| deepseek-v4-flash | pi | t01-roman | pass | 4.9 | 1 | 4 | 10.8k | 2.5k | 609 | 7.7k/0 | 0.0015 | 0.0015 | 21/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 12.1 | 1 | 5 | 20.2k | 2.7k | 2.5k | 15.0k/0 | 0.0039 | 0.0039 | 95/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 7 | 1 | 4 | 11.9k | 2.4k | 760 | 8.7k/0 | 0.0017 | 0.0017 | 16/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 7.1 | 1 | 5 | 15.0k | 2.7k | 828 | 11.5k/0 | 0.0019 | 0.0019 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 6.3 | 1 | 5 | 15.5k | 2.9k | 930 | 11.6k/0 | 0.0020 | 0.0020 | 18/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 35.1 | 1 | 5 | 52.8k | 6.6k | 8.9k | 37.2k/0 | 0.0129 | 0.0129 | 185/52 |
| deepseek-v4-flash | pi | t07-validate | pass | 7.9 | 1 | 6 | 21.8k | 3.8k | 1.3k | 16.8k/0 | 0.0028 | 0.0028 | 8/6 |
| deepseek-v4-flash | pi | t08-logsum | pass | 14.1 | 1 | 7 | 29.8k | 3.6k | 2.3k | 23.9k/0 | 0.0039 | 0.0039 | 73/4 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 7.3 | 1 | 4 | 11.9k | 2.4k | 885 | 8.6k/0 | 0.0018 | 0.0018 | 10/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 17.5 | 1 | 6 | 23.6k | 3.7k | 1.3k | 18.6k/0 | 0.0028 | 0.0028 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 8.9 | 1 | 5 | 16.4k | 3.0k | 957 | 12.4k/0 | 0.0021 | 0.0021 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 8.1 | 1 | 6 | 19.2k | 3.1k | 958 | 15.1k/0 | 0.0022 | 0.0022 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 3.9 | 1 | 3 | 8.4k | 2.5k | 369 | 5.5k/0 | 0.0012 | 0.0012 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 8.4 | 1 | 5 | 18.1k | 3.2k | 1.4k | 13.6k/0 | 0.0027 | 0.0027 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 5.6 | 1 | 4 | 10.7k | 2.5k | 492 | 7.7k/0 | 0.0014 | 0.0014 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 7.3 | 1 | 4 | 11.6k | 2.6k | 573 | 8.4k/0 | 0.0015 | 0.0015 | 24/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 17.4 | 1 | 9 | 43.0k | 3.8k | 2.8k | 36.5k/0 | 0.0047 | 0.0047 | 109/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 11.3 | 1 | 5 | 22.7k | 4.2k | 1.9k | 16.5k/0 | 0.0037 | 0.0037 | 105/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 7.1 | 1 | 5 | 19.1k | 3.8k | 1.1k | 14.2k/0 | 0.0025 | 0.0025 | 25/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 30.4 | 1 | 6 | 44.5k | 4.9k | 7.3k | 32.3k/0 | 0.0104 | 0.0104 | 187/10 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 10.5 | 1 | 4 | 20.9k | 4.2k | 2.2k | 14.5k/0 | 0.0040 | 0.0040 | 60/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 18.8 | 1 | 5 | 32.1k | 4.8k | 4.0k | 23.3k/0 | 0.0064 | 0.0064 | 100/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 11.6 | 1 | 4 | 18.5k | 3.3k | 2.1k | 13.1k/0 | 0.0036 | 0.0036 | 72/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 29.3 | 1 | 9 | 74.1k | 5.5k | 6.3k | 62.3k/0 | 0.0096 | 0.0096 | 115/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 11.2 | 1 | 5 | 25.0k | 4.1k | 2.2k | 18.7k/0 | 0.0040 | 0.0040 | 73/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 27 | 1 | 5 | 39.4k | 3.9k | 6.4k | 29.1k/0 | 0.0090 | 0.0090 | 291/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 30.9 | 1 | 8 | 86.2k | 9.6k | 5.7k | 70.9k/0 | 0.0102 | 0.0102 | 88/1 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 7.1 | 1 | 5 | 19.0k | 4.1k | 884 | 14.0k/0 | 0.0024 | 0.0024 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 4.5 | 1 | 3 | 9.0k | 2.6k | 610 | 5.8k/0 | 0.0015 | 0.0015 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 7.2 | 1 | 5 | 25.6k | 5.2k | 880 | 19.6k/0 | 0.0027 | 0.0027 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 30/30 | 6.3 | 15 | 41.3k | 3.8k | 35.4k | 2.1k | 0.1160 | 0.1160 | 72/8 |
| deepseek-v4-flash | pi | 30/30 | 5.2 | 13 | 25.9k | 3.8k | 19.8k | 2.3k | 0.1211 | 0.1211 | 75/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
