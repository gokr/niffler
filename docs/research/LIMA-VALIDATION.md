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

Live acceptance remains separately approved work: hypervisor availability,
image boot, published-revision bootstrap, guest sudo/linger/user-service
persistence, native binary stdio relay and optional SSH management-host routing.
