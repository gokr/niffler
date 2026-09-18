# batch-open-3 consolidation summary

The three slices left open by the dead batch-3 run: **component: llm** (12 rows),
**Background processes (processes)** (9) and **Observation and logs** (7) — 28 rows
total, every one re-verified against the current `docs/MANUAL.md` (2850 lines) and
the current code.

| status | count |
|---|---|
| apply | 18 |
| already | 8 |
| skip | 2 |
| code | 0 |
| unclear | 0 |

Every `old_string` was checked against the current `docs/MANUAL.md` (all 18 occur
exactly once) and the whole set was dry-run applied in id order to a copy of the
manual — no apply-time collisions, no overlapping anchors.

## applied edits (18)

| id | where | what |
|---|---|---|
| A383 | `MANUAL.md:64` | the `llm` shipped-components row: names all three hidden tools (`chat`, `llm_resolve`, `llm_models_source`) instead of only `chat` |
| A384 | :687 | `llm_resolve` also returns output provenance, `protocol`, `authType`, `hasKey` — and fails without a resolvable credential |
| A385 | :691 | new Context-window bullet for the **output** window (`outputSource`, catalog `limit.output`, the deliberate 32768 default, `maxTokens` only lowering it, Codex ignoring it) |
| A390 | :699 | `reasoning_effort` is sent only when non-empty, and how each lane spells it (Codex `reasoning`, Anthropic `thinking`+`output_config.effort`) |
| A391 | :537 | cancellation is armed only for a streamed call and honors `cancelId` (compaction's independent subject) |
| A392 | :529 | the "who passes `emitTokens: false`" parenthetical was wrong (compaction does; the expert judge passes `stream: false`; hooks never call `chat`) — corrected |
| A395 | :540 | new paragraph: replayed assistant `tool_calls` arguments are repaired before they are sent (text only, never executed) |
| A396 | :2057 | the live model-id source is named (`llm_models_source`) with its bounds (10-min TTL per provider+baseURL, 8 s probe, memory-only, Codex excluded, `no live model data yet`) |
| A399 | :376 | what `accountId` is (ChatGPT account id for the Codex lane, JWT-derived) and the failure text when neither record nor token has one |
| A388 | :1073 | §Output caps and `finish_reason`: the Anthropic lane always gets `max_tokens`, the Codex lane gets no cap, Codex `max_output_tokens`/`response.incomplete` map onto `length`, unknown reasons pass through (also carries A389) |
| A285 | :1499 | "no timeout applies" -> applies to the *job*; the starting `bash` call is still bounded (dispatch budget + the 15 s `process_start` request) |
| A452 | :1460 | `process_kill`: SIGTERM, 300 ms grace, then SIGKILL |
| A454 | :1487 | the owner-less case is any `process_start` that is not `bash run_in_background` (the model's `invoke`, `cli`, a script) |
| A455 | :1495 | "Processes die with the harness" -> they die when the component stops; a SIGKILLed component leaves them to the next start's sweep |
| A012 | :38 | the `components/` layout row names the two directories that are not bus citizens (`nats`, `ctxtest`) |
| A236 | :2234 | §Boundary gains the negative half: "Not an audit trail" (observe is an in-memory ring, logfile best-effort, console forgets, hooks record nothing; only the `approval` grant record and `var/approval-sources/` persist) |
| A238 | :2260 | `observe_monitor` row marked approval-gated like the other three |
| A241 | :1170 | the hooks section gains its verification line (`make test-hooks`, `tests/t_hooks.nim`) — scoped to what the test really covers |

## already (8)

`A059` (dup of the mechanisms.md approvals row; the processes table already matches
`components/processes/main.nim:491-530`), `A060`, `A061`, `A062` (first-wave
verified rows — spool caps, exit notice, process group/`/dev/null` all still
accurate), `A291` (auditor's FIX was "none"), `A239` (the trusted-bus-peer claim
matches the design; the optional input-validation clause is implementation detail),
`A240` (verified: `NIF_OBSERVE_MONITOR_URL`, fresh HTTP client per request),
`A397` (`x-harness.runner` is documented at `MANUAL.md:1729`, added by the
exposure-flags pass, ledger A114).

## skip (2)

- `A119` — same finding as A012 (the two reports repeat each other); folded into
  A012's edit of the `components/` row.
- `A389` — folded into A388's edit of the same paragraph; a second edit would have
  needed the same anchor.

## not a doc edit (left for the parent / code)

1. **`lengthCap` keys on the provider *name*, not the catalog provider**
   (`components/llm/main.go:816-822`): any DeepSeek-backed endpoint stored under a
   nickname other than `deepseek` (or an `NIF_LLM_PROVIDERS` key that is not
   literally `deepseek`) receives `max_completion_tokens`, which DeepSeek ignores —
   the deliberate output cap silently becomes the server default. A388 documents the
   spelling, but the routing is a code fix.
2. **`process_start` has no owner-session plumbing for non-bash callers**
   (`components/processes/main.nim:491-503` — no `x-harness.sessionId`, and only
   `bash` passes `session`): a process started by the model's own `invoke`, by `cli`
   or by a script can never raise an exit notice. A454 documents the limitation;
   the capability gap is code (the bash pattern — `x-harness.sessionId: true` plus
   the runner-injected `__session` — would generalize).
3. **`x-harness.runner` is wider than the MANUAL/AGENTS.md sentence**
   (`core/dispatch.nim:1525-1550`): the exemption applies to any session's `tools`
   allowlist, and `chat` plus `put`/`get`/`list`/`del` are exempt by name. Either
   the sentence at `MANUAL.md:1729` or the code's scope needs an explicit decision.
4. **Stale phrasing inside component strings** (code, out of scope here): the
   `process_start` LLM-facing description and `process_list`'s `note` both still say
   "Processes die with the harness" (`components/processes/main.nim:498`, `:435`) —
   the same overstatement A455 just fixed in the MANUAL.
5. `A390`'s second half (the `session` schema enum listing only `low/medium/high`)
   is **already fixed in code**: `core/catalog.nim:197` enumerates `max` and
   `core/conversation.nim:2858` accepts it.

## verification performed

- `python3 scratch-audit-build.py` (all 18 `old_string`s occur exactly once),
  `python3 scratch-audit-verify.py` (dry-run apply in id order against a copy: no
  collisions, 216-line diff reviewed). Both scratch scripts and their outputs were
  deleted after the run.
- Code read for every row: `components/llm/{main,codex,anthropic,models_source}.go`,
  `components/processes/main.nim`, `components/bash/main.nim`,
  `components/{observe,console,hooks}/main.nim`, `components/compaction/main.nim`,
  `components/expert/main.nim`, `core/{dispatch,catalog,conversation,approval}.nim`,
  `tests/t_hooks.nim`, `Makefile`.
