# Docs audit — `components/compaction/` (Nim, 308 lines: `main.nim`)

Scope: what the component offers, its tool and flags, its configuration, and how
`docs/MANUAL.md` covers it. Read-only audit; every claim carries file:line.
Component version `0.1.0` (`components/compaction/main.nim:206`), registered tool
`compaction_propose` (`main.nim:219`).

Audited revision: `docs/MANUAL.md` @ `a66dbfa` (3072 lines). The audit set's
rule applies — the quoted text is the durable anchor; the line numbers are that
revision's, and the manual was still being edited by the parallel consolidation
pass while this report was written.

## 1. What it offers

`compaction` is the *default* implementation of the runner's replaceable
summarization seam ("contract v1"). The split is stated in the component's own
header: the runner owns budgets, valid cuts, validation and the projection
commit; the component "reads the temporary referenced snapshot, chooses one of
the runner's permitted cuts, asks llm for a structured checkpoint, and returns a
candidate" (`main.nim:1-8`). It never writes `conversation` or
`context_projection`, never executes tool calls found in history, and uses a
distinct auxiliary session id so cancellation and accounting cannot alias the
parent turn (`main.nim:1-8`).

The whole job is one handler (`main.nim:220-303`) doing four things:

- **(1)** Verify the snapshot. `readSnapshot` (`main.nim:64-105`) reads
   `compaction_input:<metaId>` plus its `:p<idx>` pages through the store tool
   (`main.nim:66`, `main.nim:82`) and re-verifies every integrity check the
   runner wrote: contract version 1 (`main.nim:70-71`), the manifest digest
   recomputed with the same separator encoding the runner used (`main.nim:18-25`,
   `main.nim:73-77`, runner side `core/conversation.nim:1390-1398`), page count
   and per-page `index`/`bytes`/`digest` (`main.nim:78-88`), the concatenated
   `contentBytes` length (`main.nim:89-90`), and then that every content row is
   bound to its manifest entry by `index`/`source`/`id`/`contentHash`
   (`main.nim:91-104`). A torn or tampered snapshot is an error, never a
   best-effort read. The runner repeats the binding check on commit
   (`core/conversation.nim:1618-1630`).
- **(2)** Choose a permitted cut. `chooseCut` (`main.nim:107-121`) picks the
   permitted boundary whose `tailTokens` is nearest
   `budget.preferredTailTokens`, falling back to
   `meta.target.preferredTailTokens`; it never invents a boundary — the set
   comes from `permittedCuts` in the runner (`core/compaction.nim:83-124`,
   called at `core/conversation.nim:1474`). The runner publishes
   `preferredTailTokens = max(target div 5, 1)` and `0` when the window is
   unknown (`core/conversation.nim:1502-1504`), so an unknown capacity selects
   the *most* aggressive permitted cut.
- **(3)** Summarize once. It rebuilds the parent's prefix (the frozen system
   prompt from `meta.systemPrompt`, `main.nim:241-246`; the frozen catalog tool
   schemas re-shaped into provider form by `formatTools`, which strips
   `x-harness` and `description` from `parameters`, `main.nim:29-48`,
   `main.nim:282`), adds the covered rows (`main.nim:255-258`), and for a
   middle-span autonomous cut carries the previous checkpoint's normalized data
   explicitly (`main.nim:247-254`). The instruction message forbids executing
   anything in the history and demands exactly one JSON object with the six
   contract fields plus optional `files` (`main.nim:259-266`). Then exactly one
   auxiliary `chat` call (`main.nim:280-290`): `stream: true`,
   `emitTokens: false`, `purpose: "compaction"`, `maxTokens =
   max(budget.maxSummaryTokens, 128)` (`main.nim:277`) and
   `sessionId = cancelId = "compaction.<convId>.<attemptId>"` (`main.nim:278-279`).
   A returned tool call is refused outright (`main.nim:291-294`); the reply body
   is fenced-JSON-tolerant (`parseCheckpoint`, `main.nim:50-62`).
- **(4)** Answer or decline. `{"version":1,"status":"candidate",…,"provenance":
   {"model":…,"llmCalls":1}}` (`main.nim:296-303`), or one of the three stable
   declines `no-useful-cut` / `indivisible` / `input-budget-exceeded`
   (`main.nim:123-126`, `234`, `238`, `276`) which the runner's validator
   whitelists (`core/compaction.nim:197`, `core/compaction.nim:226-232`).

**Concurrency boundary.** The component is single-threaded but cannot use
`Component.request` for the auxiliary call: its own handler is the thing that
would block, so `auxiliaryChat` (`main.nim:161-203`) runs its own reply
subscription and a 25 ms poll loop that also drains `cancel.compaction`,
relaying a cancellation of the parent turn to `llm.cancel.<cancelId>`
(`main.nim:134-141`, `main.nim:185-190`) and publishing that cancel on timeout
(`main.nim:202-203`). The runner's timeout path publishes exactly that subject
with the parent session id (`core/dispatch.nim:1336-1349`), and `llm` keys its
cancel subscription on `cancelId` when present (`components/llm/main.go:470-480`).

**Where the component is live.** `manifest.yaml:77-86`: `autostart: true`,
`required: false`, `restart: on-failure`, binary `var/bin/compaction`. Absent or
killed, nothing else changes: the runner's rung is skipped and prune → trim →
`context-recovery-required` still run (`core/conversation.nim:1447-1449`,
`core/conversation.nim:1983-1986`, `core/conversation.nim:2084-2087`).

## 2. Tools

One tool, `compaction_propose` (`main.nim:219`).

| Field | Value |
|---|---|
| Component / version | `compaction` `0.1.0` (`main.nim:206`) |
| Tool name | `compaction_propose` (`main.nim:219`) |
| Description (LLM-invisible, but it is the contract text) | "Runner-owned context recovery seam. Reads the referenced verified snapshot and returns one structured checkpoint candidate or a stable decline. This is an internal runner tool, not a user summarization command." (`main.nim:215`) |
| Required args | `version`, `sessionId`, `attemptId`, `snapshot`, `budget` (`main.nim:214`); `trigger` is declared as an enum `["pressure","overflow","manual"]` but never read by the handler (`main.nim:211`, and no other occurrence of `trigger` in the file) |
| `x-harness` (verbatim) | `{"hidden": true, "runner": true, "timeoutMs": 120_000, "effect": "read"}` (`main.nim:216-217`) |
| Exposure | **hidden** — never in a conversation's direct set, never listed by `discover` (`core/catalog.nim:431-433` skips hidden tools; `core/catalog.nim:468-475` skips them in explicit lookups), never reachable through `invoke` (`core/dispatch.nim:288-290`), never reachable through the fabric nested proxy (`core/dispatch.nim:1255-1257`). Only a component or a runner can call it directly over `svc.compaction.call` (MANUAL.md:1869-1870) |
| Approval / workspace / parallel | none — no `approval`, no `workspace`, no `parallel`, no `sessionId`-driven injection (it receives the parent id in the body, `main.nim:209`) |

**How the runner finds it.** By *tool name*, not by component name. The runner
resolves the configured name in the catalog (`ct.cat.toolSchema(cfg.tool)`,
`core/conversation.nim:1447` and `core/conversation.nim:2965`) and dispatches it
(`ct.dispatchToolCall(cfg.tool, request, cfg.timeoutMs)`,
`core/conversation.nim:1568`), which maps name → owning component via
`catalog.toolIndex` and publishes to that component's `svc.<comp>.call`
(`core/dispatch.nim:1615-1617`, `core/dispatch.nim:1674-1690`). Core contains no
reference to the string `compaction` as a component anywhere. Consequence:
replacing the summarizer is registering *any* tool under the configured name
(`NIF_COMPACTION_TOOL`), exactly as `manifest.yaml:79-80` says; if no such tool
is registered the rung is simply skipped (`core/conversation.nim:1447-1449`) and
`/compact` reports it (`core/conversation.nim:2965-2969`).

**How it passes a frozen tool allowlist.** `hidden` + `runner: true` is the
exemption the dispatch gate implements (`core/dispatch.nim:1522-1548`), which is
why a replaced compactor keeps working in a subagent session whose `tools` list
was frozen before it existed. The `runner` flag alone is not enough — the gate
requires `hidden` too (`core/dispatch.nim:1544-1546`).

## 3. Configuration

**The component itself reads no environment variable at all.** `grep -n
'getEnv\|NIF_' components/compaction/main.nim` returns nothing: its effective
limits arrive in the request (`budget`, `snapshot`) and its only constants are
compile-time. Everything below is therefore *runner-side* configuration that
shapes the call.

- `NIF_COMPACTION_TOOL` — tool name the runner selects; default
  `compaction_propose`; empty disables summarization while keeping the
  deterministic guard (`core/compaction.nim:47`; consumers
  `core/conversation.nim:1447`, `core/conversation.nim:1984`,
  `core/conversation.nim:2965`). An unparseable/unknown name behaves like empty
  for the automatic ladder and produces the same `/compact` error.
- `NIF_COMPACTION_TIMEOUT_MS` — default `90000`, clamped `5000..600000`
  (`core/compaction.nim:48`, `core/compaction.nim:52-53`,
  `core/compaction.nim:61`). Two consumers: it is the **dispatch** budget
  (`core/conversation.nim:1568`) and the **contract** value handed to the
  component as `budget.timeoutMs` (`core/conversation.nim:1563`), which the
  component passes to its own auxiliary-chat deadline (`main.nim:290`).
- `NIF_COMPACTION_MAX_LLM_CALLS` — default `4`, clamped `1..16`
  (`core/compaction.nim:49`, `core/compaction.nim:54-55`,
  `core/compaction.nim:62`). It is enforced only *after the fact*, as a claim
  check on `provenance.llmCalls` (`core/conversation.nim:1608-1616`) and as the
  multiplier behind `budget.maxTotalInputTokens` / `maxTotalOutputTokens`
  (`core/conversation.nim:1560-1562`). The shipped component never reads
  `maxLlmCalls` and always reports `llmCalls: 1` (`main.nim:302`) — it makes
  exactly one auxiliary call by construction (`main.nim:268-270`).
- `NIF_COMPACTION_MAX_SUMMARY_TOKENS` — default `2048`, clamped `128..32768`
  (`core/compaction.nim:50`, `core/compaction.nim:56-58`,
  `core/compaction.nim:63`); shipped as `budget.maxSummaryTokens`
  (`core/conversation.nim:1558`) and floored again at 128 in the component
  (`main.nim:277`).
- Runner-owned contract constants the manual's "replaceable" sentence does not
  name: snapshot page size 512000 bytes (`core/compaction.nim:22`), orphaned
  snapshot sweep grace 600 s (`core/compaction.nim:26`; used at
  `core/conversation.nim:1420-1436`, `core/conversation.nim:2683`), checkpoint
  bounds `objective`/list items ≤ 4000 chars, lists ≤ 32 items, `files` ≤ 64,
  encoded checkpoint ≤ 65536 bytes (`core/compaction.nim:29-32`,
  `core/compaction.nim:296-324`), and the render template id `checkpoint-v1`
  (`core/compaction.nim:33`, `core/compaction.nim:150-180`).
- `budget` fields the runner grants but the shipped component ignores:
  `targetInputTokens`, `fixedPrefixTokens`, `maxTotalOutputTokens`,
  `maxLlmCalls` (`core/conversation.nim:1555-1564`); it also ignores
  `snapshot.canonicalHigh` (`core/conversation.nim:1551-1553`) and the request's
  `trigger`. It consults `maxTotalInputTokens` (`main.nim:271-276`),
  `maxSummaryTokens` (`main.nim:277`), `timeoutMs` (`main.nim:290`) and
  `preferredTailTokens` (`main.nim:107-121`) only.
- **Effective call timeout is not `NIF_COMPACTION_TIMEOUT_MS` above 120 s.** The
  runner passes `cfg.timeoutMs` as the *default*, but `dispatchToolCall`
  overrides it with the schema's `x-harness.timeoutMs` whenever present
  (`core/dispatch.nim:1631-1642`), and the component declares `120_000`
  (`main.nim:216-217`). So the runner abandons a candidate at 120 s no matter
  how large the configured value is, while the component's own auxiliary
  deadline keeps running to `budget.timeoutMs` (up to the 600000 clamp). The
  snapshot then survives until the 600 s sweep (`core/compaction.nim:26`), which
  is exactly the grace the runner's timeout comment relies on
  (`core/conversation.nim:1569-1575`).
- No `NIF_*` variable selects the model or provider for the auxiliary call: it
  goes through the `llm` component with the parent's frozen tool schemas and the
  runner's conversation model (`main.nim:280-290`), i.e. the summarizer bills
  the conversation's own model.
- `.env.example:157-167` already lists all four `NIF_COMPACTION_*` variables.

## 4. How the MANUAL covers it today

There is **no section** for the compaction component. It appears in five places:

* MANUAL.md:78 — the shipped-components row (the only description):
  "default replaceable `compaction_propose` implementation: verifies
  runner-owned paged snapshots, chooses a permitted cut, and returns a
  structured checkpoint candidate; the runner alone validates and commits
  projections".
* MANUAL.md:440-443 — the four environment rows.
* MANUAL.md:714-719 — the `/compact` bullet under
  "### Conversation controls: `/approvals`, `/limit` and `/compact`".
* MANUAL.md:844-852 — the "replaceable" bullet of "## Context window".
* MANUAL.md:853-857 (reset reasons), 1867 (the `runner` exemption), 2061-2067
  (the hidden-tool list), 2893-2894 (the `compaction_input` /
  `context_projection` store rows), 2911-2945 (Testing).

What is **missing**: the tool's name, exposure and call shape in the tool
inventory (the manual's hidden-tool list does not name `compaction_propose`);
the request/response contract a replacement must implement (snapshot
verification, the three stable declines, `llmCalls: 1`, the single auxiliary
call and its `cancelId`); the checkpoint's field set and bounds; the
runner-owned render frame the model actually sees (`<context_checkpoint
generation="N" covered="A..B">` plus a "Recall ref: {"source":"checkpoint",
…}" line, `core/compaction.nim:150-180`); the `ev.session.context` reasons for a
failed/declined/invalid/stale attempt; that `compaction_input` is transient; the
upper clamps of the three numeric variables; and how to verify a replacement
(`make test-compaction`, `make test-conformance`, `make live-smoke`).

What is **stale or wrong**: the timeout row's "whole candidate-call deadline"
(see the 120 s schema cap above), and the `x-harness.runner` sentence at
MANUAL.md:1867, which cites "(compaction, recall)" as runner-exempt machinery —
true for this component, false for `recall` (see the recall report).

## 5. DELTA list

## Layout of a running system

- MANUAL: "default replaceable `compaction_propose` implementation: verifies runner-owned paged snapshots, chooses a permitted cut, and returns a structured checkpoint candidate" | CODE: `components/compaction/main.nim:64-105` (verification), `main.nim:107-121` (cut choice), `main.nim:296-303` (candidate) | FIX: none — verified accurate, including "the runner alone validates and commits projections" (`core/conversation.nim:1591-1593`, `core/compaction.nim:201-330`).
- MANUAL: "default replaceable `compaction_propose` implementation" | CODE: `components/compaction/main.nim:216-217`, `core/catalog.nim:431-433`, `core/dispatch.nim:288-290` | FIX: add — after the sentence, state the exposure: "The tool is `hidden` + `x-harness.runner: true` (timeout 120 s, read-effect): never offered to a model, never listed by `discover`, never reachable through `invoke` — only a runner or another component calls `svc.compaction.call` directly. With the component absent or killed, summarization is simply off and the remaining ladder — lossless prune, then the lossy fallback rung, then `context-recovery-required` — still runs."

## Context window

- MANUAL: "tool-result prune → configured compactor → oldest complete-turn trim →" | CODE: `core/conversation.nim:879-924` (admission prune), `:1983-1986` (pressure rung), `:926-947` (trim), `:2084-2087` (overflow rung) | FIX: none — verified accurate.
- MANUAL: "The shipped `compaction_propose` is replaceable: set" | CODE: `core/compaction.nim:47`, `core/conversation.nim:1447`, `core/conversation.nim:2965` | FIX: add the selection mechanics — "The value is a **tool name**, not a component name: the runner resolves it in the catalog and dispatches to whichever component registered it, so a replacement can live in any component (`manifest.yaml:79-80`). An empty or unregistered value skips the rung in the automatic ladder and makes `/compact` answer `compacted: false` with `reason: "no compaction component available (NIF_COMPACTION_TOOL=<value>)"`."
- MANUAL: "`NIF_COMPACTION_TOOL=<tool>` to select another contract-v1 implementation," | CODE: `components/compaction/main.nim:207-303` | FIX: add a contract summary a replacement must satisfy — "A contract-v1 candidate tool receives `{version: 1, sessionId, attemptId, trigger, snapshot, budget}` and answers either `{version, status: "declined", attemptId, reason}` with one of the three stable reasons (`no-useful-cut`, `input-budget-exceeded`, `indivisible`) or `{version, status: "candidate", attemptId, baseGeneration, snapshotDigest, cutBefore, covered, checkpoint, provenance:{model, llmCalls}}`, where `checkpoint` carries exactly `objective`, `constraints`, `decisions`, `completedWork`, `currentBlocker`, `nextSteps` and optional `files`. The runner rejects anything else as invalid and falls through to trim; `provenance.llmCalls` above the granted `NIF_COMPACTION_MAX_LLM_CALLS` is invalid too."
- MANUAL: "temporary paged `compaction_input` snapshot, validates the candidate's" | CODE: `core/compaction.nim:22`, `core/compaction.nim:29-33`, `core/compaction.nim:296-324`, `core/conversation.nim:1533-1538` | FIX: add the bounds — "Snapshot pages are 512000 bytes, so one huge message cannot oversize a bus message; the checkpoint is bounded (objective and list items ≤ 4000 characters, ≤ 32 list items, ≤ 64 files, ≤ 65536 bytes encoded) and is rendered by the runner-owned `checkpoint-v1` template — a candidate stored by one compactor reloads identically under another."
- MANUAL: "generation/digest/cut/schema/size and strict reduction, then commits one" | CODE: `core/compaction.nim:143-148` (`strictlyReduces`), `core/conversation.nim:1649-1656` | FIX: add — "Strict reduction is measured by the runner (the rendered checkpoint's *estimated* tokens must be below the covered span's), never taken from the component's claim; the covered nodes are also re-hashed against the snapshot before the projection is committed (`core/conversation.nim:1618-1630`)."
- MANUAL: "never writes conversation or projection records." | CODE: `components/compaction/main.nim:66`, `main.nim:82` (the only store calls are two `storeGet`s of `compaction_input`) | FIX: none — verified accurate.
- MANUAL: "conversation (compaction passes `emitTokens: false`; the expert judge's call is" | CODE: `components/compaction/main.nim:286-287` (`"emitTokens": false, "purpose": "compaction"`) | FIX: none — verified accurate.
- MANUAL: "reserved for an actual sticky tool-schema promotion. These are the only" | CODE: `core/conversation.nim:1720-1726` (event fields `generation`, `covered`, `beforeTokens`, `afterTokens`), `:1575`, `:1597`, `:1603`, `:1616`, `:1629`, `:1652` | FIX: add — "The compaction rung also emits non-reset `ev.session.context` reasons: `compact:failed` (dispatch error or timeout), `compact:declined` (with `detail` = the stable reason), `compact:invalid` (schema/bounds/claimed-call-budget/strict-reduction), and `compact:stale` (the covered span changed under the attempt). None of them rebuilds the prompt prefix; the successful event carries `generation`, `covered`, `beforeTokens` and `afterTokens`."
- MANUAL: "`NIF_COMPACTION_TIMEOUT_MS`" (its row says "whole candidate-call deadline (minimum 5000 ms) | `90000`") | CODE: `core/compaction.nim:48`, `core/compaction.nim:52-53`, `core/compaction.nim:61`, `components/compaction/main.nim:216-217`, `core/dispatch.nim:1631-1642` | FIX: update — "`NIF_COMPACTION_TIMEOUT_MS` | whole candidate-call deadline; clamped to 5000-600000, but the call's `x-harness.timeoutMs` caps the runner's wait at 120000, so values above 120 seconds only extend the component's own auxiliary deadline (the runner gives up first and the snapshot waits for the 600 s sweep) | `90000` |" — or fix the component's schema so the two agree.
- MANUAL: "whole candidate-call deadline (minimum 5000 ms)" | CODE: `components/compaction/main.nim:216-217`, `core/compaction.nim:61`, `core/dispatch.nim:1637-1642` | FIX: either raise `components/compaction/main.nim`'s `x-harness.timeoutMs` to core's 600000 clamp or clamp `NIF_COMPACTION_TIMEOUT_MS` at 120000 in `core/compaction.nim:61` — the documented "whole candidate-call deadline" is not true above 120 s today (code bug in the contract's own bounds; no test covers a >120 s configuration).
- MANUAL: "auxiliary summarization call budget granted to one attempt; a candidate reporting more calls than granted is rejected as invalid" | CODE: `core/conversation.nim:1608-1616`, `components/compaction/main.nim:280-290`, `main.nim:302` | FIX: add — "The shipped component always makes exactly one auxiliary call and reports `llmCalls: 1`; the budget exists for a summarizer that iterates. The granted count also scales `maxTotalInputTokens` and `maxTotalOutputTokens` in the request's `budget`."
- MANUAL: "per-call checkpoint output cap" | CODE: `core/compaction.nim:63`, `components/compaction/main.nim:277` | FIX: update — "per-call checkpoint output cap, clamped to 128-32768 and floored again at 128 by the shipped component | `2048`".
- MANUAL: "Hidden takes precedence if both flags are present. A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist" | CODE: `core/dispatch.nim:1544-1546`, `components/compaction/main.nim:216` | FIX: none — verified accurate for this component (the exemption requires `hidden` **and** `runner`, checked at dispatch); but see the recall report: the sentence's example list "(compaction, recall)" is wrong about `recall`.
- MANUAL: "Internal tools remain hidden: core `session`/`session_prepare`, store" | CODE: `components/compaction/main.nim:216` | FIX: add `compaction_propose` to that list (and, for symmetry, the recall resolver is *on demand*, not hidden) — "Internal tools remain hidden: core `session`/`session_prepare`, store `del`, LLM `chat`/`llm_resolve`, the compaction `compaction_propose`, the systemprompt prompt, …".

## Approvals

- MANUAL: "automatic pressure ladder: core asks the configured compaction component for" | CODE: `core/conversation.nim:2957-2986` | FIX: none — verified accurate (no LLM turn, no user message, a decline never degrades to the lossy rung).
- MANUAL: "before/after token counts, or `compacted: false` with the reason (no" | CODE: `core/conversation.nim:2965-2969`, `core/conversation.nim:2983-2986` | FIX: update — "The reply reports `compacted: true` with `beforeTokens`, `afterTokens` and `generation`, or `compacted: false` with exactly two possible reasons: `no compaction component available (NIF_COMPACTION_TOOL=<value>)` (empty or unregistered) or `nothing to compact: the compactor declined or no permitted cut exists yet` — the second also covers a failed, invalid or stale candidate attempt."

## The bus in one screen

- MANUAL: "ev.session.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}" | CODE: `core/conversation.nim:1720-1726`, `:839-841`, `:850-857` | FIX: update — "`ev.session.context {sessionId, turnId?, promptTokens, usedTokens, context, reason?, warning?|trimmed?, bytesSaved?, pruned?, trimAt?, reserveTokens?, generation?, covered?, beforeTokens?, afterTokens?}` — `reason` is one of `warn:threshold`, `reset:prune`, `reset:trim`, `reset:compact`, `compact:failed|declined|invalid|stale`, `context-overflow`".

## The store

- MANUAL: "the paged pre-compaction snapshot the compaction component verifies and the runner commits from" | CODE: `core/conversation.nim:1405-1418` (`cleanupSnapshot`), `core/compaction.nim:26` (600 s sweep), `core/conversation.nim:2683` | FIX: add — "transient: deleted as soon as the attempt settles, and orphaned pages from a crashed or timed-out attempt are swept after 600 seconds. Nothing must treat it as durable; only `context_projection` is."
- MANUAL: "the committed context projection (cut, checkpoint, generation) a runner reuses after compaction" | CODE: `core/compaction.nim:333-360` (`buildProjectionRecord`), `core/conversation.nim:1684-1693` (single `expectRev` put), `core/conversation.nim:2677-2748` (reload) | FIX: add — "one document per conversation, holding `version`, `generation`, `canonicalHigh`, the renderer id, the normalized `checkpoint`, the durable `covered` canonical range, the `retained` canonical id list, `prunes`, `measurements` and `provenance`; it is written once with `expectRev` on the previous generation and is the source of truth a restart rebuilds the provider view from."
- MANUAL: absent (a candidate that names a generation/digest the runner no longer holds) | CODE: `components/compaction/main.nim:229-232` | FIX: add — "A snapshot whose `attemptId`, `digest` or `generation` does not match the request is refused with a stale-snapshot error rather than summarized; the runner drops the attempt."

## Testing

- MANUAL: "Each test boots the real component binaries (Nim, Go *and* TypeScript —" | CODE: `Makefile:447` (wildcard suite includes `tests/t_compaction.nim`), `Makefile:544` (`make test-compaction`), `Makefile:548` (`make test-conformance --bin=PATH --tool=NAME`), `Makefile:552` (`make live-smoke`), `tests/t_compaction_conformance.nim:99-141` | FIX: add — "The compaction contract has its own verification: `make test-compaction` runs the end-to-end restore/commit/resume fixtures, `make test-conformance --bin=<binary> --tool=<name>` points the same contract suite at a replacement compactor (the acceptance test for a third-party summarizer), and `make live-smoke` exercises real summarization against a real provider (network, opt-in). None of the three is part of `make test-server`."
- MANUAL: absent (nothing in the manual says which test owns this component's behaviour) | CODE: `tests/t_compaction.nim:123-215`, `tests/t_ctxcompact.nim`, `tests/compaction_live_smoke.nim:105-159` | FIX: add — a one-line coverage note in the new component section: "Coverage: `tests/t_compaction.nim` (snapshot/validation/commit/restart/second generation), `tests/t_ctxcompact.nim` (ladder, lossy-fallback durability, recall round-trip), `tests/compaction_live_smoke.nim` (real provider)."

## Self-extension and component lifecycle

- MANUAL: "or set it to empty to disable summarization while keeping the deterministic" | CODE: `core/conversation.nim:1447-1449`, `:1984`, `:2965` | FIX: none — verified accurate (empty name ⇒ the rung returns false immediately).

Finding count: 25 rows — 15 `doc-edit` (11 additions to existing text + 4 corrections), 2 `missing` (a capability absent from the MANUAL, both landing in the new component section), 7 `verified` (nothing to change), 1 `code-bug?` (the `x-harness.timeoutMs` 120 s cap against core's documented 600 s clamp — its `FIX: either … or` wording is deliberate). The two `MANUAL: absent` rows are the only ones with no quotable MANUAL text, so they carry no re-anchor.

## 6. Contract details a replacement implementer should read (not user-facing)

Not in the MANUAL and not really prose it needs, but worth stating once: the
component's only output surface is the JSON above; the model never sees it. What
the *model* sees is the runner's render (`core/compaction.nim:150-180`), so any
replacement that returns a valid checkpoint produces the identical frame — the
frame is deliberately runner-owned and versioned (`rendererId = "checkpoint-v1"`,
`core/compaction.nim:33`) so generations stay reloadable across implementations.
The two contract details most likely to bite a replacement: (1) the manifest
digest must be recomputed with `\x1f`/`\x1e` separators over
`source|id|contentHash` in order (`main.nim:18-25`,
`core/conversation.nim:1390-1398`); (2) `cutBefore`/`covered` must echo the
runner's own boundary objects verbatim from `permittedCuts` — the validator
compares ids *and* sources and rejects anything it cannot re-derive
(`core/compaction.nim:243-283`).
