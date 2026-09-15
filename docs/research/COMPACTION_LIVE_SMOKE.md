# Live compaction smoke — 2026-09-15

## Setup

- Model: Synthetic `hf:openai/gpt-oss-120b` (provider response id
  `openai/gpt-oss-120b`), low thinking effort on ordinary turns.
- Native context: 131072 tokens according to Synthetic's catalog.
- **Artificial admission window: 16000**, output reserve 7000 (input target
  9000). This triggers pressure cheaply; it is not a native-limit overflow
  test and does not exercise the provider-overflow recovery branch.
- Private NATS and temporary root; real SQLite, runner, bash, llm, default
  compactor and recall components. No production store or bus was used.
- One autonomous turn reads an oversized archive followed by ten generated
  audit batches. Each batch result is below the 8192-character pruning
  threshold, so the live tool history accumulates until middle-span
  compaction is required. The original objective is `COPPER-42`.

Reproduce after `make build`:

```sh
SYNTHETIC_API_KEY=... NIF_SMOKE_KEEP=1 make live-smoke
```

`NIF_SMOKE_MODEL` and `NIF_SMOKE_CTX` override the model and artificial
window. This target is opt-in, spends real tokens, and is excluded from
`test-server`. Failure preserves the sandbox; all processes are stopped.
No credential is persisted in the sandbox or report.

## Result

**Passed.** Sandbox from the recorded run:
`/tmp/niffler-test-compaction-live-smoke-rOfDlKmX` (local artifact, not a
portable dependency). `metrics.json` contains context/status events;
`projection.json` holds the final checkpoint; `llm-before-restart.log`
contains adapter timing and auxiliary usage.

| Measurement | Observed |
|---|---:|
| Autonomous turn wall time | 33.98 s |
| Main completions, including restart continuation | 13 |
| Auxiliary summarization completions | 2 |
| Durable generation at end of audit | 2 |
| Explicit `reset:compact` events | 2 |
| Lossy `reset:trim` events | 0 |
| Largest provider-reported main prompt | 7066 tokens |
| Auxiliary prompt usage | 7065 / 6552 tokens |
| Auxiliary completion usage | 503 / 1057 tokens |
| Auxiliary adapter-reported duration | 1.858 / 4.520 s |
| Cached input across main completions | 28672 tokens |
| Second replacement: covered estimate → checkpoint estimate | 7077 → 628 tokens |

Adapter durations are its own streaming measurements, not full turn latency.
Checkpoint token counts are the runner's estimates; prompt/completion usage
above comes from the provider. Cache counters are observed accounting, not a
claim that every reset causes a complete cache miss.

All ten batch results were present in canonical history. After a full stack
restart, the continuation answered:

```text
Objective Code: COPPER-42
Completed Batches: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

The smoke normalizes ASCII versus typographic hyphens in the objective code
(the model can format `COPPER‑42` in Markdown). It does not normalize the
separate spill-content comparison.

Canonical message values from before restart remained byte-identical. A
**direct bus call** to `context_recall` after restart returned the full
archived spill exactly (apart from recall's documented trailing-newline
paging normalization). This verifies the resolver; it does not claim the
model autonomously chose to call recall.

## Defect found by the real provider

The first meaningful run failed when Synthetic rejected an auxiliary request
with HTTP 400: the tool description was null on the provider wire. The
compactor's formatter read `description` and `parameters` from the top-level
catalog entry, but frozen catalog entries carry them inside `schema`.
Consequently the auxiliary request also lost parameter definitions.

The default compactor now formats `schema` identically to ordinary turns,
retaining descriptions and parameters while stripping `x-harness` and the
duplicated parameter-level description. `t_compaction` compares the auxiliary
and main tool arrays, and requires a non-empty description, so the mock-based
suite now catches this regression. The live run above passed after the fix.

The expanded conformance restart check also found a checkpoint-only cut
whose persisted `covered.to` named the superseded `#ckN` node. The runner now
resolves checkpoint endpoints to their previous canonical coverage before
rendering and checking reduction. Both the ordinary fixture and a genuinely
shrinking checkpoint-only fixture pass second-generation reload; the live
run above was repeated on that corrected core.

The tool-schema fix affects only the auxiliary request. It does not rewrite a conversation's
frozen system prompt or direct tools; successful compaction remains an explicit
projection reset, with canonical history append-only.
