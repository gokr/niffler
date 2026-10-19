# Fleet

Opt-in provisioning component (`var/bin/fleet`); enable with `core.spawn`, not
manifest autostart. All tools are on-demand. No interpreter dependency; SSH and
remote Bash are required for SSH targets, Multipass for VMs, Incus for containers.

`fleet_install` requires `transport` (`ssh`, `multipass` or `incus`), `target`, `root`,
`revision` (full lowercase 40-character SHA, or a ref resolved to one by
`git ls-remote` before any remote write and recorded as the pinned revision), and
local receipt `profile`. Optional VM resources: `cpus` (2), `memory` (4G),
`disk` (20G). `fleet_probe`, `fleet_status`, `fleet_logs`, `fleet_start`,
`fleet_stop`, `fleet_vm_stop` take `profile`; `fleet_update` takes `profile` and
`revision`. Mutations use the enforced normal harness approval gate, never a
terminal prompt. Profile paths are workspace-resolved; approved absolute paths
are allowed. Installation leases claim `profile`; lifecycle actions declare no
receipt writes. Separate aliases for one remote resource are not distributed locking.

SSH uses fixed argv, BatchMode=yes, ForwardAgent=no, ConnectTimeout=15 and
ordinary SSH config/known_hosts verification. Multipass uses exec, never mounts
or key extraction. New installations verify a pinned SHA before bootstrap;
complete existing installations are adopted without updates, rebuilds or
provider setup. `fleet_update` moves an adopted installation forward: it verifies
identity over the live catalog first, refuses a symlinked, unrelated or
locally-modified checkout, fetches and checks out the resolved commit, runs
`make build` in place (never `bootstrap.sh`), reinstalls and restarts the service,
and advances the receipt's pinned `gitHash` only after the updated instance
verifies. A failed update leaves the receipt at the last verified revision. Incomplete and symlinked roots refuse. Linger remains explicit for SSH/Multipass; Incus install explicitly enables guest linger for ubuntu.
No credentials are sent.

Receipts are atomic mode-0600 JSON compatible with the TUI version-1 schema:
`version,transport,target,root,expect:{instanceId,name,root,gitHash}` and optional
`createdVm:true` provenance and `host` for SSH-hosted guest management. Malformed/symlink receipts and identity/root drift
refuse. Durable identity is checked before writes; a reachable catalog is also
checked, and a verified live service is required before saving. A stopped pinned
guest being reinstalled must first be started explicitly by its administrator: Fleet cannot verify
identity on a stopped VM. Service stop and VM stop are separate; neither deletes
anything. Provenance grants no deletion authority.

Commands have bounded timeouts and process-group termination. Stderr is kept
private and omitted from errors to avoid leaking credentials; catalog stdout
is separate. Mode-0600 stdout/stderr logs remain under `var/fleet/transport` for
local debugging; successful results include `privateLogs` stderr paths and
failures name the relevant stderr path. Operators should prune these logs when
no longer needed. Machine stdout is accepted intact up to 8 MiB (oversize
refuses), using the small `catalog components` response; user-facing output is
capped at 64 KiB. Logs are the last 100 journal
lines and may contain sensitive application output. Installation uses bounded
read-only retries, never reinstalls on probe failure.

`provision.nim` provides an injectable runner. `tests/t_fleet.nim` covers policy
and real NATS registration/calls with fake transport executables; no real hosts
or VMs are contacted. No global registry or prompt-prefix changes.

## Incus and management hosts

`transport:incus` uses fixed `images:ubuntu/24.04` unprivileged system containers
(not VMs or cloud images), root `/home/ubuntu/niffler`, ordinary user ubuntu,
and explicit guest linger/user-manager startup. Default limits are 2 CPUs, 4GB
RAM, 20GB disk; unsupported quota backends fail without dropping limits.
Expanded configuration/devices reject privileged/nesting/raw configuration,
host mounts and passthrough devices. All regular exec/probe/update/lifecycle and
relay paths use noninteractive exec plus `runuser -u ubuntu` and explicit HOME;
root is used only for initial guest bootstrap. New installs temporarily grant
installer sudo inside the guest, refuse an existing grant, and trap normal EXIT
to remove it. SIGKILL, transport loss or host failure can leave a rule; inspect
`/etc/sudoers.d/niffler-fleet-bootstrap` and remove manually only after confirming
the installer stopped. Adoption skips apt and grants. Never grant host sudo.

Optional `host` is an SSH alias/user@host allowed only for Incus/Multipass.
Absent means local (old receipts unchanged); present routes EVERY guest command
through fixed SSH options with every remote argv word quoted. Route drift
refuses reuse. Missing pinned guests refuse recreation; updates refuse dirty
checkouts and stop/start the scoped service before verifying the new revision.

See [manual](../../docs/MANUAL.md#incus-and-remote-guest-management) and bundled
`niffler-harness` skill for administrator setup (`incus admin init`, trusted
root-equivalent incus-admin membership), Multipass installation, SSH known_hosts
and passwordless preflight, approval and bootstrap/update/import examples.

Incus commands always use `incus --force-local --project default`: the local
daemon on the selected management host and its default project are fixed,
regardless of mutable CLI defaults. NICs must be bridged/p2p or use a verified
managed bridge network; physical/SR-IOV passthrough refuses. Stopped pinned Incus
updates refuse until an administrator starts the container for identity checks;
existing Multipass update behavior (start stopped VM before probing) is unchanged.
