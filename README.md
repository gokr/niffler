# Niffler

[English](README.md) · [简体中文](README.zh.md) · [繁體中文](README.zh-TW.md) ·
[website](https://gokr.github.io/niffler/) ·
[Discord](https://discord.gg/ThJFEAJUAk)

This is Niffler (reborn), a minimalistic, self-extending agent harness similar in philosophy
to [Pi](https://pi.dev) or the new [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).
Niffler takes a completely different approach to
software composition though and relies on a Unix-style "components run as processes"
and use NATS as the communication plane. This allows components to be written in different
languages, be strictly isolated from each other, rewritten and restarted during runtime and even run remotely.

Niffler is meant to be cloned out and run using its own git repo as "home" so that it can extend itself.

The agent can add capabilities at runtime — writes source, compiles it with the `builder` component,
starts it via `core.spawn` — mid-conversation. Design rationale:
[docs/research/REBOOT.md](docs/research/REBOOT.md). Wire protocol:
[docs/WIRE.md](docs/WIRE.md).

```
core (Nim) ── NATS ──┬── store (Nim SDK)           ← persistence
                     ├── bash (Nim SDK)            ← shell execution
                     ├── builder (Nim SDK)         ← component compilation
                     ├── plugins (Nim SDK)         ← component ecosystem
                     ├── skills (Nim SDK)          ← Agent Skills (SKILL.md)
                     ├── fetch (Nim SDK)           ← web content retrieval
                     ├── models (Go SDK)           ← pluggable model catalog
                     ├── provider (Go SDK)         ← stored LLM provider registry
                     ├── llm (Go SDK)              ← streaming LLM adapter
                     ├── edit (Nim SDK)            ← read/edit/write file tools + undo
                     ├── grep (Nim SDK)            ← code search + file listing
                     ├── git (Nim SDK)             ← read-only repo inspection
                     ├── agent (Nim SDK)           ← subagent sessions
                     ├── fabric (Nim SDK)          ← programmable tool calling
                     ├── observe (Nim SDK)         ← live bus inspection
                     ├── logfile (Nim SDK)         ← rotating JSONL logs
                     ├── cli (Nim SDK)             ← on-demand script client
                     ├── console (Nim SDK)         ← on-demand bus viewer
                     └── your tool (any language with an SDK port)
```

Core speaks exactly one protocol (JSON envelopes over NATS, see
[docs/WIRE.md](docs/WIRE.md)); every listed capability is a separate process
component with its own language's SDK, not code compiled into core.

On a normal boot, `manifest.yaml` autostarts `store`, `bash`, `builder`,
`plugins`, `skills`, `fetch`, `models`, `provider`, `llm`, `edit`,
`grep` (four stateless queue-group replicas), `git`, `observe`, `logfile`,
`agent` and `fabric`. The Nim SDK
powers all of those except Go-based `models`, `provider` and `llm`; `cli` and `console` are built-in Nim
clients run on demand. A minimal non-streaming Go adapter, `llm-openai`, ships
as a swap-in example. The TypeScript SDK (`sdk/ts`) means the agent can also
add Node.js components mid-conversation.

Operating guide: [docs/MANUAL.md](docs/MANUAL.md) (env vars, `.env`, the bus,
approvals, recovery, troubleshooting, and reference chapters for discovery,
models, observation/logs, providers, fetch, plugins, skills, fabric and
subagents). Changelog: [CHANGELOG.md](CHANGELOG.md).

## Quickstart

```bash
git clone https://github.com/gokr/niffler.git && cd niffler
make setup              # prerequisites for your platform
make                    # build everything, once
ui/build/bin/niffler-ui # the desktop UI; or:
make ui-install         # install the launcher + app icon (Linux), then click it
```

Build once, then launch the UI — the desktop app autostarts core if it isn't
running (via the SDK's `ensureHarness`), and the **last interactive client to
close stops a harness it autostarted**. Note that the `niffler-tui` plugin
does *not* autostart anything: it attaches to an already-running harness
(like any bus client, it probes `NIF_NATS_URL` → `var/nats-url` → 4222).

Using multiple UIs in parallel? Start core manually with
`./var/bin/niffler`; its admin shell stays up until you stop it. Then launch
as many UIs as needed.

## Prerequisites

Core + components need **Nim >= 2.2.10**, **Go**, and native development
libraries for NATS C and LZ4. Futhark also needs Clang/libclang to generate
bindings. The NATS bus server is built from source as a component
(`components/nats` → `var/bin/nats-server`). TypeScript components and the desktop UI additionally need **Node/npm** (the
builder's `lang: "ts"` pulls typescript from the npm registry per build);
the UI also needs the **wails CLI** and (on Linux) WebKit/GTK dev
libraries.

On a minimal Ubuntu image, install `make` first (`sudo apt update && sudo apt install make`).

```bash
make setup    # installs native prerequisites, toolchains and Nim packages
make doctor   # checks what's installed and what's missing
```

The Makefile finds wails in `~/go/bin` even when it's not on PATH. The
commands below cover the build prerequisites. `setup` also installs optional
dialog tools. Keep `~/.nimble/bin` on your shell PATH for Nim and Futhark's
`opir`; the Makefile adds it for its own commands.

### Ubuntu 24.04+

```bash
# Go — or download from https://go.dev/dl
sudo snap install go --classic

# Native build dependencies (install before Nim packages)
sudo apt update
sudo apt install build-essential curl ca-certificates git pkg-config libssl-dev clang libclang-dev libnats-dev liblz4-dev

# Complete Nim toolchain (Ubuntu's apt package is too old)
curl -sSf https://nim-lang.org/choosenim/init.sh | sh -s -- -y 2.2.10
export PATH="$HOME/.nimble/bin:$PATH"

# nats-server — built from source by `make build` (components/nats), no install needed

# Node/npm (frontend; wails runs `npm install` itself). Ubuntu 24.04 ships
# node 18, which is fine. Older Ubuntu versions need NodeSource or nvm —
# see docs/MANUAL.md.
sudo apt install nodejs npm

# Wails CLI (lands in ~/go/bin — the Makefile finds it there)
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Wails build deps: webkit2gtk 4.1, GTK3, build tooling
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev
```

### macOS (Homebrew)

```bash
# Install Xcode command-line tools first: xcode-select --install
brew install go node pkg-config cnats lz4 llvm
export SDKROOT="$(xcrun --show-sdk-path)"
export LIBRARY_PATH="$(brew --prefix)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
curl -sSf https://nim-lang.org/choosenim/init.sh | sh -s -- -y 2.2.10
export PATH="$HOME/.nimble/bin:$PATH"
go install github.com/wailsapp/wails/v2/cmd/wails@latest   # → ~/go/bin/wails
```

No extra GUI libraries on macOS — Wails uses the system WebKit. The Makefile
sets `SDKROOT` and the Homebrew library search path too; keep the exports
above when invoking Nim/Nimble directly from your shell.

`fabric-exec` embeds the Nim VM and needs the matching compiler sources,
including `dist/checksums`. Homebrew Nim 2.2.10 omits that directory;
use choosenim or another complete Nim >= 2.2.10 distribution. This
requirement applies on both platforms. `make install-nim`
checks an existing toolchain and reports incompatibilities rather than
replacing it.

### Nim packages

Niffler's Nim dependencies are declared in `niffler.nimble`. After installing
the native prerequisites and Nim, run:

```bash
make install-nim-deps   # nimble install -y --depsOnly; included in make setup
make doctor
make build             # core + components; use make for the desktop UI too
```

`make build` compiles with installed dependencies; it does not install Nim
packages. After changing `niffler.nimble`, rerun `make install-nim-deps`.

## Running

| Command | What it does |
|---|---|
| `ui/build/bin/niffler-ui` | the desktop UI — autostarts core if needed; the last UI stops an autostarted core |
| `make ui-install` | installs `niffler-ui` to `~/.local/bin` + the launcher/app icon (Linux); `make ui-uninstall` removes it |
| `./var/bin/niffler` | the harness in a terminal: admin shell, never self-terminates |
| `./var/bin/niffler --minimal` | minimal boot profile: only `store`, `bash`, and `llm` services |
| `make build` | core + components only (skip the desktop UI) |
| `make run` | build, then the harness with the tty admin shell (status commands) |
| `make down` | stop any running harness, components and nats-server (e.g. a stray core holding the store lock) |
| `make test` | the bus-contract test suite (each test spawns its own bus) — `make test-<comp>` runs one component contract, including `test-grep`, `test-git`, `test-edit`, `test-models`, `test-observe`, and `test-logfile` |
| `make recover` | stop everything, rebuild shipped binaries, wipe spawned-component records, restart (see Recovery below) |
| `make dev` | Svelte dev server in a browser (bridge stubbed) |
| `make clean` | remove all build artifacts |

### Minimal boot profile

`./var/bin/niffler --minimal` starts the smallest useful persistent agent
profile:

| Component | Why it remains |
|---|---|
| `store` | conversation/message persistence and component records |
| `bash` | one general-purpose machine tool |
| `llm` | OpenAI-compatible model access and streaming |

Core and the NATS bus still run, and the system starts one ephemeral `session`
runner when a conversation is first used; those are control-plane processes,
not manifest services. The other shipped services — including `builder`,
`models`, `provider`, file tools, plugins/skills, and observation/logging — stay
stopped. Persisted agent-added components are not restored in this mode, but
their records are left untouched and return on the next normal boot. This is a
boot profile, not a lockdown: `core.spawn` can still start a component later.

With no `provider` or `models` service, `llm` uses the environment/`.env`
directly:

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

`NIF_OPENAI_CONTEXT` is optional; without it, `llm` uses its small built-in
model table and then a conservative 128K fallback. The desktop UI always
autostarts the normal profile, so start `--minimal` manually first and then
launch the UI; it will attach to the already-running core. `--minimal` can be
combined with `--recover`.

**Testing.** `make test` runs the whole suite: one script per non-LLM
component, each booting a private NATS server and driving a snapshot of the
real binaries over the bus (the envelope is the artifact — the same harness
tests Nim and Go components). Writable state lives under a unique temporary
`NIF_ROOT`, so component targets may run concurrently with each other and a
live development harness. Opt-ins: `NIF_TEST_INSTALL=1` installs
`gokr/niffler-weather` for real and validates its tools; the install
pipeline itself is covered hermetically via a local `file://` git repo.
Details in [docs/MANUAL.md](docs/MANUAL.md#testing).

**Harness autostart.** Any UI's first act is the SDK's `ensureHarness`:
probe for a live core (`NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222),
else spawn `var/bin/niffler` itself (`NIF_AUTOSTART=1`). Interactive
frontends register `"client": true`; an autostarted core exits when the
last one departs. Core itself reuses a bus on the default port when one is
live, else spawns the built nats-server component (`var/bin/nats-server`)
there (falling back to a random loopback port
when 4222 is taken) and writes `var/nats-url`. Set `NIF_NATS_URL` to attach
to any bus, even a remote one.

**Approvals.** Tools that change the machine or the harness — including
`bash`, `builder.build`, `edit`/`write` (mutating file tools), and
`core.spawn`/`kill`/`remove` — carry `x-harness.approval: "always"` and are
gated on a human: a y/N prompt in the terminal harness, a dialog in the web
UI. In a session the request is routed to the specific interactive component
driving the conversation (its private `svc.approval.<name>.request` subject,
derived from the call's self-declared `caller`), with a broadcast fallback
if that client is gone. Headless (no UI attached) calls are denied — never
silently approved. `NIF_AUTO_APPROVE=1` bypasses the gate (see
[docs/MANUAL.md](docs/MANUAL.md)).

**Secrets.** `.env` (gitignored) holds `NIF_OPENAI_API_KEY` and
`NIF_OPENAI_BASE_URL` (DeepSeek by default); an existing shell env always
wins. Service mode (no tty): `NIF_NATS_URL=... NIF_OPENAI_API_KEY=...
./var/bin/niffler < /dev/null`.

## Layout

```
docs/                MANUAL.md (operating guide), WIRE.md (wire protocol),
                     ARCHITECTURE.md (core boundary), FABRIC_GUIDE.md,
                     PLAN.md (open work), research/ (design history)
manifest.yaml        bootstrap component manifest
sdk/envelope.nim     envelope codec (std/json, portable by design)
sdk/niffler/         Nim component SDK (~250 lines)
sdk/go/              Go component SDK (mirror of the Nim one)
sdk/ts/              TypeScript/Node.js component SDK (mirror, npm package)
core/                catalog, supervisor, dispatch, conversation loop
components/          Nim: store, bash, builder, plugins, skills, fetch,
                     edit (read/edit/write file tools), grep, git,
                     observe, logfile, agent, fabric, cli, console;
                     Go: models, provider, llm + llm-openai example
tests/               bus-contract suite: helpers + one t_*.nim per component
ui/                  web SPA over NATS — direction + Wails bridge design
var/                 runtime: binaries, build cache (gitignored)
```

## Persistence

`store` is a component like any other — a dumb document store over the bus
(`put/get/list/del`, rev-based optimistic concurrency). Backed by an
**embedded BitBarrel** (Bitcask KV, critbit index) in critbit mode; exactly
one process owns the barrel file (`var/barrel-db`), everything else talks
envelopes — so backend choice is contained and swappable (a store-tidb
variant with FTS/vector later is a drop-in with the same tools).

Barrel's pubsub is deliberately **not** used — NATS is the one and only
bus. Kind keys: `component`, `conversation`, `message`, `plugin` (the
plugins component's install records). Core persists spawned components
(restored on normal boot; `--minimal` deliberately leaves them stopped) and
conversation messages.

**Recovery.** The repo is the snapshot; `var/` is disposable build output.
If a component is damaged — overwritten binary, broken self-added
component, corrupted record — `make recover` rebuilds the shipped binaries
from source, wipes the spawned-component records and starts fresh
(conversations survive). See docs/MANUAL.md.

## Writing a component

Nim — `import niffler/sdk`, typed tool pattern (doc comments become the schema):

```nim
import niffler/sdk

let comp = newComponent("weather", "0.1.0")
comp.tool:
  proc weather(city: string): JsonNode =
    ## Current weather for a city
    ## - city: the city name
    %*{"temp": 21}
comp.run()
```

Go — `import sdk "niffler.dev/sdk"` with the same surface
(`Tool`, `On`, `Emit`, `Request`, `Run`).

TypeScript — runs under Node.js (`import sdk from "niffler-sdk"`,
same surface, handlers may be async):

```ts
import sdk from "niffler-sdk";
const comp = sdk.newComponent("weather", "0.1.0");
comp.tool("weather", {
  type: "object",
  description: "Current weather for a city",
  properties: { city: { type: "string" } },
  required: ["city"],
}, async (_c, args: any) => {
  return { temp: 21, city: args.city };
});
comp.run();
```

Other languages: port the SDK — the envelope is the artifact (~200 lines).

Then: `builder.build {lang, name, source}` →
`core.spawn {name, binary, replicas?}` → the tool is live. `replicas` (1–16)
is only for stateless/externally coordinated components; NATS distributes
calls across their identical processes. Retire the group with
`core.remove {name}` (kill it temporarily
with `core.kill {name}`). The agent does this itself, mid-conversation —
that is the architecture's validation criterion.

## Component ecosystem

Third-party component packages are distributed as plain GitHub repos — one
repo = one package = N components, with a `niffler.json` manifest at the
root. Repos tagged with the GitHub topic
[`niffler-component`](https://github.com/topics/niffler-component) are
discoverable from inside a conversation (say "find me a weather
component") or via `plugin_search`; `plugin_install {repo}` clones the
repo into `var/plugins/<pkg>@<ref>/`, compiles each component from source
via the `builder` (the same path agent-written components take — no extra
toolchain, every platform builds with its own), then `core.spawn`s every
service component (human-approved). Go components can list additional
same-package files in a manifest `"sources"` array. Components marked
`"interactive": true` are built into `var/bin` but not spawned; the user
starts them in a terminal.
`plugin_update` / `plugin_remove` manage installed packages; installs survive
restarts via the store's `plugin` records.

Example package: [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather)
(Open-Meteo weather, no API key). Its README documents the manifest
format; its release workflow dogfoods — it boots a harness and drives it
with the **cli component** (`./var/bin/cli`: `catalog` / `wait` / `call`
/ `install <repo>[@<ref>]`, exit 0 on success), so every tag proves the
package installs and its tools work. That cli flow is the preferred way
to CI any plugin repo — Niffler testing itself.

## Milestone status

Open work — deferred follow-ups and quests — is consolidated in
[docs/PLAN.md](docs/PLAN.md).

- [x] wire spec, envelope, Nim + Go + TypeScript SDKs
- [x] supervisor (spawn/monitor/restart/drain), catalog, dispatch
- [x] bash + builder components, llm adapter (streaming OpenAI-compatible) in Go
- [x] typed tool definitions (nimcp-inspired: schema + handler from a proc)
- [x] **agent adds itself a tool end-to-end** (docs/research/REBOOT.md milestone, live
      test with DeepSeek: wrote → built → spawned → called `greet`)
- [x] **store component** — barrel-backed document store over the bus
      (put/get/list/del, rev-based optimistic concurrency); core persists
      conversations, messages and spawned components; spawned components
      restore on boot (persistence of shape, verified live across restarts)
- [ ] **code hygiene + store v2** — `feat/code-hygiene` branch
      (docs/research/STORE_V2.md): SDK storeclient/config/http helpers +
      duplication cleanup; three interchangeable store engines behind one
      contract (barrel stays default; Go SQLite + TiDB engines with goose
      migrations, picked via NIF_STORE_BACKEND); DuckDB as a bus observer.
      **SQLite + TiDB engines landed**: `components/store-sqlite` and
      `components/store-tidb` (Go, goose, `NIF_STORE_BACKEND=sqlite|tidb`,
      `make test-store-sqlite` / `test-store-tidb` green against live TiDB)
- [x] **session service** — svc.core.call `session` turns + ev.session.*
      events; service mode (no tty) for UIs; verified live
- [x] **session runners** — one conversation = one process: the system
      ensures `var/bin/session <id>` per session and forwards turns to
      `svc.session.<id>.call`; runners are ephemeral, resume from the
      store, and killing one loses only the in-flight turn (verified
      live: fresh runner + resume + clean drain)
- [x] **Wails SPA shell** — Go bridge (bus citizen), Svelte 5 chat:
      sessions from the store, live tool cards, markdown, conversation
      resume, model/token/context display; builds + verified end-to-end
- [x] **approvals** — x-harness.approval interceptor in dispatch: terminal
      prompt (tty) or caller-directed UI approval with ack, broadcast fallback,
      and `ev.approval.resolved` cleanup; deny when no human is reachable;
      verified end-to-end (service + tty probes)
- [x] **recover mode** — `--recover` / `make recover`: rebuild shipped
      binaries from source, wipe spawned-component records, keep conversations
- [x] **minimal boot profile** — `--minimal` starts only `store`, `bash` and
      `llm`, uses `NIF_OPENAI_*` directly, and leaves persisted extra
      components stopped without deleting their records
- [x] **plugins component** — ecosystem discovery + install as a bus
      service: GitHub topic search, `niffler.json` package manifest, always
      builds from source via the builder (or `file://` local repos for
      hermetic installs), spawn/update/remove, store records;
      live-tested end-to-end with `gokr/niffler-weather`
- [x] **UI-owned lifecycle** — any interactive client autostarts core via
      the SDK's `ensureHarness`; an autostarted core exits when the last
      interactive client departs, a manually started one never does. No
      launcher scripts — the desktop icon is the whole system
- [x] **models component** — models.dev baseline with an embedded offline seed,
      validated atomic cache, strict model resolution, searchable capabilities/
      limits/pricing, and deterministic `x-models-source` plugin patches with
      last-known-good fallback; `llm` consumes its context metadata
- [x] **provider component** — store-backed LLM provider registry
      (add/list/switch/active/remove/export/import, keys never leaked on
      list), subscription OAuth logins (ChatGPT Codex + Claude Pro/Max:
      PKCE browser/device flows, transparent token refresh, refresh tokens
      never leave the provider component), `ev.provider.switch`
      notifications, and live backend switching:
      `llm` resolves its default provider from the active stored one and
      falls back to `NIF_OPENAI_*` / `NIF_LLM_PROVIDERS` when absent
- [x] **wire protocols** — `llm` routes per provider `protocol`:
      OpenAI-compatible Chat Completions, OpenAI Codex Responses
      (ChatGPT OAuth headers, Responses API translation, SSE event
      mapping) and Anthropic Messages (Claude Code identity headers,
      tool_use/tool_result block translation) — all sharing the same
      streaming result shape (`ev.llm.token`, tool calls, usage)
- [x] **grep + write components** — ripgrep-backed code search
      (`grep`: path:line:match results with .gitignore/hidden/binary handling;
      `files`: sorted repo listing) and approval-gated atomic whole-file
      writes (temp file + rename, permission preservation)
- [x] **observe component** — one exact raw-bus tap, bounded live ring and
      listen/trace probes, request/reply correlation, safe capture exports,
      and core-discovered nats-server monitoring
- [x] **logfile component** — structured `ev.log.*` events across all SDKs,
      rotating JSONL persistence, bounded newest-first search, raw whole-bus
      capture, and explicit sink-health reporting
- [x] **console component** — passive bus viewer: subscribes to everything
      and renders the wire traffic readably (run it in a second terminal)
- [x] **skills component** — Agent Skills (SKILL.md): discovery across the
      standard agent dirs, online skills.sh search (the `npx skills find`
      backend), progressive-disclosure load, on-demand resources, git-based
      install into `~/.niffler/skills` / project `.opencode/skills` (no Node
      needed), removal confined to Niffler-managed dirs
- [x] **fetch component** — the old niffler `fetch` tool as a bus service:
      http/https with methods/headers/body, Trafilatura-first HTML→text
      extraction with a pure-Nim fallback, redirects, timeout and size caps,
      oversized content spilled to `var/fetch` files
- [x] **cli component** — drive the harness from a terminal or a script
      (`catalog` / `wait` / `call` / `install`), exit 0 on success; the
      preferred way to CI a plugin repo (niffler-weather's workflow uses it)
- [x] **core re-entry** — dispatch polls a private inbox and serves
      `svc.core.call` mid-turn, so a component calling back into core
      (`plugin_install` → `core.spawn`) cannot deadlock the session;
      concurrent session requests are stashed, never nested
- [x] **parallel tool waves + process replicas** — session runners fan out
      explicitly `x-harness.parallel` calls over distinct NATS inboxes and
      commit replies in model order; stateless logical components can declare
      or spawn 1–16 queue-group replicas for same-component concurrency while
      the default Nim SDK pump remains threadless (four `grep` replicas ship by
      default); audited Go tools can opt into bounded `ToolConcurrent`
      goroutines, enabled first for both LLM adapters
- [x] **bus-contract test suite** — `make test`: one script per non-LLM
      component (including models, observe, logfile, edit), each
      booting the real binaries over its own NATS; hermetic plugin installs
      via `file://`; network opt-ins behind `NIF_TEST_INSTALL`/`NIF_TEST_NETWORK`
- [x] **streaming** — `llm` adapter streams `ev.llm.token` deltas (content
      + reasoning), core forwards them as `ev.session.token`, the UI appends
      them to the live assistant bubble; per-call cancellation
      (`llm.cancel.<sessionId>`); final assistant event always carries the
      complete content
- [x] **hashline-edit** — hash-anchored `hashline_read`/`hashline_replace`/`hashline_undo`
      (Nim port of pi-hashline-edit-pro), anchors stable across edits; since
      extracted to the [niffler-hashline](https://github.com/gokr/niffler-hashline)
      plugin
- [x] **edit component** — the file tools: `read` (plain, pageable),
      exact-text `edit` as the primary editor:
      old_string uniqueness enforced (ambiguous matches refused with counts),
      several non-overlapping edits per call, guarded fallback cascade
      (trailing whitespace, indentation, unicode punctuation, block anchors,
      escaped text), `replace_all`, LF normalization, atomic `write`
      (merged in from the former write component), approval-gated,
      single-level per-file `undo_last_edit` persisted across restarts
- [x] **git component** — read-only repo inspection (`git_status`/`git_diff`/
      `git_log`/`git_show`/`git_blame`): approval-free, fixed argv (no shell),
      path-scoped to the harness root with argument validation, capped output
      with narrowing hints, clean not-a-repo handling; mutations stay in bash
- [x] **TypeScript SDK** — sdk/ts (npm package, mirror of the Go SDK);
      the builder compiles `lang: "ts"` components via tsc into a node
      wrapper binary; verified live (builder → spawn → call from Node.js)
- [x] **progressive tool discovery** — one complete global catalog, but each
      conversation freezes a small immutable direct toolset (8 shipped);
      `discover` returns hints/full schemas into the append-only history and
      `invoke` calls any live non-hidden tool through the normal approval/
      timeout path (docs/MANUAL.md); UI Live Components panel colors
      direct/seen/demand/internal per active session (`tests/t_discover.nim`)
- [x] **directed approval routing** — approval requests route to the
      component driving the turn via its private `svc.approval.<caller>.request`
      (ack-gated, broadcast fallback when the driver is gone, `ev.approval.resolved`
      clears stale modals); call envelopes carry a self-declared `caller` across
      all four SDKs; web UI acks + answers on the private subject
- [x] **fabric + subagents** (docs/research/FABRIC.md) — programmable tool calling:
      the `fabric` tool runs an LLM-written Nim program in a VM-embedding
      executor child (fresh process per program, no NATS/credentials, RLIMIT
      + kill timeout); the guest's tool calls cross a framed stdio bridge to
      the parent and re-enter the single dispatch gate via the session
      nested-call proxy (`svc.session.<id>.tool`, live lease, hidden-tool and
      depth guards); monotonic deadlines, complete bounded schema validation,
      framed-data limits, and scoped lease restoration keep nested execution
      predictable; selected-tool mode pins canonical catalog fingerprints and
      generates input-typed `tools.<name>(...)` Nim wrappers at guest compile
      time (scalar `outputSchema` types wrapper returns); compile errors
      return as real Nim diagnostics; only the program's `finish()` value
      enters the conversation (oversized results spill to quota-managed 0600
      artifacts); the `agent` tool turns sessions into subagents (delegated
      child runners; synchronous `agent_run` + steer, durable background
      jobs via `agent_spawn`/`agent_status`/`agent_wait`/`agent_stop` with
      `ev.agent.*` events, dispatch-time depth guard); guests are lint-banned
      from IO/network/FFI and the VM refuses FFI magics (import-free j* JSON
      helpers, ~ms cold eval); correlated `ev.fabric.*` lifecycle events;
      worked examples in `components/fabric/examples/`
      (`tests/t_nested.nim`, `tests/t_schema_validation.nim`,
      `tests/t_agent.nim`, `tests/t_fabric.nim`)
- [x] **expert advisory peer** (docs/research/EXPERT.md) — one expert follows one working
      session: bounded current-turn observation from `ev.session.*`, a
      stateless LLM judgment over a cache-stable knowledge prefix (reviewed
      bundled skills `niffler-tools`/`niffler-fabric` plus the observed
      session's own frozen tool view, filling up to 80% of the judge
      context), and a turn-bound `svc.session.<id>.advise` request/reply
      (stale advice rejected, never queued into a later turn); steers are
      tool-selection corrections — component + exact tool to invoke, or a
      fabric program sketch; silent by default, fail-closed
      (`tests/t_expert.nim` with a scripted mock llm)
- [ ] Level 1 UI dynamism: x-ui schema hints + generic renderer registry
- [x] Web UI TUI-parity features: slash commands (built-ins + the plugin
  registry, Tab completion, did-you-mean), thinking/tool display cycles
  (Ctrl+T/E + header chips), per-conversation thinking effort (Ctrl+G +
  header chip), visible context gauge (bar, 75%/90% thresholds, survives
  resume), mid-turn steer, two-stage stop, /status provenance,
  /provider /provider-strip command routes

## Quests — things Niffler should do itself (or that we do on a slow day)

Tracked in [docs/PLAN.md](docs/PLAN.md); kept here for the flavor:

1. **store-sqlite comparison** — port components/store/main.nim to SQLite
   (e.g. nim-community/libsql), same tools, run both, compare. The contract
   is the artifact; Niffler can read its own sources (`bash cat …/store/main.nim`),
   build, spawn and benchmark the variant — a true dogfooding quest.
2. **node/TS component SDK** — port sdk/go (~200 lines) to TypeScript; lets
   the agent add JS tools without a compile step. (Done — sdk/ts + builder
   `lang: "ts"`; JS-without-compile via tsx remains a possible follow-up.)
3. **pipewrap** — stdio/NDJSON bridge so plain scripts become components.
4. **Level 2 UI dynamism** — builder compiles Svelte components to JS modules,
   catalog registers ui-modules, bridge serves var/ui/, SPA blob-imports
   (see ui/README.md).
5. **store-tidb** — same tools, SQL tables, FTS + vector search for
   conversation memory; sharing across harnesses/hosts.
6. **component package template repo** — the niffler-weather repo layout
   + release CI as a `gh repo create`-able template; optionally a curated
   index repo for `plugin_search` ranking.
