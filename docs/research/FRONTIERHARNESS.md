# FrontierHarness Eval — Niffler pilot (2026-10-05/06)

**Status: complete and deliberately stopped. Unranked matched-control comparison. No
further runs planned.** Everything on Runta is paused; no process is running.

## Summary

- Goal: put Niffler on [FrontierHarness Eval](https://frontierharness.org) (Runta's
  benchmark) against a matched Pi control, same model and same egress policy.
- Outcome: 2 of 30 published tasks × 2 harnesses, **all four cells solved (2/2 and
  2/2)**. The rig is fully validated: budget-matched model path, Harbor adapters,
  usage accounting, verifier-correct trials. DeepSWE coverage is blocked by
  infrastructure (below). True "ranking" is unreachable without the published
  baselines' egress policy (their own validity rule) or a published-harness
  calibration run.
- Spend: **$0.78 real / $1.35 conservative of the $10 Fireworks cap** (includes
  ≈$0.25 spent on the invalid plumbing attempts below). Runta compute ≈$1–2.
  Budget approved at $10 Fireworks / $15 overall — respected.

## Results (Kimi K3 · Fireworks standard · same guarded endpoint · same egress policy)

| task | Niffler 0.4.0 (`--thinking high`) | Pi 0.99.2 (default thinking) | baseline solve rate |
|---|---|---|---|
| `regex-log` (terminal-bench) | **1.0** · 6m 09s · ≈$0.25 | **1.0** · 3m 10s · ≈$0.11 | 11/12 |
| `openssl-selfsigned-cert` (terminal-bench) | **1.0** · 3m 23s · ≈$0.11 | **1.0** · 1m 55s · ≈$0.06 | 12/12 |
| **aggregate** | **2/2** | **2/2** | |

Usage per scored run (input includes cache reads):

| run | input | cached | output |
|---|---|---|---|
| Niffler · regex-log | 104,004 | 88,186 (85%) | 11,656 |
| Pi · regex-log | 23,573 | 16,444 (70%) | 5,267 |
| Niffler · openssl | 57,481 | 48,489 (84%) | 4,402 |
| Pi · openssl | 26,713 | 22,104 (83%) | 2,494 |

Pattern worth remembering: Niffler reasons hard (2–4× the tokens) but hides most of
it behind **~85% cache hits** (frozen prefix), so cost-per-task gap is ≈2× not 4×.
Pi is leaner and roughly 2× faster on tasks of this size.

## Methodology

- Harnesses: Niffler 0.4.0 @ `efa9836` (`cli run`, thinking `high` explicitly) ·
  Pi 0.99.2 (`@earendil-works/pi-coding-agent`, **pi's own default thinking** —
  thinking was on (reasoning traces observed) but not pinned to `high`; this
  asymmetry is a disclosed deviation).
- Model: `accounts/fireworks/models/kimi-k3`, Fireworks **standard** tier,
  $3 / $0.30 / $15 per 1M (input / cached input / output).
- Budget guard (`budget_proxy.py`): fail-closed request-level meter — worst-case
  reservation (full 1M-context bound + capped output) before forwarding, settles to
  measured provider usage, missing usage stays charged; campaign ledger
  (`evidence/ledger.jsonl`). Conservative column charges cached input at full rate,
  so it can only over-charge.
- Egress policy (identical for both harnesses and both tasks): default docker
  networking + Runta CA bundle; host `DOCKER-USER` drop to `api.fireworks.ai`
  (v4+v6) so the budget proxy is the **sole** billed path; real credentials never
  enter task containers (Runta injects at egress; containers get a stub).
- Pilot constraints (would need removal for leaderboard use): 16,384-token output
  cap through the proxy; asymmetric thinking configs; 1 trial/cell (matches the
  published k=1 design).

## Invalid attempts (excluded per FrontierHarness validity rules, ≈$0.25 total)

1. 4,096 output cap → all reasoning, zero content (`finish_reason=length`) — $0.068.
2. Verifier starvation: my internal-network lockdown broke `test.sh`'s verify-time
   `apt`/`uv` install → reward 0 written *before grading* (this is the exact failure
   mode FrontierHarness's CA-overlay note warns about) — $0.094.
3. Empty model endpoint `http://:19040` (in-container gateway introspection; task
   image has no `iproute2`) → fixed with `host.docker.internal` + `host-gateway`.
4. DeepSWE: Docker "conflicting options: custom host-to-IP mapping and the network
   mode" (`extra_hosts` + shared egress-sidecar netns) → fixed with a fixed-subnet
   overlay (guard at constant `172.31.250.1`).
5. DeepSWE: `nft: add table inet gost_egress → Not supported` — **this Runta kernel
   lacks nftables inet-family support**, so Harbor's egress sidecar (required by
   `allow_internet=false` tasks) cannot enforce at all. Unfixed.

Also fixed mid-flight: guard rejected Pi's content-parts arrays (text-only check →
accept pure-text parts, still refuse media), and the adapter now classifies
zero-provider-response runs as infrastructure exceptions instead of task failures.

## If a valid ranking is ever wanted (not pursued)

1. Full 30-task suite (21 terminal-bench + 9 deep-swe) × Niffler + one control, k=1
   → 60 runs. DeepSWE needs either Runta's egress sidecar working (ask them why
   `inet` nftables fails — their published runs must have enforced *something*) or
   the Pier path (`PierNiffler` scaffold exists in `niffler_adapter.py`).
2. Clear the unranked rule: get the published egress allowlist disclosed
   (FrontierHarness/Runta contact — they offer $100 compute credits and actively
   solicit harnesses), or run published **Pi v0.84.2** as a calibration and show it
   reproduces near its published score under our recorded policy.
3. Remove pilot constraints (output cap, thinking asymmetry).
4. Cost: model **$100–250** (~$150 plan; hard tasks run 45–180 min), Runta compute
   $10–40 (fits their credit), 15–30 h wall. 10-task subset ≈ $30–80 (`Provisional`).
   Recommendation was: spend ≈$3 on a Pi v0.84.2 calibration and ask Runta about
   the egress policy + sidecar kernel issue before committing.

## Artifacts

Committed copy: **`docs/research/frontier-eval/`** (report, evidence, rig scripts and
configs). The `var/frontier-eval/` directory is the disposable runtime working copy.

- Report (FrontierHarness presentation format):
  `docs/research/frontier-eval/report/report.md` + `measurement-notes.json`
- Evidence: `docs/research/frontier-eval/evidence/` (ledger, 4 × result.json,
  4 × verifier output)
- Rig: `docs/research/frontier-eval/{budget_proxy.py, usage_mapping.py,
  niffler_adapter.py, test_pilot.py (10 checks), mock_cli_check.py,
  container_mock_check.py, fireworks_smoke.py, prepare-niffler.sh,
  guarded-overlay*.yaml, harbor-*.json, probe-sidecar-*.json}`
- Runta: runtime `fh-niffler040-build` (4 vCPU / 8 GiB / 50 GiB, **paused**),
  checkpoint `fh-niffler040-plumbing-v1` (bundle sha256 `33c33e20…`, Niffler @
  `efa9836`, harbor 0.22.0, pier 0.3.1), job dirs
  `/work/jobs/{niffler040-regex-log-pilot4, pi099-regex-log-control3,
  niffler040-openssl1, pi099-openssl1}` on the runtime.
- Gotcha for resuming: `runta exec`/`cp` against a **paused** runtime returns
  `409 Conflict` — resume first, pause after.
