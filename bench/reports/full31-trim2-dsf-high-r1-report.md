# bench report — full31-trim2-r1

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 10.7 | 1 | 6 | 25.8k | 4.8k | 933 | 20.1k/0 | 0.0027 | 0.0027 | 35/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 17.5 | 1 | 5 | 27.4k | 4.3k | 3.4k | 19.7k/0 | 0.0055 | 0.0055 | 107/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 12.9 | 1 | 6 | 24.5k | 2.1k | 1.2k | 21.2k/0 | 0.0022 | 0.0022 | 24/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 10.1 | 1 | 6 | 24.8k | 2.5k | 698 | 21.6k/0 | 0.0017 | 0.0017 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 11 | 1 | 6 | 25.6k | 2.5k | 997 | 22.1k/0 | 0.0021 | 0.0021 | 23/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 41.8 | 1 | 8 | 99.4k | 7.3k | 7.8k | 84.4k/0 | 0.0121 | 0.0121 | 138/36 |
| deepseek-v4-flash | niffler | t07-validate | pass | 8.8 | 1 | 5 | 25.6k | 3.6k | 1.3k | 20.7k/0 | 0.0027 | 0.0027 | 19/10 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 30 | 1 | 8 | 68.1k | 4.7k | 5.4k | 58.0k/0 | 0.0082 | 0.0082 | 120/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 21.8 | 1 | 7 | 37.9k | 4.0k | 1.4k | 32.5k/0 | 0.0030 | 0.0030 | 9/2 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 20.1 | 1 | 6 | 31.4k | 2.7k | 2.4k | 26.2k/0 | 0.0039 | 0.0039 | 13/7 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 7.7 | 1 | 5 | 20.5k | 2.2k | 743 | 17.5k/0 | 0.0016 | 0.0016 | 6/11 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 9.8 | 1 | 6 | 27.4k | 2.7k | 1.1k | 23.7k/0 | 0.0022 | 0.0022 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 67.7 | 1 | 6 | 67.1k | 13.5k | 2.5k | 51.1k/0 | 0.0073 | 0.0073 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 16.5 | 1 | 6 | 34.9k | 3.1k | 2.7k | 29.2k/0 | 0.0043 | 0.0043 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 16.9 | 1 | 8 | 49.8k | 4.3k | 2.8k | 42.8k/0 | 0.0049 | 0.0049 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 11.8 | 1 | 5 | 19.0k | 1.9k | 491 | 16.6k/0 | 0.0013 | 0.0013 | 24/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 48.2 | 1 | 10 | 70.5k | 4.8k | 3.8k | 62.0k/0 | 0.0063 | 0.0063 | 124/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 18.3 | 1 | 4 | 26.1k | 3.6k | 2.3k | 20.1k/0 | 0.0040 | 0.0040 | 112/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 13.8 | 1 | 4 | 20.0k | 2.9k | 1.1k | 16.0k/0 | 0.0023 | 0.0023 | 25/9 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 59.3 | 1 | 7 | 87.1k | 4.7k | 13.4k | 69.0k/0 | 0.0179 | 0.0179 | 203/9 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 23.9 | 1 | 10 | 81.1k | 5.9k | 2.9k | 72.3k/0 | 0.0057 | 0.0057 | 63/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 34.9 | 1 | 6 | 61.5k | 4.5k | 7.7k | 49.3k/0 | 0.0109 | 0.0109 | 129/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 16 | 1 | 5 | 27.1k | 2.8k | 2.6k | 21.8k/0 | 0.0040 | 0.0040 | 85/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 35.7 | 1 | 8 | 69.5k | 4.1k | 6.9k | 58.5k/0 | 0.0099 | 0.0099 | 106/6 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 14.8 | 1 | 6 | 33.7k | 3.5k | 1.7k | 28.4k/0 | 0.0033 | 0.0033 | 89/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 36.6 | 1 | 5 | 47.5k | 3.2k | 8.8k | 35.5k/0 | 0.0118 | 0.0118 | 254/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 85.5 | 1 | 20 | 376.3k | 12.7k | 15.8k | 347.8k/0 | 0.0249 | 0.0249 | 94/2 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 19.9 | 1 | 12 | 98.8k | 7.9k | 2.4k | 88.6k/0 | 0.0057 | 0.0057 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 8.1 | 1 | 5 | 22.4k | 2.5k | 847 | 19.1k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 66.5 | 1 | 6 | 70.4k | 14.3k | 4.6k | 51.5k/0 | 0.0102 | 0.0102 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 16 | 1 | 5 | 29.7k | 4.9k | 836 | 23.9k/0 | 0.0026 | 0.0026 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 4.4 | 1 | 4 | 9.9k | 2.3k | 413 | 7.2k/0 | 0.0012 | 0.0012 | 15/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 19.4 | 1 | 6 | 29.5k | 3.1k | 3.9k | 22.5k/0 | 0.0058 | 0.0058 | 107/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 11.3 | 1 | 5 | 16.2k | 2.6k | 1.2k | 12.3k/0 | 0.0024 | 0.0024 | 20/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 5.7 | 1 | 5 | 14.3k | 2.6k | 693 | 11.0k/0 | 0.0017 | 0.0017 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 7.3 | 1 | 5 | 15.9k | 3.0k | 1.0k | 11.9k/0 | 0.0022 | 0.0022 | 16/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 37.4 | 1 | 5 | 53.1k | 6.5k | 9.5k | 37.1k/0 | 0.0135 | 0.0135 | 146/34 |
| deepseek-v4-flash | pi | t07-validate | pass | 10.7 | 1 | 5 | 21.1k | 3.6k | 2.0k | 15.5k/0 | 0.0036 | 0.0036 | 11/10 |
| deepseek-v4-flash | pi | t08-logsum | pass | 22.8 | 1 | 8 | 45.4k | 4.6k | 4.4k | 36.5k/0 | 0.0069 | 0.0069 | 73/3 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 9 | 1 | 5 | 14.2k | 2.5k | 910 | 10.8k/0 | 0.0019 | 0.0019 | 7/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 12.6 | 1 | 6 | 22.9k | 3.4k | 1.5k | 18.0k/0 | 0.0029 | 0.0029 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 8.2 | 1 | 5 | 16.9k | 3.0k | 1.2k | 12.7k/0 | 0.0025 | 0.0025 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 7 | 1 | 5 | 16.6k | 2.8k | 1.1k | 12.7k/0 | 0.0022 | 0.0022 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 6.3 | 1 | 5 | 18.8k | 3.7k | 727 | 14.3k/0 | 0.0021 | 0.0021 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 9.6 | 1 | 6 | 24.7k | 4.0k | 1.4k | 19.3k/0 | 0.0030 | 0.0030 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 3.9 | 1 | 3 | 7.8k | 2.2k | 434 | 5.1k/0 | 0.0012 | 0.0012 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 6.3 | 1 | 4 | 11.2k | 2.5k | 545 | 8.2k/0 | 0.0014 | 0.0014 | 18/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 19.3 | 1 | 10 | 52.9k | 4.1k | 3.3k | 45.4k/0 | 0.0055 | 0.0055 | 129/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 9.9 | 1 | 5 | 22.4k | 4.1k | 1.8k | 16.5k/0 | 0.0035 | 0.0035 | 115/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 8.9 | 1 | 5 | 20.3k | 3.7k | 1.4k | 15.2k/0 | 0.0029 | 0.0029 | 25/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 33 | 1 | 5 | 43.8k | 5.4k | 7.9k | 30.6k/0 | 0.0112 | 0.0112 | 199/9 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 19.8 | 1 | 5 | 30.5k | 4.1k | 4.6k | 21.8k/0 | 0.0069 | 0.0069 | 71/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 30.4 | 1 | 5 | 36.9k | 4.8k | 5.7k | 26.5k/0 | 0.0084 | 0.0084 | 117/12 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 15.6 | 1 | 4 | 21.4k | 3.4k | 3.2k | 14.8k/0 | 0.0049 | 0.0049 | 81/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 46.1 | 1 | 10 | 111.5k | 6.2k | 9.8k | 95.5k/0 | 0.0142 | 0.0142 | 122/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 8.2 | 1 | 4 | 17.0k | 3.7k | 1.4k | 11.9k/0 | 0.0029 | 0.0029 | 79/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 37.2 | 1 | 5 | 44.2k | 3.8k | 9.7k | 30.7k/0 | 0.0130 | 0.0130 | 257/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 36.6 | 1 | 12 | 153.5k | 10.1k | 6.3k | 137.1k/0 | 0.0114 | 0.0114 | 87/3 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 9.3 | 1 | 5 | 22.0k | 5.3k | 1.6k | 15.1k/0 | 0.0036 | 0.0036 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 5.6 | 1 | 4 | 12.5k | 2.8k | 809 | 8.8k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 9 | 1 | 7 | 44.7k | 7.5k | 1.1k | 36.1k/0 | 0.0038 | 0.0038 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 7.2 | 1 | 5 | 17.5k | 3.1k | 1.2k | 13.2k/0 | 0.0024 | 0.0024 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.8 | 26 | 55.8k | 4.8k | 47.5k | 3.6k | 0.1871 | 0.1871 | 76/8 |
| deepseek-v4-flash | pi | 31/31 | 5.6 | 15 | 31.9k | 4.0k | 25.0k | 2.9k | 0.1508 | 0.1508 | 73/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
