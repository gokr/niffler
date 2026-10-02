# bench report — full31-trim3-r2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 11 | 1 | 7 | 27.6k | 4.4k | 930 | 22.3k/0 | 0.0026 | 0.0026 | 34/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 17.5 | 1 | 5 | 26.8k | 3.5k | 3.2k | 20.1k/0 | 0.0051 | 0.0051 | 110/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 14.6 | 1 | 6 | 24.6k | 2.3k | 881 | 21.4k/0 | 0.0019 | 0.0019 | 20/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 9.8 | 1 | 6 | 24.4k | 2.5k | 570 | 21.4k/0 | 0.0015 | 0.0015 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 13.2 | 1 | 5 | 21.9k | 2.3k | 1.1k | 18.4k/0 | 0.0022 | 0.0022 | 16/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 34.2 | 1 | 6 | 69.9k | 7.0k | 7.0k | 55.8k/0 | 0.0109 | 0.0109 | 196/70 |
| deepseek-v4-flash | niffler | t07-validate | pass | 14.1 | 1 | 6 | 30.9k | 3.0k | 2.0k | 26.0k/0 | 0.0034 | 0.0034 | 18/10 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 29.1 | 1 | 7 | 48.7k | 3.4k | 4.0k | 41.3k/0 | 0.0061 | 0.0061 | 85/6 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 14.5 | 1 | 5 | 20.1k | 1.9k | 845 | 17.3k/0 | 0.0017 | 0.0017 | 10/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 21.8 | 1 | 6 | 28.7k | 2.5k | 1.6k | 24.6k/0 | 0.0029 | 0.0029 | 12/7 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 17.6 | 1 | 6 | 31.6k | 3.8k | 1.3k | 26.5k/0 | 0.0028 | 0.0028 | 6/11 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 13.3 | 1 | 5 | 20.5k | 2.5k | 535 | 17.4k/0 | 0.0015 | 0.0015 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 89 | 1 | 7 | 77.7k | 14.6k | 3.5k | 59.5k/0 | 0.0089 | 0.0089 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 35.2 | 1 | 7 | 36.2k | 3.1k | 1.7k | 31.5k/0 | 0.0031 | 0.0031 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 55.8 | 1 | 10 | 85.6k | 7.4k | 5.2k | 73.0k/0 | 0.0089 | 0.0089 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 8.5 | 1 | 4 | 14.7k | 1.7k | 406 | 12.5k/0 | 0.0011 | 0.0011 | 21/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 29.4 | 1 | 8 | 56.9k | 2.7k | 4.5k | 49.7k/0 | 0.0065 | 0.0065 | 141/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 18.2 | 1 | 6 | 35.5k | 3.8k | 1.9k | 29.8k/0 | 0.0036 | 0.0036 | 115/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 13.2 | 1 | 5 | 26.1k | 3.8k | 1.1k | 21.1k/0 | 0.0026 | 0.0026 | 26/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 27.7 | 1 | 6 | 44.2k | 4.6k | 5.4k | 34.2k/0 | 0.0080 | 0.0080 | 217/11 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 17.9 | 1 | 5 | 31.1k | 3.5k | 2.9k | 24.7k/0 | 0.0047 | 0.0047 | 62/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 31.5 | 1 | 5 | 42.1k | 4.3k | 5.9k | 31.9k/0 | 0.0085 | 0.0085 | 115/12 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 22.8 | 1 | 7 | 47.1k | 4.3k | 2.7k | 40.1k/0 | 0.0048 | 0.0048 | 81/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 51.5 | 1 | 9 | 100.7k | 5.3k | 10.0k | 85.4k/0 | 0.0141 | 0.0141 | 157/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 13.4 | 1 | 5 | 25.4k | 3.3k | 1.2k | 20.9k/0 | 0.0026 | 0.0026 | 80/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 51.7 | 1 | 7 | 85.8k | 3.8k | 11.4k | 70.7k/0 | 0.0152 | 0.0152 | 340/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 44.5 | 1 | 12 | 97.5k | 4.3k | 7.1k | 86.1k/0 | 0.0103 | 0.0103 | 79/4 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 18.8 | 1 | 6 | 38.7k | 5.0k | 3.1k | 30.6k/0 | 0.0054 | 0.0054 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 10 | 1 | 5 | 25.7k | 3.6k | 995 | 21.1k/0 | 0.0024 | 0.0024 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 15.1 | 1 | 7 | 60.6k | 8.8k | 1.3k | 50.4k/0 | 0.0046 | 0.0046 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 14 | 1 | 5 | 27.6k | 4.2k | 879 | 22.5k/0 | 0.0024 | 0.0024 | 6/6 |
| deepseek-v4-flash | pi | t01-roman | pass | 5.6 | 1 | 4 | 10.2k | 2.3k | 463 | 7.4k/0 | 0.0013 | 0.0013 | 15/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 22.4 | 1 | 6 | 32.6k | 3.1k | 4.5k | 25.0k/0 | 0.0065 | 0.0065 | 90/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 11.5 | 1 | 5 | 15.2k | 2.4k | 1.0k | 11.8k/0 | 0.0020 | 0.0020 | 17/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 6.3 | 1 | 5 | 14.2k | 2.5k | 698 | 11.0k/0 | 0.0016 | 0.0016 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 7.5 | 1 | 5 | 15.3k | 3.0k | 809 | 11.5k/0 | 0.0019 | 0.0019 | 20/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 39.6 | 1 | 8 | 94.6k | 7.2k | 8.8k | 78.6k/0 | 0.0132 | 0.0132 | 161/42 |
| deepseek-v4-flash | pi | t07-validate | pass | 11.5 | 1 | 5 | 18.3k | 3.1k | 1.8k | 13.4k/0 | 0.0031 | 0.0031 | 13/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 14.4 | 1 | 6 | 25.9k | 3.2k | 2.3k | 20.4k/0 | 0.0039 | 0.0039 | 76/4 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 8.5 | 1 | 4 | 11.2k | 2.4k | 675 | 8.1k/0 | 0.0016 | 0.0016 | 7/4 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 26.8 | 1 | 6 | 24.4k | 3.9k | 1.3k | 19.2k/0 | 0.0028 | 0.0028 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 8.1 | 1 | 5 | 15.7k | 2.8k | 923 | 11.9k/0 | 0.0020 | 0.0020 | 7/6 |
| deepseek-v4-flash | pi | t12-refactor | pass | 9 | 1 | 5 | 15.7k | 2.7k | 1.1k | 11.9k/0 | 0.0022 | 0.0022 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 7.7 | 1 | 5 | 19.5k | 4.2k | 665 | 14.7k/0 | 0.0021 | 0.0021 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 8.2 | 1 | 5 | 16.5k | 3.1k | 891 | 12.5k/0 | 0.0021 | 0.0021 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 7.9 | 1 | 4 | 11.6k | 2.4k | 911 | 8.3k/0 | 0.0019 | 0.0019 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 17.9 | 1 | 8 | 31.7k | 4.4k | 1.2k | 26.1k/0 | 0.0029 | 0.0029 | 26/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 38.5 | 1 | 11 | 86.6k | 4.8k | 7.1k | 74.8k/0 | 0.0104 | 0.0104 | 133/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 12.6 | 1 | 4 | 20.5k | 4.0k | 2.2k | 14.3k/0 | 0.0039 | 0.0039 | 111/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 9.8 | 1 | 4 | 17.6k | 3.8k | 1.7k | 12.0k/0 | 0.0033 | 0.0033 | 27/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 36.1 | 1 | 5 | 42.8k | 4.8k | 8.3k | 29.7k/0 | 0.0116 | 0.0116 | 208/9 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 13.9 | 1 | 4 | 22.2k | 4.1k | 2.9k | 15.2k/0 | 0.0048 | 0.0048 | 67/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 27.5 | 1 | 5 | 43.4k | 4.8k | 6.2k | 32.4k/0 | 0.0091 | 0.0091 | 103/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 14.9 | 1 | 5 | 21.9k | 3.4k | 2.6k | 16.0k/0 | 0.0042 | 0.0042 | 70/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 36 | 1 | 11 | 94.3k | 6.3k | 6.6k | 81.4k/0 | 0.0103 | 0.0103 | 107/6 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 9.7 | 1 | 4 | 16.8k | 3.7k | 1.3k | 11.8k/0 | 0.0028 | 0.0028 | 83/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 34.8 | 1 | 5 | 38.1k | 7.3k | 7.6k | 23.2k/0 | 0.0115 | 0.0115 | 284/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 41.8 | 1 | 11 | 142.8k | 11.3k | 7.4k | 124.2k/0 | 0.0130 | 0.0130 | 86/4 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 11.2 | 1 | 7 | 26.9k | 3.7k | 1.3k | 21.9k/0 | 0.0028 | 0.0028 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 6.9 | 1 | 4 | 12.7k | 3.0k | 780 | 9.0k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 9.9 | 1 | 6 | 37.6k | 7.0k | 1.2k | 29.4k/0 | 0.0037 | 0.0037 | 48/48 |
| deepseek-v4-flash | pi | t31-tinyrename | pass | 8.2 | 1 | 5 | 17.1k | 3.2k | 1.1k | 12.8k/0 | 0.0023 | 0.0023 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.3 | 25 | 43.1k | 4.2k | 35.7k | 3.1k | 0.1604 | 0.1604 | 81/10 |
| deepseek-v4-flash | pi | 31/31 | 5.7 | 17 | 32.7k | 4.1k | 25.8k | 2.8k | 0.1465 | 0.1465 | 73/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
