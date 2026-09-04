# CodeWhale — prior-art analysis

> Research note — external codebase analysis, not a plan. Status: mostly
> unshipped; review receipts (item 10) and an observe-only `hooks` component
> (item 9) have since shipped — see the Delta scan at the end. Each item
> below is a candidate to become its own plan (or a line in the README
> quests).
>
> Source: a checkout of [CodeWhale](https://github.com/Hmbown/CodeWhale)
> (Rust, a fork of gemini-cli) at `../CodeWhale`, analyzed at
> `72587359f` (2026-09-03, v0.9.11-681). All citations are
> `../CodeWhale/<path>` relative to this repo's root.
>
> A second pass (2026-09) re-swept the same tree — the **Delta scan** section
> near the end covers areas this first analysis did not open (RFCs,
> `integrations/`, `plugins/`, several crates) and re-grades two items
> against what Niffler shipped since.

## What CodeWhale is

A single-binary Rust terminal coding agent (TUI + headless `exec` + HTTP
runtime API + embedded web client). Architecturally it is the *opposite* of
Niffler: the model turn loop runs in-process inside the TUI crate
(`crates/tui/src/core/engine/turn_loop.rs`), with a guard test that fails if
a second turn loop ever appears. Everything is one process; isolation comes
from policy layers, an optional OS sandbox, and a durable "Runtime" for
detached worker runs — not from process components.

That difference matters when borrowing: several of its strongest ideas are
cheaper for it *because* the loop, the catalog, and the request composer
share one address space. Niffler can still borrow the ideas, but each one
needs a home component and a bus boundary. This document lists what to look
at, mapped to Niffler components, in two tiers plus small techniques.

Its engineering culture is worth copying wholesale even where features are
not: every feature ships with a written contract (`docs/COMMAND_CONTROL_PLANE.md`,
`docs/TOOL_SURFACE.md`), a threat model (`docs/SANDBOX.md`), and an
observability surface (`/cache stats`, receipts, `doctor --json`). Rules
like "no surface advertises what it cannot do" and "an approval is not a
sandbox" are stated as invariants, not taste.

---

## Existing Niffler strength — narrow CodeWhale refinements

### Prompt-cache stability → `session`, `systemprompt`, `llm`

`../CodeWhale/docs/CACHE.md`. The invariant: **after session start, the
system prompt and tool catalog are frozen bytes; history only grows; a cache
miss is allowed only when we can name why.** Volatile facts (workspace
drift, steer input, new skills, memory entries, goal changes) are never
spliced into the prefix — they are appended as one bounded `<context_update>`
user-role message with `+`/`-` line deltas, delivered at the start of a new
user turn, each delta exactly once. Every prefix change carries a declared
reason (`change:model`, `change:goal`, `change:tool_surface`, `resume`,
`initial`); undeclared change is logged as `drift:<component>` and the
original pin is **kept** — so an undeclared change keeps counting as a miss
instead of quietly becoming the new baseline. `/cache stats` reports the pin
reason, drift count, and aggregate provider cache hit rate, making every
miss attributable.

Niffler already implements the core invariant, and is stricter than
CodeWhale about tool admission:

- `resolveSystemPrompt` (`core/conversation.nim`) resolves the constitution
  once, persists it in the conversation header, and reuses those bytes
  verbatim after a runner restart. A changed or failed `systemprompt`
  component cannot rewrite an existing conversation.
- The direct tool snapshot is persisted separately at `<sessionId>:tools`.
  `promptTools` returns only that immutable array on every request; schemas
  found through `discover` enter append-only history and execute through
  `invoke`. Unlike CodeWhale, Niffler therefore needs no
  `change:tool_surface` re-pin when a deferred tool is discovered.
- Steering and expert advice append messages rather than altering the head.
  The one ordinary history reset is context trimming
  (`core/conversation.nim`, `ctxTrimRatio`).
- `llm` already forwards the provider's
  `prompt_tokens_details.cached_tokens` in usage events.

The useful borrow is consequently narrower — operational proof and
observability, not a new composition architecture:

1. Give every legitimate miss/reset a named reason (`initial`,
   `change:model`, `change:thinking`, `change:provider`, `reset:trim`,
   degraded fallback) and report it with `ev.session.context` or a cache
   status surface.
2. Surface the cached-token count and aggregate hit ratio already collected
   by `llm`; today the datum exists but there is no `/cache stats`-style
   explanation of a miss.
3. Keep the existing semantic guards (`tests/t_systemprompt.nim` proves the
   frozen constitution; `tests/t_discover.nim` proves component churn cannot
   mutate the direct projection). Optionally add an exact-byte head fingerprint
   and drift counter, plus the contributor rule that every new context
   contributor declares "frozen prefix" or "append-only history".
4. Decide separately whether to borrow CodeWhale's bounded
   `<context_update>` deltas. Today an AGENTS.md/skill change made during a
   Niffler conversation deliberately remains invisible until a new
   conversation; CodeWhale shows such drift at the next user turn without
   changing the pinned head. That is a product choice, not a cache-discipline
   defect.

## Tier 1 — directly applicable, high value

### 1. User memory → new `memory` component

`../CodeWhale/docs/MEMORY.md`. Niffler has no cross-session memory.
CodeWhale's design is small and portable: Markdown files are the durable
source of truth, a rebuildable SQLite FTS5 index is a disposable cache;
scopes are `global/` and `workspace/<git-origin-hash>/` (notes from one repo
never leak into another's prompt); injection is bounded (≤32 entries / 12k
chars) and wrapped as **untrusted user data, not a second instruction
layer**; the model gets a `remember` tool (auto-approved — writes only to
the user's own memory files) and deeper search via `memory_search`; the
human gets a `# note` composer prefix that consumes the line without firing
a turn. Opt-in by default.

Niffler mapping: a `memory` component over the store (or its own files with
a store-backed index) is exactly the shape of our other components. The
borrowable details: origin-hash workspace scoping, the untrusted-data
framing in the injected block, auto-approval scoped to memory writes, and
the explicit "what stays out" list (secrets, transient task state,
conversation snippets, long instructions → AGENTS.md or a skill). The
`# note` prefix is a UI feature for the web UI slash-command set.

### 2. Subagent roles + transitive authority clamping → `agent` component

`../CodeWhale/docs/SUBAGENTS.md`. Our `agent_run` is one generic child.
CodeWhale's roles are *postures*, not labels: `general` / `explore` /
`planner` / `reviewer` / `implement` / `test` / `advisor` / `custom`, each
with writes/network/shell posture, a role-specific intro prompt, and a
typical-use contract. Three load-bearing rules:

1. **Delegation moves work, never authority.** A child's authority is
   clamped against the delegating parent's *live* posture, not the
   operator's: a read-only scout's `implement` child lands read-only, and
   read-only is transitive through any delegation chain (deny-list union;
   a descendant can never drop an ancestor's restriction). Delegating to
   obtain shell is mechanically useless.
2. **Depth budget**: `agent` disappears from a child's catalog at max
   depth (default 3) — checked per spawn, not just at the top.
3. **Child-side retry**: transient provider failures are retried with
   backoff *inside* the child runtime; when the budget is exhausted the
   child preserves a checkpoint and returns a continuation handle instead
   of the parent inferring what happened.

Niffler mapping: postures map onto which tools a child runner's direct set
contains plus a `x-harness`-level deny on `bash`/`write`/`edit` for
read-only roles — enforce in the child's exposure doc, not the prompt. The
clamp logic (parent posture ∩ child role) belongs in the `agent` component
that already prepares child runners. Depth already exists; make the
read-only ceiling transitive and test it (they pin it with
`a_read_only_parents_delegation_never_widens_authority`). Child-side retry
is an `llm`-adapter concern plus a checkpoint record in the store.

### 3. Typed permission rules → `core/dispatch.nim` (approval layer)

`../CodeWhale/docs/AUTHORIZATION_ORDER.md`. We have `x-harness.approval`
but no declarative policy file. Their `permissions.toml` layer is small but
sharp:

- Rules resolve by **source layer first** (`User > Agent > BuiltinDefault`),
  then action (`deny > ask > allow`); specificity is only a tie-breaker
  *within* a layer+action.
- Hard denied command prefixes (checked against the whole command and every
  chained segment) always win and cannot be overridden by an `allow`.
- A typed `allow` can clear only ordinary approval; it cannot clear a hook
  `ask` or a non-bypassable registered hold. A typed `ask` never downgrades
  Full Access into a prompt — but a typed `deny` still blocks there.
- Project overlays may only *tighten* posture, never loosen it.
- The 9-layer pipeline is monotonic after the typed layer: later layers
  (auto-review floor, repository law, human approval) can only add a prompt
  or a block.

Niffler mapping: a `permissions.toml`-style rules file loaded by core,
evaluated in dispatch between the registered baseline
(`x-harness.approval`) and the human prompt. Source-layer precedence
matters for us because component-authored rules (an `expert`-style peer or
a plugin) must never outrank user rules. The "repository law" concept
(protected-path invariants, hard block even in Full Access) is a natural
second rule type for us: today a user can approve *anything*.

### 4. OS sandbox for the shell → `bash` component

`../CodeWhale/docs/SANDBOX.md`. Their shell path (not the JS/Nim VM) can be
wrapped in an OS sandbox: Seatbelt (`sandbox-exec`) auto-probed on macOS,
bubblewrap opt-in on Linux (`prefer_bwrap = true`) with `--unshare-all`,
ro-bind `/`, private `/dev` and `/proc`, tmpfs `/tmp`, extra ro/dev bind
config. Key principles: sandbox availability is **probed and reported**,
never assumed (`macos-seatbelt` / `linux-bwrap` / `none` in status output);
approval is not a sandbox and a sandbox denial is not overridable by an
earlier approval layer.

Niffler mapping: our `bash` component runs raw shell today. An opt-in bwrap
wrapping in `bash` (reported in `bash` results or a status tool, never
advertised when absent) is a contained change that meaningfully raises the
floor for the most dangerous component. Fabric's RLIMIT + fresh process
isolation is a different layer and stays as is.

### 5. Tool-surface lifecycle with replay aliases → `core/catalog.nim`

`../CodeWhale/docs/TOOL_SURFACE.md` (+ historical `TOOL_LIFECYCLE.md`).
We already have their active/deferred split (`x-harness.hidden`,
`x-harness.onDemand`, discover/invoke) and their motivation ("one canonical
name per operation; near-duplicates measurably hurt weak models" — they
shrink the first-turn surface to exactly seven tools). What we lack:

- **Hidden-compatibility aliases**: retired tool names stay registered and
  dispatchable with identical behavior but are advertised nowhere, purely
  so old transcripts replay. Our catalog already rejects duplicate names at
  registration; an alias table (old name → canonical route) keyed in the
  store would give us safe renames.
- **Per-conversation toolbox cache**: their `tool_search` activation is
  remembered for the conversation, LRU-capped (8 names / 16 KiB of
  schemas), and *revalidated against the live catalog and policy* before
  re-advertising. Our `invoke` path has no such cache; sessions re-discover
  every turn, burning prompt budget and risking stale-schema confusion.
- Their rule "deferred tools are registered + discoverable + executable;
  removed means hard error" matches our onDemand contract — worth stating
  as an invariant in our catalog docs.

---

## Tier 2 — worth studying, bigger lifts

### 6. One durable runtime for detached work → `agent` + store

`../CodeWhale/docs/AGENT_RUNTIME.md`, `../CodeWhale/docs/FLEET.md`. Their
architectural lesson is the one REBOOT already took for sessions: subagents,
headless `exec`, and fleet workers must converge on **one** execution
lifecycle (retries, terminal states, receipts, inspection, restart) or you
get "the child failed on a one-off provider timeout and nobody knows."
Niffler's session runners *are* that substrate already; what we could
borrow when making `agent` durable across harness restarts:

- Fleet's **identity/selection never carries authority** rule: the runtime
  clamps policy *after* member selection; if the selected member can't run
  inside the envelope, launch fails closed rather than picking another.
- JSONL ledger + heartbeat leases reconciled by an idempotent
  `resume` (replay, reclaim dead leases, launch no new work) — a clean
  pattern for store-backed worker records.
- Retry-with-backoff inside the child, then checkpoint + continuation
  handle (same as item 3).

### 7. Control-plane contract → `cli` component + core

`../CodeWhale/docs/COMMAND_CONTROL_PLANE.md`, `../CodeWhale/crates/lane/src/control.rs`.
One typed descriptor table per `(domain, verb)` shared across slash command,
hotbar, and CLI — their three surfaces drifted before this (`/fleet status`
vs `codewhale fleet status` showed different things). Details worth copying:

- Availability is probed **read-only**: a status verb must not create the
  store it inspects ("no ledger" must not silently become "empty ledger I
  just made").
- Exact target ids only (no prefix/fuzzy matching); writes may be fenced
  with `@<lifecycle-seq>` for optimistic concurrency.
- Every invocation returns a receipt (operation id, outcome, observed
  state).

Niffler mapping: our `cli` component and core share tool dispatch but
nothing pins the verb semantics; a descriptor table for lifecycle verbs
(component spawn/kill, session pause/stop) would keep `cli` and the web UI
honest. The read-only probe rule directly applies to `catalog`/status tools.

### 8. Workflow orchestration (declarative compile-only) → contrast for `fabric`

`../CodeWhale/docs/WORKFLOW_AUTHORING.md`, `../CodeWhale/crates/workflow-js`.
The instructive *opposite* of fabric: where we chose a real Nim VM (RLIMIT,
framed stdio bridge, every effect through the session proxy), they chose a
**compile-only declarative JS subset** — `eval`, `import`, `fetch`,
`process`, async are all rejected; the script is a coordinator with no
FS/shell/network of its own; source lowers to a typed `WorkflowSpec` that a
Rust validation gate checks. Nodes are `agent`, `branch`, `sequence`,
`reduce`, `teacher_review`, `loop_until`, `cond`, `expand`; caps of 16
concurrent / 1000 agents per run. Their tradeoff is less expressive but
zero-runtime-threat; ours is a real language with a governance gate.

What fabric lacks that their node set has: **fan-in/reduce and gated
phases** as first-class constructs, and a hard concurrency cap as a
scheduling concept. The deferred-fabric work in docs/PLAN.md (councils,
map/reduce research) should study this,
plus their `AUTOMATIC_WORKFLOWS.md` (agent drafts the workflow, shows the
plan at the current permission mode, runtime compiles and monitors it).

### 9. Hooks → possible `hooks` component

`../CodeWhale/docs/HOOKS.md`. Plain shell processes at lifecycle points
(`session_start`, `tool_call_before`, …), env + JSON payload on stdin,
three steering verdicts folded `deny > ask > allow` with **fail-closed on a
strict hook that produces no verdict**, timeouts, `continue_on_error`.
Niffler already emits structured `ev.log.*` events on the bus; a `hooks`
component that subscribes and runs configured commands would be idiomatic —
the interesting part to copy is the steering fold and the fail-closed
semantics, not the mechanism.

> Status 2026-09: Niffler shipped an observe-only `hooks` component
> (`components/hooks/`); the remaining borrow is the steering fold and
> fail-closed semantics — see the Delta scan.

### 10. Review receipts → `git`/review tooling

`../CodeWhale/docs/RECEIPTS.md`. `review --write-receipt` writes a local
JSON receipt (diff SHA-256 fingerprint, provider/model, checks run,
findings, unresolved-risk summary — never the raw diff); `--check-receipt`
is a pre-push gate that calls no model and exits nonzero on fingerprint
mismatch or unresolved risk. A cheap, high-trust artifact pattern for any
Niffler review flow; the fingerprint-based staleness check is the reusable
idea.

> Status 2026-09: shipped in Niffler — `git`'s `review_receipt` write/check
> pair (`components/git/main.nim`).

---

## Small techniques worth stealing as-is

- **`/preview-request`** (`../CodeWhale/docs/PREVIEW_REQUEST.md`) — a
  human-only command that renders a typed, redacted manifest of the exact
  next request (session/route/tools/body, each section "exact or
  typed-absent") without sending anything; a `base-prompt` disclosure mode;
  effective system text never printed (it can contain project instructions).
  A trust/debug surface we could add to the web UI + a `systemprompt`
  inspection tool.
- **Bash arity dictionary** (`../CodeWhale/crates/execpolicy/src/bash_arity.rs`)
  — the reference implementation for command-prefix allow rules: only
  positional tokens count, flags never do, so `auto_allow = ["git status"]`
  matches `git status -s` but not `git push`. Needed the day we add
  auto-allow prefixes to approvals.
- **`.env` hardening** (`../CodeWhale/docs/CONFIGURATION.md`) — cap at
  1 MiB, reject symlinks/reparse points/multiply-linked files, reject
  variable expansion, workspace files may carry credentials *only*. Our
  `sdk/dotenv.nim` is permissive by comparison.
- **Web auth boundary** (`../CodeWhale/docs/WEB.md`) — one-time bootstrap
  capability in the launch URL exchanged loopback-only for an
  `HttpOnly`/`SameSite=Strict` session cookie; the bearer token never
  touches the browser. Relevant if the Wails shell ever gives way to a
  served client, or for remote harness access.
- **Per-tool workspace snapshots for surgical `/undo`**
  (`../CodeWhale/crates/tui/src/core/engine/turn_loop.rs:3819`) — capture
  repo state before file-modifying tools so `/undo` can revert one turn.
  We have per-file `undo_last_edit`; a turn-level git snapshot in the `git`
  component would generalize it.
- **Skill audit without merging** (`../CodeWhale/docs/SKILLS.md`) — audit
  shows every on-disk copy so shadowing stays visible; only owned dirs are
  writable. We already have the owned-dirs rule; the unmerged audit view is
  a small addition to the `skills` component.

---

## Parity — CodeWhale features we already have

Checked so as not to re-borrow what shipped here:

- **Models.dev catalog with layered precedence** — their
  `CATALOG_REFRESH.md` (live-over-bundled, atomic write, TTL, "an LLM may
  review a PR, not own the catalog") is what our `models` component does
  (validated atomic cache, last-known-good fallback).
- **Progressive tool discovery** — their active/deferred/tool_search is our
  direct/onDemand/discover+invoke; theirs is smaller (seven names) and
  alias-hardened (see Tier 1.6).
- **Subagents as sessions** — their `agent` runs on the Runtime; ours on
  session runners. Role postures and clamping (Tier 1.3) are the delta.
- **OAuth provider logins** — both implement the same PKCE/device flows
  (`docs/MANUAL.md`).
- **MCP client** — both plan it as external tools behind the same gate
  (`docs/research/MCP.md`); theirs ships a `mcp_<server>_<tool>` naming
  scheme identical to our plan's.

## Deliberate non-borrows

- **Monolithic in-process loop.** Their single-process TUI turn loop is
  what makes several of their invariants easy (and what REBOOT explicitly
  rejected for us: crash isolation from LLM-written components). Nothing
  here changes that decision.
- **No-context-trimming stance.** They keep small windows and reset via
  compaction; we trim with the store as the source of truth. Their
  attribution vocabulary (`reset:compaction`) applies to us; their
  no-trim policy does not.
- **Fleet as a product surface.** Stable member rosters and ledgers are
  useful *patterns* (Tier 2.7); as a product layer they duplicate what
  Niffler's sessions + plugins already express.

## Delta scan (2026-09 re-sweep)

Second pass over the same tree (`git pull` returned "already up to date" at
`72587359f`), covering what the analysis above never opened — the `rfcs/` and
`architecture/` subdirectories, `integrations/`, `plugins/`, the
telemetry-ingest service, and crates outside the first pass — plus a re-grade
of earlier items against what Niffler has shipped since this note was written
(observe-only `hooks`, `review_receipt` in `git`, `expert`, `bench/`, store v2
in progress). D-numbers are independent of the item numbering above.

### D1. Sub-agent git worktrees with a write-claim protocol → `fabric`/`agent`

`docs/SUBAGENTS.md` ("For parallel edit lanes, launch the child with
`worktree: true`"). A child spawn can request a fresh git worktree + branch
under `.codewhale-worktrees/` (parent checkout stays clean), with
`worktree_branch` / `worktree_base` / `worktree_path` parameters. The borrow
is the claim semantics: the child *declares* `worktree_write` plus normalized
repo-relative `write_roots`; **claims fail before mutation** when no real
isolated worktree backs them, and "a real isolated worktree may proceed in
parallel". Concrete prior art for the deferred fabric item "optional isolated
git worktrees for subagents" (docs/PLAN.md) — Niffler has nothing here today.

### D2. External eval-harness contract → `bench/`, headless runs

`integrations/verifiers-codewhale/README.md`. CodeWhale is drivable as a
harness under an external eval framework (Prime Intellect Verifiers):
isolated `CODEWHALE_HOME` per rollout, model traffic pinned to the harness's
interception endpoint with per-rollout secrets (never in argv), toolsets
delivered as a rollout-local MCP config, telemetry off, and success defined as
the exact `codewhale.exec-stream` v1 terminal receipt — malformed streams fail
closed. Niffler's `bench/tasks/` is in-house; the borrow is the *contract*:
hermetic per-run home, interceptable model traffic, versioned terminal receipt
as pass criterion (cf. `turn_usage` in `docs/AGENT_RUNTIME.md`). Pairs with
pi's evals package (PI_FEATURE_SCAN.md §3.6).

### D3. External-memory layer cutline → design constraints for any memory plan

`docs/rfcs/WORKFLOW_EXTERNAL_MEMORY.md` (principle-only cutline). A layer
table separating user memory / repo search / in-session memo (ARMH/RLM) /
TraceStore replay / a "cached-main overlay" of promoted lessons (inspectable,
reversible, never mutates main) / external memory (explicit node or plugin
only). Rules worth adopting verbatim: visibility requirements (when active,
owning node, storage location, readable scope, replay/export status,
inspect/clear/pin/export), strictest-scope inheritance ("project-local config
must not silently enable broad external-memory reads"), and "if a run cannot
explain why a fact came from external memory, the feature is not ready for
default use."

### D4. RLM sessions — kernel-backed context querying → candidate memory/context component

`crates/tui/src/rlm/{session,turn}.rs`. A deferred `rlm` tool family over a
persistent Python kernel (`PythonRuntime`) that *holds* the large context
(`context_path`, `context_meta`) so the model queries its own context
programmatically instead of re-reading it, with hit/miss telemetry
(`rpc_count`, `peak_var_count`). The Aleph/RLM pattern — context management
beyond compaction. Niffler shape: a component wrapping a persistent kernel
(the `fabricguest` bridge pattern) exposing query tools, with the memo layer
explicitly non-durable per D3.

### D5. Aux-model policy ("Fin") → `models`/`llm` + `expert`

`docs/MODEL_LAB.md`. A designated fast, thinking-off model for
harness-internal calls: routing, summaries, cheap checks, RLM child calls,
"wakeup verification", binary-completion checks; plus `--model auto` per-turn
routing to a concrete model + thinking level. Niffler's `expert` judgment
calls and a future compaction component (Phase-2 A1) both want this lane;
make it an `auxModel` policy in `models`/`llm` rather than per-component
ad-hoc choices.

### D6. Modes and postures → core session policy + fabric product design

`docs/MODES.md`.

- **Plan is enforced by the runtime** ("the runtime centrally refuses file
  mutation and shell execution") while tool names stay visible — a
  session-level read-only posture, i.e. the subagent clamping mechanism
  (item 3 above) applied to the parent session.
- **Operate** turns a prompt into a session goal with continuation;
  "dispatch is not completion — write-capable children must return real
  verification evidence" (VERDICT PASS/FAIL with evidence); best-of-N runs N
  worktrees + a reviewer and applies only on PASS; lifecycle claims are exact
  ("dispatched ≠ settled ≠ verified"). Product-level prior art for fabric's
  deferred councils/map-reduce work — the evidence-verdict contract is the
  specific steal.
- **Auto-Review posture** sits between Ask and Full Access: an LLM review
  floor that can tighten but not unblock (`docs/AUTHORIZATION_ORDER.md:81`).

### D7. Declarative plugin bundles + ecosystem compat → `plugins`/`skills`

`docs/PLUGIN_BUNDLES.md`, `docs/CLAUDE_PLUGIN_COMPAT.md`. A bundle
contributes Skills, MCP configuration, Commands, Agent profiles, and Hooks
*declaratively* through existing engines — no compiled runtime; "discovery
alone never executes, enables, trusts, downloads, updates, or installs
anything"; unsupported declarations stay inventoried instead of disabling a
mixed bundle; multi-format manifest precedence (`plugin.json` → Kimi subset →
legacy toml). `.claude/skills/*/SKILL.md` folders are read as instruction
bundles, with an `/import-claude` path. Niffler: `niffler.json` could grow
declarative sections, and `skills` could read `.claude/skills/` +
`.agents/skills/` for instant ecosystem import.

### D8. Skills routing metadata + catalog fixture matrix → `skills`

`docs/SKILLS.md`. `invocation: explicit-only` (loadable by name, omitted from
the ambient catalogue — zero prompt budget), `aliases-for` (lookup names,
never duplicate catalogue entries), a tiered bundled catalogue ("core
agentic" vs "format & tooling"), and an authored **catalog fixture matrix**
(`crates/tui/assets/skills-catalog-matrix.json`) with a bijection test — "the
shipped pack cannot change without an explicit fixture update" — plus the
doctrine that the pack never advertises capabilities the runtime lacks
(asserted: no image-gen skill without an image tool). Niffler `skills` has
none of these; the fixture pattern also generalizes to pinning the
systemprompt and direct-toolset surfaces.

### D9. Lifecycle event outbox → `logfile`/`hooks` extension

`docs/changelog-lifecycle-outbox.md`, `crates/hooks/src/lifecycle_outbox.rs`.
Opt-in JSONL outbox of runtime events with monotonic `seq` recovered from a
bounded tail scan on open (torn trailing line ignored), optional webhook +
bearer token. Unlike Niffler's rotation/diagnostic `logfile`, this is a
durable, sequence-complete sink external integrations can rely on.

### D10. Runtime API surfaces → `observe` + client components

`docs/RUNTIME_API.md`. `doctor --json` machine-readable health; an **ACP
(Agent Client Protocol) stdio adapter** (`serve --acp`) so editors (Zed) embed
the agent; HTTP/SSE + mobile page on one `app-server`. Niffler: a
doctor-style health projection (component liveness, store writability,
provider reachability — `observe` partially covers it), and an ACP adapter
component (stdio JSON-RPC ↔ `svc.session.<id>.call`) would make Niffler
embeddable in editors cheaply.

### D11. Cloud dispatch, proposal-first → pattern for remote execution

`docs/DAYTONA_CLOUD_DISPATCH.md`. Offloading a task to a cloud sandbox writes
a proposal first; nothing is created or pushed until explicit `--confirm`;
"spend and push never happen silently." Consistent with the approval
doctrine; recorded for any future remote-execution capability.

### D12. Presentation-filter boundary → store/UI invariant

`docs/rfcs/4468-output-presentation-filters.md`. "Never run an arbitrary
script between a model response and the canonical session record":
filtering/compression belongs to labeled, derived *views* that retain a
canonical reference. Applies directly to the Level-1/2 UI-dynamism work
(renderers reformat, never mutate the store record) and to compaction (A1
must add entries, never rewrite history).

### D13. Small steals

- **Motion contract** (`docs/MOTION_CONTRACT.md`): provider SSE deltas are
  input, never animation timing — coalesce on a display clock; a better
  web-UI streaming rule than render-on-delta.
- **OS keyring secrets** (`crates/secrets`): a `secrets` component instead of
  `.env`-only storage for provider keys.
- **`read_media`** (`docs/READ_MEDIA.md`): the vision tool is registered as a
  *deferred* tool to protect context budgets, plus a stable attachment store
  for pasted/screenshot paths — the CodeWhale-specific additions on top of
  pi's resize-on-read (PI_FEATURE_SCAN.md A6).

### Re-graded prior items

- **Item 10 (review receipts): shipped in Niffler**
  (`components/git/main.nim` `review_receipt`) — closed.
- **Item 9 (hooks): partially shipped** — observe-only
  (`components/hooks/`); the remaining borrow is the steering verdict fold
  and fail-closed-on-strict-hook semantics.
- **Memory (item 1) remains open** — D3 + D4 are the design constraints to
  write into its plan.
- Everything else in the tiers above stands unchanged.

### Still not worth borrowing (additions)

- `plugins/computer-use` — product-scale; interesting boundary, no current
  need.
- Chat bridges (`integrations/feishu|telegram|wecom|weixin`) — a product
  surface; `bridge-core`'s adapter shape is the template if ever.
- Model Lab as a product — the aux-model policy (D5) is the extract.
- Cloud dispatch as a product — the proposal-first pattern (D11) is the
  extract.
- TUI craft (motion/settings-picker/accessibility) beyond D13's streaming
  rule — wrong layer for a Wails UI.

### Order (delta items)

D5 → D1 → D8 → D7 → D2 → D6 (Plan posture) → D12/D13 riding UI work →
D9/D10 as integrations demand. D3/D4 feed the memory plan rather than
shipping alone.

## Open questions

1. Where does the pinned-prefix hash live — `systemprompt` (single composer)
   or `session` (runtime owner)? And do the baseprompt and the frozen
   direct-toolset schemas need a versioned serialization on the bus first?
2. Memory scope key: hash of git origin (CodeWhale) vs. store-recorded
   repo identity (Niffler has no git-origin concept in core) — origin hash
   wins on portability, but our `git` component can supply it lazily.
3. Typed permission rules: separate `permissions.toml` loaded by core, or
   store docs (kind `permission`) so the harness edits its own policy
   mid-conversation? The second is more Niffler, and needs the
   source-layer precedence designed first.
4. If `bash` gets a bwrap opt-in, who owns the probe/report — `bash` itself
   (per-call wrapping) or `observe` (capability report)? CodeWhale wraps in
   the execution path and reports in status; both need the same
   probe result, so a shared probe in `sdk` or a small status tool.
5. D1: where do worktree write-claims live — fabric program IR, the `agent`
   tool schema, or a store record the `git` component validates against?
6. D5: does the aux model belong to `models` (a catalog-level "fast" tag) or
   `llm` (a second route per session)? `expert` is the first consumer either
   way.
