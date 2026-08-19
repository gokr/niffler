# AGENTS.md — Niffler

Niffler is a minimal, self-extending agent harness.
It replaces, not extends, the old Niffler codebase (now at `~/git/niffler-old`);
only its **Nim style guidelines** (in `~/git/niffler-old/CLAUDE.md`) apply here:
camelCase, `fmt("...")` as a proc call, no asyncdispatch, doc comments with `##`.

Design rationale: [docs/REBOOT.md](docs/REBOOT.md). The one wire spec:
[docs/WIRE.md](docs/WIRE.md). Why core is core:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Read these before changing
anything structural.

## What this is (architecture invariants)

- Core speaks exactly one protocol: JSON envelopes over NATS. Core never imports
  component code; components never import core. The envelope codec
  (`sdk/envelope.nim`) is pure `std/json` runtime data — keep it that way so SDKs
  stay portable (~200 lines; the Go SDK mirrors the Nim one 1:1).
- Everything is a separate process component: `bash`, `builder`, `store`,
  `plugins`, `llm-openai` are peers. Adding a capability = write source → `builder.build`
  → `core.spawn`; removing one = `core.kill` (temporary) or `core.remove`
  (also deletes the persisted record). The agent does this to itself,
  mid-conversation — that is the architecture's validation criterion.
- Nim SDK has **no callbacks and no threads**: handlers poll
  `natsSubscription_NextMsg` on the main thread, serialized, with normal GC.
  The `{.gcsafe.}` pragmas dance from the old codebase is not needed and must not
  be copied here.
- NATS is the only bus. Barrel's (embedded BitBarrel KV in `store`) own pubsub is
  deliberately unused.
- Naming: components lowercase-hyphens (`llm-openai`), tools lowercase underscores.
  Tool names are globally unique — core rejects duplicates at registration.
- Schema extensions core honors: `x-harness.hidden` (tool invisible to the LLM,
  e.g. `chat`), `x-harness.approval` (**enforced**: terminal y/N prompt, UI
  dialog, or deny when no human is reachable — `NIF_AUTO_APPROVE=1` bypasses),
  `x-harness.timeoutMs` (see `components/builder/main.nim`).
- Tool doc comments are the LLM's only window into a tool: all prose lines of
  the first comment block join into the schema description, `- param: text`
  lines become parameter docs. Write *when-to-use* guidance there — the LLM
  decides tool choice from that text alone.

## Commands

The Makefile is the front door (it wraps the nimble tasks below):

```bash
make all              # build core + all components + desktop UI
make build            # core + components only (var/bin, no UI)
make run              # build, then ./var/bin/niffler (interactive harness)
make up               # single command: ensure bus + core, then open the UI
make down             # stop what `make up` started (UI, core, spawned bus)
make status
make test             # the whole bus-contract suite: smoke + t_bash, t_store,
                      # t_builder, t_console, t_plugins, t_core, t_cli — each
                      # boots its own NATS; core-based tests need no other
                      # harness running (store single-writer)
make recover          # stop everything, rebuild shipped binaries, wipe
                      # spawned-component records, restart (--recover)
make setup            # install prerequisites for the platform (Ubuntu/macOS)
make doctor           # check prerequisites, report what's missing
make dev              # Svelte dev server in a browser (bridge stubbed)
```

Underlying nimble tasks (same thing, one level down):

```bash
nimble all            # build core + all components into var/bin (Nim + Go)
nimble smoke          # the only test: spawns its own NATS, exercises bash + store
                      # end-to-end. Requires a prior nimble all.
```

- There is no test framework — `tests/smoke.nim` is a single end-to-end script that
  exits non-zero on failure. Run it after bus/SDK changes.
- Binaries land in `var/bin/`; `var/` is gitignored runtime state (build cache,
  `barrel-db` store file, `nats-url` of the last spawned bus).
- `scripts/niffler.sh` is the up/down/status logic behind `make up/down/status`:
  core reuses a bus on 127.0.0.1:4222 if one is live, else spawns nats-server and
  writes `var/nats-url`; the UI bridge reads that file.

### UI (Wails v2 + Svelte 5, `ui/`)

```bash
make ui                          # = cd ui && ~/go/bin/wails build -tags webkit2_41
cd ui/frontend && npm run dev    # browser-only dev (bridge stubbed)
cd ui/frontend && npm run typecheck              # tsc --noEmit
```

The SPA is a NATS client, not a Wails client: it only talks to
`frontend/src/nats.ts`; Wails is hosting, not architecture.

## Environment and gotchas

- **All deps come from nimble.** `niffler.nimble` requires `yaml`,
  `gokr/natswrapper` and `gokr/bitbarrel` (GitHub URLs); nimble installs them
  automatically on first build. `config.nims` scans `~/.nimble/pkgs2` so plain
  `nim c` invocations (builder, smoke test) resolve them without nimble.paths.
- **`.env` (gitignored) holds a real API key** (`NIF_OPENAI_API_KEY`, NIF_OPENAI_*
  pointed at DeepSeek). Components load it via `sdk/dotenv.nim`; existing shell
  env wins. Never commit it. Full env var reference: docs/MANUAL.md.
- `NIF_NATS_URL` set → attach to that bus (can be remote); unset → core spawns
  `nats-server` (must be on PATH) on a random loopback port and writes it to
  `var/nats-url`.
- The `store` component is single-writer: exactly one process owns
  `var/barrel-db`. Never run two stores against the same file.
- `llm-openai` is Go (`sdk/go`); the builder gives agent-written Go components a
  `go.mod` with a `replace niffler.dev/sdk => <root>/sdk/go` automatically.
- Harness in service mode (for the UI, no tty):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`
- **`wails build`, never `go build`, for the UI.** `go build ./...` or
  `go build -o build/bin/niffler-ui .` overwrites the binary with a stub that
  prints "Wails applications will not build without the correct build tags."
  `go vet` is fine; only `~/go/bin/wails build -tags webkit2_41` produces the
  real desktop app.
- **`nats.ts` must match the Go struct name.** `frontend/wailsjs/go/main/<Struct>.js`
  and `window.go.main.<Struct>` are generated from the bound **Go struct**
  (`Bridge`), not the `Bind: []interface{}{ app }` variable. `nats.ts` checks
  `window.go.main.Bridge`; after a renaming `wails build`, update the import
  + `isWails()` check or the SPA shows "Running in a browser" inside the shell.
- **Go SDK is `package sdk`.** `import sdk "niffler.dev/sdk"` → identifier
  `sdk` (`sdk.New`, `sdk.Component`). That's the alias the builder/LLM
  naturally writes; don't write `niffler.New` — Go will say
  "imported as niffler.dev/sdk and not used" / "undefined: sdk".

## Debugging the bus — prove the stack without the LLM

The fastest diagnosis is a one-shot bus probe: call `svc.core.call` exactly
as the UI's `Chat.svelte` does, straight over NATS. Tests written as
one-time `nim c -r` scripts in `tests/`; they share `sdk`'s envelope and
run in the same cwd, so `--path:sdk` resolves imports.

Probe a session turn (uses core's own session service; no UI involved):

```nim
import std/[json, os, times]
import natswrapper
import niffler/sdk
let nc = connect(getEnv("NIF_NATS_URL", "nats://127.0.0.1:4222"))
let data = callEnvelope("session",
  %*{"sessionId": "probe-" & $int(epochTime()), "content": "Ping"}).encode()
var msg: ptr natsMsg
let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call",
                                data.cstring, data.len.cint, 120_000 * 1_000_000)
doAssert checkStatus(st)
let r = decode($natsMsg_GetData(msg))
echo (if r.kind == ekResult: "OK " & $r.args else: "FAIL " & $r.error)
```

Build & run, no leftover files:

```bash
nim c --hints:off --path:sdk -o:/tmp/probe tests/probe.nim
NIF_NATS_URL=nats://127.0.0.1:4222 /tmp/probe; rm -f tests/probe.nim /tmp/probe
```

- `nimble smoke` is the scripted end-to-end equivalent of this (spawns its own
  NATS + bash/store). Prefer it for repeat checks; one-off probes for something
  specific (was this tool registered? does spawn work? LLM roundtrip?).
- To inspect what core actually advertises to the LLM (catches bad schemas):
  call `catalog {op: list}` and check each tool's `schema.type` is `"object"`.
- `./var/bin/console` (not in the manifest) — subscribes `>` and renders
  every envelope readably; run it in a second terminal to follow any
  harness activity live. Better than `nats sub '>'` (decoded envelopes).
- `./var/bin/cli` (not in the manifest) — drive the harness from a script:
  `catalog` / `wait <comp>` / `call <tool> '<json>'` / `install <repo>[@<ref>]`,
  each exiting 0 on success. Its catalog seeds from core (`catalog {op:
  components}`) so it works against an already-running harness. This is
  the preferred way to CI a plugin repo: boot the harness, `cli install`,
  `cli call` the tools, assert on output.
- Never wrap a single HttpClient across multiple GitHub (or any) API calls:
  a stale pooled connection (server closed it, e.g. after a 404) hangs the
  next read forever — fresh client per call (see plugins' resolveTag).
- The `ui` component also registers on the bus (0 tools) — grep core's stdout
  for `catalog: ui v` to prove the bridge connected.
- Killing all component processes leaves the NATS server orphaned; either
  use the harness's own spawn (`./var/bin/niffler` spawns nats if `NIF_NATS_URL`
  unset) or `pkill -f nats-server; pkill -f niffler/var/bin` before a cold start.

## Working in this repo

- Prefer dogfooding: to try a new tool, build it as a component through the
  harness's own `builder` + `core.spawn` before hard-wiring anything into core.
- **Component ecosystem**: third-party packages are GitHub repos with a
  `niffler.json` manifest + the `niffler-component` topic. The shipped
  `plugins` component installs them (`plugin_search`/`install`/`update`/
  `remove`) — clone into `var/plugins/<pkg>@<ref>/`, always build from
  source via `builder.build`, then `core.spawn`.
  Sample package: `gokr/niffler-weather`. Install records: store kind
  `plugin`. Never loop over a possibly-missing JSON key in component code —
  `{}` returns nil and iterating nil SIGSEGVs (json.nim items iterator).
- Verification = `nimble all && nimble smoke`, plus a live harness run for
  conversation-loop changes.
- Milestone status and open quests live in `README.md` — update it when you
  complete one.
