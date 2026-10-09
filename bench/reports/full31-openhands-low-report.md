# bench report — full31-openhands-low2

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | openhands | t01-roman | pass | 9.3 | 1 | 1 | 37.6k | 6.4k | 715 | 30.5k/0 | 0.0030 | 0.0030 | 19/1 |
| deepseek-v4-flash | openhands | t02-jsonrepair | pass | 21.4 | 1 | 1 | 56.6k | 7.7k | 3.3k | 45.7k/0 | 0.0065 | 0.0065 | 101/1 |
| deepseek-v4-flash | openhands | t03-ringbuffer | pass | 15.5 | 1 | 1 | 48.9k | 5.7k | 1.1k | 42.1k/0 | 0.0033 | 0.0033 | 15/4 |
| deepseek-v4-flash | openhands | t04-csvbugfix | pass | 13.6 | 1 | 1 | 61.1k | 6.0k | 1.3k | 53.8k/0 | 0.0037 | 0.0037 | 3/3 |
| deepseek-v4-flash | openhands | t05-todostore | pass | 12.8 | 1 | 1 | 50.1k | 6.0k | 1.5k | 42.6k/0 | 0.0038 | 0.0038 | 16/4 |
| deepseek-v4-flash | openhands | t06-stackvm | pass | 51.6 | 1 | 1 | 197.9k | 12.4k | 10.8k | 174.7k/0 | 0.0177 | 0.0177 | 179/61 |
| deepseek-v4-flash | openhands | t07-validate | pass | 21.5 | 1 | 1 | 69.2k | 6.7k | 2.9k | 59.6k/0 | 0.0058 | 0.0058 | 12/6 |
| deepseek-v4-flash | openhands | t08-logsum | pass | 39.5 | 1 | 1 | 228.8k | 12.3k | 4.7k | 211.8k/0 | 0.0106 | 0.0106 | 65/3 |
| deepseek-v4-flash | openhands | t09-poolrace | pass | 14.7 | 1 | 1 | 52.2k | 6.5k | 1.1k | 44.7k/0 | 0.0035 | 0.0035 | 4/1 |
| deepseek-v4-flash | openhands | t10-iniparse | pass | 22.2 | 1 | 1 | 55.6k | 7.1k | 1.6k | 46.8k/0 | 0.0044 | 0.0044 | 6/5 |
| deepseek-v4-flash | openhands | t11-asyncbugs | pass | 19 | 1 | 1 | 93.6k | 8.3k | 1.9k | 83.5k/0 | 0.0052 | 0.0052 | 5/10 |
| deepseek-v4-flash | openhands | t12-refactor | pass | 10.6 | 1 | 1 | 39.0k | 7.0k | 1.1k | 31.0k/0 | 0.0035 | 0.0035 | 2/4 |
| deepseek-v4-flash | openhands | t13-batchrename | pass | 11.7 | 1 | 1 | 52.1k | 8.3k | 805 | 43.0k/0 | 0.0037 | 0.0037 | 27/27 |
| deepseek-v4-flash | openhands | t14-todosweep | pass | 22.1 | 1 | 1 | 88.6k | 6.6k | 2.4k | 79.6k/0 | 0.0053 | 0.0053 | 18/0 |
| deepseek-v4-flash | openhands | t15-pollstats | pass | 13.1 | 1 | 0 | 48.8k | 5.4k | 1.1k | 42.2k/0 | 0.0032 | 0.0032 | 1/0 |
| deepseek-v4-flash | openhands | t16-apisum | pass | 12.9 | 1 | 0 | 49.1k | 5.7k | 946 | 42.5k/0 | 0.0031 | 0.0031 | 21/0 |
| deepseek-v4-flash | openhands | t17-doccheck | pass | 83.4 | 1 | 1 | 377.1k | 10.0k | 13.9k | 353.2k/0 | 0.0218 | 0.0218 | 159/0 |
| deepseek-v4-flash | openhands | t18-lruttl | pass | 26.9 | 1 | 1 | 109.4k | 8.1k | 5.1k | 96.3k/0 | 0.0091 | 0.0091 | 104/12 |
| deepseek-v4-flash | openhands | t19-tokbucket | pass | 11.6 | 1 | 1 | 43.6k | 8.4k | 1.4k | 33.8k/0 | 0.0044 | 0.0044 | 24/16 |
| deepseek-v4-flash | openhands | t20-jsonpatch | pass | 46.4 | 1 | 1 | 134.0k | 10.6k | 10.4k | 113.0k/0 | 0.0163 | 0.0163 | 192/11 |
| deepseek-v4-flash | openhands | t21-wireproto | pass | 26.9 | 1 | 1 | 87.6k | 10.6k | 5.0k | 71.9k/0 | 0.0097 | 0.0097 | 55/9 |
| deepseek-v4-flash | openhands | t22-cronnext | pass | 41.3 | 1 | 1 | 78.6k | 8.9k | 8.5k | 61.2k/0 | 0.0133 | 0.0133 | 84/17 |
| deepseek-v4-flash | openhands | t23-mergesched | pass | 15.6 | 1 | 1 | 47.1k | 6.8k | 2.6k | 37.8k/0 | 0.0054 | 0.0054 | 68/4 |
| deepseek-v4-flash | openhands | t24-editops | pass | 51.4 | 1 | 1 | 223.9k | 12.8k | 8.4k | 202.8k/0 | 0.0151 | 0.0151 | 98/11 |
| deepseek-v4-flash | openhands | t25-shardmap | pass | 32.3 | 1 | 1 | 151.6k | 11.8k | 4.6k | 135.2k/0 | 0.0098 | 0.0098 | 79/16 |
| deepseek-v4-flash | openhands | t26-logfilter | pass | 44 | 1 | 1 | 76.1k | 17.1k | 10.5k | 48.4k/0 | 0.0181 | 0.0181 | 236/4 |
| deepseek-v4-flash | openhands | t27-tarpeek | pass | 42 | 1 | 1 | 189.1k | 17.4k | 6.4k | 165.2k/0 | 0.0139 | 0.0139 | 78/1 |
| deepseek-v4-flash | openhands | t28-docbackfill | pass | 16.8 | 1 | 1 | 66.0k | 8.7k | 1.6k | 55.7k/0 | 0.0049 | 0.0049 | 18/9 |
| deepseek-v4-flash | openhands | t29-logrollup | pass | 14.7 | 1 | 1 | 64.9k | 6.7k | 1.5k | 56.7k/0 | 0.0042 | 0.0042 | 436/0 |
| deepseek-v4-flash | openhands | t30-ifacedrift | pass | 16.7 | 1 | 0 | 89.1k | 12.3k | 2.1k | 74.6k/0 | 0.0067 | 0.0067 | 48/48 |
| deepseek-v4-flash | openhands | t31-tinyrename | pass | 13.7 | 1 | 1 | 49.8k | 5.9k | 1.2k | 42.8k/0 | 0.0034 | 0.0034 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | openhands | 31/31 | 0.9 | 26 | 97.3k | 8.8k | 84.6k | 3.9k | 0.2424 | 0.2424 | 70/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

**This report supersedes the first `full31-openhands-low` record (commit 6bd924b).** That run's cells cross-talked: the adapter keyed conversations on the bench session id, which is `null` on round 1 and shared across concurrent cells, so with `jobs=2` one cell continued another's conversation (visible as t03's reply describing t02's task). Its 29/31 failure count and aggregates were contamination artifacts and its commit message's "31/31" claim described the single-cell smoke, not the run. The conversation map is now keyed per task repo; this rerun (`full31-openhands-low2`, identical command otherwise) is the valid record.

- Fresh solo-lane run on 2026-10-05: `node bench/run.mjs --harness openhands --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low`. First-party `https://api.deepseek.com/v1` chat completions (the LLM is pinned per conversation as `openai/deepseek-v4-flash`); **no LLM Gateway**. 31 results, all `pass`.
- OpenHands pinned at `8bb229341` (`v1.24.0` + 48); the lane drives its `openhands-agent-server` (PyPI **1.50.1**, the exact `uvx` package set the product launcher uses) directly over the documented REST API — the Agent Canvas UI/ingress is not involved. Conversations are created with `agent_settings {agent_kind: "openhands"}` (the product-faithful shape: default agent + `terminal`/`file_editor`/`task_tracker` toolset; an explicit `agent` block initializes no tools).
- Usage from `stats.usage_to_metrics` (provider-reported aggregates incl. cache read/write); tool calls and leak evidence from `ActionEvent`s; answer from `agent_final_response`; completion on `execution_status`; confirmations disabled (`NeverConfirm`).
- Caveats: `thinking low` is not expressible to this stack (the endpoint's default effort applies), `firstPromptTokens` is not captured, and the `turns` metric counts agent message events — not 1:1 comparable with the other lanes. The default toolset (3 coding tools) is much leaner than Niffler's/Maki's and comparable to DSH-`sdk-minimal`'s.
