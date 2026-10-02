# bench report — disc3-r3

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t13-batchrename | pass | 15.5 | 1 | 8 | 45.9k | 6.7k | 1.9k | 37.4k/0 | 0.0045 | 0.0045 | 27/27 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 26.1 | 1 | 8 | 58.5k | 7.1k | 3.5k | 47.9k/0 | 0.0067 | 0.0067 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | fail | 11.6 | 1 | 6 | 23.9k | 2.3k | 623 | 21.0k/0 | 0.0016 | 0.0016 | 24/0 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 15.3 | 1 | 8 | 45.7k | 4.5k | 1.7k | 39.4k/0 | 0.0037 | 0.0037 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 7.5 | 1 | 4 | 15.9k | 2.0k | 649 | 13.3k/0 | 0.0014 | 0.0014 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 15.9 | 1 | 8 | 68.0k | 8.0k | 1.6k | 58.4k/0 | 0.0047 | 0.0047 | 48/48 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 4.3 | 1 | 3 | 10.5k | 3.7k | 382 | 6.4k/0 | 0.0016 | 0.0016 | 27/27 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 7 | 1 | 5 | 13.9k | 2.7k | 623 | 10.6k/0 | 0.0016 | 0.0016 | 1/0 |
| deepseek-v4-flash | pi | t16-apisum | pass | 11.4 | 1 | 6 | 18.6k | 3.0k | 798 | 14.8k/0 | 0.0019 | 0.0019 | 22/0 |
| deepseek-v4-flash | pi | t28-docbackfill | pass | 12.1 | 1 | 7 | 27.1k | 3.9k | 1.3k | 21.9k/0 | 0.0029 | 0.0029 | 18/9 |
| deepseek-v4-flash | pi | t29-logrollup | pass | 7 | 1 | 4 | 14.3k | 3.1k | 955 | 10.2k/0 | 0.0021 | 0.0021 | 436/0 |
| deepseek-v4-flash | pi | t30-ifacedrift | pass | 8.1 | 1 | 5 | 29.5k | 6.7k | 987 | 21.8k/0 | 0.0033 | 0.0033 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 5/6 | 7.0 | 15 | 43.0k | 5.1k | 36.2k | 1.7k | 0.0226 | 0.0226 | 92/14 |
| deepseek-v4-flash | pi | 6/6 | 5.0 | 8 | 19.0k | 3.8k | 14.3k | 845 | 0.0135 | 0.0135 | 92/14 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
