# Fleet implementation — delivery plan

Worktrees: `niffler-fleet` and `niffler-tui-fleet`, branch `feat/fleet`.
Identity, persistent service lifecycle, birth-time agent definitions and opt-in
heartbeat are implemented. Provisioning is the optional Nim `fleet` component;
Python provisioner/tests were replaced with native code/contracts. The matching
TUI has receipt import, switching and native Multipass relay through remote
`cli relay`. No Python runtime is needed for Fleet. Cross-instance delegation
and background approvals remain planned. Each step is independently tested.

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
