# bench report — full31-syn-ds41-claudecode-2318

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| syn-deepseek-v41 | claudecode | t01-roman | pass | 23.8 | 1 | 6 | 48.3k | 0 | 332 | 19.3k/28.6k | 0.0264 | 0.0091 | 13/1 |
| syn-deepseek-v41 | claudecode | t02-jsonrepair | pass | 29.1 | 1 | 7 | 49.3k | 0 | 721 | 29.5k/19.1k | 0.0209 | 0.0068 | 66/1 |
| syn-deepseek-v41 | claudecode | t03-ringbuffer | pass | 19.7 | 1 | 10 | 48.8k | 0 | 428 | 38.6k/9.7k | 0.0145 | 0.0037 | 21/4 |
| syn-deepseek-v41 | claudecode | t04-csvbugfix | pass | 13.9 | 1 | 11 | 49.5k | 0 | 431 | 39.2k/9.8k | 0.0147 | 0.0037 | 3/3 |
| syn-deepseek-v41 | claudecode | t05-todostore | pass | 17.1 | 1 | 8 | 49.2k | 0 | 428 | 30.0k/18.8k | 0.0204 | 0.0063 | 19/4 |
| syn-deepseek-v41 | claudecode | t06-stackvm | pass | 72.9 | 1 | 19 | 104.1k | 0 | 3.0k | 79.0k/22.1k | 0.0339 | 0.0107 | 196/48 |
| syn-deepseek-v41 | claudecode | t07-validate | pass | 23 | 1 | 12 | 52.6k | 0 | 979 | 32.0k/19.6k | 0.0220 | 0.0073 | 20/11 |
| syn-deepseek-v41 | claudecode | t08-logsum | pass | 41.4 | 1 | 21 | 108.6k | 0 | 1.4k | 87.8k/19.4k | 0.0313 | 0.0080 | 91/5 |
| syn-deepseek-v41 | claudecode | t09-poolrace | pass | 17.7 | 1 | 14 | 51.0k | 0 | 596 | 40.3k/10.2k | 0.0153 | 0.0040 | 8/1 |
| syn-deepseek-v41 | claudecode | t10-iniparse | pass | 32.6 | 1 | 16 | 72.7k | 0 | 689 | 52.6k/19.4k | 0.0248 | 0.0070 | 11/7 |
| syn-deepseek-v41 | claudecode | t11-asyncbugs | pass | 21.7 | 1 | 15 | 51.4k | 0 | 643 | 31.3k/19.5k | 0.0214 | 0.0068 | 7/6 |
| syn-deepseek-v41 | claudecode | t12-refactor | pass | 9.7 | 1 | 5 | 38.9k | 0 | 281 | 29.0k/9.6k | 0.0127 | 0.0034 | 2/4 |
| syn-deepseek-v41 | claudecode | t13-batchrename | pass | 11.7 | 1 | 4 | 28.5k | 0 | 182 | 9.8k/18.6k | 0.0166 | 0.0058 | 27/27 |
| syn-deepseek-v41 | claudecode | t14-todosweep | pass | 41.8 | 1 | 25 | 74.2k | 0 | 1.1k | 62.8k/10.3k | 0.0196 | 0.0047 | 18/0 |
| syn-deepseek-v41 | claudecode | t15-pollstats | pass | 22.8 | 1 | 12 | 49.2k | 0 | 519 | 30.1k/18.6k | 0.0203 | 0.0064 | 1/0 |
| syn-deepseek-v41 | claudecode | t16-apisum | pass | 18.4 | 1 | 12 | 49.2k | 0 | 430 | 39.1k/9.7k | 0.0145 | 0.0037 | 22/0 |
| syn-deepseek-v41 | claudecode | t17-doccheck | pass | 54.4 | 1 | 24 | 87.6k | 0 | 1.9k | 66.0k/19.7k | 0.0286 | 0.0086 | 155/0 |
| syn-deepseek-v41 | claudecode | t18-lruttl | pass | 36.3 | 1 | 16 | 66.9k | 0 | 1.4k | 45.6k/19.9k | 0.0249 | 0.0079 | 105/12 |
| syn-deepseek-v41 | claudecode | t19-tokbucket | pass | 18.9 | 1 | 11 | 51.2k | 0 | 580 | 31.3k/19.3k | 0.0212 | 0.0067 | 24/11 |
| syn-deepseek-v41 | claudecode | t20-jsonpatch | pass | 52.9 | 1 | 12 | 58.1k | 0 | 2.9k | 34.9k/20.3k | 0.0253 | 0.0098 | 222/13 |
| syn-deepseek-v41 | claudecode | t21-wireproto | pass | 30 | 1 | 10 | 53.4k | 0 | 1.1k | 33.0k/19.2k | 0.0220 | 0.0073 | 69/8 |
| syn-deepseek-v41 | claudecode | t22-cronnext | pass | 57.6 | 1 | 14 | 58.0k | 0 | 2.5k | 34.8k/20.7k | 0.0251 | 0.0094 | 129/16 |
| syn-deepseek-v41 | claudecode | t23-mergesched | pass | 25.3 | 1 | 13 | 51.1k | 0 | 903 | 40.0k/10.2k | 0.0156 | 0.0044 | 76/4 |
| syn-deepseek-v41 | claudecode | t24-editops | pass | 58.6 | 1 | 19 | 58.9k | 0 | 3.1k | 35.9k/19.8k | 0.0253 | 0.0099 | 118/11 |
| syn-deepseek-v41 | claudecode | t25-shardmap | pass | 25.6 | 1 | 12 | 52.2k | 0 | 887 | 32.2k/19.2k | 0.0215 | 0.0070 | 91/16 |
| syn-deepseek-v41 | claudecode | t26-logfilter | pass | 78.8 | 1 | 16 | 73.5k | 0 | 3.6k | 50.7k/19.2k | 0.0278 | 0.0104 | 241/4 |
| syn-deepseek-v41 | claudecode | t27-tarpeek | pass | 87 | 1 | 38 | 187.2k | 0 | 3.6k | 160.8k/22.9k | 0.0483 | 0.0121 | 103/2 |
| syn-deepseek-v41 | claudecode | t28-docbackfill | pass | 32.1 | 1 | 15 | 61.2k | 0 | 552 | 32.0k/28.7k | 0.0288 | 0.0095 | 18/9 |
| syn-deepseek-v41 | claudecode | t29-logrollup | pass | 15 | 1 | 9 | 39.5k | 0 | 401 | 29.4k/9.7k | 0.0130 | 0.0036 | 436/0 |
| syn-deepseek-v41 | claudecode | t30-ifacedrift | pass | 24.4 | 1 | 16 | 67.5k | 0 | 690 | 46.2k/20.6k | 0.0247 | 0.0073 | 48/48 |
| syn-deepseek-v41 | claudecode | t31-tinyrename | pass | 30.4 | 1 | 14 | 101.6k | 0 | 640 | 72.6k/28.4k | 0.0351 | 0.0097 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| syn-deepseek-v41 | claudecode | 31/31 | 14.1 | 34 | 64.3k | 0 | 45.0k | 1.2k | 0.7163 | 0.2208 | 76/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
