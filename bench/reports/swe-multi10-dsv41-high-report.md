# bench report — swe-multi10-dsv41-high

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| syn-deepseek-v41 | claudecode | axios__axios-4731 | pass | 58.1 | 1 | 17 | 61.6k | 0 | 879 | 45.6k/15.1k | 0.0204 | 0.0059 | 4/0 |
| syn-deepseek-v41 | claudecode | caddyserver__caddy-6115 | fail | 59.3 | 1 | 15 | 71.4k | 0 | 940 | 61.4k/9.0k | 0.0182 | 0.0042 | 5/4 |
| syn-deepseek-v41 | claudecode | facebook__docusaurus-10130 | pass | 119.5 | 1 | 38 | 149.6k | 0 | 2.5k | 133.5k/13.6k | 0.0353 | 0.0079 | 11/1 |
| syn-deepseek-v41 | claudecode | fmtlib__fmt-1683 | fail | 140.8 | 1 | 30 | 168.2k | 0 | 1.5k | 155.6k/11.1k | 0.0356 | 0.0061 | 5/1 |
| syn-deepseek-v41 | claudecode | gin-gonic__gin-1805 | pass | 341.7 | 1 | 47 | 314.5k | 14.3k | 9.1k | 262.5k/28.6k | 0.0872 | 0.0254 | 5/1 |
| syn-deepseek-v41 | claudecode | jqlang__jq-2235 | fail | 595.9 | 1 | 98 | 584.5k | 0 | 16.6k | 521.9k/46.0k | 0.1402 | 0.0368 | 13/3 |
| syn-deepseek-v41 | claudecode | nushell__nushell-12901 | pass | 176.7 | 1 | 60 | 329.2k | 0 | 3.7k | 305.4k/20.1k | 0.0694 | 0.0123 | 10/0 |
| syn-deepseek-v41 | claudecode | redis__redis-10068 | pass | 254.5 | 1 | 47 | 299.6k | 0 | 4.2k | 277.7k/17.7k | 0.0637 | 0.0120 | 2/2 |
| syn-deepseek-v41 | claudecode | rubocop__rubocop-13362 | pass | 113.7 | 1 | 32 | 140.3k | 0 | 2.3k | 120.0k/17.9k | 0.0364 | 0.0089 | 1/1 |
| syn-deepseek-v41 | claudecode | tokio-rs__tokio-4384 | fail | 213.8 | 1 | 49 | 287.5k | 0 | 5.7k | 263.3k/18.5k | 0.0638 | 0.0140 | 9/0 |
| syn-deepseek-v41 | niffler | axios__axios-4731 | pass | 119.9 | 1 | 13 | 156.3k | 18.2k | 7.0k | 131.2k/0 | 0.0439 | 0.0146 | 4/0 |
| syn-deepseek-v41 | niffler | caddyserver__caddy-6115 | fail | 44.6 | 1 | 7 | 53.4k | 11.3k | 1.3k | 40.7k/0 | 0.0172 | 0.0052 | 5/4 |
| syn-deepseek-v41 | niffler | facebook__docusaurus-10130 | pass | 163.4 | 1 | 19 | 294.7k | 25.5k | 9.4k | 259.7k/0 | 0.0733 | 0.0205 | 18/2 |
| syn-deepseek-v41 | niffler | fmtlib__fmt-1683 | fail | 165.8 | 1 | 25 | 601.8k | 33.2k | 4.9k | 563.7k/0 | 0.1226 | 0.0192 | 1/1 |
| syn-deepseek-v41 | niffler | gin-gonic__gin-1805 | pass | 359.6 | 1 | 18 | 501.1k | 48.5k | 21.2k | 431.5k/0 | 0.1332 | 0.0425 | 1/1 |
| syn-deepseek-v41 | niffler | jqlang__jq-2235 | fail | 157.3 | 1 | 13 | 162.8k | 19.0k | 6.7k | 137.1k/0 | 0.0452 | 0.0146 | 2/2 |
| syn-deepseek-v41 | niffler | nushell__nushell-12901 | pass | 106.2 | 1 | 16 | 313.0k | 27.5k | 3.9k | 281.6k/0 | 0.0717 | 0.0146 | 7/1 |
| syn-deepseek-v41 | niffler | redis__redis-10068 | pass | 284.8 | 1 | 17 | 350.2k | 27.5k | 8.2k | 314.6k/0 | 0.0821 | 0.0199 | 2/2 |
| syn-deepseek-v41 | niffler | rubocop__rubocop-13362 | pass | 136 | 1 | 22 | 252.2k | 19.3k | 8.0k | 224.9k/0 | 0.0610 | 0.0167 | 1/1 |
| syn-deepseek-v41 | niffler | tokio-rs__tokio-4384 | fail | 208.6 | 1 | 20 | 362.4k | 27.1k | 13.5k | 321.8k/0 | 0.0893 | 0.0262 | 9/0 |
| syn-deepseek-v41 | pi | axios__axios-4731 | pass | 195.1 | 1 | 14 | 120.0k | 13.9k | 13.5k | 92.5k/0 | 0.0421 | 0.0209 | 6/1 |
| syn-deepseek-v41 | pi | caddyserver__caddy-6115 | fail | 42.4 | 1 | 8 | 30.1k | 7.0k | 1.4k | 21.8k/0 | 0.0107 | 0.0039 | 5/4 |
| syn-deepseek-v41 | pi | facebook__docusaurus-10130 | pass | 363.2 | 1 | 25 | 414.1k | 33.5k | 25.4k | 355.2k/0 | 0.1141 | 0.0427 | 14/2 |
| syn-deepseek-v41 | pi | fmtlib__fmt-1683 | fail | 124.1 | 1 | 16 | 120.0k | 14.9k | 4.3k | 100.9k/0 | 0.0332 | 0.0102 | 1/1 |
| syn-deepseek-v41 | pi | gin-gonic__gin-1805 | fail | 1244.9 | 1 | 28 | 513.3k | 55.7k | 95.4k | 362.2k/0 | 0.2170 | 0.1334 | 4/1 |
| syn-deepseek-v41 | pi | jqlang__jq-2235 | fail | 1595.5 | 1 | 31 | 641.2k | 40.6k | 94.5k | 506.1k/0 | 0.2268 | 0.1286 | 2/2 |
| syn-deepseek-v41 | pi | nushell__nushell-12901 | pass | 428.9 | 1 | 31 | 769.8k | 43.5k | 29.3k | 697.0k/0 | 0.1815 | 0.0524 | 4/2 |
| syn-deepseek-v41 | pi | redis__redis-10068 | pass | 248.2 | 1 | 15 | 174.2k | 20.2k | 9.1k | 144.8k/0 | 0.0503 | 0.0179 | 2/2 |
| syn-deepseek-v41 | pi | rubocop__rubocop-13362 | pass | 128.7 | 1 | 16 | 123.9k | 14.5k | 8.1k | 101.2k/0 | 0.0376 | 0.0147 | 1/1 |
| syn-deepseek-v41 | pi | tokio-rs__tokio-4384 | fail | 3600.2 | 1 | 56 | 2095.7k | 70.1k | 268.2k | 1757.3k/0 | 0.6592 | 0.3535 | 0/0 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| syn-deepseek-v41 | claudecode | 6/10 | 43.3 | 207 | 240.6k | 1.4k | 214.7k | 4.8k | 0.5701 | 0.1335 | 7/1 |
| syn-deepseek-v41 | niffler | 6/10 | 17.0 | 175 | 304.8k | 25.7k | 270.7k | 8.4k | 0.7396 | 0.1942 | 5/1 |
| syn-deepseek-v41 | pi | 5/10 | 24.0 | 797 | 500.2k | 31.4k | 413.9k | 54.9k | 1.5725 | 0.7782 | 4/2 |

*`invalid*` = tests pass but protected files (tests) were modified.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
