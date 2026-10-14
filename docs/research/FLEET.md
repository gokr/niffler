# Remote instances, resident agents and the `/niffler` switcher

> Proposal (nothing implemented). Two halves of one story.
>
> **Part I (§1–§5)** — running one or several full Nifflers on remote machines
> and driving them from another Niffler, or from a bare `niffler-tui` with no
> local harness at all: the transport question (SSH tunnel vs. overlay vs. leaf
> nodes vs. open port), instance identity, remote lifecycle, and the client-side
> `/niffler` command that works like `/fav` — an ordered list you rotate with a
> key combo.
>
> **Part II (§6–§9)** — the agent side: *persona* (who an agent is, resolved
> once into the frozen prompt at its birth), *heartbeat* (waking an agent nobody
> is driving, with its own admission lane because the wake lane deliberately
> refuses the job), *cross-instance delegation* (a remote child is a
> conversation on the other instance), and the composed **resident agent**: a
> server-hosted instance that stays up, has an identity, wakes on its own, and
> can be driven from any client.
>
> §10 is the ladder for both halves; §11–§13 are the boundaries.
>
> Companions: [REMOTE.md](REMOTE.md) is the prior-art survey and the two
> long-range paths (Chetter, a native fleet over leaf nodes + a shared TiDB
> store); this note is the near-term, client-side design that sits in front of
> both. [../WIRE.md](../WIRE.md) is the contract this must not break;
> [../MANUAL.md](../MANUAL.md) documents the bus/identity/lifecycle behaviour
> referenced below. All code references verified 2026-09-25 against this
> checkout.

## 0. The answer in one line

**An SSH tunnel is the whole transport, a client-side ordered list is the whole
fleet registry, and `/niffler` is `/fav` with instances instead of
provider/model pairs** — switching can ship with *zero* wire changes and
*almost* zero harness changes, because the bus is already the remote control
plane and the client-side switch is a connection swap.

What is genuinely missing is not transport: it is **loud identity** (today
nothing distinguishes two VMs that share a root path and a git revision),
**remote lifecycle** (nothing starts a VM's harness before you can talk to it,
and a switching client is currently also the VM harness's liveness signal), and
**a client that can hold more than one bus** (the Go SDK reads
`NIF_NATS_URL` from the environment, so one process = one instance today).

Part II is smaller still: **identity and schedule are data, and a remote child is
just a conversation on the other instance.** A *persona* is a store document
resolved once into the frozen prompt at a conversation's birth (so editing it
never rewrites a live conversation); a *heartbeat* is a store document plus a
component on the idle seam that starts turns through a machinery-marked lane of
its own — because the existing wake lane deliberately refuses to run with nothing
pending; and cross-instance delegation goes through the `session` call the `cli`
component already uses, so it needs no wire change and the delegated work lands
as a first-class conversation the human can open and take over.

The ladder, cheapest first:

| | Slice | Effort | Where the code lands |
|---|---|---|---|
| **M0** | Profile file + `/niffler` + tunnel ownership, switch by re-exec (the `/restart` pattern) | days | `niffler-tui` plugin + ~30 lines in `scripts/niffler-tui.in` |
| **M1** | In-process multi-bus: per-component bus in `sdk/go`, N idle connections, background approvals/status | ~1–2 weeks | `sdk/go` + `niffler-tui` |
| **M2** | Harness identity: `NIF_NAME` + a persisted instance id in the catalog; `niffler-remote` lifecycle helper | days | core + `scripts/` |
| **M3** | Provisioning: `niffler-init` for a clean VM (or a compose file), tunnel-only ssh keys documented | days | `scripts/`, docs |
| **M4** | Aggregation (one connection seeing many instances) — leaf nodes / `fleet` component | weeks, optional | core bus spawn + a new component |

M0 is a real, useful feature on its own. M4 is where the hard thinking in
REMOTE.md §6.2 lives, and it is deliberately last: none of the ask requires it.

Part II is the agent side, and it is a second ladder — smaller, and mostly
independent of the first:

| | Slice | Effort | Where the code lands |
|---|---|---|---|
| **A0** | Persona: `persona` store kind, `session {persona}` → a `persona` argument on `svc.systemprompt.call`, provenance in the header | days | core (two call sites) + `components/systemprompt` |
| **A1** | Heartbeat: a component + `heartbeat` store records + a `heartbeat`-marked admission lane beside the wake lane | days | new component + core's admission branch |
| **A2** | Cross-instance delegation: `fleet` component with one connection per peer, `fleet_*` tools, durable `fleetjob` records, cross-machine settlement wake | 1–2 weeks | new component (own connections — no SDK change) |
| **A3** | Resident deployment: `systemd --user` unit, `niffler-remote`, manual-mode/keepalive/tunnel-key documentation | days | `scripts/` + MANUAL |
| **A4** | Notice contract: one record shape and one lane discipline, written into WIRE, with `fleetjob` as its cross-instance specialization (§8.3) | days | WIRE + store kinds |

A0 and A1 are useful locally and need no remote work at all; A2 wants M0's
profiles and M2's identity before it is worth shipping; A3 is a script plus
documentation. Neither half needs the wire to change.

## 1. What already works (verified, so the proposal can be small)

| Capability | Where | Why it matters here |
|---|---|---|
| Attach to any bus, local or remote, by URL | `NIF_NATS_URL` (or `.env`) → `connectWithRetry` | `NIF_NATS_URL=nats://127.0.0.1:14222` against an SSH forward *is* the remote feature |
| An explicit `NIF_NATS_URL` is attach-only — nothing is probed or spawned | `core/niffler.nim:346,366,413`; `sdk/go/harness.go:EnsureHarness`; `scripts/niffler-tui.in` | A client pointed at a tunnel never spawns a *local* harness: "bare niffler-tui" works, no local clone needed |
| The client machine never needs the remote's clone: no root match is required for an explicit URL | same | The `root` check exists to stop accidental *local* cross-attachment, not to gate remote use |
| Harness identity in the catalog (`root`, `gitHash`) | `core/dispatch.nim:595`; consumed by `sdk/go/harness.go:CoreRoot`, `tui/backend.go:78`, `/status` (`tui/controls.go:2042`) | The fingerprint a switch must verify already exists on the wire; it just is not sufficient (see §3) |
| Approvals reach *any* attached interactive client | directed `svc.approval.<caller>.request`, broadcast fallback `ev.approval.request {fallback:true}`, deny when nobody acks (`core/approval.nim:1-20`) | A tunneled client is a first-class approver for a remote VM with no extra protocol |
| UI registry with leases and per-conversation claims | `core/uireg.nim` | Switching instances is a lease/claim dance the TUI already knows how to do (per harness) |
| `cli --bus <url>` | `components/cli/main.nim:273,638` | Scripting a fleet is *already* possible; the `/niffler` work is the interactive half |
| Per-bus client state (last session) | `tui/main.go:3657` (`sha256(natsURL + workspace)`) | The keying needs to become per *instance name* (§5.4) |
| `/restart` = exit 85 → wrapper re-execs the client | `tui/handoff.go`, `scripts/niffler-tui.in` | The M0 switch mechanic, already debugged |
| The bundled `nats-server` is a component that takes flags *and* config files | `components/nats/main.go`, `core/niffler.nim:63,91` | Leaf-node/gateway configs are a spawn-argument question, not a new dependency |

Two client-side limits that shape everything below:

- **The Nim bus client is deliberately tiny**: `nats://`/`tcp://` only, IPv4
  only, `user:pass` in the URL supported, **no TLS, no token auth, no
  websockets** (`natsnim/conn.nim:426-441,527-530`). Core itself is a Nim
  client, so this binds *core's own* connections too. Any transport that needs
  TLS or tokens on the client side is therefore the wrong answer — put the
  authentication in `sshd` or in the server-to-server link, where it is free.
- **Bus payload cap**: core's own bus is started with 8 MiB
  (`natsMaxPayload`); a foreign bus at the default 1 MiB fails to publish
  large replies *silently at the caller* (core warns at boot,
  `core/niffler.nim:429-436`). A tunnel to a stock `nats-server` inherits that
  warning; the fleet client's probe should surface it per instance.

## 2. Transport: four ways to reach a remote bus

### T1 — SSH tunnel (recommended default, and the only one needing no harness change)

```bash
ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L 127.0.0.1:14222:127.0.0.1:4222 gokr@vm1.example
# then, anywhere a client resolves a bus:
NIF_NATS_URL=nats://127.0.0.1:14222 niffler-tui
```

Why it wins: the bus stays bound to `127.0.0.1` and unauthenticated exactly as
it is today (core's spawn args never change: `core/niffler.nim:91`), `sshd`
does authentication, encryption and accounting, and the client needs no SDK
capability beyond the plaintext loopback URL it already speaks. It works today
by hand (REMOTE.md §7); the work is only *owning the tunnel process* and giving
it a name (§4.3).

Details that matter:

- **Distinct local ports per instance** (`14222`, `14223`, …). The tunnel
  endpoint is loopback, so an instance tunneled onto 4222 would look exactly
  like "my own local harness" to every piece of discovery logic — including
  the TUI's per-bus state keying (`tui/main.go:3657`). Give each instance its
  own port, and key state by name, not port (§5.4).
- **Make a dead tunnel loud**: `ExitOnForwardFailure=yes` (a port already in
  use fails the tunnel instead of silently forwarding nothing),
  `ServerAliveInterval` + `ServerAliveCountMax` so a wedged link dies, and the
  client's bus-reachability indicator shows `vm1: disconnected` rather than
  hanging a turn.
- **One tunnel per instance per client.** The TUI (M1) holds one bus
  connection per instance anyway, so N tunnels is the honest shape; hops
  through a bastion are `-J`/`ProxyJump`, no new code.
- Hardening is `sshd`'s, and it is good: a **tunnel-only key** can be confined
  to forwarding one destination —

  ```
  # ~/.ssh/authorized_keys on the VM
  restrict,port-forwarding,permitopen="127.0.0.1:4222" ssh-ed25519 AAAA... niffler-tunnel@laptop
  ```

  `restrict` disables port forwarding too, so `port-forwarding` has to stay
  enabled next to it; `permitopen` then limits `ssh -L` targets to that literal
  host:port (verified semantics: `authorized_keys(5)`, OpenSSH 9.6). Add
  `from="<client-prefix>*"` where the client has a stable address, and use a
  *separate* key with `restrict,command="/usr/local/bin/niffler-remote"` for
  lifecycle commands (§4.2) so the tunnel key can never run a shell. What the
  tunnel key grants is still large — everybody on the bus can call `bash` on
  that VM, gated only by approvals (§12).

### T2 — Overlay network (WireGuard/Tailscale) with a bound, authenticated bus

`NIF_NATS_URL=nats://user:pass@100.64.0.7:4222`. Needs two small harness
changes: core must stop hardcoding `-a 127.0.0.1` (a `NIF_NATS_BIND`, or
`NIF_NATS_ARGS`/config-file passthrough — `spawnNats` already knows how to pass
`-c`, `core/niffler.nim:63,95`), and the credentials must reach both the spawn
call (`--user/--pass`) and the child components' URL. `user:pass` is the one
auth mode natsnim supports; TLS is not, so the encryption has to come from the
overlay (which is exactly what it is for). Attractive because there is no
tunnel process and a web UI can use it unchanged; costs a credential per
instance and a bind decision, and Tailscale ACLs become part of the trust story.
Good M3+ option, not the first slice.

### T3 — NATS leaf nodes (aggregation later, *not* "many cores on one bus")

Each VM's `nats-server` dials a hub, exporting selected subjects; the leaf link
can be TLS'd by the server, which neatly sidesteps natsnim's TLS gap, and the
local bus stays loopback and unauthenticated (core unchanged except accepting a
config file). This is the topology REMOTE.md §6.2 reserved for federation, and
`components/nats` is the real server, so a `leafnodes {}` block is available.

**The trap to state loudly:** two cores must never share one subject
namespace. Both would `QueueSubscribe("svc.core.call", "core")`
(`core/niffler.nim:656-658`) and *one* would silently answer for the other;
`svc.session.<id>.call`, `svc.store.call`, the flat global tool namespace and
the single-writer store flock
all assume one instance per namespace. So a merged bus is only survivable with
per-instance subject prefixes, which is a wire-contract change touching
`sdk/subjects.nim`, every component and every client — the opposite of the
"one wire" promise. Until someone wants that badly, leaf nodes are for
**observability and fleet events** (`ev.>` aggregated at a hub, a shared `fleet`
registry), while *control* stays per-connection. Subject-rewriting export/import
rules might make a merged control plane possible without touching components,
but that is an unverified nats-server semantic: park it as a spike, not a plan.

### T4 — Just open the bus port (don't)

Requires TLS (natsnim cannot) or accepts cleartext, plus token auth (natsnim
cannot; `user:pass` only), plus the bind change; and everyone on that port can
call `bash` on the VM, read every conversation and every provider credential in
the store. It buys nothing that T1/T2 do not, with a worse boundary. If a
5-minute version is ever wanted, put it behind `NIF_NATS_BIND=<tailscale-ip>`
and treat the overlay as the security boundary — never a bare `0.0.0.0:4222`.

| | Auth & crypto | Harness change | Per-client process | Sees many instances at once | Verdict |
|---|---|---|---|---|---|
| **T1 SSH tunnel** | sshd (keys, `permitopen`) | none | one `ssh -N` per instance | no (N connections) | **default** |
| **T2 overlay + `user:pass`** | overlay + NATS password | small (bind, creds) | none | no (N connections) | later, for web/UI clients |
| **T3 leaf nodes** | TLS on the leaf link | small (config file) | server-to-server | events yes, control no (namespace!) | M4 aggregation |
| **T4 open port** | whatever you typed | small | none | no | don't |

## 3. Identity: never attach silently

The invariant that already protects local use — "attach only to a bus whose
core serves *this* root" (`core/niffler.nim:377-402`, `sdk/go/harness.go`,
`components/cli/main.nim:329`) — does not carry to a fleet, for two reasons:

1. **Root + revision are not unique across hosts.** Two VMs both checked out at
   `/home/gokr/nifflerprod` on the same commit are indistinguishable on the
   wire today (`catalog {op:list}` returns exactly `root` + `gitHash`,
   `core/dispatch.nim:595`), and a rebuild moves `gitHash` under a *correct*
   match, so it cannot be the identity either.
2. A tunnel to the wrong host/port, a reprovisioned VM, or a stale local port
   would otherwise be adopted silently — the failure mode the home-bus claim
   exists to prevent ("never a silent cross-attachment").

So M2 adds the missing identity, in the same place and spirit as the existing
one:

- **`NIF_NAME`** — the operator's chosen name (`vm1`, `gpu-box`), defaulting to
  the hostname when unset. `catalog` gains `name` (one line next to
  `root`/`gitHash`, `core/dispatch.nim:595-599`); `/status` and the TUI header
  show it.
- **A persisted instance id** — a UUID written once at first boot
  (`var/instance-id`, or a store doc) and carried in `catalog`. This is the
  stable identity; name is a label, root is a path, `gitHash` is a build.
- **Client-side verification rules**: a profile entry records the expected
  `{id, name}` (+ root, for readability). On connect the client requires `id`
  to match; a mismatch is a **loud refusal** ("vm1: bus is a different instance
  (id …) — refusing to attach"), never a warning-and-continue. A changed
  `gitHash` is a note, not a refusal (`/niffler probe` refreshes it); a changed
  name or root with the same id is a note too (rename/host migration), and the
  client offers to update the profile.

Until M2 ships, M0/M1 must approximate verification with `{root, gitHash}` and
say so in the refusal text. That is honest but insufficient, which is why M2 is
small and early rather than clever.

## 4. Lifecycle: who starts the instance, who keeps it alive

### 4.1 The gotcha that must be designed around

A harness started with `NIF_AUTOSTART=1` (the SDK/wrapper "boot one on demand"
path) **exits when its last interactive client departs** — 10 s idle debounce,
plus a 60 s boot grace (`core/niffler.nim:653,690-700`). A fleet client's
connection *is* that liveness signal. So a client that switches away from a
remote instance it autostarted would shut that instance down — possibly
mid-turn.

Two rules follow, and both are cheap:

- **Remote instances are started in manual mode** — no `NIF_AUTOSTART` — where
  a core "never self-terminates on client churn" (`core/niffler.nim:643-646`).
  They stay up until explicitly stopped, which is also what "a VM that is
  alive" should mean.
- **A profile may opt into `"keepalive": true`** for throwaway/dev VMs: the
  client keeps a 0-tool `client:true` registration on that bus (the `cli`
  driver already registers this way, `components/cli/main.nim:367-374`) so the
  instance lives exactly while the fleet client is around. Default off, and
  the UI says which instances are in that mode.

### 4.2 `niffler-remote`: the lifecycle contract

Starting a remote instance cannot itself go over the bus (chicken and egg), so
it goes over SSH, through one deliberately tiny script on the VM:

```
niffler-remote start|stop|status|logs|probe     # ~/bin or /usr/local/bin
```

- `start` — `setsid`(or `systemd --user`) the core in **manual mode**, with the
  VM's own `.env`; prints the resolved bus URL; idempotent (adopt a running
  instance, like `von_status` adopts one).
- `status` — pid, uptime, bus URL, name/id/root/rev, client count. This is what
  the client shows as `vm1: up, idle`.
- `stop` — SIGTERM the core (children carry PDEATHSIG, so the stack follows;
  the bus is reaped by its owner, `core/niffler.nim` teardown).
- Recommended deployment is a `systemd --user` unit for a long-lived VM;
  `niffler-remote` is the portable fallback for boxes you do not administer.

Pair it with a *second* SSH key in the profile
(`restrict,command="niffler-remote"`), and the fleet client gets start/stop
without a general shell.

### 4.3 Who owns the tunnel

Three candidate owners, and the answer depends on whether a local harness
exists:

- **The client itself (M0/M1, no local harness required)** — the TUI spawns and
  supervises `ssh -N -L` per instance, kills it on switch-away/exit, and shows
  its state. Simplest, and it is what makes "bare niffler-tui on another
  machine" real. Cost: a client crash can leave an `ssh` process (reap by
  pidfile/port check, the way the harness already reasons about leftover
  `nats-pid`).
- **The wrapper `scripts/niffler-tui.in` (M0)** — it already owns the client's
  process lifetime and the core autostart, and it already loops on exit code 85
  for `/restart`; supervising tunnels there is natural for M0 and keeps the
  plugin simple.
- **A `fleet` component in a local harness (M4)** — tunnels belong to the
  supervised stack, are shared by every local client (TUI, web UI, `cli`), and
  survive client restarts. This is where a fleet registry *should* end up; it
  is not needed to start.

## 5. The `/niffler` command (client UX)

Modelled directly on `/fav` (`tui/favorites.go`): one **ordered** list whose
order *is* the rotation order, a management command, and a key combo that
applies the next entry. The differences are forced by the medium: favorites
live in the harness's store (`kind: modelfavorite`) because they describe *that
harness*; the instance list must exist **before** any connection, so it is a
client-side file (optionally mirrored into a local harness's store later, §10).

### 5.1 Where it lives

`~/.config/niffler/instances.json` (XDG config; per-instance *state* stays
under `~/.local/state/niffler/`):

```json
{
  "order": ["local", "vm1", "gpu"],
  "instances": {
    "local": { "url": "", "workspace": "" },
    "vm1": {
      "ssh": "gokr@vm1.example",
      "localPort": 14222, "remotePort": 4222,
      "workspace": "/srv/work",
      "start": true,
      "expect": { "id": "9f3c…", "name": "vm1", "root": "/home/gokr/nifflerprod" }
    },
    "gpu": { "url": "nats://user:pass@100.64.0.7:4222",
             "expect": { "id": "1b77…", "name": "gpu" } }
  }
}
```

`order[0]` is the default on launch; `"local"` with an empty URL means "whatever
discovery resolves", i.e. today's behaviour. An `instances.json` that is absent
or malformed degrades to exactly one implicit entry (`local`) — the client must
never fail to start because the fleet file is broken.

### 5.2 The commands

- `/niffler` — list with live state (the `/fav` pattern: `Ctrl+N` rotates;
  `/niffler add` records; `/niffler <n|name>` uses). One line per instance,
  active one starred:

  ```
  * 1 vm1   gokr@vm1.example   connected  idle   3 sessions   Niffler 2/1
    2 gpu   nats://100.64.0.7  tunnel down        —            last: 2h ago
  ```

- `/niffler add <name> [--ssh user@host] [--bus url] [--workspace path]` —
  appends to `order`, connects, records the verified fingerprint (refuses to
  add an instance whose id differs from an existing entry of the same name).
- `/niffler rm <n|name>`, `/niffler rename <n|name> <new>`, `/niffler <n|name>`
  (switch), `/niffler up <name>` / `down <name>` (lifecycle via
  `niffler-remote`), `/niffler probe [<name>]` (re-verify identity, report
  bus payload cap, revision drift, workspace existence).
- `Ctrl+N` — rotate to the next instance in `order`, wrapping (`Ctrl+P` back,
  optional); displayed in the keys line next to `ctrl+x favorite provider/model`
  (`tui/i18n.go`), with the active instance in the status bar.
- `/status` gains an instance line: name, root, `gitHash`, bus (and tunnel
  state), so "which clone am I talking to" keeps its existing answer
  (`tui/controls.go:2042`) plus the new one.

### 5.3 What a switch actually does (and must not do)

Follows the ordering rules the TUI already established for `/session`:

1. **Resolve the target**: tunnel up if needed (`/niffler up` semantics),
   probe `catalog {op:list}` with a short timeout, verify identity (§3).
   Refuse loudly on mismatch and stay where we are.
2. **Secure before releasing**: claim the target's conversation with the target
   registry, *then* release the old instance's claim — the existing
   `/session` order ("a failed switch never leaves us conversationless",
   `tui/session_history.go:307-320`).
3. **Swap the connection**: unsubscribe/tear down the old component (its taps,
   its approval subject, its `client:true` registration), connect the target
   (M1: pre-existing idle connection reused), `ui register` → numbered per
   harness ("Niffler 2" *of vm1*), claim the target session, replay transcript
   from *that* store, probe for a live turn
   (`sessionProbeCmd`) exactly as attach does.
4. **Recall the right state**: the per-instance last session comes from a state
   file keyed by **instance name + workspace**, not by bus URL — a tunnel port
   change must not lose the memory, and a *different* instance reusing a name
   is caught by the id check in step 1, never by resuming the wrong
   conversation (`tui/main.go:3657` has the current keying; this is the one
   line that has to change).
5. **Clear the surface**: viewport, attachments, diagnostics — there is already
   precedent that a session switch clears both
   (`TestSwitchSessionClearsViewport`, `TestSessionSwitchClearsAttachments`),
   and "never show stale data from the previous backend" is the rule REMOTE.md
   §1 borrowed from OpenHands' backend specs. The header shows the instance.
6. **Remote workspace**: the local launch directory is meaningless on the other
   machine (a conversation workspace must be an existing directory *there*,
   `core/conversation.nim:3240-3258`, and it is immutable after the first turn).
   A new conversation on a remote instance therefore pins the profile's
   `workspace` (default: that instance's `NIF_ROOT`) and the client must say so
   in the block that opens it. Sending the local cwd would earn a loud
   "cwd is not a directory" — correct, but a bad first impression.

Things a switch must **not** do: silently steer or cancel a turn on the
instance being left (that connection is the wrong one to send on), answer an
approval for an instance it is not showing without labelling it (§5.5), or
present a stale model/provider pin from the previous instance (the per-instance
provider/model state comes from *that* store's docs, the way
`TestProviderSwitchDropsStaleConversationModel` demands today).

### 5.4 A busy turn on the instance you are leaving

The remote runner keeps working — buses are not the client's, and a turn is
owned by its runner (`core/session.nim`, "a second turn is refused with
`busy`"). So switching away from a running turn is safe and should be *allowed*,
with an honest marker: the status bar keeps a background badge (`vm1: turn
running`, `vm1: approval pending`) fed by the idle connections of M1; switching
back resumes the live token stream. What must not happen is a hidden queue of
steers/cancels aimed at the wrong instance — `esc`, steering and `/limit`
always apply to the active instance only, and their help text says so.

### 5.5 Approvals from background instances (the reason M1 is worth building)

A tunneled client is an approver: a remote agent blocked on `bash` is waiting
for a human, and the gate has no other reachable human. So the M1 client keeps
each instance's approval subscription alive and surfaces a background request
as a **modal tagged with the instance name** (`vm1: bash …`) — answering routes
the verdict on that instance's connection, and `ev.approval.resolved` closes
the stale modal (`core/approval.nim:1-20`). Options: "notify only" per
instance, and a global "quiet instances" toggle. This is the fleet client's
biggest advantage over a REST-shaped control plane: the gate arrives as an
event, labelled, without polling.

### 5.6 Remote-specific rough edges to state, not hide

- **`clickopen` resolves paths against the harness root**
  (`tui/clickopen.go:224`): for a remote instance those are remote paths.
  Correct behaviour is to disable open/link-to-file for remote instances, or
  open `ssh://user@host/path` (plus an optional profile `editor` command run
  over ssh) — never to resolve them locally.
- **Attachments** are read locally and sent as base64 in the turn
  (`tui/attach.go`), which works over a tunnel but is wasteful for large files;
  a remote instance has no `fetch`-style upload path until someone adds one.
  Fine for images, worth a note for anything bigger.
- **Clipboard** (OSC 52 / `/copy`) copies *the client's* clipboard from the
  remote transcript — correct by construction, just worth knowing.
- **Costs and credentials are per instance**: a remote VM's `provider` docs and
  API keys live in *its* store (`core/../store` kind `provider`), so
  `/provider`, `/model` and `/fav` show *that* instance's world. Say so in the
  fleet help text; the temptation to "share keys" is what a shared store would
  be for (REMOTE.md §6.2), not the fleet client.

## 6. Persona: who the agent is at birth

### 6.0 Prior art: the word is established, but it names the *prompt half*

Surveyed on the harness shelf (2026-10-14). "Persona" is **not** a Niffler
coinage, and it is never the name of the whole agent: everywhere it means the
prompt-identity contribution, inside something larger.

| Harness | What it calls the whole thing | What it calls the prompt part |
|---|---|---|
| **dsh** (deepseek-harness) | **agent preset** (`preset.yml` + `cordis.patch.yml`, `@deepseek-ai/dsh-agent-preset`, ids `standard`/`ptc`/`minimal`/`cordis`) | **persona** — the `@deepseek-ai/dsh-persona` plugin, `personaPrefix`/`personaSuffix`, system-prompt sections named `deployment:persona-prefix` |
| **CodeWhale** | **agent profile** — `.codewhale/agents/`, `$CODEWHALE_HOME/agents`, and `.claude/agents` (Claude Code's convention) | **`persona`** *or* `instructions.text` — the parser takes `instructions` and falls back to `persona`; the profile also carries `role_hint`/`base_role`, `loadout` (tools), `model`, `provider`, `requires` (capability requirements) |
| **OpenHands** | agent profile / template | **`persona`**, as a *field distinct from* `system_message_suffix`: persona replaces the prompt, instructions append to it |
| **Reasonix** | "output style" (a selectable, user-authored block) | the doc comment says it plainly: *"adds a selectable output style — a block of persona … appended to the system prompt"* |
| **gemini-cli** | subagent (`.gemini/agents`, `subagents.md`) | prose only: *"Each subagent has its own system prompt and persona."* No field. |
| **pi, kimi-cli, maki** | — | the word does not appear at all |

Two conclusions for Niffler:

1. **`persona` is the right word for what A0 shipped** — the body that becomes
   the frozen prompt. It matches dsh's plugin, CodeWhale's field and OpenHands'
   field.
2. **It is the wrong word for the whole document** if that document also carries
   tools, model and budgets — which is what §6.1 below proposes. The prior art
   calls that an **agent profile** (CodeWhale, OpenHands) or an **agent preset**
   (dsh). Niffler already spends *profile* on tool profiles (the `profile`
   tool), so the collision is real and worth a deliberate decision (§6.2).

CodeWhale's `.claude/agents` compatibility is the interesting interop detail:
that convention is markdown with YAML frontmatter (`name`, `description`,
`tools`, `model`) plus a body, read from both the project and the home
directory — a format Niffler could read as-is (§6.2).

### 6.1 The design

Today a child's *identity* is whatever the task text implies: `agent_run`
prepends a fixed `taskPreamble` ("You are a subagent…",
`components/agent/main.nim:38-46`) and everything else — model, thinking, tool
allowlist, budgets — is passed per call and frozen at the child's first turn.
Nothing names *what* the agent is. [SUBAGENTS.md](SUBAGENTS.md):49,318-319 records
`persona`/`toolFilter` as the two gaps (the tool allowlist is the half that
exists), and the closest existing seam is the `prompt_hint {slot, content,
source, key, mode}` tool that renders `<prompt_slot name="…">` blocks
(`components/systemprompt/main.nim:169-203,300-304`). That seam is **global and
forward-only**: one registration affects every conversation composed after it.
Right for a plugin contributing tool guidance, wrong for per-conversation
identity.

**A persona is data.** `store kind "persona"`, id = the name:

```json
{ "name": "reviewer",
  "body": "You review changes the way this repo reviews them: …",
  "toolProfile": "review", "model": "…", "thinking": "high",
  "budgets": {"maxRounds": 12, "maxCalls": 60},
  "approvals": "ask", "workspace": "/srv/reviews", "note": "nightly PR pass" }
```

Written by the human or by the agent (store `put`, or a persona-shaped wrapper
tool later), read by core. No component learns a role list and no `case persona`
branch appears anywhere: adding a persona is adding a document — the AGENTS.md
data-vs-code test passing by construction.

**Resolution happens once, at birth, and is frozen.** `session {persona:
"reviewer"}` → core passes `persona` to the systemprompt component (today's call
carries `{cwd, sessionId, firstMessage}`, `core/conversation.nim:77-83` — a
one-field, backward-compatible addition) → the component composes the base
prompt + project context files + a `<persona name="…">` block + the global slot
fragments, and core persists the result in the conversation header exactly as
today (`resolveSystemPrompt`, `:88-110`). The persona's other fields land in
mechanisms that already exist and freeze at that same moment:

| Persona field | Existing mechanism it resolves into |
|---|---|
| Persona field | Existing mechanism it resolves into | Status |
|---|---|---|
| `body` | the frozen system prompt (via `systemprompt`) | **shipped** (A0) |
| `toolProfile` | the frozen direct toolset (tool `profile`, resolved at the first turn) | planned |
| `model`, `thinking` | the header's frozen controls | planned |
| `budgets` | `maxRounds` / `maxCalls` / `maxTokens` | planned |
| `workspace` | the conversation workspace (immutable after the first turn) | planned |
| `approvals` | the conversation's gate mode (`ask`/`auto`) — **the human's explicit `/approvals` setting wins**, because that gate is the security boundary | planned |

Only `body` (and the `name` used in the tag) is wired today: A0 deliberately
shipped the prompt half first — it is the part with no existing mechanism to
reuse, and the part the cache discipline shapes. The remaining rows are
pass-throughs to arguments that already exist, and are better done together
(§6.2) than one at a time.

### 6.2 The naming decision

Three names are in play for three different things, and the codebase has already
half-decided two of them.

**1. `persona` = the text.** Settled (A0 shipped it) and it matches the shelf's
usage (§6.0).

**2. `profile` → `toolset`.** The interesting evidence: Niffler's *identifiers*
already call this a toolset, everywhere, while only the *surface names* say
profile —

| Says "toolset" (concept) | Says "profile" (surface) |
|---|---|
| `exposure.toolset`, "resolved once into a conversation's direct toolset", `if withToolset && !withSystemPrompt` semantics in tests, "frozen toolset snapshot" | the `profile` core tool, `session {profile}`, store kind `"profile"`, `NIF_PROFILE`, TUI `/profile`, `profileTokens` |

So this rename is not a preference — it aligns four public surface names to the
vocabulary the code has been using all along. Mechanical, wire-compatible in
practice (the `session` schema's key stays readable for one release while the
canonical spelling becomes `toolset`), and worth doing on its own merits.

**3. The definition document.** The shelf's word for it is **agent**:
opencode's `agents.mdx` defines an agent as *"specialized AI assistants …
custom prompts, models, and tool access"* — exactly the combined document —
with `primary`/`subagent` modes, Tab-cycling between them and `@`-mention to
invoke; CodeWhale calls it an agent profile; dsh calls it an agent preset. The
counter-argument to reusing `profile` here is that it makes "profile" mean two
unrelated things permanently, and Niffler already has a *provider* profile
surface in the TUI (`provider_list` fields, the OAuth/profile editor), so a
third meaning would be the one with no precedent behind it.

That leaves the collision to weigh: in Niffler, **`agent`** is currently the
component name, the `agent_*` tool prefix, and the word for a running subagent.
Using it for the definition too is a deliberate overload, and it needs a rule to
be usable:

> bare `agent` = the **definition** document · `agent_*` = the tools that run
> one · "a subagent" = a running instance of one · the `agent` component = the
> implementer of those tools.

That reads naturally ("what agents do I have?" / "list my agents" = definitions)
and it is what a user of opencode or Claude Code would already expect. The
alternative — `agentdef` — is accurate but, as noted, contrived; it also loses
the interop advantage, because the importable formats on the shelf are
`agents.mdx`-style documents and `.claude/agents` files, both of which call the
thing an agent.

**Recommendation:** `persona` (text), `toolset` (tool visibility), `agent`
(definition), with the overload rule above written into WIRE. If that overload is
judged too costly, the fallback is `agentdef` — accurate, and the only cost is a
word nobody says out loud.

**What is *not* needed is new machinery.** All three fields a definition would
set are mechanisms that already exist and freeze at birth:

| Definition field | Lands in | Already exists as |
|---|---|---|
| `persona` | the frozen system prompt | A0 (shipped) |
| `toolset` | the frozen direct toolset | `session {profile}`, `profile` tool |
| `model`, `thinking` | the header's frozen controls | session args |
| `budgets` | round/call/token caps | session args (subagents pass them per call — `components/agent/main.nim:938-945`) |
| `workspace` | the conversation workspace | `cwd` (birth-only already) |
| `approvals` | the gate mode | `approvals` control (human's setting wins) |

So "resolve an agent" is a **resolution order**, not a subsystem: for each field,
`explicit argument > definition field > harness default`. The work is the
resolver plus one provenance surface — and the provenance surface is the part
that makes it debuggable, because "which model am I actually running?" must not
become a guessing game.

**One divergence from opencode worth recording:** their agents are switchable
mid-session (Tab) because they rebuild the prompt. Niffler's cache discipline
forbids that — a definition is birth-only, exactly as persona proved. Switching
identity means a new conversation (or, later, a deliberate prefix rebuild with an
explicit `reset:agent` reason, the way `reset:tools` already works for sticky
invokes). That is the honest cost of the frozen prefix, and it should be stated
up front rather than discovered when someone tries to Tab between agents.

### 6.3 Rules the shipped half already enforces

A0 froze the three laws below in code, and its test pins each of them. Worth
naming what the implementation does *not* do yet, so the doc cannot overclaim:
the prompt half is complete (resolution, placement, birth-only, edits that never
rewrite, a resume that never re-resolves, an unknown persona that degrades to the
plain prompt with the reason on stderr), while the policy half of §6.1's table is
absent by design.

### 6.4 The laws

Three laws, all consequences of the prompt-cache discipline:

- **Birth-only.** `agent_spawn {persona}` applies to a fresh child; a
  continuation refuses it — the rule `fork` already follows ("a fork is a birth,
  not a continuation"), and for the same reason: the child's prefix is frozen.
- **Edits never rewrite history.** Changing the `persona` document affects only
  conversations born after it. The header stores `persona: {name, digest}` so a
  later edit is *visible* as drift (a UI can say "persona edited since this
  conversation was born") instead of silently inconsistent.
- **No mid-conversation switching.** A persona is not a runtime mode; switching
  identity means a new conversation. That keeps the request prefix byte-stable,
  and it is what makes the resident story (§9) cheap.

What a persona deliberately is not: a second system-prompt channel for one
conversation, a tool-schema mechanism (that is a tool `profile`), or a way to
grant capability the human has not approved.

## 7. Heartbeat: waking an agent nobody is driving

A turn today starts from a human, or from a *wake* that folds settled subagents:
`session {wake: true}` is admitted only when something is pending — core peeks
`agent_notices {peek: true}` and declines a wake with nothing to fold
(`core/conversation.nim:3858-3888`) — and it is bounded by `NIF_AGENT_WAKES`
(default 3) consecutive wake-marked messages, reset by the human's next real
message. Both properties are deliberate, and together they mean a heartbeat
**cannot** be a wake: nothing is ever pending for it, and the budget would refuse
the fourth tick. That is the constraint the design has to respect — and
respecting it is what keeps the wake lane honest ("machinery that serves work
the human asked for").

So: a `heartbeat` component plus `store kind "heartbeat"` records —

```json
{ "id": "nightly-pr-pass", "session": "vm1-review", "enabled": true,
  "intervalSec": 86400, "prompt": "Check the open PRs and report.",
  "budgets": {"maxPerDay": 4, "maxTokensPerDay": 400000},
  "nextAt": 1730000000, "lastAt": 1729913600, "lastResult": "ok" }
```

— ticked through the SDK's **idle seam** (`comp.onIdle`: the same seam
`processes` reaps background children with and `lsp` publishes diagnostics
through; all three SDKs have it, so this component can be Nim, Go or TS). When a
record is due, the component calls the existing session lane with a **third
machinery marker**, `notice: {kind: "heartbeat", id: …}` — the same structural
lane as wakes, so rendering, trimming and compaction already treat it as
machinery and never as something the human typed (the TUI's stored-message
renderer keys on `notice` today: `tui/session_history_test.go:326`,
`tui/main_test.go:3079-3095`). Admission rules:

- The heartbeat component owns the budget check *before* publishing, and the
  runner rejects a record whose budget is spent — defense in depth, so a stale or
  hand-edited record cannot punch through.
- A heartbeat that arrives while the runner holds a turn is **skipped, not
  queued** (`busy`), and retried at the next tick: a scheduled turn must never
  queue behind a live human turn.
- Nothing is persisted when the record is not due: a heartbeat is a policy
  object, not an empty user message.

Why a component and not core work: it is optional (a stock harness must not pay
for it — the `von`/`jev` precedent), it is per-instance and local (exactly right
for a fleet, §8), and the agent can write or replace it like anything else.

What a heartbeat is **not**: it keeps nothing alive. The harness stays up in
manual mode (§4.1), and a session runner retires after `NIF_RUNNER_IDLE_S`
(default 600 s) and is respawned on demand (`core/session.nim:186-193`). The
heartbeat is a *trigger*; liveness is answered elsewhere.

Two honest consequences:

- **Approvals.** A heartbeat turn can hit the gate (`bash`, `spawn`), and on a
  server with no human attached the gate **denies** — correctly. A resident
  agent therefore either works with read-effect tools, or the human grants that
  conversation `auto` knowingly (§6). Heartbeat + auto approvals is autonomous
  shell on a server; enter it deliberately, and let the instance's status line
  say so.
- **Cost.** Every tick is a full turn: tokens, money, and a real assistant
  message in the transcript. Per-day budgets and a visible `nextAt`/`lastResult`
  are not decoration — they are what makes a heartbeat trustworthy enough to
  leave enabled.

## 8. Delegation across instances: one conversation, many machines

### 8.0 One contract, two surfaces (why `agent_*` and `fleet_*` overlap on purpose)

`agent_*` and `fleet_*` share a verb — *delegate work to a conversation that is
not this one* — so the overlap is real and should not be papered over. The
useful question is which half of it is the same thing. Answer, from the code:

**Shared, and it must stay shared (these exist once, not twice):**

| Shared thing | Already generic in the harness |
|---|---|
| The delegation record shape | `sessionmeta` (`{parent, fork, activations, firstActivationAt, closed}`) — *read* generically by core: `session_info` surfaces parent/fork/activations/closed and counts children (`core/dispatch.nim:789-812`), and the depth walk counts `sessionmeta.parent` links (`:1711-1726`) |
| The depth guard | `x-harness.noSpawn` + `lineageDepth` at dispatch time (`core/dispatch.nim:2000-2014`): any tool carrying the annotation inherits it, including the two deliberate properties — the tool **stays visible at the cap** and refuses *loudly* with the caller's depth, so the model learns why instead of finding a hidden tool |
| Report-back | the durable job record + settlement notice + the `session {wake: true}` lane (`components/agent`'s `tryWake`) |
| Continuation authorization | the append-only continuation contract (content only; lineage checked; explicit refusals) |
| The refusal vocabulary | unknown / self / root / foreign / closed / busy / unreachable — one spelling, so a model reads the same failure the same way wherever it delegated |

**Different, and must not be merged (this is where the two nouns earn their
keep):**

| Difference | Why it is structural |
|---|---|
| **Address space** | `agent_*` names a session id **in this harness's own store** — no discovery, no peer set, no transport, no identity check. `fleet_*` names a **peer** first: registry, tunnel, identity verification, connection per peer. Everything hard about fleet lives here, and none of it applies locally. |
| **Failure model** | A local child fails as a runner crash (its store is always reachable). A remote job fails as *tunnel down / peer unreachable / peer restarted mid-turn / peer's revision lacks the tool / our connection died while the remote turn kept running*. `unreachable` must never be rendered as `interrupted`. |
| **Authority** | A local child's approvals route to **this** human's client (one bus, `x-harness.sessionContext` forwarding). A remote child's approvals are answered on the **peer's** bus, by whoever is attached there — possibly a different human. That difference must be visible, not normalized away. |
| **The noun the model plans with** | "A subagent" is cheap, local, idle-retired after 600 s (`NIF_RUNNER_IDLE_S`), and spends this harness's budget. "A machine" is persistent, has a name, its own humans, its own repos and its own key. Merging the tools would teach the model that fanning out to five machines is like fanning out to five subagents — it is not: it spends someone else's money, writes someone else's filesystem and can block on someone else's approval. |

**So: reuse the contract, keep the address space distinct.** Concretely —

- `fleet_*` tools carry the same annotations as `agent_*` (`x-harness.
  sessionContext`, `noSpawn`, `onDemand`, approval on the mutating ones), so the
  depth guard and the session-context proxy work unchanged.
- A remote child gets a **local mirror** `sessionmeta` record
  `{parent: <local session>, peer, remoteSession}`, so core's existing readers
  include remote children for free: `session_info {children: N}` counts them,
  `agent_list`'s roster shows them, and the depth walk sees them. The mirror is
  **visibility, not authority**: continuing or stopping a remote child is
  authorized by the fleet component's own registry (peer + remote session),
  never by the local mirror alone — the local record cannot grant access to a
  conversation whose messages live in another store. And the remote child must
  never be resumable locally: the local handle is qualified (`vm1:<id>`), so the
  local runner can never mistake it for one of its own.
- One **drift guard**, in the spirit of OpenHands' machine-enforced architecture
  tests: a catalog-level contract test asserting that *every* tool which starts a
  delegate (a schema with `noSpawn`, or whose component writes `sessionmeta`)
  also carries `sessionContext`, and that `unreachable` and `interrupted` are
  distinct in its status vocabulary. A third delegation surface should not be
  able to be born sloppy.

**If the two ever merge into one noun, the merge point is `team`, not `fleet`.**
A teammate (named, with a persona and a durable mailbox — already on the PLAN
from DSH-STEAL §5) is a local subagent *plus identity*; a resident remote agent
is a teammate *plus a location*. The axes are separable — who (persona), when
(heartbeat), where (peer), what (delegation) — and each is data, so the
composition is cheap *later* precisely because the surfaces stay honest *now*.

### 8.1 The mechanism

The local subagent tools are bus-local by construction: `agent_run`/`agent_spawn`
prepare a child on the local store, lineage is `sessionmeta.parent`, the depth
cap and `noSpawn` guard are enforced by the local dispatch gate, and the
settlement tap watches the local bus. None of that crosses a machine — and it
does not need to, because the bus already carries the one call that does.

**A remote child is a conversation on the other instance.** The fleet component
opens a session there with the existing `session` call and a fresh session id —
exactly what `components/cli` already does for headless turns
(`components/cli/main.nim:676,1027`, which even connects to an arbitrary
`--bus`). The result is a first-class conversation *on that instance*: durable in
its store, listed in its sessions, steerable and cancellable over its bus, and
continuable by sending content only — so the remote child's cached prefix
survives, the same append-only rule local continuation obeys.

The component (`fleet`, planned as M4, running on the **local** bus) holds one
connection per peer. That is cheap and needs no SDK change: components already
open their own `natsnim` connections beside their component one
(`components/cli`, `components/console`), so the peer taps, the `session` calls
and the `catalog` probes are plain client code. Its tools, written so the model
can tell them apart from the local three:

- `fleet_agents` — peers, their `NIF_NAME`/id/revision, their resident personas
  and heartbeats, live turn state.
- `fleet_run {peer, task, persona?, model?, background?, origin?, approvals?}` —
  one conversation on one peer; `background: true` returns a `jobId`
  immediately, and `approvals: "auto"` is the explicit, recorded decision to let
  it run unattended (§9.1).
- `fleet_fanout {peers: [...], task, …}` — the many-machines case: one
  conversation per peer, results gathered as they settle.
- `fleet_status` / `fleet_wait` / `fleet_steer` / `fleet_stop` — durable records
  (`store kind "fleetjob"`: `{peer, remoteSession, origin, status, summary,
  approvals, tokens}`), never a lying "running" after a restart.
- `fleet_inbox {since?}` — the reconnect digest: every job since you last
  looked, reconciled read-only against the peers, with what needs your decision
  first (§9.1). The client's `/niffler inbox` is the same call.

The split the tool descriptions must state plainly (they are the model's only
window): `fabric` for mechanical fan-out over *data* in this process, `agent_*`
for subagents *on this instance*, `fleet_*` for *other machines*.

Settlement crosses back the way subagent settlements already do: the component
taps the peer's `ev.session.<id>.turn` on its own connection, writes the local
terminal `fleetjob` record, and reuses the local wake path (`session {wake:
true}` on the parent conversation — the same code path and budget as
`components/agent`'s `tryWake`) so an idle parent is woken with a bounded,
labelled summary. **Approvals are the exception:** they stay on the peer's bus,
where the human's fleet client is attached (§5.5). Relaying an approval into the
local conversation would move a human's authority across a machine boundary
implicitly; the fleet client surfacing `vm1: approval pending` is the honest
version.

Guards, because cross-machine delegation is where a small mistake becomes a
distributed one:

- **Single-hop by default.** A conversation launched by `fleet_run` carries an
  origin marker and the `fleet_*` tools are hidden from it, so a remote child
  delegates locally (its own `agent_*`) but cannot recurse across machines unless
  the human configures that instance's peer list explicitly.
- **Version skew is checked, not assumed.** The component reads the peer's
  `catalog` (`root`, `gitHash`, and after M2 `name`/id) and refuses a job whose
  required capability the peer lacks. A half-working delegation is worse than a
  refusal.
- **Authority stays with the peer's human.** The remote child's tools, budgets
  and gate mode are fixed at its birth *there*; the local caller cannot widen
  them, exactly as a local subagent cannot widen its own.
- **The peer list is a secret** (§12): it holds SSH targets and bus URLs, lives
  client-side (or in a local store scope), and is never pushed to peers.

The reverse direction — a peer delegating into us — is deliberately out of scope
for the first cut: it needs the same component on the other side plus a mutual
trust decision, and nothing in the "drive my machines" ask requires it.

### 8.2 Where the notice lives (there is no outbox on the peer)

Facts first, because they answer the question exactly:

- Notices are written by the **spawning side, into the parent's store**:
  `agentnotice` records keyed `<parentSession>:<seq>`
  (`components/agent/main.nim:225,1421-1489`), with `deliveredAt`/`deliveredVia`
  marking delivery when they are drained (`agent_notices`, `:1577-1605`).
- The fleet component spawns through the peer's `session` call, so on vm1 that
  conversation is an ordinary **root conversation**: no `sessionmeta` (no
  parent), no `agentnotice` records, nothing addressed outward. Its result is
  its transcript in vm1's store — which is not a gap. A root conversation's
  result *is* its history.
- Therefore the tracking is entirely **ours**, and it has to be: the *pointer*
  must live somewhere durable that survives the peer restarting, the tunnel
  dying or the peer being unreachable. Our `fleetjob` record
  `{peer, remoteSession, origin, status}` is the outbox entry; the peer's
  transcript is the payload; we hold the address.

That is precisely why §9.1 works: the records are durable locally, and the truth
they point at is durable on the peer (reconcile). The peer stays "just another
Niffler" — it runs a conversation and knows nothing about being remote.

**Two relationships, often confused (get this straight or the rest reads
wrong).** The horizontal relation is ours and is not lineage; the vertical ones
belong to the peer and are ordinary:

```
   requester (laptop)                       peer (vm1)
   ------------------                       ----------
   parent conversation ──── fleet_run ────> X   (a ROOT conversation there)
        |                                     |
        └── fleetjob {peer, session: X}       ├── agent_spawn ──> child #1
            (the pointer, our store)          └── agent_spawn ──> child #2

                                            in the peer's store:
                                              sessionmeta.parent = X
                                              agentnotice "X:000001"  (X's mail)
```

- The horizontal edge is **ours**: no `sessionmeta` on the peer says X belongs to
  anyone, and the peer sees a conversation with a task in it. Our `fleetjob` is
  the pointer that makes it a fleet job.
- The vertical edges are the **peer's**, and they are exactly what they would be
  locally: X is the parent of the children *X* spawns, and their notices are
  addressed to X (`X:<seq>`).

So the answer to "where do the notices go when the remote agent spawns
subagents" is: **to X, on the peer** — and they are delivered by the peer's own
lanes (steer while X is mid-turn, wake while X is idle and its budget allows,
pull at X's next turn). X needs no awareness of being remotely driven, which is
precisely why the peer needs no new feature. The only thing crossing the machine
boundary is our pointer.

A useful corollary: an undrained notice is still *readable* — `store list {kind:
"agentnotice", idPrefix: "X:"}` on the peer's bus is an ordinary read, and
reading is not delivering. So a morning digest can honestly report "X: 2 notices
not yet folded" without waking X.

Two consequences to own rather than discover:

- **Two directions of loss.** Wipe the peer and the work is gone (it is the
  peer's store — back it up). Wipe the *requester* and the pointers are gone:
  the remote conversations survive, orphaned, and nothing local names them. The
  cheap fix is self-description **on the peer**: stamp the spawned conversation's
  header with an opaque origin (`origin: {instance, session}`) and a title prefix
  (`[fleet] …`). The peer never interprets either — data, not code — but then
  *either* instance can rediscover the relation without asking the other.
  Bookkeeping must not be the only memory.
- **The durable direction is pull; push is a latency optimization.** The
  requester is usually the *less* reachable party (a laptop, an inbound-only
  tunnel), so a design where the peer must reach back is fragile in exactly the
  case that matters. Keep the truth on the worker, reconcile from the requester,
  and let the bus push (the steer lane) only shorten the path when both ends
  happen to be up.

### 8.3 The abstraction that is genuinely missing

Not a messaging system — the bus already does live delivery, and re-inventing it
would duplicate NATS badly. What is missing is that the **notice idiom is
already three variants of one pattern**, and the fleet work would add a fourth:

| | Durable record | Live lane | Ground truth when both missed |
|---|---|---|---|
| Subagent settlement | `agentnotice`, written record-first | steer packet (`kind: subagent-settled`) | the child transcript + `agentjob` reconcile |
| Process exit | none — pointer only | steer packet (`kind: process-exited`, "pointer, not payload") | the `processes` registry |
| Fleet settlement (new) | `fleetjob` pointer | steer packet on the origin conversation | the peer's transcript + reconcile |

So the abstraction worth extracting is one durable, **addressed** message with
the delivery lanes already proved:
`{to, from, kind, summary, ref, createdAt, deliveredAt, deliveredVia, readAt}`,
where `to` is a *principal* (locally `session:<id>`; instance-qualified only for
transport), `ref` is a pointer to the payload (`agentjob`/`process`/`fleetjob`
id) and never the payload itself — the pointer-not-payload rule all three
existing variants already follow for good reason (a notice must not outgrow the
bus, and the detail must stay readable after the fact).

Why an *address* earns its keep: with one, the reply path becomes **data**.
`replyTo` in a request is then all a peer needs for reverse delegation, and
vm1 → vm2 → vm3 is routing instead of a new protocol. Without one, "who to reply
to" stays the hardcoded parent relation, and neither reverse delegation nor
multi-hop can be expressed at all. That is the whole argument for the
abstraction — not tidiness.

What must **not** be unified: the tools. `agent_notices`, `fleet_inbox` and
`processes_list` stay separate surfaces, because they differ in exactly the ways
§8.0 established (address space, authority, failure vocabulary). Unify the
*contract* — one record shape, one lane discipline, one delivery semantics —
keep the *surfaces* honest.

**Sequencing (and a warning against building it early).** Do not build a general
mailbox speculatively. Write the contract down, make `fleetjob` its first
cross-instance specialization (same record-first rule, same lanes,
`deliveredAt`/`deliveredVia` semantics identical to `agentnotice`), and
generalize only when a consumer needs *addressing* rather than a parent link.
Reverse delegation and teammate mailboxes are that consumer; nothing else is.

## 9. The composition: a resident agent

Put the pieces together and the thing the question is really about falls out of
existing mechanisms plus two small additions:

| Want | Mechanism | Status |
|---|---|---|
| Survives the TUI exiting | manual mode (no `NIF_AUTOSTART`), `systemd --user` / `niffler-remote` (§4.1–4.2) | design; needs `niffler-remote` |
| Distinguishable in a fleet | `NIF_NAME` + persisted instance id in `catalog` (§3) | small core change |
| Has an identity | persona resolved into the frozen prompt at birth (§6) | new, small |
| Wakes on its own | heartbeat component + `notice.kind: "heartbeat"` (§7) | new, small |
| Delegates locally / to other machines | `agent_*` (shipped) / `fleet_*` (§8) | local shipped; fleet new |
| Observed and steered from anywhere | the fleet client: `/niffler`, per-instance claims, background approvals (§5) | new, medium |

Worked example — "vm1 hosts the reviewer":

1. `vm1` runs the harness in manual mode under `systemd --user`, with
   `NIF_NAME=vm1`, its own clone, store and `.env`.
2. A persona document `reviewer` (body + `toolProfile: review` + budgets +
   `approvals: ask`) and a heartbeat record (`session: vm1-review`,
   `intervalSec: 86400`, prompt "check the open PRs").
3. The human's laptop runs `niffler-tui`; `/niffler` lists `* local` and
   `vm1 (idle, heartbeat in 3h, last 21:04 ok)`; `Ctrl+N` switches, and switching
   back lands on the conversation the human last used there.
4. The heartbeat fires while nobody is watching: the turn runs, its transcript is
   durable, and its summary lands in `lastResult`. If it wants `git push`, the
   gate denies (no human reachable) and the human later sees
   `vm1: approval pending`, answerable from the modal (§5.5).
5. From a local conversation, `fleet_run {peer: "vm1", persona: "reviewer",
   task: "…"}` starts a *conversation on vm1*; its settlement wakes the local
   parent — so a laptop conversation can drive work on three machines without
   holding any of it open.

What the human must always be able to see, or none of it is trustworthy: which
instance is active and which are live, whether a heartbeat exists and when it
next runs, which approvals are pending and on which instance, and which revisions
the peers are on. "Idle" and "unreachable" must never look alike.

Ops notes: heartbeats are turns (keep them read-mostly; the budgets exist for a
reason), memory is per instance (`make ram` already groups by stack), and the
store is the instance's whole memory — a resident instance is a thing to back up,
not a thing to reprovision casually.

### 9.1 "Spawn three tasks on the server, come back tomorrow"

This is the case that decides whether the design is honest, so it is worth
walking end to end. What actually runs the work is the **peer's** instance: its
runners, its store, its provider key. Your laptop's connection is only how you
asked. Three consequences follow immediately, and only the first is pleasant:

1. **Your laptop may be switched off.** The tasks do not live in your client.
   So the right ergonomics for background fleet work is exactly "spawn, then
   close the laptop" — not "keep the TUI open overnight". Note the corollary:
   *your local conversation is also asleep*, so nothing local spends tokens
   while the peer works.
2. **The peer's harness must be up**, which is the manual-mode rule from §4.1
   doing real work: an `NIF_AUTOSTART=1` harness would exit ten seconds after
   your client detached — mid-job — and every one of those three tasks would be
   `interrupted` by morning. The `systemd --user` unit is not tidiness here; it
   is the feature.
3. **Results are durable before they are delivered.** Settlement is
   record-first: the job record is written before any delivery is attempted,
   delivered by the steer lane when the parent is mid-turn and otherwise left
   pending for the parent's next turn
   (`components/agent/main.nim:60-72,129-151` — the same machinery `fleetjob`
   reuses). So reconnecting is not a retrieval step: the results were never
   lost, only unread.

**Reconnecting, concretely.** Three surfaces, in the order a human reaches for
them:

- **The digest (missing from the plan until now, and the primary one).** A
  `fleet_inbox {since?}` tool plus `/niffler inbox` in the client: every job
  since you last looked, with `status`, `summary`, the remote session id, tokens
  spent, and whether anything is *waiting on you*. "I was away ten hours" wants
  one screen, not three transcripts — and the notices that arrived while you
  were gone may already be folded or stale, so the digest must be
  **authoritative and derived from the durable records + a read-only reconcile**,
  not from the notice stream.
- **The notices** (ambient). When you return and send your parent conversation
  anything, its next turn drains the pending settlements, so your "morning
  message" naturally contains "3 jobs settled". No action required; the wake
  lane may even have woken the parent on its own, bounded by `NIF_AGENT_WAKES`.
- **The transcripts** (depth). Each job's summary names its remote session id —
  and that id is a real conversation **in the peer's store**, readable over the
  bus with the same `store.list`/`get` calls the client already makes for
  `/info`, the session browser and history replay. So `/info <remoteSession>`
  against vm1 — or just opening it in `/niffler`'s browser — shows everything,
  including which tools ran and where the tokens went. There is no sync, no
  export and no copy: you read the result where it lives. (The same trick is how
  the morning digest can be cheap: summaries from the records, detail on demand.)

**Reconcile, never lie.** On reconnect the component re-reads its non-terminal
`fleetjob` records and asks each peer (its `catalog`, then `session_info` on the
remote session) what is actually true — the lazy-restart-recovery rule
`agentjob` already follows (`components/agent/main.nim:25-27,1056-1063`,
`reconcileAll` at boot plus on every status read):

| Observed | Reported |
|---|---|
| remote turn still live | `running` (with its event stream re-attached) |
| remote session has a completed assistant message, our tap was missed | `done`, synthesized from the peer's transcript |
| remote harness restarted with no live turn and no completion | `interrupted` — truthful, not retried automatically |
| peer did not answer | `unreachable` — never rendered as `interrupted` (§8.0) |

**The one that bites: approvals while you were away.** A job that hits the
human gate does **not** run, and with nobody attached to that bus the gate
**denies** (fail closed — this is the harness's existing rule, and it is the
right one). So "spawn tasks and come back tomorrow" only works for work that
either never needs the gate or was *granted the gate before you left*. That
makes a per-job `approvals: "ask" | "auto"` flag on `fleet_run` — recorded in
the `fleetjob` and labelled in the digest — a **requirement of this scenario**,
not a nicety: it is the difference between "three tasks finished while I slept"
and "three tasks sat at a prompt until they were denied". Since the conversation
workspace and gate mode freeze at birth anyway, this costs nothing structurally;
it just has to be an explicit, visible decision at spawn time.

The other morning surprises worth designing out, all small:

- **Turn limits.** A long autonomous job can end as `budget-exhausted` or at
  its round cap (§8.1's `maxRounds`/`maxCalls`/`maxTokens`, frozen at value
  selection). The digest must show a partial result as *partial*, not as failure.
- **Cost.** Overnight spend happens on the peer's key and the peer's bill. The
  digest should carry per-job tokens (the data exists: `session_info` reports
  `completionTotal`), and a `maxTokens` cap per job is the enforcement.
- **Local ports.** Overnight, another process may take your local tunnel port;
  the identity check (§3) turns that into a refusal rather than a conversation
  with the wrong machine, and a dead tunnel shows as `vm1: tunnel down` — never
  as an empty job list.
- **Not three wake turns at breakfast.** The wake budget already bounds this
  (default 3, reset by your next real message); the digest is what you actually
  want to read first, so the client should present it before the parent's
  auto-folded notices.

## 10. Implementation sketch (so this is actionable)

**M0 — profile + `/niffler` + re-exec switch (plugin + wrapper).**
`/niffler` writes a handoff file naming the target instance and exits with a new
code (86, next to `/restart`'s 85; `tui/handoff.go` already carries uiID +
session across the re-exec, and `scripts/niffler-tui.in` already loops on 85).
The wrapper reads the target, brings its tunnel up, exports that instance's
`NIF_NATS_URL` and re-execs the client. Cost per switch: a process restart and
a transcript replay — exactly `/restart`, which is in daily use. This proves
the UX, the profile format, the identity check and the lifecycle helper before
any SDK work.

**M1 — one process, many buses (SDK + client).** Blocking detail verified
today: the Go SDK dials the *environment* (`sdk/go/component.go` `dial()` and
`reattachCandidates()` read `NIF_NATS_URL`/`NIF_ROOT` only), and `Connect` has
no bus parameter, so two components in one process cannot target two buses.
The change is small and additive: an optional per-component bus (set before
`Connect`) that `dial()`, `reattachCandidates()` and the reconnect watch honour,
defaulting to today's env-driven behaviour (the TypeScript SDK mirrors it for
the web UI). Then the TUI keeps one *active* connection plus N idle ones for
status/approvals, and switching is a state change, not a restart. Testable
without any remote host by pointing two components at two local buses.

**M2 — identity + lifecycle (core + scripts).** `NIF_NAME` (default hostname),
persisted `var/instance-id`, both in `catalog {op:list}` and `/status`;
`scripts/niffler-remote`; MANUAL entries for manual mode, keepalive and
tunnel-only keys. Small, independent of the client, and independently useful
(two local clones on one workstation already benefit from a name in `/status`).

**M3 — provisioning.** `niffler-init` (clone → `make setup && make` →
`.env` → name/id → `systemd --user` unit or `setsid` start → print
bus+name+id), or a compose/Docker image for the "no toolchain on the VM" case.
REMOTE.md §5 already flagged this as the prerequisite nobody can skip; it is
also the piece most likely to be solved by *someone else's* infrastructure
(Chetter runners, a cloud-init script), so keep it a script, not an
architecture.

And the agent-side slices (§6–§8), independent of the above except where noted:

**A0 — persona (`store kind "persona"` + a birth argument).** Add `persona` to
the `session` call, carry it into `askSystemPrompt`'s payload
(`core/conversation.nim:77-83`), teach `components/systemprompt` to compose a
`<persona>` block, and stamp `persona: {name, digest}` in the header. Small, and
testable at the bus level: a persona's text must appear in the frozen prompt of a
conversation born after it, and never in one born before it.

**A1 — heartbeat (new component + an admission lane).** The component holds
`heartbeat` records and ticks on the idle seam; core's wake-admission branch
gains the `heartbeat` marker kind with its own budget. The interesting test is
the negative one: a due heartbeat during a live human turn is skipped, and a
heartbeat past its daily budget is refused by both the component and the runner.

**A2 — cross-instance delegation (the `fleet` component).** Own connections per
peer, `fleet_*` tools (`onDemand`, so they cost nothing until discovered),
`fleetjob` records, a cross-machine settlement wake, and the origin marker that
hides `fleet_*` from delegated children. Depends on M0 (profiles) and M2
(identity) to be worth shipping, and on nothing else.

**A3 — resident deployment (scripts + docs).** A `systemd --user` unit,
`niffler-remote`, and the manual-mode / keepalive / tunnel-key documentation that
makes "the instance survives my laptop" a supported statement rather than
folklore.

**M4 — the `fleet` component (aggregation + delegation).** One component does
both jobs, because both need the same thing it holds: peer connections. It owns
the instance list (mirrored into a store kind so other local clients share it),
owns the tunnels as supervised children, aggregates `ev.session.>` across peers
into one stream for the client, and exposes `fleet_*` to the *agent* (§8). The
leaf-node topology (T3) and, if anyone ever wants it, a shared TiDB scope belong
here too — that is the REMOTE.md §6.2 half. Nothing in M0–M3 depends on it, and
it should not be allowed to delay them.

**A2 collapses into M4.** §8's cross-instance delegation is not a second
component: it is this one's second job, sharing the peer registry, the tunnels
and the identity checks with the read-only aggregation. Build M4 when the
`/niffler` client and the CLI-level remote turns have proven the ergonomics;
until then `cli --bus` is the honest way to drive a peer.

## 11. What not to do

- **Do not merge two cores onto one bus** without per-instance subject
  prefixes; the queue-group and flat-tool-name assumptions make it silently
  wrong (§2 T3). One connection per instance is the honest model.
- **Do not put the fleet registry only in the harness's store.** The list has
  to exist before any connection; a client-side file is the source of truth,
  and the store copy (M4) is a mirror for sharing.
- **Do not solve client auth with TLS/tokens.** The Nim client cannot do
  either; the leverage is in `sshd` (T1) or the overlay (T2).
- **Do not let a switch silently adopt a bus that does not match the profile's
  identity** (§3) — the home-bus rule extended, not relaxed.
- **Do not make remote instances autostart-mode by accident** when a client
  switches or exits (§4.1).
- **Do not send the local working directory to a remote instance** (§5.3.6).
- **Do not give the peer an outbox.** The spawned conversation is a plain root
  conversation there; the pointer belongs on the requester, the payload on the
  worker, and the durable direction is always pull (§8.2).
- **Do not build a general mailbox before a consumer needs addressing.** Write
  the contract, ship `fleetjob` as its first specialization, generalize when
  reverse delegation or teammates arrive (§8.3).
- **Do not let a persona edit reach a live conversation.** Personas resolve at
  birth; a document edit that silently changed a running agent's prompt would
  break the request prefix and the agent's own history at once (§6).
- **Do not run heartbeats on the wake lane, and do not let one queue.** A
  heartbeat has nothing pending (the wake admission would refuse it) and a
  scheduled turn must never queue behind a human's live turn (§7).
- **Do not relay a peer's approval into a local conversation.** The human who
  owns that machine answers it, on that machine's bus (§8).

## 12. Security posture (short, because it is the part people get wrong)

The bus is the control plane and it is unauthenticated inside its boundary, so
**transport security *is* authorization**: whoever can reach the bus can call
`bash` on that machine (approvals are the only gate) and read every
conversation and provider credential in that store. Therefore:

- One SSH key **per client machine**, tunnel-key confined with
  `from=` + `restrict,port-forwarding,permitopen="127.0.0.1:4222"`, and a
  separate lifecycle key confined with `command="niffler-remote"`.
- `NIF_AUTO_APPROVE=1` is *never* set on a shared or remote instance: it
  disables the only human gate, and the fleet client is precisely the human.
- Adding a client machine to a fleet is granting it shell access to those VMs
  (via the agent). Document it in those words.
- Prefer T1/T2 (an authenticated boundary outside the bus) to T4; if T4 is ever
  wanted, bind to the overlay interface only.
- The fleet client's own profile file holds SSH targets and NATS credentials →
  it is a secret-bearing file (0600), and must never be written by the agent or
  readable over the bus (which means: not in the store, until a scoped/shared
  store design exists).
- A **resident instance is an always-on shell with credentials**: a heartbeat
  plus `auto` approvals means unattended `bash` on a machine that holds your
  provider keys and your repos. If that is not the intent, the resident agent
  works with read-effect tools and the gate stays `ask` — and either way the
  fleet client says which mode an instance is in (§9).
- A peer's delegation authority is *its* human's to grant: the local caller
  cannot widen a remote child's tools, budgets or gate mode (§8).

## 13. Open questions

1. **Rotation semantics for "local"** — is the local harness an implicit first
   entry (my suggestion) or one entry among equals that can be removed?
2. **`Ctrl+N` availability** — used keys today are `ctrl+c/e/j/o/r/s/t/x`,
   `ctrl+↑/↓`, `alt+enter`, `shift+tab`, `tab`, `esc`, `pgup/pgdn`; `ctrl+n`
   and `ctrl+p` are free. Confirm against the terminal matrix (some terminals
   eat `ctrl+n`) before committing.
3. **Notifications** — should a background instance's approval (or a finished
   turn) raise a terminal bell/title marker, like the web UI's per-state
   emoji? Cheap, high value, needs a taste decision.
4. **Multi-instance conversations** — is there any value in a "conversation
   pinned to an instance" visible from another instance (a fleet-level
   *status* without fleet-level merge)? REMOTE.md §6.2's `fleet` scope is the
   place; defer.
5. **Session migration** between instances (export/import, already on PLAN) —
   orthogonal, but a fleet client makes it obvious.
6. **Web UI parity** — the profile file and the per-component bus are shared
   with `sdk/ts`, so the unmaintained `niffler-ui` could read the same
   `instances.json`; decide whether to keep it in scope at all.
7. **Heartbeat schedule shape** — interval only, or cron-ish expressions? The
   schedule is evaluated on the instance that owns it, so there is no clock-skew
   question; the open one is how much surface a human needs for "every morning"
   versus "every 15 minutes while I am away".
8. **Heartbeat transcript placement** — the same conversation (recommended: one
   durable history, machinery-marked) or a separate audit conversation. The
   second is tidier and worse for the model, which loses the continuity the
   heartbeat exists to provide.
9. **Persona editing across the fleet** — should the fleet client edit a peer's
   persona documents directly (a `store` call on the peer's bus), or is `write`
   through a delegated conversation the honest path? Store-write is direct and
   auditable; the delegated path is the dogfood way.
10. **Reverse delegation** — a peer launching work on us. What is the trust
    primitive: a peer list on both sides, or explicit per-job acceptance? Out of
    scope for the first cut, but the answer decides whether a fleet is symmetric.
11. **One `fleet` component or one per peer?** One keeps the registry in one
    place; a component per peer would isolate a wedged peer at the cost of a
    shared registry. The `replicas: N` rule (stateless, externally coordinated)
    points at "one component, N connections" first.
12. **The drift guard's teeth** — should the delegation contract test also
    assert that a delegate-starting tool's description states its address space
    ("a subagent here" vs "a machine")? It is prose, but the model's choice
    between `agent_*` and `fleet_*` is made from that prose alone, and the
    description is the only place the discriminator reaches it.
13. **Does `approvals: auto` on a delegated job need a second human?** The gate
    exists so a human decides; `auto` on a *remote* job means the *caller* has
    decided on behalf of a machine they are not sitting at, possibly not theirs.
    For a single-operator fleet that is obviously fine; for a shared one it wants
    the peer's owner to be able to require `ask` regardless of what the caller
    asked for (§8's "authority stays with the peer's human").
14. **Does the notice contract need pruning?** Addressed notices accumulate
    (`*:<seq>` ids, marked delivered but never removed) exactly as `agentnotice`
    does today. A retention rule belongs in the contract, not in each consumer.
15. **Leaf-node spike** — verify whether subject-rewriting import/export rules
   could give per-instance namespaces on a hub without component changes (T3).
   If yes, M4's aggregation gets much cheaper; if no, one connection per
   instance stays the answer forever.
