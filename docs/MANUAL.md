# Niffler Manual

Everything you need to operate, configure and recover a Niffler harness.
Design rationale: [REBOOT.md](REBOOT.md) · wire protocol: [WIRE.md](WIRE.md) ·
architecture boundary: [ARCHITECTURE.md](ARCHITECTURE.md).

## Layout of a running system

| Path | What it is |
|---|---|
| `core/` | the control plane (bus bootstrap, supervisor, catalog, dispatch, conversation loop) |
| `components/` | shipped component sources: `bash`, `builder`, `store`, `plugins` (Nim), `llm-openai` (Go) |
| `sdk/` | Nim SDK + `sdk/go` (Go SDK); the envelope in `sdk/envelope.nim` is the artifact |
| `docs/` | this manual + design docs |
| `manifest.yaml` | bootstrap manifest: which components core spawns, in what order, with what restart policy |
| `var/` | **runtime state, gitignored, disposable** — the repo is the snapshot |
| `var/bin/` | built binaries (core + components). Rebuilt by `make build` |
| `var/barrel-db` | the store's embedded KV file — **single-writer**: exactly one `store` process may open it |
| `var/nats-url` | bus address of the last spawned bus; the UI bridge reads it to find core |
| `var/nats-url`, `var/core.log` | written by `scripts/niffler.sh` when `make up` starts core |
| `var/.niffler.up` | state file of `scripts/niffler.sh` (core pid, whether core spawned the bus) |
| `var/build/` | source files of agent-built components (builder's scratch dir) |
| `nimcache/`, `ui/build/`, `ui/frontend/node_modules/`, `ui/frontend/dist/` | build artifacts; `make clean` removes them |

## Environment variables

All components load `.env` (from the harness root and cwd, existing shell
env always wins — see below) and inherit core's environment. The full set:

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | the harness root (repo). Core derives it from its binary location if unset, and sets it for all children. Components use it to find the SDK, `var/`, `.env`. Every component runs with **cwd = NIF_ROOT**, so the agent's `bash pwd` is always the home — regardless of where you launched the harness | `<binary location>/../..` |
| `NIF_NATS_URL` | bus to attach to. Unset → core reuses a live bus on `127.0.0.1:4222`, else spawns `nats-server` on a random loopback port and writes `var/nats-url` | auto |
| `NIF_OPENAI_API_KEY` | API key for the LLM adapter (`llm-openai`). Required for any conversation turn | — |
| `NIF_OPENAI_BASE_URL` | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | model name | `deepseek-chat` |
| `NIF_OPENAI_CONTEXT` | context window (tokens) the llm reports to core's context guard | `llm-openai`'s small built-in table (DeepSeek: 1M), else `128000` |
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
ev.session.assistant   {sessionId, content, model?, usage?}   (live model text)
ev.session.toolcall    {sessionId, tool, args, result|error}
ev.session.done        {sessionId, reply} | {sessionId, error}
ev.catalog.updated     full tool list after any registration change
ev.sys.drain           core → components: stop taking calls, finish, exit
ev.approval.request    core → UI: {id, tool, args} — human gate (see below)
ev.approval.reply      UI → core: {id, ok}
ev.cancel.<call-id>    cancellation signal (components may subscribe)
```

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
terminal or a script, CI-friendly (exit 0 on success):

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
`bash`, `builder.build`, `core.spawn`, `core.kill`, `core.remove` — are
gated on a human before they execute:

- **Terminal harness** (`make run`): a `[approval]` prompt with the tool
  name and arguments; answer `y`/`n`.
- **Web UI** (`make up`): a modal dialog appears with the same details;
  Approve/Deny answers go back over the bus (`ev.approval.request` /
  `ev.approval.reply`).
- **Neither** (service mode with no UI attached): the call is **denied**
  with a clear error — never silently approved.
- Unanswered UI requests time out after 5 minutes and are denied.
- `NIF_AUTO_APPROVE=1` bypasses the gate (headless automation).

## Context window

Core watches how much of the model's context window a conversation uses
and acts *trivially* — no summaries, no token math beyond what the model
reports:

- The window size (`context`) is informational, reported by `llm-openai` on
  every chat call: `NIF_OPENAI_CONTEXT` overrides it, else a small
  built-in table covers the default model family (DeepSeek: 1M), else a
  conservative 128K. There is no model database and nothing is fetched
  at runtime — the only window that matters is your configured model's.

- After every chat call the model's own `usage.prompt_tokens` and the
  window size (`context`, informational from `llm-openai`) are recorded
  and persisted with the assistant message, so the accounting survives
  restarts and session resume.
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
3. `core.spawn {name, binary}` starts it; it registers itself; its tools
   appear in the LLM's toolset on the next request
4. `core.kill {name}` stops it temporarily (restored on next boot);
   `core.remove {name}` stops it and deletes its persisted record

**Persistence of shape**: spawned components are recorded in the store
(kind `component`) and restored on boot. `core` itself, the bus, the
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
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`, build each component from source via `builder.build` (single-file SDK components), then `core.spawn` each (approved) |
| `plugin_update {package}` | to the latest release tag: remove, reinstall at the new ref |
| `plugin_remove {package}` | `core.remove` every component, delete the clone, drop the record |

- Install/update/remove all carry `x-harness.approval: "always"` — they
  run third-party code, and every individual spawn/remove is approved
  again by core. Never run them with `NIF_AUTO_APPROVE=1` unless you trust
  the publisher.
- The default ref is the latest release tag, else the default branch.
  `version` pins a tag or branch explicitly.
- Components always build from source via the `builder` — the same path
  agent-written components take. Running Niffler already provides the
  toolchain (Nim/Go, nats.c, libclang), so no extra requirements; every
  platform compiles with its own toolchain.
- Install records live in the store (kind `plugin`, id = package name);
  they are wiped by `--recover` like all component records — a fresh boot
  re-clones from the recorded repo/ref on reinstall.
- The GitHub API is used unauthenticated (60 req/h/IP).
- Publishing: add the `niffler-component` topic and tag releases
  (`v1.0.0`). The release workflow in the
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) sample
  dogfoods: it boots a harness and installs the package through
  `plugin_install`, so every tag proves the package installs cleanly.

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
2. **Wipes the store's component records** — spawned components are not
   restored; the harness comes back to the manifest set.
3. Boots normally (interactive). **Conversations and messages survive** —
   only the component shape is reset.

For damage to *sources* (someone edited `components/`, `core/` or `sdk/`):

```bash
make down
git restore components/ core/ sdk/      # or: git checkout -- .
make build
make up
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
                 # test-plugins, test-core, test-cli, test-smoke
```

Each test boots the real component binaries (Nim *and* Go — the envelope
is the artifact, so one harness tests every SDK) and drives them over the
bus. Core-based tests (`t_core`, `t_plugins`, `t_cli`) require **no other
harness running** against this repo's `var/barrel-db` (store
single-writer). Network opt-ins: `NIF_TEST_INSTALL=1` runs the real
`cli install gokr/niffler-weather` + tool validation; `NIF_TEST_NETWORK=1`
runs `plugin_search` against GitHub. The install pipeline itself is
covered hermetically by `t_plugins` via a local `file://` git repo.

## Common tasks

```bash
make up          # build (incremental), ensure bus + core, open the UI
make run         # terminal harness
make test        # the bus-contract suite (8 tests, each spawns its own bus)
make status      # what is running where
make down        # stop UI, core, and the bus core spawned
make doctor      # check prerequisites
make clean       # remove all build artifacts (var/, nimcache/, UI build)
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
| UI banner: bus unreachable | no core running, or `var/nats-url` stale — `make up` / `make status` |
| `core: WARNING missing binary for <name>` on boot | run `make build` |
| llm error HTTP 401/403 | `NIF_OPENAI_API_KEY` missing or wrong — check `.env` and shell env |
| "approval denied" in headless mode | expected: no human reachable. Attach the UI, use `make run`, or set `NIF_AUTO_APPROVE=1` knowingly |
| two stores fight over `var/barrel-db` | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |
| orphaned `nats-server` after `make down` | happens when components were killed directly — `pkill -f nats-server` |
| component crashes on boot, restarts in a backoff loop | `core.remove` it via the UI/terminal, or `make recover` |
| agent-modified sources | `git restore components/ core/ sdk/` then `make build` (see Recovery) |
