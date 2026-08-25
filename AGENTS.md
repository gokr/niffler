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
  `plugins`, `skills`, `fetch`, `hashline-edit`, `grep`, `write`, `observe`,
  `logfile`, `models`, `provider`, `llm` are peers. Adding a capability =
  write source → `builder.build`
  → `core.spawn`; removing one = `core.kill` (temporary) or `core.remove`
  (also deletes the persisted record). The agent does this to itself,
  mid-conversation — that is the architecture's validation criterion.
- One conversation = one process: the system harness (`niffler.nim`) is the
  irreducible root; it ensures a **session runner** (`var/bin/session <id>`,
  `core/session.nim`) per conversation and forwards `session` tool calls to
  `svc.session.<id>.call` (clients keep calling `svc.core.call`). Runners are
  internal children (restart `never`), ephemeral, and resume from the store;
  killing one loses only the in-flight turn. Turns never nest. The tty REPL
  (`core/tty.nim`) is an **admin shell**, not a conversation UI: status
  commands only (help/status/catalog/tools/sessions) — the LLM chat lives in
  the web UI and the niffler-tui plugin; scripting goes through the `cli`
  component.
- Nim SDK has **no callbacks and no threads**: handlers poll
  `natsSubscription_NextMsg` on the main thread, serialized, with normal GC.
  The `{.gcsafe.}` pragmas dance from the old codebase is not needed and must not
  be copied here.
- NATS is the only bus. Barrel's (embedded BitBarrel KV in `store`) own pubsub is
  deliberately unused.
- Naming: components lowercase-hyphens (`hashline-edit`), tools lowercase
  underscores. Tool names are globally unique — core rejects duplicates at
  registration.
- Schema extensions core honors: `x-harness.hidden` (tool invisible to the LLM,
  e.g. `chat`), `x-harness.onDemand` (kept out of a conversation's frozen
  direct toolset; reachable via `discover` + `invoke` — docs/DISCOVER.md),
  `x-harness.approval` (**enforced**: terminal y/N prompt, UI
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
./var/bin/niffler     # the harness itself (admin shell) — UIs autostart it too
niffler-ui            # the desktop app: autostarts core; the last UI stops it
make test             # the whole bus-contract suite: smoke + t_bash, t_store,
                      # t_builder, t_console, t_plugins, t_skills, t_fetch,
                      # t_models, t_provider, t_observe, t_logfile, t_core,
                      # t_cli, t_hashline,
                      # t_grep, t_write, t_autostart — each owns a private
                      # NATS server + temporary NIF_ROOT, so component
                      # targets can overlap a live harness
make gotest           # Go unit tests + vet: sdk/go, components/models, llm
                      # (also part of `make test`)
make recover          # stop everything, rebuild shipped binaries, wipe
                      # spawned-component records, restart (--recover)
make setup            # install prerequisites for the platform (Ubuntu/macOS)
make doctor           # check prerequisites, report what's missing
make dev              # Svelte dev server in a browser (bridge stubbed)
```

Underlying nimble tasks (same thing, one level down):

```bash
nimble all            # build core + all components into var/bin (Nim + Go)
nimble smoke          # legacy: the original end-to-end script (bash + store).
                      # Prefer `make test` — the full bus-contract suite.
```

- There is no test framework — `tests/` holds plain scripts (helpers.nim +
  one `t_*.nim` per component) that exit non-zero on failure. Run
  `make test` after bus/SDK changes.
- Binaries land in `var/bin/`; `var/` is gitignored runtime state (build cache,
  `barrel-db` store file, `nats-url` of the last spawned bus).
- Lifecycle has no launcher script: any UI's first act is the SDK's
  `ensureHarness` — probe (env → `var/nats-url` → 127.0.0.1:4222) for a live
  core, else spawn `var/bin/niffler` detached with `NIF_AUTOSTART=1`.
  Interactive frontends register `client: true`; an autostarted core exits
  when the last one departs (idle 10s) or none arrives (boot grace 60s).
  Manually started cores never self-terminate. `niffler-ui` gets the repo
  root baked via `make ui` ldflags (`main.nifRoot`); to debug a failed
  autostart, run `./var/bin/niffler` by hand and watch boot.

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
  `nats-server` (must be on PATH) on 4222 when free (else a random loopback
  port) and writes it to `var/nats-url`; standalone clients (`cli`,
  `console`) follow that file when `NIF_NATS_URL` is unset.
- The `store` component is single-writer: exactly one process owns
  `var/barrel-db`. Never run two stores against the same file.
- `llm` is Go (`sdk/go`); the builder gives agent-written Go components a
  `go.mod` with a `replace niffler.dev/sdk => <root>/sdk/go` automatically.
  It streams live tokens as `ev.llm.token` deltas; core re-emits them as
  `ev.session.token` for the active turn. `components/llm-openai` is the
  minimal non-streaming example adapter.
- TypeScript components (`sdk/ts`, npm package `niffler-sdk`) build with
  `builder.build {lang: "ts", ...}`: npm install (registry access needed)
  + tsc, producing a node wrapper binary; the builder wires the SDK via a
  `file:` dependency in the generated package.json. Handlers may be async;
  the SDK serializes them through a promise chain (the Nim single-thread
  model).
- Harness in service mode (for the UI, no tty):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`
- Session turns run in **session runner processes** (`var/bin/session <id>`),
  spawned on demand by the system and present in the catalog as
  `session-<id>` (0 tools). Missing `var/bin/session` → session calls fail
  with "session runner binary missing — run `make build`". Runners resume
  conversations from the store, so they are disposable; a runner whose
  conversation id came from a killed runner is recreated automatically.
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

- `make test` is the scripted end-to-end suite (spawns its own NATS per
  test). Prefer it for repeat checks; one-off probes for something
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
  source via `builder.build`, then `core.spawn` service components. Manifest
  entries with `"interactive": true` are built into `var/bin` but not spawned;
  the user starts those terminal clients manually.
  Sample package: `gokr/niffler-weather`. Install records: store kind
  `plugin`. Never loop over a possibly-missing JSON key in component code —
  `{}` returns nil and iterating nil SIGSEGVs (json.nim items iterator).
- Verification = `make build && make test` (bus-contract suite, see
  docs/MANUAL.md#testing), plus a live harness run for
  conversation-loop changes. Repository build writes are serialized by
  `scripts/with-build-lock.sh` (flock on `.niffler-build.lock`; exclusive
  for builds/clean, shared for test runs); `make build` holds one lock
  across the whole generation. Remove build artifacts with `make clean`,
  never a bare `rm -rf var`.
- **Trust a green test run — don't re-run to see "more" output.** `make`
  targets print each check as `OK: …` and end with `<NAME> TEST PASSED`,
  and the exit code reflects the whole suite. If that line prints and the
  command exits 0, capture the tail once and move on; re-running the same
  green suite only to see more of the output is wasted work. Rerun *only*
  when there is a failure to diagnose or you changed code since the last
  run.
- **A failed/partial run is the only case that needs investigation**: when
  the suite breaks, re-run the *narrowest* target that reproduces it
  (`make test-core`, `make test-bash`, …) with output captured, and fix
  before re-running broadly.
- Milestone status and open quests live in `README.md` — update it when you
  complete one.
