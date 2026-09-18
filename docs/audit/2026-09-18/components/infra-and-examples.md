# Audit: infrastructure and example components

Scope: `components/nats/`, `components/ctxtest/`, `components/systemprompt/`,
`components/llm-openai/`, `components/mcp-bridge/` — audited against
`docs/MANUAL.md` plus `manifest.yaml`, `Makefile`, `niffler.nimble`,
`core/niffler.nim` and the tests that own each fixture. Read-only audit: no
MANUAL or component source was edited.

**Revision note (read this before using a line number).** Every line number below
was re-anchored onto the MANUAL revision of the final pass — **3072 lines**
(`git log -1` = `2bd9513 docs: audit — the open-row edit set batch-open-2`). The
manual is being edited *concurrently* by this audit's own consolidation batches
(it grew 2850 → 3072 while this report was written), so numbers keep shifting:
**the quoted text, not the number, is the anchor.** Where a quote was re-located
in the final pass the number is current; for a few internal sentences (noted
inline) only the enclosing bullet's range is given. Findings a concurrent batch
has already absorbed are marked `[already applied]` — currently only the two
Layout/Testing mentions of `components/nats` and `components/ctxtest`; the
Shipped-components *table*, the 8 MiB payload budget, `prompt_hint`,
`mcp_<server>_bridge_status`, the `$ROOT`-substitution claim and the
ancestor-walk claim are all still as reported.

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

  - MANUAL.md:38 `| `components/` | shipped component sources — one directory per
  component (Nim, Go, TypeScript and one bash demo); the inventory is the
  [Shipped components](#shipped-components) table below, which is the part that
  has to stay current. Two directories are not bus citizens: `components/nats`
  builds the `var/bin/nats-server` core spawns when a bus has to be started, and
  `components/ctxtest` is a fixture the nested-call tests (`t_fabric`,
  `t_agent`) compile for themselves |` — **`[already applied]`** by a concurrent
  batch, which added the last sentence naming the bus component; the **table
  itself (MANUAL:55-86) still has no `nats-server` row**, and that is where a
  reader looking for "what ships" lands.
  - MANUAL.md:45 `| `var/nats-url` | bus address of the last spawned bus; the UI
  bridge reads it to find core |`; MANUAL:46 `| `var/nats-monitor-url` | HTTP
  monitoring endpoint when core spawned the bus; absent for reused/remote
  buses |`; MANUAL:51 `| `var/nats-pid` | pid of the bus core spawned (crash
  cleanup only — a live core stops its own bus on exit) |`.
  - MANUAL.md:392/393 — the `NIF_NATS_URL` / `NIF_NATS_SPAWN` rows (both accurate,
  including the home-bus probe rules).
  - MANUAL.md:2371-2372 `The only core integration is optional nats-server HTTP
  monitoring: when core owns the bus it allocates a second loopback port and
  writes `var/nats-monitor-url` after the server is live.`
  - MANUAL.md:2565-2567 `When core spawns nats-server it uses distinct loopback
  client and HTTP ports, then writes (the binary is the built component
  `var/bin/nats-server` from `components/nats` when present, else a PATH
  `nats-server`):` — the closest thing to a component description.
  - MANUAL.md:2574-2576 `NIF_NATS_SPAWN=1` forces an isolated core-owned bus on a
  random port … never 4222; an explicit `NIF_NATS_URL` in the environment wins.
  - MANUAL.md:3038-3041 `- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222`
  (even remote), or start your own nats-server on the default port before core —
  core reuses a live bus on `127.0.0.1:4222` and only spawns its own (the built
  `var/bin/nats-server` component) when none answers.`
  - MANUAL.md:3069 the `orphaned nats-server` troubleshooting row (correct: manual
  nats-server, non-Linux host, stale `var/nats-pid`).

Explicitly **absent** from the MANUAL, top to bottom: the `--max_payload`
extension and the 8 MiB requirement (and the boot warning for a smaller
attached bus); the config-file fallback for a PATH nats-server; the fact that
the bundled binary is deliberately not in `manifest.yaml`; the ports-file
handshake and the home-port-then-random attempt order; `make doctor`'s report
for the binary and the no-op `make install-nats`.

## 5. DELTA list

## Layout of a running system

- MANUAL:55-86 (table: `store`…`dialog`, no `nats-server` row), against MANUAL:38 which declares that table the inventory of `components/` (`[already applied]` for the *sentence* — it now names `components/nats`; the **table row is still absent**) | CODE: `components/nats/main.go:1-14`, `components/nats/go.mod:1-4` (module `nats`, nats-server v2.14.6), `Makefile:262-266` (`var/bin/nats-server`), `Makefile:310-313` (it is in the `components-inner` binary list), `manifest.yaml` (no entry) | FIX: add — `| `nats-server` | Go | **not in the manifest** | the bus itself as a first-class component: a faithful rebuild of the official `nats-server` main (pinned in `components/nats/go.mod`), built by `make build` into `var/bin/nats-server` and preferred by core over a PATH install, so no NATS prerequisite is needed. Deliberately *not* a bus component — core starts it before the bus exists, it registers no tools, and `core.spawn` cannot start it. Niffler adds one flag, `--max_payload <bytes>` (core passes 8388608); on Linux it sets `PR_SET_PDEATHSIG` so no orphaned bus outlives its harness |`

## The bus in one screen

- MANUAL: absent (the 8 MiB payload budget, the `--max_payload` extension and the boot warning for a smaller attached bus) | CODE: `core/niffler.nim:46-49` (`const natsMaxPayload = 8388608`), `:92-93` (bundled binary gets `--max_payload`), `:63-72,:94-95` (a PATH nats-server gets a generated `max_payload` config file instead), `:400-414` (`natsConnection_GetMaxPayload` → `core: WARNING bus at … caps messages at N bytes …`) | FIX: add — "A request carries a whole conversation, so the bundled bus is started with `max_payload: 8388608` (8 MiB — ≈2M tokens of JSON; above that nats-server only warns). The bundled `var/bin/nats-server` takes it as an extra flag, a PATH nats-server gets it in a generated config file instead. When core attaches to a bus it did not spawn it reads the server's real cap and warns at boot if it is below 8 MiB: such a bus rejects a large reply at publish time and the caller waits out its full timeout, which looks like a component hang rather than a bus limit."
- MANUAL: absent (the port handshake: `--ports_file_dir` + `.ports` polling, and the home-port-then-random attempt order) | CODE: `core/niffler.nim:78-116` | FIX: add (one clause, §Monitoring) — "Ports are allocated by NATS itself: core passes `--ports_file_dir <tmp>` and reads the `*.ports` file it writes (bounded 4 s wait), so concurrent harnesses cannot win a bind-close-start race. The attempt order is the home port first, then a random one."

## Common tasks

- MANUAL: absent (how the bundled bus is obtained: `make build` compiles it; `make doctor` reports/explains it; there is no `make install-nats` — the target is a stub that says so) | CODE: `Makefile:262-266`, `Makefile:620-623` (`nats-server: OK` / `built from source by 'make build' (components/nats)`), `Makefile:698-699` (`install-nats` prints "nothing to install") | FIX: add — one bullet under **Attach to any bus**: "The bus binary ships with the repo: `make build` compiles `components/nats` into `var/bin/nats-server` (there is nothing to install — `make install-nats` only says so, and `make doctor` reports `nats-server: OK` or explains that it is built from source)."

## Troubleshooting

- MANUAL:3038-3041 `or start your own nats-server on the default port before core — core reuses a live bus on `127.0.0.1:4222` and only spawns its own (the built `var/bin/nats-server` component) when none answers.` | CODE: `core/niffler.nim:176-201` (`probeBus` → `bkFree`/`bkOurs`/`bkForeignCore`/`bkBareNats`), `:354-383` (only `bkOurs` reuses; foreign core and bare nats-server both print a WARNING and spawn an isolated bus; a bare bus is reclaimed only when `var/nats-pid` names *our own* live nats-server — `reclaimOwnNats`, `:176-201`) | FIX: update — "…or start your own nats-server on the default port before core — core reuses a bus on `127.0.0.1:4222` only when a core answering it serves **this root**; a foreign harness or a bare nats-server with no core on it makes core warn and spawn an isolated bus instead (a leftover `var/nats-pid` naming one of this root's own buses is reclaimed first). To force a bus deliberately, set `NIF_NATS_URL`."
- MANUAL:2566-2567 `(the binary is the built component `var/bin/nats-server` from `components/nats` when present, else a PATH `nats-server`)` | CODE: `core/niffler.nim:51-60` (`natsServerBinary`: `getAppDir()/nats-server` wins, else `"nats-server"` from PATH, with the `ours` flag deciding the payload route) | FIX: none — verified accurate.
- MANUAL:3069 `| orphaned `nats-server` | a manually started `nats-server`, a non-Linux host (no PDEATHSIG to reap it), or a stale `var/nats-pid` left by SIGKILL — check the pid file (core verifies pid + comm, so a stale file is ignored), then `pkill -f nats-server` |` | CODE: `components/nats/pdeathsig_linux.go:12-21`, `components/nats/pdeathsig_other.go:4-6` (no-op off Linux), `core/niffler.nim:176-201` (pid + `commOf(pid) == "nats-server"` check), `Makefile:406-413` (`make down` pkills `nats-server`) | FIX: none — verified accurate.

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

**Absent from the table and from `### Testing`.** The word `ctxtest` (and
`ctxsink`) does not occur in the Shipped-components table (MANUAL:55-86) nor in
`### Testing` (MANUAL:2911-2949). It *does* occur once in §Layout, in a sentence
a concurrent audit batch added while this report was being written — `[already
applied]`: MANUAL:38 now ends with "Two directories are not bus citizens:
`components/nats` builds the `var/bin/nats-server` core spawns when a bus has to
be started, and `components/ctxtest` is a fixture the nested-call tests
(`t_fabric`, `t_agent`) compile for themselves" — which is correct but names two
of the twelve tests that use it and leaves the fixture invisible to anyone
reading the table. The Testing section describes the *suite* correctly but names
no fixture:

  - MANUAL.md:2922-2924 `Each test boots the real component binaries (Nim, Go *and*
  TypeScript — the envelope is the artifact, so one harness tests every SDK) and
  drives them over a private nats-server each test starts for itself
  (`NIF_NATS_SPAWN`-style isolation).`
  - MANUAL.md:2931-2932 `Core-based tests snapshot their required binaries into a
  unique temporary `NIF_ROOT`; Barrel, plugin clones, generated components,
  logs, and caches are therefore isolated.`
  - MANUAL.md:2934-2936 `Repository build writes are serialized, while agent-built
  test components use sandbox-local Nim caches.`

The one sentence that covers it in spirit is "agent-built test components use
sandbox-local Nim caches" — but a reader cannot tell from the MANUAL that the
fixtures exist, that one of them is a **stub LLM**, or that they are compiled by
the tests rather than built by `make build`.

## 5. DELTA list

## Testing

- MANUAL: absent (the test-only fixture components and stub LLMs: what they are, that they are compiled by the tests and never by `make build`, and that they are deliberately not in the manifest) | CODE: `components/ctxtest/main.nim:1-8` ("Not in the manifest; compiled and started by the test itself"), `components/ctxtest/sink.nim:1-15` (component `ctxsink`), `tests/t_nested.nim:26-46`, `tests/mock_llm.nim:1`, `tests/mock_parallel_llm.nim:1`, `Makefile:305-313` + `niffler.nimble:26-53` (neither builds `ctxtest`) | FIX: add — one paragraph after MANUAL:2936: "Several tests carry their own fixtures instead of a real model: `components/ctxtest/` is a **stub-LLM component** (tool `chat`, `x-harness.hidden`) that plays a scripted turn per session id, plus the contract fixtures the real tools cannot produce on demand (parameter-name mangling, a schema collision, catalog republish churn, an `effect: "read"` item for the fabric batch host, a scalar `outputSchema`, and `ctxecho` — the `sessionContext` probe that exercises the nested-call proxy and proves harness-private context is stripped). Its neighbour `components/ctxtest/sink.nim` registers a second component `ctxsink` for the same check (`sawSession`). `tests/mock_llm.nim` and `tests/mock_parallel_llm.nim` are the equivalent stand-ins for the `llm` binary. None of them is in `manifest.yaml`, none is built by `make build` — each test compiles the one it needs into its private sandbox `NIF_ROOT` and spawns it there."
- MANUAL:2934-2936 `Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches.` | CODE: `tests/helpers.nim:316-329` (`newCoreSandbox`: symlinked `sdk`, generated `config.nims` with `switch("nimcache", thisDir() / "var" / "nimcache")`, copied `niffler.nimble`), `tests/t_nested.nim:31-46` (two `nim c` compiles into `sandboxBin`) | FIX: update (optional, one clause) — "…while test-only components (and agent-built ones) are compiled with a sandbox-local `nimcache` by the test that needs them."

## Layout of a running system

- MANUAL:55-86 (table, no `ctxtest`/`ctxsink` row) with MANUAL:38 (which, in the current revision, **`[already applied]`**, names `components/ctxtest` as "a fixture the nested-call tests (`t_fabric`, `t_agent`) compile for themselves" — two of the twelve tests that use it, and still not in the table) | CODE: `components/ctxtest/` is one of the directory's 34 component dirs but is not shipped: `manifest.yaml` has no entry, `Makefile:305-313` does not build it, its own header says so (`main.nim:1-8`) | FIX: add — one sentence under the Shipped-components table (MANUAL:86): "`components/ctxtest/` is the exception to "one directory per component = shipped": it is the contract tests' own fixture (a stub LLM plus schema/nested-call probes, registering the components `ctxtest` and `ctxsink`) — not in this table, not in `manifest.yaml`, and never built by `make build`."

## Environment variables

- MANUAL:387 `NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness | CODE: `components/ctxtest/main.nim:549,630,636,648,655,662,668,676` — `NIF_REPO_ROOT` is read by a *running component process* (the fixture) to load `components/fabric/examples/*.nim`; `tests/helpers.nim:331` reads it too | FIX: update — "…and are never consulted by a shipped component (the test-only `ctxtest` fixture reads `NIF_REPO_ROOT` to load the fabric examples), so they are not part of the runtime table below."

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

---

# `components/systemprompt/` — the pluggable constitution

Files: `main.nim` (277 lines), `baseprompt.txt` (the product prompt, baked in).
Component `systemprompt` (`main.nim:119`), **in** the manifest
(`manifest.yaml:50-59`: `autostart: true`, `required: false`,
`restart: on-failure`), built into `var/bin/systemprompt`
(`Makefile:234-236`, `niffler.nimble:30`).

## 1. What it is and why it exists

It owns the **conversation constitution**: core deliberately keeps only a
minimal structural fallback (`core/conversation.nim:35-66`, ~10 lines naming the
harness root and the file tools), and the real system prompt is composed by this
component and fetched once per conversation by the session runner
(`svc.systemprompt.call`, `core/conversation.nim:82-101`). The point is
pluggability: the standing instructions are a *component*, so replacing them is
an ordinary harness operation, not a core edit.

Its composition (`main.nim:166-272`):

1) `basePrompt` = `staticRead("baseprompt.txt")` (`:36`) — the product prompt
   (change-scope discipline, tool-selection guidance, the niffler-docs hint),
   compiled in, so it works from any runtime root. **Verbatim: there is no
   substitution of any kind** (no `$ROOT`, no template).
2) The three named prompt slots `tool_usage`, `efficient_tools`,
   `after_instructions` (`:241-245`), each rendered from registered
   `prompt_hint` contributions as `<prompt_slot name="…">…</prompt_slot>`;
   a slot with no contributions is omitted entirely.
3) A `<workspace>` tail when the conversation's cwd is not the harness root
   (`:262-270`) — deliberately the only machine-specific part, appended last so
   the frozen head stays byte-stable for provider prompt caching.
4) `<project_context>` / `<project_instructions path="…">` blocks for the local
   context files (`:272-283`): per directory the first hit of
   `AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`
   (`:44-45`, `:48-60`), **plus** `AGENTS.local.md` additively (`:46`, `:62-72`),
   walking from the conversation's cwd up to and including the harness root
   (`stopAbove`, `:204`; outside the root the walk is the workspace itself), and
   deduplicating by **file identity** (`fileId` = `device:inode`, `:74-84`) so a
   symlink farm cannot inject the same instructions twice.
5) Two caps, both constants: `maxFiles = 16` context files (`:33`) and
   `maxPromptLen = 200_000` bytes inside the component (`:29`), matching core's
   own 200 000-byte truncation (`core/conversation.nim:96-98`).

The worktree shadow rule (`:183-204`) skips the *main* repo's context file when
the harness root is a linked `git worktree` nested under it.

## 2. Tools and `x-harness` flags

Two tools, both **hidden** (client/core API — the model never sees them) and
both on `svc.systemprompt.call`:

| Tool | Where | Flags | Purpose |
|---|---|---|---|
| `systemprompt {cwd?}` | `:160-272` | `{hidden: true, timeoutMs: 5000}` (`:164`) | compose and return `{systemPrompt, contextFiles}` for a new conversation; `cwd` defaults to `NIF_ROOT` and is `expandTilde`d (`:167`) |
| `prompt_hint {slot, content, source?, key?, mode?}` | `:122-158` | `{hidden: true, timeoutMs: 5000}` (`:129`) | register a prompt fragment for **future** conversations: `slot` 1–64 chars `[a-z0-9_]`, `content` 1–16384 bytes, `mode` `aggregate` (default; keyed by `slot+source+key`) or `singleton` (keyed by slot, later registration replaces the previous one); returns `{slot, source, key}` |

There are no `x-harness.workspace`, `onDemand`, `approval`, `sessionId` or
`effect` flags — both are plain hidden service tools. The component also has **no
store kind, no event subject, no slash command**; the only other surface is the
`contextFiles` count in the answer, which core's `prompt_preview` uses
indirectly.

**Spawn policy**: shipped and autostarted like any manifest component — nothing
for a user to do. It *is* replaceable, but see the Boundary/Boot deltas below:
replacement by `kill` + `spawn` lasts until the next boot (`core/niffler.nim`
restores manifest names first and skips stored duplicates).

## 3. Configuration

| Variable | Where | Default | Effect |
|---|---|---|---|
| `NIF_ROOT` | `main.nim:120` | `getCurrentDir()` | the harness root: the default `cwd`, the walk's stop directory, and the root for root-relative `<project_instructions path>` attributes |

**No other variable.** Neither cap (`maxPromptLen`, `maxFiles`), the slot list,
the candidate filenames, the worktree rule nor the 5 s tool timeout is
configurable at runtime — all are compile-time constants (`:29`, `:33`, `:44-46`,
`:129`, `:164`, `:240-245`). A user who wants a different cap or a different
candidate list rebuilds `var/bin/systemprompt` (the constitution is explicitly
the replaceable part). Core-side numbers that shape the behaviour are also
constants: 500 ms probe, 8 s retry budget, 200 000-byte cap
(`core/conversation.nim:67`, `:90-98`).

## 4. How the MANUAL covers it today

It has a **dedicated section, MANUAL:2297-2361**, plus a table row and TOC
entry — the most thoroughly covered component of this report:

  - MANUAL.md:77 `| `systemprompt` | Nim | optional | the conversation constitution: session runners fetch the system prompt from `svc.systemprompt.call` once per conversation (see [System prompt (`systemprompt`)](#system-prompt-systemprompt)) |`
  - MANUAL.md:2303-2307 `The system prompt is not a tool the LLM calls — it is the standing / instruction set every conversation starts under. It lives in a component, / not in core: core keeps only a minimal structural fallback, and a session / runner fetches the real constitution from `svc.systemprompt.call` once per / conversation.`
  - MANUAL.md:2307-2310 `Replacing the constitution is a normal Niffler operation: write a component that answers on the same subject, `build` it, `kill` the old one, `spawn` yours. The agent can do this to itself.`
  - MANUAL.md:2314-2318 (Frozen per conversation), 2176-2178 (`- **Fallback.** Component absent, slow (500 ms probe, then an 8 s budget when the catalog says it is registered), or broken → core's baked-in minimal prompt. Core never hard-depends on a component for boot.`), 2179 (`- **Cap.** Answers are truncated at 200 KB (both sides).`), 2180-2183 (agent pre-fetch) — all four verified correct.
  - MANUAL.md:2329-2332 `1. `components/systemprompt/baseprompt.txt` — the product prompt (self-extension ladder, SDK examples, repo layout), `$ROOT`-substituted, baked into the binary at compile time via `staticRead`. Editing it is rebuild + respawn; there is no runtime file dependency.`
  - MANUAL.md:2337-2339 `- per directory, first hit wins: `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` (one file per directory — `AGENTS.md` shadows a `CLAUDE.md` next to it; symlinks are followed);`
  - MANUAL.md:2340-2342 `- ancestor walk from the conversation's cwd up to `/`, harness root first, deduplicated by path — nearer-to-cwd files appear later, so the most specific instructions are the last thing the model reads;`
  - MANUAL.md:2343-2345 (worktree shadow rule), 2202-2207 (lazy loading, the one place `AGENTS.local.md` is named), 2208-2216 (`<workspace>` tail).
  - MANUAL.md:2360-2361 `The tool is `x-harness.hidden` — it never appears in an LLM toolset; it is infrastructure, reachable only by core and by components.`

**Absent** from the section, and from the whole MANUAL: the `prompt_hint` tool
and the three slots (the website and `CHANGELOG.md` document them:
`website/components.html:53`, `CHANGELOG.md:337-341`), the `<prompt_slot>`
rendering, `AGENTS.local.md` as part of the *static* walk (only the lazy bullet
names it), the `maxFiles = 16` / `200 000`-byte constants and the fact that
neither has an env knob, the `contextFiles` field, and any statement about what
`cwd` (the only argument) does.

## 5. DELTA list

## System prompt (`systemprompt`)

- MANUAL:2331 `(self-extension ladder, SDK examples, repo layout), `$ROOT`-substituted,` | CODE: `components/systemprompt/main.nim:36` (`const basePrompt = staticRead("baseprompt.txt")`), `:240` (`var prompt = basePrompt` — used verbatim; there is no `%`/`replace`/`strformat` pass anywhere in the file), `:262-270` (the root reaches the prompt only through the optional `<workspace>` tail, and as a comment explicitly forbids `$ROOT` in the head) | FIX: update — "1. `components/systemprompt/baseprompt.txt` — the product prompt (change-scope discipline, tool-selection guidance, the docs pointer), baked into the binary verbatim at compile time via `staticRead` (no substitution, no template). Editing it is rebuild + respawn; there is no runtime file dependency."
- MANUAL:2340-2341 `- ancestor walk from the conversation's cwd up to `/`, harness root first, deduplicated by path` | CODE: `components/systemprompt/main.nim:204` (`let stopAbove = if cwd == root or cwd.startsWith(root & "/"): root else: cwd`), `:209-226` (the loop breaks at `stopAbove`, so the walk is cwd→root **inclusive** for an in-root workspace and a single directory for a workspace outside the root; nothing above the harness root is ever read), `:74-84` + `:217-219` (`fileId` = `device:inode`, dedupe by identity, not by path — a symlink farm re-exposing the root would otherwise inject the same `AGENTS.md` twice) | FIX: update — "- ancestor walk from the conversation's cwd **up to the harness root (inclusive)**, root first, deduplicated by file identity (device:inode, so a symlink farm cannot inject the same file twice) — nearer-to-cwd files appear later, so the most specific instructions are the last thing the model reads. A workspace **outside** the harness root walks its own directory only: nothing above the deployment root leaks into the prompt (an unrelated `AGENTS.md` in `$HOME` in particular)."
- MANUAL:2337-2339 (per-directory candidate list, no `AGENTS.local.md`) | CODE: `components/systemprompt/main.nim:46` (`const localCandidate = "AGENTS.local.md"`), `:62-72` (`loadLocalContextFileFromDir` — additive, explicitly *not* a shadowing candidate), `:212-218` (called for **every** directory of the walk, after that directory's primary file) | FIX: update — append to the bullet: " plus `AGENTS.local.md` additively (it never shadows the primary file, and it is loaded for every directory of the walk, not only lazily)."
- MANUAL: absent (`prompt_hint` and the prompt slots) | CODE: `components/systemprompt/main.nim:122-158` (tool + validation), `:86-110` (`PromptHint` table, `renderPromptSlot`, deterministic sort by `source\x1fkey`), `:241-245` (the three slots rendered as `<prompt_slot name="…">`); exercised by `tests/t_systemprompt.nim:154-176`; already described for users in `website/components.html:53` and `CHANGELOG.md:337-341` | FIX: add — a fourth bullet to `### How it works` and a sentence to the closing paragraph: "- **Prompt slots (extension seam).** Components and plugins contribute fragments through the hidden `prompt_hint {slot, content, source?, key?, mode?}` tool: named slots (`tool_usage`, `efficient_tools`, `after_instructions`) are rendered into `<prompt_slot name="…">` blocks in deterministic order (sorted by source then key); `mode: aggregate` (default) keeps every contribution and `mode: singleton` keeps only the last one registered for that slot; a slot with no contributions renders nothing. Registration is component-local state and affects only prompts composed **after** it — a frozen conversation is never rewritten. Both `systemprompt` and `prompt_hint` are `x-harness.hidden`; they never appear in an LLM toolset."
- MANUAL: absent (the two caps are constants with no env knob: 16 context files, 200 000 bytes on both sides) | CODE: `components/systemprompt/main.nim:29` (`maxPromptLen = 200_000`), `:33` (`maxFiles = 16`), `:223-224` (the loop stops at the file cap), `:268-270` (truncation marker `[systemprompt: truncated at 200000 bytes]`), `core/conversation.nim:96-98` (core's own truncation marker) | FIX: add — one sentence after MANUAL:2322: "Two more numbers are compile-time constants with no env knob: at most 16 context files are collected, and the component truncates at 200 000 bytes itself (marker `[systemprompt: truncated at 200000 bytes]`) before core applies its own cap — a different cap means rebuilding the component."
- MANUAL:2307-2310 `Replacing the constitution is a normal Niffler operation: write a component that answers on the same subject, `build` it, `kill` the old one, `spawn` yours.` | CODE: `core/catalog.nim:79-95` (`spawn` refuses a name that is already supervised), `core/dispatch.nim:347-355` (`kill` → `removeChild`, works for manifest children too), `core/niffler.nim:471-506` (boot adds every manifest component unconditionally), `core/niffler.nim:600-604` (`if alreadyManifest: continue  # shipped manifest definition wins` — a stored spawn record whose name is in `manifest.yaml` is **silently skipped** on every later boot) | FIX: update — "Replacing the constitution is a normal Niffler operation: write a component that answers on the same subject, `build` it, `kill` the old one, `spawn` yours **under the same name** (`systemprompt` — that is the subject). Two cautions: the swap lasts only until the next boot, because a component declared in `manifest.yaml` is always restored first and a stored duplicate for the same name is skipped (`core/niffler.nim`), so a *permanent* replacement means editing `manifest.yaml`; and registering a differently-named second component that also answers `svc.systemprompt.call` does **not** replace the shipped one — both answer and the first reply wins."
- MANUAL:2323-2326 (agent pre-fetch) | CODE: `components/agent/main.nim:867-885` (requests `systemprompt` with `{cwd}`, passes the answer as the session call's `systemPrompt`) | FIX: none — verified accurate.
- MANUAL:2322 `- **Cap.** Answers are truncated at 200 KB (both sides).` | CODE: `components/systemprompt/main.nim:268-270` (200_000 bytes), `core/conversation.nim:96-98` (200_000 bytes) | FIX: none — verified accurate.
- MANUAL:2319-2321 (fallback: 500 ms probe, then 8 s when registered) | CODE: `core/conversation.nim:90-101` (`askSystemPrompt(ct, 500, …)`, then `systemPromptTimeoutMs = 8_000` only `if ct.cat.components.hasKey("systemprompt")`, else the baked-in `systemPromptFmt`) | FIX: none — verified accurate.
- MANUAL:2343-2345 (worktree shadow rule) | CODE: `components/systemprompt/main.nim:183-204` (reads `<root>/.git` for a `gitdir:` pointer, matches `/.git/worktrees/`, shadows only the same candidate filename in the main root) | FIX: none — verified accurate; note the rule requires `cwd` to be **inside** the harness root (`:185`), which the MANUAL does not state (optional clarification).
- MANUAL: absent (nothing in the MANUAL covers the component's own I/O — a MANUAL-neutral intra-component defect) | CODE: `components/systemprompt/main.nim:210` (`let f = loadContextFileFromDir(dir)` — a dead call: the same directory is re-read as `primary` at `:212` and the outer `f` is shadowed by the loop variable at `:216`) | FIX: (code) — delete line 210; it costs one redundant `readFile` per directory of the ancestor walk (and a duplicated `systemprompt: unreadable context file …` stderr line for an unreadable file), and `--hints:off` is what hides the unused-symbol warning.

## Environment variables

- MANUAL: absent (no statement that the component's caps, candidate list, slot list and timeouts are constants with no env knob) | CODE: `components/systemprompt/main.nim:29,33,44-46,129,164,240-245`; the only `getEnv` in the file is `:120` (`NIF_ROOT`) | FIX: add — the cap sentence proposed above, which doubles as the "no env knob, rebuild it" statement.

## Self-extension and component lifecycle

- MANUAL:928-931 `**Persistence of shape**: spawned components are recorded in the store (kind `component`) and restored on normal boot.` (and MANUAL:896-897 `kill {name}` stops every replica temporarily (restored on next boot); `remove {name}` stops the group and deletes its persisted record.) | CODE: `core/niffler.nim:600-604` — the restore loop **skips** a stored record whose name is already in the manifest (`# shipped manifest definition wins`), with no warning; `remove` leaves no tombstone, so a manifest component always returns at boot regardless of `kill`/`remove` | FIX: update — append: "A stored record whose name is also declared in `manifest.yaml` is skipped on restore (the shipped definition wins, silently), so replacing a shipped component means editing the manifest — `kill`+`spawn` under the same name only holds for the current boot."
- MANUAL: absent (the silent skip of a manifest-shadowed spawn record) | CODE: `core/niffler.nim:600-604` (`continue` with no echo, unlike the sibling `WARNING stored component … has missing binary` at `:620-621`) | FIX: (code) — echo one `core: WARNING stored component <name> skipped: the manifest declares it` when a stored record is skipped, so a replaced-and-forgotten component is diagnosable instead of invisible.

## 6. Not user-facing

The two tools must stay out of a normal conversation (both `hidden`, and neither
is `onDemand`, so they are also never offered to `discover`): they are core's and
plugins' API. What *is* user-facing, and currently only in the website/CHANGELOG,
is the `prompt_hint` seam — a plugin component that wants to add standing
instructions for future conversations has no MANUAL entry point today.

---

# `components/llm-openai/` — the minimal swap-in provider example

Files: `main.go` (218 lines), `main_test.go` (the three `contextWindow` unit
tests), `go.mod`/`go.sum` (`module llm-openai`, `replace niffler.dev/sdk =>
../../sdk/go`). Built into `var/bin/llm-openai` by `make build`
(`Makefile:259-260`, `niffler.nimble:47`), **never spawned by default** — the
manifest entry is commented out (`manifest.yaml:250-254`).

## 1. What it is and why it exists

It is the demonstration that the LLM adapter is a **replaceable ordinary
component**: one hidden tool named `chat` on `svc.llm-openai.call`, ~150 lines
of Go, no streaming, no provider registry — "A component like any other: tool
"chat" is hidden from the LLM (`x-harness.hidden`) and called by the core
conversation loop" (`main.go:1-6`). Swap it in for `llm` and a conversation
still runs end to end; that is its whole reason to exist (`manifest.yaml:250`
`# Minimal example adapter (same tool contract, no streaming).`).

What it does per call (`main.go:59-193`):

1) validate `messages` (`:60-65`); resolve the model as `args.model` →
   `NIF_OPENAI_MODEL` → `"deepseek-chat"` (`:66-74`); the base URL as
   `NIF_OPENAI_BASE_URL` → `https://api.openai.com/v1` (`:75-78`); require
   `NIF_OPENAI_API_KEY` (`:79-82`, an explicit error before any HTTP);
2) POST `{base}/chat/completions` with `{model, messages, tools?, max_tokens:
   32768}` (`:84-101`), `Authorization: Bearer …`, one fresh
   `http.Client{Timeout: 300 * time.Second}` (`:103`) — no shared client across
   calls, which is what makes `ToolConcurrent` safe here;
3) normalize the reply into one JSON object (`:155-190`): `content`, `model`,
   `context` (the window, computed locally by `contextWindow`, `:47-57`),
   `usage` **only when at least one token counter is non-zero** (`:162-168`),
   and `tool_calls` in the OpenAI shape with `id`/`type`/`function` — accepting
   both the nested and the DeepSeek *flat* variant (`:170-189`).

Context window resolution (`:29-57`) is deliberately tiny: env → a two-entry
built-in table → a conservative 128 000:

| Step | Value |
|---|---|
| `NIF_OPENAI_CONTEXT` (positive integer) | wins outright (`:48-52`) |
| built-in table, lowercase model id (`:40-43`) | `deepseek-chat` 1 000 000, `deepseek-reasoner` 1 000 000 |
| fallback (`:37`) | `128000` |

No model database, no runtime fetch, no `provider`/`models` involvement — the
file says so (`:31-35`) and argues the window belongs in config.

## 2. Tools and `x-harness` flags

Exactly one tool, registered while the process is still allowed to register
(`ToolConcurrent` panics after `Announce`):

| Tool | Schema | Flags |
|---|---|---|
| `chat` | `{type: object, properties: {messages: array (required), tools: array, model: string}}` (`:203-211`) | `{"hidden": true, "timeoutMs": 300000}` (`:212`) |

`ToolConcurrent` (`:203`) bounds in-flight calls (SDK default limit) — safe
because every request owns its client and result state and the context table is
immutable after startup (`:201-202`). No `onDemand`, no `approval`, no
`sessionId`, no `effect`.

**Deliberately not spawned**, and this is the actionable part of the component:
the manifest keeps it commented out, and because `chat` is **globally unique**
across the catalog (`core/catalog.nim:652-665` rejects a duplicate tool name),
it cannot be run *alongside* `llm`. To use it a user edits `manifest.yaml`
(comment out the `llm` entry, uncomment `llm-openai`, `manifest.yaml:250-254`)
and restarts the harness; `make build` already produced the binary either way.
Nothing else (no config, no store record, no spawn call) is needed.

## 3. Configuration

| Variable | Where | Default | Notes |
|---|---|---|---|
| `NIF_OPENAI_API_KEY` | `:79-81` | — (required) | missing key ⇒ `NIF_OPENAI_API_KEY not set` before any HTTP |
| `NIF_OPENAI_BASE_URL` | `:75-77` | `https://api.openai.com/v1` | `/chat/completions` is appended (`:96`) |
| `NIF_OPENAI_MODEL` | `:70-73` | `deepseek-chat` | only when the call carries no `model` |
| `NIF_OPENAI_CONTEXT` | `:48-52` | built-in table → `128000` | re-read on **every** call (`contextWindow` is called per response, `:158`), so it is not freeze-at-boot |
| `NIF_OPENAI_PROVIDER` | — | — | **not read**: the example knows no provider registry |

The hardcoded `max_tokens: 32768` (`:91`) has no knob, and the 300 s HTTP
client timeout (`:103`) is fixed but matches the schema's
`x-harness.timeoutMs: 300000`.

## 4. How the MANUAL covers it today

Exactly **one mention** in 2850 lines — the Shipped-components row for `llm`:

  - MANUAL.md:64 `| `llm` | Go | required | streaming chat adapter (hidden `chat` tool; `ev.llm.token` deltas; cancellation) — protocols: OpenAI-compatible Chat Completions, OpenAI Codex (ChatGPT OAuth) Responses and Anthropic Messages; `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml` |`

Everything else the MANUAL says about `NIF_OPENAI_*` is written for the **`llm`**
component and is silently different for this adapter:

  - MANUAL.md:402-406 (the four `NIF_OPENAI_*` rows; 371: ``NIF_OPENAI_CONTEXT` | explicit context window (tokens) the llm reports to core's context guard. Resolution order: stored provider `context` → this → `models` catalog → `llm`'s built-in table (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288 — code-resident, so a new model needs a source change) → 128000``)
  - MANUAL.md:572-584 (`**Streaming.** The `llm` component streams tokens while generating: `ev.llm.token` deltas (content + reasoning) → … Abort an in-flight call by publishing to `llm.cancel.<sessionId>.``)
  - MANUAL.md:1159-1170 (`### Provider registry (`provider`)` — `max_completion_tokens` is the default spelling, DeepSeek honors only `max_tokens`, `length` means the cap cut the reply short.)
  - MANUAL.md:186-193 (`--minimal`: `… otherwise `llm` uses its small built-in model table and then a 128K fallback …`)
  - MANUAL.md:2062 (`del`, LLM `chat`/`llm_resolve`, the systemprompt prompt, and the credential-bearing provider tools)
  - MANUAL.md:2911-2949 / 2740-2743 (`### Testing` — the Go adapters are covered by `make gotest`, and `llm-openai` is in that set: `Makefile:565`)

**Absent** from the MANUAL: the swap *procedure* (which file, which lines, that
the two adapters cannot coexist because `chat` is a globally unique tool name,
and that `var/bin/llm-openai` is already built); what the example does **not**
implement (streaming deltas, cancellation, `reasoning_effort`/thinking, provider
routing, `finish_reason`, `llm_resolve`) and why a swapped-in harness still works
despite `llm_resolve` being gone; its own two-entry context table and the
hardcoded `max_tokens: 32768`.

## 5. DELTA list

## Layout of a running system

- MANUAL:64 `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml`` | CODE: `manifest.yaml:250-254` (`# Minimal example adapter (same tool contract, no streaming). Swap it back in place of `llm` to test: comment out llm, uncomment llm-openai.`), `components/llm-openai/main.go:199-215` (`sdk.New("llm-openai", "0.1.0")`, one `chat` tool), `core/catalog.nim:652-665` (a duplicate tool name is rejected: "catalog: rejecting … missing or duplicate tool name") | FIX: add — one sentence right after the `llm` row (or a footnote on the row): "The example cannot run *alongside* `llm`: `chat` is a globally unique tool name, so `llm` must be commented out when `llm-openai` is uncommented (`manifest.yaml`). `make build` builds `var/bin/llm-openai` either way, so the swap is one manifest edit plus a harness restart."
- MANUAL:64 (`minimal non-streaming example`) | CODE: `components/llm-openai/main.go:203-212` (schema: `messages`/`tools`/`model` only), `:170-189` (the result carries no `finish_reason`/`provider`/`reasoning`), `components/llm/main.go:1140` (the `llm` component also registers `llm_resolve`, which the example does not), `core/conversation.nim:1783-1785` (`except CatchableError: discard  # older/replaced llm components can still serve chat` — core tolerates the missing `llm_resolve`), `core/conversation.nim:2220-2221` (core takes the window from the chat reply's `context`, so the example's own table still arms the context guard) | FIX: add — replace "swap it in via `manifest.yaml`" with a short labelled paragraph: "**What the example does and does not do.** It implements the `chat` contract's core — OpenAI-compatible Chat Completions, tool calls, usage, a context window the guard can use (core reads `context` from the reply, so a swapped-in adapter still arms context admission) — and deliberately nothing else: no `ev.llm.token` streaming deltas, no `llm.cancel.<sessionId>` abort (an in-flight HTTP call runs to its own 300 s timeout), no `reasoning_effort`/thinking passthrough, no provider-registry routing, no `finish_reason` (so core cannot see `length` truncation), no `llm_resolve` (core degrades gracefully: the turn proceeds, model resolution falls back to the request's own model). Stacked with its hardcoded `max_tokens: 32768` and its two-entry context table (`deepseek-chat`/`deepseek-reasoner`, else 128 000), that is the whole example."

## Environment variables

- MANUAL:406 `NIF_OPENAI_CONTEXT` … Resolution order: stored provider `context` → this → `models` catalog → `llm`'s built-in table (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288 — code-resident, so a new model needs a source change) → 128000` | CODE: `components/llm-openai/main.go:47-57` — for the swap-in example the chain is **`NIF_OPENAI_CONTEXT` → a two-entry table (`deepseek-chat`/`deepseek-reasoner` 1M, `:40-43`) → 128000**; there is no provider, no `models` catalog and no `syn:large:text`/`zai-org/glm-5.3-flash` entry. The value is re-read per call (`:158`), unlike `llm`'s freeze-at-boot fields | FIX: update — append to the row: "(the `llm-openai` swap-in example resolves only `NIF_OPENAI_CONTEXT` → a two-entry `deepseek-chat`/`deepseek-reasoner` table → `128000`, and re-reads the variable on every call)."
- MANUAL: absent (the example's other three `NIF_OPENAI_*` reads and its hardcoded `max_tokens`, and its unguarded request-body echo) | CODE: `components/llm-openai/main.go:79-81` (required key), `:75-77` (base URL), `:70-73` (model, default `deepseek-chat`), `:91` (`max_tokens: 32768`, no knob), `:103` (300 s HTTP client), `:113-115` (`fmt.Errorf("llm HTTP %d: %s\nreq: %s", …)` — the error text embeds up to 500 bytes of the response **and the entire request body**, i.e. the whole conversation) | FIX: add — a line in the swap paragraph: "It reads only `NIF_OPENAI_API_KEY`, `NIF_OPENAI_BASE_URL`, `NIF_OPENAI_MODEL`, `NIF_OPENAI_CONTEXT` (no `NIF_OPENAI_PROVIDER`), and always sends `max_tokens: 32768` — the one cap spelling DeepSeek honors (see [Output caps and `finish_reason`](#output-caps-and-finish_reason)); there is no knob for it." (Code, separately: drop `req: %s` from the error — `code-bug?`, see the row below.)

## Provider registry (`provider`)

- MANUAL:1164-1168 `How a stream ended is reported in `finish_reason`: `length` means the output cap cut the reply short (`llm` logs a truncation warning), `tool_calls` means the model stopped to call tools` | CODE: `components/llm-openai/main.go:155-190` — the result map carries `content`/`model`/`context`/`usage`/`tool_calls` but **never** `finish_reason`; the response struct does not even decode it (`:118-140`), so with this adapter core's `length` detection (`core/conversation.nim:2315-2325`) can never fire and a truncated reply is accepted as a normal answer | FIX: add (one clause, or fix in code) — "An adapter that does not report `finish_reason` (the `llm-openai` example) disables this detection entirely: a reply cut at the cap is accepted as the final answer." (Better: decode `choices[0].finish_reason` in `components/llm-openai/main.go` and return it — `code-bug?`.)
- MANUAL:1161-1163 `Niffler's default spelling is `max_completion_tokens`; DeepSeek honors only `max_tokens`, so a cap sent the default way is ignored and the server's own default (8K/64K/128K, by model) applies — send `max_tokens` for DeepSeek endpoints.` | CODE: `components/llm-openai/main.go:84-91` (sends `max_tokens: 32768` — the example is on the correct side of this warning, worth naming as the reference) | FIX: none — verified accurate; optionally cite the example next to it.

## 6. Not user-facing

Nothing in the example is meant to be visible in a conversation: the tool is
`hidden`, it has no slash command, no store kind, no event subject, and the only
MANUAL work it needs is the swap paragraph above plus the two qualifications
(`NIF_OPENAI_CONTEXT` chain, `finish_reason` silence). Two internal choices are
deliberately *not* documentation material: the DeepSeek flat/nested `tool_calls`
normalization (`main.go:170-189`) and the per-call client with
`ToolConcurrent` (`:103`, `:203`) — both are the shape every adapter must cope
with, described generically in `docs/WIRE.md` and the SDK docs.

---

# `components/mcp-bridge/` — the Go bridge that presents external MCP servers as bus components

Files: `main.go` (531 lines), `operations.go` (413), `transport.go` (282),
`types.go` (133, duplicated byte-for-byte with `components/mcp/types.go` — the
header says so at `types.go:1-3`), `envrefs.go` (48),
`sysprocattr_linux.go`/`_other.go` (13 each) and five test files.

## 1. What it is and why it exists

One **bridge process per external MCP server**, whose whole job is to make a
foreign server's tools indistinguishable from native component tools: it
registers one bus component named `mcp-<server>` (`main.go:478`) and one catalog
tool per MCP tool, so the model reaches them through the ordinary
`discover`/`invoke` path. It is never started by a human and has no manifest
entry: the `mcp` manager (a peer component) probes it with `--probe` to validate
a config, then asks core to supervise it (`core.spawn {name: "mcp-<server>",
binary: …, args: ["--server", <server>]}` — `components/mcp/main.go:517-522`).

Boot sequence (`main.go:466-531`): `--stdio-guard` short-circuits into the
sandbox guard; otherwise `DieWithParent` → connect → **read its own config from
the store** (`StoreGet("mcp", <server>)`, `:481-487`) → exit **0** if the record
is disabled (`:491-493`) → exit **1** on an identity mismatch (`:494-497`) →
`register()` → subscribe `cancel.mcp-<server>` → `OnDrain(shutdown)` →
`Announce()` → the 1 s `watch()` ticker. Registration is deliberately deferred
(`sdk.New(...).DeferAnnounce()`, `:478`) so the catalog never sees the component
without its tools.

Three argv modes, all internal:

| argv | Where | What it does |
|---|---|---|
| `--server <name>` | `:469-471`, `:478-531` | the supervised mode above; the name must pass `validateName` (`types.go:50-58`) |
| `--server <name> --probe` | `:472-477`, `:435-455` | validate a JSON config on **stdin**, make one real connect, print `{ok, tools, prompts}` on stdout, no bus at all |
| `--stdio-guard <cmd> [args…]` | `:454-456`, `transport.go:236-281` | the sandbox guard: exec the real stdio server, watch the lifeline fd 3, and on EOF/SIGTERM/SIGKILL-of-the-bridge SIGTERM then SIGKILL its **process group** |

Contract handling (the part that earns the doc's "Drift" bullet,
`main.go:156-313`): a session is **lazy** (`ensure()` on the first call), the
listing is bounded (`pageAll`: max 128 pages, repeated-cursor detection,
`operations.go:21-43`; ≤512 KiB total, `:107-109`), and every fresh connect
re-lists tools **and** prompts. If the listing differs from the cached one, the
bridge persists the fresh listing (3 rev retries, refusing to clobber a
concurrently edited config, `main.go:275-313`) and then **exits 3**
(`driftExitCode`, `:22`) for a supervisor restart with backoff. If persistence
fails it does **not** exit: it stays up in a fail-closed `retiring` state that
refuses new calls with `MCP bridge is retiring; retry after it re-registers`
(`:26`, `:257-272`, `begin()` `:92-100`).

## 2. Tools and `x-harness` flags

Registered per server by `register()` (`operations.go:348-412`). Every tool's
flags come from one helper (`xHarness`, `:333-345`):

```
{"sessionId": true, "timeoutMs": <record timeoutMs or 120000>,
 "approval": "always"        if the record sets approval: "always",
 "effect": "read"            if the record sets effect: "read",
 "hidden": true              for the helpers below,
 "onDemand": true            unless the record sets expose: "direct" (and even
                             then, when the server exceeds the direct threshold)}
```

| Tool | Flags | Purpose |
|---|---|---|
| `mcp_<server>_<tool>` (one per cached MCP tool) | as above; serialized with `Tool` when the record sets `concurrency: "serial"`, else `ToolConcurrent` (`:361-365`) | the MCP call; description is `[mcp:<server>] <remote description>` (`:358`) |
| `mcp_<server>_resources {op?, uri?}` | as above + `effect: "read"` forced (`:374-376`); enum `list`/`templates`/`read` | list resources, list URI templates, or read one URI (`:203-260`) |
| `mcp_<server>_prompt {name, arguments?}` | `hidden: true` (always) | generic renderer for any prompt by name (`:378-386`) |
| `mcp_<server>_prompt_<promptname>` (one per cached prompt) + slash command `mcp-<server>-<promptname>` | `hidden: true` | one hidden tool and one slash command per prompt, with the prompt's own argument schema (`:388-410`) |
| `mcp_<server>_bridge_status {op?}` | `hidden: true`, enum `status`/`refresh` | the manager's private helper (`:411`, handler `main.go:390-433`): `status` reports `{server, type, connected, tools, prompts, retiring, activeCalls, lastError, startedAt, lastUsed, idleMs}` |

Result shaping (`operations.go:112-190`): text content is joined into `text`,
non-text parts are JSON-serialized into the same field, structured content is
appended, and `isError` turns the call into a tool error. Anything over **64 KiB**
is spilled to `$NIF_ROOT/var/mcp-results/result-*.json` and the result becomes
`{text: <16 KiB preview + pointer>, spill: {path, bytes}, truncated: true}`.

**Spawn policy**: `mcp-bridge` is in **no** manifest (`manifest.yaml` has no
`mcp-bridge` entry; the manager's own comment at `manifest.yaml:127-131` says the
manager spawns it per server). It *is* built by `make build`
(`Makefile:222-223`, and it is in the `components-inner` list at `:310-313`), and
a user must not start it by hand — the only supported entry points are
`mcp_add`/`mcp_edit` (manager) and the manager's probe. To use it: configure a
server through `mcp_add`.

## 3. Configuration

| Variable | Read by | Where | Default |
|---|---|---|---|
| `NIF_MCP_DIRECT_THRESHOLD` | the **bridge**, at registration | `operations.go:321-327` | `10` (`<1`/unparseable ⇒ 10) |
| `NIF_MCP_PROBE_TIMEOUT_MS` | the bridge's `--probe` mode **and** the manager's probe | `main.go:437-443`; `components/mcp/main.go:466-472` | `30 s` listing timeout |
| `NIF_ROOT` | the bridge (spill directory) | `operations.go:148` | `.` when unset |
| `${NAME}` references | the bridge, at connect/spawn | `envrefs.go:1-48` (`env` values, `headers` values, `args`, `url`) | unset name ⇒ the connect fails naming every missing variable; a bare `$` stays literal |
| the OS/allowlist environment | inherited by the stdio server | `transport.go:157-179` | PATH, HOME, USER, LOGNAME, TMPDIR, TMP, TEMP, LANG, LC_ALL, SYSTEMROOT, SSL_CERT_FILE, SSL_CERT_DIR, XDG_CACHE_HOME, XDG_CONFIG_HOME, UV_CACHE_DIR, NPM_CONFIG_CACHE |

Everything else is the store record: transport (`stdio` default / `http` / `sse`,
`main.go:70-81`), `command`/`args`/`env`/`cwd`, `url`/`headers`, `enabled`,
`approval`, `expose`, `effect`, `timeoutMs` (default 120 s), `idleMs` (default
5 min) and `concurrency`, with the `tools`/`prompts` cache written back by the
bridge (`types.go:14-31`). `timeoutMs`/`idleMs` are validated ≤86 400 000 ms
(24 h) by the manager (`components/mcp/validation.go:71-73`), and every tool's
`x-harness.timeoutMs` is the record's `timeoutMs` — so a per-server call budget
is an *announcement-time* fact for that child's lifetime.

## 4. How the MANUAL covers it today

It has **no section of its own** — correctly so, since it is never user-started —
but it is the subject of the `mcp` chapter and of the shipped-components row:

  - MANUAL.md:85 `| `mcp` | Go | optional | external MCP servers (Model Context Protocol): store-backed registry (`mcp_servers`/`mcp_search`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`), one supervised bridge per server; tools become ordinary catalog tools reachable through `discover` + `invoke` (see [External MCP servers](#external-mcp-servers-mcp)) |` — the bridge is not named in the table.
  - MANUAL.md:1654-1663 (the `### Shape` diagram, whose spawn lines are `spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}`)
  - MANUAL.md:1665-1671 `The bridge is only ever started this way (or by the probe with `--probe`); its path is `NIF_MCP_BRIDGE_BIN`, default `<root>/var/bin/mcp-bridge`, and the manager re-spawns the child after a crash or drift. The bridge carries no config on its argv: it re-reads the `mcp` record named by `--server` at startup (so the record stays the single source of truth) and exits immediately if that record is disabled.`
  - MANUAL.md:1671-1676 (Naming), 1539-1547 (Exposure), 1548-1553 (Lazy sessions), 1554-1558 (Cancellation), 1559-1564 (Secrets by reference), 1576-1579 (Result size), 1580-1584 (Drift + retiring), 1585-1589 (Isolation) — all about this binary's behaviour.
  - MANUAL.md:1703-1713 (`- **Sandboxing**: stdio servers run under a guard process (`mcp-bridge --stdio-guard <cmd>`) … stdio servers inherit a fixed environment allowlist (PATH, HOME, TMPDIR, USER, SHELL, LANG, TERM) …`)
  - MANUAL.md:1753-1760 (`type` selects the transport … `concurrency: "serial"` … The manager owns every field except `tools` — the bridge rewrites only that cache when the server drifts.)
  - MANUAL.md:1789-1799 / 1663-1668 / 1680-1683 (prompt tools + slash commands, `mcp_<server>_resources` with its `list`/`templates`/`read` ops, drift covering prompts)

**Absent** from the MANUAL: the `mcp_<server>_bridge_status` helper (the door the
manager's own tools use); the exact exit codes / state machine of the bridge
(`0` disabled, `1` identity mismatch or unreadable record, `3` drift
persisted-and-restarting, `retiring` when persistence failed); the 16 KiB
preview and the machine fields of a spill (`spill {path, bytes}`, `truncated`);
and the fact that a record's `timeoutMs` becomes the announced
`x-harness.timeoutMs` for that child's lifetime.

## 5. DELTA list

## External MCP servers (`mcp`)

- MANUAL:1703-1713 `stdio servers inherit a fixed environment allowlist (PATH, HOME, TMPDIR, USER, SHELL, LANG, TERM) — `NIF_*` variables and secrets in the harness environment never reach them.` | CODE: `components/mcp-bridge/transport.go:157-179` — the allowlist is **PATH, HOME, USER, LOGNAME, TMPDIR, TMP, TEMP, LANG, LC_ALL, SYSTEMROOT, SSL_CERT_FILE, SSL_CERT_DIR, XDG_CACHE_HOME, XDG_CONFIG_HOME, UV_CACHE_DIR, NPM_CONFIG_CACHE**. `SHELL` and `TERM` are **not** in it; the locale/TLS/cache variables are (`npx`/`uvx` need `XDG_*`/`UV_CACHE_DIR`/`NPM_CONFIG_CACHE`, and TLS needs the cert paths) | FIX: update — "stdio servers inherit a fixed environment allowlist — `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`/`TMP`/`TEMP`, `LANG`/`LC_ALL`, `SYSTEMROOT`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, `XDG_CACHE_HOME`/`XDG_CONFIG_HOME`, `UV_CACHE_DIR`, `NPM_CONFIG_CACHE` — plus whatever the record's `env` adds; `SHELL` and `TERM` are *not* passed, and `NIF_*` variables and secrets in the harness environment never reach them."
- MANUAL:1758-1760 `The manager owns every field except `tools` — the bridge rewrites only that cache when the server drifts.` | CODE: `components/mcp-bridge/main.go:275-313` (`persistContract` writes `record.Tools` **and** `record.Prompts`), `components/mcp/types.go:14-31` (both are caches in the record) | FIX: update — "The manager owns every field except the caches: the bridge rewrites `tools` **and** `prompts` when the server drifts." (The `### Prompts` bullet at MANUAL:1818-1821 already says prompts are refreshed, so the two statements currently disagree.)
- MANUAL: absent (`mcp_<server>_bridge_status`, the manager's hidden helper) | CODE: `components/mcp-bridge/operations.go:411` (registered `hidden`), `main.go:390-433` (`status`/`refresh`), called by the manager at `components/mcp/main.go:775-779` | FIX: add (one clause in `### Shape`) — "Each bridge also registers one hidden helper, `mcp_<server>_bridge_status {op: status|refresh}` (invisible to the LLM); the manager uses it for the live state in `mcp_servers` and for `mcp_refresh`. Its `status` carries `connected`, `tools`, `prompts`, `retiring`, `activeCalls`, `lastError`, `startedAt`, `lastUsed`, `idleMs`."
- MANUAL:1718-1722 (`- **Drift**: … it persists the fresh listing (best effort, rev-retried) and exits 3, so the supervisor restarts it … If that refresh cannot be persisted the bridge fails closed in a *retiring* state`) | CODE: `components/mcp-bridge/main.go:22` (`driftExitCode = 3`), `:257-272` (`acceptContract`: equal caches ⇒ no-op, else `retiring = true` then persist), `:275-313` (3 attempts, refuses a concurrently edited config, `store conflict after three attempts`), `:314-350` (the 1 s watch ticker drives the re-list), `:520-526` (exit 3 only once no call is active — `maybeRestartLocked`) | FIX: none — verified accurate. Optional one-clause addition: "the exit is deferred until in-flight calls finish, so a drift never truncates a call."
- MANUAL:1686-1691 (`- **Lazy sessions**: … the MCP subprocess/HTTP session itself starts on the first tool call and idles out after `idleMs` (default 5 min; capped at 24 h). Each call gets the per-call timeout (`timeoutMs`, default 120 s, capped at 24 h).`) | CODE: `components/mcp-bridge/main.go:71-80` (`idle()` 5 min, `timeout()` 120 s), `:156-200` (`ensure()` connects on demand, reuses a live session), `:351-363` (`reap` every second when idle), `components/mcp/validation.go:71-73` (both ≤ 86 400 000 ms) | FIX: none — verified accurate.
- MANUAL:1692-1696 (`- **Cancellation**: MCP tools declare `x-harness.sessionId` — the session runner injects the live session id as `__session.session`, and a cancelled turn's `cancel.mcp-<server>` event … aborts the in-flight MCP call immediately. Direct callers (CLI scripts) get `""` — they cannot spoof a session`) | CODE: `components/mcp-bridge/operations.go:334` (`sessionId: true` on every tool), `main.go:82-120` (`begin()` strips `__session` and records `{session, tool, cancel}`), `:121-137` (`cancelCalls`, subscribed on `cancel.mcp-<server>` at `:503`) | FIX: update (precision, one clause) — "…get `""` — the runner injects the id, and an unattributed call is never cancellable (the bridge matches the cancel event's `sessionId` against the id it saw, so a forged `__session` can at most cancel its own call)." The written claim "they cannot spoof a session" is stronger than the code: nothing validates that field on the direct bus path.
- MANUAL:1665-1671 (`The bridge is only ever started this way (or by the probe with `--probe`); … it re-reads the `mcp` record named by `--server` at startup … and exits immediately if that record is disabled.`) | CODE: `components/mcp-bridge/main.go:478-497` (`sdk.New("mcp-"+*server, …).DeferAnnounce()`, `StoreGet`, `return 0` when `!cfg.enabled()`, `return 1` on `stored server identity mismatch` or an unreadable/undecodable record), `:469-477` (`--probe` requires `--server` too) | FIX: add — one sentence completing the exit story: "A bridge also exits **1** if the record is unreadable or its stored name does not match `--server` (the supervisor then backs off and retries), and `--probe` requires `--server <name>` as well — the config arrives on stdin."
- MANUAL:1714-1717 (`- **Result size**: MCP results ≤64 KiB are returned inline; larger results are spilled to `$NIF_ROOT/var/mcp-results/result-*.json` and the tool returns a short preview plus the file path (readable with `read`, `grep` or bash) …`) | CODE: `components/mcp-bridge/operations.go:19` (`inlineLimit = 64 * 1024`), `:140-190` (`bound`: `$NIF_ROOT/var/mcp-results/result-<rand>.json`, preview = `truncateUTF8(preview, 16*1024)` + `[Full MCP result: N bytes saved to <path>; use read to inspect the JSON file.]`, result `{text, spill: {path, bytes}, truncated: true}`), `:112-138` (`projectResult`: text parts joined, non-text parts JSON-serialized, structured content appended) | FIX: update — "…the tool returns a machine-readable pointer instead: `{text: <first 16 KiB of the text> + a pointer line, spill: {path, bytes}, truncated: true}` (readable with `read`, `grep` or `bash`). Non-text content parts and structured content are JSON-serialized into `text` rather than dropped."
- MANUAL:1755-1758 `approval: "always"` gates every tool of the server with the human approval prompt; `effect: "read"` marks read-only tools for fabric scheduling; `concurrency: "serial"` for servers that cannot handle overlapping calls (default `parallel` via the SDK's bounded `ToolConcurrent`).` | CODE: `components/mcp-bridge/operations.go:333-345` (`xHarness`), `:361-365` (`concurrency: "serial"` ⇒ `Tool`, else `ToolConcurrent`), `:329-331` + `:321-327` (`deferDirectTools`: `expose: "direct"` is demoted to `onDemand` when the server publishes more than `NIF_MCP_DIRECT_THRESHOLD` tools) | FIX: add (one clause) — "A record's `timeoutMs` is not only a runtime budget: it is written into every tool's `x-harness.timeoutMs` at registration, so it is fixed for that bridge process's lifetime."
- MANUAL:1762-1786 (the `### Tools` table: "All on the `mcp` component, all on-demand. `mcp_add`, `mcp_edit` and `mcp_remove` are approval-gated …") | CODE: `components/mcp-bridge/operations.go:341-343` (`approval: "always"` per tool when the record asks for it — the *bridge's* tools are a second, per-server approval surface beside the manager's) | FIX: add (one sentence) — "`approval: "always"` on a server additionally gates every one of *its* tools (`mcp_<server>_<tool>`, resources and prompts) with the same human prompt, per call."
- MANUAL: absent (the bridge's repo copy of the shared config types) | CODE: `components/mcp-bridge/types.go:1-3` (`// Config and namespace contract shared (duplicated) with mcp-bridge/types.go. Keep these files identical; the components remain independent Go modules.`) | FIX: none — an internal invariant, correctly kept out of the MANUAL; noted so a future editor of one file knows the other must follow.

## Layout of a running system

- MANUAL:55-86 (table; the `mcp` row at 85 names the manager and its tools but not `mcp-bridge`) with MANUAL:38 (the table is the inventory of `components/`) | CODE: `manifest.yaml:127-131` (`mcp` entry: the manager spawns one bridge per server; a bare `mcp-bridge` fails), `Makefile:222-223` and `:310-313` (built by `make build`, in the `components-inner` list), no manifest entry of its own | FIX: add — extend the `mcp` row (or add a footnote under the table): "`mcp-bridge` (built by `make build` into `var/bin/mcp-bridge`, overridable with `NIF_MCP_BRIDGE_BIN`) is the per-server child the `mcp` manager supervises — it has no manifest entry and is never started by hand."

## Layout of a running system

- MANUAL:49 `| `var/approval-sources/`, `var/mcp-results/`, `var/review-receipts/`, `var/fabric-cache/`, `var/plugins/` | approval prompt payloads, MCP bridge results, `review_receipt` fingerprints, compiled fabric programs and installed plugin clones — all disposable |` | CODE: `components/mcp-bridge/operations.go:140-161` (creates `$NIF_ROOT/var/mcp-results` 0700 and writes `result-*.json` via `os.CreateTemp`), `:148` (root = `NIF_ROOT`, `.` when unset) | FIX: none — verified accurate; optionally add "(nothing prunes them — the directory grows until an operator clears it)", matching the `fetch` spool note at MANUAL:1310-1312.

## Environment variables

- MANUAL:423 `| `NIF_MCP_BRIDGE_BIN` | explicit path of the mcp-bridge binary | `<root>/var/bin/mcp-bridge` |` | CODE: `components/mcp/main.go:57-61` (read by the **manager**, not the bridge) | FIX: none — verified accurate.
- MANUAL:absent (no row names the bridge as an additional reader of `NIF_MCP_PROBE_TIMEOUT_MS`) | CODE: `components/mcp-bridge/main.go:437-443` (the bridge's own `--probe` mode reads it too, so a hand-run probe honours it) | FIX: add — extend the `NIF_MCP_PROBE_TIMEOUT_MS` row (MANUAL:469): "…read by both the manager (`mcp_add`/`mcp_edit`) **and** the bridge's own `--probe` mode (so a hand-run probe honours it too)."

## 6. Not user-facing

Two things exist purely for the manager and should stay out of the MANUAL beyond
the single clause proposed above: `mcp_<server>_bridge_status` (hidden tool) and
the `--probe`/`--stdio-guard` argv (the latter is already correctly described as
an implementation detail inside the Sandboxing bullet, MANUAL:1703-1713). The exit
codes are a middleware detail except for the one case a human actually meets — a
bridge that keeps restarting — which the `Drift` bullet already points at, so
naming exit 3 there is enough.

---

# Summary

**Findings: 46 rows** — 19 `FIX: add`, 13 `FIX: update`, 2 `FIX: (code)`
(explicit in the row), 12 `FIX: none` (verified-unchanged) — across the five
components. Every row is one line, shaped
`- MANUAL: <quote or absent> | CODE: <path:line> | FIX: <verb + wording>`, and
groups under the exact current MANUAL heading it applies to (11 groups, all
taken from `grep -n '^## ' docs/MANUAL.md`; the two level-3 subsections
`### Shipped components` and `### Output caps and \`finish_reason\`` are filed
under their level-2 parents, `Layout of a running system` and
`Provider registry (\`provider\`)`).

| component | rows | classes |
|---|---|---|
| `components/nats/` | 7 | 4 add (table row, 8 MiB budget, port handshake, `make doctor`/install), 1 update (the 4222 reuse claim), 3 verified (binary precedence, PDEATHSIG/orphan row, boot-monitor sentence) |
| `components/ctxtest/` | 4 | 2 add (the fixture paragraph under Testing, the table footnote), 1 update, 1 verified |
| `components/systemprompt/` | 14 | 3 add (`prompt_hint` + slots, the caps/no-env-knob statement, the caps sentence), 5 update (`$ROOT`, the walk, `AGENTS.local.md`, the replacement recipe, the persistence wording), 4 verified (cap, fallback, pre-fetch, worktree rule), 2 code (the silent manifest-shadow skip; the duplicated context-file read) |
| `components/llm-openai/` | 6 | 4 add (swap procedure, what it does not do, its env reads, `finish_reason` silence), 1 update (`NIF_OPENAI_CONTEXT` chain), 1 verified (`max_tokens` spelling) |
| `components/mcp-bridge/` | 15 | 6 add (helper tool, exit codes, `timeoutMs` as schema, per-server approval, the shipped-binary footnote, the probe-timeout attribution), 3 update (env allowlist, caches plural, spill fields), 2 verified (lazy sessions, spill path), 4 verified/other (drift/retiring, `NIF_MCP_BRIDGE_BIN`, the shared-types invariant, the spoof-clause clarification) |

Class view of the same 46: **19 missing** (capability or behaviour the MANUAL
never mentions), **13 wrong/doc-edit** (a statement the code contradicts, or
wording that misleads), **12 verified** (checked, correct as written), **2
code-only** fixes. The highest-frequency pattern is a *silent absence*: three of
the five components have a working, tested capability that appears nowhere in
3072 lines (the bus row + 8 MiB budget, `prompt_hint`, the bridge's helper/exit
story), and
`components/ctxtest` is invisible by design but unexplained. One row per
code-only proposal is filed explicitly:

- `code-bug?` **`llm-openai` drops `finish_reason`**: `main.go:118-190` decodes
  no such field, so core's `length`-truncation detection
  (`core/conversation.nim:2315-2325`) is dead for this adapter — a reply cut at
  the 32768-token cap is accepted as final. Also `main.go:113-115` embeds the
  **entire request body** (the whole conversation) in the error string on a
  non-200 reply.
- `code-bug?` **manifest-shadowed spawn records are skipped silently**:
  `core/niffler.nim:600-604` `continue`s without a warning, so a
  replaced-and-forgotten component is invisible at boot (its sibling
  missing-binary path does warn, `:620-621`).
- `code-bug?` **`systemprompt` reads each directory's context file twice**:
  `components/systemprompt/main.nim:210` (`let f = loadContextFileFromDir(dir)`)
  is dead — the loop then re-reads it as `primary` (`:212`) with the name `f`
  shadowed by the iteration variable (`:216`) — one redundant `readFile` per
  directory, and a duplicate stderr line for an unreadable file.

Five most important findings:

1) **The bus component has no MANUAL row.** `components/nats` builds
   `var/bin/nats-server`, core prefers it over PATH, and MANUAL:38 calls the
   Shipped-components table the inventory — yet `nats-server` is missing from it,
   and the harness's own **8 MiB `max_payload` requirement** (plus the boot
   warning for a smaller attached bus) is undocumented. That number is the
   explanation for a whole class of "the reply never arrived" failures.
2) **`$ROOT`-substituted is wrong** (MANUAL:2331): `baseprompt.txt` is
   `staticRead` and used verbatim, with a comment explicitly forbidding paths in
   the frozen head. A reader who believes the sentence will look for a
   substitution mechanism that does not exist.
3) **The ancestor walk description is wrong** (MANUAL:2340-2341): the walk stops
   at the harness root (or at the workspace when it is outside), and dedupes by
   `device:inode`, not by path — the symlink-farm case the code was written for.
4) **Replacing a shipped component does not survive a boot.** MANUAL:2307-2310
   tells the reader that `kill` + `spawn` replaces the constitution;
   `core/niffler.nim:600-604` silently prefers the manifest definition on every
   later boot, and §Self-extension's `kill`/`remove`/persistence wording never
   mentions it (compounded by the silent skip — a code fix is proposed).
5) **`prompt_hint` and the prompt slots are absent from the MANUAL** although
   they are a shipped, tested extension seam (and already documented on the
   website and in `CHANGELOG.md`): a plugin has no MANUAL entry point for adding
   standing instructions to future conversations.



