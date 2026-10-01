# bench report — disc3-r2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t13-batchrename | pass | 9.5 | 1 | 6 | 29.5k | 5.4k | 1.1k | 23.0k/0 | 0.0030 | 0.0030 | 27/27 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 29.9 | 1 | 13 | 103.7k | 9.9k | 3.0k | 90.8k/0 | 0.0071 | 0.0071 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 67.2 | 1 | 22 | 220.7k | 10.3k | 6.0k | 204.4k/0 | 0.0115 | 0.0115 | 39/0 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 12.8 | 1 | 6 | 29.7k | 3.5k | 1.4k | 24.8k/0 | 0.0029 | 0.0029 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 18.7 | 1 | 7 | 37.4k | 3.8k | 1.4k | 32.3k/0 | 0.0030 | 0.0030 | 475/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 16.7 | 1 | 9 | 76.3k | 8.2k | 1.4k | 66.7k/0 | 0.0045 | 0.0045 | 48/48 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 6.9 | 1 | 4 | 13.4k | 3.7k | 552 | 9.2k/0 | 0.0018 | 0.0018 | 27/27 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 6.7 | 1 | 4 | 11.3k | 2.4k | 763 | 8.2k/0 | 0.0017 | 0.0017 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 7.2 | 1 | 4 | 10.4k | 2.4k | 329 | 7.7k/0 | 0.0012 | 0.0012 | 15/0 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 10.2 | 1 | 6 | 27.6k | 4.7k | 1.3k | 21.6k/0 | 0.0030 | 0.0030 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 7.8 | 1 | 5 | 23.9k | 5.1k | 756 | 18.0k/0 | 0.0026 | 0.0026 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 9 | 1 | 6 | 38.5k | 6.7k | 1.3k | 30.6k/0 | 0.0037 | 0.0037 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 6/6 | 10.5 | 26 | 82.9k | 6.8k | 73.7k | 2.4k | 0.0320 | 0.0320 | 101/14 |
| deepseek-v4-flash | pi | 6/6 | 4.8 | 8 | 20.9k | 4.2k | 15.9k | 819 | 0.0140 | 0.0140 | 91/14 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
