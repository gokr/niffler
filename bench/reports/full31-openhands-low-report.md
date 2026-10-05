# bench report — full31-openhands-low

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | openhands | t01-roman | pass | 10.3 | 1 | 1 | 37.4k | 6.5k | 664 | 30.2k/0 | 0.0029 | 0.0029 | 13/1 |
| deepseek-v4-flash | openhands | t02-jsonrepair | pass | 34.7 | 1 | 1 | 119.0k | 13.5k | 4.9k | 100.6k/0 | 0.0105 | 0.0105 | 77/1 |
| deepseek-v4-flash | openhands | t03-ringbuffer | fail | 28 | 1 | 1 | 119.0k | 13.5k | 4.9k | 100.6k/0 | 0.0105 | 0.0105 | 0/0 |
| deepseek-v4-flash | openhands | t04-csvbugfix | fail | 2.4 | 1 | 1 | 133.8k | 18.7k | 5.1k | 110.0k/0 | 0.0124 | 0.0124 | 0/0 |
| deepseek-v4-flash | openhands | t05-todostore | fail | 7.1 | 1 | 2 | 148.5k | 19.0k | 5.1k | 124.4k/0 | 0.0126 | 0.0126 | 0/0 |
| deepseek-v4-flash | openhands | t06-stackvm | fail | 6.1 | 1 | 2 | 148.5k | 19.0k | 5.1k | 124.4k/0 | 0.0126 | 0.0126 | 0/0 |
| deepseek-v4-flash | openhands | t07-validate | fail | 8.1 | 1 | 3 | 163.5k | 19.2k | 5.3k | 139.0k/0 | 0.0130 | 0.0130 | 0/0 |
| deepseek-v4-flash | openhands | t08-logsum | fail | 8.1 | 1 | 3 | 163.5k | 19.2k | 5.3k | 139.0k/0 | 0.0130 | 0.0130 | 0/0 |
| deepseek-v4-flash | openhands | t09-poolrace | fail | 5 | 1 | 4 | 194.0k | 19.8k | 5.6k | 168.7k/0 | 0.0136 | 0.0136 | 0/0 |
| deepseek-v4-flash | openhands | t10-iniparse | fail | 7.9 | 1 | 4 | 194.0k | 19.8k | 5.6k | 168.7k/0 | 0.0136 | 0.0136 | 0/0 |
| deepseek-v4-flash | openhands | t11-asyncbugs | fail | 5.5 | 1 | 5 | 225.3k | 20.6k | 5.8k | 198.8k/0 | 0.0144 | 0.0144 | 0/0 |
| deepseek-v4-flash | openhands | t12-refactor | fail | 2.6 | 1 | 5 | 225.3k | 20.6k | 5.8k | 198.8k/0 | 0.0144 | 0.0144 | 0/0 |
| deepseek-v4-flash | openhands | t13-batchrename | fail | 10.8 | 1 | 5 | 275.0k | 21.5k | 7.2k | 246.3k/0 | 0.0166 | 0.0166 | 0/0 |
| deepseek-v4-flash | openhands | t14-todosweep | fail | 10.4 | 1 | 5 | 275.0k | 21.5k | 7.2k | 246.3k/0 | 0.0166 | 0.0166 | 0/0 |
| deepseek-v4-flash | openhands | t15-pollstats | fail | 7.1 | 1 | 6 | 291.7k | 22.6k | 7.2k | 261.9k/0 | 0.0170 | 0.0170 | 0/0 |
| deepseek-v4-flash | openhands | t16-apisum | fail | 6.8 | 1 | 6 | 291.7k | 22.6k | 7.2k | 261.9k/0 | 0.0170 | 0.0170 | 0/0 |
| deepseek-v4-flash | openhands | t17-doccheck | fail | 2.5 | 1 | 7 | 308.6k | 22.9k | 7.4k | 278.4k/0 | 0.0174 | 0.0174 | 0/0 |
| deepseek-v4-flash | openhands | t18-lruttl | fail | 2.7 | 1 | 7 | 308.6k | 22.9k | 7.4k | 278.4k/0 | 0.0174 | 0.0174 | 0/0 |
| deepseek-v4-flash | openhands | t19-tokbucket | fail | 6.8 | 1 | 8 | 325.5k | 23.0k | 7.5k | 295.0k/0 | 0.0176 | 0.0176 | 0/0 |
| deepseek-v4-flash | openhands | t20-jsonpatch | fail | 6.4 | 1 | 8 | 325.5k | 23.0k | 7.5k | 295.0k/0 | 0.0176 | 0.0176 | 0/0 |
| deepseek-v4-flash | openhands | t21-wireproto | fail | 2.8 | 1 | 9 | 342.5k | 23.3k | 7.5k | 311.7k/0 | 0.0179 | 0.0179 | 0/0 |
| deepseek-v4-flash | openhands | t22-cronnext | fail | 2.4 | 1 | 9 | 342.5k | 23.3k | 7.5k | 311.7k/0 | 0.0179 | 0.0179 | 0/0 |
| deepseek-v4-flash | openhands | t23-mergesched | fail | 7.7 | 1 | 10 | 359.5k | 23.4k | 7.6k | 328.4k/0 | 0.0181 | 0.0181 | 0/0 |
| deepseek-v4-flash | openhands | t24-editops | fail | 7.3 | 1 | 10 | 359.5k | 23.4k | 7.6k | 328.4k/0 | 0.0181 | 0.0181 | 0/0 |
| deepseek-v4-flash | openhands | t25-shardmap | fail | 7.3 | 1 | 11 | 376.5k | 23.6k | 7.7k | 345.2k/0 | 0.0184 | 0.0184 | 0/0 |
| deepseek-v4-flash | openhands | t26-logfilter | fail | 7.1 | 1 | 11 | 376.5k | 23.6k | 7.7k | 345.2k/0 | 0.0184 | 0.0184 | 0/0 |
| deepseek-v4-flash | openhands | t27-tarpeek | fail | 5.4 | 1 | 12 | 393.6k | 23.8k | 7.8k | 362.0k/0 | 0.0187 | 0.0187 | 0/0 |
| deepseek-v4-flash | openhands | t28-docbackfill | fail | 2.8 | 1 | 12 | 393.6k | 23.8k | 7.8k | 362.0k/0 | 0.0187 | 0.0187 | 0/0 |
| deepseek-v4-flash | openhands | t29-logrollup | fail | 2.3 | 1 | 13 | 410.7k | 24.1k | 7.9k | 378.8k/0 | 0.0190 | 0.0190 | 0/0 |
| deepseek-v4-flash | openhands | t30-ifacedrift | fail | 2.6 | 1 | 14 | 427.9k | 24.2k | 8.0k | 395.6k/0 | 0.0192 | 0.0192 | 0/0 |
| deepseek-v4-flash | openhands | t31-tinyrename | fail | 2.4 | 1 | 14 | 427.9k | 24.2k | 8.0k | 395.6k/0 | 0.0192 | 0.0192 | 0/0 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | openhands | 2/31 | 6.7 | 7 | 273.7k | 21.0k | 246.2k | 6.5k | 0.4844 | 0.4844 | 3/0 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

- Fresh solo-lane run on 2026-10-05: `node bench/run.mjs --harness openhands --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low --run-id full31-openhands-low`. First-party `https://api.deepseek.com/v1` chat completions (the LLM is pinned per conversation as `openai/deepseek-v4-flash`); **no LLM Gateway**.
- OpenHands pinned at `8bb229341` (`v1.24.0` + 48); the lane drives its `openhands-agent-server` (PyPI **1.50.1**, the exact `uvx` package set the product launcher uses) directly over the documented REST API — the Agent Canvas UI/ingress is not involved. Conversations are created with `agent_settings {agent_kind: "openhands"}`, which is the product-faithful shape: the server builds its default agent and toolset (`terminal`, `file_editor`, `task_tracker`, plus `think`/`finish`) — an explicit `agent` block initializes no tools at all.
- Usage comes from `stats.usage_to_metrics` (provider-reported aggregates incl. cache read/write); tool calls and leaks from `ActionEvent`s; the final answer from `agent_final_response`; completion on `execution_status`. Confirmations are disabled (`NeverConfirm`).
- Caveats: `thinking low` is not expressible to this stack (the endpoint's default effort applies), `firstPromptTokens` is not captured, and the `turns` metric counts agent message events — not comparable 1:1 with the other lanes' turn semantics. Tool-surface note: the default agent set is three coding tools, notably leaner than Niffler's or Maki's surfaces and comparable to DSH-`sdk-minimal`'s bash-only lane.
