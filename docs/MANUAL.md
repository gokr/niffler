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
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch) · [`grep` in detail](#grep-in-detail)
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
| `var/bin/` | built binaries (system core + session runner + components), plus everything `builder.build` compiles — agent-built components land here too, beside the system ones. Rebuilt by `make build` |
| `var/store.db` | the SQLite store's data file (default engine) — **single-writer**: exactly one `store` process may open it. Older, un-migrated harnesses still use `var/barrel-db`; a migrated root keeps that file untouched beside `var/store.db`. Each engine locks its own file — `var/store.db.lock`, `var/barrel-db.lock` |
| `var/nats-url` | bus address of the last spawned bus; the UI bridge reads it to find core |
| `var/nats-monitor-url` | HTTP monitoring endpoint when core spawned the bus; absent for reused/remote buses |
| `var/logs/`, `var/captures/` | rotating structured logs and explicit observe probe exports (see [Observation and logs](#observation-and-logs)) |
| `var/toolout/` | `bash` spill files (`<session>/<pid>-<epoch>-<counter>.out`) written when a command's output exceeds the inline cap — absolute paths that `read` can page through; swept after 1 h, so an old turn's path may be gone |
| `var/approval-sources/`, `var/mcp-results/`, `var/review-receipts/`, `var/fabric-cache/`, `var/plugins/` | approval prompt payloads, MCP bridge results, `review_receipt` fingerprints, compiled fabric programs and installed plugin clones — all disposable |
| `var/models/`, `var/processes/`, `var/repomap-tags/`, `var/fetch/` | component state: the models.dev catalog cache, background-process records, the repomap tag cache, spilled fetch bodies |
| `var/nats-pid` | pid of the bus core spawned (crash cleanup only — a live core stops its own bus on exit) |
| `var/build/` | source files of agent-built components (builder's scratch dir): one `<name>.nim` for Nim, a whole project directory for Go and TypeScript (`go.mod`, `package.json`/`tsconfig.json`, `node_modules/`, `dist/`). It is the **only** copy of an agent-built component's source — the persisted `component` record carries none, so `make clean` orphans it |
| `nimcache/` | build artifacts; `make clean` removes them (together with `var/`) |

### Shipped components

| Component | Language | Manifest | What it does |
|---|---|---|---|
| `store` | Nim/Go | required | document store over the bus (`put/get/list/del`, rev-based concurrency). All four tools are on-demand, and `del` is additionally hidden — core deletes records, the model cannot. Engines register under the same name with the same four tools (`put`/`get`/`list`/`del`; the barrel engine additionally registers a hidden `selftest` — the one `/doctor` fans out to — that the Go engines do not implement): `store-sqlite` (Go, SQLite + goose migrations, `var/store.db`) is the **default**; `barrel` (`var/bin/store`) and `tidb` remain selectable with `NIF_STORE_BACKEND` — see [Store engines](#store-engines) |
| `bash` | Nim | required | the classic tool: shell commands with timeout + output cap. Commands run as the leader of their own process group, so a timeout or a cancelled turn kills the whole tree (exit 124 / 130) — no orphaned children. Results carry `text` (an `(exit N)` status line — non-zero = failure; 124 = timeout, 130 = cancelled, 126 = cwd not enterable (the tool also uses 126 for found-but-not-executable), 127 = `bash` not on `PATH`, 128 + signal when the command killed itself (139 = SIGSEGV, 143 = SIGTERM) — followed by combined stdout/stderr; this is what the LLM transcript shows) plus machine fields `exit_code`, `cancelled`, and `spill {path, bytes, lines}` when oversized output spills to a file under `var/toolout/` (the absolute path is in `spill.path`; pageable with `read`, swept after 1 h). `run_in_background: true` hands a long-running command (server, watcher) to the `processes` component instead of blocking — see [Background processes](#background-processes-processes) |
| `repomap` | Nim | optional | ranked workspace map (docs/research/REPOMAP.md): the load-bearing files and their key definitions in ~1KB, built from a tree-sitter + native-Nim tags graph with personalized PageRank (the aider repomap port). `repo_map {workspace?, focus?, mentionedIdents?, budget?}` is onDemand and read-effect. Workspace-open auto-append (one append-only history entry on `ev.workspace.opened`) is **on by default but gated** (`docs/research/REPOMAP-GATES.md`): the workspace must have at least 50 covered files, and its rendered map must have at least 800 bytes, 25 symbols and 5 symbol-bearing files. A small/stub map is withheld and logged as `repo map withheld`; set `NIF_REPOMAP_AUTOAPPEND=0` to disable the append. The explicit `repo_map` tool is available regardless of these gates. Cache: `var/repomap-tags/` (mtime-keyed). Optional component — absent means no map, nothing else changes. Parameters, tag tiers and append payload: [`repomap` in detail](#repomap-in-detail) |
| `processes` | Nim | optional | long-running commands with an owner: `process_start` (detached, own process group, returns an id at once), `process_poll` (drains incremental output), `process_kill` (stops the group), `process_list` — see [Background processes](#background-processes-processes) |
| `builder` | Nim | required | compiles agent-written Nim/Go/TypeScript source with `build {lang, name, source, files?, defines?}`, and builds manifest-v2 plugin projects with `build_package {name, lang, sourceRoot, project, steps, artifact}` (approval-gated, on demand). Package projects keep their own dependency manifests and lockfiles; the builder stages them, expands only controlled SDK/output placeholders, executes bounded argv recipes, validates the declared `executable`/`node` artifact, and returns the published binary/runtime bundle. Recipes may combine toolchains (for example `npm ci` followed by `wails build`); recipes use a bounded argv tool set and cannot invoke a shell wrapper. `info` returns SDK paths, the global tool-naming rule, and both build flows |
| `llm` | Go | required | streaming chat adapter — three hidden tools, none of them in a conversation's direct set: `chat` (one inference, `ev.llm.token` deltas, cancellation; `runner`-exempt, timeout `NIF_LLM_TIMEOUT_MS`), `llm_resolve` (the credential-free resolution probe clients call) and `llm_models_source` (the `x-models-source` v1 live-id source the `models` catalog calls) — protocols: OpenAI-compatible Chat Completions, OpenAI Codex (ChatGPT OAuth) Responses and Anthropic Messages; `llm-openai` in `components/llm-openai` is the minimal non-streaming example (it reads only `NIF_OPENAI_API_KEY`, `NIF_OPENAI_BASE_URL`, `NIF_OPENAI_MODEL` and `NIF_OPENAI_CONTEXT` — not `NIF_OPENAI_PROVIDER` — and always sends `max_tokens: 32768`, a hardcoded value with no knob); swap it in via `manifest.yaml` — comment `llm` out in the same edit, since `chat` is a globally unique tool name and a duplicate registration is refused; `make build` builds `var/bin/llm-openai` either way. Expect nothing beyond the chat contract: no `ev.llm.token` streaming, no cancel, no `finish_reason`, no `llm_resolve` (core degrades gracefully on the last one) |
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
| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches — parameters, caps, exit codes and the effect classification are in [`grep` in detail](#grep-in-detail) |
| `systemprompt` | Nim | optional | the conversation constitution: session runners fetch the system prompt from `svc.systemprompt.call` once per conversation (see [System prompt (`systemprompt`)](#system-prompt-systemprompt)) |
| `compaction` | Nim | optional | default replaceable `compaction_propose` implementation: verifies runner-owned paged snapshots, chooses a permitted cut, and returns a structured checkpoint candidate; the runner alone validates and commits projections — the tool itself is `hidden` + `x-harness.runner: true` (read-effect, 120 s), so no model ever sees it and only a runner or another component calls it; with the component absent or killed, summarization is off and the deterministic ladder (lossless prune, then the lossy fallback rung) still runs |
| `recall` | Nim | optional | on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint — plus `mode: search`, a grep over the conversation's whole canonical history (trimmed/compacted-away messages included) |
| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) — a pure client that never publishes `reg.publish`, so it never appears in `catalog` and `cli wait cli` can never succeed |
| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |
| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring (see [Observation and logs](#observation-and-logs)) — all twelve tools are on demand and none declares `x-harness.effect`, so the fabric batch host schedules even `observe_events`/`observe_logs` as writes |
| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) — both tools are on demand and neither declares `x-harness.effect`, so the fabric batch host schedules even `logfile_search` as a write |
| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |
| `mcp` | Go | optional | external MCP servers (Model Context Protocol): store-backed registry (`mcp_servers`/`mcp_search`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`), one supervised bridge per server (the child is the separate `mcp-bridge` binary — `var/bin/mcp-bridge`, built by `make build`, path overridable with `NIF_MCP_BRIDGE_BIN`; it has no manifest entry and is never started by hand); tools become ordinary catalog tools reachable through `discover` + `invoke` (see [External MCP servers](#external-mcp-servers-mcp)) |
| `nats-server` | Go | **not in the manifest** | the bus itself as a first-class component: a faithful rebuild of the official `nats-server` main (pinned in `components/nats/go.mod`), built by `make build` into `var/bin/nats-server` and preferred by core over a PATH install, so no NATS prerequisite is needed. Deliberately *not* a bus component — core starts it before the bus exists, it registers no tools, and `core.spawn` cannot start it. Niffler adds one flag, `--max_payload <bytes>` (core passes 8388608), and on Linux it sets `PR_SET_PDEATHSIG` so no orphaned bus outlives its harness. There is nothing to install for it: `make install-nats` only says so, and `make doctor` reports `nats-server: OK` or explains that it is built from source |
| `dialog` | bash | — | demo component written entirely in bash — nats CLI + jq, no SDK, no compile step: `dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer (`dialog_show` → `{ok, shown: yes|no, via: zenity|notify|log, kind}` — `shown` is the backend's real outcome: a failed dialog or the log fallback is `no`, never a fake `yes`; `dialog_ask` → `{ok, answer: yes|no|timeout|no-display}` — `timeout` means a human had the dialog and let it lapse, `no-display` means nobody could answer). Neither tool is approval-gated or on demand, so both land in the direct toolset of every conversation started while `dialog` is up, and without a display (`DISPLAY` unset or zenity missing) `dialog_ask` answers `no-display` immediately without asking anyone. Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool). Prereqs: the nats CLI and `jq` are hard — without either the component cannot answer at all; `zenity` (or `notify-send`) only for the visible part, and only with `DISPLAY` set. `make setup` installs all three, `make doctor` checks them |

`components/ctxtest/` is the exception to one directory per component = one
shipped component: it is the contract tests' own fixture — a stub `chat` LLM
plus the nested-call probes — which the tests compile themselves into binaries
registering as `ctxtest` and `ctxsink`. It is not in this table, not in
`manifest.yaml`, and never built by `make build`.

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
approval. A qualifying workspace receives one map via append-only history
on open; smaller or stub workspaces get nothing unless the model asks.
`budget` is in tokens, 1024 by default and 4096 at most.

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
directories, and stops after 5000 files or 5 s. A single build is capped at
90 s inside the tool's 120 s envelope. A docs-only or otherwise tiny
workspace therefore maps to nothing — the append path logs
`repo map withheld`, and the tool answers `No map: …`.

**What the append injects.** One user-role message per conversation: a
bracketed preamble naming the workspace and warning that it is a snapshot
taken when the conversation started, then the map. It goes into ordinary
append-only history — the runner folds it in before the conversation's next
LLM request, never into the frozen prefix — so a later compaction may trim it
away and `repo_map` re-creates it on demand. The component publishes the
finished map to `svc.session.<id>.map` (the runner's drain subject); the
append it then makes is visible to observers as `ev.session.<id>.map
{sessionId, workspace, bytes}`.

### `grep` in detail

The `grep` row above is the summary. Both tools run ripgrep as a fixed argv —
the pattern travels as an argument after `--`, never through a shell — so
quotes, backslashes and spaces need no escaping, which is the reliability win
over `bash grep`. `rg` resolves through `PATH`; when it is missing both tools
answer exit 127 with an install hint that points at `bash grep -rn`.
`.gitignore` and hidden/binary files are skipped by default, `hidden: true`
adds hidden files while `.gitignore` still applies, and a `glob` narrows
without un-hiding. `path` is workspace-relative at dispatch, and results come
back as absolute paths.

`grep {pattern, path?, glob?, context? (≤50), case_insensitive?, hidden?,
max_results? (default 200), timeoutMs? (default 30000)}` returns `path:line:match`
lines; `files {path?, glob?, hidden?, max_results? (default 500), timeoutMs?}`
returns sorted paths. `max_results` is capped at 10000 lines and the text at
32 KB (head and tail kept, with a marker saying how much was cut), and a line
longer than 300 columns is omitted as `[Omitted long matching line]` (rg's
`--max-columns 300`). `exit_code` is the contract: 0 match, 1 none (`[no
matches]`/`[no files]`), 2 bad regex, 124 timeout, 127 rg missing. `grep`
declares `parallel: true` and `files` does not, and neither declares
`x-harness.effect` — the fabric batch host schedules both as writes. Four
stateless manifest replicas serve them through one queue group.

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
session is visible before its first message, and emits the same
`ev.session.<id>.*` events as the classic in-core loop. Sessions are ephemeral: history lives
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
refuses to boot on an unknown value. An unset `NIF_STORE_BACKEND` is a default,
not a demand: when `var/bin/store-sqlite` was never built, core warns and boots
the manifest binary (`var/bin/store`, barrel) instead. An explicit value is a
demand — a missing binary is only warned about, never silently swapped for
another engine's database.

- **sqlite** (default, `var/bin/store-sqlite`, Go): the same document
  contract on SQLite. Documents live verbatim as JSON TEXT; `put` is one
  atomic statement (doc + rev move together — the KV engine's two-key
  crash window is gone); schema via embedded goose migrations; pure-Go
  driver (`modernc.org/sqlite`, no cgo). Data file `var/store.db` (WAL),
  introspectable with any SQLite tool (`sqlite3 var/store.db 'select kind,
  count(*) from docs group by kind'`), attachable read-only from DuckDB
  for offline analytics. Default since context compaction landed: the
  context projection needs the atomic write and a range-readable list
  (docs/research/COMPACTION.md §2). The SQLite pragmas are code-resident, not
  configurable (`_txlock=immediate`, WAL, `synchronous(NORMAL)`, a 10 s
  `busy_timeout`, one pooled connection), and the goose migration is applied
  automatically at startup.
- **barrel** (`var/bin/store`): embedded BitBarrel KV (Bitcask-style) in
  `var/barrel-db` — schema-free by design, zero deps, proven. Still fully
  supported (`NIF_STORE_BACKEND=barrel`); its `put` is a two-key sequence
  (doc, then rev): a crash between them can update content without its
  revision, and for a *new* document the doc key is written with no rev key at
  all, which `get` and `list` read as absent (`rev == 0`) — the document is
  unreachable until it is written again.
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
  Works against plain MySQL 8 too. The DSN user needs the rights goose
  requires to create its version table and apply migrations; connect/read/
  write timeouts are hardcoded (5 s / 60 s / 30 s), and the engine holds a
  single pooled connection (one session, so a `FOR UPDATE` transaction's
  statements stay together) — N harnesses on one cluster hold N connections
  and share no pool.

Beyond root and engine selection the engines take no configuration: file
paths, lock paths, pragmas, timeouts and pool sizes are code-resident
(`NIF_ROOT` decides the root, `NIF_STORE_BACKEND` the engine,
`NIF_STORE_TIDB_DSN` the cluster).

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

The store contract is one test run against every engine: `make test-store`
(the selected/default engine), `make test-store-sqlite`, `make test-store-tidb`
(needs `NIF_STORE_TIDB_DSN`, otherwise it prints SKIP); `t_store_paging` pins
the `after`/`hasMore`/`nextAfter` cursor semantics that resume and migration
depend on.

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
and it never edits the source data. The store contract cannot enumerate
kinds (`list` needs one), so it reads every document **of the kinds it
probes** — a candidate list that is a verified census of every kind the
harness writes today (`agentjob`, `agentnotice`, `approval`,
`compaction_input`, `component`, `context_projection`, `contextreceipt`,
`conversation`, `fabricprog`, `mcp`, `message`, `plugin`, `profile`,
`session`, `sessionmeta`, `slash`, `spill`) — and the closing verification
walks the kinds it actually CARRIED, per kind, against the target. A kind
added to the harness later is still silently skipped until the census is
extended (the bus gives no way to see it), which is why the list is
maintained beside the store's kind table.
The direction wired up today is barrel → `sqlite` (the
default) or barrel → `tidb` with `--to tidb`; a SQLite-only root is refused
with "root already uses sqlite — nothing to migrate". Each document is
replayed into the fresh target, then verified per kind. The flags
(`--root`, `--to <engine>`, `--dry-run`, `--scan [<top>]`, `--all [<top>]`,
`--force`) are described by the tool's own `--help`; `--force` overlays an
existing target database (the old one is moved aside as
`<name>.<timestamp>.aside`) and the design behind each stage is
[research/STORE_V2.md](research/STORE_V2.md) "Moving data between engines".

`--scan` finds the top directory, sibling clones, and benchmark trees
(`var/bench/**/niffler-root`). Migration refuses to run on a root that holds both
`var/barrel-db` and `var/store.db` — the state a finished migration leaves,
where a re-run fails with "ambiguous source; move one aside first" (move the
stale `var/store.db` aside to repeat it). Rollback is simply
`NIF_STORE_BACKEND=barrel`, since the barrel file is untouched; moving data in
the other direction — out of SQLite or TiDB — is not wired up.

## State and configuration

Niffler has no single config file. State is spread across five places,
chosen by lifetime: boot decisions are environment, identity/selection is
the store, per-conversation choice is the conversation header, display is
the browser, and everything derived is `var/` (regenerable — delete it and
`make build` + a boot rebuilds the world) — **except agent-built components**:
`builder.build` keeps their source only under `var/build/` and their binary only
under `var/bin/`, and the persisted `component` record stores neither, so when
those outputs are gone while the store survives, the next boot warns `stored
component <name> has missing binary` and skips it. Rebuild it with `builder.build`
+ `core.spawn`, or drop the record with `core.remove`.

| Where | What | Lifetime |
|---|---|---|
| **Environment / `.env`** | all `NIF_*` variables (table below): boot & bus, LLM connection, per-component tuning. `.env` (root, gitignored) holds secrets and local overrides; shell env wins; reference copy with defaults in `.env.example` | process lifetime — components read env once at boot, so a change needs `core.kill` + `core.spawn`. A variable *exported in the shell that started core* is inherited by every child and needs a harness restart instead |
| **The store** (kind table in [The store](#the-store)) | conversation headers, messages, the `provider` registry (credentials included), frozen per-conversation toolsets, the slash table, plugin/component install records, subagent job/lineage records, fabric programs, MCP server configs | durable — the harness's database |
| **Conversation header** (`conversation` kind) | per-conversation choice: model, modelOverride, thinking, profile, title, budgets/token meters — set through the `session` call (`/model`, `/effort` in UIs) and echoed in turn results | per conversation |
| **Home / project files** | skills trees (project `.agents|.claude|.opencode/skills` > bundled `skills/` > home `~/.niffler/skills` + agent-standard dirs > `~/.config/opencode/skills`, then the tree compiled into the binary as the last resort); LSP registry `~/.config/niffler-lsp/servers.json` (`NIF_LSP_REGISTRY`) | durable, user-editable |
| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json` (else `~/.config/niffler-edit/undo.json`): last pre-edit bytes per file plus per-conversation seen-state digests. One record per edited file, no size cap and no eviction — it grows with the number of distinct files edited, and is safe to delete at any time (deleting it loses only undo history and unchanged-read stubs, never file content) | durable, user-editable |
| **`var/`** (gitignored) | `bin/` built binaries, `logs/` bus JSONL and per-component JSONL (`.1`…`.N` rotations) plus child logs, `models/` catalog cache, `nats-url`/`nats-pid` bus claiming, `processes/` spools (`pN.out`/`pN.err` per start, wiped at boot; ids continue from the persisted counter instead of restarting at `p1`), `repomap-tags/` per-file tags cache (`{mtime, tags}` JSON keyed by the sha1 of the absolute path; empty results are never cached), `fetch/`, `captures/`, `store.db` (the SQLite engine's file) or `barrel-db` (the barrel engine's) — whichever `NIF_STORE_BACKEND` selected — plus its `.lock`, which exactly one `store` process may hold at a time | runtime, regenerable |
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
env always wins — see below) and inherit core's environment. `NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs (`NIF_NATS_CLI` is the exception — the spawned bash component `dialog` reads it as its last-resort nats CLI): they steer `make` and `scripts/` and are never consulted by a shipped component — the test-only `ctxtest` fixture reads `NIF_REPO_ROOT` to load the fabric examples — so they are not part of the runtime table below. `NIF_LSP_BIN` still has a row there: it is the `make install-lsp` target directory, whose default (`~/.local/bin`) the `lsp` component also searches. The full set:

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | the harness root (repo). Core derives it from its binary location if unset, and sets it for all children. Components use it to find the SDK, `var/`, `.env`. Every component runs with **cwd = NIF_ROOT**, so the agent's `bash pwd` is always the home — regardless of where you launched the harness | `<binary location>/../..` |
| `NIF_NATS_URL` | bus address. In the **environment** (tests, bench, scripts): attach-only — core uses exactly that bus. Declared in **`.env`** (or the well-known `nats://127.0.0.1:4222`): the clone's **home bus** — claimed when free, attached to only when the answering core serves this root (identity via the catalog's `root` field), yielded loudly to a foreign core or bare nats-server (isolated random bus instead; a recorded leftover `var/nats-pid` is reclaimed first), and written to `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` forces an isolated core-owned bus on a random port — never 4222, never attaches (dev clones and tests). With an explicit `NIF_NATS_URL` the URL wins | unset |
| `NIF_AUTOSTART` | set by an SDK's `ensureHarness` when a UI had to spawn core: that core exits when the last interactive client departs (see Starting and stopping) | unset |
| `NIF_AUTOSTART_IDLE_S` | seconds after the last interactive departure before an autostarted core exits | `10` |
| `NIF_AUTOSTART_BOOT_S` | seconds an autostarted core waits for its first interactive client before giving up | `60` |
| `NIF_ENSURE_ATTACH` | `0` makes `ensureHarness` skip attaching and always spawn a core (tests) | `1` |
| `NIF_STORE_BACKEND` | store engine selected at boot: `sqlite` (default → `var/bin/store-sqlite`), `barrel` (→ `var/bin/store`), `tidb` (→ `var/bin/store-tidb`); anything else refuses to boot. All engines register as component `store` with identical tools — see [Store engines](#store-engines). An un-migrated barrel (history in `var/barrel-db`, no `var/store.db` yet) makes core refuse to boot with the `niffler-store-migrate` instructions; `barrel` here is the escape hatch. An **unset** value whose engine binary is missing (`var/bin/store-sqlite` absent) warns and falls back to `var/bin/store` — an explicit request never falls back | `sqlite` |
| `NIF_STORE_TIDB_DSN` | TiDB/MySQL DSN for the `tidb` store engine, e.g. `root@tcp(127.0.0.1:4000)/niffler` (docker single-node: `docker run -p 4000:4000 pingcap/tidb`). Required for that engine — no local default; the component refuses to boot without it. Sessions are forced to UTC unless the DSN sets `time_zone`. The account needs rights for goose's DDL migrations, applied at every boot (a fresh database, then each new migration as it ships); the connect/read/write timeouts (5 s/60 s/30 s) and the single pooled connection are code-resident, not env-tunable | unset |
| `NIF_GIT_MIRROR` | host prefix replacing `https://github.com` when the `plugins` component clones packages (e.g. `https://cnb.cool` or a Gitee mirror) — API/search endpoints stay on GitHub | unset |
| `NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default |
| `NIF_OPENAI_API_KEY` | API key for the LLM adapter (`llm`). Required for any conversation turn; with no key at all the adapter refuses before any HTTP request (`provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`), which is a different symptom from a key that exists but is rejected (HTTP 401/403) | — |
| `NIF_OPENAI_BASE_URL` | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | model name | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | models catalog provider id for the default LLM connection; common endpoints are inferred when unset | inferred |
| `NIF_OPENAI_CONTEXT` | explicit context window (tokens) the llm reports to core's context guard. Resolution order: stored provider `context` → this → `models` catalog → `llm`'s built-in table (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288 — code-resident, so a new model needs a source change) → 128000 (the `llm-openai` swap-in example resolves only `NIF_OPENAI_CONTEXT` → a two-entry `deepseek-chat`/`deepseek-reasoner` table → `128000`, and re-reads the variable on every call) | `models` catalog, then the built-in table, then `128000` |
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
| `NIF_LLM_MAX_RETRIES` | additional attempts for transient LLM failures (429/5xx/overloaded/connection drop) with exponential backoff; each retry announces `ev.session.<id>.retry`. Auth/quota/bad-request errors always fail fast | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | additional attempts when a streamed response drops mid-flight — budgeted separately from the general case because a dropped stream may already have billed output | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | additional attempts for connect/dial failures | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | upper bound honored from a server `retry-after` hint: `llm` wraps the HTTP client, parses `Retry-After` (seconds or an HTTP date) and appends `; retry-after-ms: <n>` to the provider's error so core can honor the wait without every adapter depending on the same client library; a hinted wait longer than this cap is clamped, and an invalid or absent header leaves the error untouched | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | ceiling for one `llm` `chat` completion; slow reasoning models (e.g. GLM thinking=max via llmgateway) can exceed the default on a single response | `300000` |
| `NIF_CTX_RESERVE` | output tokens held back by context admission; defaults to the model's resolved catalog output cap, `16384` when unknown; `0` disables the reserve | catalog output cap |
| `NIF_COMPACTION_TOOL` | contract-v1 candidate tool selected by the runner; empty disables summarization but not prune/trim/error admission | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | whole candidate-call deadline, clamped to 5000–600000 ms; the runner passes it as the dispatch bound (`budget.timeoutMs`) and the candidate tool's own `x-harness.timeoutMs` is the same 600000 ceiling, so a configuration up to the clamp is what the runner actually waits for (a value above the clamp still only extends the component's auxiliary-call deadline — the runner gives up first and the snapshot waits for the 600 s sweep) | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | auxiliary summarization call budget granted to one attempt, clamped to 1–16; a candidate reporting more calls than granted is rejected as invalid, and the granted count scales the request's `maxTotalInputTokens`/`maxTotalOutputTokens`. The shipped `compaction` component always makes exactly one auxiliary call and reports `llmCalls: 1` — the budget is for a summarizer that iterates | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | per-call checkpoint output cap, clamped to 128–32768 and floored at 128 by the shipped component | `4096` |
| `NIF_OBSERVE_RING` | messages retained in observe's global ring; accepted range 1–10000, outside it the component exits non-zero | `2000` |
| `NIF_OBSERVE_RING_BYTES` | approximate wire bytes retained in the global ring; accepted range 65536–104857600 | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | maximum retained bytes per observed message; accepted range 1024–1048576, and a larger message is kept as a base64 preview of three quarters of the cap | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | active + stopped probes retained at once; accepted range 1–256, and at the bound the next `observe_listen`/`observe_trace` fails with `probe limit reached` | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | retained bytes per probe; accepted range 65536–16777216, entries are evicted oldest-first and a single entry above the cap is counted in `dropped` | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | confined directory for `observe_dump` | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | aggregate generated-capture quota; oldest files are pruned. Accepted range 65536–1073741824, and when even pruning cannot fit a dump the tool fails with `capture directory quota is exhausted` | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | explicit nats-server HTTP endpoint for an external/reused bus | core discovery file |
| `NIF_LOGFILE_DIR` | JSONL output directory — an absolute path is used as-is, a relative one resolves against the harness root | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist, validated at boot: a malformed or over-512-byte pattern, more than 64 unique patterns, or an empty list makes the component exit non-zero | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation; accepted range 256–104857600, outside it the component exits non-zero | `10485760` |
| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables); accepted range 0–100, and generations above the value are deleted at every boot | `5` |
| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl`; accepted range 1–1024, and JSONL files already present at boot count toward it | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search`, accepted range 1024–104857600 and shared across all files of that search | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query; accepted range 100–100000, applies to `logfile_paths` too, and the truncation is reported as `directoryTruncated` | `10000` |
| `NIF_AUTO_APPROVE` | `1` → the approval gate (below) is bypassed, and every `/limit` keep-going question is answered with yes (it implies `NIF_AUTO_CONTINUE`). For headless automation only; never set it in a session you care about | unset |
| `NIF_AUTO_CONTINUE` | `1` → a turn that reaches one of the conversation's soft limits (`/limit`) keeps going without asking (`NIF_AUTO_APPROVE=1` implies it). For headless automation only | unset |
| `NIF_MAX_TURN_ROUNDS` | hard LLM-round ceiling per turn; an explicit per-session `maxRounds` may narrow it | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | estimated-token cap on a conversation's direct toolset for `invoke {sticky: true}` promotion; a promotion that would exceed it is deferred and reported in the tool result | `4000` |
| `NIF_PROFILE` | default named tool profile for new conversations, used when the `session` call carries no `profile` argument | unset |
| `NIF_AGENT_MAX_DEPTH` | caps how deep `agent_spawn` delegation may nest (core enforces at dispatch; the agent component mirrors it). `0` forbids delegation; spawn tools stay visible at the cap | `1` |
| `NIF_HOOKS_EVENTS` | comma-separated bus subjects the hooks component watches, with NATS wildcards (`*` one token, a trailing `>` the rest). Read at boot — a config change is `core.kill` + `core.spawn` | `ev.session.*.turn` |
| `NIF_HOOKS_<SUBJECT>` | the shell command run for one watched subject (dots and wildcards become `_`, with `*.` and `>.` collapsing: `ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` → `NIF_HOOKS_EV_LOG__`); event payload piped to stdin as JSON | unset |
| `NIF_HOOKS_TIMEOUT_MS` | per-hook timeout, clamped to 100–60000 ms; a timeout kills the hook and logs exit 124 | `10000` |
| `NIF_MCP_REGISTRY_URL` | base URL of the external-MCP server catalog (air-gapped/proxied setups) | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | timeout for one real-connect probe in `mcp_add`/`mcp_edit` (the bridge's own `--probe` mode reads it too, so a hand-run probe honours it): when set (positive) it wins over both the 30 s default and the server's own `timeoutMs` | `30000` |
| `NIF_READ_OUTLINE_LINES` | whole-read line threshold above which read returns a language-server symbol outline instead of the raw window; `0` disables the outline | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | Workspace-open repo-map auto-append is on by default, still subject to the census/content admission gates (`docs/research/REPOMAP-GATES.md`). `0` opts out; `1` explicitly opts in. The `repo_map` onDemand tool is unaffected | `1` |
| `NIF_REPOMAP_MIN_CENSUS` | census-file floor for the append: a workspace with fewer covered source files is never mapped (docs/research/REPOMAP-GATES.md). The gates are append-only — `repo_map` is never gated, a small map is a fine answer to an explicit question | `50` |
| `NIF_REPOMAP_MIN_BYTES` | append content gate: a rendered map below this many bytes is a stub and is withheld. The gates are append-only — `repo_map` is never gated | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | append content gate: rendered symbol-row minimum. The gates are append-only — `repo_map` is never gated | `25` |
| `NIF_REPOMAP_MIN_FILES` | append content gate: symbol-bearing file minimum. The gates are append-only — `repo_map` is never gated | `5` |
| `NIF_RUNNER_IDLE_S` | a session runner with no session call for this long retires; the next call spawns a fresh one (subagent children re-ensure on demand) | `600` |
| `NIF_WRITE_MAX_BYTES` | cap for the `write` tool's whole-file payload | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | host for the local OAuth callback listener (ports stay fixed at 1455/53692) | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core's child-log retention cap in `var/logs` (MB) | `200` |
| `NIF_LOG_RETENTION_DAYS` | days core retains child logs before sweeping | `7` |
| `NIF_SPAWN_WAIT_MS` | how long `core.spawn` waits for the new component to register in the catalog before failing the call (clamped 250–120000); the wait ends early when the catalog records a refusal, so the knob only bounds a silent component | `5000` |

**Build and script knobs** — read by the scripts around the harness, never by
components: `NIF_BIN_DIR` (bin directory `scripts/install.sh` links the PATH
entries into), `NIF_BUILD_LOCK` (lock file `scripts/with-build-lock.sh` flocks —
exclusive for builds, shared for test runs), `NIF_NATS_CLI` (the nats CLI
`components/dialog/dialog.sh` drives — the one entry here a component does
read: it is consulted only when `nats` is neither on `PATH` nor in
`$HOME/go/bin`), `NIF_CONF_KEEP`, plus the test helpers `NIF_STORE_BIN` and
`NIF_REPO_ROOT`. `NIF_LSP_BIN` and `NIF_LSP_BIN_DIRS` are runtime variables and
stay in the table above. The lock only covers `make`: `builder.build` runs
outside it, so a runtime component build can race `make build` — and `make clean`
deletes `var/bin` and `var/build` under it. Stop the harness while an agent is
building a component.

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
ev.session.<id>.turn        {sessionId, turnId, phase: start|done, content?, error?}
                       #   per-conversation event namespace: a client watching
                       #   one conversation subscribes ev.session.<id>.>, an
                       #   observer subscribes ev.session.> for everything
                       #   (ev.session.*.token for every token stream)
ev.session.<id>.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.<id>.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.<id>.token       {sessionId, turnId?, content, reasoning}  (live token deltas)
ev.session.<id>.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.<id>.advice      {sessionId, turnId?, source, content, reason} an advisory was
                             folded in (`reason` is the judge's one-line justification)
ev.session.<id>.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                             status?} runtime machinery was folded in (subagent
                             settlement, background process exit, autonomous wake);
                             `content` is the rendered text UIs show
ev.session.<id>.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.<id>.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
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
active turn as `ev.session.<id>.token` → the UI appends them to the live
assistant bubble. A delta frame is published only for a call that carries a
non-empty `sessionId` **and** leaves `emitTokens` on — auxiliary callers
stream internally for cancellation but keep their partial output out of the
conversation (compaction passes `emitTokens: false`; the expert judge's call is
not even streamed, so nothing is emitted either way) — and one frame is emitted
per stream chunk that has content or reasoning. The `purpose` argument those
callers send is telemetry only (provider, model, effort, ttft and tok/s are
logged with it) and never changes provider behavior. The final
`ev.session.<id>.assistant` event always carries
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
everything and renders the wire traffic readably: calls with subject + tool +
args, results, errors, events, approvals. Two limits are worth knowing: a
bare `reg.publish`/`reg.depart` payload prints as an empty-bodied
`event <subject>` line (use `observe_subjects` or `catalog` to see which
component came up), and every SDK result prints with an empty tool name —
correlate it with the call line above. It is how you follow a live install
or a stuck-tool call:

When the bus dies, console goes quiet for the nats client's reconnect budget
(tens of seconds to ~4 minutes), then prints its `console: bus connection
lost` line and retries every 2 s, re-reading `var/nats-url` each time — a
harness that restarts on a new random port is picked up automatically.

```bash
./var/bin/console    # in a separate terminal while the harness runs
```

It has no options: it renders every envelope on the bus, one line per message,
with call args and errors truncated to 300 characters, results and event
payloads to 500 and assistant text to 2000 — colors only on a tty. For a
bounded, filterable, persistent view use `observe`/`logfile`.

**The cli component** (`./var/bin/cli`) drives the same bus from a
script or pipeline — non-interactive, CI-friendly (exit 0 on success, 1 on
failure, 2 on a usage error or bad JSON);
it is the scripting face, the tty admin shell is the interactive one:

```bash
./var/bin/cli catalog                        # components + their tools
./var/bin/cli wait <component> [secs]        # wait for registration
./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
```

`catalog` prints a leading `# harness: <root> @ <gitHash>` line naming which
clone's core answered, then one `component: tool, tool` line per component
(unordered); it exits 1 when core does not answer or the catalog is empty.
`cli install` clones, builds via the builder, spawns every component and
waits for each service name to appear in core's accepted catalog; interactive
components are verified by their build. `wait <component> [secs]` polls core's
accepted catalog (default 60 s; `0` performs a single read). CLI catalog and tool
lookup also use core's
authoritative directory, never raw registration broadcasts. A plugin repo's CI
proves a package by running the harness itself through this one command. `file://` repo URLs
install from local git repos (hermetic tests, mirrors). `call` first waits up to
60 s for core to accept the tool, then waits `--timeout=<secs>` (default 30 s)
for the reply — the cli's own budget, never the tool's `x-harness.timeoutMs`, so
slow tools need an explicit extension (`cli --timeout=600 call build …`).
Name-based verification
does not distinguish an existing accepted component from a newly started
process with the same name.

It is a plain bus client: `cli call` dispatches straight to
`svc.<component>.call` (only the catalog read goes through core), so its calls
bypass the approval gate, the workspace and session injection, a tool's
`x-harness.timeoutMs` and the hidden/on-demand filter — `cli call del …` and
`cli call chat …` work. Treat it as an operator tool: give it the trust you
give the shell you started the harness from.

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
- The gate lives in core's dispatcher, so it protects core-mediated
  callers only: the model, and anything that comes through `svc.core.call`.
  A caller that reaches a component directly runs an `approval: "always"`
  tool unasked — the `plugins` install path calls `svc.builder.call`
  itself (its own `plugin_install` call is what carries the approval), and
  `./var/bin/cli`, `dialog` or a test publishing to `svc.<component>.call`
  never enters that gate. Treat such a caller as the trust level of the
  shell that started the harness.

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
usual `ev.session.<id>.context {reason: "reset:compact"}`. No LLM turn runs and no
user message is appended. The commit zeroes the measured prompt size (this
projection has not been through a provider yet), so the manual path also
publishes a status frame — `usedTokens` is the local estimate, `estimated:
true`, plus the window — or the context gauge would keep showing the
pre-compaction number until the next turn measured it. The next request's
measured usage replaces the estimate. The auxiliary summary inherits the conversation's
resolved provider/model; it does not silently follow a later global-provider
switch. The reply reports `compacted: true` with `beforeTokens`, `afterTokens`
and `generation`, or `compacted: false` with the precise decline/failure
reason (for example `no permitted cut exists yet`, `input-budget-exceeded`,
`summary-output-truncated`, an invalid candidate detail, or an unavailable
compactor). A decline never silently falls back to lossy trim.

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
- Core emits `ev.session.<id>.status` with the resolved provider/model/context and
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
  (`ev.session.<id>.context {reason: "warn:threshold"}`); at it — never later
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
  guard. The value is a **tool name**, not a component name: the runner resolves
  it in the catalog and dispatches to whichever component registered it, so a
  replacement can live in any component. An empty or unregistered value skips
  the rung in the automatic ladder and makes `/compact` answer `compacted:
  false` with `reason: "no compaction component available
  (NIF_COMPACTION_TOOL=<value>)"`. `NIF_COMPACTION_TIMEOUT_MS`, `NIF_COMPACTION_MAX_LLM_CALLS`, and
  `NIF_COMPACTION_MAX_SUMMARY_TOKENS` bound each attempt. The seam is a
  versioned contract: a candidate tool is called with `{version: 1, sessionId,
  attemptId, trigger, snapshot: {ref, generation, canonicalHigh, digest},
  budget: {…}}` and answers either `{version: 1, status: "declined", attemptId,
  reason}` with one of the three stable reasons (`no-useful-cut`,
  `input-budget-exceeded`, `indivisible`), or `{version: 1, status:
  "candidate", attemptId, baseGeneration, snapshotDigest, cutBefore, covered,
  checkpoint, provenance: {model, llmCalls}}`, where `checkpoint` carries
  exactly `objective`, `constraints`, `decisions`, `completedWork`,
  `currentBlocker`, `nextSteps` and optional `files`. Anything else is rejected
  as invalid and falls through to trim — as is a `provenance.llmCalls` above the
  granted `NIF_COMPACTION_MAX_LLM_CALLS`, and a component that finds the
  request's `attemptId`, `digest` or `generation` disagreeing with the snapshot
  it reads refuses the call with `stale-snapshot`. The runner writes a
  temporary paged `compaction_input` snapshot, validates the candidate's
  generation/digest/cut/schema/size, re-hashes the covered nodes against the
  snapshot, and measures strict reduction itself (the rendered checkpoint's
  estimated tokens must be below the covered span's), then commits one
  `context_projection` document with optimistic `expectRev`. Snapshot pages are
  512000 bytes, so one huge message cannot oversize a bus message; the
  checkpoint is bounded (objective and list items ≤ 4000 characters, ≤ 32 items
  per list, ≤ 64 files, ≤ 65536 bytes encoded) and is rendered by the
  runner-owned `checkpoint-v1` template, so a checkpoint stored by one compactor
  reloads identically under another. The component
  never writes conversation or projection records.
- A successful projection emits `reason: "reset:compact"`; model-free pruning
  emits `reset:prune`; lossy fallback emits `reset:trim`. `reset:tools` remains
  reserved for an actual sticky tool-schema promotion. These are the only
  intentional prompt-prefix rebuilds and make cache misses attributable. The
  compaction rung also reports non-reset reasons, which never rebuild the prefix:
  `compact:failed` (dispatch error or timeout), `compact:declined` (with
  `detail` = the stable decline reason), `compact:invalid` (schema, bounds,
  claimed-call-budget or strict-reduction failure) and `compact:stale` (the
  covered span changed under the attempt); the successful `reset:compact` event
  carries `generation`, `covered`, `beforeTokens` and `afterTokens`.
- Canonical `message` documents are immutable and append-only. Prune and
  compaction change only the provider projection; a restarted runner validates
  and reloads the durable checkpoint plus retained canonical tail, while
  `context_recall` resolves canonical/spill/current-checkpoint refs; a
  `checkpoint` ref returns the projection's structured checkpoint plus its
  `generation` (not paged text), ignores `mode`/`offset`/`limit`, and is refused
  when it names a superseded generation — that state has been absorbed into the
  current checkpoint, which is the one to read — and its
  `mode: search` greps the conversation's whole canonical `message` history —
  every message, including the span a trim or compaction dropped, where no notice
  names individual refs (search reads `message` documents only; spill bodies and
  checkpoints are never searched, their refs resolve them). Missing or
  corrupt projection refs fail explicitly instead of silently replaying an
  oversized span.
- `context_recall {ref?, mode?, query?, session?, role?, offset?, limit?}` is
  the resolver behind those notices: `ref` is one `{source, id}` object or an
  array of them (`source` is `canonical`, `spill` or `checkpoint`), `mode: full`
  (the default) pages one document with `offset`/`limit` under a 256 KB
  per-document ceiling, `mode: match` greps one document's lines — bounded
  by `limit` lines only, with no byte ceiling, so a query matching one
  enormous single-line result returns that line whole — and
  `mode: search` greps the conversation for messages mentioning `query`
  (`role` filters them; `session` picks the conversation to search — a
  session-leased call may name only ITS OWN conversation, so a runner call
  cannot read another conversation's history, while direct bus callers
  keep unrestricted access) and returns bounded one-line hits whose `id`
  can then be read back as a `canonical`
  ref. Defaults: 2000 lines, 50 matches, 20 hits; the tool is on demand and
  read-effect, and it is `runner`-exempt so subagents can always reach it.
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
  `context_recall`, and the omission notice is DURABLE: a resumed runner
  rebuilds the trimmed projection from `trimThrough` and re-inserts the
  notice (range-honest — it names the canonical span below the first kept
  seq, not the live run's exact `coveredFrom`/`coveredTo` pair), so a
  restart keeps a visible pointer to what the projection dropped. `mode:
  search` is the way back into trimmed history — the notice carries no
  recall ref, because a whole-turn drop covers many messages.

- The prune step is byte-exact and model-free: a tool result over 8192 bytes is
  rewritten as its first 4096 bytes, an `[tool result middle pruned: N bytes
  omitted — recall the original with context_recall {"ref": {"source": "spill",
  "id": "<convId>:<seq>"}}]` marker, and its last 1024 bytes — never twice,
  and never when the result would not shrink. The marker's `source` is `spill`
  exactly when the result was spill-backed and the promoted document
  re-verified, else `canonical`, and its `id` is the canonical seqNo the notice
  quotes, so it can be passed straight back to `context_recall`. Those three
  numbers are constants, not configuration. `context_recall` itself is on
  demand, not hidden: `discover` lists it, `invoke` accepts it and a bare name
  still dispatches, but a conversation frozen with a `tools` allowlist refuses
  it like any tool outside that list — the one case where a prune or spill
  notice's instruction cannot be followed.

## Self-extension and component lifecycle

The agent adds capabilities at runtime, mid-conversation:

1. writes a component source (Nim: `import niffler/sdk`, typed tool
   pattern; Go: `import sdk "niffler.dev/sdk"`; TypeScript: the `sdk/ts`
   package — see the system prompt). A TypeScript build needs `node` and `npm`
   on PATH (a missing one refuses with `node and npm are required on PATH for
   ts components`), generates `package.json`/`tsconfig.json` around a `file:`
   dependency on `<root>/sdk/ts`, and its `var/bin/<name>` is a node wrapper
   that `require`s `var/build/<name>/dist/main.js` by absolute path — copying
   that "binary" elsewhere, or deleting `var/build/`, breaks the component with
   no error message explaining why
2. `build {lang, name, source, files?, defines?}` (the `builder` component)
   compiles it into `var/bin/` (`files` adds further Go sources, `defines`
   passes compiler defines). Check its result instead of assuming the binary
   exists: `{ok, lang, name, binary, log}` on success, `{ok: false, lang,
   error}` on failure, where `error` is the compiler's own output tail (2000
   bytes). No exit code is reported, so a build killed at its internal budget
   (Nim, Go and `npm install` 300 s, `tsc` 120 s) reads exactly like a
   compile error with whatever output it had produced
3. `spawn {name, binary, replicas?}` (core) starts it; it registers itself;
   new conversations expose its tools directly (when not on demand), existing
   ones reach them via `discover` + `invoke` (see [Progressive tool discovery](#progressive-tool-discovery)).
   `spawn` reports ok only once that registration landed in the catalog: a
   refused registration (the catalog's reason) or a silent component past
   `NIF_SPAWN_WAIT_MS` fails the call with the reason and a bounded tail of
   the child's log, and rolls the attempt back — replicas stopped, nothing
   persisted — so the name is free for an immediate corrected re-spawn. A
   component that registered but whose store record could not be written
   (store down) also fails, with `registered: true`: it runs now and is gone
   after the next boot, which is not a plain success
4. `kill {name}` stops every replica temporarily (restored on next boot);
   `remove {name}` stops the group and deletes its persisted record. A runner
   is killed the same way (`kill {name: "session-<id>"}`) but comes back on
   the next session call, not on the next boot. A rebuild does not reach a
   running process — the old binary keeps executing — so picking up new code
   is `kill` then `spawn`; before that, `spawn` answers `component already
   supervised: <name>`

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
hint: a tool that declares `parallel: true` may be dispatched
concurrently with other parallel-marked tools in the same assistant
message (`grep` and `read` do; `files`, though read-only, does not, so
an `invoke`d `files` serializes).

**Restart policy**: every supervised child carries one — `never` or
`on-failure` (the default; a restarted child is tried after 1 s, doubling per
consecutive crash, capped at 8 s). The manifest sets it per component
(`manifest.yaml`), `spawn` always uses `on-failure`, and session runners are
always `never`.

**Persistence of shape**: spawned components are recorded in the store
(kind `component`) and restored on normal boot. A stored record whose name is
also declared in `manifest.yaml` is skipped on restore — the shipped definition
wins, silently — so replacing a shipped component means editing the manifest; a
`kill` + `spawn` under the same name holds only for the current boot. `--minimal` leaves those
records untouched but does not restore them. `core` itself, the bus, the
catalog and the supervisor are not removable — that asymmetry is the
architecture (ARCHITECTURE.md).

## Component ecosystem (`plugins`)

The `plugins` component is the ecosystem front door — community component
packages are plain GitHub repos with a `niffler.json` manifest at the root
(one repo = one package = N components). Manifest v1 keeps the compact
`{name, components: [{name, lang, main, sources?, env?, defines?, interactive?}]}`
form. Manifest v2 uses `{manifestVersion: 2, components: [{name, lang,
project, build: {steps: [[argv...]], artifact: {path, runner}}}]}`: the
package owns `package.json`/lockfiles, `go.mod`/`go.sum`, or Nimble files;
Niffler only supplies the SDK placeholders and builder seam. `lang` is
metadata for the Nim, Go, or TypeScript SDK; recipes may combine external
package tools (for example a Go/Wails client uses npm and wails). The builder
rejects unsupported commands and shell-wrapper steps, while project/artifact
paths must stay inside the clone, and
a manifest that declares no components is rejected. Repos tagged with the GitHub
topic `niffler-component` are discoverable without any registry:

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub topic search; returns repo, description, stars, plus the winning `query` and per-attempt diagnostics — GitHub ANDs the words, so a zero-hit query is retried with fewer of them |
| `plugin_installed` | the packages installed on this harness |
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`, build each component via the builder (`build` for v1, `build_package` for v2), then `spawn` each service component (approved). Installing a package that already has a record is an error, not a re-install — use `plugin_update`, or `plugin_remove` first; the clone is shallow (`--depth 1`) and v1 Go packages carry an untracked `go.work` for manual builds |
| `plugin_update {package}` | to the latest release tag: remove, reinstall at the new ref; a package with no releases (tracking a branch) is pulled in place (`git pull --ff-only` of the existing clone) and rebuilt when the pull moves HEAD or the installed artifacts are stale/missing |
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
  `"sources": ["component/helper.go", ...]`; these must be non-symlink `.go`
  files **in the same directory as `main`** (the plugins manifest reader refuses
  a path in a subdirectory, and only the basename reaches the builder), at most
  64 files and 2 MB in total, and the builder compiles them with `main` as one
  package. A `sources` key on a Nim or TS entry is refused when the manifest is
  read.
- Manifest-v2 packages declare dependencies in their own ecosystem files:
  TypeScript uses `package.json`/`package-lock.json`, Go uses `go.mod`/`go.sum`,
  and Nim uses `.nimble`/lockfiles. The recipe runs from the declared project
  directory, so `npm ci`/`npm run build`, `go mod download`/`go build`,
  `nimble install`/`nim c`, or `npm ci` followed by `wails build` all use the
  package's normal dependency semantics. A Wails desktop client is a Go
  component with an `executable` artifact and may be marked `interactive`.
  `${NIF_SDK_ROOT}`, `${NIF_SDK_GO}`, `${NIF_SDK_TS}`, `${NIF_PROJECT}` and
  `${NIF_OUTPUT}` are the only builder substitutions. Steps are argv arrays,
  not shell strings, and the builder rejects traversal, symlinked inputs,
  oversized projects, unsafe runners, and undeclared artifacts.
- A component manifest entry with `"interactive": true` is built into
  `var/bin` but is not passed to `core.spawn`. It is a terminal client (for
  example a TUI) that the user starts manually, so it is not supervised or
  restarted on boot. Stop any running client manually before removing or
  updating its package.
- A manifest entry may carry `defines` (an array of `-d:`-style prepends) and
  `env` (an array of `NAME=value` strings). Both are passed through — `defines`
  to the builder (Nim only: a Go or TS build accepts and silently ignores
  them), `env` to the spawn — so a package can carry its own configuration
  without editing the manifest.
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
are surfaced as a retryable stream error, not as a reply. An adapter that never
reports `finish_reason` loses both signals — no truncation warning, and an empty
completion cut at the cap retried as an ordinary empty reply instead of ending
the turn with `the provider cut the reply at the output cap before any
content`; the `llm-openai` example returns none.

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
(docs/research/CODEWHALE.md). A hook is a plain process: the event **payload** is piped to the command's
stdin as pretty JSON — the envelope is stripped, and a message that is not
an envelope passes through as raw bytes, so the hook reads the payload's
fields at the top level (`jq -r .msg`, never `jq -r .payload.msg`) —
written to a temp file (`getTempDir()/niffler-hook-<pid>-<n>.json`, default
permissions: treat it like a capture directory) and `cat` into the hook,
never interpolated into the command line — failures and timeouts (default
10s, max 60s) are logged and never fatal, and a payload is capped at 256 KB
with a truncation marker appended. There is deliberately no steering/veto:
approval decisions live in core's dispatch gate. It registers no tools at
all — the interface is the environment and the bus — and with no matching
`NIF_HOOKS_<SUBJECT>` set it logs `watching nothing, staying up` and keeps
running.

Configuration is env-based, read at boot (a `.env` change applies to the
respawned component; a variable exported in core's shell needs a harness
restart):

```bash
NIF_HOOKS_EVENTS="ev.session.*.turn,ev.log.error"   # subjects to watch
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

Wildcards follow NATS: `*` matches exactly one subject token and a trailing
`>` matches the rest, so `ev.session.*.turn` fires for every conversation's
finished turn and `ev.log.>` for every log event (the session id rides the
subject and the payload). Overlapping specs are safe: a message that
satisfies two of them still runs the first matching command **once** — the
component dedupes per delivered message (a 256-entry ring keyed by envelope
id and command), so the list need not be disjoint.

Subject → env name: dots and wildcards become `_`, uppercased, with `*.`
and `>.` collapsing so the canonical names survive
(`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`); a wildcard that ends
the spec contributes its own underscore, so `ev.log.>` and `ev.log.*` are
both `NIF_HOOKS_EV_LOG__`. Worked examples —
desktop notification, sound alert, email, webhook, error tail — live in
`components/hooks/README.md`. The events worth
watching are `ev.session.<id>.turn` (turn boundaries), `ev.session.<id>.done`
(carries `reply`), `ev.session.<id>.status` (per LLM round),
`ev.session.<id>.context` (warn/trim/reset) and `ev.log.<component>`; their
payload fields are listed under [The bus in one screen](#the-bus-in-one-screen). Matching is first-match-wins over the
comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at
boot is ignored — the component logs `watching …` only for the hooks it will
run.

A **failing** hook's combined output is echoed to the component's stderr
and lands in `var/logs/hooks.log` (the supervisor redirects child output
there); a hook that exits 0 has its output discarded. Neither path writes
into logfile's JSONL, which persists bus traffic only.

`make test-hooks` (`tests/t_hooks.nim`) is the smoke test: it boots the
component with `NIF_HOOKS_EV_SESSION_TURN`, publishes an
`ev.session.<id>.turn` and checks that the decoded payload reached the hook's
stdin.

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

**The edit tool's automatic push is never silent for a known language.**
After every successful edit it queues diagnostics asynchronously — the check
runs in the lsp component's idle seam and the verdict is delivered on the
conversation's `.diag` lane — and the edit result names that lane, so
"checked and clean" can never look like "nothing happened". When the check
cannot be queued (a file outside the conversation workspace, or a failure to
reach the lsp component) the edit result says so instead, with the reason.
Silence is reserved for files whose extension no registry entry claims: a
`.md` file is nobody's language-server business.

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
| `process_start {command, label?, workdir?}` | Spawn the command detached (own process group, stdin from /dev/null, stdout/stderr appended to spool files under `var/processes/`) and return its id immediately. Approval-gated. A background start through the `bash` tool's `run_in_background` is approved once, on the `bash` call itself — the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` issued through core (the model, or any tool reached via `svc.core.call`) is gated — a bus client that addresses `svc.processes.call` itself (the `cli`, a script) is not gated at all |
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
manager re-spawns the child after a crash or drift. The bridge carries no config on its argv: it re-reads the `mcp` record named by `--server` at startup (so the record stays the single source of truth) and exits immediately if that record is disabled. It exits 1 when the record is unreadable or its stored name does not match `--server` (the supervisor then backs off and retries), and `--probe` requires `--server <name>` too — the probe's config arrives on stdin.

- **Naming**: tools are prefixed `mcp_<server>_<tool>` (niffler lowercase
  convention, globally unique in the catalog); descriptions carry a
  `[mcp:<server>]` provenance prefix. Server names must match
  `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$` (≤32 chars, `bridge` reserved); tool names are sanitized to the same
  alphabet and capped at 64 chars. The manager rejects servers whose generated tool names
  collide with another server's or with a catalog tool.
  Each bridge also registers one hidden helper, `mcp_<server>_bridge_status
  {op: status|refresh}` (invisible to the LLM), which `mcp_servers` calls for
  its live state and `mcp_refresh` for the reconnect; `status` carries
  `connected`, tool and prompt counts, `retiring`, `activeCalls`, `lastError`,
  `startedAt`, `lastUsed` and `idleMs`.
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
  call immediately. Direct callers (CLI scripts) normally get `""`, and an
  unattributed call is never cancellable — only its `timeoutMs` bounds it.
  Nothing validates the field on the direct bus path, so a caller that supplies
  its own `__session` names the id its call is matched against, and any
  `cancel.mcp-<server>` carrying that id cancels it.
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
  inherit a fixed environment allowlist — `PATH`, `HOME`, `USER`, `LOGNAME`,
  `TMPDIR`/`TMP`/`TEMP`, `LANG`/`LC_ALL`, `SYSTEMROOT`,
  `SSL_CERT_FILE`/`SSL_CERT_DIR`, `XDG_CACHE_HOME`/`XDG_CONFIG_HOME`,
  `UV_CACHE_DIR`, `NPM_CONFIG_CACHE` — plus whatever the record's `env` adds.
  `SHELL` and `TERM` are *not* passed, and `NIF_*` variables and secrets in
  the harness environment never reach them. HTTP/SSE servers only see configured `Authorization`
  headers, and only when they point at the server's own origin — credentials
  are never replayed to a cross-origin redirect target (the redirect is
  refused instead).
- **Result size**: MCP results ≤64 KiB are returned inline; larger results are
  spilled to `$NIF_ROOT/var/mcp-results/result-*.json` and the tool gets a
  machine-readable pointer instead — `{text: <the first 16 KiB of the text
  plus a line naming the file>, spill: {path, bytes}, truncated: true}`
  (readable with `read`, `grep` or `bash`), so a big result never blows up the
  context window. Non-text content parts and structured content are
  JSON-serialized into `text` rather than dropped.
- **Drift**: on each fresh session (and on server-pushed
  `notifications/tools/list_changed`) the bridge re-lists the server's
  tools; when the contract moved it persists the fresh listing (best effort,
  rev-retried) and exits 3, so the supervisor restarts it announcing the
  current truth.
  The exit waits for in-flight calls to finish, so a drift never truncates a
  call. Catalog and execution never disagree for long. If that refresh cannot be persisted the bridge fails closed in a *retiring* state instead of crash-looping: `mcp_servers` shows the error, and the server needs `mcp_refresh` (after active calls finish) or `mcp_edit` to recover.
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
(`url`+`headers`). `approval: "always"` gates every one of the server's own
tools — `mcp_<server>_<tool>`, its resources tool and its prompt tools — with the
human approval prompt, per call; `effect: "read"` marks read-only tools for fabric
scheduling; `concurrency: "serial"` for servers that cannot handle overlapping
calls (default `parallel` via the SDK's bounded `ToolConcurrent`). A record's
`timeoutMs` is not only a runtime budget: the bridge writes it into every tool's
`x-harness.timeoutMs` at registration, so it is fixed for that bridge process's
lifetime. The
manager owns every field except the caches: the bridge rewrites `tools`
**and** `prompts` when the server drifts.

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
| on demand | `x-harness.onDemand: true` | omitted | hint + schema lookup | `invoke` (a call by bare name also dispatches when the conversation has no tool allowlist) |
| hidden | `x-harness.hidden: true` | omitted | omitted, including explicit lookup | components/core only |

Hidden takes precedence if both flags are present. A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist — how replaceable runner machinery (the compactor) reaches a child whose toolset was frozen before it existed. The two flags are required together: an on-demand tool that carries `runner` without `hidden` is **not** exempt, and is refused in an allowlisted conversation like any other tool outside its `tools` list. Exposure is not an ACL:
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
  tools, `undo_last_edit`, `context_recall` (what a notice naming replaced
  content points at), `repo_map` (the ranked workspace map the model
  asks for explicitly), and the `observe_*` diagnostics plus
  logfile's `logfile_search`/`logfile_paths`.
- State and introspection: store `get`/`list`, `session_info`, and the
  skill entry points `skill_list`/`skill_load` (a workflow guide is
  loaded only when one fits the task).
- Orchestration: `fabric`, the `agent_*` and `expert_*` tools.
- Core lifecycle/status/catalog, builder, plugins, and fetch.
- Models and provider administration.
- Skill resources, online search, install, and remove.

Internal tools remain hidden: core `session`/`session_prepare`, store
`del`, LLM `chat`/`llm_resolve`, the systemprompt prompt, the compaction seam's
`compaction_propose`, and the
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
conversation. Replacing the constitution is a normal Niffler operation: write a
component that answers on the same subject — the subject is derived from
the component name, so it must register as `systemprompt` — `build` it,
`kill` the old one (`core.spawn` refuses a name that is already
supervised), then `spawn` yours. The swap lasts only until the next
boot, though: a component declared in `manifest.yaml` is restored
first and a stored record for the same name is skipped, so a permanent
replacement means editing `manifest.yaml`. The agent can do this to
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
- **Cap.** Answers are truncated at 200 KB (both sides) — the component stops
  at 200 000 bytes itself (marker `[systemprompt: truncated at 200000 bytes]`;
  core adds its own) and collects at most 16 context files. Both numbers are
  compile-time constants with no env knob: a different cap means rebuilding
  the component.
- **Agent pre-fetch.** The `agent` component requests the prompt for
  subagent children before their first turn and passes it via the session
  call's `systemPrompt` field (best effort — the runner's own fallback
  covers a missing component).
- **Prompt slots (extension seam).** Components and plugins contribute
  fragments through the hidden `prompt_hint {slot, content, source?, key?,
  mode?}` tool: the named slots (`tool_usage`, `efficient_tools`,
  `after_instructions`) are rendered into `<prompt_slot name="…">` blocks in a
  deterministic order (by `source`, then `key`); `mode: aggregate` (default)
  keeps every contribution and `mode: singleton` keeps only the last one
  registered for that slot, while a slot with no contributions renders
  nothing. Registration is component-local state and only affects prompts
  composed *after* it — a frozen conversation is never rewritten.
  `prompt_hint` is `x-harness.hidden` too, so neither it nor `systemprompt`
  ever appears in an LLM toolset.

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt` — the product prompt
   (change-scope discipline, tool-selection guidance, the docs pointer),
   baked into the binary verbatim at compile time via `staticRead` — no
   substitution and no template. Editing it is
   rebuild + respawn; there is no runtime file dependency.
   The product prompt is also where the model is taught the replaced-content
   recourse: pruned tool results, spilled command output and compaction
   checkpoints are retrievable with `context_recall` by passing the ref quoted
   in the notice verbatim — weaken that sentence and every trim, spill and
   compaction notice stops being followed.
2. The repo's local context files, Pi-style, wrapped in
   `<project_context>`/`<project_instructions path="...">` tags after the
   product prompt:
   - per directory, first hit wins: `AGENTS.override.md`, `AGENTS.md`,
     `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` (one file per directory —
     `AGENTS.md` shadows a `CLAUDE.md` next to it; symlinks are followed;
     `AGENTS.local.md` is added in addition, never as a candidate: it never
     shadows the primary file, and it is collected for every directory of the
     walk, not only lazily);
   - ancestor walk from the conversation's cwd **up to the harness root
     (inclusive)**, root first, deduplicated by file identity (device:inode —
     a symlink farm cannot inject the same file twice); nearer-to-cwd files
     appear later, so the most specific instructions are the last thing the
     model reads. A workspace **outside** the harness root walks its own
     directory only, so an unrelated `AGENTS.md` in `$HOME` never leaks into
     the prompt;
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
service or capture directories to untrusted bus clients. Nor can it be
replicated: the ring, the probes and the component census are process-local, so
replicas would split one view into several and multiply exactly that exposure —
the manifest leaves `replicas` unset for this reason.

**Not an audit trail.** None of these components is a durable record of
decisions: `observe` keeps a bounded in-memory ring that dies with the
component, `logfile` is best-effort (at-most-once, `ev.log.>` by default),
`console` prints and forgets, and `hooks` record nothing. The only durable
artefacts of the approval gate are the client-written grant record (store
kind `approval`) and the program source core writes to
`var/approval-sources/<digest>.nim` — no request/verdict history exists.

### `observe`: bounded live inspection

`observe` has one raw `>` subscription. It preserves the original JSON node,
including unknown envelope fields and bare registration payloads. Its
sibling `console` decodes every message: an envelope renders as
`call`/`result`/`error`/`event`, while a bare payload (a `reg.publish` /
`reg.depart` registration) renders as `event <subject>` followed by the
object itself, and a result line carries the tool it answers (shortened
envelope id; attribution from an id→tool map of the calls already rendered —
the SDK's reply envelope carries no tool name). Malformed JSON
is retained as `{raw, decodeError}` when it is valid UTF-8; arbitrary bytes use
lossless `rawBase64` instead. Oversized messages are represented by a bounded
base64 preview rather than letting one message consume the process.

The global ring is bounded by both message count and approximate wire bytes —
2 000 messages and ~16 MiB by default (`NIF_OBSERVE_RING`, clamped 1..10000;
`NIF_OBSERVE_RING_BYTES`, 64 KiB..100 MiB), with a single retained message
capped at 64 KiB (`NIF_OBSERVE_ENTRY_BYTES`, 1 KiB..1 MiB — a larger one is kept
as a base64 preview). Each targeted probe has independent count and byte bounds
— at most 2 000 entries and 2 MiB (`cap`, clamped 1..2000;
`NIF_OBSERVE_PROBE_BYTES`, 64 KiB..16 MiB) — and the number of probes is also
capped at 32 (`NIF_OBSERVE_MAX_PROBES`, 1..256), so the 33rd
`observe_listen`/`observe_trace` fails until one is removed. Stopped probes
remain queryable until `observe_remove` releases their memory.

| Tool | Use |
|---|---|
| `observe_subjects` | List the authoritative component/service view when core is reachable (a `session-<id>` component maps to `svc.session.<id>.call`), the fixed known-event set (`reg.publish`, `reg.depart`, `ev.sys.drain`, `ev.catalog.updated`, `ev.llm.token`, `ev.session.>`, the three `ev.approval.*` subjects, `svc.approval.>.request`, `ev.log.>`, `ev.models.updated`, `llm.cancel.>`), and the most frequently observed concrete subjects (top 100, `_INBOX.*` excluded); the core view is a best-effort 250 ms `catalog` request and the `*Truncated`/`dropped*` counters say when an answer is partial |
| `observe_listen` | Start a bounded capture for a token-correct NATS pattern (`*` and terminal `>`) plus optional regex; `cap` defaults to 500 and is clamped to 1..2000, and the returned `probeId` is `pr-<id>` (same for `observe_trace`) |
| `observe_trace` | Capture calls to one component and correlate result/error inbox replies by envelope id — it watches `svc.<component>.call` and the scoped `svc.<component>.<id>.call` form, `toolRegex` filters by tool name, `cap` defaults to 500 (max 2000), and each correlated reply carries `elapsedMs` from a monotonic clock |
| `observe_probes` | Inspect probe state, retained bytes, caps, and pending traces |
| `observe_stop` | Freeze a probe while retaining its entries |
| `observe_remove` | Delete a probe and release its memory |
| `observe_events` | Query a probe or the global ring, newest first, with time/kind/component/subject/regex filters; `kind` is `call|result|event|error`, `component` matches `svc.<component>.*`, `ev.log.<component>` or an envelope's own `component` field, `subject` is an exact concrete subject, and `limit` is clamped to 1..500 |
| `observe_logs` | Query recent `ev.log.*` events in memory — the ring only, for persisted history use `logfile_search`; items carry `component`, `level`, `msg` plus the emitter's `at` as `emittedAt` and `ctx` when present, and `limit` is clamped to 1..500 |
| `observe_dump` | Approval-gated export of one probe beneath `NIF_OBSERVE_CAPTURE_DIR` (the file is `<captureDir>/<probeId>.jsonl`, one JSON object per captured entry, in a directory created user-only — 0700, files 0600 — with a symlinked target refused and older captures pruned oldest-first to a byte quota and a 256-file cap; when even pruning cannot fit the dump the tool fails with `capture directory quota is exhausted`); arbitrary output paths are not accepted |
| `observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns; approval-gated — it borrows the operator's monitoring endpoint |
| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |
| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated. The request wait is clamped to 100–30000 ms (`timeoutMs`), and the tool call itself carries `x-harness.timeoutMs: 35000` |

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

Default input is `ev.log.>`. One file per component name matching
`[a-z0-9-]{1,64}`, under `NIF_LOGFILE_DIR` (`$NIF_ROOT/var/logs` by default; an
absolute value is used as-is, a relative one is resolved against the harness
root):

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
The list is validated at boot: a malformed or over-512-byte pattern, more than
64 unique patterns, or an empty result makes the component exit non-zero. With
several patterns the tap is `>` and matching happens locally; a single pattern
is subscribed as itself.

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
generation. Rotated generations are named `<file>.1` … `<file>.<KEEP>`, and
every boot deletes any generation numbered above the current
`NIF_LOGFILE_KEEP` — lowering the knob destroys history at the next start.
`.jsonl` files already on disk at boot also count against
`NIF_LOGFILE_MAX_FILES`.

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

Both read tools are `onDemand` and declare no `x-harness.effect`, so the fabric
batch host schedules even a read as a write. `logfile_search` takes
`{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?,
until? (epoch seconds, `since ≤ until`), limit? (default 100, cap 500)}`; an
invalid argument comes back as `{"error": …}` inside a *successful* result
rather than as an error envelope, and with no `timeoutMs` on the schema the call
runs under core's 120 s default deadline.

`logfile_paths` reports up to 500 retained files plus `writeErrors`,
`lastError`, `lastErrorAt`, `maxBytes`, `keep`, `subjects` and the component-file
count. Filesystem failures also go to stderr. The **log directory** is created
user-only (0700, files 0600) where the platform permits, and an active symlink
at a log path is refused.

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
NATS allocates the ports itself: core passes `--ports_file_dir <tmp>` and
reads the client and monitoring ports back from the `*.ports` file it writes
(a bounded 4 s wait), so concurrent harnesses cannot win a bind-close-start
race. Core passes the home port when it is free and `-1` (a random port) when
it starts an isolated bus.
A reused or remote bus has no discoverable HTTP endpoint; configure
`NIF_OBSERVE_MONITOR_URL` explicitly. `NIF_NATS_SPAWN=1` forces an isolated
core-owned bus on a random port (primarily for tests and diagnostics) —
never 4222; an explicit `NIF_NATS_URL` in the environment wins.

A request carries a whole conversation, so the bundled bus is started with
`max_payload: 8388608` (8 MiB — about 2M tokens of JSON; above that
nats-server only warns): the bundled `var/bin/nats-server` takes it as an
extra flag, while a PATH `nats-server` gets it in a generated config file
instead. When core attaches to a bus it did not spawn, it reads the server's
real cap and warns at boot when it is below 8 MiB — such a bus rejects a large
reply at publish time and the caller waits out its full timeout, which looks
like a component hang rather than a bus limit.

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
`ev.session.<id>.*` events (toolcall start/done — the judgment trigger — turn
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
persisted, and announced on `ev.session.<id>.advice`. The judge lane itself stays
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
(`put` accepts `expectRev` and fails with `rev-conflict` on mismatch). The
barrel engine also registers a hidden `selftest` tool — a real
put/get/rev/list/`del` roundtrip that `/doctor` can call; the two SQL engines
register the four tools only.
`put`, `get` and `list` are on-demand tools; `del` is hidden — core deletes
records, the model cannot. `put` also carries `x-harness.sessionId`, which is
what makes the write fence below possible. A **session-bound caller may only write curated kinds**
(`fabricprog` today): every other kind is harness-managed and refused with
`forbidden-kind`, so no live session can corrupt transcripts or component
records. Direct bus callers (cli, tests, core) keep full access.
Kinds in use by core and its components (the store tools' own docstrings name
only a subset — this table is the complete list):

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` — the conversation header (also carries the frozen system prompt, model/thinking selection, per-session budget controls and token meters) |
| `message` | `<convId>:<seq>` (the sequence zero-padded to six digits — id order is message order) | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` — persisted shape restored on boot |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` — install record of the `plugins` component |
| `provider` | nickname (plus the `active` marker doc) | LLM provider registry of the `provider` component. Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only (`provider_list`; `mcp_servers` likewise redacts the `mcp` records' `env`/`headers`). That covers both kinds' secrets, so any copy of `var/store.db` or `var/barrel-db` is a copy of them |
| `session` | `<sessionId>:tools` | the conversation's frozen direct toolset snapshot (see [Progressive tool discovery](#progressive-tool-discovery)) |
| `slash` | `slash` | the merged slash-command table UIs render (see [WIRE.md](WIRE.md)) |
| `agentjob` | `<jobId>` | durable background `agent_spawn` job records (continuations stamp `continued`, `activation`, and queue `close`) |
| `agentnotice` | `<parentSession>:<seq>` | subagent settlement notices (summary + recourse to the full reply; `deliveredAt`/`deliveredVia` mark delivery) |
| `sessionmeta` | `<sessionId>` | subagent lineage / runner metadata: `{parent}` on spawn; continuations add `activations` (turn count, 1-based) and `firstActivationAt`; `close: true` retirement sets `closed` |
| `fabricprog` | program name | the model-curated fabric program library (`fabric {name}` runs one) |
| `profile` | profile name | named tool-profile selector list of the `profile` core tool; resolved once into a conversation's direct toolset at its first turn |
| `approval` | `<sessionId>:<key>` | a client's "don't ask again" grant (keyed by tool, or `tool:<digest>` for program-shaped calls); core reads it to skip the approval gate |
| `contextreceipt` | `<convId>:<requestId>` | the request-scoped receipt of an overflow-recovery attempt, written before it is spent and updated with the outcome |
| `compaction_input` | `<convId>:<attemptId>` | the paged pre-compaction snapshot the compaction component verifies and the runner commits from (pages are `<id>:p<idx>`). Transient: deleted as soon as the attempt settles, and pages orphaned by a crashed or timed-out attempt are swept after 600 s — nothing may treat it as durable (only `context_projection` is) |
| `context_projection` | `<convId>` | one document per conversation — the committed context projection (`version`, `generation`, `canonicalHigh`, `renderer`, the normalized `checkpoint`, the durable `covered` canonical range, the `retained` ids, `prunes`, `measurements`, `provenance`) a runner reuses after compaction. Written once with `expectRev` on the previous generation; it is the source of truth a restart rebuilds the provider view from, and the recall resolver reads its `checkpoint`/`generation` when a notice names a `checkpoint` ref |
| `spill` | `<convId>:<n>` | an oversized tool result promoted out of the context window, addressable with `context_recall {"ref": {"source": "spill", "id": "…"}}`. Promotion is best-effort at append time (a failure keeps the temp-file pointer and adds no ref); a missing, empty or malformed spill document is refused loudly instead of answered as an empty success, and the prune gate re-verifies the document before pruning, so a broken spill can never cost the last copy |
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
make test           # the full gate: the bus-contract suite (the desktop UI's
                    # frontend tests + typecheck live in gokr/niffler-ui)
make test-server    # ... server side only: one test-owned NATS per test, no node
make test-bash      # ... or just one — `make help` lists every target
                 # (test-uireg, test-autostart, test-<component>); the full
                 # bus suite is `make test-server`
```

`make test-server` runs the ~60 test binaries through
`scripts/run-tests.sh` in a bounded pool (one test per core by default):
tests own private NATS servers and temporary roots, so they overlap safely.
Each test's output is captured to `var/test-logs/<name>.log`, its wall time
is printed on completion, and the summary lists the slowest — override with
`TEST_JOBS=N` (or `NIF_TEST_JOBS=N` for the script directly); `TEST_JOBS=1`
is the old sequential run, and the logs remain per-test either way.
`NIF_TEST_VERBOSE=1` interleaves each test's captured output after its line.

Each test boots the real component binaries (Nim, Go *and* TypeScript —
the envelope is the artifact, so one harness tests every SDK) and drives
them over a private nats-server each test starts for itself (`NIF_NATS_SPAWN`-style isolation).
The desktop UI's frontend tests are not part of this suite: the UI is the
[gokr/niffler-ui](https://github.com/gokr/niffler-ui) plugin now, and its lib
unit tests and typecheck run in that repository (`make test` /
`make typecheck` there), so this gate stays self-contained.
Core-based tests snapshot their required binaries into a unique temporary
`NIF_ROOT`; Barrel, plugin clones, generated components, logs, and caches are
therefore isolated. Individual `make test-*` targets may run concurrently
with each other and a live development harness — `scripts/run-tests.sh`
relies on exactly that to pool the suite. Repository build writes
(`make build`, `make clean`) are serialized by `scripts/with-build-lock.sh`;
a runtime `builder.build` does not take that lock, so a `make clean` in a
second terminal deletes `var/bin` and `var/build` under a running build.
Agent-built test components use sandbox-local Nim caches.

Several tests carry their own fixtures instead of a real model:
`components/ctxtest/` is a stub-LLM component (a hidden `chat` that plays a
scripted turn per session id) that also supplies the contract fixtures a real
tool cannot produce on demand — parameter-name mangling, a schema collision,
catalog republish churn, an `effect: "read"` item for the fabric batch host, a
scalar `outputSchema` — plus `ctxecho`, the `sessionContext` probe that proves
harness-private context is stripped from nested calls;
`components/ctxtest/sink.nim` registers a second component (`ctxsink`, which
reports `sawSession`) for the same check. `tests/mock_llm.nim` and
`tests/mock_parallel_llm.nim` are the equivalent stand-ins for the `llm`
binary. None of them is in `manifest.yaml` or built by `make build`: each test
compiles the one it needs into its private sandbox `NIF_ROOT` and spawns it
there.

`/doctor deep` additionally fans out to each component's own self test over
the bus (`comp.selfTest`): `bash`, for example, really execs a command through
its process-group path and then proves the timeout kill at a 1 s budget,
expecting exit 124. Components that do not implement one are listed under
`selftestMissing` (and as one `selftest (not implementing)` markdown row) —
coverage information, never a failed check.

The compaction contract has a verification lane of its own:
`make test-compaction` runs the end-to-end propose/commit/restart/reload
fixtures, and `make test-conformance --bin:<path> --tool:<name>` points the
same contract-v1 suite at a replacement compactor — the acceptance test for a
third-party summarizer (both ride the wildcard `t_*` suite, so
`make test-server` runs them too). `make live-smoke` is the opt-in live gate:
real summarization against a real provider, `SYNTHETIC_API_KEY=...`, outside
the suite.

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
  binary itself is installed by `make install-ui` — the desktop UI is the
  [gokr/niffler-ui](https://github.com/gokr/niffler-ui) plugin, built by the
  builder into `var/bin/niffler-ui` and linked onto PATH by `make install`.
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
  bus that the desktop UI would refuse. The chain is per client: the Nim clients (`cli`, `console`) probe
  `NIF_NATS_URL` → `<NIF_ROOT or their own clone>/var/nats-url` →
  127.0.0.1:4222 and never the cwd, while the bash `dialog` uses
  `NIF_NATS_URL` → `./var/nats-url` (cwd only) → 127.0.0.1:4222. Start the harness first — desktop UI
  or `./var/bin/niffler`.
- **Terminal admin shell** — `./var/bin/niffler` directly, or
  `./var/bin/niffler --minimal` for the three-component boot profile. A
  manually started core never self-terminates; stop it with Ctrl-C / SIGTERM.
  `NIF_AUTOSTART=1` in the environment overrides the shell — that core is
  service mode even on a tty — and while it sits at the prompt it keeps
  serving `svc.core.call`, so a UI can attach to a tty-started core.

Interactive frontends register `"client": true` (the SDK's `interactive()`
/ `Component.Client` marker). `console` and `dialog` are not interactive frontends by this
definition: neither registers `client: true`, so an autostarted core
can exit under them (the `console` reconnects on its own when a new
harness appears). That mark is a registration, not a lease: a
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
                    # + niffler-ui when its plugin binary exists and the
                    # niffler-tui wrapper on request — never component
                    # binaries such as the `grep` tool (`var/bin/grep`, which
                    # shells out to `rg`), so PATH cannot shadow grep/git/...)
make install-tui    # same, installing the niffler-tui terminal client quietly
                    # (= make install WITH_TUI=1)
make uninstall      # remove those PATH entries again
make install-ui     # install the desktop UI plugin (gokr/niffler-ui): an
                    # isolated auto-approved harness boots, the plugin manager
                    # clones + the builder builds it into var/bin/niffler-ui
make install-lsp    # install the lsp component's default language servers
make test           # the full gate: the bus-contract suite (the UI repo's
                    # frontend tests live in gokr/niffler-ui)
make test-server    # the bus-contract suite alone (each test owns a private bus)
make doctor         # check prerequisites
make ram            # RAM of running stacks (harness + components + nats + clients)
make down-here      # stop this checkout's harness, components and spawned bus
                    # only — bench worktrees and other clones survive
make clean          # remove all build artifacts (var/, nimcache/)
```

- **Headless service mode** (no tty, for UIs/automation):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` —
  serves `svc.core.call`; approval-requiring tools are denied unless a UI
  is attached or `NIF_AUTO_APPROVE=1`.
- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222` (even remote), or
  start your own nats-server on the default port before core — core reuses
  a bus on `127.0.0.1:4222` only when the core answering it serves **this
  root**; a foreign harness, or a bare nats-server with no core on it, makes
  core warn and spawn an isolated bus instead (a leftover `var/nats-pid`
  naming one of this root's own buses is reclaimed first). To force a bus
  deliberately, set `NIF_NATS_URL`.
- **Probe the bus** without the LLM: one-shot `nim c -r` scripts in
  `tests/` (see AGENTS.md "Debugging the bus").
- **Wails**: the desktop UI (and any Wails client package) builds through
  its package recipe, which must run `wails build -tags webkit2_41`
  (Linux) — a plain `go build` produces a stub. The UI's SPA dev server
  lives in the gokr/niffler-ui checkout (`make dev` there).
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
| a turn was cancelled but a compile keeps running | `build` declares no `x-harness.sessionId` and `builder` subscribes no `cancel.build`, so the cancel is dropped: the compiler runs to its own deadline and only the reply is abandoned. Wait for the tool result before cancelling, or `core.kill {name: "builder"}` |
| session call fails: "session runner binary missing" | `var/bin/session` was never built — `make build` |
| `spawn` fails: "spawn failed — tool '<t>' already provided by <owner>" | the registration was refused — almost always a tool name that already exists (names are globally unique; prefix yours with the component name). Fix the name, rebuild and `spawn` again: the failed attempt was rolled back (replicas stopped, nothing persisted), so the name is free immediately. On core's stdout the same refusal reads `catalog: rejecting <name> — …` |
| `spawn` fails: "did not register within <n> ms" | the component never announced itself in time — a slow-starting one, or a binary that died on the way (core appends a bounded tail of `var/logs/<name>.log` to the error). Fix the cause and `spawn` again (the attempt was rolled back), or raise `NIF_SPAWN_WAIT_MS` for a genuinely slow component |
