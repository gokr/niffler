# Niffler Manual

[English](MANUAL.md) · [简体中文](MANUAL.zh.md) · [繁體中文](MANUAL.zh-TW.md)

Everything you need to operate, configure and recover a Niffler harness, plus
reference chapters for the shipped components. Design rationale lives in
[research/REBOOT.md](research/REBOOT.md); the wire protocol is
[WIRE.md](WIRE.md); the core/component boundary is
[ARCHITECTURE.md](ARCHITECTURE.md); open work is consolidated in
[research/PLAN.md](research/PLAN.md).

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Store engines](#store-engines)
- [State and configuration](#state-and-configuration) · [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch)
- [External MCP servers (`mcp`)](#external-mcp-servers-mcp)
- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)
- [Progressive tool discovery (`discover`/`invoke`)](#progressive-tool-discovery)
- [Model catalog (`models`)](#model-catalog-models)
- [System prompt (`systemprompt`)](#system-prompt-systemprompt)
- [Observation and logs (`observe`, `logfile`)](#observation-and-logs)
- [Hooks](#hooks)
- [Fabric and subagents](#fabric-and-subagents)
- [Expert advisory peer (`expert`)](#expert-advisory-peer-expert)
- [Recovery](#recovery) · [The store](#the-store) · [Testing](#testing)
- [Starting and stopping](#starting-and-stopping) · [Common tasks](#common-tasks) · [Troubleshooting](#troubleshooting)

## Layout of a running system

| Path | What it is |
|---|---|
| `core/` | the control plane: system harness (`niffler.nim`: bus bootstrap, supervisor, catalog, dispatch) + the session runner (`session.nim`) and the turn loop it drives (`conversation.nim` — the largest module — plus `compaction.nim`, `approval.nim`, `retry.nim`, `uireg.nim`, `tty.nim`) |
| `components/` | shipped component sources — one directory per component (Nim, Go, TypeScript and one bash demo); the inventory is the [Shipped components](#shipped-components) table below, which is the part that has to stay current. Two directories are not bus citizens: `components/nats` builds the `var/bin/nats-server` core spawns when a bus has to be started, and `components/ctxtest` is a fixture the nested-call tests (`t_fabric`, `t_agent`) compile for themselves |
| `sdk/` | Nim SDK (`sdk/niffler`) + `sdk/go` (Go) + `sdk/ts` (TypeScript/Node.js, npm package `niffler-sdk`); the envelope in `sdk/envelope.nim` is the artifact |
| `docs/` | this manual, the wire spec (`WIRE.md`), the settings design (`research/SETTINGS.md`), the core-boundary rationale (`ARCHITECTURE.md`), the fabric user guide (`FABRIC_GUIDE.md`), open work (`research/PLAN.md`) and `research/` (design history) |
| `manifest.yaml` | bootstrap manifest: which components core spawns, restart policy, and optional stateless `replicas` count; `--minimal` filters it to `store`, `bash`, and `llm` |
| `var/` | **runtime state, gitignored, disposable** — the repo is the snapshot |
| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |
| `var/store.db` | the SQLite store's data file (default engine) — **single-writer**: exactly one `store` process may open it. Older harnesses/migrated roots use `var/barrel-db` instead |
| `var/nats-url` | bus address of the last spawned bus; the UI bridge reads it to find core |
| `var/nats-monitor-url` | HTTP monitoring endpoint when core spawned the bus; absent for reused/remote buses |
| `var/logs/`, `var/captures/` | rotating structured logs and explicit observe probe exports (see [Observation and logs](#observation-and-logs)) |
| `var/toolout/` | `bash` spill files (`<session>/<pid>-<epoch>-<counter>.out`) written when a command's output exceeds the inline cap — absolute paths that `read` can page through; swept after 1 h, so an old turn's path may be gone |
| `var/approval-sources/`, `var/mcp-results/`, `var/review-receipts/`, `var/fabric-cache/`, `var/plugins/` | approval prompt payloads, MCP bridge results, `review_receipt` fingerprints, compiled fabric programs and installed plugin clones — all disposable |
| `var/models/`, `var/processes/`, `var/repomap-tags/`, `var/fetch/` | component state: the models.dev catalog cache, background-process records, the repomap tag cache, spilled fetch bodies |
| `var/nats-pid` | pid of the bus core spawned (crash cleanup only — a live core stops its own bus on exit) |
| `var/build/` | source files of agent-built components (builder's scratch dir) |
| `nimcache/`, `ui/build/`, `ui/frontend/node_modules/`, `ui/frontend/dist/` | build artifacts; `make clean` removes them |

### Shipped components

| Component | Language | Manifest | What it does |
|---|---|---|---|
| `store` | Nim/Go | required | document store over the bus (`put/get/list/del`, rev-based concurrency). All four tools are on-demand, and `del` is additionally hidden — core deletes records, the model cannot. Engines register under the same name with identical tools: `store-sqlite` (Go, SQLite + goose migrations, `var/store.db`) is the **default**; `barrel` (`var/bin/store`) and `tidb` remain selectable with `NIF_STORE_BACKEND` — see [Store engines](#store-engines) |
| `bash` | Nim | required | the classic tool: shell commands with timeout + output cap. Commands run as the leader of their own process group, so a timeout or a cancelled turn kills the whole tree (exit 124 / 130) — no orphaned children. Results carry `text` (an `(exit N)` status line — non-zero = failure; 124 = timeout, 130 = cancelled, 126 = cwd not enterable (the tool also uses 126 for found-but-not-executable), 127 = `bash` not on `PATH`, 128 + signal when the command killed itself (139 = SIGSEGV, 143 = SIGTERM) — followed by combined stdout/stderr; this is what the LLM transcript shows) plus machine fields `exit_code`, `cancelled`, and `spill {path, bytes, lines}` when oversized output spills to a file under `var/toolout/` (the absolute path is in `spill.path`; pageable with `read`, swept after 1 h). `run_in_background: true` hands a long-running command (server, watcher) to the `processes` component instead of blocking — see [Background processes](#background-processes-processes) |
| `repomap` | Nim | optional | ranked workspace map (docs/research/REPOMAP.md): the load-bearing files and their key definitions in ~1KB, built from a tree-sitter + native-Nim tags graph with personalized PageRank (the aider repomap port). `repo_map {workspace?, focus?, mentionedIdents?, budget?}` is onDemand and read-effect — the model asks, nothing is injected. The workspace-open auto-append (one append-only entry on `ev.workspace.opened`; the component publishes it, the runner appends it) is **off by default**: set `NIF_REPOMAP_AUTOAPPEND=1` to opt in. It ships off because the A/B did not clear the bar (full30: ~40% more tokens, no accuracy gain; Multi10 high 8/10 vs 9/10 with it on, though the low rerun inverted that and the original high run partly measured stub maps — see `bench/reports/repomap-ab-*.md`) and onDemand tools never activate themselves. Opted in, the append is also **gated** (`docs/research/REPOMAP-GATES.md`): a workspace below the census floor is never built and a stub map (byte/symbol/file thresholds) is never injected — withheld maps are logged as `repo map withheld`. With the append off this is simply a component the model can discover when it wants orientation. Cache: `var/repomap-tags/` (mtime-keyed). Optional component — absent means no map, nothing else changes. Parameters, budget default and cap, tag tiers and the append payload: [`repomap` in detail](#repomap-in-detail) |
| `processes` | Nim | optional | long-running commands with an owner: `process_start` (detached, own process group, returns an id at once), `process_poll` (drains incremental output), `process_kill` (stops the group), `process_list` — see [Background processes](#background-processes-processes) |
| `builder` | Nim | required | compiles agent-written Nim/Go/TypeScript source into binaries: `build {lang, name, source, files?, defines?}` (approval-gated, on demand) and `info` (on demand: the per-language source skeleton and SDK locations) |
| `llm` | Go | required | streaming chat adapter — three hidden tools, none of them in a conversation's direct set: `chat` (one inference, `ev.llm.token` deltas, cancellation; `runner`-exempt, timeout `NIF_LLM_TIMEOUT_MS`), `llm_resolve` (the credential-free resolution probe clients call) and `llm_models_source` (the `x-models-source` v1 live-id source the `models` catalog calls) — protocols: OpenAI-compatible Chat Completions, OpenAI Codex (ChatGPT OAuth) Responses and Anthropic Messages; `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml` |
| `models` | Go | optional | models.dev provider/model catalog, atomic cache, strict resolution, and plugin correction/discovery layers (see [Model catalog](#model-catalog-models)) |
| `provider` | Go | optional | store-backed LLM provider registry: `provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`, subscription OAuth login (`provider_oauth_start`/`complete`/`cancel`), `ev.provider.switch` notifications |
| `plugins` | Nim | optional | ecosystem front door: topic search + install/update/remove of packages |
| `skills` | Nim | optional | Agent Skills (SKILL.md): discovery, load, resource access, git-based install/remove |
| `fetch` | Nim | optional | web content retrieval: http/https, HTML→text extraction, size caps with file spill |
| `edit` | Nim | optional | the file tools: `read` (canonical `reads` array — up to 12 files/ranges in one call (per item 2000 lines, 256 KB, 2 KB per line — a longer line becomes a `bash: sed -n …` notice; 512000 bytes aggregate per call, the remainder reported as a per-item error that does not fail the batch), pageable, single-file `path` sugar; a whole read of a >1000-line file with a language server for its type returns the lsp symbol outline instead — window with offset/limit, or `offset: 1` to read whole anyway, `NIF_READ_OUTLINE_LINES` tunes/disables — a whole re-read of a file ≥512 bytes that this conversation already read in full and that is byte-identical returns `[unchanged] <path>: N bytes, M lines, digest <sha1>` instead of the text; `force: true` (or any offset/limit window) forces the re-dump, and windowed reads and small files always re-dump), `edit` (only ever changes *existing* text files — a missing path is `E_NOT_FOUND`, an empty file `E_EMPTY`, both pointing at `write` as the way to create content; takes an `edits[]` array of `{old_string, new_string, replace_all?}` pairs — there is no separate multi-edit tool — all matched against the *original* file, checked for overlap and no-change, then written in one atomic rename; the guarded fallback cascade is trailing whitespace → indentation drift → unicode punctuation → block anchors by Levenshtein similarity ≥ 0.65 → double-escaped text, and every tier must still match exactly once; a staleness gate sits *before* matching — when the conversation's last-observed digest of the file differs from disk (an external edit, or a `bash` mutation since the read/write), `edit` refuses with `E_STALE` instead of matching text the model has never seen: re-read and redo. Session-less callers (`cli`, other components) are not tracked and skip the gate), `write` (atomic whole-file: creates parent directories, follows symlinks, preserves the target's permissions, caps the payload at `NIF_WRITE_MAX_BYTES` = 900000), `undo_last_edit` (single-level per file — the previous edit only, not a stack — persisted across restarts and keyed by absolute path, reverting content, BOM and line endings exactly; refused with `E_UNDO_STALE` when the file was modified or deleted after the edit, in which case the stale record is *discarded* (re-read and edit forward); the undo record is written before the file, so a store failure refuses the edit with `E_UNDO_UNAVAILABLE` rather than losing the ability to revert; approval-gated mutations); anchored block moves live in the [niffler-hashline](https://github.com/gokr/niffler-hashline) plugin |
| `lsp` | Nim | optional | language-server seam: one `lsp` tool — `diagnostics` (compiler/lint errors without a test run), `documentSymbol` (file outline: every symbol with kind, name and one-based position), `workspaceSymbol` (repo-wide symbol search on the server's index — fuzzy `query`, cross-file results), `goToDefinition`, `findReferences`, `goToImplementation`, `hover`, `warmup` — plus `lsp_servers` (list the merged registry) and `lsp_registry` (`add`/`remove` an entry, approval-gated) — over any configured stdio language server (gopls, nimtortoise, typescript-language-server, pyright, rust-analyzer, clangd, bash-language-server, jdtls, intelephense, solargraph, csharp-ls by default). The registry is data (`$XDG_CONFIG_HOME/niffler-lsp/servers.json`): adding a language is a config entry or an `lsp_registry add` the agent can make itself — never code (AGENTS.md: language-agnostic core). On-demand tools |
| `git` | Nim | optional | read-only repo inspection: `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame` over fixed argv (approval-free; mutations stay in bash) plus `review_receipt` — a local diff-fingerprint write/check pair under `var/review-receipts/` for pre-push review handoff (never calls a model; check fails when the diff changed since the receipt). On-demand tools — the worker reaches them via `discover` + `invoke`, keeping the direct toolset small |
| `agent` | Nim | optional | subagent sessions, nine tools: `agent_run`/`agent_spawn` (fresh or continued children, background jobs, durable settlement notices) plus `agent_status`/`agent_wait`/`agent_stop`/`agent_steer`/`agent_ask`/`agent_notices`/`agent_list` — see [Fabric and subagents](#fabric-and-subagents) |
| `expert` | Nim | optional | advisory peer: follows one or more sessions concurrently, LLM-judged, turn-bound steer (see [Expert advisory peer](#expert-advisory-peer-expert)) |
| `fabric` | Nim | optional | programmable tool calling: the model writes a Nim program that orchestrates tools; only its `finish()` value enters the conversation (see [Fabric and subagents](#fabric-and-subagents)) |
| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |
| `systemprompt` | Nim | optional | the conversation constitution: session runners fetch the system prompt from `svc.systemprompt.call` once per conversation (see [System prompt (`systemprompt`)](#system-prompt-systemprompt)) |
| `compaction` | Nim | optional | default replaceable `compaction_propose` implementation: verifies runner-owned paged snapshots, chooses a permitted cut, and returns a structured checkpoint candidate; the runner alone validates and commits projections |
| `recall` | Nim | optional | on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint — plus `mode: search`, a grep over the conversation's whole canonical history (trimmed/compacted-away messages included) |
| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |
| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |
| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring (see [Observation and logs](#observation-and-logs)) |
| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) |
| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |
| `mcp` | Go | optional | external MCP servers (Model Context Protocol): store-backed registry (`mcp_servers`/`mcp_search`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`), one supervised bridge per server; tools become ordinary catalog tools reachable through `discover` + `invoke` (see [External MCP servers](#external-mcp-servers-mcp)) |
| `dialog` | bash | — | demo component written entirely in bash — nats CLI + jq, no SDK, no compile step: `dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer. Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool). Prereqs: natscli, jq, zenity — `make setup` installs all three |
### `bash` in detail

The bash row above is the summary; this is the contract the model works
against. `bash {command, timeoutMs?, cwd?, run_in_background?}` runs
`bash -c <command>` (`$PATH`-resolved, no override) as the leader of a fresh
process group, with stderr merged into stdout in arrival order, the child
inheriting the component's environment (`NIF_ROOT`, `.env`, everything core
exported) and stdin, and descriptors above stderr closed before the spawn. A
fresh shell per call means `cd` does not persist; `cwd` (the conversation
workspace) is realized as `cd -- <cwd> || exit $?`, so a missing workspace
directory fails the call instead of running somewhere else.

Two timeouts are easy to conflate. The argument (`timeoutMs`, default 30 s)
bounds the *command* — a timeout kills the whole process group and reports
exit 124 — while the schema's `x-harness.timeoutMs` (60 s) bounds how long
*core* waits for the reply. A command may therefore legally outlive the
dispatch budget: with `timeoutMs: 120000` the caller sees a dispatch timeout,
not a tidy 124.

Output is bounded by two compile-time constants with **no env knob** — the
only `getEnv` in the component is `NIF_ROOT`, so a bigger transcript budget
means rebuilding it: at most 2,000,000 bytes are captured and at most 12,000
bytes of transcript reach the model, keeping head and tail and replacing the
middle with
`[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]`,
where the hint tells the *model* to narrow the command or page the spill file
rather than the human to raise a setting. Bigger captures spill to
`var/toolout/` (absolute path in `spill.path`, swept after 1 h). When nothing
could be captured at all — unterminated heredoc, unbalanced quote — the
transcript carries
`[no output captured — the command failed to parse or start; check quoting and
heredoc termination]` instead of a bare exit code. Heredocs themselves are
supported: a command containing `<<` is wrapped so the redirection starts on
its own line.

Cancellation has the same shape as the row describes, with one addition: a
`cancel.bash` is honoured only within **30 s** of its timestamp, and a cancel
for a *different* session is stashed — the next queued request for that
session turns into a synthetic `(exit 130 — cancelled by request)`
**without running the command**. Exit codes are the tool's contract: 124
timeout, 130 cancelled, 126 cwd not enterable, 127 no `bash` on `PATH`,
128 + signal for a command that killed itself. `bash` declares no
`x-harness.effect`, so the fabric batch host classifies it as a **write** and
runs it exclusively, never inside the read concurrency cap.

### `repomap` in detail

The `repomap` row above is the summary. The `repo_map` tool is discover-only
— absent from a conversation's frozen direct set, reachable through
`discover` + `invoke` — carries `x-harness.effect: read` and needs no
approval, so the model asks and nothing is injected; `budget` is in tokens,
1024 by default and 4096 at most.

`focus` ranks the graph around the files the conversation is working on — and
omits their own definitions, since it already has them — while
`mentionedIdents` boosts files whose path or definitions match the symbols the
task names.

Tag coverage is two tiers: tree-sitter for Go, Python, TypeScript,
JavaScript, C, C++, Rust and Ruby (grammars vendored under
`components/repomap/csrc/`, per-language queries under
`components/repomap/queries/`), and a native Nim tagger for `.nim`/`.nims`,
because the Nim grammar's generated parser is 40 MB. An extension outside
those tiers contributes no symbols, so a map of an untaggable language is
empty rather than wrong.

The census that feeds the graph walks the workspace once, skipping hidden
directories, `docs/`, `var/`, `logs/`, `vendor/`, `node_modules/`, the build
outputs (`dist/`, `build/`, `target/`, `nimcache/`, …) and the other junk
directories, and stops after 5000 files or 5 s. A docs-only or otherwise tiny
workspace therefore maps to nothing — the append path logs
`repo map withheld`, and the tool answers `No map: …`.

**What the append injects.** One user-role message per conversation: a
bracketed preamble naming the workspace and warning that it is a snapshot
taken when the conversation started, then the map. It goes into ordinary
append-only history — the runner folds it in before the conversation's next
LLM request, never into the frozen prefix — so a later compaction may trim it
away and `repo_map` re-creates it on demand. Observers see
`ev.session.map {sessionId, workspace, bytes}`.

### Minimal boot profile (`--minimal`)

The normal manifest is the full, self-extending harness. For the smallest
useful persistent runtime, start:

```bash
./var/bin/niffler --minimal
```

This filters the manifest boot set to exactly three service components:

- `store` — conversation/message persistence and component records
- `bash` — one general-purpose machine tool
- `llm` — OpenAI-compatible model access and streaming

Core and NATS still run, and the first conversation starts its normal ephemeral
`var/bin/session <id>` runner. `builder`, `plugins`, `skills`, `fetch`,
`models`, `provider`, the dedicated file tools, and observation/logging do not
start. Persisted components created through `core.spawn` are deliberately not
restored, but their store records are not deleted; a later normal boot restores
them. Minimal mode is only a boot profile, not a policy boundary — a caller can
still use `core.spawn` during the run.

Because neither `provider` nor `models` is present, normal conversation turns
resolve the backend directly from `NIF_OPENAI_API_KEY`,
`NIF_OPENAI_BASE_URL`, and `NIF_OPENAI_MODEL`. Set `NIF_OPENAI_CONTEXT` when
an exact context window matters; otherwise `llm` uses its small built-in model
table and then a 128K fallback — but that table still lists the discontinued `deepseek-chat`/`deepseek-reasoner` ids, so `NIF_OPENAI_CONTEXT` is the only correct answer on DeepSeek today.

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

The desktop UI's automatic launch uses the normal profile. To use the UI with
the minimal profile, start the command above first and then launch
`niffler-ui`; it attaches to the existing core. `--minimal --recover` is also
valid: recovery rebuilds and wipes spawned-component records first, then boots
the three-component profile. This is a runtime choice only; `make build` still
builds the full shipped set.

### Session runners

One conversation = one process (`var/bin/session <sessionId>`), spawned by
the system harness on demand. Clients keep calling `svc.core.call`
(tool `session`); the system ensures a runner per session id and forwards
the turn to `svc.session.<sessionId>.call`. That forward is asynchronous —
core's pump owns the inbox — so one long turn cannot block another
conversation's runner; readiness is the runner appearing in the catalog,
polled for up to 10 s after the spawn. The runner is a supervised
child (restart policy `never`), and that is literal: a runner that dies is not
restarted — the next session call re-ensures it from the store, and a corpse
is reaped mid-wait so the replacement is spawned immediately. It announces
itself as component
`session-<id>` with zero tools, seeds its catalog from
`catalog {op: snapshot}` at startup, writes the conversation header so the
session is visible before its first message, and emits the same `ev.session.*`
events as the classic in-core loop. Sessions are ephemeral: history lives
in the store, so a fresh runner resumes the conversation on the next call. A
runner with no session call for `NIF_RUNNER_IDLE_S` (default 600 s) retires
gracefully and is re-created on the next call; the idle clock is stamped when
a turn finishes, so a long turn counts as activity, not idleness.
Killing a runner kills only that conversation — the process is the unit of
isolation. Turns never nest either way. Beyond `.call` a runner serves five
per-conversation subjects, each carrying the same session id: `.steer`
(mid-turn steering), `.advise` (expert advice, answered from the idle slot),
`.map` (repo-map auto-append), `.diag` (asynchronous diagnostics pushed by
`edit`) and `.tool` (the nested session-call proxy used by fabric and
subagents).

Deleting a conversation is one gated core tool, hidden from the LLM:
`conversation_delete` stops that conversation's runner first (a live turn
would otherwise resurrect records), then removes the header, the messages,
the frozen toolset, the subagent lineage and the job records.

The stdin/stdout tty (`make run`) is an **admin shell**, not a conversation
UI: it only inspects the harness itself — `help`, `status`, `catalog`,
`tools`, `sessions`, `exit` — with arrow-key history and tab completion
(see `core/tty.nim`). The LLM chat lives in the `niffler-tui` terminal client
and the web UI; scripting goes through the `cli` component.

### Clients and the UI registry

Every interactive frontend registers on the bus as a zero-tool component and
keeps a lease alive: core's hidden `ui` tool — `register`, `renew`,
`release`, `owner`, plus `claim`/`release_session` for per-conversation
ownership — tracks which window owns which conversation (the component named
`ui` is the desktop bridge, not this tool). A lease lasts 20 s, and expired
leases are swept lazily on each request — no timer thread exists. Display
numbers ("Niffler 1", "Niffler 2") are monotonic for the harness's lifetime.
This is
coordination, not authentication: it decides which window renders a
conversation and nothing more. After `/restart` the successor adopts its
predecessor's ui id from a handoff record (TTL 120 s, keyed by bus +
workspace), so the conversation and its "Niffler N" label survive.

### Store engines

The store's **bus contract is the artifact**: `put/get/list/del`,
`expectRev` optimistic concurrency, id-ordered lists (docs/WIRE.md).
Multiple engines implement it and register as component `store` with
identical tools — consumers never learn which engine is live. Selection is
a boot-time choice: `NIF_STORE_BACKEND=sqlite|barrel|tidb` (default
`sqlite`); core resolves the manifest entry's binary accordingly and
refuses to boot on an unknown value.

- **sqlite** (default, `var/bin/store-sqlite`, Go): the same document
  contract on SQLite. Documents live verbatim as JSON TEXT; `put` is one
  atomic statement (doc + rev move together — the KV engine's two-key
  crash window is gone); schema via embedded goose migrations; pure-Go
  driver (`modernc.org/sqlite`, no cgo). Data file `var/store.db` (WAL),
  introspectable with any SQLite tool (`sqlite3 var/store.db 'select kind,
  count(*) from docs group by kind'`), attachable read-only from DuckDB
  for offline analytics. Default since context compaction landed: the
  context projection needs the atomic write and a range-readable list
  (docs/research/COMPACTION.md §2).
- **barrel** (`var/bin/store`): embedded BitBarrel KV (Bitcask-style) in
  `var/barrel-db` — schema-free by design, zero deps, proven. Still fully
  supported (`NIF_STORE_BACKEND=barrel`); its `put` is a two-key sequence
  (doc, then rev), so a crash between them can update content without its
  revision.
- **tidb** (`var/bin/store-tidb`, Go): the same schema over the MySQL
  protocol (go-sql-driver) — a network-shared store any number of
  harnesses can serve from. `NIF_STORE_TIDB_DSN` points at the cluster
  (`root@tcp(host:4000)/niffler`; single-node docker:
  `docker run -p 4000:4000 pingcap/tidb`). `value` stays MEDIUMTEXT, not
  the native JSON type — binary JSON normalizes key order and number
  precision, breaking the verbatim-document contract; indexed queries
  arrive later as generated columns over the TEXT (a goose migration).
  `kind`/`id` are utf8mb4_bin: byte-exact equality, byte-order list
  sorting and case-sensitive LIKE prefixes (contract parity with the
  other engines). No flock — the cluster is shared state by design; row
  locks (`SELECT … FOR UPDATE`, pessimistic transactions) arbitrate
  writers and the rev counter stays the optimistic-concurrency check.
  Works against plain MySQL 8 too.

The file-backed engines (`sqlite`, `barrel`) enforce single-writer the same
way: one process owns the file (flock; kernel-released on crash), everyone else
speaks envelopes. `tidb` has no file to lock — the cluster is shared state by
design, and row locks plus the rev counter arbitrate between harnesses.

`list` is a **page**, not a complete view: `limit` defaults to 100 and is
clamped to 1000, and the reply carries `hasMore` plus a `nextAfter` id cursor.
Pass `nextAfter` back as `after` to walk the rest — `after` is exclusive, and
`nextAfter` is absent when `hasMore` is false. The store keeps full histories,
so a long conversation does not fit in one call; core's own full-kind reads
(resume, `session_info`, `conversation_delete`) page automatically.

### Migrating between engines

**Switching engines does not move data.** After upgrade, a harness whose
history is in `var/barrel-db` refuses to boot rather than opening an empty
`var/store.db` and looking like it lost every conversation:

```
core: this harness has conversation history in var/barrel-db, but the
      default store engine is now SQLite and no var/store.db exists yet.
core: migrate first (nothing is moved automatically):
core:     niffler-store-migrate --root /path/to/harness
core: scan for other un-migrated roots (benchmarks, clones):
core:     niffler-store-migrate --scan
core: or keep using the old engine: NIF_STORE_BACKEND=barrel
```

`niffler-store-migrate` (in `var/bin`) runs **offline** — it starts its own
private NATS server and store processes, so no harness needs to be booted,
and it never edits the source data. It reads every document from the source
engine over the bus contract (so any engine pair works, including TiDB),
replays each into the fresh target, then verifies per-kind counts. The flags
(`--root`, `--to <engine>`, `--dry-run`, `--scan [<top>]`, `--all [<top>]`)
are described by the tool's own `--help`; the design behind each stage is
[research/STORE_V2.md](research/STORE_V2.md) "Moving data between engines".

`--scan` finds the top directory, sibling clones, and benchmark trees
(`var/bench/**/niffler-root`). Migration refuses to overlay an existing
target database; rollback is simply `NIF_STORE_BACKEND=barrel`, since the
barrel file is untouched. The same export/replay path moves data in either
direction.

## State and configuration

Niffler has no single config file. State is spread across five places,
chosen by lifetime: boot decisions are environment, identity/selection is
the store, per-conversation choice is the conversation header, display is
the browser, and everything derived is `var/` (regenerable — delete it and
`make build` + a boot rebuilds the world).

| Where | What | Lifetime |
|---|---|---|
| **Environment / `.env`** | all `NIF_*` variables (table below): boot & bus, LLM connection, per-component tuning. `.env` (root, gitignored) holds secrets and local overrides; shell env wins; reference copy with defaults in `.env.example` | process lifetime — components read env once at boot, so a change needs `core.kill` + `core.spawn`. A variable *exported in the shell that started core* is inherited by every child and needs a harness restart instead |
| **The store** (kind table in [The store](#the-store)) | conversation headers, messages, the `provider` registry (credentials included), frozen per-conversation toolsets, the slash table, plugin/component install records, subagent job/lineage records, fabric programs, MCP server configs | durable — the harness's database |
| **Conversation header** (`conversation` kind) | per-conversation choice: model, modelOverride, thinking, profile, title, budgets/token meters — set through the `session` call (`/model`, `/effort` in UIs) and echoed in turn results | per conversation |
| **Home / project files** | skills trees (project `.agents|.claude|.opencode/skills` > bundled `skills/` > home `~/.niffler/skills` + agent-standard dirs > `~/.config/opencode/skills`, then the tree compiled into the binary as the last resort); LSP registry `~/.config/niffler-lsp/servers.json` (`NIF_LSP_REGISTRY`) | durable, user-editable |
| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json` (else `~/.config/niffler-edit/undo.json`): last pre-edit bytes per file plus per-conversation seen-state digests. One record per edited file, no size cap and no eviction — it grows with the number of distinct files edited, and is safe to delete at any time (deleting it loses only undo history and unchanged-read stubs, never file content) | durable, user-editable |
| **`var/`** (gitignored) | `bin/` built binaries, `logs/` bus JSONL + child logs, `models/` catalog cache, `nats-url`/`nats-pid` bus claiming, `processes/` spools (`pN.out`/`pN.err` per start, wiped at boot; ids continue from the persisted counter instead of restarting at `p1`), `repomap-tags/` per-file tags cache (`{mtime, tags}` JSON keyed by the sha1 of the absolute path; empty results are never cached), `fetch/`, `captures/`, `store.db` (the store engine's file — exactly one owner) | runtime, regenerable |
| **Browser localStorage** | display only: reasoning/tool-card detail levels, locale (`niffler-think`, `niffler-tools`) | per browser |
| **Repo files** | `manifest.yaml` (shipped component registry), `skills/` (bundled skills), build files (`config.nims`, `*.nimble`, `Makefile`) | versioned |

Precedence rules worth knowing: shell env beats `.env`; an active `provider`
beats `NIF_OPENAI_*`; a conversation's frozen toolset snapshot beats live
catalog (that is what makes resumes byte-stable); the skill trees shadow in
the order project > bundled > home > config. The `lsp` component
additionally treats build files (`go.mod`/`go.work`, `tsconfig.json`/
`package.json`, `*.nimble`/`config.nims`, `Cargo.toml`) as repo *markers* —
where to walk from, not configuration it parses, while `repomap` lists such
marker files as bare entries in its map; `skills` uses fixed directories
only.

The env-var half of this table is the candidate to move into the store as
global settings with a `/settings` command — the design (precedence
`conversation header > store settings > env > code default`, which keys move
in phase 1, which stay env forever) is `research/SETTINGS.md`.

## Environment variables

All components load `.env` (from the harness root and cwd, existing shell
env always wins — see below) and inherit core's environment. `NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness, so they are not part of the runtime table below. The full set:

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | the harness root (repo). Core derives it from its binary location if unset, and sets it for all children. Components use it to find the SDK, `var/`, `.env`. Every component runs with **cwd = NIF_ROOT**, so the agent's `bash pwd` is always the home — regardless of where you launched the harness | `<binary location>/../..` |
| `NIF_NATS_URL` | bus address. In the **environment** (tests, bench, scripts): attach-only — core uses exactly that bus. Declared in **`.env`** (or the well-known `nats://127.0.0.1:4222`): the clone's **home bus** — claimed when free, attached to only when the answering core serves this root (identity via the catalog's `root` field), yielded loudly to a foreign core or bare nats-server (isolated random bus instead; a recorded leftover `var/nats-pid` is reclaimed first), and written to `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` forces an isolated core-owned bus on a random port — never 4222, never attaches (dev clones and tests). With an explicit `NIF_NATS_URL` the URL wins | unset |
| `NIF_AUTOSTART` | set by an SDK's `ensureHarness` when a UI had to spawn core: that core exits when the last interactive client departs (see Starting and stopping) | unset |
| `NIF_AUTOSTART_IDLE_S` | seconds after the last interactive departure before an autostarted core exits | `10` |
| `NIF_AUTOSTART_BOOT_S` | seconds an autostarted core waits for its first interactive client before giving up | `60` |
| `NIF_ENSURE_ATTACH` | `0` makes `ensureHarness` skip attaching and always spawn a core (tests) | `1` |
| `NIF_STORE_BACKEND` | store engine selected at boot: `sqlite` (default → `var/bin/store-sqlite`), `barrel` (→ `var/bin/store`), `tidb` (→ `var/bin/store-tidb`); anything else refuses to boot. All engines register as component `store` with identical tools — see [Store engines](#store-engines). An un-migrated barrel makes core refuse to boot with the `niffler-store-migrate` instructions; `barrel` here is the escape hatch | `sqlite` |
| `NIF_STORE_TIDB_DSN` | TiDB/MySQL DSN for the `tidb` store engine, e.g. `root@tcp(127.0.0.1:4000)/niffler` (docker single-node: `docker run -p 4000:4000 pingcap/tidb`). Required for that engine — no local default; the component refuses to boot without it. Sessions are forced to UTC unless the DSN sets `time_zone` | unset |
| `NIF_GIT_MIRROR` | host prefix replacing `https://github.com` when the `plugins` component clones packages (e.g. `https://cnb.cool` or a Gitee mirror) — API/search endpoints stay on GitHub | unset |
| `NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default |
| `NIF_OPENAI_API_KEY` | API key for the LLM adapter (`llm`). Required for any conversation turn; with no key at all the adapter refuses before any HTTP request (`provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`), which is a different symptom from a key that exists but is rejected (HTTP 401/403) | — |
| `NIF_OPENAI_BASE_URL` | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | model name | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | models catalog provider id for the default LLM connection; common endpoints are inferred when unset | inferred |
| `NIF_OPENAI_CONTEXT` | explicit context window (tokens) the llm reports to core's context guard. Resolution order: stored provider `context` → this → `models` catalog → `llm`'s built-in table (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288 — code-resident, so a new model needs a source change) → 128000 | `models` catalog, then the built-in table, then `128000` |
| `NIF_AGENT_MODEL_WEAK` / `NIF_AGENT_MODEL_MEDIUM` / `NIF_AGENT_MODEL_STRONG` | exact model ids used by a fresh subagent when `modelTier` is requested; a child tier is clamped to the parent's configured tier | unset |
| `NIF_AGENT_DEFAULT_TIER` | tier ceiling used when the parent's exact model is not present in the configured ladder (`weak`, `medium`, or `strong`) | `strong` |
| `NIF_AGENT_WAKES` | consecutive autonomous wake turns a conversation may run after a background subagent settles while it is idle (docs/WIRE.md "Autonomous wake"); the human's next message resets the budget, `0` disables waking (the notice then waits for the next turn's pull drain) | `3` |
| `NIF_AGENT_NOTICE_HOLD` | `0` lets a turn close even when a settlement notice arrived during its final step (the notice waits for the next turn's drain); by default the turn is held open one extra step so it cannot close over a child that just finished (docs/WIRE.md "Busy-parent inbox") | `1` |
| `NIF_LLM_PROVIDERS` | JSON object of named providers `{nickname: {baseUrl, apiKey, model, context, catalog, protocol?, authType?, accountId?, stripPrefix?}}` the `chat` tool's `provider` arg resolves. `protocol` is `openai-chat` (default), `anthropic` or `openai-codex`; `authType` defaults to `api_key`; `stripPrefix` rewrites a namespaced id (`alibaba/glm-5.2` → `glm-5.2`) for gateways that route on the canonical id; `accountId` is the ChatGPT account id the Codex lane's headers carry, derived from the OAuth token when the record does not hold one (with neither, the call fails with `OpenAI Codex OAuth token has no ChatGPT account id; sign in again`). Malformed JSON and a missing `apiKey` each fail the call explicitly. The provider registry (`provider` component) supersedes the default when active | `{}` |
| `NIF_MODELS_URL` | models.dev-compatible catalog base or JSON endpoint | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | pinned local baseline catalog: while set, this file *is* the baseline — the component never downloads `NIF_MODELS_URL` (not even with `models_refresh {force: true}`) and picks up changes to the file on the next refresh. Plugin sources and `NIF_MODELS_OVERRIDE` still apply | unset |
| `NIF_MODELS_OVERRIDE` | local JSON Merge Patch applied after every plugin source | unset |
| `NIF_MODELS_OFFLINE` | `1` stops the component downloading models.dev; the cached/seed baseline and every plugin source are still used and source tools are still called. Combine with `NIF_MODELS_REFRESH_INTERVAL=0` for a fully static catalog | unset |
| `NIF_MODELS_CACHE_DIR` | catalog and source-patch cache | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | minimum age before refetching the baseline; `0` disables the cache window, so every refresh refetches it | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | background refresh interval; `0` disables | `1h` |
| `NIF_FETCH_DIR` | large fetch results and temporary extraction files | `$NIF_ROOT/var/fetch` |
| `NIF_FETCH_ALLOW_PRIVATE` | `1` (also `true`/`yes`) allows the `fetch` tool to contact loopback/private/link-local destinations; use only for trusted local development services | unset (blocked) |
| `NIF_SKILLS_BUNDLED_DIR` | explicit location of the `skills` component's bundled tree, replacing `<repo>/skills` and its `$NIF_ROOT/skills` fallback. A path that does not exist makes discovery serve the compiled-in copies (dir `(baked)`) | `<repo>/skills` |
| `NIF_MCP_DIRECT_THRESHOLD` | number of cached tools a configured `expose: direct` MCP server may publish directly; larger servers are deferred to progressive discovery | `10` |
| `NIF_MCP_BRIDGE_BIN` | explicit path of the mcp-bridge binary | `<root>/var/bin/mcp-bridge` |
| `NIF_PROCESSES_SPOOL_CAP` | `processes` spool size before a background process's output file is truncated to its tail on the next poll — the kept tail is `min(2 MiB, cap div 2)` and the value is not validated, so a cap at or below zero empties a spool | `33554432` |
| `NIF_PROCESSES_POLL_CHUNK` | maximum new bytes one `process_poll` returns per stream (kept below the spool cap so a burst is always split; clamped to 1 KiB-1 MiB) | `65536` |
| `NIF_LSP_REGISTRY` | absolute path of the language-server user registry (`servers.json`) | `$XDG_CONFIG_HOME/niffler-lsp/servers.json` |
| `NIF_LSP_WARM_MAX` | heavy (index-holding) language servers pre-started per workspace on `ev.workspace.opened` | `2` |
| `NIF_LSP_WARM_CHEAP` | cheap (non-indexing) servers pre-started, from their own budget — they never displace a heavy pick | `1` |
| `NIF_LSP_WARM_TOTAL` | ceiling on processes pre-started per workspace | `4` |
| `NIF_LSP_BIN` | install directory used by `make install-lsp` (server wrappers and the user-local JDK); also resolved as a default fallback bin dir | `~/.local/bin` |
| `NIF_LSP_BIN_DIRS` | extra directories searched for server binaries beyond PATH (colon-separated; a leading `~` means your home directory) | — |
| `NIF_TRAFILATURA` | Trafilatura executable path/name; `off` disables external extraction | auto-detect `trafilatura` on `PATH` |
| `NIF_LOG_LEVEL` | SDK structured-log publication threshold (`debug`, `info`, `warn`, `error`) | `info` |
| `NIF_LLM_MAX_RETRIES` | additional attempts for transient LLM failures (429/5xx/overloaded/connection drop) with exponential backoff; each retry announces `ev.session.retry`. Auth/quota/bad-request errors always fail fast | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | additional attempts when a streamed response drops mid-flight — budgeted separately from the general case because a dropped stream may already have billed output | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | additional attempts for connect/dial failures | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | upper bound honored from a server `retry-after` hint: `llm` wraps the HTTP client, parses `Retry-After` (seconds or an HTTP date) and appends `; retry-after-ms: <n>` to the provider's error so core can honor the wait without every adapter depending on the same client library; a hinted wait longer than this cap is clamped, and an invalid or absent header leaves the error untouched | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | ceiling for one `llm` `chat` completion; slow reasoning models (e.g. GLM thinking=max via llmgateway) can exceed the default on a single response | `300000` |
| `NIF_CTX_RESERVE` | output tokens held back by context admission; defaults to the model's resolved catalog output cap, `16384` when unknown; `0` disables the reserve | catalog output cap |
| `NIF_COMPACTION_TOOL` | contract-v1 candidate tool selected by the runner; empty disables summarization but not prune/trim/error admission | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | whole candidate-call deadline (minimum 5000 ms) | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | auxiliary summarization call budget granted to one attempt; a candidate reporting more calls than granted is rejected as invalid | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | per-call checkpoint output cap | `2048` |
| `NIF_OBSERVE_RING` | messages retained in observe's global ring | `2000` |
| `NIF_OBSERVE_RING_BYTES` | approximate wire bytes retained in the global ring | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | maximum retained bytes per observed message | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | active + stopped probes retained at once | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | retained bytes per probe | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | confined directory for `observe_dump` | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | aggregate generated-capture quota; oldest files are pruned | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | explicit nats-server HTTP endpoint for an external/reused bus | core discovery file |
| `NIF_LOGFILE_DIR` | JSONL output directory | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation | `10485760` |
| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables) | `5` |
| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl` | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search` | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query | `10000` |
| `NIF_AUTO_APPROVE` | `1` → the approval gate (below) is bypassed, and every `/limit` keep-going question is answered with yes (it implies `NIF_AUTO_CONTINUE`). For headless automation only; never set it in a session you care about | unset |
| `NIF_AUTO_CONTINUE` | `1` → a turn that reaches one of the conversation's soft limits (`/limit`) keeps going without asking (`NIF_AUTO_APPROVE=1` implies it). For headless automation only | unset |
| `NIF_MAX_TURN_ROUNDS` | hard LLM-round ceiling per turn; an explicit per-session `maxRounds` may narrow it | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | estimated-token cap on a conversation's direct toolset for `invoke {sticky: true}` promotion; a promotion that would exceed it is deferred and reported in the tool result | `4000` |
| `NIF_PROFILE` | default named tool profile for new conversations, used when the `session` call carries no `profile` argument | unset |
| `NIF_AGENT_MAX_DEPTH` | caps how deep `agent_spawn` delegation may nest (core enforces at dispatch; the agent component mirrors it). `0` forbids delegation; spawn tools stay visible at the cap | `1` |
| `NIF_HOOKS_EVENTS` | comma-separated bus subjects the hooks component watches; trailing `>` wildcards work. Read at boot — a config change is `core.kill` + `core.spawn` | `ev.session.turn` |
| `NIF_HOOKS_<SUBJECT>` | the shell command run for one watched subject (dots and `>` become `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`); event payload piped to stdin as JSON | unset |
| `NIF_HOOKS_TIMEOUT_MS` | per-hook timeout, clamped to 100–60000 ms; a timeout kills the hook and logs exit 124 | `10000` |
| `NIF_MCP_REGISTRY_URL` | base URL of the external-MCP server catalog (air-gapped/proxied setups) | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | timeout for one real-connect probe in `mcp_add`/`mcp_edit`: when set (positive) it wins over both the 30 s default and the server's own `timeoutMs` | `30000` |
| `NIF_READ_OUTLINE_LINES` | whole-read line threshold above which read returns a language-server symbol outline instead of the raw window; `0` disables the outline | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | `1` opts into the repomap component's workspace-open auto-append (one map injected per new conversation). Off by default — the A/Bs disagree on sign by regime and the original high lane partly measured stub maps (`bench/reports/repomap-ab-*.md`). The `repo_map` onDemand tool is unaffected either way | unset |
| `NIF_REPOMAP_MIN_CENSUS` | census-file floor for the append: a workspace with fewer covered source files is never mapped (docs/research/REPOMAP-GATES.md). The gates are append-only — `repo_map` is never gated, a small map is a fine answer to an explicit question | `50` |
| `NIF_REPOMAP_MIN_BYTES` | append content gate: a rendered map below this many bytes is a stub and is withheld. The gates are append-only — `repo_map` is never gated | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | append content gate: rendered symbol-row minimum. The gates are append-only — `repo_map` is never gated | `25` |
| `NIF_REPOMAP_MIN_FILES` | append content gate: symbol-bearing file minimum. The gates are append-only — `repo_map` is never gated | `5` |
| `NIF_RUNNER_IDLE_S` | a session runner with no session call for this long retires; the next call spawns a fresh one (subagent children re-ensure on demand) | `600` |
| `NIF_WRITE_MAX_BYTES` | cap for the `write` tool's whole-file payload | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | host for the local OAuth callback listener (ports stay fixed at 1455/53692) | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core's child-log retention cap in `var/logs` (MB) | `200` |
| `NIF_LOG_RETENTION_DAYS` | days core retains child logs before sweeping | `7` |

**Build and script knobs** — read by the scripts around the harness, never by components: `NIF_BIN_DIR` (bin directory `scripts/install.sh` links the PATH entries into), `NIF_BUILD_LOCK` (lock file `scripts/with-build-lock.sh` flocks — exclusive for builds, shared for test runs), `NIF_NATS_CLI` (the nats CLI `components/dialog/dialog.sh` drives), `NIF_CONF_KEEP`, plus the test helpers `NIF_STORE_BIN` and `NIF_REPO_ROOT`. `NIF_LSP_BIN` and `NIF_LSP_BIN_DIRS` are runtime variables and stay in the table above.

Every Niffler variable carries the `NIF_` prefix, so the harness never
collides with tools that use the bare conventions (`NATS_URL`,
`OPENAI_API_KEY`).

### The `.env` file

`.env` (repo root, gitignored) holds local secrets/config:

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

Loading rules (same in the Nim, Go and TypeScript SDKs): existing shell
environment **always wins** over `.env`; the SDKs load the current
directory's `.env` first and the harness root's second, first definition of
a key wins. The desktop UI bridge loads them in the opposite order (harness
root, then cwd — `ui/bridge.go`), so there the root file wins. So
`NIF_OPENAI_API_KEY=other ./var/bin/niffler` overrides the file, and
`unset NIF_OPENAI_API_KEY` before starting if you want the file value.
`.env` must be a plain regular file: a symlinked or hardlinked copy is
refused, the file is capped at 1 MiB, and values are never `$VAR`-expanded.

`.env.example` in the repo root is the reference copy — every variable
commented out, its default as the commented value — but it is not exhaustive
in either direction (a few entries of the table above are missing from it,
and it carries test/tooling variables the harness does not read in normal
operation); the table is authoritative.

## The bus in one screen

Core speaks exactly one protocol: JSON envelopes over NATS (details in
[WIRE.md](WIRE.md)). Subjects — the backbone you meet while operating, not
the complete inventory (every component also publishes its own event
families: `ev.log.<component>` from the SDKs, `ev.lsp.warm`, `ev.agent.*`,
`ev.fabric.*`):

```
reg.publish            component announces itself: {name, version, pid, tools:[{name, schema}]}
reg.depart             graceful shutdown announcement
svc.<component>.call   queue-grouped tool call request/reply
svc.session.<id>.steer   fire-and-forget mid-turn message injection ({content})
svc.session.<id>.advise  turn-bound advisory request/reply (the expert peer):
                         accepted only while the named turnId is live
svc.session.<id>.map     repomap → runner: the workspace map to append once
ev.workspace.opened    core → components: {workspace, conversationId} — a
                       conversation's workspace, for pre-warm and the repo-map append
ev.session.turn        {sessionId, turnId, phase: start|done, content?, error?}
ev.session.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.token       {sessionId, turnId?, content, reasoning}  (live token deltas)
ev.session.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.advice      {sessionId, turnId?, source, content, reason} an advisory was
                       folded in (`reason` is the judge's one-line justification)
ev.session.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                       status?} runtime machinery was folded in (subagent
                       settlement, background process exit, autonomous wake);
                       `content` is the rendered text UIs show
ev.session.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
ev.catalog.updated     direct (prompt-facing) tool projection after any
                       registration change; `catalog {op: snapshot}` still
                       returns everything incl. hidden/on-demand schemas
ev.models.updated      effective provider/model/source counts after refresh
ev.provider.switch     provider component → bus: {nickname, previous, source, at}
ev.provider.changed    redacted provider registry invalidation event
ev.llm.token           llm adapter → core: {sessionId, content, reasoning} deltas
ev.sys.drain           core → components: stop taking calls, finish, exit
ev.log.<component>     structured SDK logs: {component, level, msg, ctx?, at}
ev.lsp.warm            lsp → bus when a workspace warmup settles: {workspace, warmed, skipped}
ev.agent.started|done|notice  agent: a background job started, a job became
                       terminal, a settlement was folded into the turn
ev.fabric.started|phase|log|call.started|call.done|done
                       one fabric program's lifecycle, correlated by `runId`
llm.cancel.<sessionId> abort an in-flight streaming call (see Streaming below)
svc.approval.<name>.request  directed approval to the component driving the
                           turn (derived from the call envelope's `caller`);
                           driver acks {id, ack: true}, then answers {id, ok}
ev.approval.request    core → UI: {id, tool, args, caller?, fallback?} —
                       human gate, broadcast (see Approvals below)
ev.approval.reply      UI → core: {id, ack?} | {id, ok}
ev.approval.resolved   core → UIs: {id, ok} — gate verdict; dismiss stale modals
cancel.<component>     cancellation side-channel: a runner publishes it when a
                       turn cancel lands while a dispatch is in flight; bash
                       kills the command's process group (see WIRE.md)
```

**Streaming.** The `llm` component streams tokens while generating:
`ev.llm.token` deltas (content + reasoning) → core forwards them for the
active turn as `ev.session.token` → the UI appends them to the live
assistant bubble. A delta frame is published only for a call that carries a
non-empty `sessionId` **and** leaves `emitTokens` on — auxiliary callers
stream internally for cancellation but keep their partial output out of the
conversation (compaction passes `emitTokens: false`; the expert judge's call is
not even streamed, so nothing is emitted either way) — and one frame is emitted
per stream chunk that has content or reasoning. The `purpose` argument those
callers send is telemetry only (provider, model, effort, ttft and tok/s are
logged with it) and never changes provider behavior. The final
`ev.session.assistant` event always carries
the complete content, so a missed last frame heals itself. Abort an
in-flight call by publishing to `llm.cancel.<sessionId>` — or, when the caller
passed a `cancelId`, to `llm.cancel.<cancelId>`: the subscription is armed
only for a streamed call (`stream: true`, which core always sets) and uses
`cancelId` with the session id as its default. Auxiliary callers depend on
that separation — compaction cancels
`llm.cancel.compaction.<sessionId>.<attemptId>` — so a user's turn stop can
neither kill nor be killed by a summarization call.

History is replayed to the provider verbatim, which is why the adapter
repairs it on the way out: an assistant `tool_calls` payload left unterminated
by a dropped stream (or a buggy writer) has its strings and containers closed,
and an unsalvageable payload becomes `{}` — a strict backend rejects the whole
request otherwise. The repair reads text only and never executes anything.

`nats sub '>'` attached to the bus shows the harness thinking in real time.
Or better: **the console component** (`./var/bin/console`, not in the
manifest — start it yourself in a second terminal) subscribes to
everything and renders the wire traffic readably: calls with tool + args,
results, errors, events, approvals — it is how you follow a live install
or a stuck-tool call:

```bash
./var/bin/console    # in a separate terminal while the harness runs
```

**The cli component** (`./var/bin/cli`) drives the same bus from a
script or pipeline — non-interactive, CI-friendly (exit 0 on success);
it is the scripting face, the tty admin shell is the interactive one:

```bash
./var/bin/cli catalog                        # components + their tools
./var/bin/cli wait <component> [secs]        # wait for registration
./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
```

`cli install` clones, builds via the builder, spawns every component and
waits for each service name to appear in core's accepted catalog; interactive
components are verified by their build. CLI catalog and tool lookup also use core's
authoritative directory, never raw registration broadcasts. A plugin repo's CI
proves a package by running the harness itself through this one command. `file://` repo URLs
install from local git repos (hermetic tests, mirrors). Name-based verification
does not distinguish an existing accepted component from a newly started
process with the same name.

## Approvals

Tools whose schema carries `x-harness.approval: "always"` — currently
`bash`, `build` (the `builder` component), core's `spawn`, `kill` and
`remove`, `edit`, `write`, `undo_last_edit`, `fabric`, `agent_run`,
`agent_spawn`, `agent_ask`, `expert_follow`, `lsp_registry`, `mcp_add`,
`mcp_edit`, `mcp_remove`, `mcp_refresh`, `plugin_install`, `plugin_update`,
`plugin_remove`, `process_start`, `process_kill`, `skill_install`,
`skill_remove`, `provider_add`, `provider_update`, `provider_export`,
`provider_import`, `provider_use_environment`, `observe_send`,
`observe_request`, `observe_dump`, `observe_monitor` — are gated on a human
before they execute; every tool of an MCP-bridge server configured
`approval: always` is gated the same way, and hidden entries such as
`provider_update`/`provider_use_environment` still gate when called directly,
so the list is not closed (core's unregistered `conversation_delete` surface
included):

- **Terminal harness** (`make run`): a `[approval]` prompt with the tool
  name and arguments; answer `y`/`n` (falls back to the tty prompt only
  when core is on a terminal and no UI is attached).
- **Web UI / interactive component**: a request is routed to the specific
  component that is driving the session — core derives it from the call
  envelope's self-declared `caller` and publishes to that component's
  private subject `svc.approval.<name>.request`. The driver acks it
  (`{id, ack: true}`) to confirm a human is being asked, shows a modal with
  the tool name and arguments, and answers `{id, ok}`.
- **Driver gone / not interactive**: if the driver does not ack within 1.5 s
  (`ackTimeoutSecs`), the request is rebroadcast on `ev.approval.request` with
  `fallback: true` so any interactive client can step in; with no interactive
  client registered the rebroadcast is skipped and the call is denied at once. Direct
  (non-session) calls broadcast immediately.
- **Neither** (service mode with no UI attached): the call is **denied**
  with a clear error — the caller sees `approval denied for tool '<name>'`
  (core's own tools: `approval denied for <name>`) as a normal tool error, the
  turn continues and nothing is retried silently — never a silent approval.
- When a verdict lands, core publishes `ev.approval.resolved {id, ok}` so
  every client dismisses any stale modal.
- A tool approval that no client answers times out after 5 minutes
  (`timeoutMs`, 300 s) and is denied (the log says `timed out after Ns —
  denying`); a `/limit` keep-going question has its own shorter window (120 s).
- `NIF_AUTO_APPROVE=1` bypasses the gate (headless automation).
- Core's own destructive tools are named `spawn`, `kill`, `remove` and
  `conversation_delete`; they are gated by name inside `handleCoreTool`, not
  through a schema, so `x-harness.approval` appears on component tools only.

A program-shaped call (`fabric`, or `agent_run`/`agent_spawn` with `code`) is
approved by *content*, not by tool name: core hashes the source plus the
selected `tools` and `maxCalls` into a digest, writes the full source to
`var/approval-sources/<digest>.nim` (mode 0600) and shows that path in the
prompt, so the approver reads everything instead of a truncated excerpt
(`tests/t_approval_manifest.nim`).

### Conversation controls: `/approvals`, `/limit` and `/compact`

Three controls belong to you (the human), never to the model, and apply to one
conversation. All are set through the session call (the web UI exposes them
as `/approvals`, `/limit` and `/compact`; any bus client can call `session`
directly). The `approvals` and `limits` settings are persisted with the
conversation, so a resumed conversation keeps them; `/compact` is an action,
not a setting.

- **`/approvals auto`** — this conversation stops asking: every
gated tool is granted, and core says so loudly in its log
(`core: approval auto-granted for <tool> (this conversation is in approval
mode: auto)`), because a silent grant is exactly what the gate exists to
prevent. The setting is persisted in the conversation header (`approvals`), so
a resumed conversation in a session runner logs the same line. `/approvals ask` (or `/approvals` with an
empty argument) restores the normal gate. Use it for a conversation you have
decided to trust end to end; the per-tool "don't ask again" record is still
available for narrower trust. A client's auto-approve action writes a durable
record (store kind `approval`, id `<sessionId>:<key>` — clients write it, not
core); for program-shaped calls the key is `<tool>:<digest>`, so a blanket
"always approve fabric" never covers newly written source. When such a record
matches, the gate never flashes a dialog.
- **`/limit rounds=N tokens=N seconds=N`** — soft budgets for a turn: LLM
rounds, cumulative tokens, and wall-clock seconds. Seconds is checked before
every tool dispatch (one `bash` call can outlast a whole round); rounds and
tokens are checked before the next LLM round. When one is reached the turn
does not die:
core asks you **"keep going?"** through the same approval channel (the UI
shows a Continue/Stop prompt naming the limit), and a *yes* extends that limit
by one more step. A *no*, no answer, or no reachable client ends the turn with
a distinct `limit-<dimension>` record that names the limit and the command
that raises it. `/limit clear` removes all three.
- **`/compact`** — run the compactor *now* instead of waiting for the
automatic pressure ladder: core asks the configured compaction component for
a checkpoint over a permitted cut, installs it atomically, and emits the
usual `ev.session.context {reason: "reset:compact"}`. No LLM turn runs and no
user message is appended. The reply reports `compacted: true` with
before/after token counts, or `compacted: false` with the reason (no
compaction component configured, the compactor declined, or nothing
compactable yet); a decline never silently falls back to lossy trim.

The distinction that matters: these limits are *yours*, so they negotiate;
the job-scoped budgets (`maxRounds`/`maxCalls`/`maxTokens`, which the `agent`
component freezes into a subagent's conversation, and `NIF_MAX_TURN_ROUNDS`)
stay hard — a subagent must not be able to talk its way into more budget.
`NIF_AUTO_CONTINUE=1` answers every keep-going question with yes (headless
automation, same spirit as `NIF_AUTO_APPROVE=1`).

A session call that arrives while a turn is running is refused immediately
with `busy` ("the conversation is mid-turn — retry when the turn finishes")
rather than waiting: turns never nest, and a client that waits instead just
expires its own timeout (this is what made `/export` look broken during a long
turn).

## Context window

Core watches how much of the model's context window a conversation uses
and acts *trivially* — no summaries, no token math beyond what the model
reports:

- The effective window is resolved by hidden `llm_resolve {model?}` before
  each turn, so a newly selected model's limit reaches the context guard
  before inference. Per-provider `context` and `NIF_OPENAI_CONTEXT` override
  the models catalog; a small built-in table and conservative 128K remain as
  fallback if `models` is removed. The result includes secret-free provider,
  model, catalog, context and output provenance plus the provider's `protocol`,
  `authType` and `hasKey` for interactive clients; it still needs a resolvable
  provider, so with no stored and no environment credential it fails instead of
  reporting a window. See [Model catalog](#model-catalog-models).

- The **output** window is resolved alongside the context window and comes
  back as `output`/`outputSource`: the catalog's `model.limit.output`, else a
  deliberate 32768 default — without an explicit cap the provider applies its
  own server-side cap and truncates long answers mid-stream. A per-call
  `maxTokens` only ever lowers the resolved value (the expert judge's tiny
  verdicts), and the Codex lane ignores it entirely.

- `session {sessionId, content?, model?, thinking?, title?, cwd?, profile?, discovery?, tools?, maxRounds?, maxCalls?, maxTokens?}` accepts a
  conversation-scoped model override. A model-only call persists and resolves
  the selection without inference; presence with an empty value clears it.
  `profile` names a stored tool profile resolved into the direct toolset on
  the conversation's first call only (`NIF_PROFILE` supplies the default);
  an unknown profile fails the call, and resumes ignore the argument.
  `thinking` is the reasoning effort, one of `""`, `low`, `medium`, `high`,
  `max`; `""` is the provider default (UIs show it as "auto") and is the only
  value that clears an earlier choice. It is forwarded to the provider as
  `reasoning_effort` — and only when non-empty, so a provider that does not
  support the field never sees one; the `llm` adapter maps the value onto each
  protocol's own form (Codex `reasoning {effort, summary}`, Anthropic
  `thinking` plus `output_config.effort`) — and carried on the conversation
  header.
  `discovery {…}` is an explicit client discovery: it runs `discover`,
  records the schemas in the durable discovery summary and appends them as
  a user message — no LLM turn, no promotion into the direct toolset.
  Core stores the choice in the conversation header and pins the resolved
  model across all tool rounds in a turn.
- The per-session controls freeze on the first call and persist in the
  header: `tools` (a tool allowlist the child may dispatch; at most 32 names
  are honoured, and the accepted arguments are not declared in the `session`
  tool schema), `maxRounds`
  (LLM rounds per turn, 1–`NIF_MAX_TURN_ROUNDS`, narrowing the hard ceiling),
  `maxCalls` (total tool dispatches per turn, 1-500 — every dispatch
  attempt counts, success or error), and `maxTokens` (cumulative
  provider-reported tokens per turn, checked before each new round).
  Budget exhaustion ends the turn as a budget-exhausted error — subagent
  drivers (`agent_run`/`agent_spawn`) surface it as a failure, never a
  text reply.
- `cwd` pins the conversation's **workspace**: an existing directory inside
  `NIF_ROOT` (relative paths resolve against the root), immutable after
  creation and persisted in the header so resumed runners resolve context
  and paths identically. Session runners rewrite path-shaped tool arguments
  at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read
  resolve relative paths there, and git tools scope at the workspace repo.
  The system prompt component appends a workspace notice when it differs
  from the root. The default workspace is `NIF_ROOT` itself.
- After every chat call core records prompt tokens and uses
  `usage.total_tokens` (or prompt + completion fallback) as the best current
  occupancy. Provider, model, context, occupancy and the override are also
  mirrored into the conversation header, so meters survive restarts without
  loading the entire transcript.
- Core emits `ev.session.status` with the resolved provider/model/context and
  current `usedTokens`; clients render `usedTokens / context` directly.
  When the provider reports cached input (`prompt_tokens_details.cached_tokens`),
  the status event also carries the conversation's cumulative cache split as
  `cache {prompt, read, hitRate}` (summed prompt and cached tokens, ratio in
  percent); the conversation header keeps the same numbers as `cachePrompt`,
  `cacheRead` and `cacheHitRate`. With the frozen prompt prefix most prompt
  tokens should be cached after the first request, so a low ratio is a signal
  worth noticing (the web UI shows `⚡ <cached>/<prompt> cached` per message and
  the cumulative split in `/info`; the TUI shows a `cache NN%` chip in its
  header and the same split in `/status`).
- Persisted messages carry audit metadata that never reaches the LLM:
  `createdAt` on every message, `turnId` everywhere, and `startedAt` /
  `durationMs` on assistant, tool and error records (an `error` record is
  persisted when the LLM call itself fails, and replay skips error roles).
- Admission runs before **every** provider request, including each tool-loop
  round. Before reported usage exists, it prices the whole request (messages
  plus frozen tool schemas) with a conservative chars/4 estimate. The
  reserved headroom is the model's declared output cap from the catalog
  (`limit.output`, e.g. DeepSeek's 384000) — the provider counts the
  requested `max_tokens` against its window at admission, so a fixed 16K
  reserve once let a 736,803-token prompt overflow a 1,048,576 provider limit
  the prompt alone fit. `NIF_CTX_RESERVE` overrides the derived reserve. Core
  warns once at 75% of the way to the effective line
  (`ev.session.context {reason: "warn:threshold"}`); at it — never later
  than 90% of the window — core executes a bounded ladder: deterministic
  tool-result prune → configured compactor → oldest complete-turn trim →
  explicit `context-recovery-required`. On the wire the `llm` component
  additionally clamps the requested output to the headroom the serialized
  prompt (messages plus tool schemas) leaves, so estimation drift in either
  layer cannot push a fitting prompt over the provider's limit. It never
  knowingly sends an over-window request.
- The trigger measures in the **provider's scale, not the estimate's**: every
  successful response re-measures a calibration offset (reported
  `prompt_tokens` minus the local estimate of the same request) and
  admission, warnings and trim price candidates as estimate + offset. The
  raw chars/4 proxy can lag a denser tokenizer by tens of thousands of
  tokens — observed on a 524K-window conversation where the "90%" line
  silently fired at ~99% and a request the core called 86% was refused at
  400. The offset is model-scoped (cleared on model change, re-learned from
  the next response), seeded on resume from stored usage, clamped to
  `[0, window]`, and never persisted — it re-measures on the first response.
- The shipped `compaction_propose` is replaceable: set
  `NIF_COMPACTION_TOOL=<tool>` to select another contract-v1 implementation,
  or set it to empty to disable summarization while keeping the deterministic
  guard. `NIF_COMPACTION_TIMEOUT_MS`, `NIF_COMPACTION_MAX_LLM_CALLS`, and
  `NIF_COMPACTION_MAX_SUMMARY_TOKENS` bound each attempt. The runner writes a
  temporary paged `compaction_input` snapshot, validates the candidate's
  generation/digest/cut/schema/size and strict reduction, then commits one
  `context_projection` document with optimistic `expectRev`. The component
  never writes conversation or projection records.
- A successful projection emits `reason: "reset:compact"`; model-free pruning
  emits `reset:prune`; lossy fallback emits `reset:trim`. `reset:tools` remains
  reserved for an actual sticky tool-schema promotion. These are the only
  intentional prompt-prefix rebuilds and make cache misses attributable.
- Canonical `message` documents are immutable and append-only. Prune and
  compaction change only the provider projection; a restarted runner validates
  and reloads the durable checkpoint plus retained canonical tail, while
  `context_recall` resolves canonical/spill/current-checkpoint refs, and its
  `mode: search` greps the whole canonical history — including the span a trim
  dropped, where no notice names individual refs. Missing or
  corrupt projection refs fail explicitly instead of silently replaying an
  oversized span.
- A provider-reported `context-overflow` gets exactly one receipt-backed
  recovery attempt. The same prune → compactor → trim order is re-measured;
  a second overflow is terminal, never an unbounded retry loop. When
  capacity is unknown and the refusal carries no parseable window, the
  attempt reduces blind (lossless prune, then trim to the newest request)
  and the retry only goes out if the candidate actually shrank — an
  irreducible candidate ends terminal instead of resending what was
  refused. The adapter normalizes provider overflow wordings (including
  the bare `"Context limit exceeded"` body some hosts return) to the
  stable `context-overflow` prefix; the runner's classifier carries the
  raw phrasings as a fallback.
- A lossy trim is **durable**: it records the canonical seqNo it cut
  through in the conversation header (`trimThrough`) and the ordinary
  resume honors it, so a restart rebuilds the trimmed projection instead
  of re-inflating the full pre-trim context while the meter restores
  post-trim usage. Dropped turns remain in canonical history for
  `context_recall`.

## Self-extension and component lifecycle

The agent adds capabilities at runtime, mid-conversation:

1. writes a component source (Nim: `import niffler/sdk`, typed tool
   pattern; Go: `import sdk "niffler.dev/sdk"`; TypeScript: the `sdk/ts`
   package — see the system prompt)
2. `build {lang, name, source, files?, defines?}` (the `builder` component)
   compiles it into `var/bin/` (`files` adds further Go sources, `defines`
   passes compiler defines)
3. `spawn {name, binary, replicas?}` (core) starts it; it registers itself;
   new conversations expose its tools directly (when not on demand), existing
   ones reach them via `discover` + `invoke` (see [Progressive tool discovery](#progressive-tool-discovery))
4. `kill {name}` stops every replica temporarily (restored on next boot);
   `remove {name}` stops the group and deletes its persisted record. A runner
   is killed the same way (`kill {name: "session-<id>"}`) but comes back on
   the next session call, not on the next boot

A fabric program that stabilizes takes the same route: `fabricprog` is the
scratchpad, `builder.build` + `core.spawn` is graduation (see
[FABRIC_GUIDE.md](FABRIC_GUIDE.md)).

`replicas` is optional (1–16, default 1) and is persisted. Use it only for
stateless or externally coordinated components: all replicas share the same
`svc.<name>.call` NATS queue group, so concurrent requests distribute one per
process. Never replicate single-writer `store`, or a component such as `edit`
whose mutation/undo state is process-local. The default Nim SDK pump remains
serial. Its initial NATS connection retries for up to 60 seconds while the bus
is binding, then fails into the supervisor's normal backoff; shutdown interrupts
that wait. A component may explicitly own native concurrency when replicas do not
fit: prefer `std/threads` + `std/locks` for long-lived/shared-state Nim workers,
use `taskpools` for isolated jobs, and never use `asyncdispatch`. In Go,
ordinary `Tool` handlers remain exclusive; an audited handler can use
`ToolConcurrent` (bounded to 16 in flight by default, configurable through
`ConcurrentLimit`). Concurrent handlers must synchronize shared state and must
not synchronously call a serialized tool on their own component. This
server-side choice is independent of the runner-facing `x-harness.parallel`
hint.

**Restart policy**: every supervised child carries one — `never` or
`on-failure` (the default; a restarted child is tried after 1 s, doubling per
consecutive crash, capped at 8 s). The manifest sets it per component
(`manifest.yaml`), `spawn` always uses `on-failure`, and session runners are
always `never`.

**Persistence of shape**: spawned components are recorded in the store
(kind `component`) and restored on normal boot. `--minimal` leaves those
records untouched but does not restore them. `core` itself, the bus, the
catalog and the supervisor are not removable — that asymmetry is the
architecture (ARCHITECTURE.md).

## Component ecosystem (`plugins`)

The `plugins` component is the ecosystem front door — community component
packages are plain GitHub repos with a `niffler.json` manifest at the root
(one repo = one package = N components). The manifest itself is small:
`niffler.json` = `{name, components: [{name, lang: "nim"|"go"|"ts", main,
sources?, env?, defines?, interactive?}]}` — `lang` must be one of the three
SDKs, `main` must exist and not be a symlink, and a manifest that declares no
components is rejected. Repos tagged with the GitHub
topic `niffler-component` are discoverable without any registry:

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub topic search; returns repo, description, stars, plus the winning `query` and per-attempt diagnostics — GitHub ANDs the words, so a zero-hit query is retried with fewer of them |
| `plugin_installed` | the packages installed on this harness |
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`, build each component from source via the builder's `build` tool, then `spawn` each service component (approved). Installing a package that already has a record is an error, not a re-install — use `plugin_update`, or `plugin_remove` first; the clone is shallow (`--depth 1`) and carries an untracked `go.work` for a Go package that expects a sibling SDK checkout |
| `plugin_update {package}` | to the latest release tag: remove, reinstall at the new ref; a package with no releases (tracking a branch) is pulled in place (`git pull --ff-only` of the existing clone) and rebuilt only when the pull moved HEAD |
| `plugin_remove {package}` | `core.remove` every supervised component, delete the clone, drop the record |

- Install/update/remove all carry `x-harness.approval: "always"` — they
  run third-party code, and every individual spawn/remove is approved
  again by core. Never run them with `NIF_AUTO_APPROVE=1` unless you trust
  the publisher.
- The default ref is the latest release tag, else the default branch.
  `version` pins a tag or branch explicitly.
- Components always build from source via the `builder` — the same path
  agent-written components take. Running Niffler already provides the
  toolchain (Nim/Go and the NATS SDK), so no NATS C library is required; every
  platform compiles with its own toolchain. A Go entry may declare
  `"sources": ["component/helper.go", ...]`; these must be non-symlink,
  same-package `.go` files beside `main`, and the builder compiles them as one
  package.
- A component manifest entry with `"interactive": true` is built into
  `var/bin` but is not passed to `core.spawn`. It is a terminal client (for
  example a TUI) that the user starts manually, so it is not supervised or
  restarted on boot. Stop any running client manually before removing or
  updating its package.
- A manifest entry may carry `defines` (an array of `-d:`-style prepends) and
  `env` (an array of `NAME=value` strings). Both are passed through — `defines`
  to the builder, `env` to the spawn — so a package can carry its own
  configuration without editing the manifest.
- Install records live in the store (kind `plugin`, id = package name);
  they are wiped by `--recover` like all component records — a fresh boot
  re-clones from the recorded repo/ref on reinstall.
- The GitHub API is used unauthenticated (60 req/h/IP).
- Publishing: add the `niffler-component` topic and tag releases
  (`v1.0.0`). The release workflow in the
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) sample
  dogfoods: it boots a harness and installs the package through
  `plugin_install`, so every tag proves the package installs cleanly.
- A package can extend or correct model metadata by registering a hidden tool
  with `x-models-source: {version: 1, priority: ...}`. The `models` component
  discovers it automatically and applies its JSON Merge Patch while that
  component is present. See [Source plugins](#source-plugins).
- Three reference shapes exist in-tree: the `gokr/niffler-weather` package
  (Nim), the MCP bridge (a spawned Go component), and
  `components/dialog/dialog.sh` — a whole bash component with no SDK at all.

## Skills

The `skills` component gives the agent reusable workflow guidance — the open
[Agent Skills](https://agentskills.io) format (SKILL.md files with YAML
frontmatter), the same convention Claude Code, opencode and Cursor use.
The keys Niffler reads are `name`, `description`, `version`, `license`,
`tags` and `allowed-tools` (lists for the last two); `allowed-tools` is
metadata the model reads, never an enforced restriction. Read/load is
read-only over the bus, and the only writes are the approval-gated
`skill_install`/`skill_remove` pair in the two managed directories; no tool
adds skills to the prompt — loading is progressive disclosure through the
tool result.

All eight tools are **on-demand** (`x-harness.onDemand`): none sits in a
conversation's frozen direct toolset, so the first reach for one is a
`discover` + `invoke` hop (see [Progressive tool
discovery](#progressive-tool-discovery)). Loading a skill appends its text
to history — nothing here rewrites the frozen prompt prefix, so a
`skill_load` costs a cache read, not a cache miss.

Discovery covers the bundled skills shipped in the repo plus the standard
agent directories (first match per skill name wins — project beats bundled
beats home beats config):

| Source | Directories |
|---|---|
| project | `$NIF_ROOT/.agents/skills`, `$NIF_ROOT/.claude/skills`, `$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills` — the checkout this binary was compiled in (a build-time path); `$NIF_ROOT/skills` is the fallback for relocated deployments, and `NIF_SKILLS_BUNDLED_DIR` overrides both — never removable |
| home | `~/.agents/skills`, `~/.claude/skills`, `~/.opencode/skills`, `~/.niffler/skills` |
| config | `~/.config/opencode/skills` (where `npx skills add -g -a opencode` installs) |

Within a source the directories are tried in the order listed, so
`~/.agents/skills/nats` is served over `~/.claude/skills/nats`. Discovery is
a **fresh walk on every call** — no cached registry, no store records, no
refresh op — so a
`skill_install` or another agent's `npx skills add` is visible immediately.
The walk does not descend into **symlinked directories**: a skill that only
reaches a scanned directory through a symlink is not discovered, and
`skill_audit` does not list it either; nor is a **symlinked SKILL.md** file
yielded, so a skill whose SKILL.md is a link to a real file elsewhere is
invisible as well (a symlink farm such as
`~/.claude/skills → ~/.agents/skills` is therefore invisible — harmless when
the link target is scanned anyway, silent when it is not).

Bundled skills (`todo-markdown` — keep todo state in a repo TODO.md,
not in tool state; `niffler-tools` — which tool fits which job;
`niffler-fabric` — constructing fabric programs; `niffler-harness` —
operating the running harness itself) make Niffler useful out of the box;
shadow one by dropping a same-named skill into a project or home directory.

When **no** bundled tree is reachable — a deployment shipping `var/bin`
without the repo checkout, where neither `<repo>/skills` nor
`$NIF_ROOT/skills` exists — discovery falls back to the bundled SKILL.md
files **compiled into the binary**. Those entries report source `bundled`
and dir `(baked)`; they carry no resources (`skill_resources` is empty —
none of the bundled skills ship any) and are never removable. Disk always
wins by name, so a checkout is unaffected by the fallback.

| Tool | What it does |
|---|---|
| `skill_list {query?, source?}` | available skills (name, description, version, license, tags, allowedTools, source, dir — `license`/`allowedTools` are inert metadata); filter by substring or source; compiled-in fallback entries report dir `(baked)` |
| `skill_search {query, owner?}` | online search of the skills.sh registry (the `npx skills find` backend): name, repo source, install count, slug and url (at most 20 hits per call; a query under 2 characters is refused before any network call, and a failed call returns the HTTP error text); the `source`+`name` pair feeds `skill_install` directly |
| `skill_load {name}` | the skill's markdown body (frontmatter comes back as fields) + its resource list into the conversation (the load mechanism); a body over 200 000 bytes is truncated with `truncated: true` |
| `skill_resources {name}` | the skill's `references/`, `scripts/`, `assets/` files, one level deep — a file in `references/sub/x.md`, or a symlinked file, is neither listed nor readable |
| `skill_resource {name, path}` | read one resource on demand |
| `skill_audit` | read-only, unmerged inventory of every SKILL.md on disk — plus names served only by the compiled-in fallback (dir `(baked)`): marks the active winner per name and every shadowed/invalid copy (invalid = unreadable SKILL.md, unparseable frontmatter, or no name even after falling back to the directory name — a SKILL.md that omits `name:` is accepted under its directory's name; discoveries merge in `skill_list`, so shadowing is only visible here) |
| `skill_install {repo, skill?, global?}` | clone a git repo, copy the chosen SKILL.md tree into `~/.niffler/skills` (default) or `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | delete a skill from a Niffler-managed directory only |

- `skill_search` is a read-only HTTP call to `https://skills.sh/api/search`
  (unauthenticated); it is not gated on approval. It returns at most 20
  hits per call, and `owner` narrows the same query — it is not a separate
  namespace. Install is: search →
  `skill_install {repo, skill}` → approval dialog → done.

- Skills installed with `npx skills add <owner>/<repo>` (the skills.sh
  ecosystem CLI) land in the standard dirs above and are discovered without
  reinstall; `skill_install` exists so Niffler works without Node, via plain
  git. It copies only SKILL.md trees — no code runs — and accepts
  `owner/name`, github.com URLs and `file://` local repos (hermetic tests).
- Repos holding several skills (e.g. `vercel-labs/agent-skills`) require the
  `skill` parameter; `skill_install` lists the candidates when it is missing.
  The parameter matches a skill's name or its directory basename.
- `skill_install` needs `git` on `PATH`: it clones `--depth 1` into
  `$NIF_ROOT/var/skills-tmp/<name>` (removed again afterwards) from
  `https://github.com/` — older releases can only be reached through a
  mirror by pointing `repo` at one — and copies the whole skill directory,
  resources included. It refuses a name whose destination already exists
  (`skill_remove` first); the result reports `source: home|project`.
- `skill_remove` refuses anything outside `~/.niffler/skills` and
  `$NIF_ROOT/.opencode/skills` — skills other agents installed into shared
  dirs are removed with their own tooling.
- Install and remove carry `x-harness.approval: "always"` (they write outside
  `var/`).

## Provider registry (`provider`)

Configured LLM backends are store records, not a config file. The
`provider` component keeps them under kind `provider` (id = nickname, plus
the `active` marker doc) and exposes them to the agent and to `llm`:

None of these is in a conversation's frozen direct set: `provider_add`,
`provider_remove`, `provider_list`, `provider_switch`, `provider_models`,
`provider_export` and `provider_import` are `x-harness.onDemand` (reachable
through `discover` + `invoke`), while `provider_update`, `provider_status`,
`provider_active`, `provider_get`, `provider_use_environment` and the three
OAuth tools are `x-harness.hidden` (clients only — `invoke` refuses them).

| Tool | What it does |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?, active?}` | add or overwrite an API-key provider (upsert by nickname; `protocol`: `openai-chat` default or `anthropic`); the first provider — API-key or OAuth — becomes active automatically unless `active: false`; `stripPrefix` sends a namespaced model id without its `vendor/` prefix for gateways that route on the canonical id (e.g. `glm-5.2` for `alibaba/glm-5.2`); response is redacted |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?}` | hidden client API for partial updates; omitted API key is preserved |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | hidden, start a subscription login: `protocol` `openai-codex` (ChatGPT Plus/Pro) or `anthropic` (Claude Pro/Max); `method` `browser` (local callback) or `device` (headless, OpenAI only). Returns `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | hidden, poll/finish a login; returns `{pending, retryAfterMs?}` until the callback (or pasted `code`) lands, then stores the provider and reports it redacted |
| `provider_oauth_cancel {flowId}` | hidden, cancel a pending login and close its callback listener |
| `provider_list` | all stored providers (redacted — no keys/tokens), which one is active; each entry carries `authType` (`api_key`/`oauth`), `protocol` and `expiresAt` |
| `provider_status` | hidden, redacted effective provider including environment fallback and `hasKey` |
| `provider_active` | hidden internal read of the effective provider's full config, credential included |
| `provider_get {nickname}` | hidden internal full-config read used to pin an explicit stored provider across a turn |
| `provider_models {nickname?\|baseUrl?, apiKey?, refresh?}` | model ids the provider's `/models` endpoint currently serves — a stored provider by nickname, or an explicit endpoint+key (the connect form, before the credential is saved); the two shapes are alternatives (`nickname` wins if both are given) and one of them is required. Disk-cached 5 min per endpoint (stale cache served when the probe fails); errors are returned to the caller so clients can fall back to the catalog |
| `provider_switch {nickname}` | make another stored provider active; the next chat call (and `llm_resolve`) uses it immediately, with no restart |
| `provider_use_environment` | hidden client API that clears the stored marker and returns to `NIF_OPENAI_*` |
| `provider_remove {nickname}` | delete a provider; if it was active, the alphabetically first remaining provider takes over, else the `NIF_OPENAI_*` fallback resumes |
| `provider_export` / `provider_import` | JSON backup/migration round-trip, credentials included; import merges, validates records and can restore the active marker |

Exposure flags, so the per-row prose need not be parsed: the `provider_oauth_*`,
`provider_status`, `provider_active`, `provider_get` and
`provider_use_environment` rows are **hidden** client API (a UI or an operator
calls them; the model never sees them), while `provider_add`, `provider_update`,
`provider_list`, `provider_switch`, `provider_export` and `provider_import` are
**on-demand** — the model reaches them through `discover` + `invoke`. The four
credential-moving tools carry `x-harness.approval: "always"` (below), and
`provider_models` runs under a 20 s timeout.

Omitted fields take protocol defaults: `openai-codex` infers the ChatGPT backend
URL and `anthropic` the Anthropic one (under `openai-chat` a `deepseek` or
`openai` nickname implies its own base URL), the model defaults to
`deepseek-chat` (`openai-chat`), `gpt-5.4` (`openai-codex`) or
`claude-sonnet-4-6` (`anthropic`), and the two OAuth protocols infer their
models.dev catalog id (`openai`/`anthropic`).

### Wire protocols

Each provider carries a `protocol` that `llm` routes on:

- `openai-chat` — the OpenAI-compatible Chat Completions endpoint (default;
  DeepSeek, OpenRouter, local vLLM, …).
- `openai-codex` — ChatGPT's Codex Responses endpoint
  (`https://chatgpt.com/backend-api/codex/responses`) with ChatGPT OAuth
  headers (`chatgpt-account-id`, `OpenAI-Beta: responses=experimental`);
  messages are translated to the Responses API input format and the SSE event
  stream (text/reasoning deltas, function calls) is mapped back to the
  shared result shape.
- `anthropic` — the Anthropic Messages endpoint; OAuth logins send Claude
  Code identity headers and betas, system prompts lead with the Claude Code
  preamble, and tool calls/results are translated to `tool_use`/`tool_result`
  blocks (consecutive tool results merge into one user message); its usage is
  normalized for core's counters — `prompt_tokens` is input + cache reads +
  cache writes, while only cache **reads** count as cached tokens (cache
  writes are billed at write rates). Across all three protocols a `usage`
  object accompanies the result only when the provider reported non-zero
  tokens.

An API-key provider may use `openai-chat` or `anthropic` only: `openai-codex`
requires a ChatGPT subscription login (`provider_oauth_start`), and
`provider_add` refuses the combination.

### Output caps and `finish_reason`

Output caps are spelled per protocol, and a mis-spelled cap fails silently.
Niffler's default spelling is `max_completion_tokens`; DeepSeek honors only
`max_tokens`, so a cap sent the default way is ignored and the server's own
default (8K/64K/128K, by model) applies — send `max_tokens` for DeepSeek
endpoints. The Anthropic lane always receives the resolved window as
`max_tokens`; the Codex lane is told no cap at all. How a stream ended is
reported in `finish_reason`: `length` means the output cap cut the reply short
(`llm` logs a truncation warning), `tool_calls` means the model stopped to call
tools, and Anthropic's `max_tokens` stop maps onto `length` (its `tool_use` stop
maps onto `tool_calls`); Codex's `max_output_tokens` finish and its
`response.incomplete` event map onto `length` as well, while an unrecognized
reason passes through unchanged for the log. Two OpenAI-compatible error
finishes, `aborted` and `insufficient_system_resource`, arrive with HTTP 200 and
are surfaced as a retryable stream error, not as a reply.

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

The `provider` component implements the same PKCE login flows Pi and opencode
use (fixed localhost callback ports, manual redirect/code fallback, and the
OpenAI device-code flow for headless machines). A started flow expires after
15 minutes; `provider_oauth_start` returns its `expiresAt` (epoch ms), so an
abandoned login can never be completed later:

1. `provider_oauth_start` returns the authorization URL; interactive clients
   open it in the system browser. OpenAI alternatively offers `device` login
   (a short code entered at `auth.openai.com/codex/device`).
2. `provider_oauth_complete` polls until authorization completes, then
   exchanges the code and stores the provider — `authType: "oauth"` with the
   access token, refresh token, expiry and (for ChatGPT) the account id
   extracted from the JWT.
3. Every credential read (`provider_active`, `provider_get`, status
   resolution) refreshes the token transparently when it is within 5 minutes
   of expiry and persists the rotated credential. The `llm` component never
   sees a refresh token.

Environment knobs: `NIF_OAUTH_CALLBACK_HOST` (default `127.0.0.1`) moves the
local callback listener (ports stay fixed at 1455/53692 like the reference
clients). Exports contain live refresh tokens — treat `provider_export`
output as a secret.

The fallback backend presents itself as nickname `default` (`source:
environment`), with `NIF_OPENAI_BASE_URL` defaulting to
`https://api.openai.com/v1` and `NIF_OPENAI_MODEL` to `deepseek-chat`;
`provider_use_environment` clears the active marker, it does not delete stored
providers.

Interactive clients expose the same moves as slash commands: `/provider
<nickname>` (alias `/providers`) switches the global backend, `/provider
environment` (alias `/provider env`) comes back here, and `/provider strip
[off]` toggles vendor-prefix stripping on the active provider; the UI's provider
manager wraps the same tools (`provider_add`/`provider_update`/`provider_remove`
and the OAuth start/complete/cancel flow) behind the approval prompt.

- `provider_add`/`provider_update`/`provider_import`/`provider_export` carry
  `x-harness.approval: "always"` — they move credentials or mutate connection
  settings. Interactive clients call the hidden update/status tools directly
  after an explicit user action and must never render/log credential payloads.
- `llm` resolves its default backend from the active stored provider on
  every chat call, so `provider_switch` takes effect immediately. When the
  `provider` component is absent or nothing is active, `llm` falls back to
  `NIF_OPENAI_*` and the `NIF_LLM_PROVIDERS` table as before. An explicit
  `provider` arg to `chat` or `llm_resolve` resolves a stored nickname first,
  then `NIF_LLM_PROVIDERS`, so a session can pin a non-active stored provider
  across its turn without switching the global default.
- A stored provider's explicit `context` (tokens) wins over the models
  catalog; its `catalog` id names the models.dev provider for the context
  lookup, and `plugin` is informational metadata naming the component that owns
  this provider's extra tools — `provider` neither starts nor validates it, so
  the named component must be spawned separately and can only react on
  `ev.provider.switch`. On every switch the component publishes
  `ev.provider.switch {nickname, previous, source, at}` so such plugins can
  enable or hide their tools. Every registry mutation also publishes the
  secret-free `ev.provider.changed {op, nickname, active, source, at}` — `op` is
  one of `add`, `update`, `switch`, `remove`, `import`, `login` or `refresh` —
  for interactive clients to invalidate their provider/model views.
- The `active` marker is a plain store doc (`{nickname, updatedAt}`) — written
  with `expectRev` 0 — and a dangling or empty marker is deleted automatically
  on the next read, so `provider_remove`/`provider_use_environment` need no
  manual repair; `store` tools remain there for manual surgery if you want it.
- A switch changes the backend, not the conversation: a conversation's pinned
  `modelOverride` still belongs to the provider it was chosen under and may not
  exist on the new one. Interactive clients therefore clear the pin when a
  switch actually moves the backend (the web UI and the TUI do); a bare
  `provider_switch` call leaves it in place, so a stale pin can fail the next
  turn until the conversation's model is reset (`/model default` in the UI).

## Hooks

The `hooks` component (off by default — an autostart flag, not a build one:
`make build` compiles the binary like every component, so enabling it is
`NIF_HOOKS_*` plus `spawn {name: "hooks", binary: "<root>/var/bin/hooks"}`)
runs operator shell commands when selected bus events fire — the observe-only subset of CodeWhale's hooks
(docs/research/CODEWHALE.md). A hook is a plain process: the decoded event
payload is piped to the command's stdin as pretty JSON — written to a temp
file and `cat` into the hook, never interpolated into the command line —
failures and timeouts (default 10s, max 60s) are logged and never fatal,
and a payload is capped at 256 KB with a truncation marker appended. There is deliberately no steering/veto:
approval decisions live in core's dispatch gate.

Configuration is env-based, read at boot (a `.env` change applies to the
respawned component; a variable exported in core's shell needs a harness
restart):

```bash
NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"   # subjects to watch
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

Subject → env name: dots and `>` become `_`, uppercased
(`ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`). Worked examples —
desktop notification, sound alert, email, webhook, error tail — live in
`components/hooks/README.md`. Matching is first-match-wins over the
comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at
boot is ignored — the component logs `watching …` only for the hooks it will
run.

Hook stdout and stderr go to the component's own log, `var/logs/hooks.log`
(the supervisor redirects child output there) — never into logfile's JSONL,
which persists bus traffic only.

`make test-hooks` (`tests/t_hooks.nim`) is the smoke test: it boots the
component with `NIF_HOOKS_EV_SESSION_TURN`, publishes an `ev.session.turn`
and checks that the decoded payload reached the hook's stdin.

## Fetch

The `fetch` component is the web access tool (a port of the old niffler
`fetch` tool). One on-demand tool — the model reaches it through `discover`
+ `invoke`; it is never part of a conversation's frozen direct set:

| Tool | What it does |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH an http(s) URL; HTML → clean text via Trafilatura or a pure-Nim fallback; follows redirects; enforces caps (`timeout` default 30 s, max 120 s) |

- `convertToText` (default true) extracts readable text from HTML — JSON
  payloads are always returned verbatim. Conversion runs only for a
  `text/html` response (XHTML is advertised in `Accept` but comes back raw);
  a call that never converts reports `extractionMethod: "none"`.
- Extraction is a ladder: `trafilatura` (given the already-downloaded HTML in
  a temp dir under `$NIF_FETCH_DIR`, bounded to 30 seconds) → the built-in
  `htmlparser` walk → the raw body (`extractionMethod: "raw-fallback"`). A
  missing executable, a non-zero exit, a timeout or empty output falls back
  silently. Set `NIF_TRAFILATURA` to an executable path/name to override
  detection, or to `off`/`0`/`false`/`none` to disable it.
- Responses are capped at `maxSize` (default 10 MiB, min 1024 bytes, max
  50 MiB); content over 200 KB after processing is written to a unique
  `fetch_<rand>.txt` under `$NIF_FETCH_DIR` (default `$NIF_ROOT/var/fetch`)
  and the tool result becomes `Content saved to file (over 200000 bytes after
  processing): <path>`, so the agent reads large pages with its own file
  tools instead of blowing the conversation. Nothing prunes those files — the
  directory grows until an operator clears it, and it also hosts
  trafilatura's temporary work dirs.
- Errors (non-2xx, timeouts, oversized responses, invalid URLs/methods)
  come back as `ok: false` with the status and a body snippet: an HTTP error
  carries `extra.status` and at most the first 500 bytes of the stripped
  body, and a response over `maxSize` is such an error, never a spill.
  Success results carry `finalUrl` (after redirects), `status`,
  `contentType`, `contentLength`, `convertedToText`, `extractionMethod`,
  `savedToFile` and `filePath`.
- Requests are validated before they are sent and every redirect hop is
  re-validated: http(s) only, at most 2048 URL characters, no URL
  credentials, and every resolved address checked — loopback, private,
  link-local, CGNAT, multicast, `localhost`/`.local`/`.internal`, and an
  empty or failing DNS answer are all refused (fail closed: `"hostname
  resolves to a private address: <host>"`, `"cannot validate hostname <host>:
  <msg>"`). `NIF_FETCH_ALLOW_PRIVATE` (`1`, or `true`/`yes`) bypasses the
  check for trusted local services.
- Redirects: at most 5 hops, each re-validated; 301/302/303 become GET with
  the body and Content-Length/Content-Type/Transfer-Encoding dropped, 307/308
  keep method and body; a missing `Location` or a non-http(s) target is an
  error. Caller `headers` override the defaults (`niffler-fetch/0.1` UA, an
  HTML-ish `Accept`, `Accept-Language`).
- No approval gate (like `plugin_search`), but the tool declares no
  `x-harness.effect`, so the fabric batch host schedules `fetch` as a write
  and runs it exclusively.

## Language servers (`lsp`)

Status: **implemented** (Nim component; deterministic fixture tests; the
niffler-tui client adds a `/lsp` registry picker).

One generic seam over any stdio language server. The component knows no
languages: which server handles which file extension is **data** — a registry
with sane defaults built in. Adding a language is a config entry, never code
(AGENTS.md invariant: language-agnostic core). The `repomap` component is the
current exception: a map language needs its grammar vendored under
`components/repomap/csrc/`, a `{.compile.}` entry in `ts.nim`, a
`queries/<lang>-tags.scm` and its extensions in `tags.nim` — that tier list is
the seam's present limit, not a policy.

### The tools

| Tool | What it does |
|---|---|
| `lsp {operation, path, query?, line?, character?, workspaceRoot?}` | One query against the file's language server: `diagnostics` (compiler/lint errors without a test run), `documentSymbol` (file outline: every symbol with kind, name and one-based position — no line/character needed), `workspaceSymbol` (repo-wide symbol search — a fuzzy `query` string; the server builds its index after warmup, so the first call may need a retry), `goToDefinition`, `findReferences`, `goToImplementation`, `hover` — or `warmup`: with a directory as `path` (or `workspaceRoot`), census its languages and pre-start their servers |
| `lsp_servers {}` | List configured servers (read-only, approval-free) with provenance: `builtin` default or `user` registry entry |
| `lsp_registry {action: add\|remove, name, command, extensions?, initializationOptions?, requires?, cheap?}` | Mutate the user registry (approval-gated write). `add` takes `{name (lowercase letters/digits/hyphens), command, extensions: {".ext": "languageId"}}`, overrides a built-in of the same name, and refuses an extension already mapped to another server with `E_LSP_CONFLICT` (remove that mapping first); `remove` deletes user entries only |

The model sends one-based line/character (UTF-16, matching LSP's code-unit
convention); `findReferences` always includes the declaration; results are
capped (100 locations / ~16 000 characters) with truncation metadata;
structured
`[E_LSP_*]` errors (`E_LSP_UNAVAILABLE`, `E_LSP_UNSUPPORTED`, `E_LSP_TIMEOUT`,
`E_LSP_SCOPE`, `E_LSP_PROTOCOL`, `E_LSP_REGISTRY`, `E_LSP_CONFLICT`,
`E_NOT_FOUND`, `E_NOT_TEXT`, `E_BAD_SHAPE`) let callers route on codes, not
prose —
timeout and protocol errors append the server's last stderr line, which
names the actual failure (missing binary, crash, indexing).

**Scope is a bound, not an equality.** A file inside the conversation
workspace is indexed under the workspace root (its warm servers are reused); a
file *outside* it — a sibling checkout, a git worktree, any other directory an
agent is working in — is indexed under its own marker-derived root, and the
reply carries `workspaceRoot` naming it, because the relative paths in an
answer would otherwise be ambiguous. `E_LSP_SCOPE` remains only for the two
cases that would hand a server an unbounded tree: a `..` component in the path,
and a file whose marker walk reaches the filesystem root or `$HOME` (the
message asks for an explicit `workspaceRoot`). Refusing an out-of-workspace
file outright was tried and was actively harmful: the edit tool's diagnostics
push swallowed the refusal as "no server configured", so an agent working in
another checkout got no diagnostics and no signal that it had none.

All three tools are **on-demand** (`discover`/`invoke` — see [Progressive tool
discovery](#progressive-tool-discovery)), keeping the frozen
toolset small; the tool description is the model's when-to-use guide. The
`lsp` tool is read-only and approval-free; `lsp_registry` writes the registry
file and is approval-gated.

### Model usage

Typical turns:

- Before editing unfamiliar code: `goToDefinition`/`hover` on the symbol
  instead of guessing from grep matches.
- After an edit to a compiled language: `diagnostics` on the touched file —
  the compiler's verdict in one call instead of a full test round.
- When a textual match is ambiguous: `findReferences` resolves the symbol
  semantically.

Queries open the document transiently (`didOpen` with the current bytes →
request → `didClose`), so every query sees the file as it is on disk right
now — including the agent's own just-written edits — and the opened bytes are
echoed as a `didSave` as well, because the nimsuggest-based Nim servers
publish diagnostics only on save (a no-op for open-push servers such as
pyright, clangd and bash-language-server). One server process is
kept per (server, workspace) and reused across queries; a timeout or protocol
error tears that instance down so the next query starts fresh, and at most
eight live instances are kept (LRU-evicted). Each query runs on a 60 s budget
and the `initialize` handshake gets 30 s, inside the tool's 90 s envelope;
diagnostics wait 1.5 s after the first push before settling. A relative `path`
resolves against the conversation workspace; without an explicit
`workspaceRoot` the server root is derived from the file's nearest module
marker for its language (`go.mod`/`go.work`, `Cargo.toml`,
`tsconfig.json`/`package.json`, `pyproject.toml`, `*.nimble`/`config.nims`,
`compile_commands.json`/`CMakeLists.txt`), then `.git`, then the workspace —
the walk never climbs above the workspace, and markers are built in per
extension, so a language added purely as a registry entry keeps the
`.git`/workspace fallback. Only a `..` component or a marker walk that would
reach the filesystem root or `$HOME` is refused (`E_LSP_SCOPE`, asking for an
explicit `workspaceRoot`).

Core fires a **warmup** automatically when a conversation workspace is
announced (`ev.workspace.opened`): the component runs a bounded extension
census (stops at 5 000 files or a 2 s budget; hidden files and junk
directories such as `node_modules`, `vendor`, `dist`, `build` and `target`
are skipped) and pre-starts servers for the most prevalent languages, so the
first real query does not pay server startup. It then publishes
`ev.lsp.warm {workspace, warmed, skipped}` so a UI can show which servers came
up and which were skipped. The `warmup` operation re-runs the same path explicitly.

Unconfigured languages degrade, never break: an extension with no server (or
a missing binary) returns `E_LSP_UNAVAILABLE` with the fix in the message —
"add one with the lsp_registry tool (or edit <registry path>)". The model
falls back to grep/read on its own.

### Registry: adding a language

Three routes, all writing the same file:

1. **TUI picker** — `/lsp` in niffler-tui: browse configured servers, `a` to
   add (name, command, extensions — e.g. `elixir-ls`, `elixir-ls`, `.ex,
   .exs`), ctrl+s to save (human approval prompt, since it writes config);
   `e` edits (a built-in opens as an override), `d` removes user entries.
2. **Ask the agent** — "register elixir-ls for Elixir files" → the model calls
   `lsp_registry add` itself (same approval gate).
3. **Edit the file directly** — `$XDG_CONFIG_HOME/niffler-lsp/servers.json`:

```json
{
  "elixir-ls": {
    "command": ["elixir-ls"],
    "extensions": {".ex": "elixir", ".exs": "elixir"}
  }
}
```

Every entry: `command` (argv array, or a plain string split on whitespace)
plus an `extensions` map (leading-dot extension → LSP language id).
Optional `initializationOptions` passes through to the server's `initialize`.
Two more optional keys carry what used to be code: `requires` (runtime
binaries that must resolve, e.g. `["java"]` for jdtls — a server whose
runtime is missing reports itself instead of spawning and dying) and
`cheap` (a server that indexes nothing and therefore does not consume a heavy
warmup slot; bash-language-server is the built-in example).
Built-in defaults — gopls, nimtortoise, typescript-language-server, pyright,
rust-analyzer, clangd, bash-language-server, jdtls, intelephense, solargraph,
csharp-ls — work whenever the binary is on `PATH` or in a fallback dir
(`~/go/bin`, `~/.nimble/bin`, `~/.local/bin`, `~/.dotnet/tools`, `~/bin`);
`make install-lsp` installs them idempotently (Go, Nim and TS are mandatory —
Niffler is built from those — the rest are y/n prompts, `make install-lsp
ALL=1` (`--all`) for unattended installs, and a non-TTY run skips the optional
languages; nothing is installed with `sudo` — only under `$HOME` — and a
missing runtime (JDK, .NET SDK, rustup) is reported with the exact command
instead of being auto-installed; the same script installs the user-local JDK
below. A failure is non-fatal per language: the lsp tool just skips it with
`E_LSP_UNAVAILABLE`; a failure is non-fatal per language: the lsp tool just
skips it with `E_LSP_UNAVAILABLE`; `NIF_LSP_BIN` overrides the install
directory, default `~/.local/bin`, which is also a default fallback bin
dir). Java is the one language whose *runtime*
is installed too: a user-local JDK 21 under `~/.local/share/niffler-lsp/jdk`
(sudo-free, like the server downloads) when no JDK 17+ is on `PATH` — a jdtls
wrapper without a JRE used to report "ok" and then die mid-query.
Override one by adding an entry with the same name. The registry is
re-read on every call, so edits take effect immediately; a malformed file or
entry is skipped with a warning on stderr (visible in `var/logs/lsp.log`)
instead of failing the query.

Set `NIF_LSP_REGISTRY` to an absolute path to relocate the user registry
(tests, multi-harness setups).

**Warmup budgets.** Core publishes `ev.workspace.opened` at conversation
bootstrap; the component censuses the workspace (bounded walk) and pre-starts
servers so the first real query does not pay a cold start. Heavy servers —
the ones that index the whole workspace (gopls, rust-analyzer, jdtls,
clangd, pyright, intelephense, solargraph) — are capped at
`NIF_LSP_WARM_MAX` (default 2) picks; *cheap* servers, which index nothing,
get their own budget (`NIF_LSP_WARM_CHEAP`, default 1, and only from 2+
matching files) and never displace a heavy pick — on a repo full of `.sh`
files bash-language-server otherwise took one of the two slots from the
language the task was actually written in. `NIF_LSP_WARM_TOTAL` (default 4)
ceilings the processes pre-started per workspace. A pick whose `requires`
runtime is missing is reported in `skipped` ("jdtls (needs 'java')") rather
than started.

## Repository inspection (`git`)

Status: **implemented** (Nim component; `tests/t_git.nim`).

The read-only half of a git workflow, as first-class tools; the write half
(add/commit/push/checkout/restore) stays in `bash`, which is approval-gated.
Every subcommand runs as a fixed argv (`--no-optional-locks -c color.ui=false
-c core.quotepath=false --no-pager`), never through a shell, scoped with
`-C <repo>` — flags, refs and paths travel byte-for-byte.

| Tool | What it does |
|---|---|
| `git_status {repo?, path?}` | current branch plus one porcelain line per changed file; untracked files appear here, never in `git_diff` |
| `git_diff {repo?, path?, unified?=3, stat?=false}` | everything changed since HEAD, staged **and** unstaged (`unified` clamped 0..50; `stat: true` is a one-line-per-file summary) |
| `git_log {repo?, path?, max_count?=20, author?}` | recent history, one line per commit (`max_count` clamped 1..200; `author` is a substring) |
| `git_show {repo?, rev, path?}` | one commit in full: metadata, message, complete diff (`rev` required) |
| `git_blame {repo?, path, start_line?=1, max_lines?=200}` | line-by-line attribution; uncommitted lines read `Not Committed Yet` |
| `review_receipt {op?="write", findings?, model?}` | the local review receipt write/check pair (below) |

All six are **on-demand** (`discover`/`invoke`), and the five read tools carry
`parallel: true` and a 45 s envelope. An empty or relative `repo` resolves
against the conversation workspace when core injects the call (session turns);
a direct bus call resolves it against the component's cwd, the harness root.
`path` is never rewritten — it travels as `-- <path>` and resolves against
`repo`.

**Failure and refusal semantics.** Argument refusals never start git: they
come back as exit 2 with an `(exit 2 — refused)` prefix (non-existent or `..`
`repo`; absolute or `..` `path`; option-looking, whitespace-bearing or
oversized `rev`; a `-`-prefixed or oversized `author`). Real runs return git's
exit code with git's own output; `124` is prefixed `[timed out]` and `128` with
"not a git repository" is prefixed `[no git repository at the target
directory]`. Empty results get friendly markers (`[no changes since HEAD]`,
`[no commits matched]`); everything else is raw git stderr, so a **detached
HEAD** is just git's `## HEAD (no branch)` and a broken index is git's fatal
text with exit 128 — neither is special-cased. Output is bounded twice: 40 000
bytes kept head+tail (with a `truncated N of M bytes` marker) and a per-tool
line cap — `git_status` 200 lines, `git_diff` 10 000 (500 with `stat`),
`git_show` 10 000, `git_log` and `git_blame` at their count plus one — each
with a "narrow the scope" hint.

**Review receipts.** `review_receipt` is the one write-side tool here and the
one git tool with no approval gate: it only ever writes a file under
`var/review-receipts/`. `op: "write"` records a SHA-256 fingerprint of the
working-tree diff (plus optional `findings` and `model`) as
`rr-<unix>-<fp8>.json` (`schema_id: "niffler.review-receipt/v1"`, `id`,
`created_at`, `diff_fingerprint`, `note`); `op: "check"` compares the current
diff with the newest receipt — exit 0 plus the receipt id when they match,
exit 1 with `receipt_fingerprint` and `current_fingerprint` when the diff
moved, and exit 1 with a `detail` when there are no receipts, none parse, or
the diff is empty. It never calls a model.

**The git binary.** `git` must resolve on `PATH`, and a `PATH` hit that is the
component's own `var/bin/git` is skipped (that would recurse); unresolved git
returns exit 127 with an install hint.

## Background processes (`processes`)

Status: **implemented** (Nim component; `tests/t_processes.nim`).

bash is synchronous by design — servers, watchers and test loops need a
different contract: start once, poll incremental output, kill explicitly.

| Tool | What it does |
|---|---|
| `process_start {command, label?, workdir?}` | Spawn the command detached (own process group, stdin from /dev/null, stdout/stderr appended to spool files under `var/processes/`) and return its id immediately. Approval-gated. A background start through the `bash` tool's `run_in_background` is approved once, on the `bash` call itself — the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` (e.g. from `cli`) is gated |
| `process_poll {id, waitMs?, filter?, tail?}` | Drain output appended since the last poll — incremental, never re-injects old bytes; `waitMs` blocks until new output or exit (25 s cap); `filter` is a regex over the new lines (the drain cursor still advances past all of them); any non-empty `tail` re-reads the last ~64 KB of raw output. Read-effect |
| `process_kill {id}` | Terminate the whole process group — SIGTERM, 300 ms grace, then SIGKILL. Approval-gated |
| `process_list {}` | Show the registry — running and recently finished entries with exit codes. Read-effect |

Details:

- The child writes append-mode to spool files (never a pipe it could
  deadlock on); the component reads from per-stream cursors, so the OS
  absorbs output bursts. A spool beyond the cap (32 MiB,
  `NIF_PROCESSES_SPOOL_CAP`) is truncated to its tail on the next poll — it
  keeps the last 2 MiB, or half the cap when that is smaller, and the
  truncating poll appends `[spool truncated to its tail — the cap was reached]`;
  one poll returns at most `NIF_PROCESSES_POLL_CHUNK` new bytes per stream
  (default 64 KiB).
- Each tool carries its own dispatch budget `x-harness.timeoutMs` —
  `process_start` 20 s, `process_poll` 30 s, `process_kill` 15 s,
  `process_list` 10 s — separate from the `waitMs` cap inside
  `process_poll`.
- Cap: 32 concurrent processes. Finished entries are never evicted: every
  process of this component's lifetime stays in the registry — only
  *running* ones are written to `registry.json` — so `process_list`
  keeps reporting a finished child as `exited(code N)` or
  `killed(signal N)` until the component exits.
- **A finished process tells its conversation.** When you start one through
  the `bash` tool's `run_in_background` flag, bash hands the owning
  conversation to the registry; when that child exits, `processes` publishes
  an exit notice into it (the same lane subagent settlement notices use), so
  the turn that follows opens with `[background process p3 (dev-server)
  exited(code 0)] ran 412s, 8123 bytes of output — read it with
  \`process_poll\` …`. It is a pointer: the output stays in the spool, and the
  command text never travels.

  This is why a background job no longer goes unnoticed: the component reaps
  its children on a periodic tick (the SDK's `onIdle`), not only when someone
  polls — which also means `process_list` shows `exited(code N)` promptly
  instead of `running` until asked. Only `bash run_in_background` hands the
  owning conversation over (it is the one caller that passes `session`), so a
  `process_start` reached any other way — the model's own `discover` +
  `invoke`, `cli`, a script — is started without an owner session; a process
  whose conversation runner has already retired is announced to nobody too.
  Poll those.
- Tool errors carry stable codes: `E_BAD_SHAPE` (empty `command`, a
  missing `workdir`, an invalid `filter` regex), `E_NOT_FOUND` (unknown
  id — `process_list` shows the registry) and `E_LIMIT` (32 live
  processes, or a child that could not be forked).
- `process_list` entries carry `started_at` (epoch seconds), so a client can
  show how long something has been running — the `bg 1 (7m)` badge is the
  `niffler-tui` plugin's status line, not core's.
- `workdir` defaults to the conversation workspace: core substitutes it for
  an empty or `.` value and resolves a relative path against the
  workspace (`x-harness.workspace`), and a path that does not exist
  fails with `E_BAD_SHAPE`. A bare bus call (`cli call process_start`)
  skips that substitution, so the child inherits the component's own
  cwd (`$NIF_ROOT`).
- Crash-safe: children are process-group leaders, so a SIGKILLed component
  leaves them running — `registry.json` (pid + /proc starttime, defeating
  pid reuse) drives a boot sweep that kills orphans from a previous life
  before serving. They die when the `processes` component stops; if it is
  killed instead, the next start sweeps what is left.

All four tools are on-demand (`discover`/`invoke`). The bash tool's
`run_in_background` flag is a thin producer over this component: the call
returns the id at once — no timeout applies to the *job*, but the `bash`
call that starts it is still bounded (its dispatch budget, and the 15 s
`process_start` request behind it) — and the transcript line points at
`process_poll`/`process_kill`. If the component is not running, bash
answers `[E_BACKGROUND]` and suggests running the command synchronously.

## External MCP servers (`mcp`)

Status: **implemented** (manager + bridge + discovery integration; UI
surfaces are thin clients over the same tools).

Niffler acts as an MCP **client/host**: each configured external MCP server
(Model Context Protocol) becomes one supervised bridge process, and the
server's tools become ordinary catalog tools — discoverable, invocable and
approval-gated exactly like any component tool. The bridge is built on the
official Go SDK (`github.com/modelcontextprotocol/go-sdk`).

### Shape

```
store kind "mcp" (one record per server)
        │ owned by the mcp manager (components/mcp)
        ▼
spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}
        │ one supervised process per server (survives reboots via the
        │ component record; supervisor restarts it on failure)
        ▼
bridge announces mcp_<server>_<tool> schemas  ──►  catalog ──► discover/invoke
        │
        └── lazy MCP session ──► stdio subprocess / streamable-http / sse
```

The bridge is only ever started this way (or by the probe with `--probe`); its
path is `NIF_MCP_BRIDGE_BIN`, default `<root>/var/bin/mcp-bridge`, and the
manager re-spawns the child after a crash or drift. The bridge carries no config on its argv: it re-reads the `mcp` record named by `--server` at startup (so the record stays the single source of truth) and exits immediately if that record is disabled.

- **Naming**: tools are prefixed `mcp_<server>_<tool>` (niffler lowercase
  convention, globally unique in the catalog); descriptions carry a
  `[mcp:<server>]` provenance prefix. Server names must match
  `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$` (≤32 chars, `bridge` reserved); tool names are sanitized to the same
  alphabet and capped at 64 chars. The manager rejects servers whose generated tool names
  collide with another server's or with a catalog tool.
- **Exposure**: on-demand by default (`x-harness.onDemand`) — schemas enter
  the conversation through `discover {component: "mcp-<server>"}` and calls
  go through `invoke`, so MCP servers never bloat the frozen direct toolset.
  `"expose": "direct"` opts a server's tools into every new conversation's
  snapshot — unless the server publishes more than `NIF_MCP_DIRECT_THRESHOLD`
  tools (default 10), in which case the bridge defers the entire server to
  on-demand. The threshold is read by the bridge process when it announces
  its tools, so it is fixed for that child's lifetime (change it and
  respawn the bridge).
- **Lazy sessions**: adding a server validates it with one real connect
  (initialize + tools/list) and caches the tool listing in the record; the
  MCP subprocess/HTTP session itself starts on the first tool call and idles
  out after `idleMs` (default 5 min; capped at 24 h). Each call gets the
  per-call timeout (`timeoutMs`, default 120 s, capped at 24 h). Booting the
  harness never pays for `npx`/`uvx` startup.
- **Cancellation**: MCP tools declare `x-harness.sessionId` — the session
  runner injects the live session id as `__session.session`, and a cancelled
  turn's `cancel.mcp-<server>` event (docs/WIRE.md) aborts the in-flight MCP
  call immediately. Direct callers (CLI scripts) get `""` — they cannot
  spoof a session, and unattributed calls are only bounded by `timeoutMs`.
- **Secrets by reference**: `env` values, `headers` values, `args` and the
  `url` may contain `${NAME}` references that resolve from the harness
  environment when the bridge connects or spawns the server — the store
  keeps the placeholder, listings echo only key names, and a missing
  variable fails the connect with a clear error instead of sending an empty
  credential. A bare `$` stays literal.
- **Sandboxing**: stdio servers run under a guard process (`mcp-bridge
  --stdio-guard <cmd>`) that owns the server's process group and watches a
  lifeline pipe — if the bridge dies (SIGKILL included), the guard SIGTERMs
  then SIGKILLs the whole group; a kernel `PDEATHSIG` backstops the guard
  itself, so an MCP server can never outlive its harness. stdio servers
  inherit a fixed environment allowlist (PATH, HOME, TMPDIR, USER, SHELL,
  LANG, TERM) — `NIF_*` variables and secrets in the harness environment
  never reach them. HTTP/SSE servers only see configured `Authorization`
  headers, and only when they point at the server's own origin — credentials
  are never replayed to a cross-origin redirect target (the redirect is
  refused instead).
- **Result size**: MCP results ≤64 KiB are returned inline; larger results
  are spilled to `$NIF_ROOT/var/mcp-results/result-*.json` and the tool
  returns a short preview plus the file path (readable with `read`, `grep` or
  bash) instead of blowing up the context window.
- **Drift**: on each fresh session (and on server-pushed
  `notifications/tools/list_changed`) the bridge re-lists the server's
  tools; when the contract moved it persists the fresh listing (best effort,
  rev-retried) and exits 3, so the supervisor restarts it announcing the
  current truth. Catalog and execution never disagree for long. If that refresh cannot be persisted the bridge fails closed in a *retiring* state instead of crash-looping: `mcp_servers` shows the error, and the server needs `mcp_refresh` (after active calls finish) or `mcp_edit` to recover.
- **Isolation**: one process per server; a hung or crashed server cannot
  take down others (the supervisor's on-failure backoff restarts it). A
  server's tools keep their frozen schema in existing conversations after
  removal — calls then fail through normal routing.

### The record

One store document per server (kind `mcp`, id = sanitized server name;
`mcp_servers` lists them with env/header **values redacted**):

```json
{
  "name": "filesystem",
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  "env": {"API_KEY": "..."},
  "cwd": "",
  "enabled": true,
  "approval": "always",
  "expose": "ondemand",
  "effect": "write",
  "timeoutMs": 120000,
  "idleMs": 300000,
  "concurrency": "parallel",
  "tools": [{"name": "read_file", "description": "...", "inputSchema": {}}],
  "prompts": [{"name": "review", "description": "...", "arguments": [{"name": "code", "required": true}]}]
}
```

`type` selects the transport: `stdio` (default; `command`+`args`+optional
`env`/`cwd`), `http` (streamable HTTP; `url`+optional `headers`) or `sse`
(`url`+`headers`). `approval: "always"` gates every tool of the server with
the human approval prompt; `effect: "read"` marks read-only tools for fabric
scheduling; `concurrency: "serial"` for servers that cannot handle overlapping
calls (default `parallel` via the SDK's bounded `ToolConcurrent`). The
manager owns every field except `tools` — the bridge rewrites only that cache
when the server drifts.

### Tools

All on the `mcp` component, all on-demand. `mcp_add`, `mcp_edit` and
`mcp_remove` are approval-gated (as is the `core.spawn`/`core.remove` they
issue); `mcp_refresh`, `mcp_servers` and `mcp_search` are not — refreshing
only re-lists an already-approved server.

| Tool | Purpose |
|---|---|
| `mcp_servers` | list records + live bridge state (registered tools, session status, last error). A stalled bridge never blocks the listing (1 s status timeout, 8 concurrent); if the catalog is unreachable the row reports `live: false` instead of failing |
| `mcp_add` | validate with one real connect (through the bridge in probe mode — config on stdin, no bus), store the record with the cached tool listing, spawn the bridge. Validation timeout: 30s or `timeoutMs` if higher (`NIF_MCP_PROBE_TIMEOUT_MS` overrides) — first runs of `npx`/`uvx` servers download packages. `enabled: false` stores a parked config without connecting or spawning (`mcp_edit {enabled: true}` activates it later). If the bridge does not register within 15 s the record is still stored and the call returns `ok` plus a `warning` naming `var/logs/mcp-<server>.log` |
| `mcp_edit` | merge provided fields, re-validate, respawn (or stop when disabling) |
| `mcp_remove` | `core.remove` the bridge (no boot resurrection) + delete the record |
| `mcp_refresh` | force a bridge to drop its session, reconnect and re-list now |
| `mcp_search` | query the official MCP Registry for servers by keyword (read-only); returns ready `mcp_add` arguments for installable npm/PyPI entries |

A server's own tools appear in the catalog only once its bridge has spawned —
right after `mcp_add`, or on boot from the restored component record.

Adding an MCP server therefore asks for approval twice by design: once for
the `mcp_add` itself, once for the `core.spawn` it triggers — the human gate
on changing the harness shape (docs/ARCHITECTURE.md). `mcp_edit` likewise
asks twice (the edit, then the respawn) and `mcp_remove` twice (the removal,
then `core.remove`).

### Prompts, resources, registry

- **Prompts become slash commands.** Each server prompt is registered as a
  hidden catalog tool `mcp_<server>_prompt_<promptname>` (invisible to the
  LLM, `x-harness.hidden`) plus a slash command `mcp-<server>-<promptname>`
  whose named parameters mirror the prompt's arguments (≤32 prompts per
  server, ≤16 arguments each); a second hidden generic tool
  `mcp_<server>_prompt` renders any prompt by name for clients. Rendering a prompt is an ordinary bus call; the
  result carries the rendered text as `userMessage`, and the UI appends it
  to the conversation as a **user** message (slash result convention,
  `ui/frontend/src/lib/slashResult.ts`) — prompt output is never injected
  into the transcript as system/assistant content. The bridge re-registers
  them on drift like tools (server-pushed `notifications/prompt_list_changed`
  included).
- **Resources** surface as one concurrent tool `mcp_<server>_resources`
  (`x-harness.effect: "read"`): `{op: "list"}`, `{op: "templates"}` (URI
  templates) or `{op: "read", uri: ...}`.
  Text results follow the same 64 KiB inline cap as tool results (larger
  spill to `var/mcp-results`); binary blobs come back base64 with the MCP
  mimeType.
- **Registry**: `mcp_search <query>` queries the official MCP Registry
  (`registry.modelcontextprotocol.io`; override with `NIF_MCP_REGISTRY_URL`)
  and returns name/title/description/version plus a suggested `mcp_add`
  config for npm/PyPI-packaged entries — versions pinned from the registry
  (`npx -y <id>@<v>` / `uvx <id>==<v>`). Entries are marked `installable`
  only when they need zero configuration; template variables in the package
  id or declared required env/headers surface as `requirements`
  ("configuration required: ...") instead of a half-filled config. Failures are reported verbatim
  (`registry unreachable: …`, `registry returned status N`, `bad registry
  payload`); browsing never mutates anything — nothing installs until the
  returned args are passed to `mcp_add`.
- **Drift covers prompts too**: `checkDriftLocked` (fresh session) and both
  list-changed notifications re-list tools *and* prompts; the record's cache
  is refreshed and the bridge exits 3 for a supervisor restart.

### Verification

`tests/t_mcp.nim` (in `make test`): compiles a dependency-free fixture MCP
server (`tests/fixtures/mcp_server.nim`, newline-delimited JSON-RPC over
stdio) and a mock registry (`tests/fixtures/mock_registry.nim`, std-only
HTTP) into a private sandbox and exercises the whole contract — add (with
secret redaction), bridge registration, discover hints + full schema, lazy
invoke, tool-error propagation, mid-flight cancellation (`cancel.mcp-<server>`
aborts an in-flight call), resources list/read, prompt slash command +
rendering, registry search against the mock, server-pushed drift (persist +
restart + rediscovery), edit/respawn, spawn-args persistence for boot
restore, and removal. Two regression tests pin the process-hygiene fixes: a
SIGKILLed guard must leave no orphaned MCP server (kernel `PDEATHSIG`), and
failed adds must leave no record. Go unit tests (`make gotest`) cover the
SDK's frozen-registration gate (`Announce` panics on late registration;
post-ready calls fail with `not-ready`), name/contract validation, registry
shape parsing, transport credential/redirect rules, and cancellation plumbing.

## Progressive tool discovery

Status: **implemented**.

Niffler keeps one complete global catalog while exposing a small, immutable
toolset to each conversation. Additional schemas enter the append-only message
history through `discover`; calls to those tools go through the fixed `invoke`
gateway. This reduces prompt bloat without weakening core approval or timeout
policy.

### Model

#### Existence is global; exposure is per conversation

A component exists when it is live on the bus. `reg.publish` inserts all its
tools into core's catalog; `reg.depart` or supervisor cleanup removes them. A
binary under `var/bin` is inert until manifest autostart, `core.spawn`, or a
plugin install starts it.

Exposure is a separate concern:

| Level | Schema metadata | Direct LLM schema | Discovery | Invocation |
|---|---|---|---|---|
| direct | `x-harness.onDemand` absent | included in a new session snapshot | hint + schema lookup | direct or `invoke` |
| on demand | `x-harness.onDemand: true` | omitted | hint + schema lookup | `invoke` |
| hidden | `x-harness.hidden: true` | omitted | omitted, including explicit lookup | components/core only |

Hidden takes precedence if both flags are present. A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist — how replaceable runner machinery (compaction, recall) reaches a child whose toolset was frozen before it existed. Exposure is not an ACL:
the complete catalog remains authoritative for routing. The LLM-facing
`invoke` gateway refuses hidden targets, while components can still request
hidden tools directly over NATS.

#### Full catalog and projections

- `catalog {op: "snapshot"}` returns complete component registrations and
  schemas. Session runners seed their local catalogs from it.
- `catalog {op: "components"}` returns the complete component-to-tool-name
  map used by the CLI.
- `catalog {op: "list"}` returns the current name-sorted direct projection for
  a *new* conversation. It is not the toolset of an existing session.
- Dispatch, approvals, `x-harness.timeoutMs`, and component-to-component calls
  always consult the full catalog.

### Core tools

`discover` and `invoke` are direct core tools in every new conversation. `profile` is an on-demand core tool for managing named tool profiles; `session.profile` selects one when a conversation is first created. `/profile` in the web UI or TUI sets the client default used by `/new`.
`session_info` (onDemand) summarizes a conversation (header fields,
per-role message counts, cumulative completion tokens); `prompt_preview`
(onDemand) shows composed-request provenance — where the system prompt came
from, how many project context files feed it, the frozen direct tool names
vs. schemas discovered so far, message/token counts — without sending
anything. `doctor` (onDemand) is a one-shot machine-readable health report:
store reachability, llm registration, active provider, systemprompt
presence, catalog size, conversation count, plus a self-test fan-out —
every component that registers the standard `selftest` tool (docs/WIRE.md)
is asked to check itself and its per-check results are collected in the
report (components without one are listed as not implementing it). With
`deep: true` the probes go live — the lsp component boots every configured
language server against throwaway fixtures (clean file → 0 diagnostics,
hover answers, broken file → errors), the repomap check maps a throwaway
workspace and asserts both append gates fire, the store runs a full
put/get/rev/list/del roundtrip on its engine. Quick mode stays cheap
(binary resolution only); useful as a CI liveness gate or a first
diagnostics step. The UIs expose it as `/doctor`. The report also carries a
rendered Markdown table in `text` (what `/doctor` displays), and `ask: true`
adds a `userMessage` (the docs/WIRE.md convention) so the client submits an
interpretation request as a user turn.

#### Explicit client commands

The chat clients expose the same catalog state without requiring an LLM turn:

- `/components [all|direct|discovered|undiscovered]` lists live components and filters each tool by its exposure in the current conversation. `direct` means the schema is in the request tools array; `discovered` means it is known in history and callable through `invoke`; `undiscovered` means it is live but not yet exposed to this conversation.
- `/discover COMPONENT` or `/discover tool=NAME` performs an explicit discovery request and records the returned schemas in the conversation's durable discovery summary. It does not promote tools into the direct array; use a profile at `/new`, or `invoke` with `sticky: true`, when direct schema exposure is wanted.
- `/profile NAME` selects a named profile for new conversations; `/profile default` clears the selection. Changing it never rewrites an existing conversation's frozen exposure.

The web Components panel provides the same all/direct/discovered/undiscovered filters and a text search. Hidden tools remain internal and are never listed by `/discover`.

#### Hints

```json
{"query": "web"}
```

`query` is optional and matches component names, tool names, and descriptions
case-insensitively. A multi-word query is a conjunction: every
whitespace-separated word must appear in the component name or the tool
name/description — a keyword phrase like "mechanical fan-out" matches even
though no description contains it verbatim. An empty query returns the bus
directory with tool names only; `component` and `tools` calls return full
descriptions and schemas. The result is deterministic: components and tools are
name-sorted, descriptions are whitespace-normalized one-line hints capped at
200 characters, and volatile fields such as pid and registration time are
excluded.

```json
{
  "components": [
    {
      "name": "fetch",
      "version": "0.1.0",
      "direct": [],
      "onDemand": [
        {"name": "fetch", "description": "Fetch a web page or API endpoint..."}
      ]
    }
  ],
  "count": 1
}
```

`discover {component: "fetch"}` returns that component's direct and on-demand
hints. Components with no non-hidden tools are omitted.

#### Schemas

Request only the tools needed for the next step, up to 16 at a time:

```json
{"component": "fetch", "tools": ["fetch"]}
```

The result contains normalized full schemas, sorted by tool name:

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

Unknown and hidden tool requests have the same error shape so discovery is not
a hidden-tool existence oracle.

`tools` without a `component` searches every live component — callers often
know the tool name but not its owner. Each returned schema then carries the
owning `component`, and names with no discoverable tool are listed in
`notFound` (an empty schema set is an error naming the requested tools).

#### Invocation

Call a discovered schema through the fixed gateway:

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` recursively enters the normal `dispatchToolCall` path. The target
tool's approval dialog, timeout, component routing, and errors therefore behave
exactly like a direct call. It can also reach a newly registered non-hidden
tool that was not present when the conversation started.

### Session state and caching

Provider prompt caches include top-level tool definitions. Adding a discovered
concrete schema to a later `tools` array would change the prefix and invalidate
the accumulated cache. Returning a schema only as a tool result is append-only,
but the model still needs a declared function through which to call it; that is
why `invoke` is fixed and generic.

On the first turn, a session runner:

1. computes `Catalog.promptTools()`;
2. stores the exact ordered schemas under store kind `session`, id
   `<sessionId>:tools`;
3. uses that snapshot for every LLM round and after runner restart.

The document shape is:

```json
{
  "version": 1,
  "direct": [
    {"component": "bash", "name": "bash", "schema": {}}
  ],
  "discovered": [
    {"component": "fetch", "name": "fetch"}
  ],
  "initializedAt": 0,
  "updatedAt": 0
}
```

`direct` carries schemas because it is the resume-safe provider snapshot.
`discovered` is a durable summary for inspection and UI state; the schemas
themselves live in persisted tool-result messages. Only a successful
full-schema `discover` call updates it. Hint searches and failed lookups do not.

Component registration churn never changes an existing conversation's direct
array. A late component is found through `discover` and called through
`invoke`. If a direct component departs, its frozen schema remains in that
conversation for cache stability; a call fails through normal routing and
current discovery reflects that it is gone.

### Shipped policy

With the complete shipped manifest, 7 tools are direct (a profile, or `invoke
{sticky: true}`, can widen that set for one conversation):

- Core: `discover`, `invoke`.
- Routine work: `bash`, `grep`, and the file tools
  `read`/`edit`/`write` (the `edit` component).

The long tail is on demand:

- Search and inspection: `files` (sorted listing), the git
  tools, `undo_last_edit`, `repo_map` (the ranked workspace map the model
  asks for explicitly), and the observe/logfile diagnostics.
- State and introspection: store `get`/`list`, `session_info`, and the
  skill entry points `skill_list`/`skill_load` (a workflow guide is
  loaded only when one fits the task).
- Orchestration: `fabric`, the `agent_*` and `expert_*` tools.
- Core lifecycle/status/catalog, builder, plugins, and fetch.
- Models and provider administration.
- Skill resources, online search, install, and remove.

Internal tools remain hidden: core `session`/`session_prepare`, store
`del`, LLM `chat`/`llm_resolve`, the systemprompt prompt, and the
credential-bearing provider tools (`provider_update`,
`provider_use_environment`, `provider_status`, `provider_active`,
`provider_get`, `provider_oauth_start`, `provider_oauth_complete`,
`provider_oauth_cancel`). Store `put` is on demand (it carries
`x-harness.sessionId` for the frozen-toolset snapshot).

Absent `onDemand` metadata remains direct for third-party compatibility. A
component spawned after a session starts still does not mutate that session's
frozen direct array; discover/invoke is the handshake for the new capability.

### UI

The Live Components panel joins global `core.status` data with the active
session's exposure document. Tool chips use text plus color:

- `direct`: in the immutable provider tool array;
- `seen`: its schema was successfully discovered in this conversation;
- `demand`: live and non-hidden, but not exposed in this conversation;
- `internal`: hidden from the LLM.

Component liveness remains a separate status dot. The panel reloads on session
selection, catalog changes, discovery/done events, reconnect, and periodic
polling. Deleting a conversation also deletes its exposure document.

### Verification

`tests/t_discover.nim` is the end-to-end contract. It proves deterministic
projection and discovery, full-catalog retention, hidden non-disclosure,
approval and timeout preservation through invoke, the actual session-runner LLM
payload, immutable behavior across late registrations, schema persistence in
message history, and durable UI exposure metadata.

Run it alone with `make test-discover`; it is also part of `make test`.

---

## Model catalog (`models`)

The `models` component is Niffler's replaceable provider/model metadata plane.
It does not belong in core and it is not a universal inference adapter. It
answers which providers and models exist, how they are addressed, what they
support, and their limits and prices. An `llm` component still owns the actual
wire protocol, authentication flow, request transforms, and streaming.

The design borrows the useful common shape from Pi and OpenCode:

- models.dev is the broad curated baseline.
- A small embedded seed makes a first offline boot useful: deliberately tiny —
  the shipped `deepseek` provider with `deepseek-chat` and `deepseek-reasoner`
  only, so the configured default keeps working offline. Everything else
  appears once the baseline is fetched or a source/override supplies it.
- The last validated download is written atomically and retained on failure.
- Corrections and provider discovery are deterministic layers, not edits to
  the downloaded file.
- User-supplied model ids are resolved strictly; ambiguous bare ids are never
  selected by catalog order.

### Merge order

The effective catalog is rebuilt in this order:

1. `NIF_MODELS_PATH`, the cached models.dev catalog, or the embedded seed.
2. Registered `x-models-source` plugins, ascending by `priority` and then by
   `component/tool`. A larger priority therefore wins.
3. `NIF_MODELS_OVERRIDE`, always last.

Plugin and local layers are JSON Merge Patches (RFC 7396): objects merge,
arrays and scalar values replace, and `null` deletes a key. The full
models.dev shape is preserved, including fields Niffler does not yet use — so a
patch may add a whole provider, add models under an existing one, or change any
field. A provider or model that omits `id`/`name` has them filled from its map
key, and non-object entries are dropped during normalization.

The component refreshes at startup, whenever the component catalog changes (a
registration or a departure), and then on `NIF_MODELS_REFRESH_INTERVAL`
(default one hour; `0` disables the periodic tick). A models.dev download is
skipped while its cache is younger than five minutes. HTTP fetches are bounded
(16 MiB, 12 s per request), retried up to three times with 200/400 ms backoff,
failing fast on client errors, validated (a catalog with no usable model
entries is rejected, so a malformed response cannot replace the last-known-good
cache), and atomically
renamed into `var/models/api.json`. Each registered plugin source also has a
last-known-good patch named `<component>--<tool>.json` under
`var/models/sources/` (anything outside `A-Za-z0-9-_.` becomes `_`); that patch
is used when the source temporarily fails, but only while the source component
remains registered — removing the component drops its registration, status and
cached patch in one step, so a departed source cannot keep influencing the
catalog. The local override keeps its previous patch when the file is
unreadable mid-rewrite. A failed refresh is retried automatically (30s or the
configured interval, whichever is sooner) so crash reconciliation without
`reg.depart` is not stranded until the next hourly tick. `ev.sys.drain`
cancels refresh work and shuts the component down.

### Tools

| Tool | Purpose |
|---|---|
| `models_providers` | provider connection metadata and configured status, never secret values |
| `models_list` | filtered model search with capabilities, modalities, limits, and costs |
| `models_get` | exact provider/model descriptor for another component |
| `models_resolve` | strict `provider/model` or globally unique bare-id resolution |
| `models_refresh` | queue a refresh of models.dev and every live extension source: it returns immediately with the *current* provenance report plus `queued` and `force`, the work happens asynchronously (registration bursts are coalesced over 150 ms), so read `models_sources` again — or wait for `ev.models.updated` — to see the outcome; `force: true` bypasses the cache TTL |
| `models_sources` | provenance, freshness, stale fallback, and error diagnostics |

All six tools are `onDemand`: they are absent from a conversation's frozen
direct toolset, so the model reaches them through `discover` + `invoke`.
Components and `cli call` address them directly by name. Nothing here is
`hidden`, so `/discover tool=models_sources` lists them.

`models_resolve` never guesses: a bare id that exists under several providers
comes back `found: false` with `matches`, and an unknown reference comes back
`found: false` with up to ten `suggestions`; a `provider/model` string whose
prefix is not a known provider id is looked up as a literal bare id, so a
typo'd provider looks like a missing model. On success the answer carries the
selected `provider`, `model`, `reference`, `configured` and the catalog
`updatedAt`.

`models_list {status: "active"}` also matches models whose status field is
absent (models.dev omits it for normal models). List results are trimmed when
they would exceed the bus payload limit, and an oversized single descriptor
errors instead of timing out on the wire. Descriptor metadata is recursively
redacted: secret-like keys (api keys, tokens, passwords, credentials,
authorization headers, private keys, cookies) never reach a caller, at
provider or model level. Argument shapes: `models_list` takes `status`,
`provider`, `query` and `limit` (default 50, max 500); `models_get` requires
`provider` + `model`; `models_providers`/`models_sources` take no arguments.
List-style results are `{models|providers, count, total}` and are trimmed with
`truncated: true` when they would exceed the bus payload limit, while one
oversized `models_get` descriptor errors instead of timing out.

Live sources: models.dev is the metadata authority (limits, pricing), but the
ids a provider actually serves come from the provider itself. Two
complementary surfaces exist — the `provider` component's `provider_models`
tool probes an endpoint on demand with a stored or explicit credential (the
connect form), and the `llm` component's hidden `llm_models_source` tool
registers as an `x-models-source` plugin (priority 150) whose patch adds the
ids each provider was observed serving. The probe behind it is one background
`GET {baseUrl}/models` per catalog-provider + base-URL key every 10 minutes
(8 s timeout; the ids live in memory only, so a restart forgets them until the
next chat, and the tool answers `no live model data yet` until a probe has
succeeded; the Codex lane is excluded because the ChatGPT backend exposes no
such route) so the whole catalog converges on what endpoints really list. Both
are best-effort: failures never affect chat or the catalog baseline.

`llm` asks `models_get` for the selected model's context window. Explicit
provider `context` and `NIF_OPENAI_CONTEXT` still win, and the existing small
fallback remains available if `models` is removed. Provider endpoints are
classified by hostname, not URL substring. Interactive clients should call the
hidden, credential-free `llm_resolve {model?}` rather than duplicating this
precedence: it reports the effective global provider, optional conversation
model override, catalog, context, and each value's provenance.

### Source plugins

A model source is an ordinary component installed by `plugins`. One hidden
tool carries this registration extension:

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

The contract: the `x-harness.hidden` flag is convention, the `x-models-source`
extension is what registers the tool; `version` must be exactly 1 or the tool
is skipped; `priority` defaults to 100 and equal priorities are ordered by
`component/tool`. `models` discovers marked tools from `reg.publish` and from
core's full catalog snapshot, so component boot order does not matter. It calls
the tool with `{"version": 1}` and a 30 s deadline; a result without a `patch`
object counts as a failure that keeps the last-known-good patch. The result is
a JSON Merge Patch (RFC 7396):

```json
{
  "patch": {
    "openai": {
      "models": {
        "model-with-wrong-limit": {"limit": {"context": 200000}},
        "retired-model": null
      }
    }
  }
}
```

A complete worked source component — marker, tool, package layout and
verification — is in [MODEL_SOURCES.md](MODEL_SOURCES.md).

Put the source in a normal `niffler.json` package. Installation, update,
removal, process isolation, and persistence are already handled by the existing
`plugins` and core lifecycle. Removing the source component immediately removes
its patch from the effective catalog. No model-specific extension mechanism is
added to core.

### Configuration

Configuration variables (`NIF_MODELS_*`) are listed in the master
[Environment variables](#environment-variables) table above.

The cheapest way to fix or add metadata is a JSON Merge Patch file:

```json
{ "deepseek": { "models": { "deepseek-chat": { "limit": { "context": 131072 } } } } }
```

pointed at by `NIF_MODELS_OVERRIDE=/abs/path/override.json` (environment only,
so changing it means `core.kill` + `core.spawn`). It is re-read on every
rebuild, merges after all plugin patches, and `null` deletes a key. A file that
is unreadable mid-rewrite keeps the previous patch and is reported as `stale`
by `models_sources`. The plugin path above remains the durable, shareable
option.

The component only reports which credential environment names a provider uses
and whether one is set, computed at call time and attached to provider and
model results. *Configured* means: one of the provider's `env` names is set, or
the id appears as a nickname in `NIF_LLM_PROVIDERS`, or — for the shipped
`deepseek` entry — `NIF_OPENAI_API_KEY` is set. It never returns credential
values. Provider-specific
OAuth, ambient credentials, headers, request transformations, and native API
behavior belong in inference adapter components, which can be shipped or
installed as plugins independently of this catalog.

#### Verification

`make test-models` boots a private harness with a local fixture catalog and
proves registration, strict resolution, and that a built source plugin's patch
appears on spawn and disappears on removal. Against a live harness,
`./var/bin/cli call models_sources '{}'` prints provenance and
`./var/bin/cli call models_get '{"provider":"deepseek","model":"deepseek-chat"}'`
one descriptor.

---

## System prompt (`systemprompt`)

Status: **implemented** by the `systemprompt` component.

### Boundary

The system prompt is not a tool the LLM calls — it is the standing
instruction set every conversation starts under. It lives in a component,
not in core: core keeps only a minimal structural fallback, and a session
runner fetches the real constitution from `svc.systemprompt.call` once per
conversation. Replacing the constitution is a normal Niffler operation:
write a component that answers on the same subject, `build` it,
`kill` the old one, `spawn` yours. The agent can do this to
itself.

### How it works

- **Frozen per conversation.** The resolved prompt is persisted in the
  conversation header (`systemPrompt` field) at the first turn and reused
  verbatim on every resume, in any runner process. The prompt prefix stays
  stable so providers reuse it; a component that dies or changes
  mid-conversation never rewrites a running conversation's instructions.
- **Fallback.** Component absent, slow (500 ms probe, then an 8 s budget
  when the catalog says it is registered), or broken → core's baked-in
  minimal prompt. Core never hard-depends on a component for boot.
- **Cap.** Answers are truncated at 200 KB (both sides).
- **Agent pre-fetch.** The `agent` component requests the prompt for
  subagent children before their first turn and passes it via the session
  call's `systemPrompt` field (best effort — the runner's own fallback
  covers a missing component).

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt` — the product prompt
   (self-extension ladder, SDK examples, repo layout), `$ROOT`-substituted,
   baked into the binary at compile time via `staticRead`. Editing it is
   rebuild + respawn; there is no runtime file dependency.
2. The repo's local context files, Pi-style, wrapped in
   `<project_context>`/`<project_instructions path="...">` tags after the
   product prompt:
   - per directory, first hit wins: `AGENTS.override.md`, `AGENTS.md`,
     `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` (one file per directory —
     `AGENTS.md` shadows a `CLAUDE.md` next to it; symlinks are followed);
   - ancestor walk from the conversation's cwd up to `/`, harness root
     first, deduplicated by path — nearer-to-cwd files appear later, so the
     most specific instructions are the last thing the model reads;
   - worktree shadow rule: when the harness root is a `git worktree` under
     the main repo, the main repo root's context file is skipped — the
     ancestor walk would otherwise apply the same logical repo scope twice;
   - lazy loading: a `read` that enters a directory *below* the harness
     root appends any newly discovered `AGENTS.override.md`/`AGENTS.md`/
     `AGENTS.MD`/`CLAUDE.md`/`CLAUDE.MD` (+ `AGENTS.local.md`) for the
     directories on the path, each wrapped in `<lazy_project_instructions
     path="…">`, once per session — a monorepo subtree stays out of the
     frozen head until the model actually enters it.
3. A per-conversation `<workspace>` tail, appended only when the
   conversation's cwd is **not** the harness root: it names the working
   directory (relative paths resolve from it) and the harness root, so
   `docs/`, `components/` and `sdk/` resolve by absolute path from an
   out-of-root workspace. The frozen head above stays path-free either way —
   the root is a per-conversation fact, identical for every conversation on
   one machine, so provider cache prefixes still line up.

The tool is `x-harness.hidden` — it never appears in an LLM toolset; it is
infrastructure, reachable only by core and by components.

## Observation and logs

Status: **implemented** by the `observe` and `logfile` components.

### Boundary

Observe the bus, not component internals. Both components are ordinary NATS
citizens built on the SDK; core never imports them. The only core integration is
optional nats-server HTTP monitoring: when core owns the bus it allocates a
second loopback port and writes `var/nats-monitor-url` after the server is live.

Observation is an administrative capability. A bus capture can contain tool
arguments, model output, approvals, and data from every session. Niffler's
current trust model is a single trusted user/admin; do not expose the observe
service or capture directories to untrusted bus clients.

**Not an audit trail.** None of these components is a durable record of
decisions: `observe` keeps a bounded in-memory ring that dies with the
component, `logfile` is best-effort (at-most-once, `ev.log.>` by default),
`console` prints and forgets, and `hooks` record nothing. The only durable
artefacts of the approval gate are the client-written grant record (store
kind `approval`) and the program source core writes to
`var/approval-sources/<digest>.nim` — no request/verdict history exists.

### `observe`: bounded live inspection

`observe` has one raw `>` subscription. It preserves the original JSON node,
including unknown envelope fields and bare registration payloads. Malformed JSON
is retained as `{raw, decodeError}` when it is valid UTF-8; arbitrary bytes use
lossless `rawBase64` instead. Oversized messages are represented by a bounded
base64 preview rather than letting one message consume the process.

The global ring is bounded by both message count and approximate wire bytes.
Each targeted probe has independent count and byte bounds; the number of probes
is also capped. Stopped probes remain queryable until `observe_remove` releases
their memory.

| Tool | Use |
|---|---|
| `observe_subjects` | List the authoritative component/service view when core is reachable, known event patterns, and the most frequently observed concrete subjects |
| `observe_listen` | Start a bounded capture for a token-correct NATS pattern (`*` and terminal `>`) plus optional regex |
| `observe_trace` | Capture calls to one component and correlate result/error inbox replies by envelope id |
| `observe_probes` | Inspect probe state, retained bytes, caps, and pending traces |
| `observe_stop` | Freeze a probe while retaining its entries |
| `observe_remove` | Delete a probe and release its memory |
| `observe_events` | Query a probe or the global ring, newest first, with time/kind/component/subject/regex filters |
| `observe_logs` | Query recent `ev.log.*` events in memory |
| `observe_dump` | Approval-gated export of one probe beneath `NIF_OBSERVE_CAPTURE_DIR`; arbitrary output paths are not accepted |
| `observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns; approval-gated — it borrows the operator's monitoring endpoint |
| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |
| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated and limited to 30 seconds |

`observe_send` cannot send call/result/error envelopes or registrations.
`observe_send`, `observe_request`, `observe_monitor`, and the
filesystem-mutating `observe_dump` carry `x-harness.approval: always`, so
an LLM path must pass core's human gate.
A client talking directly to `svc.observe.call` is already a trusted bus peer
and bypasses core policy, just as it can call any other service subject directly.
Generated captures are pruned oldest-first to a byte quota and a 256-file cap.

Trace requests expire from the pending correlation table after 60 seconds.
Probe subjects, labels, and regular expressions have fixed input limits;
oversized probe entries are dropped and counted rather than retained outside the
byte budget. Tool responses stop before the wire's approximately 64 KiB
inline-result convention and report `truncated` (or value byte metadata for a
large diagnostic reply) rather than returning unbounded data.

### `logfile`: rotating JSONL persistence

`logfile` is best-effort process-local persistence, not an audit log. Core NATS
is at-most-once: records emitted before startup or during a restart are lost.
Guaranteed replay would require an explicit JetStream design.

Default input is `ev.log.>`. A valid component name gets one file:

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including
whole-bus `>`, goes to a single `bus.jsonl`; dynamic inbox subjects therefore do
not create unbounded file descriptors or filenames. The number of component log
files is capped, and excess/spoofed component subjects also fall back to
`bus.jsonl`. Multiple configured patterns are treated as one locally filtered
union, so overlapping patterns persist each matching publication exactly once.

Every line records sink time and original wire data:

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses
`raw` and `decodeError`. The sink opens, appends, flushes, and closes each record.
Rotation compares `current size + record size` before
renaming closed files, so exact-boundary writes cannot leave a stale file handle.
A single record larger than the configured file size is retained as the active
file and rotated before the next record. `NIF_LOGFILE_KEEP=0` retains no rotated
generation.

`logfile_search` reads only a bounded tail from the retained files, sorts
matching records by `receivedAt` newest-first, and reports `truncated`,
`scannedBytes`, malformed line counts, and read errors. Results also have an
encoded response-byte budget. Structured log records expose `component`,
`level`, `msg`, `ctx`, and optional emitter time; raw bus records expose the
preserved message. Search never trusts an emitter-supplied timestamp for
`since`/`until` windows.
Directory enumeration is capped by `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports
`directoryTruncated` when more files exist; searches still inspect the bounded
subset.

`logfile_paths` reports a bounded retained-file list plus `writeErrors`,
`lastError`, and `lastErrorAt`. Filesystem failures also go to stderr. Capture
directories are user-only where the platform permits; active symlink targets
are rejected.

### SDK APIs

All three SDKs expose the same observation/logging and raw-envelope APIs:

```nim
type TapHandler* = proc(c: Component, subject: string, data: string)
proc tap*(c: Component, pattern: string, handler: TapHandler): Component
proc log*(c: Component, level, msg: string, ctx: JsonNode = nil)
proc publishEnvelope*(c: Component, subject: string, env: Envelope)
proc requestEnvelope*(c: Component, subject: string, env: Envelope,
                      timeoutMs: int = 5000): Envelope
```

```go
func (c *Component) Tap(pattern string, h TapHandler) *Component
func (c *Component) Log(level, msg string, ctx any) error
func (c *Component) PublishEnvelope(subject string, env Envelope) error
func (c *Component) RequestEnvelope(subject string, env Envelope, timeout time.Duration) (Envelope, error)
```

```ts
comp.tap(pattern, handler)
comp.log(level, msg, ctx?)
comp.publishEnvelope(subject, envelope)
await comp.requestEnvelope(subject, envelope, timeoutMs?)
```

Each SDK lets NATS perform subject matching and dispatches only the handler bound
to the subscription that delivered the message. This avoids the previous
cross-product where one call could be delivered through the call, event, and tap
paths multiple times. Nim remains callback-free and thread-free; Go uses its
existing mutex and TypeScript its promise chain.
Go waits for drained subscription callbacks (up to its bounded shutdown grace),
and TypeScript waits for queued handlers without deadlocking a handler that
explicitly closes its own component.

#### Idle work (`onIdle`)

All three SDKs expose the same *idle seam* — a callback for work that no request
can carry (reaping background children, health probes, cache refreshes).
`components/processes` uses it to notice a background child's exit without
anyone polling, which is what makes its exit notice possible.

```nim
proc onIdle*(c: Component, intervalMs: int, handler: IdleHandler): Component
```

```go
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component
```

```ts
comp.onIdle(intervalMs, handler)
```

The API is mirrored; the *execution model* is each runtime's, so the contract is
stated per SDK:

| SDK | runs on | exclusion |
|---|---|---|
| Nim | the pump loop, between passes | never while a handler runs — that loop is serialized |
| Go | its own ticker goroutine | takes the serial handler lock; `ToolConcurrent` handlers hold only the read lock, so it may overlap those |
| TS | the promise chain, like every handler | never interleaves with another handler |

Common to all three: register before connect/run, one handler per component (a
second registration replaces the first), the interval is floored at 10ms, the
timer starts with the connection and stops at close, and a panicking idle
handler is logged, never fatal. Prefer it to a component thread whenever
“every N seconds” is all you need.

Nim's arbitrary-envelope request helper continues pumping only raw tap
subscriptions while it waits. Tool and event handlers remain non-nested, while
an observer can timestamp the target request and reply during an
`observe_request`. Trace durations and expiry use a monotonic clock; displayed
`at` values remain wall-clock epoch seconds.

Structured logs publish an event on the exact subject `ev.log.<component>` with
`{component, level, msg, ctx?, at}`. Levels are `debug`, `info`, `warn`, and
`error`. `NIF_LOG_LEVEL` defaults to `info` and suppresses lower levels before
publication in every SDK. Invalid emitted levels fail; an invalid threshold
falls back to `info`.

### Monitoring

When core spawns nats-server it uses distinct loopback client and HTTP ports,
then writes (the binary is the built component `var/bin/nats-server` from
`components/nats` when present, else a PATH `nats-server`):

```text
var/nats-url
var/nats-monitor-url
```

The monitor discovery file is written only after the client connection succeeds.
A reused or remote bus has no discoverable HTTP endpoint; configure
`NIF_OBSERVE_MONITOR_URL` explicitly. `NIF_NATS_SPAWN=1` forces an isolated
core-owned bus on a random port (primarily for tests and diagnostics) —
never 4222; an explicit `NIF_NATS_URL` in the environment wins.

`observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each
request. It reports whether subscription detail was truncated; `mostSubscribed`
means subscriber density, not message throughput.

All `NIF_OBSERVE_*`, `NIF_LOGFILE_*` and `NIF_LOG_LEVEL` variables are
listed in the master [Environment variables](#environment-variables) table above.

All bounds are validated at startup; invalid configuration exits non-zero
rather than silently substituting a default.

### Verification

`tests/t_observe.nim` covers exact-once taps, wildcard boundaries, registration
capture, cap/byte eviction, monotonic trace correlation during diagnostic
requests, malformed-call replies, timeout behavior, embedded-NUL and
invalid-UTF-8 raw data, response bounds, approval metadata, quota-pruned safe
dumps, monitor discovery, and invalid configuration.

`tests/t_logfile.nim` covers SDK log filtering, newest-first queries, time/regex
filters, encoded response and actual disk-read bounds, exact-once overlapping
subject patterns, closed-file rotation, zero retention, embedded-NUL whole-bus
preservation, bounded path listings, sink health, and invalid configuration.
Both tests use isolated temporary output directories and are part of `make test`.
## Fabric and subagents

The `fabric` component adds programmable tool calling: the model writes a
Nim program that drives Niffler tools itself, and only the program's
`finish()` value enters the conversation. The `agent` component turns
sessions into subagents. The full design and threat model:
[research/FABRIC.md](research/FABRIC.md) (the external review that shaped it:
[research/FABRIC_FEEDBACK.md](research/FABRIC_FEEDBACK.md)). User-facing
guide with nudge phrasing and worked examples:
[FABRIC_GUIDE.md](FABRIC_GUIDE.md).

| Tool | What it does |
|---|---|
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | Run one LLM-written Nim program: `var/bin/fabric-exec` compiles it into a private process (no embedded VM; an identical program is cached in `var/fabric-cache`, self-bounded at 64 entries / 128 MB, evicting least-recently-stored). `code` is inline program source; `name` runs a stored program from the model-curated `fabricprog` library instead. With `tools`, selected schemas are pinned and generate compile-time-checked `tools.<name>(...)` wrappers; allowlisted `callTool` remains the fallback. Only `finish(value)` reaches the conversation. Approved native code is bash-class trust, not a sandbox. Budgets: `maxCalls` defaults to 200 (max 1000) and `timeoutMs` to 240 s (hard cap 300 s, also clamped to the caller's remaining session deadline); every nested call inherits the run's remaining time, and oversized `finish()` values spill to `var/fabric-artifacts/<run>.json` ([FABRIC_GUIDE.md](FABRIC_GUIDE.md), "Budgets and limits"). |
| `fabric_help {topic?}` | Read the Fabric guest reference and worked-example sources from inside the component; an empty `topic` returns the reference plus the example index, a topic returns that program. Discover-only: reach it through `discover` + `invoke` when you are about to write a program, so you never have to locate component files. |
| `agent_run {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | Run a task in a subagent session and return its final reply. Without `session` it starts a **fresh** child (own runner, own loop): its `model`/`modelTier`/`thinking`/`tools`/budgets come from this call and freeze at its first turn, exactly as a continuation's were. With `session` (a previously returned `sessionId`) it gives that **existing child another turn** — its conversation, model, thinking, tools and budgets are frozen at its first turn, so the caller's model/thinking/tools/budget arguments are ignored and the result reports the child's `effective` controls; the child must belong to this conversation, must not be closed, and must not be mid-turn (that refuses with `code: "busy"` — use `agent_spawn` to queue instead). Optional per-job budgets on fresh runs: `maxRounds` (tool rounds per turn, 1–`NIF_MAX_TURN_ROUNDS`), `maxCalls` (total tool dispatches, 1-500), `maxTokens` (cumulative tokens) — exhaustion ends the turn as a budget-exhausted failure. `model` is an exact id, while `modelTier` (`weak`/`medium`/`strong`) resolves through `NIF_AGENT_MODEL_*` and is clamped to the parent's tier — the two are mutually exclusive. `close: true` retires the child after this turn (nothing is deleted; later continuations refuse). |
| `agent_spawn {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | Start the same kind of task in the background; returns `{jobId, sessionId}` immediately. Without `session` it starts a fresh child; with `session` it **queues** another turn for an existing child (same frozen-controls rules as `agent_run`, but a mid-turn child is fine — the turn runs next; only the lineage parent may continue). `close: true` retires the child after the queued/background turn settles. `timeoutMs` is the job budget: once exceeded the job is cancelled (agent_stop semantics) the next time it is observed. |
| `agent_status {jobId}` | Non-blocking durable job lookup (running/done/failed/stopped + reply or error). |
| `agent_wait {jobId, timeoutMs?}` | Block until a background job is terminal; late waits read the durable record. |
| `agent_stop {jobId}` | Cancel a running job for real: the child's LLM request is aborted, its turn ends promptly, and an in-flight bash command is killed (whole process tree). The terminal record says "stopped". |
| `agent_steer {session_id, message}` | Inject a message into a running background job's turn (drained between LLM rounds). |
| `agent_ask {session, question, timeoutMs?}` | Ask a child a question and get its answer. An idle child answers directly — this is an ordinary continuation (`timeoutMs` bounds the wait, default 300 s) — while a **mid-turn** child cannot start a second turn, so the question is queued as parent mail and arrives with its next continuation (the result says `queued: true`, `deliveredVia: "next-turn"`). The same lineage authorization as `agent_run` applies: unknown, foreign and closed children refuse. Approval-gated. |
| `agent_list {scope?}` | The caller's subagent roster, derived from the durable lineage: one row per child with its `sessionId`, `jobId`, `task`, and a residency-based `status` — `running` (working now), `idle` (resident between turns), `ready` (storage only; **resumable, not finished**). `scope: "descendants"` walks the whole tree below you, while the default `children` is the depth-1 view; real nesting exists once `NIF_AGENT_MAX_DEPTH` is raised above 1. You are told when a child settles, so this is for orientation, not polling. |
| `agent_notices {session?, peek?}` | Drain this conversation's pending subagent **settlement notices** — one entry per background child that finished, was stopped, or failed. Notices are delivered automatically (see below); this is for notices that arrived while the conversation was idle, and `peek` looks without consuming. |

### Settlement notices

A background child that reaches a terminal state tells its **parent
conversation**, not just the UI (`ev.agent.done` is observe-only). The notice
is a durable `agentnotice` record written before any delivery is attempted,
and it is a *pointer*, not the reply:

- while the parent's turn is running, the notice is folded in immediately
  (steer lane) as a structurally marked user message; the would-stop point
  drains notices too, so a turn cannot close over a child that finished
  during its last step (`NIF_AGENT_NOTICE_HOLD=0` disables only that hold);
- otherwise the parent is **woken**: the agent component starts a turn whose
  only job is folding the pending notices in, so the settlement is visible
  without the human asking. Wakes are bounded by `NIF_AGENT_WAKES` (default 3
  consecutive wake turns; the human's next message resets the budget, `0`
  disables waking). A declined wake persists nothing, and the parent's next
  turn pulls every pending notice at the top of the turn (pull lane) — so the
  model never has to poll;
- either way the notice carries a bounded `summary`, `replyBytes` (the
  untruncated length) and `fullReplyIn: "agent_status"`, because the full
  reply is already durable in the `agentjob` record and one call away.

Notices are best-effort: an unreachable store or agent component costs a
notice, never a turn.

### Continuation (sessions with memory)

Both drivers take `session`: a previously returned `sessionId` gives that
child another turn instead of minting a fresh one. The child keeps its
conversation — send only the new task. Authorization is the durable lineage
relation (`sessionmeta.parent`), so only the child's own parent conversation
can continue it, and every failure refuses explicitly: unknown session, root
conversation, foreign child, closed child and an unreachable store all
return distinct errors rather than silently starting a fresh child.

The two drivers differ exactly where their promises differ:

- `agent_run {session}` promises a result **now**, so a mid-turn child is
  refused (`code: "busy"`, naming `agent_spawn`/`agent_wait`/`agent_status`);
- `agent_spawn {session}` promises the work **happens**, so it queues —
  the child's runner serializes turns and runs the queued one next.

Continuation is append-only history: the follow-up task is persisted as the
next user message (no preamble, no system prompt), so the child's cached
prefix survives. Each turn advances the child's activation ledger
(`sessionmeta.activations`, with `firstActivationAt`), and background
continuations stamp `continued`/`activation` on their `agentjob` record.
`close: true` retires a child after its turn (`sessionmeta.closed`) — the
record and transcript survive; only further continuation refuses.

### Delegation depth

`NIF_AGENT_MAX_DEPTH` (default **1**) caps how deep delegation may nest,
evaluated by walking `sessionmeta.parent` links at dispatch time. `0`
forbids delegation entirely. The spawn tools stay visible at the cap: a
denied start returns an error naming the limit and the caller's depth, so
the model learns why. Raising it above 1 is a deliberate act — a child's
synchronous `agent_run` is served re-entrantly by the agent component
(see WIRE.md "Delegation depth"), and `agent_spawn` from a child needs no
re-entrancy at all (background jobs never hold the pump).

### Fork (a child that has read the discussion)

`fork: true | {"lastK": n} | {"maxChars": n}` — on **fresh spawns only** (a
fork is a birth, not a continuation; `fork` + `session` is refused) — seeds
the child's message log with this conversation's **completed turns** before
its first request, so the child has *read* the discussion instead of being
told about it. The result and `session_info` carry the provenance
(`{source, uptoId, copied}`).

- **The cut is balanced and contiguous-from-0**: it lands on completed-turn
  boundaries only — never mid-tool-round — and the seed is the longest
  transcript prefix that replays as a valid provider message list (every
  `tool_calls` answered by its tool records, no orphaned tool records). An
  in-flight turn at the tail is excluded; a crash left dangling mid-history
  truncates the fork there (fail-closed beats copying an unbalanced prefix).
- **Budgets cut on turn boundaries** and a selection that drops everything
  fails closed — an empty child would look like success while being wrong.
- **What is not copied**: per-message `usage` meters (the child's accounting
  is its own), `summary`/`error` role records (a summary is a derivation of
  records that are copied raw; error records are the parent's audit), the
  toolset snapshot (`<session>:tools`), and the header's control fields —
  a fork is a birth: the caller's `tools`/`maxRounds`/… arguments freeze the
  child's controls from this call, never the parent's.
- **Born cold**: the child's first request replays the inherited history
  uncached; warm from the second turn. That is the price of *judgment*
  inheritance, and the right trade only when the preamble would otherwise
  have to narrate the context. Bulk transfer with no judgment needed is
  what `fabric` is for.

### Fabric (programmable tool calling)

- **Governance, not sandbox**: the guest is in bash's trust class — the human
  approves the program once (`x-harness.approval: always`). Every nested call
  crosses the session nested-call proxy (`svc.session.<id>.tool`), re-entering
  the single dispatch gate (approval, complete schema validation, deadline).
  The executor child holds no NATS connection, no credentials and no
  inherited `NIF_*` environment: it sees only `PATH`, a scratch
  `HOME`/`TMPDIR` and the cache path.
- **Approval manifests**: program approvals show a source digest, the full
  program under `var/approval-sources/<digest>.nim` (mode 0600), the selected
  tools, and the declared budgets. Persisted auto-approve is keyed by
  `fabric:<digest>` — approving one program never covers a different one.
- **Guards**: proxy rejects hidden tools and internal/recursive surfaces
  (`fabric`, `agent`, `chat`, `session`, `invoke`, `session_prepare`); a
  per-turn lease expires stale requests; in typed mode each call is checked
  against the pinned component fingerprint, so a component replaced mid-run
  fails with `catalog-changed` instead of calling a drifted tool; `maxCalls`
  budgets calls;
  `x-harness.noSpawn` denies subagent spawns from subagents at dispatch time.
- **Effect-aware batching**: `batch()` keeps at most 4 calls on the bus at once. Each tool is classified by `x-harness.effect` (anything undeclared counts as a write); reads may fill the cap together, writes are globally exclusive, not per target.
- **Context economy**: intermediate results never enter the conversation;
  oversized `finish()` values spill to `var/fabric-artifacts/<run>.json`
  (mode 0600) and the tool result points at the path.
- **Guest API**: `import fabricguest` gives the structured `call(tool, JsonNode) ->
  JsonNode`, `batch`, `finish(JsonNode)`, `log`/`logg`, `stringArg`/`inputs`
  (plus the legacy `callTool`/`j*` string helpers). `fabricmeta.nim` turns
  pinned runtime schemas into input-typed wrappers; results are `JsonNode`
  unless the tool declares a scalar `outputSchema`. The `fabric_help` tool
  returns the reference and example sources from inside the component,
  without locating files. Worked examples: `components/fabric/examples/`.
- **When to use what**: direct loop for judgment-per-step work; `fabric` for
  mechanical known-shape orchestration; `agent_run` for exploratory subtasks
  that need their own context; hybrid programs may call `agent_run`.

## Expert advisory peer (`expert`)

The `expert` component is a non-interactive advisory peer (design:
[research/EXPERT.md](research/EXPERT.md) — §2 knowledge prefix, §4 scheduling,
§5 judgment contract, §6 turn-bound advice, §8 cost and observability). It follows one or more working
sessions concurrently — armed explicitly with `expert_follow {session_id}`
(approval-gated, off by default, and on demand: arm it with `discover` +
`invoke`, or from a shell with `./var/bin/cli call expert_follow
'{"session_id": "conv-…"}'`; the component is inert until then) — watches
each followed session's
`ev.session.*` events (toolcall start/done — the judgment trigger — turn
start/done, assistant text, the reasoning tail of token deltas, and a
context-pressure trip at 80 % of the window) into a bounded per-session
in-memory current-turn frame that is cleared at turn done, so no evidence ever
crosses a turn, and asks an LLM judge (a stateless hidden-`chat` call: fixed
cache-stable knowledge prefix — sized from `llm.llm_resolve` to 80 % of the
judge's window minus an 8 000-token reserve for the observation and the verdict,
and cached per follow — plus one ephemeral observation, no tools) whether
the evidence warrants a steer. Only high-confidence steers naming live,
non-hidden tools are delivered, and only if the gates hold: the steer carries a
non-empty `tools` list and a non-empty message within the `MaxMessage` cap, each
name is normalized (backticks stripped, `component.tool` reduced to the tool),
must be visible to that session, must appear in the message text, and at least
one of them must be a tool the worker is not already using in this turn — a
steer naming only tools already in the frame is read as silence, not as a change
of tool. Delivery is through the turn-bound
`svc.session.<id>.advise` request/reply surface: the runner accepts advice
only while that exact turn is still running — late advice is rejected
(`stale-turn`/`no-active-turn`, plus `wrong-session`, `empty` and `duplicate`
for an exact repeat of the last advice, and `advisory-limit` once the turn has
one), never queued into the next turn. Accepted
advice is folded as a marked user message (`[Niffler advisor: expert] ...`),
persisted, and announced on `ev.session.advice`. The judge lane itself stays
global: one judgment in flight, shared cooldown, per-session latest-state
coalescing. Every parsed judgment — silence included — is published as an
`ev.log.expert` line (action, reason, message), which is how an operator answers
"why was it silent?". The published numbers: at most 2 judgments per turn
(`MaxJudgmentsPerTurn`) with at least 8 s between them (`EvalCooldownMs`); the
frame keeps 8 recent tool activities (`MaxActivities`), clips each field at
400 chars (`MaxField`), keeps a 2 000-char reasoning tail (`MaxReasoningTail`)
and caps an advisory message at 1 200 chars (`MaxMessage`). The judge call
itself is capped at 1 536 output tokens (`JudgeMaxOutputTokens`), asks for
`reasoning_effort: "low"` (`JudgeReasoningEffort`) and times out after 120 s
(`ChatTimeoutMs`) — all three are compile-time constants, so changing one means
editing `components/expert/main.nim` and rebuilding. The token cap is
best-effort: a gateway may ignore it.

| Tool | What it does |
|---|---|
| `expert_follow {session_id, model?, provider?}` | Follow a session (multi-target: each followed session keeps its own frame, knowledge prefix, judgment budget and per-follow metrics); re-following resets its frame. `model`/`provider` override the judgment calls for that follow; without them the judge runs on `llm`'s default backend (the active provider), which keeps judge cost off the worker's model. Approval-gated. |
| `expert_unfollow {session_id?}` | With `session_id`: drop that follow. Without: drop all follows and discard their frames. |
| `expert_reload` | Rebuild the knowledge prefix of every followed session from the live catalog (new cache epoch). |
| `expert_status {session_id?}` | With `session_id`: that follow's frame, knowledge version, per-session counters (judgments, silences, steers, accepted, rejected, staleDrops, errors), the prefix diagnostics (`liveTools`, `skills`, `prefixChars`, `prefixBudgetTokens`) and judge token totals (`tokens {prompt, cached, completion}`). Without: followed targets plus lifetime diagnostics (the same counters and token totals, lifetime). |

The component has no configuration of its own: no `NIF_*` variable changes how
it follows or judges (`NIF_LOG_LEVEL` only decides whether its own
`ev.log.expert` lines are visible).

Design invariants: the working session never waits for the expert
(best-effort, cooldown, latest-state coalescing); no growing expert
transcript (every judgment is stateless) and nothing durable in the component
itself — frames, prefixes and counters live in the process, so a restart drops
every follow and re-arming is explicit; the only stored artifact of an accepted
steer is the folded message record in the followed conversation); fail closed
(any parse/validation/
transport error is silence); the expert never acts — it only suggests, and
approval-gated work stays with the working session's human gate.

The prefix holds the component's own policy, the three reviewed bundled skills
(`niffler-tools`, `niffler-fabric`, `niffler-harness` — a project or home skill
that shadows a bundled name is refused, so that allowlist is the trust
boundary), then the observed session's own tool view: its frozen direct
exposure and tool allowlist (read from `core.prompt_preview`) plus the on-demand
tools it could `discover`. Never the global LLM toolset — that would overstate
what an older or allowlisted session can actually call.

## Recovery

The repo is the snapshot; `var/` is disposable build output — delete build
output with `make clean`, never a bare `rm -rf var`; and a `store` that
refuses to start means another process still holds the lock
(`var/store.db.lock` / `var/barrel-db.lock`), not a stale file: `make down`
or kill the stale store and the kernel releases it. If the agent
(or a bug) breaks a shipped component — overwrote a binary in `var/bin`,
corrupted a spawned component's record, or a self-added component crashes
on boot — start Niffler in recover mode:

```bash
make recover        # stops anything running, then ./var/bin/niffler --recover
```

`--recover` does three things, in order:

1. **Rebuilds the shipped binaries from source** (`make build`, falling
   back to `nimble all`) — fixes overwritten/corrupted `var/bin/*`.
2. **Wipes the store's component records** — no persisted extra component
   shape remains to restore.
3. Boots the requested profile (normally the full interactive harness;
   `--recover --minimal` selects the minimal profile). **Conversations and
   messages survive** — only the component shape is reset.

For damage to *sources* (someone edited `components/`, `core/`, `sdk/`,
`manifest.yaml` or the `Makefile`):

```bash
# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)
git restore components/ core/ sdk/ manifest.yaml Makefile   # or: git checkout -- .
make build
./var/bin/niffler                       # or just reopen the UI
```

## The store

`store` is a component like any other — a document store over the bus with
`put` / `get` / `list` / `del` and rev-based optimistic concurrency
(`put` accepts `expectRev` and fails with `rev-conflict` on mismatch).
`get` and `list` are on-demand tools; `del` is hidden — core deletes records,
the model cannot. A **session-bound caller may only write curated kinds**
(`fabricprog` today): every other kind is harness-managed and refused with
`forbidden-kind`, so no live session can corrupt transcripts or component
records. Direct bus callers (cli, tests, core) keep full access.
Kinds in use by core and its components (the store tools' own docstrings name
only a subset — this table is the complete list):

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` — the conversation header (also carries the frozen system prompt, model/thinking selection, per-session budget controls and token meters) |
| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` — persisted shape restored on boot |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` — install record of the `plugins` component |
| `provider` | nickname (plus the `active` marker doc) | LLM provider registry of the `provider` component. Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only |
| `session` | `<sessionId>:tools` | the conversation's frozen direct toolset snapshot (see [Progressive tool discovery](#progressive-tool-discovery)) |
| `slash` | `slash` | the merged slash-command table UIs render (see [WIRE.md](WIRE.md)) |
| `agentjob` | `<jobId>` | durable background `agent_spawn` job records (continuations stamp `continued`, `activation`, and queue `close`) |
| `agentnotice` | `<parentSession>:<seq>` | subagent settlement notices (summary + recourse to the full reply; `deliveredAt`/`deliveredVia` mark delivery) |
| `sessionmeta` | `<sessionId>` | subagent lineage / runner metadata: `{parent}` on spawn; continuations add `activations` (turn count, 1-based) and `firstActivationAt`; `close: true` retirement sets `closed` |
| `fabricprog` | program name | the model-curated fabric program library (`fabric {name}` runs one) |
| `profile` | profile name | named tool-profile selector list of the `profile` core tool; resolved once into a conversation's direct toolset at its first turn |
| `approval` | `<sessionId>:<key>` | a client's "don't ask again" grant (keyed by tool, or `tool:<digest>` for program-shaped calls); core reads it to skip the approval gate |
| `contextreceipt` | `<convId>:<requestId>` | the request-scoped receipt of an overflow-recovery attempt, written before it is spent and updated with the outcome |
| `compaction_input` | `<convId>:<attemptId>` | the paged pre-compaction snapshot the compaction component verifies and the runner commits from (pages are `<id>:p<idx>`) |
| `context_projection` | `<convId>` | the committed context projection (cut, checkpoint, generation) a runner reuses after compaction |
| `spill` | `<convId>:<n>` | an oversized tool result promoted out of the context window, addressable with `context_recall {"ref": {"source": "spill", "id": "…"}}` |
| `mcp` | server name | MCP server config record of the `mcp` component (see [External MCP servers](#external-mcp-servers-mcp)) |
| `selftest` | store self-test probe | throwaway — written and deleted by the store's own self-test roundtrip |

Backend is the selected engine — SQLite at `var/store.db` by default,
BitBarrel at `var/barrel-db` with `NIF_STORE_BACKEND=barrel`, or the
DSN-shared TiDB engine (`NIF_STORE_TIDB_DSN`, no flock — row locks and the
rev counter arbitrate between harnesses). **Exactly one process owns that
file** — never run two file-backed `store` processes against the same
database (a second core booted against the same root would do exactly that;
use a temp `NIF_ROOT` copy for experiments).

`list` is a page, not a complete view (see [Store engines](#store-engines)):
everything in core that must see a whole kind goes through `storeListAll` —
a single capped `list` silently truncated long transcripts on resume.

## Testing

```bash
make test           # the full gate: frontend tests, then the bus-contract suite
make test-server    # ... server side only: one test-owned NATS per test, no node
make test-ui        # ... frontend side only: lib unit tests + `npm run typecheck`
make test-bash      # ... or just one — `make help` lists every target
                 # (test-uireg, test-autostart, test-<component>); the full
                 # bus suite is `make test-server`
```

Each test boots the real component binaries (Nim, Go *and* TypeScript —
the envelope is the artifact, so one harness tests every SDK) and drives
them over a private nats-server each test starts for itself (`NIF_NATS_SPAWN`-style isolation).
The frontend tests are the exception: they import the TypeScript lib modules
(`ui/frontend/src/lib/*.ts`) and run on plain node with type stripping, so
`make test-ui` needs neither dependencies nor a bus (`npm run typecheck`
does need `ui/frontend/node_modules`, which `make ui` installs). `make test`
is simply `make test-ui` + `make test-server`; use `make test-server` for
server-side work and `make test-ui` for frontend work.
Core-based tests snapshot their required binaries into a unique temporary
`NIF_ROOT`; Barrel, plugin clones, generated components, logs, and caches are
therefore isolated. Individual `make test-*` targets may run concurrently
with each other and a live development harness. Repository build writes are
serialized, while agent-built test components use sandbox-local Nim caches.
`/doctor deep` additionally fans out to each component's own self test over
the bus (`comp.selfTest`): `bash`, for example, really execs a command through
its process-group path and then proves the timeout kill at a 1 s budget,
expecting exit 124.
Network opt-ins: `NIF_TEST_INSTALL=1` runs the real
`cli install gokr/niffler-weather` + tool validation; `NIF_TEST_NETWORK=1`
runs `plugin_search` against GitHub, `skill_search` against skills.sh, and
the TypeScript builder build
(npm registry). The install pipeline itself is covered hermetically by
`t_plugins` via a local `file://` git repo.
Observe/logfile tests use temporary output directories and never delete the
developer's `var/logs` or `var/captures`. External network opt-ins can still
share provider rate limits even though their local state is isolated.

## Starting and stopping

There is no launcher script — the binaries own the lifecycle:

- **Desktop icon / `niffler-ui`** — the common case. The bridge's first act
  is the SDK's `ensureHarness`: probe `NIF_NATS_URL` → `var/nats-url` →
  127.0.0.1:4222 for a core serving **this root** (the catalog carries the
  owning harness's root; a foreign clone's core is never adopted); if none
  answers, spawn `var/bin/niffler` detached with `NIF_AUTOSTART=1`. The
  repo root is baked in at `make ui` time (ldflags), so the installed icon
  works as well as the in-tree binary.
  The probes are patient: attaching retries for ~10 s at 200 ms, and a spawned
  core must answer within 20 s or `ensureHarness` fails with `spawned core did
  not answer within 20s — check <root>` (the Nim SDK first reaps a core it
  spawned earlier in the same session, if it has exited).
- **Interactive plugins** (e.g. `niffler-tui`) — they do **not** call
  `ensureHarness` and never spawn a harness: they probe for a live bus
  (`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` →
  127.0.0.1:4222), connect and register `client: true` (so an autostarted
  core stays up while they run). Unlike `ensureHarness` they do **not** check
  which root the answering core serves, so a TUI can join a foreign harness's
  bus that the desktop UI would refuse. Start the harness first — desktop UI
  or `./var/bin/niffler`.
- **Terminal admin shell** — `./var/bin/niffler` directly, or
  `./var/bin/niffler --minimal` for the three-component boot profile. A
  manually started core never self-terminates; stop it with Ctrl-C / SIGTERM.
  `NIF_AUTOSTART=1` in the environment overrides the shell — that core is
  service mode even on a tty — and while it sits at the prompt it keeps
  serving `svc.core.call`, so a UI can attach to a tty-started core.

Interactive frontends register `"client": true` (the SDK's `interactive()`
/ `Component.Client` marker). That mark is a registration, not a lease: a
client killed without `reg.depart` keeps an autostarted core up — and keeps
core believing a human is reachable for approvals — until the catalog drops
it (the `ui` registry's 20 s lease is a separate clock, see
[Clients and the UI registry](#clients-and-the-ui-registry)). An
**autostarted** core counts them: when the last one departs it shuts down
after `NIF_AUTOSTART_IDLE_S` (default 10s —
a restarting UI re-registers inside that window), taking its components and
spawned bus with it; if none ever arrives it gives up after
`NIF_AUTOSTART_BOOT_S` (default 60s). Closing a UI that attached to a
*manually* started core changes nothing — the core stays up.
`NIF_ENSURE_ATTACH=0` makes `ensureHarness` spawn unconditionally (tests).
An explicit `NIF_NATS_URL` short-circuits the other way: the client attaches
to exactly that bus and nothing is probed or spawned. (`NIF_NATS_SPAWN=1` is
the core-side twin — an isolated core-owned bus on a random port, never
4222; see [Environment variables](#environment-variables).)

At the kernel level the same rule holds with one deliberate exception: core
itself has no parent-death signal — an autostarted core must outlive the UI
that spawned it — while every child it starts does. Supervised children
(components, session runners) are wrapped in `setpriv --pdeathsig TERM` when
util-linux's `setpriv` is on `PATH`, the SDKs set `PR_SET_PDEATHSIG` in the
components they spawn, and the bundled `nats-server` sets it in its own
`main`, so nothing survives its harness even on SIGKILL. Off Linux (or
without `setpriv`) both mechanisms are absent, which is how an orphaned bus
happens (see Troubleshooting).

## Common tasks

```bash
./var/bin/niffler             # full harness in a terminal (admin shell)
./var/bin/niffler --minimal   # store + bash + llm only at boot
niffler-ui                    # desktop UI; autostarts the full profile
make build          # rebuild what changed
make install        # PATH entries (niffler, niffler-cli, niffler-console,
                    # + niffler-tui wrapper on request — never component
                    # binaries, so PATH cannot shadow grep/git/...)
make install-tui    # same, installing the niffler-tui terminal client quietly
                    # (= make install WITH_TUI=1)
make uninstall      # remove those PATH entries again
make install-ui     # build the desktop UI, then add the launcher entry + icon
                    # (Linux; = make ui-install; -uninstall counterpart ui-uninstall)
make install-lsp    # install the lsp component's default language servers
make test           # the full gate: frontend tests + the bus-contract suite
make test-server    # the bus-contract suite alone (each test owns a private bus)
make test-ui        # frontend alone: lib unit tests + typecheck (no NATS)
make doctor         # check prerequisites
make ram            # RAM of running stacks (harness + components + nats + clients)
make down-here      # stop this checkout's harness, components and spawned bus
                    # only — bench worktrees and other clones survive
make clean          # remove all build artifacts (var/, nimcache/, UI build)
```

- **Headless service mode** (no tty, for UIs/automation):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` —
  serves `svc.core.call`; approval-requiring tools are denied unless a UI
  is attached or `NIF_AUTO_APPROVE=1`.
- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222` (even remote), or
  start your own nats-server on the default port before core — core reuses
  a live bus on `127.0.0.1:4222` and only spawns its own (the built
  `var/bin/nats-server` component) when none answers.
- **Probe the bus** without the LLM: one-shot `nim c -r` scripts in
  `tests/` (see AGENTS.md "Debugging the bus").
- **Wails**: build only with `wails build -tags webkit2_41` (Linux);
  plain `go build` produces a stub. `make dev` runs the SPA in a browser
  with the bridge stubbed.
- **Monitor RAM** of a running system with `make ram` (or
  `watch -n5 scripts/niffler-ram.sh`): totals per stack — your clone,
  `nifflerprod`, and each bench private harness separately — over harness +
  NATS + all spawned components + session runners + clients. Membership is
  by executable path (`*/var/bin/*`, `niffler-ui`), not the process tree:
  the tui is the *parent* of an autostarted harness, and a bench run's
  private bus belongs to the bench driver, so a PPID walk would miss both.
  Read PSS, not RSS: stacks sharing one `var/bin` build double-count
  file-backed pages in RSS. Workload children of the `bash` tool
  (compilers, test binaries) are excluded by design.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI shows "Running in a browser" inside the desktop app | `nats.ts` binding mismatch — `window.go.main.Bridge` must match the Go struct name (ui/README.md) |
| UI banner: bus unreachable | core autostart still in progress or failed — start `./var/bin/niffler` in a terminal to see boot errors |
| `core: WARNING missing binary for <name>` on boot | run `make build` |
| llm error HTTP 401/403 | check the active provider's key or token first (`provider_status` for a redacted view of what is in effect, `provider_list` for `expiresAt`); only with no stored provider active does `NIF_OPENAI_API_KEY` in `.env` or the shell environment decide |
| "approval denied" in headless mode | expected: no human reachable. Attach the UI, use `make run`, or set `NIF_AUTO_APPROVE=1` knowingly |
| two stores fight over the same data file (`var/store.db` or `var/barrel-db`) | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |
| boot refuses: "this harness has conversation history in var/barrel-db" | the default engine changed to SQLite and your history is still in barrel — run `niffler-store-migrate --root <path>` (the error prints it), or set `NIF_STORE_BACKEND=barrel` to keep the old engine |
| orphaned `nats-server` | a manually started `nats-server`, a non-Linux host (no PDEATHSIG to reap it), or a stale `var/nats-pid` left by SIGKILL — check the pid file (core verifies pid + comm, so a stale file is ignored), then `pkill -f nats-server` |
| component crashes on boot, restarts in a backoff loop | `core.remove` it via the UI/terminal, or `make recover` |
| agent-modified sources | `git restore components/ core/ sdk/ manifest.yaml Makefile` then `make build` (see Recovery) |
| session call fails: "session runner binary missing" | `var/bin/session` was never built — `make build` |
