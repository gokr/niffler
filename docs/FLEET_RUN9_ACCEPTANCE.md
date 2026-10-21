# Run9 Fleet live acceptance — 2026-10-21

Result: a local DeepSeek-backed Niffler invoked `fleet_install` to install a
fresh remote Niffler, then invoked `fleet_task_submit`. Two real remote tasks
returned independently checked results and automatically notified the local
conversation. The second task ran after a Fleet service stop/start.

## Tested configuration

- Controller: this checkout, branch `codex/run9-fleet`, with the process-service
  and reconciliation fixes described below. The original older checkout was
  preserved separately.
- Provider/model: DeepSeek, `deepseek-flash`, on both controller and worker.
- Worker: existing Run9 `niffler-2`, 1 CPU / 2 GiB, Alpine Linux, SSH alias
  `run9-niffler-2`; install root `/opt/niffler-fleet`.
- Source pin: `5b2cb29798c3bfb17b51093ab71ae9981edb111c`, independently checked
  with remote `git rev-parse HEAD`. Fleet's identity receipt stores the short hash.
- Service: explicit `process` mode, because the host has no systemd.
- Instance identity: `7316b8f1622cec1b98ad5f35f34b940d`; unchanged after restart.

Host preparation installed build prerequisites and copied the Linux toolchain;
it did not install the Niffler checkout. The model's actual `fleet_install`
cloned, checked out the pin, built all components, installed the process manager,
started the harness and verified its identity before saving a private receipt.
Provider configuration was installed separately by the operator with mode 0600;
Fleet did not copy credentials.

## Evidence

Controller conversation: `run9-fleet-controller`.

| Task | Remote session / job | Independent sum | Result |
|---|---|---:|---|
| Initial execution | `fleet-21dabe92a5cfd3482a60b2cb34f2e97ff885b065` | 275868 | Exact nonce, values and sum matched; automatic notice received |
| After service restart and status fix | `fleet-3ae4223080d7115bc7918d4d81cd6e6ce80b7603` | 233654 | Exact match; settled, reachable, delivered; exactly one notice |

Each worker received only the path to newly generated random input, not its
contents or expected answer. Each remote transcript records actual `read` and
`git_status` tool calls. The model was permitted only those tools, with limits of
6 rounds, 4 calls and 50,000 tokens. Both tasks reported a clean checkout.

Private local evidence is under `var/acceptance/`: `verification.json`, job
records, remote transcripts, controller transcript, expected data, full source
pin check and stop/start/probe results. Connection receipt:
`var/fleet/run9-niffler-2.json`. These runtime files are not committed.

## Fixes and encountered failures

1. Upstream SSH installation required systemd. Added an explicit Linux process
   service with identity-checked lifecycle, locking, child restart and parent
   death handling. Default systemd behavior is unchanged. Process mode requires
   prepared build dependencies and does not provide reboot persistence.
2. Initial live compilation failed because the copied Nim toolchain lacked its
   config directory. Repaired the toolchain, verified a real JSON program,
   preserved the incomplete checkout, and retried through `fleet_install`.
3. Successful task reconciliation unconditionally deleted an absent JSON
   `diagnostic` key. Nim raised `key not in object`, incorrectly recording
   `reachable=false` even though the result was complete. Guarded deletion and
   added regression assertions. The second live task verifies the corrected state.

4. The live box had util-linux `flock`/`setsid`/`setpriv` installed by hand.
   Stock Alpine provides BusyBox applets instead: BusyBox `setpriv` rejects
   `--pdeathsig` and BusyBox `flock` has no `-o`. The process manager and the
   installer preflight now probe `setpriv --pdeathsig` capability (refusing
   before any clone or build), the build lock falls back to its mkdir lock when
   `flock` lacks `-o`, and core's supervisor and the `von` launcher pick their
   kernel-cleanup wrapper by the same capability probe instead of presence.
   Verified on the Run9 Alpine 3.20 box against the real BusyBox 1.36.1
   applets; the default systemd install/update scripts are byte-identical to
   the base revision.

## Operating limits

- This proves bounded **read-only delegation**, not unattended coding changes
  or autonomous multi-node scheduling.
- Run9 SSH command execution works; ordinary port forwarding is unavailable.
  TUI/NATS tunnel switching is not covered by this acceptance.
- `/tmp`, `/run` and `/var/tmp` are memory mounts. Use persistent paths for
  installed state. Raw binary SSH output was corrupted by text conversion;
  use Run9 file transfer or Base64 for binary transport.
- An explicit Run9 background execution kept the runtime alive during testing.
  Test lease: `exec-qie3s4ujsznt`, initially reporting an idle deadline of
  2026-10-21 11:04:48 UTC and a hard deadline of 12:04:47 UTC.
  Process mode survives SSH logout, not runtime/host restart. This is not proof
  of unattended operation through Run9 idle shutdown. After waking a stopped
  runtime, use `fleet_start` and verify with `fleet_probe`.
- Process-mode revision updates require operator maintenance; they do not
  silently invoke the systemd updater.
- Run9 operations used `sys9 run` (sys9 0.3.5, Run9 0.21.2). The global
  `@sys9/run9-cli` helper is still present after invoking the wrapper; this report
  does not claim permanent removal of that dependency.

## Verification scope

Local builds and the Fleet installation, task and fault suites passed; the real
Linux process lifecycle test passed on Run9. Full repository testing was also
attempted but was not green: macOS path/platform and Fabric execution
failures remain. This is not a claim that the entire repository test suite passes.

No core protocol or frozen prompt prefix was changed; core's only change is
the capability probe for its `setpriv` wrapper. Fleet receipts carry the
explicit service mode; completion continues through append-only notices.
