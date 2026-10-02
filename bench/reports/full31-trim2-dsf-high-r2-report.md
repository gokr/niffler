# bench report — full31-trim2-r2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 5.9 | 1 | 4 | 14.4k | 3.5k | 543 | 10.4k/0 | 0.0018 | 0.0018 | 36/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 10.3 | 1 | 5 | 22.2k | 3.9k | 1.6k | 16.8k/0 | 0.0031 | 0.0031 | 97/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 11.8 | 1 | 5 | 20.3k | 2.0k | 972 | 17.3k/0 | 0.0019 | 0.0019 | 25/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 10.6 | 1 | 5 | 21.5k | 2.8k | 546 | 18.2k/0 | 0.0016 | 0.0016 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9.8 | 1 | 6 | 24.7k | 2.4k | 749 | 21.5k/0 | 0.0018 | 0.0018 | 16/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 31.3 | 1 | 10 | 120.5k | 8.5k | 5.8k | 106.2k/0 | 0.0101 | 0.0101 | 147/59 |
| deepseek-v4-flash | niffler | t07-validate | pass | 15.7 | 1 | 7 | 42.4k | 3.7k | 2.6k | 36.1k/0 | 0.0045 | 0.0045 | 20/11 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 26.4 | 1 | 10 | 68.4k | 4.3k | 3.9k | 60.2k/0 | 0.0064 | 0.0064 | 81/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 16.3 | 1 | 7 | 35.6k | 3.5k | 1.1k | 31.0k/0 | 0.0026 | 0.0026 | 4/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 21.9 | 1 | 7 | 38.8k | 3.5k | 1.8k | 33.5k/0 | 0.0034 | 0.0034 | 6/5 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 13.8 | 1 | 5 | 27.7k | 4.1k | 1.4k | 22.1k/0 | 0.0031 | 0.0031 | 7/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 12.3 | 1 | 5 | 20.9k | 2.4k | 680 | 17.9k/0 | 0.0016 | 0.0016 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 14.5 | 1 | 7 | 48.8k | 6.0k | 1.2k | 41.6k/0 | 0.0035 | 0.0035 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 10.2 | 1 | 6 | 27.5k | 2.7k | 1.0k | 23.7k/0 | 0.0022 | 0.0022 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 16.9 | 1 | 9 | 59.9k | 5.5k | 1.8k | 52.6k/0 | 0.0042 | 0.0042 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 14.3 | 1 | 8 | 40.5k | 3.9k | 800 | 35.8k/0 | 0.0023 | 0.0023 | 25/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 45.1 | 1 | 9 | 85.8k | 4.7k | 6.7k | 74.4k/0 | 0.0099 | 0.0099 | 129/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 15.4 | 1 | 4 | 28.2k | 3.5k | 3.0k | 21.6k/0 | 0.0048 | 0.0048 | 112/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 7.1 | 1 | 4 | 20.1k | 3.0k | 933 | 16.1k/0 | 0.0021 | 0.0021 | 27/13 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 42.6 | 1 | 7 | 82.9k | 4.4k | 9.9k | 68.6k/0 | 0.0136 | 0.0136 | 207/9 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 18.2 | 1 | 5 | 37.8k | 3.6k | 3.4k | 30.8k/0 | 0.0053 | 0.0053 | 71/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 24.8 | 1 | 5 | 40.2k | 4.0k | 5.1k | 31.0k/0 | 0.0076 | 0.0076 | 127/12 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 19.6 | 1 | 6 | 35.4k | 2.8k | 3.2k | 29.4k/0 | 0.0049 | 0.0049 | 84/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 48.6 | 1 | 11 | 131.5k | 5.1k | 10.9k | 115.5k/0 | 0.0153 | 0.0153 | 132/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 11.4 | 1 | 5 | 25.5k | 3.3k | 1.3k | 20.9k/0 | 0.0027 | 0.0027 | 83/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 33.4 | 1 | 5 | 45.3k | 3.2k | 8.1k | 34.0k/0 | 0.0108 | 0.0108 | 245/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 43.5 | 1 | 14 | 193.2k | 10.3k | 7.0k | 175.9k/0 | 0.0125 | 0.0125 | 99/3 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 10.3 | 1 | 6 | 39.6k | 6.8k | 1.3k | 31.5k/0 | 0.0037 | 0.0037 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 8.5 | 1 | 5 | 22.6k | 2.8k | 946 | 18.8k/0 | 0.0021 | 0.0021 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 10.3 | 1 | 6 | 42.3k | 6.5k | 1.0k | 34.8k/0 | 0.0034 | 0.0034 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 11.2 | 1 | 5 | 27.2k | 4.2k | 759 | 22.3k/0 | 0.0023 | 0.0023 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 4.6 | 1 | 4 | 10.4k | 2.4k | 536 | 7.4k/0 | 0.0014 | 0.0014 | 15/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 7.7 | 1 | 5 | 15.0k | 2.5k | 1.3k | 11.1k/0 | 0.0024 | 0.0024 | 74/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 9.5 | 1 | 5 | 14.5k | 2.4k | 915 | 11.1k/0 | 0.0019 | 0.0019 | 15/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 7.2 | 1 | 6 | 18.7k | 3.0k | 840 | 14.8k/0 | 0.0020 | 0.0020 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 6.2 | 1 | 5 | 14.4k | 2.8k | 683 | 10.9k/0 | 0.0017 | 0.0017 | 18/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 30.2 | 1 | 7 | 77.9k | 6.9k | 8.2k | 62.8k/0 | 0.0123 | 0.0123 | 138/25 |
| deepseek-v4-flash | pi | t07-validate | pass | 10.3 | 1 | 5 | 22.9k | 4.3k | 2.0k | 16.5k/0 | 0.0038 | 0.0038 | 15/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 12 | 1 | 6 | 24.0k | 3.1k | 2.2k | 18.7k/0 | 0.0037 | 0.0037 | 79/5 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 5.8 | 1 | 4 | 10.9k | 2.4k | 586 | 7.9k/0 | 0.0015 | 0.0015 | 7/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 15.4 | 1 | 6 | 22.5k | 3.7k | 1.3k | 17.5k/0 | 0.0028 | 0.0028 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 7.2 | 1 | 5 | 16.7k | 3.0k | 1.1k | 12.5k/0 | 0.0023 | 0.0023 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 9.9 | 1 | 6 | 22.0k | 3.3k | 1.3k | 17.4k/0 | 0.0027 | 0.0027 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 5.1 | 1 | 4 | 13.0k | 3.3k | 482 | 9.2k/0 | 0.0016 | 0.0016 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 7.8 | 1 | 4 | 13.0k | 2.7k | 1.0k | 9.2k/0 | 0.0021 | 0.0021 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 6.6 | 1 | 5 | 15.8k | 2.6k | 1.0k | 12.2k/0 | 0.0021 | 0.0021 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 6.8 | 1 | 5 | 13.2k | 2.6k | 435 | 10.2k/0 | 0.0013 | 0.0013 | 22/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 40.1 | 1 | 13 | 111.1k | 5.0k | 8.0k | 98.0k/0 | 0.0117 | 0.0117 | 145/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 10.2 | 1 | 5 | 24.4k | 4.1k | 1.7k | 18.6k/0 | 0.0034 | 0.0034 | 102/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 7.2 | 1 | 5 | 18.4k | 3.9k | 1.1k | 13.4k/0 | 0.0026 | 0.0026 | 27/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 44.2 | 1 | 7 | 78.6k | 5.1k | 11.1k | 62.3k/0 | 0.0153 | 0.0153 | 216/9 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 12.2 | 1 | 4 | 21.8k | 4.0k | 2.7k | 15.1k/0 | 0.0045 | 0.0045 | 62/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 20.5 | 1 | 7 | 69.8k | 11.9k | 4.3k | 53.6k/0 | 0.0091 | 0.0091 | 118/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 24.7 | 1 | 6 | 41.2k | 3.7k | 5.3k | 32.3k/0 | 0.0077 | 0.0077 | 82/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 48.3 | 1 | 9 | 96.5k | 4.8k | 11.6k | 80.1k/0 | 0.0159 | 0.0159 | 134/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 9.7 | 1 | 5 | 20.5k | 3.7k | 1.6k | 15.2k/0 | 0.0031 | 0.0031 | 80/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 59.1 | 1 | 6 | 90.1k | 4.1k | 14.8k | 71.2k/0 | 0.0195 | 0.0195 | 330/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 31.3 | 1 | 7 | 85.5k | 8.9k | 6.6k | 70.0k/0 | 0.0110 | 0.0110 | 84/1 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 8.6 | 1 | 6 | 27.6k | 5.4k | 1.1k | 21.1k/0 | 0.0031 | 0.0031 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 5.8 | 1 | 4 | 13.1k | 2.9k | 716 | 9.5k/0 | 0.0018 | 0.0018 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 7.4 | 1 | 5 | 27.2k | 5.7k | 988 | 20.5k/0 | 0.0030 | 0.0030 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 7.4 | 1 | 5 | 16.8k | 2.8k | 1.3k | 12.8k/0 | 0.0024 | 0.0024 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.5 | 19 | 48.1k | 4.2k | 41.0k | 2.9k | 0.1550 | 0.1550 | 75/9 |
| deepseek-v4-flash | pi | 31/31 | 5.7 | 16 | 34.4k | 4.1k | 27.2k | 3.1k | 0.1596 | 0.1596 | 75/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
