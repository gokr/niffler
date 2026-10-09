# FrontierHarness Eval — third-party reproduction

`UNRANKED` `MATCHED CONTROL` `2/30 TASKS` `KIMI K3 · FIREWORKS STANDARD` `1 TRIAL/CELL`

## Result

| Harness | Pass | Cost / task | Median job time |
|---|---|---|---|
| **Niffler 0.4.0** | 2/2 (100%) | ≈$0.18 | 4m 46s |
| **Pi 0.99.2** | 2/2 (100%) | ≈$0.09 | 2m 32s |

## Comparison

| Harness (config) | Pass | Cost total | Input | Cached | Output | Thinking |
|---|---|---|---|---|---|---|
| Niffler 0.4.0 | 100% | ≈$0.36 | 161,485 | 84.5% | 16,058 | `high` (explicit) |
| Pi 0.99.2 | 100% | ≈$0.17 | 50,286 | 76.7% | 7,761 | default (on, level n/a) |

## Task results

| Task (suite) | Niffler 0.4.0 | Pi 0.99.2 | Baseline solve rate |
|---|---|---|---|
| `regex-log` (terminal-bench) | **1.0** · 6m 09s · ≈$0.25 | **1.0** · 3m 10s · ≈$0.11 | 11/12 |
| `openssl-selfsigned-cert` (terminal-bench) | **1.0** · 3m 23s · ≈$0.11 | **1.0** · 1m 55s · ≈$0.06 | 12/12 |
| `httpx-multipart-response-parsing` (deep-swe) | `BLOCKED-INFRA` | `BLOCKED-INFRA` | — |

## Qualifications

- `Provisional` — 2 tasks × 1 trial; near-ceiling task difficulty.
- `Unranked` — published baselines' egress policy unrecorded; matched candidate/control only.
- `Deviations` — 16,384-token output cap via budget guard; asymmetric thinking configs.
- `Coverage` — deep-swe 0/9: runta kernel lacks nftables inet family (`add table inet gost_egress … Not supported`); Harbor egress sidecar required by `allow_internet=false` cannot enforce.
- `Excluded` — 5 infra_invalid attempts (output cap truncation, verifier starvation, empty endpoint, Docker host-mapping conflict, nft sidecar failure). Zero graded effect; ≈$0.25 retained spend.

## Method labels

`model accounts/fireworks/models/kimi-k3` `tier standard` `pricing $3 / $0.30 / $15 per 1M (in / cached / out)` ·
`egress default+CA · api.fireworks.ai fenced · budget proxy sole billed path (identical both harnesses)` ·
`env runta 4 vCPU / 8 GiB · harbor 0.22.0 · task 2 vCPU / 8 GiB` ·
`times job wall time incl. setup + verifier` · `costs measured provider usage, cached at cached rate`

## Sources

FrontierHarness Eval v1.0 · <https://github.com/frontier-harness-eval/eval> @ `e837a70` · benchmark definition `benchmark.json` · task corpus `terminal-bench@2.0` @ `69671fba`.
Evidence: `evidence/` (ledger, per-trial results, verifier outputs) · checkpoint `fh-niffler040-plumbing-v1` · runta job dirs `/work/jobs/{niffler040-regex-log-pilot4,pi099-regex-log-control3,niffler040-openssl1,pi099-openssl1}`.
