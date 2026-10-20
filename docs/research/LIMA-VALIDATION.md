# Lima transport review evidence

CLI: installed `limactl version 2.2.1` on Linux x86_64. No VM creation, boot,
privileged command or real guest connection was authorized or performed.

## Image provenance

Fetched over HTTPS from the publisher (not guessed or copied from a mutable
Ubuntu `release` alias):

```
https://cloud-images.ubuntu.com/releases/noble/release-20260926/SHA256SUMS
6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2 *ubuntu-24.04-server-cloudimg-amd64.img
1d6bffe64b848468ac97f821d369a4846d983de1800ccf6b5ec8853e85cefc55 *ubuntu-24.04-server-cloudimg-arm64.img
```

These match Lima v2.2.1 `templates/_images/ubuntu-24.04.yaml`. HTTPS publisher
checksum retrieval is the provenance evidence; no independent GPG verification
or image download/boot was performed. Runtime Lima verifies the pinned digest.
Dated Ubuntu URLs may expire; review URL and checksum changes together, fail
closed, never add upstream's unpinned fallback.

## Reproduce CLI default-fill checks (no VM)

From the harness worktree:

```bash
limactl --version
nim c --hints:off --path:sdk -o:var/lima-config-check tests/lima_config_check.nim
./var/lima-config-check
```

This exports the actual generated Fleet configuration, executes installed
`limactl validate --fill`, parses its YAML and runs the same effective-policy
validator as provisioning. It then repeats with an isolated `LIMA_HOME` whose
`_config/default.yaml` injects a host-home mount: **real Lima fill inherits that
mount despite the standalone template's empty mounts**, and Fleet must reject
it. Output: `LIMA CONFIG CHECK PASSED (no VM created/started)`.
Evidence files are in `var/lima-config-evidence/`. Ordinary `make test-fleet`
uses fake transports and does not depend on installed Lima.

On the tested 2.2.1 default fill, qemu/Linux/x86_64, 2 CPUs/4GiB/20GiB,
ubuntu `/home/ubuntu`, disabled containerd and proxy propagation, and the
all-address/all-protocol ignore port-forward rule survived. No mounts, hooks,
extra disks, copies or extra networks appeared in the ordinary filled config.
Lima supplied an inert containerd archive registry even though both containerd
modes are false; Fleet requires those modes to remain false. Explicit image
entries must match the reviewed three-field objects exactly: extra archive,
kernel, initrd, variant or unknown image fields refuse. Policy containers and
booleans are type-checked; malformed empty values must not evade checks.
Custom firmware image registries, driver/OS overrides and certificate injection
also refuse.

## Scope and limits

This is a checked set of transport/boot isolation constraints, **not an immutable
review of every Lima default or future configuration field**. Unknown top-level
fields are not a complete allowlist. The management account, limactl binary,
Lima implementation and host hypervisor remain trusted. Inspection and later
start/shell are separate CLI calls: concurrent management-host configuration
changes are not OS-fenced. Host administrators must not race Fleet or install
unsafe Lima defaults/overrides. TUI relay verifies pinned Niffler identity but
is not a duplicate Lima configuration auditor. No claim of protection against a
malicious hypervisor/operator or a compromised Lima binary is made.

TUI review: Incus still uses fixed local/default-project argv and ordinary
ubuntu runuser/HOME, requires `/home/ubuntu/niffler`, validates guest/host names,
and rejects mixed transports. Multipass registry fields (even empty or alongside
SSH) and receipts explicitly reject with new-receipt migration guidance.

## Live smoke on this machine (2026-10-20)

Authorized single-host smoke: Ubuntu 24.04 host, KVM available, `limactl 2.2.1`,
qemu 8.2.2, enough disk. Instance `fleet-smoke`, created from the **Fleet-generated**
config (`var/lima-smoke/fleet.yaml`, produced by `tests/lima_config_check.nim`),
2 CPU / 4 GiB / 20 GiB, x86_64, image digest
`sha256:6a81c375…7d5bb4d2` (the amd64 pin).

Boot: 63 s from cached image to `READY`; qemu/KVM, no hostagent port
forwarding except SSH.

Verified inside the guest:

- `ubuntu` uid 1000, `HOME=/home/ubuntu`, Ubuntu 24.04.5, kernel 6.8, x86_64.
- 2 CPUs, ~3.9 GiB RAM, 19 GB root filesystem — the declared limits.
- **No host paths**: `/home/gokr`, `/Users` and `/tmp/lima` absent; `mount` shows
  no virtiofs/9p/sshfs entries at all.
- Guest `127.0.0.1:4222` refuses, so the guest cannot reach a host-local bus.
- Passwordless sudo for `ubuntu`, exactly as the config requests.
- Outbound HTTPS works (image already digest-verified by Lima).

Transport contract (`provision.remote` / `guard` / `probe`): a script piped to
`limactl shell --workdir=/home/ubuntu <vm> bash -s` runs as `ubuntu` in
`/home/ubuntu`; a guest `exit 7` surfaces as `limactl` exit 7 (checked without a
pipeline, which had masked it in a first attempt); the probe's loopback-only URL
regex accepts the generated `nats://127.0.0.1:<port>` form.

Fleet `fleet_install {transport: lima, revision: main}` against this VM:

- resolved and pinned `main` → `2ecaae8`, cloned and built in the guest
  (~13 min: 40 binaries), and wrote a mode-0600 receipt pinning
  `instanceId ef2b655323f6d2dc2e4fe8ebf9dc1437`, name `lima-fleet-smoke`,
  root and `gitHash`.
- The user service came up as `niffler-350014a71e60fe02.service`:
  `Active: active (running)`, **`Linger=yes`**, ~221 MB RSS, 33 child components
  registered (store, locks, agent, expert, fabric, lsp, repomap, …).
- The service spawned its own isolated bus at `nats://127.0.0.1:33981`, bound to
  `127.0.0.1` only; a host-side connect to that port is **refused**, so the
  guest bus is not reachable from this machine.
- `fleet_probe`, `fleet_status` and `fleet_logs` all verified the pinned identity
  over the live catalog afterwards.

Known gap found by the smoke: `fleet_install` writes the receipt and brings the
service up, but the bus call that started it did not return to `cli` (killed
after 20 min, no output, while the component stayed healthy — a later
`fleet_probe` answered immediately). Needs diagnosis: a long-lived `install`
reply path, not a transport fault.

Delegation is **not** exercised end-to-end: the guest `.env` is the untouched
`.env.example`, so the instance has no provider credentials and cannot run a
turn. That is correct behaviour (Fleet never copies credentials); a delegated
smoke needs explicit provider setup on an authorized guest.

Teardown: `limactl stop fleet-smoke` / `limactl delete fleet-smoke` remain
operator actions; Fleet still never deletes a guest.

## Not covered

- SSH-hosted guest provisioning (fake-transport tests only).
- `fleet_update` against a published revision on a real guest.
- Cross-instance delegation to a Lima peer (needs guest provider credentials).
- macOS hosts (Seatbelt/VZ paths) — this smoke was Linux/KVM only.
