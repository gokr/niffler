# Remote full harnesses — prior art, and two paths for Niffler

> Research note for the "fleet of alive agents" idea: full Nifflers running
> remotely (EC2-like VMs), long-running, each with its own filesystem and repo
> clones, controlled from a local client. What do the harnesses we track have,
> what do they *not* have, and what would this mean for Niffler? Concludes with
> the two paths under consideration: **first-class Chetter support** (§6.1) and
> a **native fleet component over a shared TiDB store** (§6.2).
>
> Basis: `~/git/harnesses/*` and `~/git/chetter` at the 2026-09-13 update (dsh
> `c291e7961a`, pi `71dca871b`, OpenHands `28464621d`, chetter `3df7479`).
> Companion docs: [../PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) (protocol
> support), [REBOOT.md](REBOOT.md) (NATS topology notes),
> [../PI-NEXT.md](PI-NEXT.md) (the near-term list this extends),
> [../MANUAL.md](../MANUAL.md) (bus identity, approvals, store engines).

## 0. The answer in one line

**None of them has a remote *harness*; OpenHands is the only one with a real
remote-*agent* architecture, and it is built on exactly the piece Niffler
already has — an addressable control plane.** Everyone else's "remote" story is
one of three weaker things: a remote *sandbox* (dsh's E2B), a remote
*presentation* (pi's radius relay, dsh's api-gateway), or a remote *sandbox
wrapper* (gemini-cli's Docker/Podman flags).

The terminology matters, because the user-facing feature ("my agent lives in
EC2 and I drive it from my laptop") decomposes into four separate layers:

| Layer | What it means | Who has it |
|---|---|---|
| **A. Remote execution** — the agent's *effects* (files, shells) happen elsewhere | sandbox swap | dsh E2B, gemini-cli sandbox, dsh sandbox-* |
| **B. Remote presentation** — the *session* runs locally; a remote client attaches to view/drive it | reverse attach | pi radius-relay, dsh api-gateway/remotes |
| **C. Remote agent runtime** — the whole agent loop runs *on another machine* as a service; the local thing is a control surface | **the actual ask** | **OpenHands (Agent Server)**, nobody else in this set |
| **D. Fleet of many** — one client flips between many independent agents on many machines | C × N | OpenHands (backends list) |

## 1. OpenHands — the real prior art (layer C/D)

OpenHands' current shape (`~/git/harnesses/OpenHands/README.md`) is
exactly the contemplated feature, shipped as a product:

> "It runs locally on your machine by default, but can connect to multiple
> 'agent backends', e.g. running agents in Docker containers, on VMs, or within
> your company infrastructure. You can optionally choose to run agents on
> OpenHands Cloud or OpenHands Enterprise infrastructure."

The mechanism is the **OpenHands Agent Server** (`software-agent-sdk/…/
openhands-agent-server`): *a REST API for running multiple agents on a single
machine. Each Agent Server runs on a single host/port; the Agent Canvas can
connect to multiple Agent Servers and easily flip between them* — with backend
specs in `specs/backend-management.md` (auto-switch on connect, fallback on
removal, never show stale data from a previous backend) and a documented VM
backend setup path.

Design choices worth noting, because they are the two hard problems:

- **Local/remote symmetry**: the UI talks to a local backend and a remote one
  the same way (a URL with a port), which is what makes `--backend-only`
  (server + automation + ingress, no UI) a clean mode. The remote machine runs
  the *full* agent stack; the laptop is a thin canvas.
- **Identity of sessions vs. backends is kept separate**: switching backends
  re-renders the same page against the other backend's data. The spec forbids
  "stale data from the previous backend" — i.e. session state lives with the
  backend, the client holds no illusion otherwise.

Trade-off: OpenHands' Agent Server is REST + per-backend URLs. There is no
shared bus; each (backend, agent) pair is addressed directly, and "fleet"
federation across machines is left to the user's infrastructure (k8s manifests
exist under `helm/`, cloud in OpenHands Cloud).

## 2. dsh — remote sandbox (layer A), remote presentation (layer B)

dsh has impressive remote-*ish* machinery, and none of it is a remote harness:

- **E2B family** (`packages/e2b/README.md`): *"lets agents read and edit files,
  run shell commands, and use terminals inside one remote Linux sandbox
  instead of on the host machine … **The harness, model calls, and session
  state remain local**; the sandbox is ephemeral, experimental, and absent
  from shipped compositions by default."* — layer A only, deliberately
  scoped: state stays local, the sandbox is disposable.
- **api-gateway + api/remotes** (`packages/api/gateway/README.md`,
  `packages/api/remotes/README.md`): a typed Client→Host RPC over a
  WebSocket mux — "Typed Client-to-Host calls and streams", with forwarded
  Host events, per-attachment subscriptions and cancellation. This is layer
  B: the *host* is the running harness; clients (Web, future TUI) attach to
  it. It is not for driving a harness on a third machine.
- **Sandbox backends** (`packages/sandbox/`): local confinement (bubblewrap /
  Landlock / Seatbelt / Windows ACL) — same axis as our SANDBOX-PLAN, not
  remote at all.

The one genuinely remote element is **which side stays home**: dsh's E2B keeps
the *brain* local and moves the *hands*; OpenHands' Agent Server moves both.
dsh's `packages/api/remotes/` is the more interesting read for the *protocol*
of a control plane (forwarded events, attachment lifetime, reconnection), and
its weakness is instructive: it is one host, many UIs — not many hosts, one
operator.

## 3. pi — experimental host/client split (layer B)

Pi's current remote work is all in `packages/coding-agent/src/experimental/`:

- **`radius-relay.ts`** — an authenticated WebSocket relay with two
  subprotocols (`pi-session-relay.host.v1` / `.client.v1`): the *host* (a
  running experimental server) maintains an outbound multiplexed connection to
  a relay; *clients* connect to the relay and attach to that host's sessions.
  Retry/backoff constants, framed data protocol, connection-id UUIDs. This is
  layer B with a relay in the middle — the same shape as dsh's gateway, plus
  NAT traversal (host dials out).
- **`coordinator.ts`** — a local peer router for the experimental server's
  workers (session workers, `mini/`), Unix-socket control plane.
- **`packages/server/`** — the durable Session/Agent Harness server, explicitly
  "experimental **local** server": multi-presentation attachment
  (`attachClient`, `attachmentId` routing), session directory, worker
  retirement when presentation demand hits zero.

So pi has built the *attachment* half (many presentations to one session) and
the *durability* half (sessions as addressable objects), and the relay exists to
make "remote presentation" survive NAT — but the shipped product still runs
one process, and the docs describe the whole stack as experimental. Nothing in
pi runs the harness on a VM you own.

## 4. Everyone else

- **gemini-cli** (`docs/cli/sandbox.md`): `GEMINI_SANDBOX=true|docker|podman|
  sandbox-exec|runsc|lxc` — container *isolation* of tool execution on the
  same machine (layer A, strongest form: the project dir is mounted in).
- **qwen-code**: gemini-cli fork — same model.
- **kimi-cli, codex, octofriend, CodeWhale, Reasonix**: local-first CLIs.
  Reasonix's provider endpoint catalog and CodeWhale's `fleets/`/`computer/`
  directories are the closest to multi-host thinking, but their agents execute
  where the CLI runs.

## 5. Why the field converged this way (and why Niffler shouldn't)

The gap is not that nobody thought of it. It is that the three big harnesses
are **in-process by architecture**, which makes layer C expensive to retrofit:

- Pi: one Node process; the session *is* the process state. Moving it means
  their whole AgentHarness durability program (which is their current frontier).
- dsh: one Cordis host composition; remotes are projections *of* that host.
- OpenHands started as a server product — its harness was *always* behind an
  API — so layer C was the native architecture from day one.

Niffler's position is the interesting one: **the bus already is a remote control
plane** ([../WIRE.md](../WIRE.md) — `NIF_NATS_URL=nats://host:4222` "attach to any
bus, even a remote"; REBOOT.md listed leaf nodes/gateways as "multi-machine
federation later, if ever wanted"). What is missing is not transport but
*harness identity and placement discipline*, and a few honest gaps:

| Gap | Why it matters for remote | Current state |
|---|---|---|
| Bus is loopback-only, unauthenticated | A remote bus must bind beyond `127.0.0.1` and gate who may publish `svc.>` | `core/niffler.nim` spawns with `-a 127.0.0.1` (line 67); the bundled `components/nats` build supports `--user/--pass/--auth` and TLS, but core never passes them |
| One clone = one instance, home-bus claim | Two full Nifflers on one bus fight over the store and the flat tool namespace | `NIF_NATS_SPAWN=1` (isolated random bus) exists; cross-host isolation = one bus per VM, plus the existing "yield loudly to a foreign core" behavior |
| Store is a local file | The VM's conversations live on the VM; nothing needs to change, but backups/observability are per-host | barrel/SQLite/TiDB engines behind one contract — TiDB already is the network-shared story |
| Setup = clone + build | A VM needs Nim/Go toolchains; a bad checkout is a broken harness | `manifest.yaml` + persisted component records restore shape, but binaries are per-host builds (`var/bin` is disposable) |
| Approvals need a human *reachable* | A headless VM with no attached UI must deny, not queue forever | Already correct: deny when no client acks; the fleet UI becomes the ack path |

The smallest honest statement of the feature: **Niffler-on-a-VM is already
possible; Niffler-as-a-fleet is a policy and packaging problem, not a protocol
problem.** The wire does not need to change — `NIF_NATS_URL` + approvals +
`cli`/UI as remote clients cover C and D. The work is:

1. **Bus security** — `--auth` token on the spawned server + `NIF_NATS_URL`
   carrying it; core only ever binds loopback today, so remote requires an
   explicit decision (or SSH-tunnel the bus, which needs nothing).
2. **Instance identity for fleets** — the harness already prints root + git
   revision and every catalog response carries them; a fleet UI needs that to
   disambiguate 1-of-N cores, and `core.status` needs a name the operator chose
   (env `NIF_NAME` or similar) rather than a path.
3. **Provisioning** — an install that works on a clean VM (the repo already
   self-builds via `make setup && make`; a `niffler-init` that clones, builds,
   generates `.env`, starts, and writes back a URL+token would make an EC2
   instance a 3-command setup), or docker (the `bench/container/` image already
   exists for bench jobs).
4. **The UI** — multi-backend list à la OpenHands; the web UI is a NATS client
   already, so this is a `--bus` picker plus the existing root/revision badges.

What makes Niffler's version *better* than OpenHands' if done: the control
plane is pub/sub, not REST — a fleet UI subscribes to `ev.session.>` across all
buses at once, approvals arrive as events rather than polls, and a component
can be restarted or rebuilt *on the remote machine* by the agent itself
(self-extension works remotely exactly as locally, because it goes through the
bus). The failure mode to respect is the one the home-bus claim already solves
locally: a fleet needs loud identity, never silent cross-attachment.

## 6. Two paths for Niffler

The survey says the primitive (a reachable, controllable full harness) is
mostly there. Two concrete directions follow from that, and they are
complementary rather than competing: Chetter is *operator-side, task-oriented*
orchestration; a native fleet is *agent-side, persistent* cooperation.

### 6.1 Path 1 — first-class Chetter support

Chetter (`~/git/chetter`, Go) already does the operator half of this document:
run autonomous dev agents from **standard harnesses** (OpenCode primary; Claude
Code, CodeWhale, Pi, Codex supported) in Docker/Kubernetes, with task
submission, live progress, pause/resume, cron/PR-review triggers, runner fleet
health, usage/cost accounting, and a full ConnectRPC API **exposed as ~60 MCP
tools** (`chetter_submit_task`, `chetter_task_events`, `chetter_runner_health`,
`chetter_resume_agent_session`, …).

How harness integration works there (`runner/harness/harness.go`): an adapter
implements `Harness` (config/env/model), either `RPCHarness` (JSONL subprocess
— that is how the pi adapter drives `pi --mode rpc`) or `ServeHarness` (HTTP
session: ServeCommand/CreateSession/SendPrompt/AbortSession/ReadSessionExport/
WatchEvents), plus optional `SessionContinuable`, `SessionStatusProbe`,
`CompletionAwareHarness`. Chetter also **injects two MCP servers into every
harness**: `chetter` (its API, bearer-tokened) and `runner-bridge` (progress
events back to the runner, relayed via a tiny stdio→Unix-socket `mcp-bridge`).

So "really good Chetter support" has three rungs, cheapest first:

1. **Zero code (today):** Niffler's `mcp` component already manages external
   MCP servers over stdio/HTTP/SSE with header injection — adding the Chetter
   server makes every Niffler agent able to submit/track Chetter tasks and
   read fleet health. Chetter injecting `runner-bridge` into Niffler works the
   same way in reverse.
2. **Chetter-side adapter** (`runner/harness/niffler/`, Go, mostly Chetter
   work): Niffler is already drivable headless — service mode + `cli call
   session` per prompt; conversations persist in the store, so
   `SessionContinuable` is a second call with the same `sessionId`,
   `SessionStatusProbe` maps to `session_info`/`ev.session.*`, and
   `ReadSessionExport` is the store→markdown recipe already in AGENTS.md.
   Niffler's "one clone = one instance" maps cleanly onto Chetter's per-task
   workspace (the clone *is* the workspace; `var/` persists with it, so
   pause/resume keeps the harness's brain).
3. **A dedicated `chetter` component** (the interesting one): instead of the
   agent round-tripping through generic MCP tools, a component speaks
   Chetter's ConnectRPC natively — typed schemas instead of 60 flat tools,
   `chetter_task_events` streamed onto the bus as `ev.chetter.*`, Chetter
   tasks first-class like our own `agentjob`s (status/wait/stop semantics for
   free), and progress reported to `runner-bridge` by watching `ev.session.*`
   on the bus, with no agent turn spent on reporting.

The honest comparison to keep in mind: Chetter orchestrates **tasks into
ephemeral runner containers**; it does not host persistent agenthood. A Niffler
under Chetter is a strong runner for discrete tasks; the *persistent* clone
with its own repos, memory and self-extension is Path 2.

### 6.2 Path 2 — a native fleet over a shared TiDB store

The Niffler-native version: a `fleet` component that talks to *other complete
Nifflers* — each a long-lived harness on its own VM with its own clone, its own
bus, its own accumulated state. Prerequisites come straight from §5 (identity,
bus auth, provisioning). The new design pieces:

**Transport — NATS leaf nodes, not a new protocol.** REBOOT.md reserved this
exact case ("Leaf nodes/gateways: multi-machine federation later, if ever
wanted"). Each VM's `nats-server` runs as a **leaf node** dialing a hub: the
local loopback bus stays exactly as it is (core never changes), the leaf
connection exports only selected subjects (`fleet.>`, gathered approvals),
subjects stay isolated per harness by default, and the leaf dials *out*, so NAT
traversal is solved by topology rather than by code. The alternative — a fleet
component holding N outbound connections — needs every remote bus reachable
and authenticated and has no isolation boundary; leaf nodes are the NATS-native
answer and are configuration, not code.

**Identity and discovery — the shared store as the registry.** The TiDB engine
was built for this: *"No flock — the cluster is shared state by design; row
locks arbitrate writers and the rev counter stays the
optimistic-concurrency check"* ([../MANUAL.md](../MANUAL.md) § Store engines).
N harnesses can point `NIF_STORE_BACKEND=tidb` at one DSN today. What is
missing is scoping discipline, because ids *will* collide: `message` ids are
`<convId>:<seq>`, `component` records, `<sessionId>:tools` snapshots, the
`slash` table and the provider `active` marker are all singletons today.

- **Private scope per harness** (store-level prefix from `NIF_NAME`, invisible
  to components) for everything harness-owned — component records, provider
  credentials, session snapshots, conversations.
- **A shared `fleet` scope** for coordination records written only by the
  fleet component: `peer` docs (`{name, revision, busHint, capabilities,
  lastSeen}` with rev-bump heartbeats), delegation/task records, shared
  artifacts.
- **Do not share harness-internal state by default.** The bus already makes
  every store reachable — a peer's `store` is just a component on its bus, so
  cross-harness read visibility is a routing question, not a schema question.
  The shared DB earns its keep for records that must *outlive any single
  harness* and for fleet-wide rich queries (the STORE_V2 FTS/vector quest over
  the shared scope becomes literal shared memory).

**Coordination patterns** (what `fleet` actually does):

- `fleet_delegate {peer, task, budgets?}` — write a task record in the shared
  scope, signal `fleet.<peer>.task` over the hub; the peer's fleet component
  runs it as a child session (reusing `agent_run` machinery cross-harness).
  Lineage/depth guards extend across hops via shared-scope records.
- `fleet_status` / `fleet_wait` — durable records, so a late reader never sees
  a lying "running" (same lazy-restart-recovery rule as `agent_status`).
- Approvals gather to the hub; the operator's UI acks from anywhere. A
  headless VM still fails closed when no human is reachable.
- Steering and stop map over the same gathered subjects.

**Security posture:** per-peer bus tokens, TLS on leaf links, per-harness store
credentials (shared-DB writes limited to the fleet scope), and the rule that an
approval arriving from a peer is never auto-answered by the peer itself.

### 6.3 How the paths compose

They are different points in one design space, not rivals:

| | Chetter (Path 1) | Native fleet (Path 2) |
|---|---|---|
| Unit | a **task** in an ephemeral runner container | a **persistent harness** with its own clone/memory |
| Orchestrator | operator + GitHub events + crons | the agents themselves (peer delegation) |
| State | workspace dir + Chetter server DB | per-harness stores + one shared TiDB scope |
| Strength | exists today, mature ops surface (fleet health, usage, audit, pause/resume) | long-lived agenthood, self-extension, agent-to-agent cooperation |

And they stack: a Chetter-managed Niffler runner gets the `chetter` component
(1a/1c) and can *also* be a fleet peer; a fleet Niffler can delegate discrete
decoupled work into Chetter runners. If the near-term goal is "operator drives
many agents from GitHub and timers", Path 1 rung 1 is a same-day experiment and
rung 2 is the real work. If the goal is "agents that live for weeks and
cooperate", Path 2's registry + leaf-node slice is the first milestone, and it
depends on the §5 prerequisites (identity, auth, provisioning) either way.

## 7. Sizing

| Piece | Effort | Notes |
|---|---|---|
| SSH-tunnel remote harness (no code) | ~0 | `ssh -L 4222:localhost:4222 host`, set `NIF_NATS_URL`; approvals reach the local UI over the tunnel. Works today. |
| Chetter rung 1: `mcp_add` the Chetter server (and accept `runner-bridge`) | ~0 | Niffler's `mcp` component already does stdio/HTTP/SSE + header auth; 60 tools arrive in the catalog on demand. |
| `--auth` + non-loopback bind option | small | The bundled server already supports the flags; core never passes them. WIRE/MANUAL update + tests. |
| `NIF_NAME` + fleet identity in `core.status`/UI | small | Catalog already carries root+revision; add an operator-chosen name. Also the store-scope key. |
| Chetter rung 2: Niffler adapter in `runner/harness/niffler/` | medium | Go, Chetter-side; RPCHarness via service mode + `cli`; export from the store; pause/resume rides the persisted clone. |
| `niffler-init` VM provisioning (or compose file) | medium | Mostly a script around clone/build/.env/start; container image exists for bench. |
| Store scoping (`NIF_STORE_SCOPE` prefix; private + `fleet` scopes) | medium | TiDB engine is already multi-writer by design; this is convention + tests, not a new engine. |
| Dedicated `chetter` component (ConnectRPC, `ev.chetter.*`, runner-bridge reporting) | medium | Rung 3; replaces generic MCP round-trips with typed, streaming integration. |
| `fleet` component MVP (registry + delegate/status/wait over leaf subjects) | medium–large | Reuses `agent_run` machinery cross-harness; depth guards extend via shared-scope lineage. |
| Leaf-node topology + fleet UI (backends list, aggregate `ev.session.>`) | medium | Server config, not core code; OpenHands' backend specs (BM-001..003) are a good spec to steal. |
| Shared memory: FTS/vector over the shared scope | large, later | Rides the STORE_V2 TiDB quest; this is what makes the fleet's shared store *memory* rather than a registry. |

Recommendation: the paths are sequenced, not exclusive. Ship the small pieces
first — they are shared by both paths (identity, auth, provisioning), and rung
1 of Chetter is a same-day experiment that needs none of them. Then choose by
goal: operator-driven task fleets → Chetter rung 2/3; long-lived cooperating
agents → fleet registry + leaf nodes over the shared TiDB scope. Do not build
layer C as a bespoke feature; the bus plus these pieces already compose it, and
that keeps the architecture's one-wire promise intact (no OpenHands/REST
split-brain between local and remote control paths).
