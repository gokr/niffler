# bench report — full30-dsf-high-0dd2874

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 5.8 | 1 | 4 | 15.7k | 3.8k | 445 | 11.5k/0 | 0.0017 | 0.0017 | 21/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 17.7 | 1 | 6 | 35.1k | 4.6k | 3.1k | 27.4k/0 | 0.0053 | 0.0053 | 81/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 11.9 | 1 | 5 | 21.6k | 2.3k | 733 | 18.6k/0 | 0.0017 | 0.0017 | 21/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11 | 1 | 7 | 33.3k | 2.8k | 1.0k | 29.4k/0 | 0.0023 | 0.0023 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 18.8 | 1 | 8 | 45.6k | 3.3k | 2.6k | 39.7k/0 | 0.0044 | 0.0044 | 19/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 79.5 | 1 | 14 | 269.7k | 9.8k | 15.2k | 244.7k/0 | 0.0226 | 0.0226 | 197/79 |
| deepseek-v4-flash | niffler | t07-validate | pass | 17.4 | 1 | 7 | 47.4k | 4.1k | 3.2k | 40.1k/0 | 0.0053 | 0.0053 | 22/9 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 26.9 | 1 | 8 | 59.9k | 3.8k | 4.0k | 52.1k/0 | 0.0063 | 0.0063 | 77/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 29.2 | 1 | 10 | 73.8k | 4.6k | 3.5k | 65.7k/0 | 0.0060 | 0.0060 | 14/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 24.3 | 1 | 7 | 43.6k | 3.2k | 2.6k | 37.9k/0 | 0.0043 | 0.0043 | 6/5 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 19.1 | 1 | 8 | 47.8k | 4.9k | 1.3k | 41.6k/0 | 0.0033 | 0.0033 | 4/7 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 10.9 | 1 | 6 | 27.6k | 2.7k | 830 | 24.1k/0 | 0.0019 | 0.0019 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 7.9 | 1 | 6 | 30.5k | 3.6k | 698 | 26.2k/0 | 0.0021 | 0.0021 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 12.5 | 1 | 7 | 36.6k | 3.1k | 1.6k | 32.0k/0 | 0.0030 | 0.0030 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 43.5 | 1 | 9 | 120.0k | 11.6k | 7.5k | 100.9k/0 | 0.0131 | 0.0131 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 10.4 | 1 | 5 | 21.5k | 2.0k | 717 | 18.8k/0 | 0.0016 | 0.0016 | 22/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 57.1 | 1 | 11 | 123.7k | 5.1k | 9.1k | 109.4k/0 | 0.0131 | 0.0131 | 141/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 20 | 1 | 7 | 55.7k | 4.3k | 3.4k | 48.0k/0 | 0.0057 | 0.0057 | 131/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 8.7 | 1 | 4 | 21.9k | 3.2k | 1.0k | 17.7k/0 | 0.0023 | 0.0023 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 69.8 | 1 | 13 | 210.9k | 10.5k | 14.2k | 186.2k/0 | 0.0212 | 0.0212 | 237/11 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 34.8 | 1 | 7 | 73.7k | 4.0k | 6.9k | 62.8k/0 | 0.0099 | 0.0099 | 65/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 25 | 1 | 6 | 51.2k | 4.7k | 4.9k | 41.6k/0 | 0.0076 | 0.0076 | 120/14 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 29.9 | 1 | 7 | 58.6k | 3.1k | 5.7k | 49.8k/0 | 0.0080 | 0.0080 | 73/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 58.8 | 1 | 13 | 169.8k | 5.9k | 12.6k | 151.3k/0 | 0.0179 | 0.0179 | 108/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 12.9 | 1 | 5 | 27.2k | 3.5k | 1.4k | 22.4k/0 | 0.0028 | 0.0028 | 89/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 30.6 | 1 | 7 | 64.9k | 6.2k | 6.5k | 52.2k/0 | 0.0100 | 0.0100 | 292/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 59.2 | 1 | 15 | 192.1k | 7.4k | 9.4k | 175.4k/0 | 0.0145 | 0.0145 | 87/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 25.4 | 1 | 10 | 86.2k | 7.0k | 3.6k | 75.6k/0 | 0.0069 | 0.0069 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 13.2 | 1 | 7 | 37.9k | 3.2k | 1.4k | 33.3k/0 | 0.0029 | 0.0029 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 18.7 | 1 | 8 | 73.1k | 7.7k | 2.6k | 62.8k/0 | 0.0057 | 0.0057 | 48/48 |
| deepseek-v4-flash | pi | t01-roman | pass | 4.1 | 1 | 4 | 10.6k | 2.7k | 557 | 7.3k/0 | 0.0015 | 0.0015 | 15/1 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 10 | 1 | 5 | 17.3k | 3.2k | 1.7k | 12.4k/0 | 0.0031 | 0.0031 | 79/1 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 11.2 | 1 | 4 | 12.7k | 2.5k | 988 | 9.2k/0 | 0.0020 | 0.0020 | 17/4 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 6.3 | 1 | 5 | 14.8k | 2.6k | 753 | 11.4k/0 | 0.0018 | 0.0018 | 3/3 |
| deepseek-v4-flash | pi | t05-todostore | pass | 7.8 | 1 | 5 | 16.6k | 3.0k | 1.1k | 12.4k/0 | 0.0023 | 0.0023 | 18/4 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 23.7 | 1 | 5 | 43.4k | 6.5k | 5.8k | 31.0k/0 | 0.0092 | 0.0092 | 190/57 |
| deepseek-v4-flash | pi | t07-validate | pass | 11.2 | 1 | 6 | 24.2k | 3.3k | 2.0k | 18.8k/0 | 0.0036 | 0.0036 | 16/8 |
| deepseek-v4-flash | pi | t08-logsum | pass | 17.6 | 1 | 9 | 46.8k | 4.0k | 3.1k | 39.7k/0 | 0.0052 | 0.0052 | 66/3 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 7 | 1 | 4 | 11.7k | 2.5k | 824 | 8.3k/0 | 0.0018 | 0.0018 | 6/1 |
| deepseek-v4-flash | pi | t10-iniparse | pass | 15.2 | 1 | 6 | 23.8k | 3.2k | 1.7k | 18.9k/0 | 0.0031 | 0.0031 | 6/5 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 9.7 | 1 | 5 | 18.0k | 3.2k | 1.5k | 13.3k/0 | 0.0029 | 0.0029 | 5/10 |
| deepseek-v4-flash | pi | t12-refactor | pass | 7 | 1 | 5 | 15.3k | 2.8k | 926 | 11.6k/0 | 0.0020 | 0.0020 | 2/4 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 6.7 | 1 | 5 | 20.2k | 4.1k | 793 | 15.4k/0 | 0.0023 | 0.0023 | 27/27 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 9.6 | 1 | 6 | 22.3k | 3.2k | 1.5k | 17.5k/0 | 0.0029 | 0.0029 | 18/0 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 4.9 | 1 | 3 | 8.7k | 2.4k | 727 | 5.6k/0 | 0.0016 | 0.0016 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 5.9 | 1 | 4 | 10.7k | 2.5k | 351 | 7.8k/0 | 0.0012 | 0.0012 | 15/0 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 37.2 | 1 | 10 | 80.0k | 4.0k | 7.2k | 68.9k/0 | 0.0103 | 0.0103 | 100/0 |
| deepseek-v4-flash | pi | t18-lruttl | pass | 9.1 | 1 | 5 | 21.5k | 4.2k | 1.6k | 15.7k/0 | 0.0032 | 0.0032 | 102/12 |
| deepseek-v4-flash | pi | t19-tokbucket | pass | 9 | 1 | 4 | 18.4k | 3.9k | 1.9k | 12.7k/0 | 0.0035 | 0.0035 | 27/11 |
| deepseek-v4-flash | pi | t20-jsonpatch | pass | 29.9 | 1 | 6 | 43.6k | 4.9k | 7.0k | 31.7k/0 | 0.0100 | 0.0100 | 203/9 |
| deepseek-v4-flash | pi | t21-wireproto | pass | 10.8 | 1 | 4 | 20.6k | 4.1k | 2.2k | 14.3k/0 | 0.0040 | 0.0040 | 61/8 |
| deepseek-v4-flash | pi | t22-cronnext | pass | 26.8 | 1 | 5 | 37.7k | 5.0k | 5.8k | 26.9k/0 | 0.0086 | 0.0086 | 110/16 |
| deepseek-v4-flash | pi | t23-mergesched | pass | 11.3 | 1 | 4 | 18.1k | 3.4k | 2.1k | 12.7k/0 | 0.0036 | 0.0036 | 71/4 |
| deepseek-v4-flash | pi | t24-editops | pass | 52.6 | 1 | 13 | 157.6k | 7.3k | 11.6k | 138.8k/0 | 0.0169 | 0.0169 | 128/11 |
| deepseek-v4-flash | pi | t25-shardmap | pass | 12.8 | 1 | 6 | 27.0k | 4.1k | 1.8k | 21.1k/0 | 0.0035 | 0.0035 | 89/16 |
| deepseek-v4-flash | pi | t26-logfilter | pass | 49.9 | 1 | 5 | 52.3k | 9.0k | 12.2k | 31.1k/0 | 0.0176 | 0.0176 | 289/4 |
| deepseek-v4-flash | pi | t27-tarpeek | pass | 37.4 | 1 | 8 | 94.8k | 9.1k | 7.5k | 78.2k/0 | 0.0122 | 0.0122 | 80/1 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 9.1 | 1 | 6 | 26.7k | 5.9k | 1.1k | 19.7k/0 | 0.0032 | 0.0032 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 4.8 | 1 | 4 | 12.4k | 2.9k | 638 | 8.8k/0 | 0.0017 | 0.0017 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 9.6 | 1 | 6 | 34.9k | 6.1k | 1.3k | 27.5k/0 | 0.0035 | 0.0035 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 30/30 | 7.9 | 27 | 72.6k | 4.9k | 63.3k | 4.4k | 0.2133 | 0.2133 | 80/10 |
| deepseek-v4-flash | pi | 30/30 | 5.6 | 16 | 32.1k | 4.2k | 25.0k | 2.9k | 0.1479 | 0.1479 | 75/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
