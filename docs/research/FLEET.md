# Remote instances and the `/niffler` switcher

> Proposal (nothing implemented). How to run one or several full Nifflers on
> remote machines and drive them from another Niffler, or from a bare
> `niffler-tui` with no local harness at all. Covers the transport question
> (SSH tunnel vs. overlay vs. leaf nodes vs. open port), instance identity,
> remote lifecycle, and the client-side UX: a `/niffler` command that works
> like `/fav` — an ordered list you switch between with a key combo.
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
  that VM, gated only by approvals (§8).

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
client-side file (optionally mirrored into a local harness's store later, §7).

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

## 6. Implementation sketch (so this is actionable)

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

**M4 — aggregation (`fleet` component + leaf topology).** A local `fleet`
component that owns the instance list (mirrored into a store kind so the web UI
and other local clients share it), owns the tunnels as supervised children,
aggregates `ev.session.>` across instances into one stream, and exposes
`fleet_list` / `fleet_status` / `fleet_delegate` to the *agent* — the agent-side
half of REMOTE.md §6.2, which is where leaf nodes and (if anyone wants it) a
shared TiDB scope belong. Nothing in M0–M3 depends on it, and it should not be
allowed to delay them.

## 7. What not to do

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

## 8. Security posture (short, because it is the part people get wrong)

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

## 9. Open questions

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
7. **Leaf-node spike** — verify whether subject-rewriting import/export rules
   could give per-instance namespaces on a hub without component changes (T3).
   If yes, M4's aggregation gets much cheaper; if no, one connection per
   instance stays the answer forever.
