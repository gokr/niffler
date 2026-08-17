# Niffler

A minimal, self-extending agent harness. The agent adds capabilities at
runtime — write source, compile it with the `builder` component, start it via
`core.spawn` — mid-conversation. Design rationale:
[docs/REBOOT.md](docs/REBOOT.md). Wire protocol: [docs/WIRE.md](docs/WIRE.md).

```
core (Nim) ── NATS ──┬── bash (Nim SDK)
                     ├── builder (Nim SDK)
                     ├── llm-openai (Go SDK)
                     └── your tool (any language with an SDK port)
```

Core speaks exactly one protocol (JSON envelopes over NATS, see
[docs/WIRE.md](docs/WIRE.md)); everything else — bash, the builder, the LLM
adapter — is a separate process component with its own language's SDK.

## Quickstart

```bash
make up
```

One command: builds core + components + the desktop UI, starts a bus and core
if none is running, and opens the Wails UI. Stop everything with `make down`.

Only the terminal harness? `make run`. Just build? `make` (or `make all`).

## Prerequisites

Core + components need **Nim**, **Go** and **nats-server**; the desktop UI
additionally needs **Node/npm**, the **wails CLI** and (on Linux) the
WebKit/GTK dev libraries.

```bash
make setup    # installs everything for your platform (Ubuntu/macOS)
make doctor   # checks what's installed and what's missing
```

The Makefile finds wails in `~/go/bin` even when it's not on PATH. The
manual commands below are what `make setup` runs.

### Ubuntu 22.04+

```bash
# Go — or download from https://go.dev/dl
sudo snap install go --classic

# Nim 2.x (Ubuntu's apt package is too old) — adds ~/.nimble/bin to PATH
curl -sSf https://nim-lang.org/choosenim/init.sh | sh

# nats-server — or grab a binary from https://github.com/nats-io/nats-server/releases
go install github.com/nats-io/nats-server/v2@latest

# Node/npm (frontend; wails runs `npm install` itself)
sudo apt install nodejs npm

# Wails CLI (lands in ~/go/bin — the Makefile finds it there)
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Wails build deps: webkit2gtk 4.1, GTK3, build tooling
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config
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
| `make run` | terminal harness (interactive) |
| `make test` | end-to-end smoke test (spawns its own bus) |
| `make dev` | Svelte dev server in a browser (bridge stubbed) |
| `make clean` | remove all build artifacts |

**Bus autostart.** With no `NATS_URL`, core reuses a bus on the default port
(127.0.0.1:4222) if one is live, otherwise it spawns nats-server on a random
loopback port and writes `var/nats-url`. The UI bridge reads that file, so
`make up` just works. Set `NATS_URL` to attach to any bus, even a remote one.

**Secrets.** `.env` (gitignored) holds `OPENAI_API_KEY` and `OPENAI_BASE_URL`
(DeepSeek by default); an existing shell env always wins. Service mode (no
tty): `NATS_URL=... OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`.

## Layout

```
docs/                REBOOT.md (design rationale), WIRE.md (wire protocol)
manifest.yaml        bootstrap component manifest
sdk/envelope.nim     envelope codec (std/json, portable by design)
sdk/niffler/         Nim component SDK (~250 lines)
sdk/go/              Go component SDK (mirror of the Nim one)
core/                catalog, supervisor, dispatch, conversation loop
components/          bash, builder, store (Nim), llm-openai (Go)
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
bus. Kind keys: `component`, `conversation`, `message`. Core persists
spawned components (restored on boot) and conversation messages.

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

Go — `import niffler "niffler.dev/sdk"` with the same surface
(`Tool`, `On`, `Emit`, `Request`, `Run`). Other languages: port the SDK —
the envelope is the artifact (~200 lines).

Then: `builder.build {lang, name, source}` → `core.spawn {name, binary}` →
the tool is live. The agent does this itself, mid-conversation — that is the
architecture's validation criterion.

## Milestone status

- [x] wire spec, envelope, Nim + Go SDKs
- [x] supervisor (spawn/monitor/restart/drain), catalog, dispatch
- [x] bash + builder components, llm-openai (OpenAI-compatible) in Go
- [x] typed tool definitions (nimcp-inspired: schema + handler from a proc)
- [x] **agent adds itself a tool end-to-end** (docs/REBOOT.md milestone, live
      test with DeepSeek: wrote → built → spawned → called `greet`)
- [x] **store component** — barrel-backed document store over the bus
      (put/get/list/del, rev-based optimistic concurrency); core persists
      conversations, messages and spawned components; spawned components
      restore on boot (persistence of shape, verified live across restarts)
- [x] **session service** — svc.core.call `session` turns + ev.session.*
      events; service mode (no tty) for UIs; verified live
- [x] **Wails SPA shell** — Go bridge (bus citizen), Svelte 5 chat:
      sessions from the store, live tool cards, markdown; builds + verified
      end-to-end against core in service mode
- [ ] approvals via `svc.ui.call` (x-harness interceptor in dispatch)
- [ ] Level 1 UI dynamism: x-ui schema hints + generic renderer registry
- [ ] streaming (chunk frames + `ev.*` token events), cancellation
- [ ] conversation resume in the UI (store reload wired, needs UI polish)

## Quests — things Niffler should do itself (or that we do on a slow day)

1. **store-sqlite comparison** — port components/store/main.nim to SQLite
   (e.g. nim-community/libsql), same tools, run both, compare. The contract
   is the artifact; Niffler can read its own sources (`bash cat …/store/main.nim`),
   build, spawn and benchmark the variant — a true dogfooding quest.
2. **node/TS component SDK** — port sdk/go (~200 lines) to TypeScript; lets
   the agent add JS tools without a compile step.
3. **pipewrap** — stdio/NDJSON bridge so plain scripts become components.
4. **Level 2 UI dynamism** — builder compiles Svelte components to JS modules,
   catalog registers ui-modules, bridge serves var/ui/, SPA blob-imports
   (see ui/README.md).
5. **store-tidb** — same tools, SQL tables, FTS + vector search for
   conversation memory; sharing across harnesses/hosts.
