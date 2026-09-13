# Remote full harnesses — prior art and the Niffler shape

> Research note for the "fleet of alive agents" idea: full Nifflers running
> remotely (EC2-like VMs), long-running, each with its own filesystem and repo
> clones, controlled from a local client. What do the harnesses we track have,
> what do they *not* have, and what would this mean for Niffler?
>
> Basis: `~/git/harnesses/*` at the 2026-09-13 update (dsh `c291e7961a`, pi
> `71dca871b`, OpenHands `28464621d`). Companion docs:
> [PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) (protocol support),
> [research/REBOOT.md](research/REBOOT.md) (NATS topology notes).

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
plane** ([WIRE.md](WIRE.md) — `NIF_NATS_URL=nats://host:4222` "attach to any
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

## 6. Sizing

| Piece | Effort | Notes |
|---|---|---|
| SSH-tunnel remote harness (no code) | ~0 | `ssh -L 4222:localhost:4222 host`, set `NIF_NATS_URL`; approvals reach the local UI over the tunnel. Works today. |
| `--auth` + non-loopback bind option | small | The bundled server already supports the flags; core never passes them. WIRE/MANUAL update + tests. |
| `NIF_NAME` + fleet identity in `core.status`/UI | small | Catalog already carries root+revision; add an operator-chosen name. |
| `niffler-init` VM provisioning (or compose file) | medium | Mostly a script around clone/build/.env/start; container image exists for bench. |
| Fleet UI (backends list, flip, aggregate `ev.session.>`) | medium | OpenHands' backend specs (BM-001..003) are a good spec to steal. |
| NATS leaf nodes for many-VMs-one-plane | large, optional | The REBOOT "if ever wanted" line; only if one *shared* bus for many harnesses becomes a goal (it conflicts with per-VM isolation). |

Recommendation: do not build layer C as a feature; ship 1–3 so that "run a full
Niffler on a VM" is a supported configuration, then let the UI fleet view be
the product. That keeps the architecture's one-wire promise intact and avoids
the OpenHands/REST split-brain between local and remote control paths.
