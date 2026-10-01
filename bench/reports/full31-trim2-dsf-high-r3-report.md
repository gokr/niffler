# bench report — full31-trim2-r3

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 6.2 | 1 | 4 | 14.7k | 3.8k | 463 | 10.4k/0 | 0.0018 | 0.0018 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 19.7 | 1 | 6 | 35.8k | 4.7k | 3.7k | 27.4k/0 | 0.0060 | 0.0060 | 128/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 11.8 | 1 | 5 | 19.8k | 1.6k | 1.3k | 17.0k/0 | 0.0021 | 0.0021 | 27/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 7.2 | 1 | 5 | 20.4k | 2.1k | 631 | 17.7k/0 | 0.0015 | 0.0015 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 7.7 | 1 | 5 | 20.5k | 2.3k | 774 | 17.4k/0 | 0.0017 | 0.0017 | 19/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 30.7 | 1 | 6 | 67.7k | 6.9k | 6.8k | 54.0k/0 | 0.0106 | 0.0106 | 197/55 |
| deepseek-v4-flash | niffler | t07-validate | pass | 11.2 | 1 | 5 | 23.4k | 2.4k | 1.8k | 19.2k/0 | 0.0030 | 0.0030 | 21/8 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 21.2 | 1 | 7 | 44.4k | 2.9k | 3.7k | 37.8k/0 | 0.0055 | 0.0055 | 76/3 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 16.1 | 1 | 6 | 26.3k | 2.0k | 1.4k | 22.9k/0 | 0.0024 | 0.0024 | 13/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 25.7 | 1 | 8 | 48.6k | 4.0k | 2.5k | 42.1k/0 | 0.0045 | 0.0045 | 11/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 12.8 | 1 | 6 | 30.8k | 4.0k | 1.2k | 25.6k/0 | 0.0028 | 0.0028 | 6/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 8.8 | 1 | 5 | 20.6k | 2.6k | 596 | 17.4k/0 | 0.0016 | 0.0016 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 18.6 | 1 | 9 | 85.3k | 11.3k | 2.1k | 71.9k/0 | 0.0064 | 0.0064 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 12.5 | 1 | 8 | 39.2k | 3.1k | 1.5k | 34.6k/0 | 0.0030 | 0.0030 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 21 | 1 | 8 | 54.2k | 6.4k | 2.8k | 45.1k/0 | 0.0055 | 0.0055 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 13 | 1 | 7 | 29.4k | 2.5k | 827 | 26.1k/0 | 0.0019 | 0.0019 | 24/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 61 | 1 | 11 | 127.0k | 5.2k | 9.1k | 112.8k/0 | 0.0131 | 0.0131 | 148/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 14.9 | 1 | 5 | 29.7k | 3.7k | 2.4k | 23.7k/0 | 0.0041 | 0.0041 | 114/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 7.7 | 1 | 4 | 21.9k | 3.9k | 1.0k | 17.0k/0 | 0.0025 | 0.0025 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 36.3 | 1 | 6 | 54.2k | 4.5k | 8.3k | 41.5k/0 | 0.0116 | 0.0116 | 209/14 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 20.2 | 1 | 5 | 33.2k | 4.0k | 3.2k | 26.0k/0 | 0.0052 | 0.0052 | 68/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 37.3 | 1 | 5 | 48.7k | 4.3k | 8.1k | 36.2k/0 | 0.0113 | 0.0113 | 126/17 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 17.4 | 1 | 6 | 34.6k | 2.9k | 2.6k | 29.1k/0 | 0.0042 | 0.0042 | 73/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 28.2 | 1 | 6 | 49.8k | 3.9k | 6.0k | 39.8k/0 | 0.0087 | 0.0087 | 111/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 11.2 | 1 | 5 | 25.5k | 3.4k | 1.3k | 20.9k/0 | 0.0027 | 0.0027 | 81/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 47.3 | 1 | 9 | 88.4k | 4.0k | 10.2k | 74.2k/0 | 0.0139 | 0.0139 | 312/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 34.4 | 1 | 11 | 152.0k | 11.2k | 5.3k | 135.6k/0 | 0.0105 | 0.0105 | 103/3 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 68.4 | 1 | 11 | 126.0k | 12.7k | 6.1k | 107.1k/0 | 0.0118 | 0.0118 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 8 | 1 | 5 | 22.3k | 2.8k | 904 | 18.6k/0 | 0.0020 | 0.0020 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 21.1 | 1 | 11 | 113.7k | 10.9k | 2.3k | 100.5k/0 | 0.0067 | 0.0067 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 14.2 | 1 | 5 | 29.9k | 5.1k | 920 | 23.9k/0 | 0.0028 | 0.0028 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 4.8 | 1 | 4 | 10.3k | 2.4k | 526 | 7.4k/0 | 0.0014 | 0.0014 | 13/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 10.6 | 1 | 5 | 18.5k | 2.8k | 2.2k | 13.6k/0 | 0.0035 | 0.0035 | 82/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 9.7 | 1 | 5 | 14.5k | 2.6k | 844 | 11.0k/0 | 0.0019 | 0.0019 | 17/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 7.1 | 1 | 6 | 18.9k | 3.0k | 844 | 15.1k/0 | 0.0020 | 0.0020 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 6.5 | 1 | 5 | 15.1k | 2.9k | 856 | 11.3k/0 | 0.0020 | 0.0020 | 19/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 30.2 | 1 | 5 | 47.3k | 6.5k | 7.7k | 33.2k/0 | 0.0114 | 0.0114 | 116/18 |
| deepseek-v4-flash | pi | t07-validate | pass | 9.9 | 1 | 7 | 25.8k | 3.5k | 1.4k | 21.0k/0 | 0.0028 | 0.0028 | 13/6 |
| deepseek-v4-flash | pi | t08-logsum | pass | 17 | 1 | 8 | 39.9k | 4.0k | 3.1k | 32.8k/0 | 0.0051 | 0.0051 | 75/2 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 7.7 | 1 | 5 | 13.8k | 2.7k | 739 | 10.4k/0 | 0.0018 | 0.0018 | 7/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 16.8 | 1 | 6 | 25.5k | 3.6k | 1.9k | 20.0k/0 | 0.0035 | 0.0035 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 6.6 | 1 | 5 | 15.7k | 3.0k | 901 | 11.8k/0 | 0.0020 | 0.0020 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 5.9 | 1 | 4 | 12.5k | 2.6k | 884 | 9.0k/0 | 0.0019 | 0.0019 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 5 | 1 | 4 | 13.9k | 3.4k | 535 | 10.0k/0 | 0.0017 | 0.0017 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 6.9 | 1 | 5 | 16.3k | 3.0k | 895 | 12.4k/0 | 0.0020 | 0.0020 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 7.4 | 1 | 5 | 15.9k | 2.8k | 961 | 12.2k/0 | 0.0021 | 0.0021 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 6 | 1 | 4 | 10.7k | 2.5k | 430 | 7.8k/0 | 0.0013 | 0.0013 | 22/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 28.2 | 1 | 7 | 50.4k | 3.8k | 6.1k | 40.4k/0 | 0.0088 | 0.0088 | 133/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 11.6 | 1 | 5 | 22.6k | 4.1k | 2.0k | 16.5k/0 | 0.0038 | 0.0038 | 109/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 9 | 1 | 5 | 22.2k | 3.9k | 1.8k | 16.5k/0 | 0.0034 | 0.0034 | 25/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 49.7 | 1 | 5 | 52.5k | 4.8k | 11.5k | 36.2k/0 | 0.0155 | 0.0155 | 216/10 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 11.2 | 1 | 4 | 21.5k | 4.1k | 2.5k | 14.8k/0 | 0.0043 | 0.0043 | 65/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 20.7 | 1 | 4 | 28.9k | 4.8k | 4.4k | 19.7k/0 | 0.0069 | 0.0069 | 101/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 12.9 | 1 | 3 | 14.2k | 3.1k | 2.9k | 8.3k/0 | 0.0044 | 0.0044 | 73/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 40.1 | 1 | 6 | 53.1k | 4.4k | 9.0k | 39.7k/0 | 0.0124 | 0.0124 | 99/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 8.1 | 1 | 5 | 19.1k | 3.8k | 1.2k | 14.2k/0 | 0.0026 | 0.0026 | 79/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 46.8 | 1 | 8 | 86.1k | 4.3k | 10.4k | 71.4k/0 | 0.0142 | 0.0142 | 253/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 61.6 | 1 | 14 | 228.4k | 10.4k | 11.3k | 206.7k/0 | 0.0179 | 0.0179 | 87/1 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 7.9 | 1 | 5 | 22.7k | 5.7k | 1.2k | 15.7k/0 | 0.0033 | 0.0033 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 5.1 | 1 | 3 | 9.6k | 2.8k | 772 | 6.0k/0 | 0.0018 | 0.0018 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 8.4 | 1 | 6 | 37.2k | 6.7k | 1.1k | 29.4k/0 | 0.0034 | 0.0034 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 7.1 | 1 | 5 | 17.1k | 3.2k | 1.1k | 12.8k/0 | 0.0023 | 0.0023 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.6 | 22 | 49.6k | 4.7k | 41.7k | 3.2k | 0.1710 | 0.1710 | 79/9 |
| deepseek-v4-flash | pi | 31/31 | 5.4 | 16 | 32.3k | 3.9k | 25.4k | 3.0k | 0.1514 | 0.1514 | 70/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
