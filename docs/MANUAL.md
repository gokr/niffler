# Niffler Manual

Everything you need to operate, configure and recover a Niffler harness, plus
reference chapters for the shipped components. Design rationale lives in
[research/REBOOT.md](research/REBOOT.md); the wire protocol is
[WIRE.md](WIRE.md); the core/component boundary is
[ARCHITECTURE.md](ARCHITECTURE.md).

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch)
- [Progressive tool discovery (`discover`/`invoke`)](#progressive-tool-discovery)
- [Model catalog (`models`)](#model-catalog-models)
- [System prompt (`systemprompt`)](#system-prompt-systemprompt)
- [Observation and logs (`observe`, `logfile`)](#observation-and-logs)
- [Fabric and subagents](#fabric-and-subagents)
- [Expert advisory peer (`expert`)](#expert-advisory-peer-expert)
- [Recovery](#recovery--recover) · [The store](#the-store) · [Testing](#testing)
- [Starting and stopping](#starting-and-stopping) · [Common tasks](#common-tasks) · [Troubleshooting](#troubleshooting)

## Layout of a running system

| Path | What it is |
|---|---|
| `core/` | the control plane: system harness (`niffler.nim`: bus bootstrap, supervisor, catalog, dispatch) + session runner (`session.nim`: one process per conversation, the conversation loop) |
| `components/` | shipped component sources: `bash`, `builder`, `store`, `plugins`, `skills`, `fetch`, `edit`, `grep`, `git`, `agent`, `fabric`, `observe`, `logfile`, `cli`, `console` (Nim), `models`, `provider` and `llm` (Go) |
| `sdk/` | Nim SDK (`sdk/niffler`) + `sdk/go` (Go) + `sdk/ts` (TypeScript/Node.js, npm package `niffler-sdk`); the envelope in `sdk/envelope.nim` is the artifact |
| `docs/` | this manual, the wire spec, the core-boundary rationale and `research/` (design history) |
| `manifest.yaml` | bootstrap manifest: which components core spawns, in what order, and with what restart policy; `--minimal` filters it to `store`, `bash`, and `llm` |
| `var/` | **runtime state, gitignored, disposable** — the repo is the snapshot |
| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |
| `var/barrel-db` | the store's embedded KV file — **single-writer**: exactly one `store` process may open it |
| `var/nats-url` | bus address of the last spawned bus; the UI bridge reads it to find core |
| `var/nats-monitor-url` | HTTP monitoring endpoint when core spawned the bus; absent for reused/remote buses |
| `var/logs/`, `var/captures/` | rotating structured logs and explicit observe probe exports (see [Observation and logs](#observation-and-logs)) |
| `var/nats-pid` | pid of the bus core spawned (crash cleanup only — a live core stops its own bus on exit) |
| `var/build/` | source files of agent-built components (builder's scratch dir) |
| `nimcache/`, `ui/build/`, `ui/frontend/node_modules/`, `ui/frontend/dist/` | build artifacts; `make clean` removes them |

### Shipped components

| Component | Language | Manifest | What it does |
|---|---|---|---|
| `store` | Nim | required | document store over the bus (`put/get/list/del`, rev-based concurrency) |
| `bash` | Nim | required | the classic tool: shell commands with timeout + output cap |
| `builder` | Nim | required | compiles agent-written Nim/Go source into binaries |
| `llm` | Go | required | streaming chat adapter (hidden `chat` tool; `ev.llm.token` deltas; cancellation) — protocols: OpenAI-compatible Chat Completions, OpenAI Codex (ChatGPT OAuth) Responses and Anthropic Messages; `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml` |
| `models` | Go | optional | models.dev provider/model catalog, atomic cache, strict resolution, and plugin correction/discovery layers (see [Model catalog](#model-catalog-models)) |
| `provider` | Go | optional | store-backed LLM provider registry: `provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`, subscription OAuth login (`provider_oauth_start`/`complete`/`cancel`), `ev.provider.switch` notifications |
| `plugins` | Nim | optional | ecosystem front door: topic search + install/update/remove of packages |
| `skills` | Nim | optional | Agent Skills (SKILL.md): discovery, load, resource access, git-based install/remove |
| `fetch` | Nim | optional | web content retrieval: http/https, HTML→text extraction, size caps with file spill |
| `edit` | Nim | optional | the file tools: `read` (plain, pageable), `edit` (unique `old_string`, guarded fallback cascade, `replace_all`), `write` (atomic whole-file), `undo_last_edit` (approval-gated mutations); anchored block moves live in the [niffler-hashline](https://github.com/gokr/niffler-hashline) plugin |
| `git` | Nim | optional | read-only repo inspection: `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame` over fixed argv (approval-free; mutations stay in bash). On-demand tools — the worker reaches them via `discover` + `invoke`, keeping the direct toolset small |
| `agent` | Nim | optional | subagent sessions: `agent_run` — fresh context, own loop, summary returned (see [Fabric and subagents](#fabric-and-subagents)) |
| `expert` | Nim | optional | advisory peer: follows one session, LLM-judged, turn-bound steer (see [Expert advisory peer](#expert-advisory-peer-expert)) |
| `fabric` | Nim | optional | programmable tool calling: the model writes a Nim program that orchestrates tools; only its `finish()` value enters the conversation (see [Fabric and subagents](#fabric-and-subagents)) |
| `grep` | Nim | optional | ripgrep-backed search: `grep` (contents, path:line:match) and `files` (sorted listing); .gitignore-aware, no shell quoting needed |
| `systemprompt` | Nim | optional | the conversation constitution: session runners fetch the system prompt from `svc.systemprompt.call` once per conversation (see [System prompt (`systemprompt`)](#system-prompt-systemprompt)) |
| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |
| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |
| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring (see [Observation and logs](#observation-and-logs)) |
| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) |
| `dialog` | bash | — | demo component written entirely in bash — nats CLI + jq, no SDK, no compile step: `dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer. Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `core.spawn {name: "dialog", binary: ".../var/bin/dialog"}`. Prereqs: natscli, jq, zenity — `make setup` installs all three |

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
table and then a 128K fallback.

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
the turn to `svc.session.<sessionId>.call`. The runner is a supervised
child (restart policy `never`); it announces itself as component
`session-<id>` with zero tools, seeds its catalog from
`catalog {op: snapshot}` at startup, and emits the same `ev.session.*`
events as the classic in-core loop. Sessions are ephemeral: history lives
in the store, so a fresh runner resumes the conversation on the next call.
Killing a runner kills only that conversation — the process is the unit of
isolation. Turns never nest either way.

The stdin/stdout tty (`make run`) is an **admin shell**, not a conversation
UI: it only inspects the harness itself — `help`, `status`, `catalog`,
`tools`, `sessions`, `exit` — with arrow-key history and tab completion
(see `core/tty.nim`). The LLM chat lives in the web UI and the `niffler-tui`
plugin; scripting goes through the `cli` component.

## Environment variables

All components load `.env` (from the harness root and cwd, existing shell
env always wins — see below) and inherit core's environment. The full set:

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | the harness root (repo). Core derives it from its binary location if unset, and sets it for all children. Components use it to find the SDK, `var/`, `.env`. Every component runs with **cwd = NIF_ROOT**, so the agent's `bash pwd` is always the home — regardless of where you launched the harness | `<binary location>/../..` |
| `NIF_NATS_URL` | bus to attach to. Unset → core reuses a live bus on `127.0.0.1:4222`, else spawns `nats-server` there (or on a random loopback port when 4222 is taken) and writes `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` forces core to spawn an isolated loopback bus instead of reusing port 4222 — only when `NIF_NATS_URL` is unset (an explicit URL always wins) | unset |
| `NIF_AUTOSTART` | set by an SDK's `ensureHarness` when a UI had to spawn core: that core exits when the last interactive client departs (see Starting and stopping) | unset |
| `NIF_AUTOSTART_IDLE_S` | seconds after the last interactive departure before an autostarted core exits | `10` |
| `NIF_AUTOSTART_BOOT_S` | seconds an autostarted core waits for its first interactive client before giving up | `60` |
| `NIF_ENSURE_ATTACH` | `0` makes `ensureHarness` skip attaching and always spawn a core (tests) | `1` |
| `NIF_GIT_MIRROR` | host prefix replacing `https://github.com` when the `plugins` component clones packages (e.g. `https://cnb.cool` or a Gitee mirror) — API/search endpoints stay on GitHub | unset |
| `NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default |
| `NIF_OPENAI_API_KEY` | API key for the LLM adapter (`llm`). Required for any conversation turn | — |
| `NIF_OPENAI_BASE_URL` | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | model name | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | models catalog provider id for the default LLM connection; common endpoints are inferred when unset | inferred |
| `NIF_OPENAI_CONTEXT` | explicit context window (tokens) the llm reports to core's context guard | `models` catalog, then `llm` fallback |
| `NIF_LLM_PROVIDERS` | JSON object of named providers `{nickname: {baseUrl, apiKey, model, context, catalog}}` the `chat` tool's `provider` arg resolves; the provider registry (`provider` component) supersedes the default when active | `{}` |
| `NIF_MODELS_URL` | models.dev-compatible catalog base or JSON endpoint | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | pinned local baseline catalog; useful for offline/testing | unset |
| `NIF_MODELS_OVERRIDE` | local JSON Merge Patch applied after every plugin source | unset |
| `NIF_MODELS_OFFLINE` | `1` disables remote catalog refresh | unset |
| `NIF_MODELS_CACHE_DIR` | catalog and source-patch cache | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | minimum age before refetching the baseline | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | background refresh interval; `0` disables | `1h` |
| `NIF_FETCH_DIR` | large fetch results and temporary extraction files | `$NIF_ROOT/var/fetch` |
| `NIF_TRAFILATURA` | Trafilatura executable path/name; `off` disables external extraction | auto-detect `trafilatura` on `PATH` |
| `NIF_LOG_LEVEL` | SDK structured-log publication threshold (`debug`, `info`, `warn`, `error`) | `info` |
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
| `NIF_AUTO_APPROVE` | `1` → the approval gate (below) is bypassed. For headless automation only; never set it in a session you care about | unset |

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

Loading rules (identical in the Nim SDK, Go SDK and the UI bridge):
existing shell environment **always wins** over `.env`; `.env` is loaded
from the current directory and from `$NIF_ROOT`, in that order. So
`NIF_OPENAI_API_KEY=other ./var/bin/niffler` overrides the file, and
`unset NIF_OPENAI_API_KEY` before starting if you want the file value.

## The bus in one screen

Core speaks exactly one protocol: JSON envelopes over NATS (details in
[WIRE.md](WIRE.md)). Subjects:

```
reg.publish            component announces itself: {name, version, pid, tools:[{name, schema}]}
reg.depart             graceful shutdown announcement
svc.<component>.call   queue-grouped tool call request/reply
svc.session.<id>.steer   fire-and-forget mid-turn message injection ({content})
svc.session.<id>.advise  turn-bound advisory request/reply (the expert peer):
                         accepted only while the named turnId is live
ev.session.turn        {sessionId, turnId, phase: start|done, content?, error?}
ev.session.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.token       {sessionId, turnId?, content, reasoning}  (live token deltas)
ev.session.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.advice      {sessionId, turnId?, source, content} an advisory was folded in
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
svc.approval.<name>.request # directed approval to the component driving the
                           # turn (derived from the call envelope's `caller`);
                           # driver acks {id, ack: true}, then answers {id, ok}
ev.approval.request    core → UI: {id, tool, args, caller?, fallback?} —
                       # human gate, broadcast (see Approvals below)
ev.approval.reply      UI → core: {id, ack?} | {id, ok}
ev.approval.resolved   core → UIs: {id, ok} — gate verdict; dismiss stale modals
ev.cancel.<call-id>    cancellation signal (components may subscribe)
```

**Streaming.** The `llm` component streams tokens while generating:
`ev.llm.token` deltas (content + reasoning) → core forwards them for the
active turn as `ev.session.token` → the UI appends them to the live
assistant bubble. The final `ev.session.assistant` event always carries
the complete content, so a missed last frame heals itself. Abort an
in-flight call by publishing to `llm.cancel.<sessionId>`.

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
waits for each registration — a plugin repo's CI proves a package by
running the harness itself through this one command. `file://` repo URLs
install from local git repos (hermetic tests, mirrors).

## Approvals

Tools whose schema carries `x-harness.approval: "always"` — currently
`bash`, `builder.build`, `core.spawn`, `core.kill`, `core.remove`,
`plugin_install`, `plugin_update`, `plugin_remove`, `skill_install`,
`skill_remove`, `provider_add`, `provider_update`, `provider_export`,
`provider_import`, `provider_use_environment`, `write`, `observe_send`,
`observe_request`, `observe_dump` — are
gated on a human before they execute:

- **Terminal harness** (`make run`): a `[approval]` prompt with the tool
  name and arguments; answer `y`/`n` (falls back to the tty prompt only
  when core is on a terminal and no UI is attached).
- **Web UI / interactive component**: a request is routed to the specific
  component that is driving the session — core derives it from the call
  envelope's self-declared `caller` and publishes to that component's
  private subject `svc.approval.<name>.request`. The driver acks it
  (`{id, ack: true}`) to confirm a human is being asked, shows a modal with
  the tool name and arguments, and answers `{id, ok}`.
- **Driver gone / not interactive**: if the driver does not ack within a
  short window, the request is rebroadcast on `ev.approval.request` with
  `fallback: true` so any interactive client can step in. Direct
  (non-session) calls broadcast immediately.
- **Neither** (service mode with no UI attached): the call is **denied**
  with a clear error — never silently approved.
- When a verdict lands, core publishes `ev.approval.resolved {id, ok}` so
  every client dismisses any stale modal.
- Unanswered UI requests time out after 5 minutes and are denied.
- `NIF_AUTO_APPROVE=1` bypasses the gate (headless automation).

## Context window

Core watches how much of the model's context window a conversation uses
and acts *trivially* — no summaries, no token math beyond what the model
reports:

- The effective window is resolved by hidden `llm_resolve {model?}` before
  each turn, so a newly selected model's limit reaches the context guard
  before inference. Per-provider `context` and `NIF_OPENAI_CONTEXT` override
  the models catalog; a small built-in table and conservative 128K remain as
  fallback if `models` is removed. The result includes secret-free provider,
  model, catalog and context provenance for interactive clients. See
  [Model catalog](#model-catalog-models).

- `session {sessionId, content?, model?, thinking?, title?, cwd?}` accepts a
  conversation-scoped model override. A model-only call persists and resolves
  the selection without inference; presence with an empty value clears it.
  Core stores the choice in the conversation header and pins the resolved
  model across all tool rounds in a turn.
- `cwd` pins the conversation's **workspace**: an existing directory inside
  `NIF_ROOT` (relative paths resolve against the root), immutable after
  creation and persisted in the header so resumed runners resolve context
  and paths identically. Session runners rewrite path-shaped tool arguments
  at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read_many
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
- Persisted messages carry audit metadata that never reaches the LLM:
  `createdAt` on every message, `turnId` everywhere, and `startedAt` /
  `durationMs` on assistant, tool and error records (an `error` record is
  persisted when the LLM call itself fails, and replay skips error roles).
- At **75%** of the window, core warns once (terminal log; the UI shows a
  note) — `ev.session.context {warning: true}`.
- At **90%**, core trims: whole turns are dropped from the front of the
  conversation (system prompt stays; never below 2 user turns; a note
  message tells the model history was cut). Whole-turn drops keep
  `tool_call_id` pairs intact. `ev.session.context {trimmed: n}`.
- Before the model has reported usage (fresh or resumed session), a
  rough chars/4 estimate stands in.
- The **store keeps the full history** — trimming is in-memory per
  session, so nothing is lost; a resumed session simply re-trims.
- If the API still rejects an over-limit request, the error surfaces as
  a normal llm error (existing behavior). Thresholds are constants in
  `core/conversation.nim` (`ctxWarnRatio`, `ctxTrimRatio`, `minKeepTurns`).

## Self-extension and component lifecycle

The agent adds capabilities at runtime, mid-conversation:

1. writes a component source (Nim: `import niffler/sdk`, typed tool
   pattern; Go: `import sdk "niffler.dev/sdk"` — see the system prompt)
2. `builder.build {lang, name, source}` compiles it into `var/bin/`
3. `core.spawn {name, binary}` starts it; it registers itself; new
   conversations expose its tools directly (when not on demand), existing
   ones reach them via `discover` + `invoke` (see [Progressive tool discovery](#progressive-tool-discovery))
4. `core.kill {name}` stops it temporarily (restored on next boot);
   `core.remove {name}` stops it and deletes its persisted record

**Persistence of shape**: spawned components are recorded in the store
(kind `component`) and restored on normal boot. `--minimal` leaves those
records untouched but does not restore them. `core` itself, the bus, the
catalog and the supervisor are not removable — that asymmetry is the
architecture (ARCHITECTURE.md).

## Component ecosystem (`plugins`)

The `plugins` component is the ecosystem front door — community component
packages are plain GitHub repos with a `niffler.json` manifest at the root
(one repo = one package = N components). Repos tagged with the GitHub
topic `niffler-component` are discoverable without any registry:

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub topic search; returns repo, description, stars |
| `plugin_installed` | the packages installed on this harness |
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`, build each component from source via `builder.build`, then `core.spawn` each service component (approved) |
| `plugin_update {package}` | to the latest release tag: remove, reinstall at the new ref |
| `plugin_remove {package}` | `core.remove` every supervised component, delete the clone, drop the record |

- Install/update/remove all carry `x-harness.approval: "always"` — they
  run third-party code, and every individual spawn/remove is approved
  again by core. Never run them with `NIF_AUTO_APPROVE=1` unless you trust
  the publisher.
- The default ref is the latest release tag, else the default branch.
  `version` pins a tag or branch explicitly.
- Components always build from source via the `builder` — the same path
  agent-written components take. Running Niffler already provides the
  toolchain (Nim/Go, nats.c, libclang), so no extra requirements; every
  platform compiles with its own toolchain. A Go entry may declare
  `"sources": ["component/helper.go", ...]`; these must be non-symlink,
  same-package `.go` files beside `main`, and the builder compiles them as one
  package.
- A component manifest entry with `"interactive": true` is built into
  `var/bin` but is not passed to `core.spawn`. It is a terminal client (for
  example a TUI) that the user starts manually, so it is not supervised or
  restarted on boot. Stop any running client manually before removing or
  updating its package.
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

## Skills

The `skills` component gives the agent reusable workflow guidance — the open
[Agent Skills](https://agentskills.io) format (SKILL.md files with YAML
frontmatter), the same convention Claude Code, opencode and Cursor use. It is
read/load only over the bus: no tool adds skills to the prompt, loading is
progressive disclosure through the tool result.

Discovery covers the bundled skills shipped in the repo plus the standard
agent directories (first match per skill name wins — project beats bundled
beats home beats config):

| Source | Directories |
|---|---|
| project | `$NIF_ROOT/.agents/skills`, `$NIF_ROOT/.claude/skills`, `$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills` (shipped with Niffler; `$NIF_ROOT/skills` as fallback) — never removable |
| home | `~/.agents/skills`, `~/.claude/skills`, `~/.opencode/skills`, `~/.niffler/skills` |
| config | `~/.config/opencode/skills` (where `npx skills add -g -a opencode` installs) |

Bundled skills (e.g. `todo-markdown` — keep todo state in a repo TODO.md,
not in tool state) make Niffler useful out of the box; shadow one by
dropping a same-named skill into a project or home directory.

| Tool | What it does |
|---|---|
| `skill_list {query?, source?}` | available skills (name, description, version, tags, source, dir); filter by substring or source |
| `skill_search {query, owner?}` | online search of the skills.sh registry (the `npx skills find` backend): name, repo source, install count; the `source`+`name` pair feeds `skill_install` directly |
| `skill_load {name}` | full SKILL.md instructions + resource list into the conversation (the load mechanism) |
| `skill_resources {name}` | the skill's `references/`, `scripts/`, `assets/` files |
| `skill_resource {name, path}` | read one resource on demand |
| `skill_install {repo, skill?, global?}` | clone a git repo, copy the chosen SKILL.md tree into `~/.niffler/skills` (default) or `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | delete a skill from a Niffler-managed directory only |

- `skill_search` is a read-only HTTP call to `https://skills.sh/api/search`
  (unauthenticated); it is not gated on approval. Install is: search →
  `skill_install {repo, skill}` → approval dialog → done.

- Skills installed with `npx skills add <owner>/<repo>` (the skills.sh
  ecosystem CLI) land in the standard dirs above and are discovered without
  reinstall; `skill_install` exists so Niffler works without Node, via plain
  git. It copies only SKILL.md trees — no code runs — and accepts
  `owner/name`, github.com URLs and `file://` local repos (hermetic tests).
- Repos holding several skills (e.g. `vercel-labs/agent-skills`) require the
  `skill` parameter; `skill_install` lists the candidates when it is missing.
- `skill_remove` refuses anything outside `~/.niffler/skills` and
  `$NIF_ROOT/.opencode/skills` — skills other agents installed into shared
  dirs are removed with their own tooling.
- Install and remove carry `x-harness.approval: "always"` (they write outside
  `var/`).

## Provider registry (`provider`)

Configured LLM backends are store records, not a config file. The
`provider` component keeps them under kind `provider` (id = nickname, plus
the `active` marker doc) and exposes them to the agent and to `llm`:

| Tool | What it does |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, active?}` | add an API-key provider (`protocol`: `openai-chat` default or `anthropic`); the first one becomes active automatically; response is redacted |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?}` | hidden client API for partial updates; omitted API key is preserved |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | hidden, start a subscription login: `protocol` `openai-codex` (ChatGPT Plus/Pro) or `anthropic` (Claude Pro/Max); `method` `browser` (local callback) or `device` (headless, OpenAI only). Returns `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | hidden, poll/finish a login; returns `{pending, retryAfterMs?}` until the callback (or pasted `code`) lands, then stores the provider and reports it redacted |
| `provider_oauth_cancel {flowId}` | hidden, cancel a pending login and close its callback listener |
| `provider_list` | all stored providers (redacted — no keys/tokens), which one is active; each entry carries `authType` (`api_key`/`oauth`), `protocol` and `expiresAt` |
| `provider_status` | hidden, redacted effective provider including environment fallback and `hasKey` |
| `provider_active` | hidden internal read of the effective provider's full config, credential included |
| `provider_get {nickname}` | hidden internal full-config read used to pin an explicit stored provider across a turn |
| `provider_switch {nickname}` | make another stored provider active; live-updates the LLM backend |
| `provider_use_environment` | hidden client API that clears the stored marker and returns to `NIF_OPENAI_*` |
| `provider_remove {nickname}` | delete a provider; if it was active, another one takes over or environment fallback resumes |
| `provider_export` / `provider_import` | JSON backup/migration round-trip, credentials included; import merges, validates records and can restore the active marker |

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
  blocks (consecutive tool results merge into one user message).

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

The `provider` component implements the same PKCE login flows Pi and opencode
use (fixed localhost callback ports, manual redirect/code fallback, and the
OpenAI device-code flow for headless machines):

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
  lookup, and `plugin` may name a component that hooks provider-specific
  tools. On every switch the component publishes
  `ev.provider.switch {nickname, previous, source, at}` so such plugins can
  enable or hide their tools. Every registry mutation also publishes the
  secret-free `ev.provider.changed {op, nickname, active, source, at}` for
  interactive clients to invalidate their provider/model views.
- The `active` marker is a plain store doc — remove or overwrite it with
  `store` tools if you need manual surgery.

## Fetch

The `fetch` component is the web access tool (a port of the old niffler
`fetch` tool). One tool:

| Tool | What it does |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH an http(s) URL; HTML → clean text via Trafilatura or a pure-Nim fallback; follows redirects; enforces caps |

- `convertToText` (default true) extracts readable text from HTML — JSON
  payloads are always returned verbatim.
- If `trafilatura` is on `PATH`, fetch gives it the already-downloaded HTML
  for higher-quality main-content extraction (bounded to 30 seconds). Missing,
  failed, timed-out, or empty extraction falls back to the built-in
  `htmlparser` walk. Set `NIF_TRAFILATURA` to an executable path/name to
  override detection, or `off` to disable it.
- Responses are capped at `maxSize` (default 10 MiB, max 50 MiB); content
  over 200 KB after processing is written to a file under `$NIF_FETCH_DIR`
  (default `$NIF_ROOT/var/fetch`) and the tool result points at it, so the
  agent reads large pages with its own file tools instead of blowing the
  conversation.
- Errors (non-2xx, timeouts, oversized responses, invalid URLs/methods)
  come back as `ok: false` with the status and a body snippet.
- Read-only network access — no approval gate (like `plugin_search`).

## Progressive tool discovery (`discover`/`invoke`)

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

Hidden takes precedence if both flags are present. Exposure is not an ACL:
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

`discover` and `invoke` are direct core tools in every new conversation.

#### Hints

```json
{"query": "web"}
```

`query` is optional and matches component names, tool names, and descriptions
case-insensitively. The result is deterministic: components and tools are
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

With the complete shipped manifest, 13 tools are direct:

- Core: `discover`, `invoke`.
- Routine work: `bash`, store `get`/`list`, `grep`/`files`, and the file
  tools `read`/`edit`/`write`/`undo_last_edit` (the `edit` component).
  Anchored block moves (the niffler-hashline plugin) register
  `hashline_replace`/`hashline_undo` as onDemand: run `discover`/`invoke`
  against them once installed.
- Skill entry points: `skill_list`, `skill_load`.

The long tail is on demand:

- Core lifecycle/status/catalog, builder, plugins, and fetch.
- Models and provider administration.
- Observe and logfile diagnostics.
- Skill resources, online search, install, and remove.

Internal tools remain hidden: core `session`, store `put`/`del`, LLM `chat`,
and credential-bearing `provider_active`.

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
- A small embedded seed makes a first offline boot useful.
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
models.dev shape is preserved, including fields Niffler does not yet use.

The component refreshes at startup and hourly. A models.dev download is
skipped while its cache is younger than five minutes. HTTP fetches are bounded,
retried, validated (a catalog with no usable model entries is rejected, so a
malformed response cannot replace the last-known-good cache), and atomically
renamed into `var/models/api.json`. Each registered plugin source also has a
last-known-good patch under `var/models/sources/`; that patch is used when the
source temporarily fails, but only while the source component remains
registered. The local override keeps its previous patch when the file is
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
| `models_refresh` | queue a refresh of models.dev and every live extension source |
| `models_sources` | provenance, freshness, stale fallback, and error diagnostics |

`models_list {status: "active"}` also matches models whose status field is
absent (models.dev omits it for normal models). List results are trimmed when
they would exceed the bus payload limit, and an oversized single descriptor
errors instead of timing out on the wire. Descriptor metadata is recursively
redacted: secret-like keys (api keys, tokens, passwords, credentials,
authorization headers, private keys, cookies) never reach a caller, at
provider or model level.

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

`models` discovers marked tools from `reg.publish` and from core's full catalog
snapshot, so component boot order does not matter. It calls the tool with
`{"version": 1}`. The result is:

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

Minimal Nim source component:

```nim
import niffler/sdk

let comp = newComponent("my-models", "0.1.0")
comp.tool(%*{"hidden": true}):
  proc my_models_source(version: int = 1): JsonNode =
    ## Add or correct model catalog data for My Provider.
    ## - version: models source protocol version
    %*{"patch": {
      "my-provider": {
        "id": "my-provider",
        "name": "My Provider",
        "env": ["MY_PROVIDER_API_KEY"],
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.example.com/v1",
        "models": {
          "my-model": {
            "id": "my-model",
            "name": "My Model",
            "reasoning": true,
            "tool_call": true,
            "modalities": {"input": ["text"], "output": ["text"]},
            "limit": {"context": 200000, "output": 32000},
            "cost": {"input": 1.0, "output": 5.0}
          }
        }
      }
    }}

comp.tools[^1].schema["x-models-source"] = %*{"version": 1, "priority": 200}
comp.run()
```

Put that component in a normal `niffler.json` package. Installation, update,
removal, process isolation, and persistence are already handled by the existing
`plugins` and core lifecycle. Removing the source component immediately removes
its patch from the effective catalog. No model-specific extension mechanism is
added to core.

### Configuration

Configuration variables (`NIF_MODELS_*`) are listed in the master
[Environment variables](#environment-variables) table above.

The component only reports which credential environment names a provider uses
and whether one is set. It never returns credential values. Provider-specific
OAuth, ambient credentials, headers, request transformations, and native API
behavior belong in inference adapter components, which can be shipped or
installed as plugins independently of this catalog.

---

## System prompt (`systemprompt`)

Status: **implemented** by the `systemprompt` component.

### Boundary

The system prompt is not a tool the LLM calls — it is the standing
instruction set every conversation starts under. It lives in a component,
not in core: core keeps only a minimal structural fallback, and a session
runner fetches the real constitution from `svc.systemprompt.call` once per
conversation. Replacing the constitution is a normal Niffler operation:
write a component that answers on the same subject, `builder.build`,
`core.kill` the old one, `core.spawn` yours. The agent can do this to
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
     ancestor walk would otherwise apply the same logical repo scope twice.

The tool is `x-harness.hidden` — it never appears in an LLM toolset; it is
infrastructure, reachable only by core and by components.

## Observation and logs (`observe`, `logfile`)

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
| `observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns |
| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |
| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated and limited to 30 seconds |

`observe_send` cannot send call/result/error envelopes or registrations.
`observe_send`, `observe_request`, and the filesystem-mutating `observe_dump`
carry `x-harness.approval: always`, so an LLM path must pass core's human gate.
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
then writes:

```text
var/nats-url
var/nats-monitor-url
```

The monitor discovery file is written only after the client connection succeeds.
A reused or remote bus has no discoverable HTTP endpoint; configure
`NIF_OBSERVE_MONITOR_URL` explicitly. `NIF_NATS_SPAWN=1` forces an isolated
core-owned bus (primarily useful for tests and diagnostics) — only when
`NIF_NATS_URL` is unset; an explicit URL always wins.

`observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each
request. It reports whether subscription detail was truncated; `mostSubscribed`
means subscriber density, not message throughput.

#All `NIF_OBSERVE_*`, `NIF_LOGFILE_*` and `NIF_LOG_LEVEL` variables are
listed in the master [Environment variables](#environment-variables) table above.

All bounds are validated at startup; invalid configuration exits non-zero
rather than silently substituting a default.

All bounds are validated at startup; invalid configuration exits non-zero rather
than silently substituting a default.

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
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | Run one LLM-written Nim program in `var/bin/fabric-exec` (embedded Nim VM, fresh process per program). `code` is inline program source; `name` runs a stored program from the model-curated `fabricprog` library instead. With `tools`, selected schemas are pinned and generate compile-time-checked `tools.<name>(...)` wrappers; allowlisted `callTool` remains the fallback. Only `finish(value)` reaches the conversation. |
| `agent_run {task, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | Run a task in a fresh subagent session (own runner, own loop) and return its final reply. Optional per-job budgets: `maxRounds` (tool rounds per turn, 1-20), `maxCalls` (total tool dispatches, 1-500), `maxTokens` (cumulative tokens) — exhaustion ends the turn as a budget-exhausted failure. |
| `agent_spawn {task, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | Start the same kind of task in the background; returns `{jobId, sessionId}` immediately. `timeoutMs` is the job budget: once exceeded the job is cancelled (agent_stop semantics) the next time it is observed. |
| `agent_status {jobId}` | Non-blocking durable job lookup (running/done/failed/stopped + reply or error). |
| `agent_wait {jobId, timeoutMs?}` | Block until a background job is terminal; late waits read the durable record. |
| `agent_stop {jobId}` | Cancel a running job for real: the child's LLM request is aborted, its turn ends promptly, and an in-flight bash command is killed (whole process tree). The terminal record says "stopped". |
| `agent_steer {session_id, message}` | Inject a message into a running background job's turn (drained between LLM rounds). |

- **Governance, not sandbox**: the guest is in bash's trust class — the human
  approves the program once (`x-harness.approval: always`). Every nested call
  crosses the session nested-call proxy (`svc.session.<id>.tool`), re-entering
  the single dispatch gate (approval, complete schema validation, deadline).
  The executor child holds no NATS connection and no credentials.
- **Approval manifests**: program approvals show a source digest, the full
  program under `var/approval-sources/<digest>.nim` (mode 0600), the selected
  tools, and the declared budgets. Persisted auto-approve is keyed by
  `fabric:<digest>` — approving one program never covers a different one.
- **Guards**: proxy rejects hidden tools and internal/recursive surfaces
  (`fabric`, `agent`, `chat`, `session`, `invoke`, `session_prepare`); a
  per-turn lease expires stale requests; `maxCalls` budgets calls;
  `x-harness.noSpawn` denies subagent spawns from subagents at dispatch time.
- **Context economy**: intermediate results never enter the conversation;
  oversized `finish()` values spill to `var/fabric-artifacts/<run>.json`
  (mode 0600) and the tool result points at the path.
- **Guest API**: `fabricguest.nim` provides the raw bridge (`callTool`,
  `batch`, `finish`, `logg`, `stringArg`, and import-free `j*` helpers).
  `fabricmeta.nim` turns pinned runtime schemas into input-typed wrappers;
  results are `JsonNode` unless the tool declares a scalar `outputSchema`.
  Worked examples: `components/fabric/examples/`.
- **When to use what**: direct loop for judgment-per-step work; `fabric` for
  mechanical known-shape orchestration; `agent_run` for exploratory subtasks
  that need their own context; hybrid programs may call `agent_run`.

## Expert advisory peer (`expert`)

The `expert` component is a non-interactive advisory peer (design:
[EXPERT.md](../EXPERT.md)). It follows ONE working session — armed explicitly
with `expert_follow {session_id}` (approval-gated, off by default) — watches
that session's `ev.session.*` events into a bounded in-memory current-turn
frame, and asks an LLM judge (a stateless hidden-`chat` call: fixed
cache-stable knowledge prefix + one ephemeral observation, no tools) whether
the evidence warrants a steer. Only high-confidence steers naming live,
non-hidden tools are delivered, through the turn-bound
`svc.session.<id>.advise` request/reply surface: the runner accepts advice
only while that exact turn is still running — late advice is rejected
(`stale-turn`/`no-active-turn`), never queued into the next turn. Accepted
advice is folded as a marked user message (`[Niffler advisor: expert] ...`),
persisted, and announced on `ev.session.advice`.

| Tool | What it does |
|---|---|
| `expert_follow {session_id, model?}` | Follow one session (1:1); captures the non-hidden catalog into the knowledge prefix. Approval-gated. |
| `expert_unfollow` | Stop following and drop the observation frame. |
| `expert_reload` | Rebuild the knowledge prefix from the live catalog (new cache epoch). |
| `expert_status` | Target, active turn, inference state, and bounded counters (judgments, silences, steers, accepted, rejected, staleDrops, errors). |

Design invariants: the working session never waits for the expert
(best-effort, cooldown, latest-state coalescing); no growing expert
transcript (every judgment is stateless); fail closed (any parse/validation/
transport error is silence); the expert never acts — it only suggests, and
approval-gated work stays with the working session's human gate.

## Recovery — `--recover`

The repo is the snapshot; `var/` is disposable build output. If the agent
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

For damage to *sources* (someone edited `components/`, `core/` or `sdk/`):

```bash
# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)
git restore components/ core/ sdk/      # or: git checkout -- .
make build
./var/bin/niffler                       # or just reopen the UI
```

## The store

`store` is a component like any other — a document store over the bus with
`put` / `get` / `list` / `del` and rev-based optimistic concurrency
(`put` accepts `expectRev` and fails with `rev-conflict` on mismatch).
Kinds in use by core:

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` |
| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` — install record of the `plugins` component |

Backend is an embedded BitBarrel (bitcask-style) at `var/barrel-db`.
**Exactly one process owns that file** — never run two `store` processes
against the same barrel (a second core booted against the same root would
do exactly that; use a temp `NIF_ROOT` copy for experiments).

## Testing

```bash
make test        # the whole bus-contract suite (spawns its own NATS per test)
make test-bash   # ... or just one: test-store, test-builder, test-console,
                 # test-plugins, test-skills, test-fetch, test-models,
                 # test-observe, test-logfile, test-core, test-cli,
                 # test-autostart, test-smoke
```

Each test boots the real component binaries (Nim, Go *and* TypeScript —
the envelope is the artifact, so one harness tests every SDK) and drives
them over a private NATS server whose loopback ports are allocated by NATS.
Core-based tests snapshot their required binaries into a unique temporary
`NIF_ROOT`; Barrel, plugin clones, generated components, logs, and caches are
therefore isolated. Individual `make test-*` targets may run concurrently
with each other and a live development harness. Repository build writes are
serialized, while agent-built test components use sandbox-local Nim caches.
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
  127.0.0.1:4222 for a live core; if none answers, spawn `var/bin/niffler`
  detached with `NIF_AUTOSTART=1`. The repo root is baked in at `make ui`
  time (ldflags), so the installed icon works as well as the in-tree binary.
- **Interactive plugins** (e.g. `niffler-tui`) — they do **not** call
  `ensureHarness` and never spawn a harness: they probe for a live bus
  (`NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222), connect and register
  `client: true` (so an autostarted core stays up while they run). Start the
  harness first — desktop UI or `./var/bin/niffler`.
- **Terminal admin shell** — `./var/bin/niffler` directly, or
  `./var/bin/niffler --minimal` for the three-component boot profile. A
  manually started core never self-terminates; stop it with Ctrl-C / SIGTERM.

Interactive frontends register `"client": true` (the SDK's `interactive()`
/ `Component.Client` marker). An **autostarted** core counts them: when the
last one departs it shuts down after `NIF_AUTOSTART_IDLE_S` (default 10s —
a restarting UI re-registers inside that window), taking its components and
spawned bus with it; if none ever arrives it gives up after
`NIF_AUTOSTART_BOOT_S` (default 60s). Closing a UI that attached to a
*manually* started core changes nothing — the core stays up.
`NIF_ENSURE_ATTACH=0` makes `ensureHarness` spawn unconditionally (tests).

## Common tasks

```bash
./var/bin/niffler             # full harness in a terminal (admin shell)
./var/bin/niffler --minimal   # store + bash + llm only at boot
niffler-ui                    # desktop UI; autostarts the full profile
make build          # rebuild what changed
make test           # the bus-contract suite (each test owns a private bus)
make doctor         # check prerequisites
make clean          # remove all build artifacts (var/, nimcache/, UI build)
```

- **Headless service mode** (no tty, for UIs/automation):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` —
  serves `svc.core.call`; approval-requiring tools are denied unless a UI
  is attached or `NIF_AUTO_APPROVE=1`.
- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222` (even remote).
- **Probe the bus** without the LLM: one-shot `nim c -r` scripts in
  `tests/` (see AGENTS.md "Debugging the bus").
- **Wails**: build only with `wails build -tags webkit2_41` (Linux);
  plain `go build` produces a stub. `make dev` runs the SPA in a browser
  with the bridge stubbed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI shows "Running in a browser" inside the desktop app | `nats.ts` binding mismatch — `window.go.main.Bridge` must match the Go struct name (ui/README.md) |
| UI banner: bus unreachable | core autostart still in progress or failed — start `./var/bin/niffler` in a terminal to see boot errors |
| `core: WARNING missing binary for <name>` on boot | run `make build` |
| llm error HTTP 401/403 | `NIF_OPENAI_API_KEY` missing or wrong — check `.env` and shell env |
| "approval denied" in headless mode | expected: no human reachable. Attach the UI, use `make run`, or set `NIF_AUTO_APPROVE=1` knowingly |
| two stores fight over `var/barrel-db` | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |
| orphaned `nats-server` | only possible when its core was SIGKILLed (the exit defer was skipped) — kill the pid in `var/nats-pid`, else `pkill -f nats-server` |
| component crashes on boot, restarts in a backoff loop | `core.remove` it via the UI/terminal, or `make recover` |
| agent-modified sources | `git restore components/ core/ sdk/` then `make build` (see Recovery) |
