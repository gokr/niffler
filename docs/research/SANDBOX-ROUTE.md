# SANDBOX-ROUTE — which enforcement mechanism, decided

Status: **decision record.** Settles the question Phase 1 was blocked on
([SANDBOX-IMPLEMENTATION.md](SANDBOX-IMPLEMENTATION.md) Phase 0 item 2): how the
launcher is allowed to create the namespaces it needs, and on which backend.
Evidence below is **measured on this host** (Ubuntu 24.04.5, kernel 7.0.0-34,
AppArmor enforcing), not inferred. Read with
[SANDBOX-MATRIX.md](SANDBOX-MATRIX.md) §5.

## 1. The measurements

**bubblewrap is refused, for a specific and fixable reason.** AppArmor's
`kernel.apparmor_restrict_unprivileged_userns = 1` (Ubuntu's default since
23.10) overrides `unprivileged_userns_clone = 1`, so an unconfined program
cannot create a user namespace:

```
$ bwrap --unshare-user --ro-bind / / /bin/true   → setting up uid map: Permission denied
$ bwrap --unshare-net  --ro-bind / / /bin/true   → loopback: Failed RTM_NEWADDR: Operation not permitted
$ unshare -Ur true                               → write failed /proc/self/uid_map: Operation not permitted
```

`bwrap` has no AppArmor profile here (`grep -rl bwrap /etc/apparmor.d/` is
empty) and that is the *entire* reason. Ubuntu grants `userns` to any program
that has a profile — which is why `/etc/apparmor.d/{ch-run,ch-checkns,buildah,crun}`
exist as three-line "unconfined but named" stubs.

**Landlock needs no profile, and works today.** A small C probe
(`PR_SET_NO_NEW_PRIVS` + `landlock_create_ruleset` + `restrict_self`):

```
landlock OK: ruleset fd = 3
landlock ABI version = 8
write inside allowed: ALLOWED
write outside (equally-owned dir): DENIED
read /etc/hostname (no rule): DENIED
read .env inside allowed dir: ALLOWED        ← the decisive line
```

## 2. The decisive property

**Landlock is an allow-list with no deny rules**, so it cannot carve a file out
of a directory it has already granted. Granting the workspace
(`READ_FILE|READ_DIR|WRITE_FILE|…` on `/ws`) grants the whole subtree, and
`.env` comes with it. Since `.env` sits *inside* the project a conversation
works in, hiding it is exactly the carve-out Landlock cannot express.

Two ways around that, both with real costs:

- **Grant `READ_DIR` on the workspace but `READ_FILE` only per subdirectory**,
  enumerating the tree at launch — the filesystem walk SANDBOX-PLAN §2
  explicitly rules out, plus a TOCTOU window on every new file.
- **Don't grant the workspace; grant only what is needed** — brittle for a
  shell running arbitrary build tooling.

Note also the correction this forces on our own docs: Landlock is **not**
"write-only in v1". `READ_FILE` has been an access right since the first ABI
(the header documents third-ABI additions as *refinements* like `REFER`, not
the existence of read). What Landlock lacks is **deny semantics**, and that is
the honest reason it cannot hide an in-tree secret — not read support.

## 3. Decision

**Ship `niffler-sandbox` as a profiled binary that execs bubblewrap, and install
its AppArmor profile as an opt-in prerequisite.**

Rationale, in order of weight:

1. **Only a mount namespace can hide an in-tree secret**, and that requirement
   is the one that selects the backend (SANDBOX-MATRIX §5). bwrap expresses it
   as one argument (`--ro-bind /dev/null <path>`); Landlock has no equivalent.
2. **The profile is a known, small, reviewable artifact** — the same shape
   Ubuntu itself ships for `ch-run`, `buildah` and `crun`. We are not inventing
   a privilege mechanism; we are joining an existing one.
3. **It is install-time, not run-time.** No new privileged RPC, no persistent
   grant store — the two things SANDBOX-PLAN §7 says to stop for.

Rejected alternatives, with reasons:

| Alternative | Why not |
|---|---|
| **Landlock only** | Cannot hide `.env` (§2). Acceptable as a *degraded* backend that reports reads-unconfined, never as the default for a `.env` promise. |
| **`setpriv`-as-root launcher** | `setpriv` *drops* privileges; elevating needs `sudo`. That means either a sudoers rule (a broader grant than a targeted profile) or a setuid binary (worse). Not justified for this. |
| **Run the harness as root** | Enormously worse; the whole point is reducing blast radius. |
| **Container/VM route** | The right answer for untrusted code (SANDBOX-PLAN §8) and a fine operator choice, but it is a deployment, not the per-command guard this plan is about. Offer it, do not require it. |

## 4. Consequences for the implementation

- **The launcher is ours, not an exec of system `bwrap`.** It must be the
  profiled binary, because the profile is attached by *path*. This also gives
  us the launch-id/outcome channel SANDBOX-PLAN §3 requires.
- **⚠ Correction after implementing: the profile must be on the binary that
  *creates the namespace*, not on a wrapper that execs bwrap.** AppArmor
  profiles attach **per exec** — the profile is the *executing* program's — so
  granting `userns` to `niffler-sandbox` would not extend to the `bwrap` it
  spawns. Confirmed by the shipped precedent: every profile on this host names
  the namespace creator itself (`profile ch-run /usr/bin/ch-run`, likewise
  `buildah`, `crun`, `ch-checkns`), never a wrapper.

  Two ways to satisfy that, and they should be chosen deliberately:

  1. **The launcher creates the namespace itself** (`unshare(CLONE_NEWUSER |
     CLONE_NEWNS | CLONE_NEWNET)`, write `uid_map`/`gid_map`, then exec bwrap
     with the `--unshare-*` flags dropped). Keeps the grant on our own binary.
     Note the measured split: `unshare(CLONE_NEWUSER)` **succeeds in-process**
     on this host; what AppArmor denies is the mapped-namespace setup bwrap
     does (`setting up uid map: Permission denied`). So the failure is in the
     uid/gid mapping step, which the launcher would own directly.
  2. **Profile `bwrap`'s own path.** Fewer moving parts, but the grant then
     covers *every* bwrap use on the machine, which is broader than intended.

  Option 1 is the one consistent with "narrow grant"; option 2 is the one
  consistent with "less code". **Unverified on this host either way — profile
  loading needs root, which this session did not have.** Phase 1's bwrap path
  is therefore implemented but *not* proven, and must not be reported as
  working until a host with the profile has run the enforcement tests.
- **Profile installation** follows the `make install-lsp` precedent: a script,
  idempotent, per-item, **non-fatal on failure**, and never part of `make
  setup`. `make doctor` reports it as a prerequisite with the exact remedy
  text, and the probe independently verifies the result rather than trusting
  that the file was installed.
- **Three-way backend reporting**, so degraded is never presented as protected:

  | State | Meaning |
  |---|---|
  | `landlock` | writes confined, **reads unconfined** — the guard works without any profile |
  | `bwrap` | writes and reads confined; secrets hidden — the full promise |
  | `off`/`failed` | no confinement; the command did not run unguarded if the operator asked for guarding |
- **Never silently fall back** between them. A host that cannot get a profile
  runs `landlock` and *says so*; a host asked for the full promise refuses
  rather than downgrading quietly. Verified behaviour: with no profile and no
  opt-in, `probe` reports `none` and `run` exits 125 having executed nothing.
- **The probe must use Landlock's own ABI**, not the kernel version:
  `LANDLOCK_CREATE_RULESET_VERSION` (returns 8 here), and it must assert a
  **forbidden operation fails**, never that `true` succeeds (SANDBOX-PLAN §3).
- **CI cannot be a plain Ubuntu runner.** Whatever profile state a runner has
  decides which backend a test exercises. Enforcement tests must set the state
  explicitly and skip-with-reason where a backend is genuinely unavailable —
  never let an all-skipped run read as green.

## 5. Open questions this decision leaves open

- **macOS parity.** Seatbelt needs no profile and covers reads, so it is the
  full-promise backend there — but nothing here has been run on a Mac. Phase 1
  cannot be called done for macOS on the strength of this document.
- **Profile path stability.** The profile names the launcher's absolute path,
  which differs per checkout (worktrees, `NIF_ROOT`). Decide whether the
  install step rewrites the path each time (simple, honest) or the launcher is
  installed to a stable location (fewer moving parts). Prefer the rewrite.
- **Does the profile weaken anything?** It grants `userns` to one binary at one
  path, `flags=(unconfined)`. That is what Ubuntu itself does for `ch-run`; a
  security review should confirm the launcher cannot be used as a general
  namespace-creation primitive for its caller.
- **Landlock as a hardened extra.** With ABI 8 present, applying Landlock
  *inside* the bwrap sandbox would add a second, kernel-enforced layer that
  survives a bwrap misconfiguration. Optional, cheap to test, not required.
