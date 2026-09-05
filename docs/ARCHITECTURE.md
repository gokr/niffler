# Architecture — why core is core

Everything is a component except the irreducible control plane. This file is the
answer to "why is this in core instead of a component?" — the design test, the
five mechanisms, and the deliberate exclusions.

## The component test

A mechanism can be a component iff:

1. it can exist *after* the bus exists, and
2. the agent must be able to kill, remove, or rebuild it at runtime.

Anything that must precede the bus, or must outlive the agent's power to remove
things, is core. Components are the expendable layer by definition; the agent
retires them with `core.kill`/`core.remove`. The trust anchors are the ones that
must never be retirable — otherwise the harness loses its only handle on
processes, its namespace authority, or its own mind.

## The irreducible mechanisms

### 1. Bus bootstrap — `core/niffler.nim`

NATS spawn/attach, port pick, `.env` load, manifest read, `var/nats-url`.
Everything else is defined relative to the bus — components *are* bus
subscribers — so this runs before any component can exist. Irreducible by
definition.

### 2. Supervisor — `core/supervisor.nim`

Process lifecycle: start, crash detection, drain ordering, SIGTERM→SIGKILL
escalation on shutdown. `core.spawn`/`kill`/`remove` are its API surface.
Stateless logical components may have multiple supervised process replicas;
core distributes calls across their accepted private service addresses.
Lifecycle operations stop the supervised replicas and preserve external peers.

Two separate reasons it cannot be a component:

- *Chicken-and-egg*: someone must start the first process, and something must
  restart the supervisor when it crashes. It must be the OS parent-of-record —
  correct pid-based crash detection and clean drain ordering only work from
  that position.
- *Trust*: the whole point of `core.kill`/`core.remove` is that the agent can
  retire anything. The supervisor is the one thing that must be un-retirable —
  a removed supervisor would orphan every child, lose crash recovery and drain.
  A killable supervisor defeats the architecture's own validation criterion.

### 3. Conversation loop + session entry — `core/conversation.nim` + `core/session.nim`

The `session` tool (hidden) and the loop that drives the LLM, dispatches tools,
and composes the system prompt. This is the agent's own mind.

The mind is split across two processes: the *system harness* (`niffler.nim`,
the irreducible root) owns the `session` tool's address — it ensures a
*session runner* (`session.nim`, `var/bin/session <id>`) per conversation and
forwards to `svc.session.<id>.call` — and the runner executes turns, one
process per conversation. Crash isolation (docs/research/REBOOT.md) works because the
mind's *state* is a component (`store`); the mind's *code* is a spawned
process that can be restarted freely: a killed runner loses nothing but the
in-flight turn — the next session call spawns a fresh runner that resumes
from the store. The agent cannot remove the loop itself: there is no tool
that retires `niffler.nim` (it is the bus), and `session-<id>` runners are
internal children (restart policy `never`), not agent capabilities.

### 4. Catalog authority — `core/catalog.nim`

The live registry: `reg.publish`/`reg.depart` handling, global tool-name
uniqueness enforcement, exposure projection (`x-harness.hidden` removes a
tool from every LLM view; `x-harness.onDemand` keeps it out of the per-
conversation direct set but discoverable via `discover`), schema
normalization, `ev.catalog.updated` announcements, and accepted-instance routing. Routing always uses the
full catalog — exposure shapes prompts, not dispatch rights. SDK processes
subscribe only to private instance addresses. The system catalog owns public
component addresses and forwards to accepted instances, preserving the original
reply inbox. Rejection therefore excludes a process from delivery, not just
from discovery. Session catalogs are read-only mirrors and never own routes.

The borderline case — it is almost a component (a `reg.>` subscriber). It stays
in core because it must (a) exist before any component registers — boot order —
and (b) be the un-killable authority for what counts as a tool. A removed
catalog would let two components squat the same tool name and blind the harness
to its own body.

### 5. Approval / policy — `core/dispatch.nim` (the seam)

`x-harness.approval` and `x-harness.timeoutMs` are honored on the dispatch path.
Approval is deliberately kept as a synchronous interceptor in core rather than
a bus hop: policy must be synchronous and central, and a multi-hop middleware
chain over NATS would be slower and less trustworthy (docs/research/REBOOT.md, open
threads). Unlike 1–4 this is a *choice*, not a structural necessity — it could
become a component the day the harness outgrows one interceptor.

The interceptor routes interactively (`core/approval.nim`): the component
driving a session (the envelope's self-declared `caller`) gets the request on
its private `svc.approval.<name>.request` subject, acks it to show a human is
being asked, and answers `{id, ok}`; a missing ack rebroadcasts to any
interactive client, direct calls broadcast immediately, and `ev.approval.resolved`
lets every client dismiss stale modals.

Dispatch also owns the mid-turn re-entry path: tool calls are sent as
poll-loop requests on a private inbox, and every idle slot serves core's
own `svc.core.call` surface (spawn/kill/remove/catalog) plus the live
`ev.llm.token` stream. Without this, a component calling back into core
during a session turn (`plugin_install` → `core.spawn`) would deadlock
against the in-flight turn. Concurrent `session` requests are stashed,
never nested, and drained when the turn ends.

## What is deliberately outside core

The mechanisms that *are* components, and the capability they carry:

| Component | Capability | Notes |
|---|---|---|
| `store` | state/persistence | single-writer KV; the mind's state lives here, not in core |
| `models` | provider/model metadata | models.dev baseline plus replaceable plugin correction and discovery layers |
| `llm` | LLM access | hidden `chat` tool; streaming with live `ev.llm.token` deltas, reasoning tokens, per-call cancellation |
| `builder` | compilation | agent-written Nim/Go → binary |
| `bash` | execution | general-purpose machine access |
| `plugins` | ecosystem | discovery + install of third-party component packages (topic search, `niffler.json` manifest, source builds) |
| `edit` | file tools | `read` (plain, pageable) / `edit` (exact old_string/new_string, uniqueness enforced, guarded fallback cascade, `replace_all`) / `write` (atomic whole-file) / `undo_last_edit`; anchored block moves live in the niffler-hashline plugin |
| `git` | repo inspection | read-only `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame` over fixed argv; mutations stay in bash |
| `observe` | live introspection | bounded raw-bus ring, targeted probes/traces, and server monitoring |
| `logfile` | diagnostic persistence | rotating best-effort JSONL sink; no JetStream/audit guarantee |

The pattern: state, access, build, and exec are all replaceable peers. If a
mechanism can be rebuilt by the agent at runtime, it must be one. A process is
the isolation/lifecycle boundary, not a requirement that its internals be
single-threaded: audited components may own native workers (`std/threads` +
`std/locks` is the preferred general Nim model; Go uses goroutines), while the
default Nim SDK pump stays serial and `asyncdispatch` is never used.

## Where the boundary shows

`core.kill` works on every component — `bash`, `builder`, `store`, `llm`,
`plugins`, `hashline-edit`, anything the agent added. What it cannot touch is
exactly the list above: the supervisor's children-ownership, the catalog, the
loop, the bus. That asymmetry is the architecture, not an implementation detail.

Session runners are the one deliberate crack in that wall: their processes
belong to the supervisor (restart policy `never`) and can be killed without
losing the conversation — the mind survives in the store and the loop code,
not in the process. The unit of isolation for the agent's own mind is the
process, exactly like everything else.
