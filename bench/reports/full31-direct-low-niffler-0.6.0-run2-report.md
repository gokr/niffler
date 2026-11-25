# bench report — full31-direct-low-niffler-0.6.0-run2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | niffler | t01-roman | pass | 6.6 | 1 | 5 | 20.5k | 4.0k | 551 | 15.9k/0 | 0.0020 | 0.0020 | 35/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 11.4 | 1 | 6 | 30.9k | 2.1k | 1.7k | 27.1k/0 | 0.0029 | 0.0029 | 86/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 13.4 | 1 | 7 | 34.8k | 2.8k | 1.0k | 31.0k/0 | 0.0023 | 0.0023 | 19/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 6.3 | 1 | 5 | 21.1k | 1.8k | 489 | 18.8k/0 | 0.0012 | 0.0012 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9 | 1 | 5 | 23.7k | 2.3k | 1.1k | 20.4k/0 | 0.0021 | 0.0021 | 25/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 20.7 | 1 | 7 | 65.6k | 6.2k | 3.9k | 55.6k/0 | 0.0068 | 0.0068 | 132/32 |
| deepseek-v4-flash | niffler | t07-validate | pass | 13.8 | 1 | 8 | 43.4k | 3.1k | 1.6k | 38.7k/0 | 0.0031 | 0.0031 | 16/9 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 17.6 | 1 | 11 | 66.9k | 3.8k | 2.2k | 60.9k/0 | 0.0041 | 0.0041 | 73/5 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 13.1 | 1 | 6 | 28.0k | 2.0k | 1.0k | 25.0k/0 | 0.0020 | 0.0020 | 13/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 15.8 | 1 | 7 | 36.7k | 2.8k | 1.6k | 32.4k/0 | 0.0029 | 0.0029 | 12/7 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 6.1 | 1 | 4 | 19.5k | 3.0k | 592 | 15.9k/0 | 0.0017 | 0.0017 | 6/11 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 7.2 | 1 | 5 | 22.6k | 2.3k | 606 | 19.7k/0 | 0.0015 | 0.0015 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 9.8 | 1 | 7 | 42.1k | 4.3k | 738 | 37.0k/0 | 0.0024 | 0.0024 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 20 | 1 | 8 | 50.1k | 3.0k | 3.0k | 44.0k/0 | 0.0048 | 0.0048 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 8.2 | 1 | 6 | 26.6k | 2.1k | 670 | 23.8k/0 | 0.0016 | 0.0016 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 23.6 | 1 | 13 | 80.8k | 4.2k | 2.7k | 73.9k/0 | 0.0050 | 0.0050 | 23/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 20.3 | 1 | 9 | 60.1k | 3.1k | 3.4k | 53.6k/0 | 0.0053 | 0.0053 | 123/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 13.1 | 1 | 5 | 30.6k | 3.2k | 2.3k | 25.2k/0 | 0.0038 | 0.0038 | 122/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 7.8 | 1 | 5 | 25.8k | 3.0k | 959 | 21.9k/0 | 0.0022 | 0.0022 | 27/13 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 31.2 | 1 | 9 | 87.3k | 4.9k | 6.2k | 76.2k/0 | 0.0094 | 0.0094 | 201/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 11.1 | 1 | 5 | 29.4k | 3.3k | 1.8k | 24.3k/0 | 0.0033 | 0.0033 | 65/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 22 | 1 | 8 | 69.4k | 5.4k | 3.9k | 60.0k/0 | 0.0067 | 0.0067 | 123/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 10.8 | 1 | 5 | 26.3k | 2.4k | 1.6k | 22.3k/0 | 0.0027 | 0.0027 | 81/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 21.5 | 1 | 7 | 49.8k | 3.7k | 4.1k | 42.0k/0 | 0.0063 | 0.0063 | 131/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 11.3 | 1 | 6 | 33.8k | 3.3k | 1.4k | 29.1k/0 | 0.0028 | 0.0028 | 80/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 25.9 | 1 | 7 | 63.2k | 4.7k | 5.3k | 53.2k/0 | 0.0080 | 0.0080 | 267/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 34.6 | 1 | 10 | 119.3k | 7.9k | 4.7k | 106.8k/0 | 0.0086 | 0.0086 | 93/2 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 7.8 | 1 | 5 | 26.7k | 3.8k | 676 | 22.1k/0 | 0.0021 | 0.0021 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 7 | 1 | 5 | 24.1k | 2.5k | 753 | 20.9k/0 | 0.0018 | 0.0018 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 12.3 | 1 | 7 | 52.7k | 5.9k | 1.6k | 45.2k/0 | 0.0040 | 0.0040 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 8.2 | 1 | 6 | 31.6k | 3.4k | 731 | 27.5k/0 | 0.0021 | 0.0021 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 31/31 | 6.7 | 14 | 43.3k | 3.6k | 37.7k | 2.0k | 0.1153 | 0.1153 | 75/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
