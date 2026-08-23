# Niffler

This is Niffler (reborn), a minimalistic, self-extending agent harness similar in philosophy
to [Pi](https://pi.dev) or the new [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). Niffler takes a completely different approach to
software composition though and relies on a Unix-style "components run as processes"
and use NATS as the communication plane. This allows components to be written in different
languages, be strictly isolated from each other and even run remotely.

Niffler is meant to be cloned out and run using its own git repo as "home".

The agent adds capabilities at runtime — writes source, compiles it with the `builder` component,
starts it via `core.spawn` — mid-conversation. Design rationale:
[docs/REBOOT.md](docs/REBOOT.md). Wire protocol: [docs/WIRE.md](docs/WIRE.md).

```
core (Nim) ── NATS ──┬── bash (Nim SDK)
                     ├── builder (Nim SDK)
                     ├── plugins (Nim SDK)   ← component ecosystem
                     ├── hashline-edit (Nim SDK)
                     ├── llm (Go SDK)
                     └── your tool (any language with an SDK port)
```

Core speaks exactly one protocol (JSON envelopes over NATS, see
[docs/WIRE.md](docs/WIRE.md)); everything else — bash, the builder, the LLM
adapter — is a separate process component with its own language's SDK.

The shipped set proves the multi-language point: `bash`, `builder`,
`store`, `plugins`, `hashline-edit`, `cli` and `console` are written
against the Nim SDK, while the LLM adapter `llm` is deliberately in Go —
and a TypeScript SDK ships too (sdk/ts), so the agent adds components in
any of the three languages mid-conversation.

Operating guide: [docs/MANUAL.md](docs/MANUAL.md) (env vars, `.env`, the
bus, approvals, recovery, troubleshooting). Changelog:
[CHANGELOG.md](CHANGELOG.md).

## Quickstart

```bash
make up
```

One command: builds core + components + the desktop UI, starts a bus and core
if none is running, and opens the Wails UI. Stop everything with `make down`.

Only the terminal harness? `make run`. Just build? `make` (or `make all`).

## Prerequisites

Core + components need **Nim**, **Go** and **nats-server**; TypeScript
components and the desktop UI additionally need **Node/npm** (the
builder's `lang: "ts"` pulls typescript from the npm registry per build);
the UI also needs the **wails CLI** and (on Linux) WebKit/GTK dev
libraries.

```bash
make setup    # installs everything for your platform (Ubuntu/macOS)
make doctor   # checks what's installed and what's missing
```

The Makefile finds wails in `~/go/bin` even when it's not on PATH. The
manual commands below are what `make setup` runs.

### Ubuntu 24.04+

```bash
# Go — or download from https://go.dev/dl
sudo snap install go --classic

# Nim 2.x (Ubuntu's apt package is too old) — adds ~/.nimble/bin to PATH
curl -sSf https://nim-lang.org/choosenim/init.sh | sh

# nats-server — or grab a binary from https://github.com/nats-io/nats-server/releases
go install github.com/nats-io/nats-server/v2@latest

# Node/npm (frontend; wails runs `npm install` itself). Ubuntu 24.04 ships
# node 18, which is fine. Older Ubuntu versions need NodeSource or nvm —
# see docs/MANUAL.md.
sudo apt install nodejs npm

# Wails CLI (lands in ~/go/bin — the Makefile finds it there)
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Wails build deps: webkit2gtk 4.1, GTK3, build tooling
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config libssl-dev
```

### macOS (Homebrew)

```bash
brew install go nim nats-server node
go install github.com/wailsapp/wails/v2/cmd/wails@latest   # → ~/go/bin/wails
```

No extra GUI deps on macOS — Wails uses the system WebKit. Ensure the Xcode
command-line tools are installed (`xcode-select --install`).

### Nim packages

Niffler's Nim dependencies are declared in `niffler.nimble` (`yaml`, plus
`gokr/natswrapper` and `gokr/bitbarrel` from GitHub) and installed
automatically by nimble on the first build (`make build`).

## Running

| Command | What it does |
|---|---|
| `make up` | build, ensure bus + core, open the desktop UI |
| `make down` | stop UI, core and the bus core spawned |
| `make status` | show what is running where |
| `make run` | the harness with the tty admin shell (status commands) |
| `make test` | the bus-contract test suite (8 tests, each spawns its own bus) — `make test-<comp>` runs one: test-bash, test-store, test-builder, test-console, test-plugins, test-core, test-cli, test-smoke |
| `make recover` | stop everything, rebuild shipped binaries, wipe spawned-component records, restart (see Recovery below) |
| `make dev` | Svelte dev server in a browser (bridge stubbed) |
| `make clean` | remove all build artifacts |

**Testing.** `make test` runs the whole suite: one script per non-LLM
component, each booting the real binaries and driving them over the bus
(the envelope is the artifact — the same harness tests Nim and Go
components). Core-based tests need no other harness running (store
single-writer). Opt-ins: `NIF_TEST_INSTALL=1` installs
`gokr/niffler-weather` for real and validates its tools; the install
pipeline itself is covered hermetically via a local `file://` git repo.
Details in [docs/MANUAL.md](docs/MANUAL.md#testing).

**Bus autostart.** With no `NIF_NATS_URL`, core reuses a bus on the default port
(127.0.0.1:4222) if one is live, otherwise it spawns nats-server on a random
loopback port and writes `var/nats-url`. The UI bridge reads that file, so
`make up` just works. Set `NIF_NATS_URL` to attach to any bus, even a remote one.

**Approvals.** Tools that change the machine or the harness (`bash`,
`builder.build`, `core.spawn`/`kill`/`remove`) carry `x-harness.approval:
"always"` and are gated on a human: a y/N prompt in the terminal harness, a
dialog in the web UI. Headless (no UI attached) calls are denied — never
silently approved. `NIF_AUTO_APPROVE=1` bypasses the gate (see
[docs/MANUAL.md](docs/MANUAL.md)).

**Secrets.** `.env` (gitignored) holds `NIF_OPENAI_API_KEY` and
`NIF_OPENAI_BASE_URL` (DeepSeek by default); an existing shell env always
wins. Service mode (no tty): `NIF_NATS_URL=... NIF_OPENAI_API_KEY=...
./var/bin/niffler < /dev/null`.

## Layout

```
docs/                REBOOT.md (design rationale), WIRE.md (wire protocol)
manifest.yaml        bootstrap component manifest
sdk/envelope.nim     envelope codec (std/json, portable by design)
sdk/niffler/         Nim component SDK (~250 lines)
sdk/go/              Go component SDK (mirror of the Nim one)
sdk/ts/              TypeScript/Node.js component SDK (mirror, npm package)
core/                catalog, supervisor, dispatch, conversation loop
components/          bash, builder, store, plugins, hashline-edit, cli,
                     console (Nim), llm (Go)
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
(restored on boot) and conversation messages.

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

Then: `builder.build {lang, name, source}` → `core.spawn {name, binary}` →
the tool is live. Retire it with `core.remove {name}` (kill it temporarily
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
service component (human-approved). Components marked `"interactive": true`
are built into `var/bin` but not spawned; the user starts them in a terminal.
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

- [x] wire spec, envelope, Nim + Go + TypeScript SDKs
- [x] supervisor (spawn/monitor/restart/drain), catalog, dispatch
- [x] bash + builder components, llm adapter (streaming OpenAI-compatible) in Go
- [x] typed tool definitions (nimcp-inspired: schema + handler from a proc)
- [x] **agent adds itself a tool end-to-end** (docs/REBOOT.md milestone, live
      test with DeepSeek: wrote → built → spawned → called `greet`)
- [x] **store component** — barrel-backed document store over the bus
      (put/get/list/del, rev-based optimistic concurrency); core persists
      conversations, messages and spawned components; spawned components
      restore on boot (persistence of shape, verified live across restarts)
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
      prompt (tty) or UI dialog (ev.approval.request/reply); deny when no
      human is reachable; verified end-to-end (service + tty probes)
- [x] **recover mode** — `--recover` / `make recover`: rebuild shipped
      binaries from source, wipe spawned-component records, keep conversations
- [x] **plugins component** — ecosystem discovery + install as a bus
      service: GitHub topic search, `niffler.json` package manifest, always
      builds from source via the builder (or `file://` local repos for
      hermetic installs), spawn/update/remove, store records;
      live-tested end-to-end with `gokr/niffler-weather`
- [x] **console component** — passive bus viewer: subscribes to everything
      and renders the wire traffic readably (run it in a second terminal)
- [x] **cli component** — drive the harness from a terminal or a script
      (`catalog` / `wait` / `call` / `install`), exit 0 on success; the
      preferred way to CI a plugin repo (niffler-weather's workflow uses it)
- [x] **core re-entry** — dispatch polls a private inbox and serves
      `svc.core.call` mid-turn, so a component calling back into core
      (`plugin_install` → `core.spawn`) cannot deadlock the session;
      concurrent session requests are stashed, never nested
- [x] **bus-contract test suite** — `make test`: one script per non-LLM
      component (bash, store, builder, console, plugins, core, cli), each
      booting the real binaries over its own NATS; hermetic plugin installs
      via `file://`; network opt-ins behind `NIF_TEST_INSTALL`/`NIF_TEST_NETWORK`
- [x] **streaming** — `llm` adapter streams `ev.llm.token` deltas (content
      + reasoning), core forwards them as `ev.session.token`, the UI appends
      them to the live assistant bubble; per-call cancellation
      (`llm.cancel.<sessionId>`); final assistant event always carries the
      complete content
- [x] **hashline-edit** — hash-anchored `read`/`replace`/`undo_last_replace`
      (Nim port of pi-hashline-edit-pro), anchors stable across edits
- [x] **TypeScript SDK** — sdk/ts (npm package, mirror of the Go SDK);
      the builder compiles `lang: "ts"` components via tsc into a node
      wrapper binary; verified live (builder → spawn → call from Node.js)
- [ ] Level 1 UI dynamism: x-ui schema hints + generic renderer registry
- [ ] cancellation in the terminal harness + UI (ev.cancel flow polish)

## Quests — things Niffler should do itself (or that we do on a slow day)

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
