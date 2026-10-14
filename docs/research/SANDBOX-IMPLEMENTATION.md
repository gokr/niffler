# SANDBOX-IMPLEMENTATION — an ordered plan

Status: **launcher prototype implemented; not integrated with bash.**
**Current Linux route is authoritative in [SANDBOX-ROUTE.md](SANDBOX-ROUTE.md):
use system bubblewrap, with an opt-in direct system-bwrap AppArmor grant where
needed.** The earlier Phase 0 claims below about mandatory wrapper profiling
and AppArmor exec inheritance are superseded by that corrected decision.
Concrete execution schedule for the
design settled in [SANDBOX-MATRIX.md](SANDBOX-MATRIX.md) §5–§6a and
[SANDBOX-PLAN.md](SANDBOX-PLAN.md). Read those first — this file does not
re-argue the decisions, it schedules them.

Supersedes [SANDBOX-PLAN.md](SANDBOX-PLAN.md) §3–§5 in two places: the backend
pair is **bwrap + Seatbelt** (Landlock has read support but no subtractive deny
rule to mask `.env` under a broad readable workspace grant),
and read confinement is a **core-side scope check**, not part of the launcher.
SANDBOX-PLAN's scope, honesty and stopping rules still govern.

## 0. What we gain — and what we do not

Ranked by what actually changes the day it ships.

| # | Gain | Who benefits |
|---|---|---|
| 1 | **Blast-radius containment.** A hallucinated `rm -rf`, a bad `find -delete`, a runaway `make clean` can no longer reach outside the conversation workspace. | the headline; today nothing stops this |
| 2 | **`.env` and machine secrets become unreadable to shells.** The clone holds a live `NIF_OPENAI_API_KEY`; `bash cat .env` currently works. | real exfiltration path closed |
| 3 | **The component-bypass path closes.** A confined shell cannot reach `127.0.0.1:4222`, so it cannot ask `edit`/`builder`/`plugins` to perform a write it is not allowed to do. | closes a hole SANDBOX-PLAN §1 lists as *possible* today |
| 4 | **The write boundary gets kernel teeth.** `locks` is cooperative and documented as unable to cover fabric native I/O, plugin installs and direct exec. The launcher covers exactly those. | complements shipment we already made |
| 5 | **Read scope stops the model, not just shells.** `read .env` becomes an ordinary refusal. | the tool call an LLM actually makes |
| 6 | **Reproducible, offline command environments** (bench/CI): no network, workspace-only state. | DeepSWE-style runs |
| 7 | **A probeable, honestly-reported state.** `bash_sandbox_status` says *off* / *failed* / *applied* — never a silent downgrade. | debuggability before security |

**Honest non-gains** (these stay outside the promise, and the docs must say so):

- Not containment of a malicious agent — the agent edits the harness's own
  source tree, so it can weaken any check it can reach (SANDBOX-PLAN §6).
- Not confidentiality against a component that ignores its declared scope; the
  read check is cooperative, like `writes`.
- Not a network firewall: no domain filtering, and `bash` has no bus only
  because the namespace gives it none.
- Not protection for future unconfined launches elsewhere on the machine.
- No protection against a symlink swapped between a path check and the open.

Each phase below is independently shippable. Phases 1–2 are the security
increment; 3 is the read seam; 4 is convenience. Nothing in 3–4 is a
prerequisite for 1–2.

## Phase 0 — decide and de-risk (no product code)

1. **Confirm the backend pair** and record the platform matrix. Verified on
   this machine: Ubuntu 24.04 / kernel 7.0, `bwrap` present,
   `unprivileged_userns_clone=1`. `sandbox-exec` is macOS-only and absent here,
   so macOS enforcement needs a real Mac before its phase can be called done.
2. **⚠ `unprivileged_userns_clone=1` is NOT sufficient on Ubuntu 24.04.**
   AppArmor's `kernel.apparmor_restrict_unprivileged_userns = 1` (the default
   since 23.10, and **set on this host**) overrides it: an *unconfined*
   program may no longer create a user namespace. Measured by hand:

   ```
   $ bwrap --unshare-user --ro-bind / / /bin/true
   bwrap: setting up uid map: Permission denied
   $ bwrap --unshare-net --ro-bind / / /bin/true
   bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
   $ unshare -Ur true
   unshare: write failed /proc/self/uid_map: Operation not permitted
   ```

   `--unshare-user`, `--unshare-net`, `--unshare-all` all fail, so **plain
   bubblewrap does not work out of the box here**, and a hand-written
   `--unshare-net` is not available either. This is the failure codex's probe
   exists to catch (`USER_NAMESPACE_FAILURES`), and it confounds the earlier
   "Phase 0 exit criterion" of running `bwrap … /bin/true` by hand.

   **The remedy is small and well-understood.** AppArmor grants `userns` to a
   program that *has a profile*; Ubuntu ships exactly this for the tools that
   need it (`/etc/apparmor.d/{ch-run,ch-checkns,buildah,crun}` are all the
   three-line "unconfined but named" pattern):

   ```
   abi <abi/4.0>,
   include <tunables/global>
   profile niffler-sandbox /path/to/niffler-sandbox flags=(unconfined) {
     userns,
     include if exists <local/niffler-sandbox>
   }
   ```

   `bwrap` itself has **no** profile on this host (`grep -rl bwrap
   /etc/apparmor.d/` is empty), which is why it is refused. So the launcher
   must be *our own* profiled binary — a reason to ship `niffler-sandbox`
   rather than exec the system `bwrap` directly.

   **Settled in [SANDBOX-ROUTE.md](SANDBOX-ROUTE.md)** (measured, with the
   rejected alternatives): ship the profiled-bwrap launcher; install the profile
   as an opt-in prerequisite; report a three-way backend state (`landlock` =
   writes confined/reads unconfined, `bwrap` = the full promise, `off`/`failed`)
   so a degraded host is never presented as protected. Note Landlock **has** read
   support — what it lacks is a deny rule, so it cannot carve an in-tree `.env`
   out of a granted workspace. That, not read support, is why bwrap is needed.

   **Consequences to settle before Phase 1:**

   - **Packaging.** The profile must be installed (root) and the launcher path
     is machine-specific, so it cannot be a blind `make` step. Model it on
     `make install-lsp` (idempotent, per-item, non-fatal) and document it in
     `make doctor` as a prerequisite with a named remedy — never a silent
     fallback.
   - **Alternatives if the profile is refused:** run the launcher as root with
     `setpriv` (our supervisor already uses `setpriv --pdeathsig`), or ship a
     container/VM route (SANDBOX-PLAN §8). All are acceptable; what is *not*
     acceptable is falling back to unconfined execution.
   - **Landlock is the lower-friction backend here** precisely because it needs
     no user namespace — `no_new_privs` plus `landlock_create_ruleset` — and it
     works on a stock Ubuntu with no profile (ABI 8 measured). It is still
     **not** the answer for hiding `.env`, because it has no deny rule to carve
     an in-tree file out of a granted directory ([SANDBOX-ROUTE.md](SANDBOX-ROUTE.md) §2).
     Do not let that trade-off be decided by convenience without recording it.
   - **CI and dev machines differ.** A test that passes because the runner ran
     as root, or on a host with the restriction off, proves nothing. The probe
     must assert the *forbidden operation* fails, per SANDBOX-PLAN §3.
3. **Write down the one immutable launch request** (SANDBOX-PLAN §2 already
   specifies it): canonical workspace, canonical cwd, writable roots, private
   scratch, explicit env, exact argv. Resolve once per launch; no policy
   lattice, no glob language.
4. **Decide the default.** Plan says `NIF_BASH_SANDBOX=off|on`, initially
   **off**. Keep that — a guard that breaks common workflows on day one gets
   turned off permanently.

**Exit:** a one-page decision note; a *profiled* launcher binary creates a
user namespace and hides a file **on this host** (not merely a host where the
restriction is disabled).

## Phase 1 — the launcher (§ helper binary, not a component)

New `var/bin/niffler-sandbox`, with `probe` and `run` subcommands.

1. **Linux backend (bwrap).** Assemble argv along the lines codex uses:
   `--new-session --die-with-parent --unshare-user --unshare-pid --unshare-ipc
   --unshare-net`, a read-only root, a minimal `/dev` and fresh `/proc`, a
   writable `--bind` of the workspace, `--ro-bind /dev/null <secret>` masks,
   `--chdir <canonical cwd>`, then `-- <cmd>`. Note `--unshare-net` is what
   closes gain #3 — it is not optional even though v1 claims no network policy.
2. **macOS backend (Seatbelt).** Generate a profile that allows reads/writes
   inside the workspace and denies read/write of the masked paths, then
   `/usr/bin/sandbox-exec -p <profile>`. Reuse codex's `.sbpl` shapes as
   reference; escape correctly.
3. **Report honestly.** A launcher-to-parent channel (extra FD, not
   stdout/stderr) carrying launch id, backend, outcome — because a command can
   itself exit 125 and that number alone is not a sandbox diagnosis
   (SANDBOX-PLAN §3). Never fall back silently; an unavailable backend refuses
   the command.
4. **Probe must test a forbidden operation**, not `true`. `bwrap` present but
   unable to create a user namespace is a *failed* probe with a named reason
   (codex probes exactly this, and refuses with a specific message).

**Exit criteria:** two sibling dirs `allowed`/`outside`; the same command
writes inside and is denied outside; a symlink pointing out does not become a
write escape; the probe reports capability truthfully; a config that cannot be
applied starts **no** user command.

## Phase 2 — bash integration (opt-in) — *security increment lands here*

1. **Wrap the launch, change nothing else.** `bash` execs `argv` via `execvp`
   in `runCmd` (`sdk/niffler/procutil.nim`); the wrapper is another argv prefix,
   exactly like the existing `netScoped` container/netns variants. Preserve
   cancellation, timeouts, process-group teardown, output caps and spill files
   — these are the features most likely to regress.
2. **Build the child environment allowlist.** Required platform vars, reviewed
   PATH, minimal locale/toolchain set. Do **not** forward provider keys, NATS
   URL/credentials or loader-injection vars. Env sanitizing is not read
   confidentiality, and the docs must say that.
3. **Return a structured `sandbox` field** (`{scope: "shell-write", backend,
   state, digest}`) alongside existing result fields, and render the necessary
   guidance in `text` — machine-only fields never reach the model.
4. **Add `bash_sandbox_status`** (on-demand, read-only) so a human or the model
   can ask what is actually in force.
5. **Update `docs/WIRE.md` / `docs/MANUAL.md`.** No `sdk/envelope.nim` change.

**Exit criteria:** alternate calls from two conversations through the one bash
process — workspace A must not become writable for B because A ran first;
`cwd` overrides honored; timeout/cancel/descendants still work;
off-mode behavior byte-identical; `bash cat .env` refused when on.

**Prompt-cache note (required):** tool schemas stay frozen. Status and denial
text arrive as append-only tool results. A refusal is history, never a prefix
change — the same rule the write-arbitration work followed.

## Phase 3 — read scope in core (§6a) — *stops the tool call*

1. **Add `x-harness.reads {pathFields, …}`**, mirroring `x-harness.writes`.
2. **Make `applyWorkspace` contain, not just resolve.** Today it rewrites
   relative paths and lets absolute ones through unchecked. Add the check:
   a resolved path outside the conversation's set is refused with
   `E_READ_OUTSIDE`, and *fail closed for a tool declaring no scope* — the
   conservative default that makes a component-side declaration safe.
3. **Declare read scope on the readers**: `edit`'s `read`, `grep`, `skills`,
   `repomap`, `observe`, `fetch`, `lsp`. Keep the declarations declarative —
   never a hardcoded `.env` list in a shared component.
4. **Allowance source is the workspace set** (`workspaceRootsFor`: primary +
   worktrees + same-origin siblings + `__workspace`), so `.env`, `~/.ssh` and
   `NIF_ROOT` control state are excluded without a deny list.

**Exit criteria:** `read .env` refused with a clear message; `read` inside the
workspace unaffected; an undeclared tool is opaque (still refused);
`make build && make test` green.

**Scope rule:** a bare `read <abs-path>` may still be how a human points the
agent at a file outside the tree. That is an operator decision — allow it only
via an explicit grant (Phase 4), not by leaving the check open.

## Phase 4 — beyond the first release (each its own gate)

- **Declarative in-tree deny entries** for secrets that legitimately live inside
  a project (fixture credentials); operator-owned config.
- **One-shot grants** for an outside directory, reusing the approval transport
  but *not* blanket auto-approval (SANDBOX-PLAN §5).
- **Component ceilings** at the supervisor for services with a stable footprint.
- **VM/container deployment** — SANDBOX-PLAN §8's strongest option, and the
  right answer for genuinely untrusted code.

## Stopping rules

Stop and revise scope if the work needs silent fallback, a generic privileged
RPC, persistent grant authority, or a claim about network rules we did not
implement (SANDBOX-PLAN §7). If Phase 1's backends need extensive compatibility
machinery, take SANDBOX-PLAN §8's wrapper/VM route instead of expanding.

Validation is `make build && make test` plus the phase's own enforcement tests,
on real Linux and macOS hosts; a skipped platform is not a green one.

