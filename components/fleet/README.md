# Fleet

Opt-in provisioning component (`var/bin/fleet`); enable with `core.spawn`, not
manifest autostart. All tools are on-demand. No interpreter dependency; SSH and
remote Bash are required for SSH targets, and Multipass for VM targets.

`fleet_install` requires `transport` (`ssh` or `multipass`), `target`, `root`,
full lowercase 40-character `revision`, and local receipt `profile`. Optional
VM resources: `cpus` (2), `memory` (4G), `disk` (20G). `fleet_probe`,
`fleet_status`, `fleet_logs`, `fleet_start`, `fleet_stop`, `fleet_vm_stop` take
`profile`. Mutations use the enforced normal harness approval gate, never a
terminal prompt. Profile paths are workspace-resolved; approved absolute paths
are allowed. Installation leases claim `profile`; lifecycle actions declare no
receipt writes. Separate aliases for one remote resource are not distributed locking.

SSH uses fixed argv, BatchMode=yes, ForwardAgent=no, ConnectTimeout=15 and
ordinary SSH config/known_hosts verification. Multipass uses exec, never mounts
or key extraction. New installations verify a pinned SHA before bootstrap;
complete existing installations are adopted without updates, rebuilds or
provider setup. Incomplete and symlinked roots refuse. Linger remains explicit.
No credentials are sent.

Receipts are atomic mode-0600 JSON compatible with the TUI version-1 schema:
`version,transport,target,root,expect:{instanceId,name,root,gitHash}` and optional
`createdVm:true` provenance. Malformed/symlink receipts and identity/root drift
refuse. Durable identity is checked before writes; a reachable catalog is also
checked, and a verified live service is required before saving. A stopped pinned
VM must first be started explicitly by its administrator: Fleet cannot verify
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
