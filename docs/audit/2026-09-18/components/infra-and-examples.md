# Audit: infrastructure and example components

Scope: `components/nats/`, `components/ctxtest/`, `components/systemprompt/`,
`components/llm-openai/`, `components/mcp-bridge/` — audited against
`docs/MANUAL.md` at the working-tree revision (**2850 lines**; every line number
below is that revision's) plus `manifest.yaml`, `Makefile`, `niffler.nimble`,
`core/niffler.nim` and the tests that own each fixture. Read-only audit: no
MANUAL or component source was edited.

These five are the harness's *plumbing* — the bus, the test fixture, the
constitution, the swap-in LLM example and the MCP child process. Four of the
five register on the bus; one (`nats-server`) deliberately never does. Two
(`ctxtest`, `llm-openai`) are deliberately not in `manifest.yaml`; one
(`mcp-bridge`) is spawned only by another component; one (`nats-server`) is
spawned by core before the bus exists.

Row format of every DELTA list (machine-parsed, grouped under the exact current
MANUAL heading):

`- MANUAL: <exact quote or "absent"> | CODE: <path:line> | FIX: <add|update|remove + exact wording>`

Classes used: `doc-edit`, `wrong`, `missing`, `trim`, `code-bug?`, `delta`,
`verified`.

---

# `components/nats/` — the bus itself as a shipped component

Files: `main.go` (150 lines), `pdeathsig_linux.go` (21), `pdeathsig_other.go`
(7), `go.mod` (module `nats`, `github.com/nats-io/nats-server/v2 v2.14.6`).

## 1. What it is and why it exists

A **faithful copy of the official nats-server `main`** (`main.go:1-14`), rebuilt
inside the harness so the one external bus dependency ships with the repo:
`make build` produces `var/bin/nats-server` from this source, pinned by
`go.mod`, and core **prefers that binary over a PATH install** so a desktop
install needs no NATS prerequisite (`core/niffler.nim:51-60`; the Makefile
comment at `Makefile:262-264` says the same).

It is **not a bus component in the runtime sense** (`main.go:11-14`): core
spawns it *before the bus exists*, it never connects to NATS as a peer, it
registers **no tools**, and it has **no `manifest.yaml` entry** — so it is
invisible to `catalog`, impossible to reach through `core.spawn`, and never
touched by the supervisor.

Flags: it must stay CLI-compatible with the official binary because core drives
it by flags, not config — `core/niffler.nim:92-96` passes
`-a 127.0.0.1 -p <port> -m -1 --ports_file_dir <tmp>` plus **one Niffler
extension**, `--max_payload <bytes>` (registered `main.go:110-115`, applied
`main.go:128-130`), because the official binary accepts `max_payload` only from
a config file. On Linux it takes `PR_SET_PDEATHSIG` = SIGTERM first thing
(`main.go:104`, `pdeathsig_linux.go:12-21`, no-op off Linux) so a kernel reaps
the bus when core dies, SIGKILL included.

Ports and the payload cap are core's business, not the component's:

- port attempt order + handshake: `core/niffler.nim:78-116` (random temp
  `--ports_file_dir`, `.ports` file polled 200 × 20 ms; the caller passes
  `[homePort]` or `["-1"]`);
- payload: `const natsMaxPayload = 8388608` (`core/niffler.nim:46-49`) — ≈2M
  tokens of JSON, above which nats-server only warns;
- a **PATH** nats-server that cannot take the flag gets a generated
  `max_payload: 8388608` config file instead (`core/niffler.nim:63-72`,
  `:94-95`), because that binary would otherwise silently run at the 1 MiB
  default and large replies would never arrive;
- an **attached, foreign** bus is measured and warned about at boot
  (`core/niffler.nim:400-414`, `natsConnection_GetMaxPayload`).

## 2. Tools and `x-harness` flags

**None, and none possible.** It registers nothing with the catalog — no
`svc.*` subject, no tool, no `x-harness` flag, no store kind. There is nothing
to discover or invoke; the only "interface" is the CLI (`nats-server --help`
prints the flag list, `main.go:28-100`) and the discovery files core writes
after it is up.

### Spawn policy — deliberately absent from `manifest.yaml`

Confirmed: `manifest.yaml` has no `nats`/`nats-server` entry anywhere (the only
in-tree mention of the binary in that file's world is the component comment).
A user therefore **cannot** start the bus with `spawn {name: "nats-server"}`,
and should not: core's `spawnNats` owns the argv, the ports and the PID record
(`var/nats-pid`). What a user does instead is:

- let core spawn it (the default: `NIF_NATS_URL` unset, or a home bus declared
  in `.env` that is free), or
- attach to one they run themselves with `NIF_NATS_URL` — but see the delta
  below: a bare nats-server is *not* reused as a home bus.

## 3. Configuration

**The component reads no environment variable at all** (`grep -n 'Getenv'`
over `components/nats/*.go` → 0 hits). Everything that configures the bus
belongs to core or to the SDK:

| Knob | Read by | Default | Effect |
|---|---|---|---|
| `NIF_NATS_URL` | core (`core/niffler.nim:337`) and every SDK's discovery helper (`sdk/go/harness.go:29`, `sdk/niffler/sdk.nim:634`, `sdk/ts/src/wire.ts:41`) | unset → home port `nats://127.0.0.1:4222` | explicit env = attach-only; declared in `.env` = this clone's home bus |
| `NIF_NATS_SPAWN` | core (`core/niffler.nim:343-345`) | unset | `1` → isolated bus on a random port, never 4222 |
| `NIF_OBSERVE_MONITOR_URL` | `observe` | core's discovery file | HTTP monitoring endpoint for an external/reused bus |
| argv (`-a/-p/-m/--ports_file_dir/--max_payload`) | core `spawnNats` | `-a 127.0.0.1`, `-m -1`, payload 8388608 | the only real configuration surface |

Files it owns indirectly: `var/nats-url`, `var/nats-monitor-url`,
`var/nats-pid` (written by core, `core/niffler.nim:390-414`).

## 4. How the MANUAL covers it today

It **is** mentioned — but only as an implementation detail of core, never as a
component with a row of its own:

- MANUAL:38 `| `components/` | shipped component sources — one directory per
  component (Nim, Go, TypeScript and one bash demo); the inventory is the
  [Shipped components](#shipped-components) table below, which is the part that
  has to stay current |` — yet the table (MANUAL:55-86) has **no `nats-server`
  row**.
- MANUAL:45 `| `var/nats-url` | bus address of the last spawned bus; the UI
  bridge reads it to find core |`; MANUAL:46 `| `var/nats-monitor-url` | HTTP
  monitoring endpoint when core spawned the bus; absent for reused/remote
  buses |`; MANUAL:51 `| `var/nats-pid` | pid of the bus core spawned (crash
  cleanup only — a live core stops its own bus on exit) |`.
- MANUAL:357/358 — the `NIF_NATS_URL` / `NIF_NATS_SPAWN` rows (both accurate,
  including the home-bus probe rules).
- MANUAL:2228-2229 `The only core integration is optional nats-server HTTP
  monitoring: when core owns the bus it allocates a second loopback port and
  writes `var/nats-monitor-url` after the server is live.`
- MANUAL:2414-2416 `When core spawns nats-server it uses distinct loopback
  client and HTTP ports, then writes (the binary is the built component
  `var/bin/nats-server` from `components/nats` when present, else a PATH
  `nats-server`):` — the closest thing to a component description.
- MANUAL:2425-2427 `NIF_NATS_SPAWN=1` forces an isolated core-owned bus on a
  random port … never 4222; an explicit `NIF_NATS_URL` in the environment wins.
- MANUAL:2816-2819 `- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222`
  (even remote), or start your own nats-server on the default port before core —
  core reuses a live bus on `127.0.0.1:4222` and only spawns its own (the built
  `var/bin/nats-server` component) when none answers.`
- MANUAL:2847 the `orphaned nats-server` troubleshooting row (correct: manual
  nats-server, non-Linux host, stale `var/nats-pid`).

Explicitly **absent** from the MANUAL, top to bottom: the `--max_payload`
extension and the 8 MiB requirement (and the boot warning for a smaller
attached bus); the config-file fallback for a PATH nats-server; the fact that
the bundled binary is deliberately not in `manifest.yaml`; the ports-file
handshake and the home-port-then-random attempt order; `make doctor`'s report
for the binary and the no-op `make install-nats`.

## 5. DELTA list

## Shipped components

- MANUAL:55-86 (table: `store`…`dialog`, no `nats-server` row), against MANUAL:38 which declares that table the inventory of `components/` | CODE: `components/nats/main.go:1-14`, `components/nats/go.mod:1-4` (module `nats`, nats-server v2.14.6), `Makefile:262-266` (`var/bin/nats-server`), `Makefile:310-313` (it is in the `components-inner` binary list), `manifest.yaml` (no entry) | FIX: add — `| `nats-server` | Go | **not in the manifest** | the bus itself as a first-class component: a faithful rebuild of the official `nats-server` main (pinned in `components/nats/go.mod`), built by `make build` into `var/bin/nats-server` and preferred by core over a PATH install, so no NATS prerequisite is needed. Deliberately *not* a bus component — core starts it before the bus exists, it registers no tools, and `core.spawn` cannot start it. Niffler adds one flag, `--max_payload <bytes>` (core passes 8388608); on Linux it sets `PR_SET_PDEATHSIG` so no orphaned bus outlives its harness |`

## The bus in one screen

- MANUAL: absent (the 8 MiB payload budget, the `--max_payload` extension and the boot warning for a smaller attached bus) | CODE: `core/niffler.nim:46-49` (`const natsMaxPayload = 8388608`), `:92-93` (bundled binary gets `--max_payload`), `:63-72,:94-95` (a PATH nats-server gets a generated `max_payload` config file instead), `:400-414` (`natsConnection_GetMaxPayload` → `core: WARNING bus at … caps messages at N bytes …`) | FIX: add — "A request carries a whole conversation, so the bundled bus is started with `max_payload: 8388608` (8 MiB — ≈2M tokens of JSON; above that nats-server only warns). The bundled `var/bin/nats-server` takes it as an extra flag, a PATH nats-server gets it in a generated config file instead. When core attaches to a bus it did not spawn it reads the server's real cap and warns at boot if it is below 8 MiB: such a bus rejects a large reply at publish time and the caller waits out its full timeout, which looks like a component hang rather than a bus limit."
- MANUAL: absent (the port handshake: `--ports_file_dir` + `.ports` polling, and the home-port-then-random attempt order) | CODE: `core/niffler.nim:78-116` | FIX: add (one clause, §Monitoring) — "Ports are allocated by NATS itself: core passes `--ports_file_dir <tmp>` and reads the `*.ports` file it writes (bounded 4 s wait), so concurrent harnesses cannot win a bind-close-start race. The attempt order is the home port first, then a random one."

## Common tasks

- MANUAL: absent (how the bundled bus is obtained: `make build` compiles it; `make doctor` reports/explains it; there is no `make install-nats` — the target is a stub that says so) | CODE: `Makefile:262-266`, `Makefile:620-623` (`nats-server: OK` / `built from source by 'make build' (components/nats)`), `Makefile:698-699` (`install-nats` prints "nothing to install") | FIX: add — one bullet under **Attach to any bus**: "The bus binary ships with the repo: `make build` compiles `components/nats` into `var/bin/nats-server` (there is nothing to install — `make install-nats` only says so, and `make doctor` reports `nats-server: OK` or explains that it is built from source)."

## Troubleshooting

- MANUAL:2816-2819 `or start your own nats-server on the default port before core — core reuses a live bus on `127.0.0.1:4222` and only spawns its own (the built `var/bin/nats-server` component) when none answers.` | CODE: `core/niffler.nim:176-201` (`probeBus` → `bkFree`/`bkOurs`/`bkForeignCore`/`bkBareNats`), `:354-383` (only `bkOurs` reuses; foreign core and bare nats-server both print a WARNING and spawn an isolated bus; a bare bus is reclaimed only when `var/nats-pid` names *our own* live nats-server — `reclaimOwnNats`, `:176-201`) | FIX: update — "…or start your own nats-server on the default port before core — core reuses a bus on `127.0.0.1:4222` only when a core answering it serves **this root**; a foreign harness or a bare nats-server with no core on it makes core warn and spawn an isolated bus instead (a leftover `var/nats-pid` naming one of this root's own buses is reclaimed first). To force a bus deliberately, set `NIF_NATS_URL`."
- MANUAL:2415-2416 `(the binary is the built component `var/bin/nats-server` from `components/nats` when present, else a PATH `nats-server`)` | CODE: `core/niffler.nim:51-60` (`natsServerBinary`: `getAppDir()/nats-server` wins, else `"nats-server"` from PATH, with the `ours` flag deciding the payload route) | FIX: none — verified accurate.
- MANUAL:2847 `| orphaned `nats-server` | a manually started `nats-server`, a non-Linux host (no PDEATHSIG to reap it), or a stale `var/nats-pid` left by SIGKILL — check the pid file (core verifies pid + comm, so a stale file is ignored), then `pkill -f nats-server` |` | CODE: `components/nats/pdeathsig_linux.go:12-21`, `components/nats/pdeathsig_other.go:4-6` (no-op off Linux), `core/niffler.nim:176-201` (pid + `commOf(pid) == "nats-server"` check), `Makefile:406-413` (`make down` pkills `nats-server`) | FIX: none — verified accurate.

## 6. Not user-facing

Everything internal here should stay internal, and does: the `--stdio`-free
argv composition, the temp `--ports_file_dir`, the `PR_SET_PDEATHSIG` call and
the generated payload config are core/component mechanics, not operator
surface. The single item worth documenting for a *user* is the 8 MiB payload
budget (above) — because it is the one number that explains a class of
"nothing came back" failures, and because an attached bus can violate it.

---

# `components/ctxtest/` — the test fixture component

Files: `main.nim` (884 lines), `sink.nim` (16 lines). Component names:
`ctxtest` (`main.nim:18`) and `ctxsink` (`sink.nim:6`) — the latter is a
**second, separate** component registered by the same directory.

## 1. What it is and why it exists

A **test-only fixture**, stated in its own header (`main.nim:1-8`):

> `## ctxtest — test-only component for the nested-call proxy (tests/t_nested.nim).`
> `## Not in the manifest; compiled and started by the test itself.`

It exists to make the session loop testable **without a real LLM and without a
real model's judgement**: it registers a stub `chat` (`main.nim:51-77`) that
plays a scripted conversation per `sessionId`, so a sandbox core runs complete
turns (tool calls, rounds, budgets, cancellations, subagent delegation,
compaction triggers) deterministically. The same file doubles as the fixture
for contract details a real component cannot safely produce on demand:
parameter-name mangling (`ctx_options`, dash/keyword names at `:769-786`), a
name collision pair (`ctx_collision`, `:787-791`), republish churn with an
inflated version (`ctx_republish`, `:792-807`), a declared read-effect tool for
the fabric batch scheduler (`ctx_sleep`, `:808-820`), a tool with a scalar
`outputSchema` (`ctx_out`, `:821-825`), and the session-context probe
(`ctxecho`, `:837-883`). `sink.nim` is the smallest possible
`sessionContext`-sink: `ctxinspect` returns `sawSession` so the test can prove
that harness-private context is **stripped** before a nested target sees its
arguments.

It is used by 12 contract tests: `t_nested`, `t_core`, `t_agent`,
`t_agentcont`, `t_agentdepth`, `t_agentfork`, `t_agentnotice`, `t_agentp3`,
`t_agentwake`, `t_fabric`, `t_fabric_cancel`, `t_systemprompt` (each compiles it
into its own sandbox: e.g. `tests/t_nested.nim:26-46`,
`tests/t_agent.nim:46-59`). Two sibling fixtures cover the other LLM shape:
`tests/mock_llm.nim` (compacted as the `llm` binary, for
`t_expert`/`t_compaction`/`t_controls`/`t_ctxcompact`/`t_compaction_conformance`)
and `tests/mock_parallel_llm.nim` (`t_parallel`).

## 2. Tools and `x-harness` flags

No manifest entry, no autostart, no supervision: the tests spawn the binaries
they compiled themselves (`startComponent(...)` under a private NATS). Schema
details (all eight tools are *direct* catalog tools, not `onDemand` — a fixture
harness wants them visible):

| Tool | Where | Flags (`x-harness`) | Purpose |
|---|---|---|---|
| `chat {messages, tools?, sessionId?, stream?, reasoning_effort?}` | `:51-77` | `{hidden: true}` | the stub LLM: scripted turns per session id; echoes `messages[0]` for `sp-*` sessions (`:753-765`), reports fake `usage` for `BIG_TOKENS`, raises for `FORCE_LLM_FAILURE`, sleeps for `SLOW_CHILD` |
| `ctx_options {requiredValue, optionalString?, optionalInt?, optionalBool?, ratio?, tags?, payload?, dash-value?, method?, mode?}` | `:769-786` | none (`additionalProperties: false`) | parameter-name/schema fidelity: dash and keyword names, enums, integer/bool/number/array/object types |
| `ctx_collision {foo_bar?, fooBar?}` | `:787-791` | none | name-collision behaviour in the generated guest wrapper |
| `ctx_republish {}` | `:792-807` | none | republishes its own registration with version `9.9.9` (catalog churn) |
| `ctx_sleep {ms, say?}` | `:808-820` | `{effect: "read"}` | the declared-read item the fabric batch host may overlap |
| `ctx_out {say}` | `:821-825` | `{effect: "read"}` + `outputSchema: {type: string}` | typed output schema for the fabric wrapper |
| `ctxecho {msg?}` | `:837-883` | `{sessionContext: true}` | the nested-call probe: live lease → `bash` (must succeed and return `nested-ok`), bogus lease → denied, hidden `session` tool → denied, `chat`/`invoke` → denied by name, missing required args → bad-args, stale selected-schema metadata → denied, and `ctxinspect` proves `__session` was stripped |
| `ctxinspect {value}` (`ctxsink`) | `sink.nim:8-15` | none | returns `{value, sawSession}` — `sawSession: false` is the assertion |

**What a user must do to use it: nothing, and there is nothing to do.** It is
absent from `manifest.yaml`, absent from `Makefile:305-313`
(`components-inner`) and from `niffler.nimble all_internal`, so `make build`
never produces `var/bin/ctxtest` and `make test` compiles it only inside a
temporary sandbox root (`nim c --hints:off --path:<repo>/sdk -o:<sandbox>/var/bin/ctxtest
components/ctxtest/main.nim`). To exercise it by hand you must reproduce that:
compile it yourself, start a core with a manifest that does not include it, and
spawn it with `core.spawn`/`startComponent`. Nothing in a normal harness
answers `svc.ctxtest.call`.

## 3. Configuration

Only two variables, both read at handler time (no config knobs of its own):

| Variable | Where | Default | Used for |
|---|---|---|---|
| `NIF_ROOT` | `main.nim:141`, `:172` | `getCurrentDir()` | the marker paths `var/slowbash-marker` and `var/fab-slowbash-marker` that the cancellation tests look for (an orphaned `sleep` would touch them) |
| `NIF_REPO_ROOT` | `main.nim:549, 630, 636, 648, 655, 662, 668, 676` | — (no fallback: `readFile("")` fails) | loads the fabric example programs (`components/fabric/examples/*.nim`) as guest source |

Both are the *test's* variables (`Makefile:510` exports `NIF_REPO_ROOT=$(ROOT)`,
`tests/helpers.nim:331-332` falls back to `NIF_ROOT`), inherited through the
sandbox core. `NIF_ROOT` is the documented component root; `NIF_REPO_ROOT` is
documented as a build/script-only knob — see the delta below.

## 4. How the MANUAL covers it today

**Absent.** The word `ctxtest` (and `ctxsink`) does not occur anywhere in
MANUAL.md — no row in the Shipped-components table (MANUAL:55-86), no mention in
`### Testing` (MANUAL:2718-2756), nothing in §Layout (MANUAL:38) even though
that row defines the table as the inventory of `components/`. The Testing
section describes the *suite* correctly but names no fixture:

- MANUAL:2729-2731 `Each test boots the real component binaries (Nim, Go *and*
  TypeScript — the envelope is the artifact, so one harness tests every SDK) and
  drives them over a private nats-server each test starts for itself
  (`NIF_NATS_SPAWN`-style isolation).`
- MANUAL:2740-2741 `Core-based tests snapshot their required binaries into a
  unique temporary `NIF_ROOT`; Barrel, plugin clones, generated components,
  logs, and caches are therefore isolated.`
- MANUAL:2742-2743 `Repository build writes are serialized, while agent-built
  test components use sandbox-local Nim caches.`

The one sentence that covers it in spirit is "agent-built test components use
sandbox-local Nim caches" — but a reader cannot tell from the MANUAL that the
fixtures exist, that one of them is a **stub LLM**, or that they are compiled by
the tests rather than built by `make build`.

## 5. DELTA list

## Testing

- MANUAL: absent (the test-only fixture components and stub LLMs: what they are, that they are compiled by the tests and never by `make build`, and that they are deliberately not in the manifest) | CODE: `components/ctxtest/main.nim:1-8` ("Not in the manifest; compiled and started by the test itself"), `components/ctxtest/sink.nim:1-15` (component `ctxsink`), `tests/t_nested.nim:26-46`, `tests/mock_llm.nim:1`, `tests/mock_parallel_llm.nim:1`, `Makefile:305-313` + `niffler.nimble:26-53` (neither builds `ctxtest`) | FIX: add — one paragraph after MANUAL:2743: "Several tests carry their own fixtures instead of a real model: `components/ctxtest/` is a **stub-LLM component** (tool `chat`, `x-harness.hidden`) that plays a scripted turn per session id, plus the contract fixtures the real tools cannot produce on demand (parameter-name mangling, a schema collision, catalog republish churn, an `effect: "read"` item for the fabric batch host, a scalar `outputSchema`, and `ctxecho` — the `sessionContext` probe that exercises the nested-call proxy and proves harness-private context is stripped). Its neighbour `components/ctxtest/sink.nim` registers a second component `ctxsink` for the same check (`sawSession`). `tests/mock_llm.nim` and `tests/mock_parallel_llm.nim` are the equivalent stand-ins for the `llm` binary. None of them is in `manifest.yaml`, none is built by `make build` — each test compiles the one it needs into its private sandbox `NIF_ROOT` and spawns it there."
- MANUAL:2742-2743 `Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches.` | CODE: `tests/helpers.nim:316-329` (`newCoreSandbox`: symlinked `sdk`, generated `config.nims` with `switch("nimcache", thisDir() / "var" / "nimcache")`, copied `niffler.nimble`), `tests/t_nested.nim:31-46` (two `nim c` compiles into `sandboxBin`) | FIX: update (optional, one clause) — "…while test-only components (and agent-built ones) are compiled with a sandbox-local `nimcache` by the test that needs them."

## Shipped components

- MANUAL:55-86 (table, no `ctxtest`/`ctxsink` row) with MANUAL:38 `| `components/` | shipped component sources — one directory per component (Nim, Go, TypeScript and one bash demo); the inventory is the [Shipped components](#shipped-components) table below, which is the part that has to stay current |` | CODE: `components/ctxtest/` is one of the directory's 34 component dirs but is not shipped: `manifest.yaml` has no entry, `Makefile:305-313` does not build it, its own header says so (`main.nim:1-8`) | FIX: add — one sentence under the Shipped-components table (MANUAL:86): "`components/ctxtest/` is the exception to "one directory per component = shipped": it is the contract tests' own fixture (a stub LLM plus schema/nested-call probes, registering the components `ctxtest` and `ctxsink`) — not in this table, not in `manifest.yaml`, and never built by `make build`."

## Environment variables

- MANUAL:352 `NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness | CODE: `components/ctxtest/main.nim:549,630,636,648,655,662,668,676` — `NIF_REPO_ROOT` is read by a *running component process* (the fixture) to load `components/fabric/examples/*.nim`; `tests/helpers.nim:331` reads it too | FIX: update — "…and are never consulted by a shipped component (the test-only `ctxtest` fixture reads `NIF_REPO_ROOT` to load the fabric examples), so they are not part of the runtime table below."

## 6. Not user-facing

Nothing in `ctxtest` should reach the MANUAL's user surface except the one
paragraph proposed under `### Testing`, because the fixture is a *test* fact, not
a capability: it has no user-facing tool, no config, no store kind, no event, no
slash command, and it cannot be present in a normal harness at all (no manifest
entry, no binary in `var/bin`). Documenting its session-id script grammar in the
MANUAL would be documenting the tests inside the operator manual — the right home
for that is the file's own comments, which already carry it (`main.nim:64-765`, the
`chat` dispatcher: `agent-*`, `agt-*`, `fcs-*`, `cnt-*`, `frk-*`,
`ntc-*`, `lst-multi`, `si-live`, `ws-*`, `fab-*`, `sp-*`).
