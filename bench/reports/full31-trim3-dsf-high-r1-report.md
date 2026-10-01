# bench report — full31-trim3-r1

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 4.8 | 1 | 3 | 8.2k | 2.7k | 471 | 5.0k/0 | 0.0014 | 0.0014 | 32/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 18.8 | 1 | 6 | 32.5k | 3.5k | 2.9k | 26.0k/0 | 0.0048 | 0.0048 | 109/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 15.6 | 1 | 5 | 22.4k | 3.7k | 1.4k | 17.3k/0 | 0.0029 | 0.0029 | 20/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 9.5 | 1 | 6 | 25.7k | 2.7k | 778 | 22.3k/0 | 0.0019 | 0.0019 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9 | 1 | 6 | 24.7k | 2.5k | 774 | 21.4k/0 | 0.0018 | 0.0018 | 16/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 36.4 | 1 | 6 | 70.1k | 7.1k | 7.3k | 55.7k/0 | 0.0113 | 0.0113 | 183/59 |
| deepseek-v4-flash | niffler | t07-validate | pass | 12.9 | 1 | 5 | 22.9k | 2.1k | 1.7k | 19.1k/0 | 0.0028 | 0.0028 | 18/12 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 34.6 | 1 | 9 | 68.5k | 3.5k | 4.7k | 60.3k/0 | 0.0071 | 0.0071 | 102/6 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 21.3 | 1 | 8 | 46.0k | 4.5k | 1.4k | 40.1k/0 | 0.0033 | 0.0033 | 6/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 33.4 | 1 | 8 | 46.0k | 3.9k | 2.3k | 39.8k/0 | 0.0041 | 0.0041 | 7/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 14.4 | 1 | 6 | 25.0k | 2.7k | 665 | 21.6k/0 | 0.0017 | 0.0017 | 6/11 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 18.5 | 1 | 6 | 27.9k | 3.1k | 1.0k | 23.7k/0 | 0.0023 | 0.0023 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 73.9 | 1 | 6 | 55.2k | 11.5k | 2.7k | 41.0k/0 | 0.0069 | 0.0069 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 20.9 | 1 | 6 | 29.5k | 2.8k | 1.6k | 25.1k/0 | 0.0030 | 0.0030 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 25 | 1 | 8 | 54.0k | 6.7k | 2.3k | 45.1k/0 | 0.0050 | 0.0050 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 22.6 | 1 | 8 | 41.9k | 4.0k | 1.2k | 36.7k/0 | 0.0028 | 0.0028 | 31/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 51.4 | 1 | 9 | 80.1k | 4.5k | 6.5k | 69.1k/0 | 0.0096 | 0.0096 | 148/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 22.5 | 1 | 6 | 37.4k | 3.8k | 2.4k | 31.2k/0 | 0.0042 | 0.0042 | 137/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 10.6 | 1 | 4 | 21.1k | 3.6k | 989 | 16.5k/0 | 0.0024 | 0.0024 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 38 | 1 | 7 | 61.2k | 4.8k | 6.9k | 49.5k/0 | 0.0100 | 0.0100 | 215/10 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 25.2 | 1 | 7 | 51.9k | 4.3k | 3.9k | 43.6k/0 | 0.0063 | 0.0063 | 62/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 34 | 1 | 4 | 41.1k | 4.3k | 6.7k | 30.1k/0 | 0.0095 | 0.0095 | 113/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 14 | 1 | 4 | 22.4k | 2.5k | 2.2k | 17.7k/0 | 0.0035 | 0.0035 | 65/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 53.3 | 1 | 8 | 105.0k | 4.2k | 11.7k | 89.1k/0 | 0.0158 | 0.0158 | 143/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 13 | 1 | 4 | 20.7k | 2.8k | 1.3k | 16.6k/0 | 0.0025 | 0.0025 | 80/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 73.6 | 1 | 13 | 210.5k | 16.1k | 12.9k | 181.5k/0 | 0.0214 | 0.0214 | 262/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 70.9 | 1 | 19 | 201.7k | 6.9k | 9.1k | 185.7k/0 | 0.0141 | 0.0141 | 89/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 35991.9 | 1 | 9 | 86.2k | 9.8k | 3.8k | 72.6k/0 | 0.0079 | 0.0079 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 10.1 | 1 | 6 | 26.4k | 2.8k | 844 | 22.8k/0 | 0.0020 | 0.0020 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 35992.6 | 1 | 5 | 52.2k | 11.4k | 3.7k | 37.1k/0 | 0.0081 | 0.0081 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 35926.9 | 1 | 6 | 38.9k | 6.4k | 749 | 31.7k/0 | 0.0030 | 0.0030 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 5.9 | 1 | 4 | 10.4k | 2.4k | 557 | 7.4k/0 | 0.0014 | 0.0014 | 13/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 16.4 | 1 | 7 | 30.0k | 3.3k | 2.8k | 23.9k/0 | 0.0045 | 0.0045 | 74/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 10.1 | 1 | 4 | 11.9k | 2.5k | 887 | 8.6k/0 | 0.0019 | 0.0019 | 14/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 6.2 | 1 | 4 | 11.2k | 2.4k | 713 | 8.1k/0 | 0.0016 | 0.0016 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 8.4 | 1 | 5 | 16.0k | 3.1k | 1.0k | 11.9k/0 | 0.0022 | 0.0022 | 16/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 29.9 | 1 | 6 | 60.7k | 6.9k | 7.1k | 46.7k/0 | 0.0108 | 0.0108 | 174/55 |
| deepseek-v4-flash | pi | t07-validate | pass | 10.1 | 1 | 5 | 18.4k | 3.2k | 1.8k | 13.4k/0 | 0.0032 | 0.0032 | 13/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 13.5 | 1 | 6 | 25.1k | 3.3k | 2.2k | 19.6k/0 | 0.0037 | 0.0037 | 66/3 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 7.2 | 1 | 4 | 11.3k | 2.5k | 724 | 8.1k/0 | 0.0017 | 0.0017 | 5/1 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 26.8 | 1 | 7 | 32.0k | 4.2k | 2.1k | 25.7k/0 | 0.0039 | 0.0039 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 10.8 | 1 | 5 | 17.3k | 3.0k | 1.4k | 12.9k/0 | 0.0026 | 0.0026 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 10.1 | 1 | 5 | 16.0k | 2.9k | 932 | 12.2k/0 | 0.0021 | 0.0021 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 6.4 | 1 | 4 | 13.2k | 3.2k | 565 | 9.5k/0 | 0.0017 | 0.0017 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 9.6 | 1 | 6 | 21.6k | 3.3k | 1.1k | 17.2k/0 | 0.0024 | 0.0024 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 5.3 | 1 | 3 | 7.8k | 2.2k | 444 | 5.1k/0 | 0.0012 | 0.0012 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 8.3 | 1 | 4 | 10.6k | 2.4k | 367 | 7.8k/0 | 0.0012 | 0.0012 | 18/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 37.7 | 1 | 12 | 81.5k | 4.6k | 5.9k | 71.0k/0 | 0.0089 | 0.0089 | 120/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 11.9 | 1 | 5 | 22.3k | 4.0k | 1.9k | 16.4k/0 | 0.0036 | 0.0036 | 117/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 11.2 | 1 | 6 | 25.5k | 3.9k | 1.8k | 19.8k/0 | 0.0035 | 0.0035 | 26/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 70.3 | 1 | 7 | 108.0k | 5.3k | 16.6k | 86.0k/0 | 0.0221 | 0.0221 | 251/9 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 19.3 | 1 | 5 | 29.0k | 4.1k | 4.0k | 20.9k/0 | 0.0062 | 0.0062 | 65/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 23.4 | 1 | 5 | 33.0k | 4.9k | 5.0k | 23.2k/0 | 0.0076 | 0.0076 | 103/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 14.6 | 1 | 4 | 20.5k | 3.4k | 2.9k | 14.2k/0 | 0.0046 | 0.0046 | 79/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 62.3 | 1 | 9 | 120.1k | 5.2k | 13.1k | 101.8k/0 | 0.0179 | 0.0179 | 136/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 12.8 | 1 | 6 | 25.6k | 4.0k | 1.6k | 20.0k/0 | 0.0033 | 0.0033 | 80/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 48.2 | 1 | 3 | 33.5k | 10.9k | 12.2k | 10.4k/0 | 0.0180 | 0.0180 | 301/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 38.7 | 1 | 8 | 73.1k | 9.3k | 7.2k | 56.6k/0 | 0.0118 | 0.0118 | 88/2 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 11.2 | 1 | 5 | 19.5k | 3.6k | 1.4k | 14.5k/0 | 0.0028 | 0.0028 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 5.4 | 1 | 3 | 8.9k | 2.6k | 666 | 5.6k/0 | 0.0016 | 0.0016 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 7.7 | 1 | 4 | 21.9k | 6.3k | 922 | 14.7k/0 | 0.0031 | 0.0031 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 8.4 | 1 | 5 | 18.3k | 3.1k | 1.3k | 13.8k/0 | 0.0026 | 0.0026 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.9 | 3506 | 53.5k | 5.0k | 45.0k | 3.5k | 0.1834 | 0.1834 | 78/10 |
| deepseek-v4-flash | pi | 31/31 | 5.4 | 18 | 30.8k | 4.1k | 23.4k | 3.3k | 0.1637 | 0.1637 | 75/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
