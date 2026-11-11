# bench report — full31-syn-ds41-claudecode-j1

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| syn-deepseek-v41 | claudecode | t01-roman | pass | 10.8 | 1 | 5 | 44.9k | 0 | 206 | 12.0k/32.7k | 0.0283 | 0.0101 | 15/1 |
| syn-deepseek-v41 | claudecode | t02-jsonrepair | pass | 28.1 | 1 | 12 | 70.1k | 0 | 868 | 47.3k/21.9k | 0.0262 | 0.0079 | 96/1 |
| syn-deepseek-v41 | claudecode | t03-ringbuffer | pass | 45.9 | 1 | 10 | 57.6k | 0 | 519 | 35.2k/21.9k | 0.0238 | 0.0074 | 17/4 |
| syn-deepseek-v41 | claudecode | t04-csvbugfix | pass | 19.4 | 1 | 10 | 56.8k | 0 | 380 | 34.5k/21.9k | 0.0235 | 0.0072 | 3/3 |
| syn-deepseek-v41 | claudecode | t05-todostore | pass | 14.4 | 1 | 9 | 57.6k | 0 | 411 | 35.0k/22.1k | 0.0238 | 0.0073 | 16/4 |
| syn-deepseek-v41 | claudecode | t06-stackvm | pass | 48.9 | 1 | 15 | 70.0k | 0 | 2.6k | 53.2k/14.2k | 0.0230 | 0.0077 | 129/64 |
| syn-deepseek-v41 | claudecode | t07-validate | pass | 24 | 1 | 16 | 83.3k | 0 | 754 | 59.8k/22.8k | 0.0287 | 0.0081 | 13/10 |
| syn-deepseek-v41 | claudecode | t08-logsum | pass | 32.3 | 1 | 21 | 96.1k | 0 | 1.1k | 72.4k/22.7k | 0.0310 | 0.0085 | 76/4 |
| syn-deepseek-v41 | claudecode | t09-poolrace | pass | 26 | 1 | 7 | 45.0k | 0 | 391 | 12.0k/32.6k | 0.0285 | 0.0103 | 6/1 |
| syn-deepseek-v41 | claudecode | t10-iniparse | pass | 39.5 | 1 | 13 | 84.3k | 0 | 907 | 49.4k/34.0k | 0.0362 | 0.0116 | 12/6 |
| syn-deepseek-v41 | claudecode | t11-asyncbugs | pass | 17.4 | 1 | 12 | 58.2k | 0 | 573 | 35.3k/22.4k | 0.0242 | 0.0076 | 6/5 |
| syn-deepseek-v41 | claudecode | t12-refactor | pass | 14.3 | 1 | 13 | 57.4k | 0 | 380 | 45.5k/11.5k | 0.0170 | 0.0042 | 2/4 |
| syn-deepseek-v41 | claudecode | t13-batchrename | pass | 19.6 | 1 | 7 | 46.1k | 0 | 186 | 23.2k/22.7k | 0.0221 | 0.0072 | 27/27 |
| syn-deepseek-v41 | claudecode | t14-todosweep | pass | 23.2 | 1 | 17 | 60.3k | 0 | 932 | 36.9k/22.5k | 0.0250 | 0.0081 | 18/0 |
| syn-deepseek-v41 | claudecode | t15-pollstats | pass | 21 | 1 | 14 | 57.1k | 0 | 430 | 45.4k/11.3k | 0.0168 | 0.0042 | 1/0 |
| syn-deepseek-v41 | claudecode | t16-apisum | pass | 61.5 | 1 | 6 | 45.2k | 0 | 228 | 33.9k/11.1k | 0.0146 | 0.0038 | 22/0 |
| syn-deepseek-v41 | claudecode | t17-doccheck | pass | 45.5 | 1 | 23 | 101.1k | 0 | 1.9k | 76.1k/23.1k | 0.0330 | 0.0097 | 119/0 |
| syn-deepseek-v41 | claudecode | t18-lruttl | pass | 30.3 | 1 | 8 | 60.1k | 0 | 804 | 35.3k/24.0k | 0.0258 | 0.0084 | 106/12 |
| syn-deepseek-v41 | claudecode | t19-tokbucket | pass | 32.1 | 1 | 10 | 60.3k | 0 | 748 | 36.9k/22.7k | 0.0249 | 0.0079 | 26/11 |
| syn-deepseek-v41 | claudecode | t20-jsonpatch | pass | 72.4 | 1 | 19 | 84.0k | 0 | 3.3k | 56.6k/24.2k | 0.0323 | 0.0115 | 228/13 |
| syn-deepseek-v41 | claudecode | t21-wireproto | pass | 21.8 | 1 | 11 | 60.8k | 0 | 930 | 37.0k/22.9k | 0.0253 | 0.0082 | 65/8 |
| syn-deepseek-v41 | claudecode | t22-cronnext | pass | 36.6 | 1 | 7 | 63.6k | 0 | 1.8k | 39.2k/22.7k | 0.0265 | 0.0092 | 123/12 |
| syn-deepseek-v41 | claudecode | t23-mergesched | pass | 50.8 | 1 | 10 | 76.6k | 0 | 1.7k | 40.1k/34.8k | 0.0363 | 0.0127 | 84/4 |
| syn-deepseek-v41 | claudecode | t24-editops | pass | 42.9 | 1 | 10 | 75.3k | 0 | 1.7k | 50.7k/22.9k | 0.0284 | 0.0092 | 127/6 |
| syn-deepseek-v41 | claudecode | t25-shardmap | pass | 30 | 1 | 9 | 48.4k | 0 | 620 | 23.8k/24.0k | 0.0238 | 0.0081 | 88/16 |
| syn-deepseek-v41 | claudecode | t26-logfilter | pass | 87.6 | 1 | 14 | 92.0k | 0 | 4.4k | 62.2k/25.3k | 0.0355 | 0.0133 | 275/4 |
| syn-deepseek-v41 | claudecode | t27-tarpeek | pass | 67.8 | 1 | 28 | 195.3k | 0 | 2.5k | 167.4k/25.4k | 0.0501 | 0.0116 | 81/1 |
| syn-deepseek-v41 | claudecode | t28-docbackfill | pass | 31.1 | 1 | 13 | 70.5k | 0 | 538 | 46.8k/23.2k | 0.0267 | 0.0079 | 18/9 |
| syn-deepseek-v41 | claudecode | t29-logrollup | pass | 14.1 | 1 | 11 | 34.6k | 0 | 389 | 22.7k/11.5k | 0.0133 | 0.0040 | 436/0 |
| syn-deepseek-v41 | claudecode | t30-ifacedrift | pass | 19.5 | 1 | 13 | 62.3k | 0 | 440 | 14.0k/47.8k | 0.0410 | 0.0150 | 48/48 |
| syn-deepseek-v41 | claudecode | t31-tinyrename | pass | 15.1 | 1 | 8 | 57.9k | 0 | 336 | 35.4k/22.2k | 0.0238 | 0.0073 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| syn-deepseek-v41 | claudecode | 31/31 | 12.3 | 34 | 68.8k | 0 | 44.4k | 1.1k | 0.8395 | 0.2653 | 74/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
