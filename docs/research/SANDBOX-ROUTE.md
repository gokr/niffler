# SANDBOX-ROUTE — system bubblewrap, not home-grown namespaces

Status: **selected design; privileged installation and full-backend enforcement
not yet validated on this host**. Implementation lives on
`feat/sandbox-implementation`. No change to the live harness yet.

## Decision

Use the system `/usr/bin/bwrap` on Linux and Seatbelt on macOS. Niffler's
helper assembles policy and supervises execution; it does not implement user
namespaces, UID/GID mapping or mount setup itself. Reuse bubblewrap's reviewed
implementation rather than adding security-sensitive namespace code.

On hosts that require it, install an opt-in AppArmor userns grant for the system
bubblewrap binary. This permission applies to **every use of that binary**, not
only Niffler. It permits namespace creation; it does not grant host root access.
No global sysctl change, sudoers rule, setuid helper, or root harness is needed.

Do not silently substitute Landlock when full secret masking was requested.
Landlock-only write protection requires explicit operator opt-in and must report
that secret masking is unavailable. It does not satisfy the `.env` requirement.

## Evidence and corrections

On this Ubuntu host, `/usr/bin/bwrap --unshare-user --unshare-net --ro-bind / /
/bin/true` fails with `loopback: Failed RTM_NEWADDR: Operation not permitted`.
The user namespace sysctl is enabled, but AppArmor's unprivileged-userns
restriction is also enabled. The observed refusal is consistent with that
restriction; the absence of a bwrap profile alone is not proof of its sole cause.
A loaded profile and a successful real enforcement test remain necessary.

Landlock ABI 8 is available here. An actual restricted process can write inside
an allowed directory and cannot write outside it. `READ_FILE` exists from the
first Landlock ABI: earlier claims that Landlock lacks read support were wrong.
Landlock rules are additive allow rules; a broad readable workspace grant also
includes its `.env`. There is no subtractive deny rule for that broad grant.
This motivates bwrap masking, not a claim that Landlock cannot restrict reads.

Earlier claims that AppArmor policy always disappears on exec were also wrong:
exec inheritance and transitions depend on the profile's rules. Naming a wrapper
or inspecting Ubuntu's shipped profiles does not establish actual inheritance.
We choose a direct system-bwrap profile to avoid depending on an untested wrapper
configuration, not because wrapper inheritance is impossible.

`setpriv` does not elevate privileges. We will not run the harness or arbitrary
commands as host root to work around sandbox prerequisites.

## Installation and verification

The installer is intentionally separate from `make build` and `make setup`:

```bash
cd ~/git/niffler-sandbox
bash scripts/install-sandbox-profile.sh --dry-run
make install-sandbox-profile SUDO=1
./var/bin/niffler-sandbox probe
make test-sandbox
```

Review the dry-run output before approving installation. The installer targets
only the fixed root-owned, non-group/world-writable system bwrap path. It checks
profile syntax before installation, refuses to overwrite a different existing
profile, and reports loading failures. Uninstall:

```bash
make uninstall-sandbox-profile SUDO=1
```

Installation is a host-level permission change, **not enabling bash guarding**.
Bash integration is still pending. A successful availability probe is also not
proof of secret masking: enforcement tests must verify allowed operations work,
forbidden operations fail, and children inherit restrictions.

## Remaining acceptance work

- Run the privileged install with a human's authorization; test bwrap on this
  host. No privileged host changes have been made by this agent.
- Strengthen the current probe: it uses `/bin/true` for bwrap availability and
  cannot yet attest to enforcement. Bound probe execution time.
- Validate secret masks, aliases/symlinks, environment sanitization, scratch,
  parent-death cleanup and cancellation before bash integration.
- Implement and test Seatbelt on an actual Mac; it is not implemented yet.
- In-process readers need service-side access checks too: checking only a tool's
  root argument cannot hide secrets found while traversing that directory.
- Locks coordinate competing writers; sandbox permissions authorize filesystem
  access. A lock claim is not authorization and must not broaden sandbox rights.

Prompt-prefix effect: no runtime prefix change. Future status/refusal guidance
enters append-only tool results; newly exposed schemas follow frozen-tool rules.
