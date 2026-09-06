# DeepSWE (Datacurve) — benchmark port

[DeepSWE](https://github.com/datacurve-ai/deep-swe) by Datacurve AI is a
benchmark for frontier coding agents: **113 original, long-horizon software
engineering tasks** drawn from active open-source repositories, with isolated
environments and behavior-based verifiers. This directory ports it into the
`bench/run.mjs` comparison framework, next to `bench/swe/` (SWE-bench
Verified) and the 17 custom tasks in `bench/tasks/`. First cross-harness
pilot results: [PILOT.md](PILOT.md) (niffler 3/10, opencode 1/10, pi 0/10 on
deepseek-v4-flash, one-shot).

**Name collision warning.** There are two unrelated things called DeepSWE:

| | what it is |
|---|---|
| **DeepSWE (Datacurve)** — this directory | a *benchmark*: 113 tasks, Harbor format, verified by held-out tests |
| **DeepSWE-Preview (Agentica)** | a *model*: Qwen3-32B RL-trained agent (rLLM/R2E-Gym), scored **on** SWE-bench Verified (42.2% pass@1, 59% with test-time scaling) |

When writing reports, always say "DeepSWE (Datacurve)" or "DeepSWE-Preview
(Agentica)" — never bare "DeepSWE".

## DeepSWE (Datacurve) vs SWE-bench Verified

| | SWE-bench Verified | DeepSWE (Datacurve) |
|---|---|---|
| Tasks | 500 real GitHub issues (2012–2023) | 113 **original curated** tasks on active repos |
| Languages | Python only, 12 repos | TypeScript 35, Python 34, Go 34, Rust 5, JavaScript 5 |
| Horizon | issue→patch, 15–45 min typical | long-horizon feature/bug specs, agent window up to **3 h** |
| Grading | FAIL_TO_PASS / PASS_TO_PASS via official swebench harness | same concept (`f2p_node_ids` / `p2p_node_ids`), via shared `grader.py` in a **separate verifier container** |
| Solution accepted | any patch passing hidden tests | same, explicitly behavioral (any correct implementation, reference solution never used at grading) |
| Environment | `/testbed` image per instance | prebuilt agent image per task (public ECR, ~0.8–1 GB compressed), deps installed, **no-network agent** |
| Contamination | public for years, gold patches in dataset | original tasks, tests + solutions held out |
| Runner | `swebench==4.1.0` Docker harness | Harbor task format, run by [Pier](https://github.com/datacurve-ai/pier) (Harbor fork; per-agent network allowlists) |
| Official protocol | `--rounds 1` one-shot | one-shot, agent commits its work, collect hook extracts `git diff --binary <base> HEAD` |

## Task anatomy (Harbor format, per task)

```text
task.toml         metadata: repo, base commit, language, agent image, limits,
                  [verifier] network_mode/environment_mode/timeout, [[verifier.collect]]
instruction.md    the prompt the agent sees (verbatim in our prompt.md)
environment/      Dockerfile reproducing the prebuilt ECR agent image
tests/            HELD OUT: test.sh (entry), grader.py (shared), test.patch,
                  config.json (f2p/p2p whitelists), Dockerfile (verifier image)
solution/         HELD OUT: solution.patch + solve.sh (offline review only)
```

Verifier flow (we run it **unmodified** inside Docker):

1. agent works in the task env, commits its work;
2. `[[verifier.collect]]` extracts `git diff --binary <base> HEAD` → `model.patch`;
3. verifier container (task image + hidden tests): `grader.py prepare` resets
   per-file and applies `model.patch` + `test.patch` to pristine `/app`;
4. task-specific `test.sh` runs the suites with CTRF/JUnit reporters;
5. `grader.py grade` computes `reward.json`: `reward` = 1 iff every f2p id
   passes and no p2p id fails; plus f2p/p2p fractions and a `partial` score.

## Pipeline (mirrors bench/swe/)

```bash
# 1. Clone the benchmark repo and emit task cards (all 113 by default).
node bench/deepswe/import.mjs --out var/bench/deepswe/tasks-deepswe.jsonl \
     [--lang go,python] [--tasks id1,id2] [--limit N]

# 2. Create base-only agent checkouts + hidden cards, optionally pre-pull
#    the ECR agent images (~1 GB compressed each; verifier builds need them).
node bench/deepswe/prepare.mjs --input var/bench/deepswe/tasks-deepswe.jsonl \
     --out var/bench/deepswe/tasks --pull-images

# 3. Run cells like any other bench family (canonical = one-shot).
node bench/run.mjs --task-root var/bench/deepswe/tasks --task all \
     --harness niffler,pi,opencode --model deepseek-v4-flash \
     --rounds 1 --jobs 2 \
     --turn-timeout-min 185 --task-timeout-min 200 --test-timeout-sec 2000 \
     --run-id deepswe-<sha>
```

Files generated under `var/bench/deepswe/` (gitignored, `make clean` wipes):
`upstream/` (shallow clone of datacurve-ai/deep-swe — held-out tests +
solutions live here, agents never see it), `mirrors/` (upstream repo
mirrors), `tasks/` (the task root handed to run.mjs), `evaluations/`
(per-verify reward.json + ctrf.json + run.log). Hidden cards default to
`~/.cache/niffler-deepswe/cards/`.

### Status: verified end-to-end (2026-09-05, etree-xml-diff-patch, Go)

- trivial non-solution change → `f2p 0/52, p2p 15/15`, unresolved (exit 1);
- gold `solution.patch` → `f2p 52/52, p2p 15/15`, `reward 1`, resolved (exit 0);
- verifier image build ≈ 1 min after the agent image is pulled; suites ≈ 1 min.

## Protocol notes / deviations

- **`--rounds 1` is canonical.** Multi-round feedback would feed hidden-test
  failure output back to the agent — report any such run as non-canonical
  (same rule as SWE-bench).
- **Host workspace, not a container.** DeepSWE's official protocol runs the
  agent inside a no-network container. We hand agents a plain git checkout on
  the host (like bench/swe), with "no network / no test runs / stay in repo"
  rules in the prompt. This is test hiding, not a hostile-process sandbox.
- **Commit protocol.** The official instruction asks agents to commit their
  work; verification diffs against the `base` tag, so committing or not makes
  no difference to grading.
- **Protected files.** Paths touched by `test.patch` are marked protected in
  `meta.json`; touching them marks the run invalid even if grading passes.
- **Resource limits.** verify.mjs applies the task card's verifier limits
  (`--cpus 2 --memory 8192m --network none` default) and a hard container
  timeout (`NIF_DEEPSWE_HARNESS_TIMEOUT_MS`, default verifier timeout + 120 s).

## Costs (measured / estimated)

- Agent images: 0.77–1.04 GB compressed each (sampled 5); all 113 ≈ 120 GB
  compressed, plan ~250–350 GB uncompressed. Pull per-wave and prune.
- Verifier timeout 1800 s/task; agent window up to 3 h/task (realistically
  20–60 min). 113 tasks × 3 harnesses ≈ multi-day at `--jobs 2`.
- Long-horizon → expect ~2–4 M tokens/task; order 0.5–1 B tokens per harness
  for the full set. Pilot with 10–15 tasks across the 5 languages first.

## Running remotely (wowbagger / Arcane / chetter)

The bench is "node + git + docker + API keys", so it packages as a job
container with Docker-out-of-Docker (DooD) — the same pattern chetter already
uses on the wowbagger box (`/var/run/docker.sock` mounted into runners):

- **Machine**: wowbagger = Netcup vServer, Ubuntu 24.04, ~500 GB disk,
  **15 GB RAM** — verifier containers want up to 8 GB, so verification must
  run serially or 2-wide at most; 500 GB disk fits ~2 waves of images with
  pruning.
- **Packaging**: a `niffler-bench` image (node 22 + git + docker CLI + the
  niffler repo + `var/bin` + nats-server + harness CLIs, or derived from
  chetter's `chetter-agent-base` which already ships pi/opencode/codewhale),
  run with the host docker socket mounted + API keys via env file.
- **Trigger**: Arcane project / `docker compose run bench --run-id X …` over
  ssh, or `arcane-cli`; results land in a named volume, reports sync back
  (`bench/report.mjs` runs anywhere on a copied run dir).
- **MCP**: either a small bench tool inside chetter (it is already an MCP
  server with runner containers on that host) or a standalone stdio MCP
  wrapper that shells the same compose-run command — lets the agent kick off
  and poll runs conversationally.
