# Niffler vs Pi — architecture comparison

> What Niffler does differently from [Pi](https://pi.dev), the other minimal
> coding harness in this family — and where the differences are load-bearing
> rather than cosmetic.
>
> Basis: Niffler at `7b46ccd` (2026-09-13), Pi at `71dca871b` / npm
> `@earendil-works/pi-coding-agent` 0.85.1 (2026-09-11). This is a historical
> comparison snapshot; compaction, overflow recovery and subagent continuation
> have since landed on Niffler `main`. Pi claims are read
> from its shipped docs (`packages/coding-agent/docs/*`, `README.md`) and the
> `packages/` tree; Niffler claims from this repo, cited by path. This is a
> *difference map*, not a scoreboard: the [bench/](../bench/README.md) suite exists for
> measurements, and [research/PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md)
> is the feature-level "what to borrow" sibling of this document.
>
> Read [ARCHITECTURE.md](ARCHITECTURE.md), [WIRE.md](WIRE.md) and the repo's
> [`AGENTS.md`](../AGENTS.md) (which carries the invariants quoted here) first if you
> want the Niffler side in full; this file only compares.

## 1. The one-line difference

**Pi is a program. Niffler is a system of processes.**

Pi runs one Node process in which tools, extensions, skills, hooks, the
session, and the model loop all live in memory, extended in-process by
TypeScript modules (`pi.registerTool`), persisted as JSONL files. Niffler runs
a small Nim control plane (`core`, ~5.7k lines) on a NATS bus; every
capability — bash, edit, grep, git, store, llm, plugins, skills, MCP, the
agent's own conversation loop — is a separate OS process with its own SDK
(Nim, Go, TypeScript), interchangeable at runtime and replaceable by the agent
mid-conversation.

That difference propagates into almost everything below. The rest of this
document is that propagation.

| Axis | Pi | Niffler |
|---|---|---|
| Unit of execution | one Node process; extensions in-thread | one NATS bus; one process per capability |
| Extension seam | in-process TypeScript API (`docs/extensions.md`) | bus subject + JSON envelope (`docs/WIRE.md`); SDKs in Nim/Go/TS |
| State | JSONL entry tree on disk; in-process memory | `store` component (barrel/SQLite/TiDB) behind one bus contract |
| The model loop's process | the same process as everything else | one disposable `session` runner process per conversation |
| Tool-call transport | function call | `svc.<component>.call` request/reply, JSON envelopes |
| Prompt/tool prefix | compaction, dynamic tool activation | frozen-prefix doctrine + progressive discovery (`discover`/`invoke`) |
| Integration | CLI modes (`-p`, JSON, RPC) + SDK import | any bus citizen observes/drives it (`console`, `cli`, UIs, other agents) |
| Language policy | TypeScript only | language-agnostic by construction; support added as data or a plugin |

## 2. Composition: processes vs in-process plugins

Niffler's design rationale is written out in [research/REBOOT.md](research/REBOOT.md);
the short version against Pi:

- **Teardown = `exit()`.** Removing a capability is `core.kill` /
  `core.remove`; the OS disposes of its file descriptors, threads, memory and
  children. Pi's in-process extensions can be *unregistered*, but anything
  they started leaks unless the author wrote the inverse by hand.
- **Crash isolation.** The component author is an LLM that writes buggy code
  ([REBOOT.md](research/REBOOT.md) states this explicitly). A component crash
  is a bus departure; core restarts it per its policy (`restart: on-failure`)
  and the agent's conversation is untouched. In Pi, a bad extension or tool
  throws inside the same process as the session.
- **The mind is a process too.** One conversation = one process
  (`var/bin/session <id>`, [MANUAL.md § Session runners](MANUAL.md)). Killing
  it loses only the in-flight turn — the next call spawns a fresh runner that
  resumes from the store. Pi's equivalent durability work is the
  **AgentHarness** specification (`packages/agent/docs/harness.md`, WP00–WP07
  landed, several parts explicitly WIP) in the repo's `agent/` package, which
  is *not* the shipped coding-agent product: that still runs one process with
  JSONL sessions.
- **Language freedom.** The envelope codec is 77 lines of `std/json`
  (`sdk/envelope.nim`); SDKs exist in Nim, Go and TypeScript, and the `builder`
  component compiles agent-written components in any of them into `var/bin`
  mid-conversation. Pi's extension API is TypeScript, always in-process.
- **Replicas.** A stateless component may declare `replicas: N` (1–16); its
  NATS queue group distributes calls across processes that share one logical
  name. The shipped `grep` runs four. Pi's parallelism is threads/promises in
  one process.

What this costs Niffler: ~100µs per hop instead of a function call (accepted —
LLM calls take seconds), a NATS server in the deployment, and clone-as-instance
operational semantics (a clone claims its home bus; foreign cores are yielded
to loudly — [MANUAL.md § Environment](MANUAL.md)). What it buys: the
architecture's validation criterion — **the agent adds, rebuilds, and removes
its own capabilities mid-conversation**, which is a 3-step loop here (`builder
.build` → `core.spawn` → tool is live) and a fork-and-recompile of Pi.

## 3. The bus as the integration surface

Because everything is an envelope on a subject, Niffler gets things for free
that Pi builds per-mode:

- **Observability.** `./var/bin/console` subscribes to the entire bus and
  renders every call, result, event and approval of a live harness. The
  `observe` component keeps a bounded ring, probes, traces and an optional
  server monitor; `logfile` persists `ev.log.*` as rotating JSONL. Pi's
  equivalents are its modes and its TUI; there is no "watch the harness think"
  socket by default.
- **Scriptability.** `cli` drives any harness from a shell (`catalog`, `wait`,
  `call`, `install`) with exit codes — Niffler's plugin CI is exactly this:
  boot a harness, install a package, assert on tool output.
- **Many front-ends, one protocol.** The desktop UI and `niffler-tui` are NATS
  clients, not SDK users; `ui/frontend/src/nats.ts` is the entire integration
  surface. Pi has a well-documented TUI plus RPC/JSON modes, but a third-party
  UI integrates against its protocol rather than merely subscribing.
- **Approval routing is bus-native.** A gate request is published to the
  private subject of the client that drove the turn (`svc.approval.<caller>
  .request`, derived from the call envelope's self-declared `caller`), with an
  ack and a broadcast fallback, and `ev.approval.resolved` to clear stale
  modals — see §7.

The wire is deliberately small: 4 envelope kinds, `reg.>`/`svc.*`/`ev.*`
subject families, one reply per call, streaming as chunked events. Full spec:
[WIRE.md](WIRE.md). Pi's equivalent artifacts are its extension event types and
the experimental `protocol` package (CBOR, routed envelopes, v8, explicitly
"experimental, no compatibility guarantees").

## 4. The strict prompt-cache regime

This is the most consequential *policy* difference, and it is a doctrine, not a
trick. The stated rule ([`AGENTS.md`](../AGENTS.md) "Prompt-cache discipline",
[MANUAL.md § Context window](MANUAL.md)):

> a conversation's request prefix — the frozen system prompt plus the frozen
> direct tool schemas — must stay byte-stable for the conversation's lifetime;
> history only grows.

Concretely:

1. **The system prompt is frozen into the conversation header** at creation
   (`resolveSystemPrompt` in `core/conversation.nim`); the `systemprompt`
   component composes it once (product prompt + the repo's
   `AGENTS.override.md`/`AGENTS.md` chain). A component swap, a new skill, or
   a new tool never rewrites it.
2. **The direct tool schema set is frozen at the first turn**, persisted under
   store kind `session`, id `<sessionId>:tools`. Late registrations never
   mutate an existing conversation: the model reaches them through discovery
   (§5). A departed component's schema stays for cache stability.
3. **Discovery enters as history, not as a prefix change.** `discover` returns
   schemas *inside a tool result* — an append-only message — and `invoke` is a
   fixed generic gateway declared from turn one. The model therefore needs no
   new declaration in the tools array to call a just-discovered tool.
4. **Exactly two sanctioned prefix changes exist**, and both are named on the
   wire: a context trim (`reason: "reset:trim"`) and a sticky `invoke`
   promotion (`reason: "reset:tools"`, emitted only when the direct set
   actually grew, capped by `NIF_MAX_DIRECT_TOKENS`, default 4000 estimated
   tokens). Everything else is append-only history.
5. **Cache hits are measured and surfaced.** The `llm` adapter forwards
   `prompt_tokens_details.cached_tokens`; `ev.session.status` carries
   `cacheHitTokens`/`cacheHitRatio`; the web UI and TUI render them per turn.
   A low ratio with a stable prefix is a signal, not ambient noise.

Pi's approach is also cache-aware — compaction requests disable cache writes,
`PI_CACHE_RETENTION=long` extends provider TTLs, and native **deferred tool
loading** injects activated schemas at the tool-result position for Anthropic
and OpenAI — but Pi's default posture is "the active tool list *is* the tools
array, changes are allowed". Its own docs warn that activating a tool can
invalidate the prefix. Niffler chooses the stricter invariant and pays for it
with the `invoke` indirection: an on-demand call is always
`invoke {tool, arguments}` instead of a natively declared function.

The IV.4 trade-off is explicit in [MANUAL.md § Session state and caching](MANUAL.md):
Pi's deferred-loading model gives better token shape (no gateway indirection,
native validation) while keeping a stable prefix; Niffler's `invoke` keeps the
prefix bit-exact for *every* provider, at the cost of one level of argument
nesting. The feature scan proposes `x-harness.loadable` as the middle ground
([research/PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §2.2) — it is not
shipped.

## 5. Progressive tool discovery (`discover` / `invoke`)

Pi's shipped surface gives the model a handful of built-in tools
(`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`) plus whatever
extensions registered — all in the prompt (extension docs describe
*inactive* tools and a loader, which is Pi's answer to the same problem).

Niffler separates **existence** (global catalog) from **exposure** (per
conversation):

| Level | Metadata | In the frozen tools array | Discoverable | Callable via |
|---|---|---|---|---|
| direct | — | yes | yes | direct or `invoke` |
| on demand | `x-harness.onDemand: true` | no | yes (hints/schemas) | `invoke` |
| hidden | `x-harness.hidden: true` | no | no | components/core only |

The shipped manifest exposes **seven** direct tools (`discover`, `invoke`,
`bash`, `grep`, `read`, `edit`, `write`) while the catalog behind them holds
the store, git, git-blame, observe, logfile, skills, fabric, agent, MCP, LSP,
plugins, builder, models, provider and fetch tools — all reachable on demand.
`discover` is deterministic and cache-friendly by construction: name-sorted,
whitespace-normalized hints capped at 200 chars, volatile fields (pid,
registration time) excluded, at most 16 schemas per call. Hidden and unknown
tool lookups return the *same* error shape, so discovery is not an existence
oracle for internal surfaces. `invoke` re-enters the single dispatch gate, so
approval, timeout, schema validation and routing behave exactly as for a
direct call. Named **tool profiles** (`profile`, `session.profile`, `NIF_PROFILE`)
resolve a different direct set at conversation creation; `invoke {sticky:
true}` is the one durable promotion path.

Consequences unique to Niffler: the model can reach a tool a component
*registered after the conversation started* (`plugin_install` mid-session)
without a prefix change, and the UI can show exactly which exposure state each
live tool is in for the active conversation (`/components all|direct|
discovered|undiscovered`, colored chips in the web UI).

## 6. Context pressure: trim vs compaction

At the snapshot, Niffler was deliberately simple ([MANUAL.md § Context window](MANUAL.md)):
warn at 75%, at 90% drop **whole turns** from the front. Since then, Niffler
has added a durable context ledger, deterministic prune/trim, replaceable
compaction and recall, provider-scale accounting, and bounded provider-overflow
recovery. Per-session budget controls still freeze at first call and remain
explicit stops rather than silent degradation.

Pi has real **compaction**: structured LLM summaries with an iterative
previous-summary input, a configurable reserve (`reserveTokens`, default 16k),
a retained recent window (`keepRecentTokens`, default 20k), manual
`/compact [instructions]`, auto-compaction on overflow *and* proactively, plus
branch summarization on `/tree` navigation.

Niffler's shipped answer is documented in [research/COMPACTION.md](research/COMPACTION.md):
a replaceable `compaction` component (`compaction_propose` / `context_recall`)
where the *runner* validates, applies and persists — the component proposes,
core never delegates mutation of its own conversation, and replaced content
keeps a durable recall link. SQLite is now the default store engine, with
Barrel and TiDB selectable behind the same contract.

## 7. Policy rides the schema — and where it is enforced

Niffler's `x-harness` extension object travels with the tool schema, so one
JSON Schema artifact carries contract + policy + docs. The shipped keys:

`approval`, `timeoutMs`, `hidden`, `onDemand`, `sessionContext`, `sessionId`,
`effect` (read/write scheduling for fabric's batch host), `workspace` (path
arguments resolve against the conversation workspace), `noSpawn` (subagents
cannot spawn subagents, checked at dispatch), `parallel` (safe to fan out in a
turn wave).

The dispatch path in core honors them uniformly — `invoke`, subagents, fabric
programs and direct calls all pass through the same gate. Policies are thus
data on a schema, not code in a policy engine; a third-party component
declares its own.

**Approvals** ([MANUAL.md § Approvals](MANUAL.md)): a tool marked
`approval: "always"` (bash, write/edit, spawn/kill/remove, fabric, agent,
plugin/skill install, provider credentials, observe writes…) blocks on a
human. Terminal: y/N. Service mode: routed to the *specific* interactive
client driving the turn via its private subject, ack-gated, broadcast
fallback, `ev.approval.resolved` cleanup. **No human reachable → denied**,
never silently approved (`NIF_AUTO_APPROVE=1` for headless automation).
Subagent approvals route to the original caller's UI, so the human sees every
gate inside delegated work. Fabric programs get an **approval manifest**: the
full source at a digest-keyed `var/approval-sources/<digest>.nim` (0600), the
selected tools, the budgets — and persisted auto-approval is keyed by
`fabric:<digest>`, so "always approve fabric" can never cover unreviewed
source.

Pi's position is the opposite philosophy on defaults: *no permission popups
by design* ("run in a container, or build your own confirmation flow"), while
its `tool_call` hooks can **block and rewrite** arguments in place
(`{block: true, reason, terminate}`) — strictly more expressive than Niffler's
gate, and per the feature scan an acknowledged Niffler gap ("hooks with teeth";
`components/hooks` is observe-only by design today).

## 8. Fabric, subagents, and the expert peer

These three exist because components can call back into the session's dispatch
path — a shape Pi would need extensions to emulate (and a third party did:
`pi-fabric` is an extension that adds a `fabric_exec` TypeScript tool).

**`fabric`** — programmable tool calling ([FABRIC_GUIDE.md](FABRIC_GUIDE.md),
[research/FABRIC.md](research/FABRIC.md)). The model writes a small **Nim
program**; `fabric-exec` compiles it (no embedded VM any more —
`73bfc03`, content-addressed cache in `var/fabric-cache`) and runs it in a
private process with a cleared environment, no NATS connection, RLIMIT caps,
`setsid` and an fd sweep. The guest's tool calls cross a framed stdio bridge to
the parent component, which dispatches them through the session's nested-call
proxy (`svc.session.<id>.tool`) — so every call re-enters the *same* approval,
schema-validation and deadline gate. Only `finish(value)` reaches the
conversation; oversized values spill to 0600 artifacts. Selected-tool mode
pins catalog fingerprints and generates input-typed `tools.<name>(...)`
wrappers, so a wrong argument type is a **compile error in the generated
program**, not a runtime failure. Budgets: `maxCalls`, `timeoutMs`, per-turn
lease, depth guards, `batch(...)` with effect-aware concurrency, and a
model-curated `fabricprog` library in the store. Public posture: **governance,
not sandbox** — the program is approved as a whole, bash-class trust, and the
architecture keeps every effect crossing the gate on purpose.

**`agent`** — subagents as sessions of their own (`agent_run` synchronous,
`agent_spawn` durable background jobs with `agent_status`/`agent_wait`/
`agent_stop`/`agent_steer`; store kind `agentjob`; child runners driven via
`session_prepare` so concurrent calls never deadlock core's stash; per-job
`model`/`thinking`/`tools`/`maxRounds`/`maxCalls`/`maxTokens`; depth guard at
dispatch; lazy restart recovery that never reports a dead job as "running").

**`expert`** — a non-interactive *advisory peer* ([MANUAL.md § Expert](MANUAL.md),
[research/EXPERT.md](research/EXPERT.md)): it follows sessions armed via
`expert_follow`, observes their bounded current-turn events, and a stateless
LLM judge over a cache-stable knowledge prefix decides whether to steer the
working session — delivered through a **turn-bound** `svc.session.<id>.advise`
request/reply that rejects stale advice rather than queuing it. Silent by
default, fail-closed on any parse/transport error, never performs work.

Pi's philosophy is explicit — *no sub-agents in core* — with delegation left to
tmux or extensions. So this is not "Pi lacks the capability"; it is "Niffler
makes it part of the governed dispatch path, so approvals, budgets, lineage and
cancellation apply to delegated work identically".

## 9. Concurrency model

Niffler's default SDK pump is single-threaded, callback-free and serialized
([`AGENTS.md`](../AGENTS.md)): poll subscriptions, run one handler at a time,
normal GC, never
`asyncdispatch`. Concurrency is then an explicit, per-layer decision:

| Mechanism | Scope | Control |
|---|---|---|
| Turn waves | sibling tool calls marked `x-harness.parallel` fan out over distinct inboxes, results committed in model order | per-tool schema flag; approval/session-context tools stay serial |
| Process replicas | same logical component, N processes, NATS queue group (`replicas: 1–16`; `grep` ships 4) | manifest/`core.spawn` |
| Component-owned threads | long-lived workers inside one component (`std/threads`+locks; Go goroutines) | component-local, audited |
| `ToolConcurrent` | audited Go handlers (both LLM adapters) | explicit registration |

Pi's default is parallel tool execution in one Node process ("sibling tool
calls … executed concurrently", with per-file mutation queues so parallel
`edit`/`write` don't lost-update) — simpler and more uniform, but it is thread
concurrency inside the same process that also owns the session and every
extension.

## 10. Data plane: a store component with interchangeable engines

Pi persists sessions as JSONL files (a tree of entries), with an optional
SQLite session backend package implementing a `SessionRepo` interface.

Niffler's `store` is *a peer on the bus*: `put/get/list/del` + `expectRev`
optimistic concurrency, single-writer enforced by file flock (or, for TiDB, by
the cluster). Three engines are interchangeable behind the identical contract,
selected at boot with `NIF_STORE_BACKEND`: **barrel** (embedded BitBarrel KV,
default), **sqlite** (`store-sqlite`, Go, atomic single-statement put,
goose migrations, inspectable with any SQLite tool), **tidb** (network-shared
cluster store for multiple harnesses). Kinds in use: `conversation`,
`message`, `component` (the persisted shape of spawned components), `plugin`,
`provider`, `session`, `slash`, `agentjob`, `sessionmeta`, `fabricprog`,
`mcp`, `skill` installs.

Architectural consequences: (a) the mind's state is external and swappable —
killing a runner loses nothing; (b) the store itself is killable/replaceable
because the *contract* is the artifact, and the quest "port it to SQLite and
compare" is a dogfooding exercise the agent can run on itself; (c) any bus
client can read conversations with `cli`, and offline the values are plain
JSON in `var/barrel-db`.

## 11. Self-extension and the ecosystem

Niffler's loop, all mid-conversation and human-gated: write source →
`builder.build {lang}` (Nim / Go / TypeScript; a generated Go `go.mod` wires
`sdk/go`) → `core.spawn {name, binary, replicas?}` → component registers →
catalog updated → reachable. The spawned set is persisted (store kind
`component`) and restored on boot; `--minimal` deliberately leaves them
stopped; `--recover` rebuilds shipped binaries from source and wipes records
while keeping conversations.

The ecosystem is component packages: plain GitHub repos with a `niffler.json`
manifest and the `niffler-component` topic; `plugins` discovers
(`plugin_search`), clones, builds from source with the same builder, spawns
service components, marks `"interactive": true` entries as user-launched
clients, and records installs. `cli install <repo>` is a full CI harness.

Pi's ecosystem is **pi packages** on npm/git: extensions (in-process TS),
skills, prompt templates, themes — installed via `pi install`, configured with
`pi config`, discovered by convention. Pi's docs are blunt that packages run
with full system access; Niffler's equivalent risk surface is approval-gated
installation plus process isolation (and, in both systems, bash-class trust
once installed).

Two Pi capabilities with no Niffler equivalent yet are worth naming here: a
**project trust gate** (Pi asks before loading project-local settings,
packages and extensions; Niffler auto-loads `manifest.yaml` and restores
plugin records for whatever repo is the harness home — the feature scan maps
the fix, §2.3) and **prompt templates** (parameterized `/name args` markdown;
Niffler has skills but no `$1`/`${@:N}` expansion).

## 12. Provider and model layer

Niffler splits it into two components: `models` (models.dev baseline +
offline seed + plugin patches, with capabilities/limits/prices and a
`llm_resolve` result carrying secret-free provenance) and `provider` (a
**store-backed registry** of LLM backends under kind `provider`, with an
active marker, transparent OAuth token refresh for ChatGPT Codex and Claude
Pro/Max — PKCE browser and device flows — and `ev.provider.switch`
notifications). The `llm` component routes three wire protocols
(OpenAI-compatible chat, OpenAI Codex Responses, Anthropic Messages) with
translation and streaming in all three; credentials live in `provider`, and
the `llm` component never sees a refresh token. Model/thinking are per-turn,
per-conversation header fields, switchable mid-conversation; the provider
registry is a bus capability any client (UI, TUI, agent) can edit through
approval-gated tools.

Pi has a comparable (arguably broader) provider catalog, `/login` OAuth for
several subscription services, model cycling and a strong per-model settings
layer (`thinkingBudgets`, `modelThinkingLevels`, `supportsMidConvoEffort`), but
it is configuration + in-process model runtime rather than components that can
be replaced at runtime. Niffler's provider-admin tools are hidden from the LLM
(credentials); Pi's are UI commands.

## 13. Tool-suite differences worth knowing

Everything here is a component, hence disposable, replicable, and callable by
other components:

- **`lsp`** — one tool (`diagnostics`, `goToDefinition`, `findReferences`,
  `goToImplementation`, `hover`) over any configured stdio language server;
  the registry is *data* (`servers.json`, defaults for six languages, an
  approval-gated `lsp_registry add`), per the language-agnostic-core
  invariant. Pi has no built-in LSP surface (its docs list language servers as
  ordinary local processes started by the user/tooling).
- **`mcp`** — an MCP *manager* plus one supervised `mcp-bridge` process per
  server; server tools become ordinary catalog tools namespaced
  `mcp_<server>_<tool>` (on demand by default), server prompts become hidden
  tools and slash commands, resources become a read-effect tool with spill,
  and `mcp_search` browses the official registry. Pi deliberately ships no
  MCP (extensions or CLI tools with READMEs instead).
- **`observe` + `logfile` + `console`** — live ring/probes/traces, rotating
  structured logs, and a whole-bus viewer: diagnosis without an LLM.
- **`hooks`** — bus-event → shell command, observe-only (explicitly *not*
  Pi's veto/patch hooks).
- **`skills`** — Agent Skills (SKILL.md) discovery across the standard agent
  dirs, progressive-disclosure loading, skills.sh search, and git-based
  install with no Node dependency. Pi has the same format and conventions;
  Niffler also makes install/remove approval-gated and confined.
- **`git`** — read-only inspection tools (status/diff/log/show/blame) over
  fixed argv, approval-free, scoped to the harness root; mutations stay in
  bash. Pi provides `bash` and relies on it (plus its built-in
  `grep`/`find`/`ls`).
- **Slash commands as declarative component data** — a component registers a
  spec (name, description, target tool, typed params, completion sources) and
  any UI renders it; the table is checkpointed in the store. Pi registers
  commands from in-process extensions.

## 14. What Pi has that Niffler does not

Honest list, because a comparison that only cuts one way is marketing:

- **Session tree**: in-place branching, `/tree`, `/fork`, `/clone`, labels,
  filters, branch summaries, message queues with steering and follow-up
  delivery modes. Niffler has a replay-valid fork for subagent births, but no
  navigation UI for general conversations. Planned: session tree in
  [research/PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md) C1.
- **In-process extension API richness**: custom editors, UI widgets,
  rendering for tool calls/results, keybindings, themes, hot reload. Niffler's
  UI dynamism is an explicit open item (PLAN.md: Level 1/2 UI dynamism).
- **Hooks with teeth** (block/patch tool calls and results).
- **Project trust** for untrusted checkouts (see §11).
- **Evals package**: model-backed behavioral checks with session artifacts.
  Niffler has strong bus-contract and mock-LLM loop tests; a `make eval`
  driving real sessions through `svc.core.call` is a proposal in the feature
  scan.
- **Mature RPC/SDK embedding modes** (`--mode rpc`, `--mode json`, SDK
  package) and a large TUI feature surface (themes, keybindings, editors,
  image paste).
- **Image inputs / multimodal reads**: Pi reads and resizes images;
  Niffler's file tools are text-only.
- **A package registry** (npm) for sharing extensions; Niffler's plugin
  ecosystem is GitHub-repo-based and younger.
- **Operational simplicity**: `npm install -g` and go. Niffler needs Nim,
  Go, native libraries, and builds its own NATS server — a real adoption
  cost for the process model's benefits.

Both systems today share one gap: **neither sandboxes the agent**. Pi says so
in `docs/security.md`; Niffler says so in [research/SANDBOX-PLAN.md](research/SANDBOX-PLAN.md)
(a revised plan exists; nothing is implemented).

## 15. Where the designs converge

Worth stating, because the convergence is informative:

- Both treat the JSON Schema as the tool contract and the doc comment as the
  model's only when-to-use guide.
- Both freeze a cache-stable prefix (Pi by defaulting to stability, Niffler by
  doctrine) and both report cache statistics to the user.
- Both isolate subagents *conceptually* (Pi via extensions/tmux, Niffler via
  child sessions) and both recently grew durable-execution designs
  (Pi: AgentHarness; Niffler: store-v2 + compaction + durable agent jobs).
- Both keep the model loop small and push capability outward — Pi to
  extensions, Niffler to components. The disagreement is only about the
  boundary: in-process for Pi, process+bus for Niffler.

## Appendix — evidence map

| Claim | Niffler evidence | Pi evidence |
|---|---|---|
| Process components, SDKs, builder/spawn | `manifest.yaml`, `sdk/`, `components/`, [docs/ARCHITECTURE.md](ARCHITECTURE.md) | `packages/coding-agent/docs/extensions.md` (`pi.registerTool`) |
| One conversation = one process | `core/session.nim`, `var/bin/session`, [MANUAL.md § Session runners](MANUAL.md) | `packages/agent/docs/harness.md` (durable harness; WP status §0.9) |
| Frozen prefix doctrine | `AGENTS.md` "Prompt-cache discipline"; `core/conversation.nim:resolveSystemPrompt`; store kind `session` | `docs/compaction.md`; `docs/extensions.md` "Dynamic Tool Loading" |
| Progressive discovery | `core/catalog.nim`, `core/dispatch.nim`, [MANUAL.md § Progressive tool discovery](MANUAL.md); `tests/t_discover.nim` | deferred activation: `extensions.md` § Dynamic Tool Loading; `ai/src/utils/deferred-tools.ts` |
| Context trim | [MANUAL.md § Context window](MANUAL.md) (75%/90%, named reset reasons) | `docs/compaction.md` (summaries, reserve/keep windows) |
| `x-harness` policy keys | [WIRE.md](WIRE.md) § x-harness schema extensions; `core/dispatch.nim` | hooks: `extensions.md` "Tool Events" (`block`, mutable `event.input`) |
| Directed approvals | `core/approval.nim`, [WIRE.md](WIRE.md) § Approvals | `docs/usage.md` Philosophy ("No permission popups") |
| Fabric / subagents / expert | [research/FABRIC.md](research/FABRIC.md), [FABRIC_GUIDE.md](FABRIC_GUIDE.md), `components/fabric/`, `components/agent/`, `components/expert/` | `README.md` Philosophy (no sub-agents); `pi-fabric` third-party extension |
| Store engines | [MANUAL.md § Store engines](MANUAL.md), `components/store*`, [research/STORE_V2.md](research/STORE_V2.md) | `docs/sessions.md` (JSONL), `packages/session-backends/sqlite-node` |
| Self-extension + recovery | [MANUAL.md § Self-extension](MANUAL.md), § Recovery; `components/builder`, `components/plugins` | `docs/packages.md`, `pi install` |
| Provider registry + OAuth | `components/provider/`, `components/llm/`, [MANUAL.md § Provider registry](MANUAL.md) | `docs/providers.md`, `docs/custom-provider.md`, `/login` |
| LSP as data; MCP bridges | `components/lsp/`, `components/mcp/`, CHANGELOG "lsp: language-server seam" | no built-in LSP/MCP in core (`docs/usage.md`) |
| Session tree / branching | linear `kind=message` ([MANUAL.md § The store](MANUAL.md)) | `docs/sessions.md` (`/tree`, `/fork`, `/clone`), `docs/session-format.md` |
| Project trust | unguarded manifest/plugin restore | `docs/usage.md` § Project Trust |
| No sandbox in either | [research/SANDBOX-PLAN.md](research/SANDBOX-PLAN.md) | `docs/security.md` |
