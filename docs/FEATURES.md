# Features — the complete inventory

[English](FEATURES.md) · [Manual](MANUAL.md) · [Wire](WIRE.md) · [Architecture](ARCHITECTURE.md)

What Niffler ships, one list, grouped by area. This file is an **index of
capabilities**, not a reference: it names what exists and where it is
documented, without repeating parameters, defaults or semantics. When a row
needs detail, follow the linked document — [MANUAL.md](MANUAL.md) for
operating, [WIRE.md](WIRE.md) for the protocol, [ARCHITECTURE.md](ARCHITECTURE.md)
for why a mechanism is in core, [FABRIC_GUIDE.md](FABRIC_GUIDE.md) for
orchestration, and [research/](research/README.md) for design history.

Keep this list exhaustive but coarse: a new capability earns a row (or an
addition to an existing row); a changed default or parameter does not.

## Contents

- [Architecture and runtime model](#architecture-and-runtime-model)
- [Core system harness](#core-system-harness)
- [Conversations and session runners](#conversations-and-session-runners)
- [Context window, pruning, compaction and recall](#context-window-pruning-compaction-and-recall)
- [Tool exposure and progressive discovery](#tool-exposure-and-progressive-discovery)
- [Shipped components and tools](#shipped-components-and-tools)
- [The wire protocol](#the-wire-protocol)
- [Schema extensions (`x-harness.*`)](#schema-extensions-x-harness)
- [Approvals, trust and safety](#approvals-trust-and-safety)
- [SDKs](#sdks)
- [Self-extension, plugins and the ecosystem](#self-extension-plugins-and-the-ecosystem)
- [Clients and UI surfaces](#clients-and-ui-surfaces)
- [Configuration and state](#configuration-and-state)
- [Operations: build, test, bench, docs](#operations-build-test-bench-docs)
- [Explicitly not shipped](#explicitly-not-shipped)

## Architecture and runtime model

See [ARCHITECTURE.md](ARCHITECTURE.md), [AGENTS.md](../AGENTS.md) "What this is".

- One protocol only: JSON envelopes over NATS. Core never imports component
  code; components never import core.
- Every capability is a separate OS process component — peers, no plugins in
  the host process. Polyglot by construction (Nim, Go, TypeScript, and one
  shell-only component with no SDK at all).
- Self-extension mid-conversation: write source → `build` → `spawn`;
  `kill` stops a group temporarily, `remove` also deletes the persisted
  record.
- `replicas: N` (1–16) per component, served through the existing NATS queue
  group; stateless or externally coordinated components only.
- Bootstrap manifest (`manifest.yaml`): per-entry restart policy
  (`never`/`on-failure`), `required`, `autostart`, `interactive`, `defines`,
  `env`, `replicas`; the store becomes authoritative after boot.
- Supervised children with crash backoff; core drains children in reverse
  registration order.
- Kernel lifecycle discipline: every child carries a parent-death signal
  (`setpriv --pdeathsig TERM` / `PR_SET_PDEATHSIG`) so nothing outlives its
  harness; core itself is deliberately exempt (autostarted cores must outlive
  the UI that spawned them).
- Clone-as-instance: the checkout is the harness home (`NIF_ROOT`); `var/` is
  disposable runtime state and the repo is the snapshot.
- Language-agnostic core: language support is data (config registries) or a
  plugin component; no per-language branches in shared components.
- Prompt-cache discipline as an invariant: a conversation's request prefix
  (frozen system prompt + frozen direct tool schemas) stays byte-stable, and
  everything else enters as append-only history.

## Core system harness

See [MANUAL.md](MANUAL.md) "Layout of a running system", "Starting and
stopping"; [WIRE.md](WIRE.md) "Lifecycle".

- Bus bootstrap: core spawns the bundled `nats-server` build when no bus is
  configured, at an 8 MiB `max_payload` (or a PATH `nats-server` via a
  generated config), and writes `var/nats-url` / `var/nats-monitor-url`.
- Home-bus claiming vs. explicit attach: environment URL → `.env` home bus →
  the well-known port; identity-checked adoption of only a core serving *this*
  root; loud yield to a foreign core or bare NATS server; isolated random bus
  (`NIF_NATS_SPAWN`); reclaim of this root's own leftover bus.
- Port allocation by the server itself (`--ports_file_dir`), with a separate
  loopback HTTP monitoring port.
- Boot profiles: full, `--minimal` (store, bash, llm and systemprompt), `--recover`
  (rebuild shipped binaries, wipe spawned-component records, boot);
  `NIF_AUTOSTART` service mode with idle-departure and boot-grace exits.
- Supervisor: spawn/drain/remove, restart policy and backoff, child-log
  retention sweep, log tail shown when a child dies.
- Catalog authority: registrations and departures, globally unique tool
  names (duplicates refused in full), schema normalization for LLM validity,
  full snapshot / component map / direct projection, replica and pid tracking.
- Dispatch seam: routing by bare tool name, workspace and session context
  injection, timeouts, approval, hidden/on-demand filtering, parallel fan-out,
  effect classification, delegation-depth guard, nested-call leases.
- Core's own tools: `session` (hidden), `session_prepare`, `spawn`, `kill`,
  `remove`, `catalog`, `status`, `doctor`, `prompt_preview`, `session_info`,
  `discover`, `invoke`, `profile`, `ui` (hidden), `conversation_delete`
  (hidden, gated).
- Never-blocking core: session calls ride a private forwarding inbox, and
  mid-turn component calls (e.g. `spawn` inside `plugin_install`) are served
  from the dispatch idle slot; a second turn is refused with `busy` instead of
  nesting.
- Admin tty shell (`core/tty.nim`): `help`, `status`, `catalog`, `tools`,
  `sessions`, `exit`/`quit`/Ctrl-D, arrow-key history, tab completion.
- Health surfaces: `status`, `catalog`, `doctor` with a `selftest` fan-out
  (quick and `deep` live probes), `/doctor` in the UIs.
- Coordinated shutdown: `ev.sys.drain` → grace → SIGTERM → SIGKILL, with
  `ev.sys.shutdown` for voluntary departures.

## Conversations and session runners

See [MANUAL.md](MANUAL.md) "Session runners", "Conversation controls", "Context
window"; [WIRE.md](WIRE.md) "Subjects", "Approvals", "Attachments".

- One conversation = one ephemeral process (`var/bin/session <id>`, restart
  `never`), ensured on demand and resumable from the store; killing a runner
  loses only the in-flight turn.
- Per-conversation subjects: `.call` (turns and control), `.steer`, `.advise`,
  `.map`, `.diag`, `.tool` (nested-call proxy).
- Turns never nest; separate conversations run concurrently; a mid-turn call is
  refused `busy` immediately.
- Idle retirement and re-creation; readiness polling; mid-wait corpse reaping.
- Session call surface: `content`, `provider`, `model`, `thinking`, `title`,
  `cwd`, `profile`, `discovery`, `tools`, `maxRounds`, `maxCalls`, `maxTokens`,
  `approvals`, `limits`, `compact`, `export`, `wake`, `attachments`.
- Frozen per-conversation controls (tool allowlist, budgets, profile) and a
  persisted conversation header carrying selection, meters and controls.
- Provider/model pins are one selection: a model-only call pins the provider it
  resolves under in the same write; explicit pins never silently fall through;
  legacy half-pins are healed on resume; subagents inherit the whole pin.
- Workspace pinning (`cwd`), immutable per conversation, with a workspace set
  that includes linked git worktrees and sibling checkouts of the same origin.
- Mid-turn steering, turn-bound advisory delivery, repo-map appends and
  asynchronous LSP diagnostics — all folded as append-only history.
- Image attachments: validation (MIME allowlist, magic bytes, per-image and
  per-turn caps), metadata/pixel store split, deterministic greedy-newest
  projection, caption placeholder, delete sweep.
- Hard, non-negotiable budgets for subagents alongside soft human limits that
  negotiate through the approval channel.
- Conversation deletion (messages, toolset, lineage, jobs, attachments) behind
  a hidden gated tool.
- Introspection: `/export` (the exact provider request), `prompt_preview`
  (composition provenance), `session_info` (summary and per-role counts),
  `/compact` (run the compactor now).

## Context window, pruning, compaction and recall

See [COMPACTION.md](COMPACTION.md) — the model and the comparison with other
harnesses — plus [MANUAL.md](MANUAL.md) "Context window" and the design record
[research/COMPACTION.md](research/COMPACTION.md).

- Admission priced before every provider request, including each tool round;
  conservative estimate with a calibration offset re-measured from reported
  usage (model-scoped, clamped, never persisted).
- Output reserve derived from the model's catalog output cap, overridable.
- Threshold warning, then a bounded ladder: byte-exact tool-result prune →
  configured compactor → oldest-complete-turn trim → explicit
  `context-recovery-required`.
- Deterministic, model-free prune with recall markers and byte-exact bounds.
- Replaceable compaction seam (`NIF_COMPACTION_TOOL`): versioned contract,
  paged snapshots, candidate validation, strict-reduction check, atomic
  `expectRev` commit, runner-owned `checkpoint-v1` rendering.
- Explicit compaction outcomes — unavailable / failed / declined / invalid /
  stale — none of which silently degrades to lossy trim.
- Durable context projection with generations and a trim watermark honored on
  every resume path; durable omission notices naming the dropped span.
- Provider-overflow recovery with a one-shot request-scoped receipt and
  fail-closed irreducible candidates.
- LLM retry policy: transient, stream and connect retries with exponential
  backoff, `retry-after` honoring and clamping, fail-fast auth/quota/bad
  request; retries announced on the bus.
- Canonical, append-only, immutable message history; oversized tool results
  promoted to spill documents.
- `context_recall`: `full` / `match` / `search` modes over canonical messages,
  spill bodies and the current checkpoint, with session-scoped search.
- Cumulative prompt-cache reporting per turn and in the header, with the reset
  reasons (`prune`/`compact`/`trim`/`tools`) as the only attributable rebuilds.

## Tool exposure and progressive discovery

See [MANUAL.md](MANUAL.md) "Progressive tool discovery"; [WIRE.md](WIRE.md)
"x-harness schema extensions".

- Existence is global, exposure is per conversation: direct / on-demand /
  hidden, with hidden taking precedence.
- A small frozen direct set per conversation (shipped policy: `discover`,
  `invoke`, `bash`, `grep`, `read`, `edit`, `write`), snapshot-persisted for
  byte-stable resumes.
- `discover`: deterministic hint listing (name-sorted, one-line descriptions,
  word-AND queries), per-component hints, full schema lookup by name (bounded),
  cross-component tool search with `notFound`, and identical errors for unknown
  and hidden names (no existence oracle).
- `invoke`: the fixed gateway that re-enters normal dispatch, preserving
  approval, timeout, routing and workspace policy; exact tool name
  sanitization.
- Sticky promotion (`invoke {sticky: true}`) appending a schema durably to the
  direct set under a token budget.
- Named tool profiles (selectors for a component, a single tool, and
  exclusions) resolved once per conversation, plus `NIF_PROFILE` default and a
  client `/profile` selection.
- Runner-machinery exemption for replaceable hidden tools (compaction, recall,
  chat) in allowlisted conversations.
- Client-side exposure views (`/components` filters, `/discover`, exposure
  documents) and the Live Components panel's direct/seen/demand/internal
  chips.
- Late registrations never mutate an existing conversation's frozen set.

## Shipped components and tools

See [MANUAL.md](MANUAL.md) "Shipped components" (the per-component reference).

### Shell, processes and the machine

- `bash` — general shell execution: process-group leader, timeout and exit-code
  contract, combined output with caps and spill files, heredoc handling,
  background hand-off, cancellation.
- `processes` — owned long-running commands: start, incremental poll (filter
  and tail), kill the group, list; spool files, process cap, crash-safe
  registry sweep, and exit notices delivered to the owning conversation.

### Files, search and repository inspection

- `edit` — `read` (batched windows, unchanged detection, symbol outline for
  large files), `edit` (unique-match replacement with a guarded fallback
  cascade), `write` (atomic whole-file), `undo_last_edit` (persistent,
  single-level, stale-aware); post-edit language-server diagnostics push.
- `grep` — `grep` (content search, fixed argv, caps, exit codes) and `files`
  (sorted listing); gitignore-aware glob and hidden semantics; stateless
  replicas.
- `git` — read-only inspection (`git_status`, `git_diff`, `git_log`,
  `git_show`, `git_blame`) plus `review_receipt` (local diff-fingerprint
  write/check for review handoff); mutations deliberately stay in `bash`.
- `repomap` — ranked workspace map (tree-sitter tags plus a native Nim tagger,
  personalized PageRank, focus and mentioned-identifier ranking, token budget)
  with a gated workspace-open auto-append.

### Web and language servers

- `fetch` — web retrieval: http(s) with methods, headers and body; redirects
  re-validated per hop; SSRF checks with address pinning; extraction ladder
  (Trafilatura → built-in HTML walk → raw); size and time caps with file
  spill; structured result metadata.
- `lsp` — one seam over any stdio language server: diagnostics, document
  symbols, workspace symbols, definition, references, implementation, hover,
  warmup; registry listing and approval-gated registry mutation; data-driven
  server registry with built-in defaults; marker-derived roots, instance reuse,
  workspace warmup with heavy/cheap budgets, stable error codes, bounded scope.

### Storage

- `store` — the document store over the bus: `put`, `get`, paged `list`,
  server-side `search`, hidden `del`, hidden `selftest`; rev-based optimistic
  concurrency; session write fence for curated kinds.
- Two engines behind one contract: SQLite (default; FTS5 index, embedded
  migrations, WAL, single-writer flock) and TiDB/MySQL (shared cluster, row
  locks, no flock), selected at boot; identical result semantics.

### Models, providers and inference

- `models` — provider/model metadata plane: providers, list, get, strict
  resolve, refresh, provenance; models.dev baseline with an embedded offline
  seed, atomic cache, last-known-good fallback, and merge-patch layers
  (plugin sources by priority, local override); secret redaction; live model
  ids from the provider lane.
- `provider` — store-backed backend registry: add/update/remove/list/switch,
  status, effective-config reads, endpoint model probing, export/import,
  environment fallback, prefix stripping, catalog ids, switch notifications and
  a secret-free invalidation event.
- Subscription OAuth (ChatGPT Plus/Pro and Claude Pro/Max): browser and
  device-code flows, local callbacks, polling completion, cancel, 15-minute
  expiry, transparent token refresh.
- Protocol lanes in `llm`: OpenAI-compatible Chat Completions, OpenAI Codex
  Responses with ChatGPT OAuth headers, Anthropic Messages with Claude Code
  identity — plus output-cap spelling per protocol and normalized
  `finish_reason` reporting.
- `llm` — streaming chat adapter: `chat`, credential-free `llm_resolve`, the
  live model-id source; token deltas, cancellation channel, history repair,
  named-provider table, and a minimal non-streaming example adapter.

### Extension, ecosystem and knowledge

- `builder` — `build` (Nim/Go/TypeScript, extra sources, defines) and
  `build_package` (manifest-v2 projects: staged dependencies, bounded argv
  recipes, controlled placeholders, artifact validation) plus `info`.
- `plugins` — the ecosystem front door: topic search, installed list, install,
  update, remove; manifest v1 and v2, clone → build → spawn, release/branch
  refs, interactive entries, per-entry env/defines, mirror and registry
  overrides, install records.
- `skills` — Agent Skills (SKILL.md) surfaces: list, online search, load,
  resources, audit (shadowing and invalid copies), git-based install and
  remove; four-source discovery order, compiled-in fallback, npx-skills
  interop.
- `systemprompt` — the replaceable conversation constitution, with the project
  context chain (override/AGENTS/CLAUDE per directory, ancestor walk, worktree
  shadow rule, lazy subtree loading, workspace tail), a prompt-slot seam
  for component-contributed fragments, and size-gated independent-review
  guidance for long first messages.
- `compaction` / `recall` — the shipped implementations behind the two
  seam tools.

### External MCP servers

- `mcp` manager plus one supervised `mcp-bridge` child per server: registry
  tools (servers, add, edit, remove, refresh, registry search), stdio/http/sse
  transports, lazy sessions with idle teardown, per-call timeouts, tool name
  namespacing and sanitization, exposure threshold, secret-by-reference with
  redaction, stdio guard process with an environment allowlist, cross-origin
  credential refusal, result spill, drift detection with faithful re-announce,
  server prompts as slash commands and hidden render tools, resources tool.

### Agents, orchestration and advisory peers

- `agent` — subagent sessions: synchronous run, background spawn, status, wait,
  stop, steer, ask, notices, roster; durable jobs, lineage authorization,
  frozen controls, append-only continuation, settlement notices with wake and
  pull lanes, memory-bearing forks, alignment on an activation ledger,
  retirement, delegation-depth cap.
- `fabric` — programmable tool calling: compiled Nim guests, typed wrappers
  from pinned schemas, allowlisted `callTool`, budgets, effect-aware batching,
  program cache, artifact spill, cancellation, approval manifests by digest,
  forbidden-surface rejects, catalog-fingerprint checks, plus a guest reference
  tool and a stored program library.
- `expert` — advisory peer: follow/unfollow/reload/status, bounded current-turn
  observation, stateless LLM judge over a cache-stable knowledge prefix,
  turn-bound advice with visibility and novelty gates, per-follow metrics.
- `jev` — advisory discovery over a local decision model (recommend, suggest,
  raw typed decide) plus per-turn shadow observations; strictly advisory and
  local-only by construction.
- `von` — supervised launcher for the optional decision runtime, enabled by a
  spawn record, with a status tool and idle-seam re-checks.

### Observation, logs and hooks

- `observe` — bounded live inspection: subjects, listen, trace, probe
  management, ring and probe queries, log queries, confined capture export,
  NATS monitoring, guarded send and request; byte and count bounds everywhere.
- `logfile` — rotating JSONL persistence with bounded search and path listing,
  per-component files, raw-preserving records and validated configuration.
- `hooks` — env-configured operator shell commands on selected bus events,
  with the payload on stdin, wildcard subjects, dedupe, timeouts and a
  deliberately veto-free, observe-only contract.

### Clients, demos and the bus itself

- `cli` — the scripting driver: catalog, wait, call, install, and the headless
  turn driver (`run`, attach-or-own a home, stream or `--quiet`, export a
  transcript), with exit codes and its own timeout budget.
- `console` — renders every envelope on the bus, with reconnect handling.
- `dialog` — an SDK-free bash component demonstrating the protocol with two
  desktop dialog tools.
- `nats-server` — the bus as a first-class built component, preferred over a
  PATH install, with the harness's max-payload flag and parent-death handling.

## The wire protocol

See [WIRE.md](WIRE.md) (the single contract).

- Envelope v1: versioned id/kind/tool/args/payload/error/caller shape,
  omitted-not-null fields, unknown-field tolerance, stable error codes,
  `bad-envelope` replies, streaming frames with a terminal `done`.
- Registration and discovery subjects, queue-grouped service calls, the
  session-runner call surface, and the full per-conversation event namespace
  (turn, assistant, status, context, retry, token, toolcall, steer, advice,
  notice, map, diagnostics, done).
- Component and system events: catalog updates, model-catalog updates,
  provider switch/change, workspace opened, SDK logs, LSP warmup, agent and
  fabric lifecycle events.
- Cancellation: in-flight LLM aborts and the opt-in `cancel.<component>`
  side-channel with injected session identity.
- Approvals: directed-to-driver requests, broadcast fallback, ack/verdict
  exchange, resolution notice.
- Declarative slash commands: parameter kinds, inline values, lazy candidate
  sources, registration validation, and a persisted merged table.
- Result conventions: the `text` field as the LLM rendering, stable machine
  fields, status-line convention, `userMessage` for client-rendered user
  turns, and reference-not-inline for big payloads.
- Replica semantics, session-context/lease semantics, parallel scheduling and
  server-side concurrency as separate, explicit choices.
- Payload discipline: the bus cap the harness requires, and the boot check
  that warns on a smaller one.

## Schema extensions (`x-harness.*`)

See [WIRE.md](WIRE.md) "x-harness schema extensions".

- `hidden` — invisible to the LLM.
- `onDemand` — out of the frozen direct set; reachable through discovery.
- `approval` — the enforced human gate.
- `timeoutMs` — per-tool request bound.
- `effect` — read/write classification for batch scheduling.
- `sessionId` — injects the live session id for cancellation matching.
- `sessionContext` — injects live session context plus a nested-call lease.
- `noSpawn` — subagents may not spawn subagents.
- `workspace` — path-shaped arguments resolved against the conversation
  workspace, with the workspace-set context injected privately.
- `parallel` — safe to dispatch concurrently with other parallel tools.
- `runner` — runner-machinery exemption from a frozen tool allowlist.
- `x-models-source` — the model catalog's plugin correction/discovery seam
  (a non-`x-harness` extension, listed for completeness).

## Approvals, trust and safety

See [MANUAL.md](MANUAL.md) "Approvals"; [WIRE.md](WIRE.md) "Approvals".

- Approval-gated tools (shell-adjacent, mutating, credential-moving,
  lifecycle-changing) held until a human answers.
- Routing: directed to the component driving the turn → broadcast fallback →
  terminal prompt; **deny** when no human is reachable, never a silent grant.
- Timeouts that deny, a resolution notice that dismisses stale prompts, and a
  per-conversation auto mode that is logged loudly.
- Persisted per-tool "don't ask again" grants, keyed by tool and, for
  program-shaped calls, by content digest.
- Program approvals by content: source digest, full source artifact, selected
  tools and declared budgets.
- Soft-limit keep-going questions on the same channel.
- Least privilege in the risky paths: SSRF-validated fetching with pinned
  addresses, MCP environment allowlists and guard processes, a fabric executor
  without bus access or inherited secrets, confined capture/artifact
  directories, symlink and credential refusals, redaction in listings.
- Argument and schema validation with bounds, stable error codes, and
  fail-closed behavior where a limit is unknown.
- The explicit trust boundary: the gate protects core-mediated callers only,
  and direct bus callers are documented as trusted peers.

## SDKs

See [MANUAL.md](MANUAL.md) "SDK APIs", "Re-attaching after a bus outage",
"Idle work (`onIdle`)"; [sdk/](../sdk).

- Three SDKs — Nim, Go, TypeScript — around one portable envelope codec, with
  the same observation, raw-envelope, store-helper and configuration surfaces.
- Component/tool registration, event and tap subscriptions, emit, request/reply
  helpers, structured logging with a level threshold, and an opt-in self test.
- Harness lifecycle from the client side: attach-or-spawn with root identity
  checks, probe patience, spawned-core reaping, and the interactive client
  marker that keeps an autostarted core alive.
- Bus-outage resilience: health probing, re-attach by re-resolving the URL,
  rebuilding subscriptions and re-announcing (with an explicit re-announce hook
  for components that defer their contract).
- The idle seam for periodic work, mirrored across all three SDKs with each
  runtime's own exclusion model.
- Nim: a typed tool macro that turns a proc (plus its doc comments) into a
  schema and handler, argument helpers, schema builders, block form, serialized
  callback-free pump.
- Go: chainable registration, concurrent-tool registration with a bounded
  limit, a queued delivery loop that keeps long handlers from stalling
  delivery, context-aware requests, and a graceful bounded shutdown drain.
- TypeScript: async handlers serialized on a promise chain, with npm packaging,
  slash commands, idle work and the same envelope contract.
- `.env` loading with documented precedence, size and file-type restrictions.
- Process-death handling so SDK-spawned children never outlive their parent.

## Self-extension, plugins and the ecosystem

See [MANUAL.md](MANUAL.md) "Self-extension and component lifecycle",
"Component ecosystem (`plugins`)".

- The full loop in one conversation: write source, build it, spawn it, discover
  its tools, call them — including replacing shipped machinery.
- Spawn waits for catalog acceptance: refusals and silent components fail the
  call with the reason and a child-log tail, and the attempt is rolled back.
- Persisted component shape restored on boot, with manifest definitions winning
  over stored records, missing-binary detection, and explicit non-restoration
  under `--minimal`.
- Component packages: GitHub repos with a manifest and a topic, versions pinned
  to releases, always built from source, with a bounded, shell-free recipe model
  and declared artifacts.
- Interactive package entries that are built but never supervised.
- Model source plugins as a documented, packaged extension shape.
- Bundled skills that make the harness useful out of the box, plus interop with
  the wider skills ecosystem.

## Clients and UI surfaces

See [README.md](../README.md) "Commands"; [MANUAL.md](MANUAL.md) "Clients and
the UI registry".

- Terminal admin shell, scripting client, bus viewer, the `niffler-tui`
  terminal chat plugin, and an experimental desktop/web client in its own repo.
- The UI registry: lease-based client liveness, conversation ownership
  claims, monotonic display numbers, and label handoff across restarts.
- Built-in slash-command set for status, model/provider/effort, approvals,
  limits, compaction, sessions, tools, locale and help — plus commands
  contributed by installed plugins and MCP servers.
- Keyboard and display affordances: reasoning/tool-card/effort cycling, slash
  completion, command history, approval prompts.
- Localization: English, Simplified and Traditional Chinese clients, docs and
  website, with typed catalogs so a missing translation fails a check.

## Configuration and state

See [MANUAL.md](MANUAL.md) "State and configuration", "Environment variables".

- Environment-driven configuration: every harness variable carries the `NIF_`
  prefix, with `.env` as the local override file and a commented reference
  copy, plus documented precedence rules.
- Settings that are not env: boot selection, store-backed registries, the
  conversation header, home/project files (skills, language-server registry,
  edit-undo store), browser display state, and `var/` derived state.
- The full store kind inventory used by core and components (conversations,
  messages, components, plugins, providers, toolset snapshots, slash table,
  subagent jobs/notices/lineage, programs, profiles, approvals, compaction
  receipts/inputs/projections, spills, attachments, MCP records, advisory
  shadow records).
- Single-writer discipline for the file-backed store and its lock; no
  cross-engine data movement.
- Disposable-vs-durable separation: `var/` is regenerable, the build cache and
  agent-built component sources live there too, and a durable barrier refuses
  to boot over removed storage formats.

## Operations: build, test, bench, docs

See [MANUAL.md](MANUAL.md) "Testing", "Recovery", "Common tasks";
[../Makefile](../Makefile); [bench/README.md](../bench/README.md).

- The Makefile as the front door: build, install/uninstall, run, clean,
  doctor, ram, scoped and global stop, recover, release flags, language-server
  install, the optional advisory runtime, and plugin installation.
- A complete bus-contract gate: one test per component plus cross-cutting
  suites, each owning a private bus and a temporary root, pooled with per-test
  logs and a summary; component-scoped targets for narrow runs.
- SDK unit tests (including race and vet passes) as part of the same gate.
- Contract-conformance lane for a replacement compactor, and an opt-in live
  summarization smoke test.
- Fixture components and mock models so behaviour that no real tool can produce
  on demand stays testable.
- Network-gated opt-ins for real installs, registry searches and toolchain
  builds, with hermetic alternatives in the default suite.
- Build serialization (a shared lock for builds and cleans) and test isolation
  from a live development harness.
- Bench: a cross-harness comparison framework with a task suite, imported
  external suites, adapters for other harnesses, and time/token/quality
  metrics with invalid-run guards and committed reports.
- Documentation set: manual (with localizations), wire spec, architecture,
  fabric guide, model-source guide, this inventory, the open-work plan, and the
  research corpus — plus a localized website and CI workflows.
- Release ritual: frozen green gate, version bump, changelog headline,
  pointer updates, translation refresh last, tag and GitHub release — and
  release of the plugins that ship fixed code.

## Explicitly not shipped

Design-only work, listed so the inventory is not mistaken for a roadmap. Open
work lives in [PLAN.md](PLAN.md); proposals live in
[research/](research/README.md).

- Store-backed global settings with a `/settings` surface.
- A generic stdio/NDJSON transport for plain scripts (pipewrap).
- Durable fabric/agent diagnostic traces.
- Resource-scoped (rather than global) write exclusion in the fabric batch host.
- Compilation-free JavaScript execution for TypeScript components.
- `fabric {api: true}` declarations and teammate-style collaboration.
- Automatic thinking/model escalation and de-escalation.
- Landlock/Seatbelt shell sandboxing.
