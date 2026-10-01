# bench report — disc3-r1

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t13-batchrename | pass | 19.4 | 1 | 10 | 75.1k | 9.6k | 1.7k | 63.7k/0 | 0.0053 | 0.0053 | 27/27 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 21.5 | 1 | 10 | 60.8k | 6.2k | 1.6k | 53.0k/0 | 0.0041 | 0.0041 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 31.7 | 1 | 14 | 96.8k | 6.6k | 2.8k | 87.4k/0 | 0.0059 | 0.0059 | 26/0 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 65.6 | 1 | 9 | 98.4k | 13.1k | 4.1k | 81.2k/0 | 0.0094 | 0.0094 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 10.2 | 1 | 5 | 23.2k | 2.5k | 1.0k | 19.7k/0 | 0.0021 | 0.0021 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 24.3 | 1 | 9 | 91.0k | 11.3k | 2.3k | 77.4k/0 | 0.0066 | 0.0066 | 48/48 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 6.7 | 1 | 5 | 18.6k | 3.8k | 562 | 14.2k/0 | 0.0019 | 0.0019 | 27/27 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 8.9 | 1 | 5 | 15.3k | 2.6k | 898 | 11.8k/0 | 0.0019 | 0.0019 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 7.2 | 1 | 4 | 10.7k | 2.4k | 408 | 7.8k/0 | 0.0013 | 0.0013 | 22/0 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 12.5 | 1 | 6 | 24.9k | 4.3k | 1.3k | 19.3k/0 | 0.0029 | 0.0029 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 6.1 | 1 | 4 | 12.6k | 2.8k | 771 | 9.0k/0 | 0.0018 | 0.0018 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 7 | 1 | 4 | 20.5k | 6.3k | 867 | 13.3k/0 | 0.0030 | 0.0030 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 9.5 | 29 | 74.2k | 8.2k | 63.7k | 2.3k | 0.0334 | 0.0334 | 93/14 |
| deepseek-v4-flash | pi | 6/6 | 4.7 | 8 | 17.1k | 3.7k | 12.6k | 795 | 0.0129 | 0.0129 | 92/14 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
