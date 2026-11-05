# full31 · Synthetic DeepSeek V4.1 Flash · Claude Code 2.1.286 vs 2.1.318

Two uncontended runs of the full31 suite on the same gateway, same model, same
effort, differing only in the Claude Code build:

| run | Claude Code | cells | pass | rounds | jobs |
|---|---|---:|---:|---:|---:|
| `full31-syn-ds41-claudecode-j1` | 2.1.286 | 31 | 31/31 | 1 | 1 |
| `full31-syn-ds41-claudecode-2318` | 2.1.318 | 31 | 31/31 | 1 | 1 |

Model `syn-deepseek-v41` (`hf:deepseek-ai/DeepSeek-V4.1-Flash`) at
`api.synthetic.new/anthropic`, thinking profile `low`
(`MAX_THINKING_TOKENS=2048`), rounds ≤6, 25 min per task. No invalid cells, no
leaked cells, every cell green in round 1 in both runs — the suite is saturated
for this model through this harness, so what follows measures shape, not
capability.

## Headline

**The upgrade is a prompt-prefix saving, not a capability or speed change.**

| metric (per cell) | 2.1.286 | 2.1.318 | Δ |
|---|---:|---:|---:|
| pass | 31/31 | 31/31 | — |
| wall clock | 33.7 s | 33.7 s | +0.0 |
| LLM messages (`turns`) | 12.3 | 14.1 | +1.8 |
| tool calls | 6.3 | 7.0 | +0.7 |
| **first prompt** | **10 855** | **9 222** | **−1 633** |
| prompt / cell (read+write+uncached) | 67.7k | 63.1k | −4.6k |
| cache read | 44.4k | 45.0k | +0.7k |
| cache write | 23.4k | 18.1k | −5.3k |
| uncached input | 0 | 0 | 0 |
| output | 1.06k | 1.19k | +0.13k |
| **cost / cell (Synthetic)** | **$0.0271** | **$0.0231** | **−$0.0040** |
| run cost (Synthetic) | $0.8395 | $0.7163 | −$0.1232 |
| run cost (first-party list) | $0.2653 | $0.2208 | −$0.0445 |
| diff | +74/−9 | +76/−9 | — |

## Why the cost falls but the clock does not

On Synthetic's Anthropic endpoint every prompt token is reported as a cache
**write** (`input_tokens == cache_creation_input_tokens`, reads are exclusive,
uncached input is 0), and writes bill at the $0.80/M prompt rate. So the cost
of a Claude Code cell is essentially *prefix size × calls*. 2.1.318 sends a
1 633-token smaller first request; multiplied by ~14 calls a cell that is the
entire −$0.004/cell, and it is why the run is 15% cheaper at identical wall
clock. The newer build spends slightly more calls and produces slightly more
text (output 1.06k → 1.19k), which offsets part of the prefix saving rather
than adding to it.

The first-prompt number is the one delta that is **deterministic**: 10 838–10 893
tokens across all 31 tasks at 2.1.286, 9 204–9 259 at 2.1.318 — the same
55-token spread in both, i.e. the task prompt plus nothing variable. Everything
else at cell granularity is noise, and swings both ways: t31-tinyrename +43.7k
total tokens, t06-stackvm +34.1k, against t07-validate −30.6k, t20-jsonpatch
−25.9k, t23-mergesched −25.5k. Treat the −4.6k mean as one sample.

## What changed in the harness surface

Read from the `system/init` frame each invocation emits:

- **Tools 20 → 22**: 2.1.318 adds `Monitor` and `ToolSearch`; the rest of the
  set is unchanged (`Task`, `Bash`, `Cron{Create,Delete,List}`, `Edit`,
  `EnterWorktree`, `ExitWorktree`, `ListAgents`, `NotebookEdit`, `Read`,
  `ReportFindings`, `ScheduleWakeup`, `SendMessage`, `Skill`, `TaskStop`,
  `WebFetch`, `WebSearch`, `Workflow`, `Write`).
- **Builtin plugins 2 → 3**: `cc-plugin-privacy` joins `cc-plugin-agents-md`
  and `cc-plugin-plugin-authoring`.
- Slash commands 45 → 44.

So two *more* tool schemas ship in a prefix that is 15% *smaller*: the
per-tool payload and the base prompt were trimmed harder than the new tools
cost. Tool mix per cell moved with it — `Read` 1.55 → 2.16, `Bash` 3.39 → 3.48,
`Edit` 0.74 → 0.65.

## Where this lane sits (same model, same gateway)

The rows below share the model and the gateway. The Claude Code rows are
the two runs here (`jobs 1`); the other three are the 29 Oct 2026 three-lane run
([analysis](full31-syn-ds41-droid-analysis.md)), whose concurrency is not
recorded in its committed report — compare its **tokens and cost** with ours
freely, but read its wall clock as indicative. Cost is the Synthetic catalog
basis.

| lane | pass | wall | turns | tool calls | prompt / cell | cost / cell | first prompt |
|---|---:|---:|---:|---:|---:|---:|---:|
| pi | 31/31 | 24.4 s | 5.3 | 5.0 | 21.2k | $0.0083 | — |
| niffler | 31/31 | 29.5 s | 6.5 | 7.6 | 38.3k | $0.0134 | 3 056 |
| droid (BYOK) | 31/31 | 30.2 s | 1.9 | 8.3 | 69.0k | $0.0161 | 69 025 |
| claudecode 2.1.286 | 31/31 | 33.7 s | 12.3 | 6.3 | 67.7k | $0.0271 | 10 855 |
| **claudecode 2.1.318** | 31/31 | 33.7 s | 14.1 | 7.0 | 63.1k | **$0.0231** | **9 222** |

Claude Code is the most expensive lane on **both** cost bases (first-party
list: $0.2208/run against niffler's $0.1578 and droid's $0.1332), and it is not
the smallest prompt — Droid's is seven times larger. The difference is that
Claude Code makes the *most* calls (14.1 against droid's 1.9, which batches
~4.4 tool calls per message against Claude Code's 0.5), so it re-bills its
prefix 7× more often. Prefix size sets the per-call price; round trips set how
many times you pay it.

The same trade the Droid run found, one lane over: **a bigger prefix is
survivable if you batch harder; a small prefix is wasted if you round-trip.**

## Notes for whoever re-runs this

- The adapter (`bench/adapters/claudecode.mjs`) is unchanged; this is a pure
  CLI-version comparison. Bump with
  `npm i -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest`
  — the `allow-scripts` flag is required, otherwise the postinstall never
  fetches the platform-native binary and `claude` fails with "native binary not
  installed".
- A first, contended run (`full31-syn-ds41-claudecode`, `--jobs 2`) produced
  the same 31/31 with the same cells passing in round 1; it is not published
  because its wall times are contended. Use `--jobs 1` for anything quoted.
- `[footprint] … exceeds budget 7000` fires on every cell in both versions —
  expected for this lane and not a failure; the budget is a warning.
- **The CLI version is not recorded in the artifacts**, which is a gap worth
  closing in the adapter: `system/init` carries `tools`, `plugins` and
  `slash_commands` but no `version` field, and `result.json`/`report.{md,csv}`
  consequently do not name the build. Both runs here were bracketed by
  `claude --version` (`2.1.286` before, `2.1.318` after the upgrade) and the
  tool list in every cell's `round-1.log` confirms it (20 tools vs 22), but a
  report alone cannot tell you which binary produced it — capture
  `claude --version` per combo before trusting a cross-version comparison.
- `total_cost_usd` from Claude Code's own result event remains ignored; the
  cost columns come from the shared price table (`bench/config.json` prices
  live in `bench/adapters/*.mjs`; the Anthropic-dialect write rate is the
  prompt rate, per Synthetic's published catalog).
