# bench report — full31-direct-low-niffler-0.6.0

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 5.9 | 1 | 4 | 16.8k | 4.5k | 433 | 11.9k/0 | 0.0019 | 0.0019 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 12.1 | 1 | 6 | 29.8k | 2.0k | 1.6k | 26.1k/0 | 0.0027 | 0.0027 | 88/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 10.8 | 1 | 5 | 23.2k | 2.3k | 804 | 20.1k/0 | 0.0018 | 0.0018 | 22/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 7.4 | 1 | 5 | 22.7k | 2.3k | 496 | 19.8k/0 | 0.0014 | 0.0014 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 8.1 | 1 | 5 | 22.8k | 2.2k | 754 | 19.8k/0 | 0.0017 | 0.0017 | 19/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 19.1 | 1 | 6 | 55.6k | 6.0k | 4.0k | 45.6k/0 | 0.0069 | 0.0069 | 182/42 |
| deepseek-v4-flash | niffler | t07-validate | pass | 9.5 | 1 | 5 | 27.3k | 3.5k | 1.1k | 22.8k/0 | 0.0025 | 0.0025 | 13/7 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 14.9 | 1 | 8 | 47.0k | 3.6k | 2.1k | 41.3k/0 | 0.0038 | 0.0038 | 85/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 13.8 | 1 | 6 | 35.2k | 3.7k | 1.1k | 30.3k/0 | 0.0026 | 0.0026 | 10/2 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 14.7 | 1 | 7 | 37.0k | 3.1k | 1.1k | 32.8k/0 | 0.0024 | 0.0024 | 7/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 6.9 | 1 | 4 | 17.4k | 2.0k | 619 | 14.8k/0 | 0.0014 | 0.0014 | 6/11 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 9 | 1 | 6 | 27.5k | 2.3k | 663 | 24.6k/0 | 0.0016 | 0.0016 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 9.2 | 1 | 7 | 39.0k | 3.8k | 802 | 34.4k/0 | 0.0023 | 0.0023 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 16.7 | 1 | 9 | 53.5k | 3.1k | 2.3k | 48.1k/0 | 0.0039 | 0.0039 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 7.9 | 1 | 6 | 26.0k | 1.9k | 616 | 23.6k/0 | 0.0014 | 0.0014 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 16.2 | 1 | 8 | 40.5k | 2.5k | 1.7k | 36.4k/0 | 0.0030 | 0.0030 | 24/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 33.6 | 1 | 14 | 115.4k | 4.7k | 4.7k | 106.0k/0 | 0.0077 | 0.0077 | 130/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 13.6 | 1 | 6 | 36.9k | 3.6k | 1.9k | 31.5k/0 | 0.0035 | 0.0035 | 101/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 11.9 | 1 | 8 | 49.1k | 4.0k | 1.2k | 43.9k/0 | 0.0029 | 0.0029 | 27/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 22.7 | 1 | 6 | 48.5k | 4.2k | 4.5k | 39.8k/0 | 0.0069 | 0.0069 | 258/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 13.1 | 1 | 5 | 31.3k | 3.5k | 2.3k | 25.6k/0 | 0.0039 | 0.0039 | 66/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 21.4 | 1 | 7 | 57.2k | 4.5k | 3.8k | 48.9k/0 | 0.0062 | 0.0062 | 124/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 15.5 | 1 | 6 | 38.4k | 4.8k | 2.2k | 31.4k/0 | 0.0043 | 0.0043 | 77/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 22.5 | 1 | 11 | 81.7k | 8.4k | 3.4k | 70.0k/0 | 0.0070 | 0.0070 | 113/6 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 12.7 | 1 | 6 | 34.0k | 3.2k | 1.4k | 29.4k/0 | 0.0028 | 0.0028 | 82/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 20.6 | 1 | 6 | 46.2k | 3.1k | 4.5k | 38.5k/0 | 0.0066 | 0.0066 | 275/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 37.7 | 1 | 12 | 101.1k | 4.7k | 5.0k | 91.4k/0 | 0.0080 | 0.0080 | 98/4 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 7.6 | 1 | 5 | 25.4k | 2.9k | 567 | 21.9k/0 | 0.0017 | 0.0017 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 12.8 | 1 | 7 | 37.9k | 3.1k | 1.5k | 33.3k/0 | 0.0029 | 0.0029 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 8.9 | 1 | 6 | 42.9k | 6.6k | 845 | 35.5k/0 | 0.0032 | 0.0032 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 11.4 | 1 | 8 | 41.9k | 3.3k | 714 | 37.9k/0 | 0.0021 | 0.0021 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.8 | 14 | 42.2k | 3.7k | 36.7k | 1.9k | 0.1111 | 0.1111 | 77/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
