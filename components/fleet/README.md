# Fleet

Opt-in provisioning component (`var/bin/fleet`); enable with `core.spawn`, not
manifest autostart. All tools are on-demand. No interpreter dependency; SSH and
remote Bash are required for SSH targets, Lima for VMs, Incus for containers.

`fleet_install` requires `transport` (`ssh`, `lima` or `incus`), `target`, `root`,
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
ordinary SSH config/known_hosts verification. Lima uses native limactl shell, never mounts
or key extraction. New installations verify a pinned SHA before bootstrap;
complete existing installations are adopted without updates, rebuilds or
provider setup. `fleet_update` moves an adopted installation forward: it verifies
identity over the live catalog first, refuses a symlinked, unrelated or
locally-modified checkout, fetches and checks out the resolved commit, runs
`make build` in place (never `bootstrap.sh`), reinstalls and restarts the service,
and advances the receipt's pinned `gitHash` only after the updated instance
verifies. A failed update leaves the receipt at the last verified revision. Incomplete and symlinked roots refuse. Linger remains explicit for SSH; Lima and Incus install enable guest linger for ubuntu.
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

Optional `host` is an SSH alias/user@host allowed only for Incus/Lima.
Absent means local (old receipts unchanged); present routes EVERY guest command
through fixed SSH options with every remote argv word quoted. Route drift
refuses reuse. Missing pinned guests refuse recreation; updates refuse dirty
checkouts and stop/start the scoped service before verifying the new revision.

See [manual](../../docs/MANUAL.md#incus-and-remote-guest-management) and bundled
`niffler-harness` skill for administrator setup (`incus admin init`, trusted
root-equivalent incus-admin membership), Lima installation, SSH known_hosts
and passwordless preflight, approval and bootstrap/update/import examples.

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
