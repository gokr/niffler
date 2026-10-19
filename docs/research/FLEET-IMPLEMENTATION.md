# Fleet implementation — delivery plan

> VM backend update: current Fleet/TUI use native Lima, not Multipass. Legacy
> Multipass profiles explicitly refuse and require newly provisioned/verified
> Lima receipts. See [Lima VM policy](../MANUAL.md#lima-vm-policy). Multipass smoke
> results below are historical and do not certify Lima; Lima live smoke remains
> pending separate human authorization.

Status: provisioning/lifecycle merged into `main`; task delegation is not yet
implemented. The harness fleet worktrees have been removed after merge.
TUI code and installed/released client versions must be checked in their own repo.

Identity, persistent service lifecycle, birth-time agent definitions and opt-in
heartbeat are implemented. Provisioning is the optional Nim `fleet` component;
Python provisioner/tests were replaced with native code/contracts. The matching
TUI has receipt import, switching and native Multipass relay through remote
`cli relay`. No Python runtime is needed for Fleet. Cross-instance delegation
and background approvals remain planned. Each step is independently tested.

## Delivery checklist

| Slice | Source status / remaining acceptance |
|---|---|
| 1–2 identity and persistent service | Implemented; service contracts use fake systemd; recorded real Multipass smoke passed |
| 3–4 SSH/Multipass install/adopt/update | Implemented in Nim; real SSH and published-revision install/update smoke still pending |
| 5 client switching | Matching TUI source implemented; verify/release separately; background approvals remain open |
| 6 cross-instance delegation | Not implemented |
| 7 reconnect inbox/artifacts | Local durable human completion feed implemented; remote jobs and artifact transfer remain open |

The recorded Multipass smoke used Ubuntu 24.04, 2 CPUs/4G/20G and a source-only
snapshot build. Identity survived service restart; listeners stayed loopback;
linger stayed off; no credentials or TUI were copied. That is not acceptance
of published-revision download or ordinary SSH. `fleet_update` and ref-to-SHA
resolution have fake-transport contracts; rerunning install still only adopts.
See [the active plan](../PLAN.md) for the next bounded acceptance work.

## 1. Instance identity

Persist a random instanceId in `var/instance-id`; expose it with NIF_NAME
(hostname default), root and gitHash in catalog replies. Keep existing fields
and frozen conversation prefixes unchanged. Test distinct roots, restart
stability, label changes and malformed identity refusal. Pin identity in client
profiles before enabling any remote writes. Identity is not authentication.

## 2. Persistent server lifecycle

Add a server bootstrap mode that skips the TUI and optional extras. Install a
user systemd unit with explicit runtime root, loopback NATS and no
NIF_AUTOSTART. Check linger separately: explain when logout/reboot persistence
cannot be guaranteed. Provide start/status/logs/stop through a lifecycle helper.
Never adopt an unrelated PID or overwrite an existing installation implicitly.

## 3. SSH installation and adoption

Given user@host, probe through ordinary SSH configuration (keys, agent,
ProxyJump, known_hosts). Expose target, path, pinned revision and privilege needs in `fleet_install`;
require the standard harness approval gate before installation. Reuse bootstrap/Makefile, stream logs,
install the service, probe identity and save a connection profile only after
verification. Reruns adopt existing instances; updating is a separate decision.
No automatic .env copying or SSH-agent forwarding. Provider setup is explicit.

## 4. Multipass provisioning

Optional provisioner: create a VM with approved CPU/RAM/disk settings, bootstrap
through multipass exec, then hand off to the same instance connection contract.
No host mounts or credential inheritance by default. Track ownership: adopting
an existing VM never grants permission to destroy it. Stop Niffler, stop VM and
delete VM are separate actions; deletion warns about lost history/artifacts.
Test with fake provisioner commands before an approved real-VM smoke test.

## 5. Client connection registry and /niffler

Client-local profiles work without a local harness. Implement tunnel ownership,
identity verification, reconnect without fallback to another instance, and
/niffler switching/rotation. Per-instance conversation/workspace/draft state;
remote paths are never interpreted locally. A disconnect never stops the remote
service. Background approvals identify their instance and route on its bus.

## 6. Cross-instance delegation

A fleet component submits ordinary root conversations on each peer; those roots
may spawn local subagents normally. Remote subagent notices belong to their
remote parent. The requester persists job pointers and reconciles remote
transcripts; unreachable is not interrupted. Use explicit scopes, per-task
budgets and approved authority, never a second unrestricted delegation path.

## 7. Reconnect inbox and artifacts

Show running/completed/partial/blocked jobs after reconnect. Persist receipts
before notification, deduplicate by job/activation, separate model delivery
from human read state. Results remain on the worker; retrieve detail on demand.
Prefer patches/commits/artifact transfer to writable VM host mounts.

## Gates

Narrow contract tests first, then make build && make test-server. For each new
runtime seam, test failure/timeout/restart/identity mismatch and live isolation.
Run real SSH/VM provisioning only against a human-approved target. No public
NATS listener, global teardown, automatic credential copying or auto-approval.
