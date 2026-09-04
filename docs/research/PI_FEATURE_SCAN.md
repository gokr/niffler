# Pi Feature Scan

> Research note — a feature-level sweep of pi (github.com/earendil-works/pi) for
> capabilities worth borrowing into Niffler. Companion to
> [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md) / [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md)
> (token + wall-clock focus, basis `96317e50b`) and [MCP.md](MCP.md) (already
> planned — not re-litigated here). Three areas are deliberately out of scope:
> MCP, LLM compaction (Phase-2 A1), and long-term memory — for the last one
> note up front that **pi has no LTM subsystem to borrow** (only project-trust
> "remembered" decisions and session search; `grep -rn 'memory' packages/*/src`
> finds nothing else).
>
> Basis: pi at `6aedd1066` (pulled 2026-09), Niffler at `bda35b7`. Every claim
> below is grounded in a file path (ground-truth index, §7); pi docs are cited
> as `coding-agent/docs/*.md`, source as `agent/src/…` etc. under
> `packages/`. One nomenclature warning: pi renamed things since the last
> scan — "extensions" load in-process there (Niffler's components are the
> process-isolated equivalent), and pi's new "harness" is a durable-runtime
> spec, not a launcher.

## 0. Method

All 11 packages read: docs first (`packages/*/docs`, `packages/*/README.md`),
then source where a doc claims a behavior. A feature qualifies if it is (a) not
already in PI_EFFICIENCY_FINDINGS/PLAN, (b) not MCP/compaction/LTM, and (c)
either absent in Niffler or strictly behind pi's version of it. Each item names
the Niffler-shaped mechanism that would carry it — a component, an
`x-harness.*` schema extension, a store kind, or a WIRE change — per
[ARCHITECTURE.md](../ARCHITECTURE.md).

## 1. What changed in pi since the last scan

The prior scan read a pi whose notable subsystems were compaction, cache-stats,
retry, parallel tool execution, and the session tree. The current tree adds a
second architectural wave:

| Addition | Where | One-line summary |
|---|---|---|
| **Durable AgentHarness** (WP00–WP09) | `agent/docs/harness.md` (1468 lines), `work-packages/` | Conversations as a write-once entry tree + operations that survive process death: intent → effect → settlement, tool checkpoints, replay policy |
| **Chord** | `chord/README.md`, `agent/docs/plugins.md` | Facet/service/replicated-state composition runtime; delta-tracked state sync, transport-independent |
| **Routed protocol + client + server** | `protocol/README.md`, `client/README.md`, `server/README.md` | Versioned envelopes (CBOR), `{serverId, sessionId, attachmentId}` routing, multi-presentation attachment |
| **SQLite session backend** | `session-backends/sqlite-node/README.md` | One `SessionRepo` interface, JSONL ↔ SQLite ↔ memory interchangeable |
| **Session search interface** | `agent/src/search/index.ts` | `searchSessions/searchEntries/sync/notify/remove` contract (impl skeleton, design-first) |
| **Telemetry contracts** | `telemetry/README.md` | Vendor-neutral explicit-context spans with typed schemas; no global state, adapters for OTel |
| **Evals package** | `evals/README.md` | Model-backed behavioral evals over real `AgentSession` runs, artifacts = session JSONL |
| **Deferred tool loading** | `coding-agent/docs/extensions.md` "Dynamic Tool Loading", `ai/src/utils/deferred-tools.ts` | Mid-conversation tool activation with native `defer_loading`/`tool_search` support |
| **Radius relay** | `coding-agent/src/experimental/radius-relay.ts` | WebSocket relay attaching remote presentations to a local server (auth + attachment routing) |

Unchanged philosophy: pi still deliberately ships no built-in MCP, subagents,
permission popups, plan mode, todos, or background bash
(`coding-agent/docs/usage.md` "Design Principles").

## 2. Tier 1 — borrow (high value, architectural fit)

### 2.1 Durable tool lifecycle: replay classification + checkpoints

Pi `agent/docs/tool-durability.md`, implemented under `agent/src/harness/execution/`:

- every tool declares `replay: "safe" | "never"`; the harness persists exact
  validated args (`pi.op.tool_args/…`) **before** effect admission;
- tools may opt into **durable progress checkpoints** — the latest complete
  bounded `onUpdate` snapshot lands at `pi.pending.tool_output/…`, so a crash
  mid-effect produces a synthetic interrupted result carrying that snapshot
  instead of replaying or inventing (`tool-durability.md` §0.5 worked example);
- parallel outcomes settle in completion order into `pi.pending.entry`
  (`outcome_ready`) and materialize into the transcript in assistant source
  order only when every earlier position is ready — a crash never re-runs a
  mutation whose finalized outcome is durable.

Why it matters here: this is the same problem family as Niffler's deferred
"durable-agent hardening" (fabric time budgets, kill-on-timeout semantics) and
the store-v2 branch ([STORE_V2.md](STORE_V2.md)). Niffler already has the
transport for it — store docs with revisions, a single-writer store, and
`ev.*` events — it lacks only the *discipline*.

Niffler shape, smallest-first:

1. `x-harness.replay: "safe" | "never"` in the catalog schema (default
   `"never"` for bash/edit, `"safe"` for grep/git/read). The runner's
   kill-on-timeout path can then *state* what happened ("effect possibly
   applied, not replayed") instead of silently abandoning it.
2. Bash already spills full output to `var/toolout/<session>/` — promote that
   spill pointer to a store doc so it survives the runner (today it is
   path-only knowledge in the transcript).
3. Checkpoints + `outcome_ready` ordering belong with the store-v2 SQLite
   engine (transactional writes make the two-commit settlement natural;
   barrel can emulate with put-only-after-settlement).

Effort: step 1 small, the rest large. Fold into the store-v2 branch rather
than shipping piecemeal.

### 2.2 Deferred tool loading (cache-preserving dynamic toolsets)

Pi keeps tools *registered but inactive*; a loader tool activates them with
`pi.setActiveTools()`, and pi records the activated names **on the loader's
tool result** (`message.addedToolNames`). On the next request the schemas are
injected at the *tool-result position* — natively for capable providers
(Anthropic `defer_loading`/`tool_reference`; OpenAI `tool_search_call` /
`tool_search_output`), with a fallback that just re-sends the full active list
(`ai/src/utils/deferred-tools.ts` `splitDeferredTools`, compat flags
`supportsToolReferences`/`supportsToolSearch`).

This is the direct upgrade path for Niffler's `discover`/`invoke`
([MANUAL.md#progressive-tool-discovery](../MANUAL.md#progressive-tool-discovery)):
today the model must funnel every on-demand call through the fixed `invoke`
gateway with hand-built JSON args. pi's model instead *promotes the schema
into the toolset at a cache-stable anchor point*, so later calls are ordinary
native tool calls — better tokens (no invoke indirection), better cache (prefix
byte-stable; schemas appended mid-history), and no lost provider-side
validation.

Niffler shape: a new exposure level between "direct" and "on demand" —
`x-harness.loadable: true`. WIRE implications (spec before coding): the
runner's request builder needs an "activate" reply type on a tool result, the
frozen-toolset doctrine gets one sanctioned mid-conversation mutation point
(recorded in history), and the Go llm adapter needs the two compat passthroughs
plus schema-at-message-position for Anthropic/OpenAI. Core policy unchanged:
approvals, timeouts, hidden-tool refusal still consult the full catalog.

Effort: medium. The cache payoff compounds with everything else (A1 compaction
included — pi runs them together for this reason).

### 2.3 Project trust gate

Pi asks before loading *project-local* settings, packages, resources, and
extensions; decisions persist per folder (parent folders included) in
`~/.pi/agent/trust.json`; non-interactive modes take `defaultProjectTrust:
ask|always|never`; `--approve`/`--no-approve` override one run; `/trust` saves
the decision (`coding-agent/src/core/project-trust.ts`, `trust-manager.ts`;
`coding-agent/docs/usage.md` "Project Trust").

Niffler has the identical surface, unguarded: cloning a repo as harness home
auto-loads `manifest.yaml` (component autostart) and `plugins` restores
records — arbitrary code from an untrusted checkout. The harness already
distinguishes *its own* home (self-extension is the point); what is missing is
a decision boundary for *foreign* homes/manifests.

Niffler shape: a trust marker under `var/` (or the conversation-independent
`NIF_TRUST` env for headless) consulted at boot before manifest autostart and
plugin restore; `core.spawn` of manifest components gated the same way;
approval machinery (`core/approval.nim`) reused for the interactive ask.
Effort: small–medium; mostly policy wiring, no new transport.

### 2.4 Session tree: labels, navigation, forks, lanes (C1, restated richer)

Already planned as C1 in [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md); what
the new pi adds on top:

- **labels** on entries (`LabelEntry`, `coding-agent/docs/session-format.md`)
  with tree filtering (`no-tools` / `user-only` / `labeled-only` —
  `settings.md treeFilterMode`) — cheap, makes long trees navigable;
- **`/clone`** — duplicate the active branch into a new session file, distinct
  from `/fork` (new session from an earlier user message) and `/tree`
  (in-place branch switch) (`coding-agent/docs/sessions.md`);
- **fork policy as a module** (`agent/src/harness/session/fork.ts`,
  `fork-policy.ts`) and WP07/WP08: SQLite host-ownership rules for live forks,
  named branches with streaming copies — the durable-harness answer to "two
  processes, one history";
- **AgentLanes** (`agent/docs/harness.md` Part 2): multiple named lanes over
  one shared entry tree, each with its own model config and queues. This is
  the cleanest model seen anywhere for Niffler subagents that *share* a
  conversation's history (today `agent` subagents fork copies; lanes would let
  a subagent append to a bounded lane of the parent tree).

Niffler shape: store entries gain `parentId` (revisioned docs already support
it), the runner gains navigation; labels and filters are store projections.
Lanes are a fabric/agent design question — keep in the C1 design note, not a
quick patch. Effort: large overall; labels are the small on-ramp.

## 3. Tier 2 — cheap, high utility

### 3.1 Shell session environment injection

`coding-agent/docs/environment-variables.md`: commands run by the `bash` tool
receive `PI_SESSION_ID`, `PI_SESSION_FILE`, `PI_PROVIDER`, `PI_MODEL`,
`PI_REASONING_LEVEL`, resolved per command. Niffler's bash injects nothing
(`components/bash/main.nim` passes the ambient env only).

Niffler shape: `NIF_SESSION_ID`, `NIF_MODEL`, `NIF_PROVIDER`,
`NIF_REASONING_LEVEL` on the child process of `bash` calls dispatched from a
session (the values ride the call envelope's `__session` context already).
Scripts can then self-report or call back (`cli call …`) without the model
smuggling IDs into command strings. Effort: hours. Do not inject into
component-to-component calls — session context there is already explicit
(`x-harness.sessionContext`).

### 3.2 User prompt templates

`coding-agent/src/core/prompt-templates.ts`, `docs/prompt-templates.md`:
markdown files with frontmatter (`description`, `argument-hint`), expandable as
`/name args`, with bash-style substitution — `$1`, `$@`/`$ARGUMENTS`,
`${N:-default}`, `${@:N}` slicing. Niffler has skills (prose loaded on demand)
but no parameterized prompt shortcuts.

Niffler shape: a small `prompts` capability beside `skills` (same discovery
pattern, store the catalog in the skills component or its own component), or a
`skill` frontmatter extension if component count is a concern. Effort: small.

### 3.3 Provider robustness details (beyond shipped retry)

`coding-agent/docs/settings.md` (Retry + Message Delivery sections),
`ai/src/types.ts` (`Transport = "sse" | "websocket" | "websocket-cached"`):

- **retry-after cap** (`retry.provider.maxRetryDelayMs`, default 60s): a
  server-requested delay above the cap fails the request with a clear error
  instead of silently sleeping — the quota-reset trap. Niffler's
  `core/retry.nim` backoff has no server-delay ceiling.
- **stream idle timeout** (`httpIdleTimeoutMs`) and **transport selection**
  for the Go llm adapter.
- **cache retention knob** (`PI_CACHE_RETENTION=long`) for providers with
  extended cache TTLs — pairs with the existing cache-waste reporting (A3 ☑).
- **context-overflow classification** (`ai/src/utils/overflow.ts`): distinct
  error class for "prompt too long", which is precisely the trigger A1's
  compaction component needs; today Niffler treats it as a generic llm error.

Effort: each item small; overflow classification first (A1 dependency).

### 3.4 Model policy layer

`coding-agent/docs/settings.md` (Model & Thinking, Model Cycling),
`core/model-resolver.ts`:

- thinking-level vocabulary `off|minimal|low|medium|high|xhigh|max` with
  **per-model startup levels** (`modelThinkingLevels`) and **token budgets per
  level** (`thinkingBudgets` — mapped to provider fields via
  `compat.thinkingTokenBudgetField`);
- **model cycling**: `enabledModels` glob patterns, one-keyboard-shortcut
  rotation mid-session (pi Ctrl+P; for Niffler a UI affordance over the same
  policy).

Niffler passes `reasoning_effort` through (`core/conversation.nim:805`) but has
no level vocabulary, budgets, or rotation. Niffler shape: policy fields in the
`models`/`provider` components + a `thinking` session knob; the llm adapter
maps level→provider field. C2 (scoped/cheap models per phase) remains the
bigger sibling of this. Effort: small–medium.

### 3.5 Session export / import / share

`core/export-html/` (self-contained HTML with tool renderers and vendored
ansi-to-html), `/import` JSONL resume, `/share` secret-gist upload with viewer
URL (`coding-agent/docs/sessions.md`). Niffler's only transcript path is the
cli recipe in AGENTS.md.

Niffler shape: an on-demand `export` component reading a conversation from the
store (the AGENTS.md recipe, automated) → single-file HTML; import is the
reverse (JSONL → store messages) and also the natural backup format. `/share`
equivalent = upload the HTML; no new primitives. Effort: small–medium.

### 3.6 Behavioral evals

`evals/README.md`: model-backed behavioral checks (vitest-evals) — each eval
binds a harness config, runs a real `AgentSession` in an isolated project dir,
attaches the session JSONL as an artifact, and judges with a model.

Niffler has strong bus-contract tests and mock-LLM loop tests (`ctxtest`,
`tests/t_expert.nim`, `t_fabric`), but nothing scores *behavior* (does the
agent actually use discovery? does it recover from a trimmed context?) across
real models. Niffler shape: a `make eval` target driving real sessions through
`svc.core.call` probes against a chosen provider, artifacts = store
transcripts (already queryable via cli), judge = a second llm call. The store
keeps the eval history. Effort: medium; do after A1 so evals can assert on
compaction behavior too.

## 4. Tier 3 — keep in view

- **Hooks with teeth** — pi's `tool_call` event **patches arguments in place
  or blocks** (`{block, reason, terminate}`); `tool_result` handlers chain
  middleware-style and can rewrite results (`extensions.md` "Tool Events").
  Niffler's `hooks` is deliberately observe-only
  (`components/hooks/README.md`); a veto/rewrite layer would need its own
  design note (interaction with `core/approval.nim`, ordering, and who owns
  the mutated args in the audit trail). Prior art recorded here, not endorsed.
- **Usage ledger** — `agent/docs/harness.md` Part 1: append-only per-session
  cost rows (input/output/cache per response) in the same store as the
  conversation. Niffler's `logfile` is diagnostic and age-capped; a durable
  per-conversation ledger (store rows, surfaced in the conversation header)
  makes cost reporting and budget policies real. Cheap once store-v2 lands.
- **Chord's replicated state + delta ops** — `chord/README.md`: producers
  mutate a tracked JSON proxy and publish compact path-coded deltas; consumers
  rehydrate from snapshots. NATS already gives Niffler transport and routing;
  the borrowable *idea* is delta-tracked live state for the web UI transcript
  (bandwidth + render cost), fitting the Level-1/2 UI-dynamism work in
  [PLAN.md](../PLAN.md).
- **Session search service** — `agent/src/search/index.ts`
  (`searchSessions/searchEntries/sync/notify/remove`). The interface shape is
  the deliverable; Niffler's version belongs to the TiDB/FTS store-v2 quest
  (vector + FTS over `kind=message`).
- **System-prompt override knobs** — `AGENTS.override.md` per-directory
  override, `SYSTEM.md` (replace) / `APPEND_SYSTEM.md` (append),
  `--no-context-files` (`coding-agent/docs/usage.md` "Context Files"). Trivial
  additions to `components/systemprompt`.
- **Plugin supply-chain policies** — root `README.md` "Supply-chain
  hardening": exact-pinned deps, `min-release-age`, lifecycle-script
  allowlist, scheduled audits. Niffler's `plugins` (GitHub clones) + `builder
  lang: "ts"` (npm install) own the same surface; minimum viable version: pin
  refs (already required), document an npm lifecycle-script stance.
- **Remote presentation relay** — `experimental/radius-relay.ts`: authenticated
  WebSocket relay attaching remote UIs to a local server with attachment
  routing. Niffler version = expose the bus over WSS with auth; relevant only
  if remote control becomes a goal.
- **TUI portables** — themes/keybinding files, autocomplete providers,
  footer-data-provider pattern (`packages/tui/README.md`,
  `core/footer-data-provider.ts`): only relevant if `niffler-tui` grows a
  conversation mode; recorded for then.

## 5. Not worth borrowing (and why)

| Pi thing | Why not |
|---|---|
| In-process extension API (`pi.registerTool`, in-process hooks) | Niffler's components-as-processes *is* the stronger version; the borrowable parts (2.2, 4.1) are extracted above |
| pi-protocol CBOR framing | Niffler has a one-wire spec (NATS JSON envelopes, `docs/WIRE.md`); a second framing is architecture debt |
| Chord facet loader / host graph | NATS queue groups + the supervisor + `core.spawn` cover the same lifecycle; replicated state (4.x) is the only portable piece |
| TUI framework | Wrong layer for core; see Tier-3 portables |
| Background bash, plan mode, todos, MCP-in-core | pi deliberately ships none; Niffler's gaps there are covered by its own plans (MCP.md, fabric) |
| SQLite-in-process session storage *as such* | Parity: [STORE_V2.md](STORE_V2.md) already plans three engines behind one contract |

Parity notes so the doc doesn't overclaim gaps: bash output spill-to-temp-file
is shipped (`components/bash/main.nim` — plan item A4 done); retry, cache
reporting, usage-accurate accounting, runner fan-out, replicas, and concurrent
Go tools are ☑ per [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md).

## 6. Suggested order (impact ÷ effort)

| # | Item | Niffler shape | Effort | Depends on |
|---|---|---|---|---|
| 1 | §3.1 shell session env | `components/bash` env | hours | — |
| 2 | §2.3 project trust | boot policy + `core/approval.nim` reuse | small | — |
| 3 | §3.3 overflow classification | `core/retry.nim` error class | small | — |
| 4 | §2.2 deferred tool loading | WIRE spec + runner + llm compat flags | medium | cache doctrine (shipped) |
| 5 | §2.1 replay flag | `x-harness.replay` | small | — |
| 6 | §3.2 prompt templates | skills-adjacent component | small | — |
| 7 | §3.4 model policy | models/provider components | small–med | — |
| 8 | §2.1 checkpoints + settlement, §4 usage ledger | store v2 | large | store v2 branch |
| 9 | §2.4 session tree (+labels first) | store `parentId` + runner nav | large | A1 machinery |
| 10 | §3.5 export/import | on-demand component | small–med | — |
| 11 | §3.6 evals | `make eval` + store artifacts | medium | A1 (to be assertable) |
| 12 | §4 hooks-with-teeth, §4 chord-state, §4 search | design notes first | — | — |

Items 8, 9, and the search interface fold into the open store-v2 /
durable-hardening work rather than standing alone.

## 7. Ground-truth index

| Claim | pi evidence | Niffler evidence |
|---|---|---|
| Durable operations, three stores | `agent/docs/harness.md` Parts 0–3 | [STORE_V2.md](STORE_V2.md); `core/session.nim` (resume-from-store) |
| Tool replay + checkpoints | `agent/docs/tool-durability.md`; `agent/src/harness/execution/tools.ts` | — |
| Assistant frame persistence | `agent/docs/assistant-durability.md` | — |
| Bound values/lists, usage ledger | `agent/docs/values.md`; `harness.md` Part 1 | `components/store/main.nim` (no list-append, no ledger) |
| Deferred tool loading | `coding-agent/docs/extensions.md` "Dynamic Tool Loading"; `ai/src/utils/deferred-tools.ts`; `compat.supportsToolReferences/ToolSearch` | `docs/MANUAL.md#progressive-tool-discovery` (`discover`/`invoke` gateway) |
| Project trust | `coding-agent/src/core/project-trust.ts`, `trust-manager.ts`; `docs/usage.md` | manifest autostart + plugin restore, ungated (`core/supervisor.nim`, `components/plugins/`) |
| Session tree, labels, `/tree` `/fork` `/clone` | `docs/sessions.md`; `core/session-manager.ts`; `docs/session-format.md` | linear `kind=message` sequence |
| Lanes / named branches / live forks | `harness.md` Part 2; `agent/src/harness/session/fork.ts`; `work-packages/07…08` | `components/agent` (copy-fork subagents) |
| Shell session env | `docs/environment-variables.md` | `components/bash/main.nim` (no injection) |
| Prompt templates | `core/prompt-templates.ts`; `docs/prompt-templates.md` | — |
| Retry-after cap, transports, cache retention | `docs/settings.md` Retry/Message Delivery; `ai/src/types.ts:110` | `core/retry.nim` (backoff, no server-delay cap) |
| Overflow classification | `ai/src/utils/overflow.ts` | generic llm error path |
| Thinking levels/budgets, model cycling | `docs/settings.md`; `core/model-resolver.ts` | `core/conversation.nim:805` (`reasoning_effort` passthrough only) |
| Export/import/share | `core/export-html/`; `docs/sessions.md` | AGENTS.md cli recipe |
| Evals | `evals/README.md` | bus-contract + mock-LLM tests only |
| Hooks with teeth | `extensions.md` "Tool Events" (`tool_call` block/patch, `tool_result` chain) | `components/hooks/README.md` (observe-only, by design) |
| Replicated state + deltas | `chord/README.md` | — |
| Session search | `agent/src/search/index.ts` | — |
| Remote relay | `coding-agent/src/experimental/radius-relay.ts` | — |
| Supply-chain policies | root `README.md` | `components/plugins/`, `builder lang:"ts"` |
| No built-in MCP/subagents/todos in pi core | `docs/usage.md` "Design Principles" | — |
| pi has no LTM subsystem | `grep -rn 'memory' packages/*/src` (only project-trust) | — |
