---
name: niffler-harness
description: Operational guide to the running Niffler harness itself — lifecycle and boot profiles, session runners, the store and how to read conversations out of it, self-extension end-to-end, bus debugging (console, cli, observe, logfile), plugins, skills, approvals and recovery. Load when driving, configuring, recovering or debugging the harness rather than doing a task inside it.
---

# Niffler harness — operating the thing itself

Niffler is a self-extending harness: a system core plus one process per
component, speaking JSON envelopes over NATS. This skill covers operating and
debugging that machinery; `niffler-tools` is the which-tool-for-the-job map
and `niffler-fabric` is how to program tools. The repo snapshot is the source
of truth for code; `var/` also holds durable store and benchmark data.
`make clean` removes only `var/bin/`, `var/nimcache/` and `nimcache/`;
never delete `var/` wholesale. Use `make help`, `make help-tests` and
`make help-advanced` for grouped commands; `make stop` is checkout-scoped,
while `make stop-all` (legacy `down`) is global.

## Docs map

Deep reference for everything in this skill — root-relative paths under the
harness root (`NIF_ROOT`; from a session workspace, read them by absolute
path). Read the relevant file fully and follow its cross-references before
advising on or changing Niffler itself:

- `docs/MANUAL.md` — operating the harness: boot, configuration, env vars,
  testing
- `docs/WIRE.md` — the one bus protocol: JSON envelopes, subjects, component
  and subagent lifecycles
- `docs/ARCHITECTURE.md` — why core is core: the design test, invariants and
  their rationale
- `docs/research/` — design notes (REBOOT, STORE_V2, COMPACTION, SUBAGENTS,
  …)
- `AGENTS.md` (repo root) — development conventions; `CHANGELOG.md` — recent
  changes

## Lifecycle

- `make run` (or `./var/bin/niffler`) — the tty is an **admin shell**
  (help/status/catalog/tools/sessions), not a chat UI. Chat lives in the web
  UI and the niffler-tui plugin; scripting goes through the `cli` component.
- `--minimal` — boot profile, not a lockdown: only `store`, `bash`, `llm`
  start; persisted spawned components are not restored (their store records
  remain and a normal boot restores them).
- `--recover` (`make recover`) — stop everything, rebuild shipped binaries,
  wipe spawned-component records, restart.
- `make down` — stop stray harnesses/components and nats-server. Run it when
  a fresh store refuses to start (a detached core holds
  `var/store.db.lock`) or before a cold start.
- Autostart: a UI's first act is the SDK's `ensureHarness` — probe env →
  `var/nats-url` → `127.0.0.1:4222`, else spawn core with `NIF_AUTOSTART=1`.
  An autostarted core exits when the last interactive client departs
  (idle 10 s) or none arrives (boot grace 60 s). Manually started cores
  never self-terminate.
- One conversation = one process: an ephemeral session runner
  (`var/bin/session <id>`, restart `never`) that resumes from the store —
  killing it loses only the in-flight turn. Missing binary → `make build`.
- When a supervised child dies, the supervisor shows the tail of
  `var/logs/<name>.log` — look there first.

## The store

Document store over the bus: `put/get/list/del` with rev-based optimistic
concurrency. Engines register as the same component `store` with identical
tools (boot-time `NIF_STORE_BACKEND=sqlite|tidb`); consumers never
learn which is live. File engines are single-writer — never run two stores
against one file. Kinds include `conversation`, `message`, plugin install
records, the provider registry — and your own durable state.

Reading a conversation while a harness is on the bus:

```bash
./var/bin/cli call list '{"kind":"conversation"}'
./var/bin/cli call list '{"kind":"message","idPrefix":"<convId>:","limit":1000}'
./var/bin/cli call get '{"kind":"conversation","id":"<convId>"}'
```

Mind which store answers — the bus may host another harness's store
(`readlink /proc/$(pgrep -f bin/store | head -1)/cwd` shows which db it
owns). Offline, values are plain JSON inside `var/store.db` (SQLite).

## Self-extension end-to-end

write source → `builder.build` (Nim/Go/TS; a Go component gets its
`go.mod` `replace` wired automatically) → `core.spawn` (approval-gated) →
`discover` → `invoke`.

- `replicas: N` (1–16) only for stateless or externally coordinated
  components (existing NATS queue group); never for single-writer state
  (`store`, `edit` undo).
- `core.kill` stops a group temporarily; `core.remove` also deletes the
  persisted record (it will not come back on boot).
- Tool names are globally unique — core rejects duplicate registration.
- `manifest.yaml` is the bootstrap set; `--minimal` filters it to
  store/bash/llm.

The `x-harness.*` schema extensions core honors:

| Key | Effect |
|---|---|
| `hidden` | tool invisible to the LLM (e.g. `chat`) |
| `onDemand` | kept out of the frozen direct set; reachable via discover+invoke |
| `approval` | enforced human gate (terminal y/N; UI broadcast; `NIF_AUTO_APPROVE=1` bypasses — headless only) |
| `timeoutMs` | per-tool timeout |
| `effect` | `"read"` (parallel) vs `"write"` (exclusive) in the fabric batch host |
| `sessionId` | runner injects `__session.session` for cancel matching |
| `sessionContext` | injects live `__session` + nested-call lease |
| `noSpawn` | subagents cannot spawn subagents |
| `workspace` | path-shaped args resolve against the conversation workspace |

## Debugging the bus

- `./var/bin/console` — subscribes `>` and renders every envelope readably;
  run it in a second terminal to follow any harness activity live.
- `./var/bin/cli` — scriptable driver: `catalog` / `wait <comp>` /
  `call <tool> '<json>'` / `install <repo>[@<ref>]`, exit 0 on success.
  One-shot turn probe without any UI (needs an API key):
  `cli call session '{"sessionId":"probe-x","content":"Ping"}'`.
- `catalog {op: list}` — catch bad registrations (each `schema.type` must be
  `"object"`); `doctor` — one-shot health probe; `status` — live processes.
- `observe` / `logfile` — bounded live ring + probes; rotating JSONL with
  bounded search (`ev.log.expert` carries the expert peer's judgments). For
  debugging the harness itself, not the task.
- Prompt-cache discipline: the request prefix — frozen system prompt + frozen
  direct tool schemas — must stay byte-stable for the conversation's
  lifetime; history only grows. Never splice a volatile fact (time, a file
  edit, a catalog change) into the head; append it as a new message.
  `ev.session.<id>.status` carries the cumulative split as
  `cache {prompt, read, hitRate}`; the only legitimate full miss is a trim
  (`ev.session.<id>.context` with `reason: "reset:trim"`).

## Plugins and skills

- Plugins: `plugin_search` → `plugin_install` (clone into
  `var/plugins/<pkg>@<ref>`, build from source, spawn service components) →
  `plugin_update` / `plugin_remove`. Records live under store kind `plugin`;
  `"interactive": true` packages are built but not spawned (start them
  manually, e.g. niffler-tui). Clones honor `NIF_GIT_MIRROR`.
- Skills: discovery order conversation workspace `.agents/skills` → user
  `~/.agents/skills` → bundled (first match per name wins). Foreign-agent
  directories are not scanned implicitly. Bundled (`skills/` in the repo) are
  never removable, and when
  no disk tree exists (binary-only sandboxes) the bundled SKILL.md files
  compiled into the binary serve instead. `skill_audit` shows shadowed
  duplicates that `skill_list` hides. Loading a skill appends to the
  conversation history — it never changes the frozen prefix.

## Config and secrets

`.env` (repo root, gitignored) holds local config; existing shell env always
wins, and components load it from cwd then `$NIF_ROOT`. Every harness
variable carries the `NIF_` prefix (`NIF_OPENAI_*`, `NIF_NATS_URL`,
`NIF_STORE_BACKEND`, …) — full table in docs/MANUAL.md. Never commit
`.env`; never put secrets in store documents or task prompts.

## Recovery cheatsheet

| Symptom | Action |
|---|---|
| Boot fails, store refuses to start | `make down` (stale core holds the store.db flock), check `var/logs`, restart |
| Child component keeps dying | read the supervisor's `var/logs/<name>.log` tail; `make build` if the binary is stale |
| Spawned components misbehave | `core.kill <name>` (temporary) or `core.remove` + respawn |
| Broken build state | `make recover` (rebuild + wipe spawn records) |
| Orphaned NATS after killing components | `make down` before a cold start |
| Conversations look lost | they are not — read them from the store (recipe above) |
| A remote instance is unreachable after a reboot | `server.sh persist <root>` there; host boot policy is the usual culprit (see "Keeping a remote instance always running") |
| A client refuses a switch with `EOF` | the target's harness is not running: start it there (`server.sh start <root>`), then check `server.sh persist <root>` |

## Fleet provisioning

Enable the built optional component (not manifest autostart), then request
human approval for provisioning, not merely permission to edit code:

```bash
./var/bin/cli call spawn '{"name":"fleet","binary":"var/bin/fleet","policy":"on-failure"}'
```

Direct SSH example (preflight below):

```json
{"transport":"ssh","target":"ubuntu@worker","root":"/home/ubuntu/niffler","revision":"main","profile":"var/fleet/worker.json"}
```

After install verifies and saves its receipt, explicitly import in the matching
TUI; no automatic registry write or public NATS listener is needed:

```bash
niffler-tui --instance worker --instance-import /absolute/path/to/worker.json
niffler-tui --instance worker
```

### Keeping a remote instance always running

A provisioned instance is not automatically a *resident* one. `scripts/server.sh`
is the single entry point for that (`install|refresh|start|status|logs|stop|linger|persist`),
and it is the only supported way to change the unit. Three independent things
keep an instance reachable, and each fails on its own:

1. **The guest starts on host boot.** An Incus container needs
   `boot.autostart=true` — a container that never starts runs no systemd, so
   nothing inside can save it. `fleet_install` sets it at launch and repairs it
   when adopting an existing container. Lima has no per-VM equivalent: on macOS
   use `limactl autostart` (launchd), on a Linux management host give the VM a
   host-level unit. Never claim this from inside the guest.
2. **Linger is enabled** for the instance user (`loginctl enable-linger`), or a
   user unit is stopped at logout.
3. **The unit is enabled and its restart policy is `always`.** `on-failure`
   leaves an instance dead after a *clean* exit — a stray SIGTERM or an OOM kill
   reports success.

Run the readiness report rather than reasoning about it:

```bash
bash scripts/server.sh persist "$root"   # exit 0 only when all guest-side checks pass
```

It names the fix for each failed check and reports the boot layer as something to
verify on the management host (`boot=container (lxc) - verify on the management
host: incus config get <container> boot.autostart`), never as covered by the guest.

**A changed `server.sh` refuses the old unit.** `install` compares rendered
text and refuses a unit it did not just write — never adopting unknown content is
what stops a foreign service being inherited. After a checkout moves
(`git pull`, `fleet_update`), use `refresh`: it proves the file is ours, stops
the old process, rewrites, re-enables, and does not start. `fleet_update` does
this automatically; do it by hand only on an instance you maintain directly:

```bash
bash scripts/server.sh refresh "$root" && bash scripts/server.sh start "$root"
```

Never hand-edit the unit or `rm` it to force an install: `refresh` exists
precisely so an operator does not have to, and a deleted unit loses the enable
symlink and the readiness trail. Service lifecycle is not VM lifecycle
(`fleet_stop` ≠ `fleet_vm_stop`), and none of it deletes anything.

For an **SSH** target (no guest transport), linger and the user manager are
operator setup, never implicit: enable linger, start `user@$(id -u)` at least
once, then run `install`/`start` and let `persist` confirm. On any target, obtain
human approval before changing service lifecycle — it affects whether work
continues after the operator disconnects.


### Incus and remote guest management

For native unprivileged system containers use `transport:"incus"`, a container
name as `target`, and `root:"/home/ubuntu/niffler"`. Fleet launches the fixed
`images:ubuntu/24.04` system image (not cloud/VM), default 2 CPUs, 4GB memory,
20GB root disk; `cpus`, `memory` and `disk` override these limits. A storage
backend without root-disk quota support fails honestly; Fleet never drops limits.
Incus records `root,size=` even where nothing enforces it, so Fleet verifies the
pool first: `btrfs`/`zfs`/`lvm` enforce it, `dir` only with project quotas
(`prjquota`); a `dir` pool on plain ext4 refuses before launch.
No host mounts, passthrough devices, privileged containers or nesting are allowed;
existing containers are checked through expanded configuration/devices.

Host setup is an explicit administrator action, not performed by Fleet. On a
supported Ubuntu/Debian host install Incus (`sudo apt install incus`), run
`sudo incus admin init` to choose networking/storage, and add the operator with
`sudo usermod -aG incus-admin "$USER"`; log in again and verify `incus list`.
**incus-admin membership is host-root-equivalent**; grant it only to trusted
operators. Do not grant broad host sudo for Fleet. On a Docker host, verify guest
egress first: Docker's `iptables-legacy` `-P FORWARD DROP` shadows Incus's
nftables rules, so add a bridge-scoped exception
(`iptables -C FORWARD -i incusbr0 -j ACCEPT || iptables -I FORWARD 1 -i incusbr0 -j ACCEPT`,
likewise `-o`), applied after any `iptables-persistent` restore. Alternatively install
Lima 2.2.1 or newer from its official distribution, then verify `limactl --version`.
No mounts or SSH key extraction are used.

Both guest transports accept optional `host:"operator@hypervisor"` (or an SSH
alias). Omit `host` for local management. Every list/create/start/stop/exec goes
through this host using fixed SSH options `BatchMode=yes`, `ForwardAgent=no`,
`ConnectTimeout=15` and normal known_hosts checks; every remote argv word is
shell-quoted. Receipts bind this route; changing/adding/removing host refuses.
Preflight manually: establish trusted known_hosts and key/agent authentication,
then run `ssh -T -o BatchMode=yes -o ForwardAgent=no operator@hypervisor 'incus --force-local --project default list'`
(or `'limactl list --json --all-fields'`). The noninteractive remote PATH must include that CLI.
No passwords or credentials are stored or copied. Direct `transport:"ssh"`
uses `target` only (no `host`); provision git, Bash and writable dedicated root,
noninteractive prerequisite sudo or preinstalled build tools, and an available
systemd user manager beforehand. Direct SSH never enables linger implicitly.

Example approved bootstrap (omit host for local Incus; use lima and a VM
name for remote Lima):

```json
{"transport":"incus","target":"worker","host":"operator@hypervisor","root":"/home/ubuntu/niffler","revision":"main","profile":"var/fleet/worker.json"}
```

Incus exec defaults to root, so Fleet bootstraps ubuntu only when necessary and
always runs Niffler/install/build/probe/service commands and native relay as
ordinary **ubuntu**, with explicit HOME. Install explicitly **enables guest
linger for ubuntu** and starts its user manager; it never changes host linger.
A new root needs apt prerequisites and a temporary guest-only sudo rule for the
installer. Fleet refuses an existing rule at
`/etc/sudoers.d/niffler-fleet-bootstrap`, creates it with noclobber, validates it,
and removes it via EXIT trap on success/failure. Forced SIGKILL/host loss can
prevent cleanup (including loss of SSH while the guest installer continues):
inspect the guest with `incus --force-local --project default exec worker -- cat /etc/sudoers.d/niffler-fleet-bootstrap`
and, after confirming no installer is running, remove only that grant with
`incus --force-local --project default exec worker -- rm /etc/sudoers.d/niffler-fleet-bootstrap` before retrying.
Run these on the configured management host, not a different local Incus daemon.
No automatic claim of cleanup is possible then. Adoption of built roots skips apt and grants.
Provider settings remain explicit. No permanent NOPASSWD rule is installed.

Update uses `fleet_update {"profile":"var/fleet/worker.json","revision":"main"}`;
it uses the receipt route, never root/bootstrap sudo, preserves local changes by
refusing dirty checkouts, stops/starts the scoped user service after rebuilding,
and pins only the updated verified identity/revision. Missing pinned guests
refuse recreation; identity drift refuses writes. `fleet_vm_stop` also stops
Incus containers (never deletes); service stop is separate. Relay clients must
use the same ubuntu runuser/HOME route, not root, even for root-readable endpoints.
Tests use fake transports only; real-machine provisioning requires separate consent.

Incus commands always use `incus --force-local --project default`: the local
daemon on the selected management host and its default project are fixed,
regardless of mutable CLI defaults. NICs must be bridged/p2p or use a verified
managed bridge network; physical/SR-IOV passthrough refuses. Stopped pinned Incus
updates refuse until an administrator starts the container for identity checks;
stopped pinned Lima guests also require administrator startup before identity verification.


## Lima VM policy

Use `transport:"lima"`, VM name as `target`, root `/home/ubuntu/niffler`.
Optional SSH `host` routes every command like Incus. Requires Lima >=2.2.1.
Native `limactl create --tty=false --name=NAME -` reads standalone config on stdin;
`limactl start/stop` manage the VM; `limactl shell --workdir=/home/ubuntu NAME ...`
carries scripts and native `cli relay` binary stdio. No Colima, host mounts,
credential copying, agent forwarding, proxy propagation, automatic port forwarding
or host sudo. Lima's own private management key stays on the management host;
`loadDotSSHPubKeys` is off. Explicit defaults: 2 CPUs, 4GiB RAM, 20GiB disk.
Fleet inspects effective configuration via `limactl list --json --all-fields`
before start/adoption/execution; unsafe mounts, hooks, copies, extra devices/networks
and forwarding refuse. Operator defaults/overrides must conform; Fleet never edits them.
Guest ubuntu/home are fixed. Bootstrap enables guest linger/user manager and the
persistent user service. Lima's baseline guest passwordless sudo remains, unlike
host sudo; the temporary Fleet installer grant is removed on normal EXIT. Forced
interruption can require manual guest grant cleanup, as with Incus.

Ubuntu 24.04 server images (amd64/arm64 only) pin `release-20260926` and mandatory
SHA256 digests in provision.nim, cross-checked against Ubuntu SHA256SUMS and
[Lima v2.2.1 image pins](https://github.com/lima-vm/lima/blob/v2.2.1/templates/_images/ubuntu-24.04.yaml).
No mutable fallback: expired URLs fail closed; review URL+digest updates together.
Syntax was checked against installed Lima 2.2.1 help and upstream CLI/config sources.
Multipass is no longer supported: old receipts and TUI registry `multipass` fields
explicitly refuse. Provision a new Lima guest and import its new verified private
receipt; never rename old transport fields or copy var/instance-id. SSH and Incus
remain supported. Stopped pinned guests require administrator startup before
identity verification; missing pinned guests never recreate automatically.
No real Lima VM smoke was authorized/run. Fake tests and configuration validation
do not prove hypervisor, boot, package installation or persistent-service readiness.
