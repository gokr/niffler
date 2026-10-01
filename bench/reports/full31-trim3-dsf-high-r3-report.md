# bench report — full31-trim3-r3

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 6.5 | 1 | 4 | 11.6k | 2.7k | 622 | 8.3k/0 | 0.0016 | 0.0016 | 34/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 22.2 | 1 | 7 | 43.0k | 4.1k | 3.6k | 35.3k/0 | 0.0057 | 0.0057 | 90/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 14.6 | 1 | 5 | 22.0k | 2.6k | 1.0k | 18.3k/0 | 0.0022 | 0.0022 | 21/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 10.1 | 1 | 6 | 25.3k | 2.6k | 645 | 22.0k/0 | 0.0017 | 0.0017 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 10.7 | 1 | 6 | 24.7k | 2.5k | 782 | 21.5k/0 | 0.0018 | 0.0018 | 18/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 58.3 | 1 | 11 | 174.5k | 7.7k | 11.9k | 154.9k/0 | 0.0175 | 0.0175 | 173/50 |
| deepseek-v4-flash | niffler | t07-validate | pass | 22.5 | 1 | 9 | 61.6k | 4.2k | 3.6k | 53.8k/0 | 0.0060 | 0.0060 | 28/13 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 29.8 | 1 | 10 | 68.8k | 4.0k | 3.2k | 61.6k/0 | 0.0054 | 0.0054 | 82/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 16.5 | 1 | 6 | 29.0k | 3.5k | 905 | 24.6k/0 | 0.0023 | 0.0023 | 6/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 31.5 | 1 | 6 | 32.4k | 3.3k | 2.4k | 26.8k/0 | 0.0040 | 0.0040 | 8/7 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 13.3 | 1 | 6 | 26.3k | 3.2k | 861 | 22.3k/0 | 0.0021 | 0.0021 | 7/5 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 15.4 | 1 | 5 | 20.6k | 2.3k | 743 | 17.5k/0 | 0.0017 | 0.0017 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 123.1 | 1 | 7 | 76.1k | 13.4k | 3.0k | 59.6k/0 | 0.0080 | 0.0080 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 29.4 | 1 | 8 | 66.8k | 5.4k | 4.5k | 56.8k/0 | 0.0074 | 0.0074 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 100 | 1 | 9 | 81.5k | 8.0k | 4.1k | 69.5k/0 | 0.0077 | 0.0077 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 73.2 | 1 | 7 | 37.4k | 4.2k | 1.0k | 32.1k/0 | 0.0027 | 0.0027 | 33/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 28.8 | 1 | 9 | 61.7k | 3.0k | 4.0k | 54.7k/0 | 0.0060 | 0.0060 | 171/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 19.3 | 1 | 6 | 37.5k | 3.8k | 2.4k | 31.2k/0 | 0.0042 | 0.0042 | 108/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 11.7 | 1 | 5 | 22.9k | 2.8k | 923 | 19.2k/0 | 0.0021 | 0.0021 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 53.5 | 1 | 7 | 88.8k | 5.1k | 10.8k | 73.0k/0 | 0.0149 | 0.0149 | 197/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 15.8 | 1 | 4 | 25.3k | 3.3k | 2.5k | 19.6k/0 | 0.0040 | 0.0040 | 67/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 30.9 | 1 | 5 | 42.2k | 4.3k | 5.9k | 31.9k/0 | 0.0086 | 0.0086 | 117/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 17.2 | 1 | 6 | 33.0k | 2.9k | 2.1k | 27.9k/0 | 0.0036 | 0.0036 | 75/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 39 | 1 | 7 | 62.0k | 4.0k | 7.8k | 50.2k/0 | 0.0109 | 0.0109 | 160/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 18.9 | 1 | 6 | 34.2k | 3.6k | 1.8k | 28.7k/0 | 0.0035 | 0.0035 | 86/17 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 35972.3 | 1 | 10 | 131.7k | 6.3k | 11.1k | 114.3k/0 | 0.0159 | 0.0159 | 252/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 35976.7 | 1 | 17 | 162.8k | 6.3k | 8.7k | 147.8k/0 | 0.0132 | 0.0132 | 95/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 13.9 | 1 | 7 | 38.2k | 4.4k | 1.2k | 32.6k/0 | 0.0029 | 0.0029 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 8.9 | 1 | 4 | 18.2k | 2.2k | 1.0k | 15.0k/0 | 0.0020 | 0.0020 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 67.2 | 1 | 7 | 73.2k | 13.8k | 4.0k | 55.4k/0 | 0.0092 | 0.0092 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 14.8 | 1 | 7 | 34.0k | 3.6k | 746 | 29.7k/0 | 0.0021 | 0.0021 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 5.2 | 1 | 4 | 10.0k | 2.4k | 410 | 7.2k/0 | 0.0013 | 0.0013 | 15/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 12.3 | 1 | 5 | 18.4k | 2.8k | 2.2k | 13.4k/0 | 0.0035 | 0.0035 | 95/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 11.5 | 1 | 5 | 14.8k | 2.5k | 978 | 11.3k/0 | 0.0020 | 0.0020 | 14/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 8.5 | 1 | 6 | 17.8k | 2.8k | 887 | 14.1k/0 | 0.0020 | 0.0020 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 7.9 | 1 | 5 | 16.1k | 2.9k | 1.0k | 12.2k/0 | 0.0022 | 0.0022 | 16/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 44.8 | 1 | 6 | 74.9k | 6.8k | 10.7k | 57.5k/0 | 0.0152 | 0.0152 | 144/47 |
| deepseek-v4-flash | pi | t07-validate | pass | 10.7 | 1 | 6 | 24.4k | 4.3k | 1.6k | 18.6k/0 | 0.0033 | 0.0033 | 17/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 14.5 | 1 | 6 | 27.1k | 3.5k | 2.5k | 21.0k/0 | 0.0042 | 0.0042 | 82/3 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 10.1 | 1 | 5 | 14.9k | 2.7k | 836 | 11.4k/0 | 0.0019 | 0.0019 | 7/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 21.4 | 1 | 6 | 24.1k | 3.3k | 2.0k | 18.8k/0 | 0.0034 | 0.0034 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 9.2 | 1 | 5 | 17.3k | 3.0k | 1.4k | 12.9k/0 | 0.0026 | 0.0026 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 7 | 1 | 5 | 14.6k | 2.7k | 770 | 11.1k/0 | 0.0018 | 0.0018 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 7.6 | 1 | 5 | 17.4k | 3.7k | 560 | 13.2k/0 | 0.0019 | 0.0019 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 17 | 1 | 7 | 31.3k | 3.4k | 2.9k | 25.0k/0 | 0.0047 | 0.0047 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 9.4 | 1 | 6 | 17.1k | 2.8k | 859 | 13.4k/0 | 0.0020 | 0.0020 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 9 | 1 | 5 | 13.8k | 2.4k | 572 | 10.8k/0 | 0.0015 | 0.0015 | 21/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 26.1 | 1 | 10 | 57.5k | 4.2k | 4.5k | 48.8k/0 | 0.0070 | 0.0070 | 109/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 10.6 | 1 | 4 | 19.0k | 4.0k | 1.8k | 13.2k/0 | 0.0035 | 0.0035 | 117/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 7.9 | 1 | 4 | 16.1k | 3.7k | 1.3k | 11.1k/0 | 0.0027 | 0.0027 | 26/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 73.4 | 1 | 7 | 103.8k | 5.9k | 17.5k | 80.4k/0 | 0.0232 | 0.0232 | 241/14 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 16.9 | 1 | 4 | 24.8k | 3.9k | 3.6k | 17.3k/0 | 0.0056 | 0.0056 | 68/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 31.5 | 1 | 5 | 38.3k | 4.8k | 6.7k | 26.8k/0 | 0.0097 | 0.0097 | 106/17 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 17.8 | 1 | 4 | 22.4k | 3.4k | 3.5k | 15.5k/0 | 0.0053 | 0.0053 | 81/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 24.2 | 1 | 5 | 32.2k | 4.0k | 5.1k | 23.0k/0 | 0.0075 | 0.0075 | 110/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 13.8 | 1 | 5 | 25.6k | 3.9k | 2.5k | 19.2k/0 | 0.0043 | 0.0043 | 82/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 46.2 | 1 | 6 | 52.0k | 7.3k | 10.6k | 34.0k/0 | 0.0151 | 0.0151 | 314/4 |
| deepseek-v4-flash | pi | t27-tarpeek | timeout | 36009.1 | 1 | 11 | 128.4k | 8.2k | 7.4k | 112.8k/0 | 0.0120 | 0.0120 | 86/2 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 8.2 | 1 | 5 | 19.4k | 4.0k | 942 | 14.5k/0 | 0.0024 | 0.0024 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 6.8 | 1 | 5 | 16.4k | 2.9k | 816 | 12.7k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 8.3 | 1 | 5 | 30.2k | 6.6k | 1.2k | 22.4k/0 | 0.0035 | 0.0035 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 7.7 | 1 | 5 | 17.3k | 2.9k | 1.3k | 13.1k/0 | 0.0025 | 0.0025 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 7.1 | 2351 | 53.8k | 4.6k | 45.7k | 3.5k | 0.1810 | 0.1810 | 78/9 |
| deepseek-v4-flash | pi | 30/31 | 5.5 | 1178 | 30.9k | 3.9k | 23.8k | 3.2k | 0.1597 | 0.1597 | 75/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
