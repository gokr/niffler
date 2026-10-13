# SANDBOX-MATRIX — what the harness shelf actually ships

Status: **evidence survey; nothing here is implemented.** This is the prior-art
base [SANDBOX-PLAN.md](SANDBOX-PLAN.md) asks for before its backend choice is
frozen — the plan's own stopping rule is "if either backend needs excessive
compatibility machinery, stop and compare the existing-wrapper alternative in
§8", and the matrix below is what that comparison needs. Open work has one home
— [../PLAN.md](../PLAN.md).

Read with: [SANDBOX.md](SANDBOX.md) (superseded proposal),
[SANDBOX-PLAN.md](SANDBOX-PLAN.md) (the live plan),
[WRITE-ARBITRATION.md](WRITE-ARBITRATION.md) (the locks half of the same
boundary), [../WIRE.md](../WIRE.md).

## 1. Method, and what this does not establish

Read on 2026-10-09 against freshly pulled checkouts (`git pull --ff-only` in
`~/git/harnesses`, all fast-forwarded; deepseek-harness needed a detached HEAD
put back on `master`). Pins are in the shelf README and repeated per row below.

**This is a code-and-docs read, not an execution test.** No sandbox was run. So:
mechanism attribution and policy vocabulary are high-confidence (they are
literal code); *quality of enforcement* — escape-resistance, ABI edge cases,
whether a given profile is actually applied — is **not** established here. Where
a doc claims enforcement, say so and re-verify on a machine before relying on it.

One correction from the first pass, kept visible because it is the usual trap:
an initial grep ranked `maki` as a Landlock harness (10 hits). All of them were
in `maki/target/` — vendored crate *declared_features* metadata, not source.
With build artifacts excluded, **`maki` has no sandbox at all**. Every count
here excludes `target/`, `node_modules/`, `dist/`, `build/`, `vendor/`.

## 2. The matrix

"Filesystem" says how writes (and, where noted, reads) are confined. Rows
without a filesystem mechanism are approval-gated only — which, as OpenCode's
SECURITY.md and CodeWhale's threat model both state, is a UX control and not
isolation.

| Harness | Linux | macOS | Windows | Policy vocabulary | Notes |
|---|---|---|---|---|---|
| **codex** `816fa702e` | **bubblewrap** primary; Landlock retained as a *legacy* path (`use_legacy_landlock`) | Seatbelt (`*.sbpl` policy files) | AppContainer + `WindowsMxc` | `ReadOnly{network_access}` / `WorkspaceWrite{network_access, writable_roots}` / `DangerFullAccess` | richest engineering: bundled-bwrap fallback, user-namespace probe, WSL1 refused explicitly, daemon-socket masks, canonical-cwd `--chdir` fix |
| **CodeWhale** `182bafe6b` | **bubblewrap** + seccomp | Seatbelt | `windows.rs`, AppContainer | `DangerFullAccess` / `ReadOnly` / `WorkspaceWrite{network_access}` / `ExternalSandbox` | widest backend set: `sandbox/{backend,bwrap,policy,seccomp,read_guard,process_hardening,seatbelt,opensandbox,windows}.rs` |
| **deepseek-harness** `d743267388` | **Landlock** launcher | Seatbelt | ACL restricted token | `'read-only' \| 'workspace-write' \| 'danger-full-access'` | the vocabulary's origin for our docs; explicitly reports *partial* enforcement where ambient ACLs leak |
| **qwen-code** `58c59136` | bwrap + Landlock | Seatbelt | AppContainer (heavy) | gemini lineage | gemini fork that kept both |
| **gemini-cli** `51617c1` | **bubblewrap** (`LinuxSandboxManager`, `bwrapArgsBuilder`) | Seatbelt profiles | — | profiles `permissive/restrictive/strict` × `open/proxied` | plus docker/podman, gVisor `runsc`, LXC as named methods |
| **DeepSeek-Reasonix** `afbc1c0a0` | bwrap | Seatbelt | — | — | |
| **pi_agent_rust** `48bcd03c` | bwrap | Seatbelt | — | — | |
| **pi-fabric** `c538d3e` | bwrap | Seatbelt | — | — | |
| **pi** `6f2f164ab` | minimal (1 hit) | Seatbelt (1) | — | — | docker-first |
| **hermes-agent** `6e7b83a2f1` | bwrap, Landlock (2) | — | — | — | docker-dominant |
| **aider** `5dc9490`, **kimi-cli** `9ab1286`, **MiMo-Code** `b258d28f`, **octofriend** `45a12ac`, **opencode** `1015cb67d`, **OpenHands** `5a8635a3f`, **plandex** `e2d7720`, **maki** `d2a534a5`, **pi-hashline-edit-pro** `ba7e0a9` | **none** | none | none | — | approval-gated only, or delegated to a container the user runs |

`opencode` is worth a line: it is cited in our SANDBOX.md, and its SECURITY.md
is the clearest statement of the industry default — the permission system is a
UX feature, sandbox escapes are out of scope. Our docs already quote it; the
point stands and is unchanged by the pull.

## 3. Three convergent findings

**a. The mode vocabulary is settled.** codex, CodeWhale, dsh and qwen
independently carry the same three-value filesystem enum with a separate network
flag. Our SANDBOX-PLAN already adopted it — good, and now evidenced rather than
borrowed from one source.

**b. Confinement is per *command*, keyed to the workspace, with the workspace
mounted at its own absolute path.** Every implementation confines the launched
command, not the process tree above it. gemini's docs state the mount rule
plainly: the cwd appears inside the sandbox at the *same absolute path* as on
the host. This is the opposite of what SANDBOX.md proposed for Niffler
(spawn-time component confinement) — and SANDBOX-PLAN already corrected this for
its own reasons (bash is shared across sessions and cwds). The shelf agrees.

**c. Secret masking is a first-class concern, and we have no equivalent.**
gemini masks `.env`/`.env.*` and a configured forbidden set by binding
`/dev/null` over the file (`--ro-bind`) or a read-only tmpfs over the directory;
codex masks WSL interop sockets and daemon sockets, and reasons explicitly that
masks must be applied *after* the filesystem binds so a network path cannot
bypass them. Niffler's clone home holds a real API key in `.env`, and
SANDBOX-PLAN v1 leaves reads unrestricted. That is a deliberate, documented gap —
but the shelf shows masking is cheap, and it is the highest-value follow-up.

## 4. Where Niffler differs — the one thing no shelf harness has

**Every shelf harness confines a process that talks to nothing.** Niffler's
`bash` component is a NATS client on the host loopback. That single fact changes
the backend calculus, and SANDBOX-PLAN already flagged it in one line ("a bwrap
network namespace cannot retain access to the host's loopback bus without
additional plumbing").

Concretely: `--unshare-net` gives the sandbox a private loopback with no routes,
so a confined bash could not reach `127.0.0.1:4222`. The options are (1) keep the
network shared — which forfeits network isolation entirely, (2) forward or bind
the bus, or (3) accept that a confined shell simply has no bus, which is correct
for shell code and is what SANDBOX-PLAN already asserts ("the launched shell has
no legitimate need for a bus socket").

Option 3 is the honest answer and needs no plumbing. It also sharpens the
threat model: with the bus unreachable, a confined `bash` cannot escape by asking
a broader component (`edit`, `builder`, `plugins`) to do the write — an attack
SANDBOX-PLAN §1 lists as *possible* today, when a shell can reach the bus. Worth
stating in the plan: **network isolation here is not about exfiltration, it is
about closing the component-bypass path.**

## 5. Which backend can promise what — the "chroot" question

This is the part our plan currently compresses into one line, and the shelf is
unambiguous about it:

| Backend | Write confinement | **Read** confinement ("chroot") | Cost |
|---|---|---|---|
| **Landlock** | yes (the v1 promise) | only from a newer ABI; the plan defers it | unprivileged, in-process, no new binary deps |
| **Seatbelt** | yes | yes (the `strict` profiles) | macOS only |
| **bubblewrap** | yes | **yes, by construction** — you mount only what you bind | needs user namespaces, and **Ubuntu 23.10+ denies those to unconfined programs** via `apparmor_restrict_unprivileged_userns=1` (verified on this host: `bwrap --unshare-user` → *setting up uid map: Permission denied*). Needs an AppArmor profile, root, or a container/VM route; also blocked on WSL1 |

The pattern is stark: **every harness that wanted to hide files used bubblewrap.
Every harness using Landlock treats it as write-only protection.** dsh's own doc
is candid — its Windows ACL backend "reports partial enforcement for its ambient
ACL gaps" — and codex keeps Landlock behind a `use_legacy_landlock` flag while
bwrap is the default.

So the answer to "can we confine bash to a chroot-like reachable set" is **yes —
and that requirement, not write protection, is what selects the backend.**
Choose **Landlock alone** and the promise is "this command cannot *write* outside
its workspace" (reads unrestricted, secrets readable). Choose **bubblewrap**
(Linux) or **Seatbelt** (macOS) and the promise can be "this command can only
*see* and *write* its workspace" — a real reachable-set boundary.

Both hiding mechanisms are per-process and differ only in technique:

- **bubblewrap** hides by not mounting: `--ro-bind /dev/null <file>` over a
  secret, `--tmpfs <dir>` over a directory (gemini's forbidden-path handling).
- **Seatbelt** denies by syscall rule: `(deny file-read* file-write*
  (literal …) (subpath …))` (codex's Seatbelt policy generation).

**bwrap = bubblewrap** (`bwrap` is the project's executable name; codex also
ships a "bundled bubblewrap" fallback). Landlock is the only one of the three
that cannot hide reads in v1 — which is exactly the gap if hiding `.env` is a
requirement, and makes the live backend pair **bwrap + Seatbelt**, not
Landlock + Seatbelt.

Our plan's recommendation ("first ship opt-in shell write protection, not a new
security framework") remains the right *first release*. §5 is the argument for
what comes after it, and for not describing write protection as a chroot.

## 5b. "Per call" is native to these backends — and it is the *only* model that
## can express our sharing

This settles the question that decides whether the per-component approach in
[SANDBOX.md](SANDBOX.md) could have worked.

- **The mechanism is per spawned process, and that is not a limitation.**
  codex resolves policy per spawn (`SandboxTransformRequest` carries
  `sandbox_policy_cwd` per transform), gemini's interface is literally
  `prepareCommand(req: SandboxRequest)`, and codex's `seatbelt_daemon.rs` is
  about protecting daemon *sockets*, not a policy daemon — none of them run a
  persistent sandbox. Launch path: compute the policy → exec the command
  through the wrapper (`bwrap <args> …`, `sandbox-exec -p <profile> …`) →
  namespaces/rules are installed → `exec` the command. Every invocation
  carries its own restriction.
- **A component-level restriction cannot be re-scoped once the process is
  running.** One `bash` component serves every conversation, and calls carry
  different session ids and `cwd` values. Confining the component at spawn
  fixes one policy for its whole life; there is no way to widen or narrow it
  per call. That is why SANDBOX.md's spawn-time thesis had to be withdrawn,
  and why per-command is not a compromise but the requirement.

The happy accident: this is **the same shape as the locks gate** — per call,
keyed to the conversation's workspace, resolved fresh at dispatch. The machinery
already exists; the sandbox adds a second, kernel-backed enforcement point to a
policy boundary we already compute.

## 6. Read confinement is a *second* mechanism — a launcher cannot cover `.env`

Hiding `.env` is a reasonable goal: the clone sets `NIF_OPENAI_API_KEY` in
`.env`, and today any command can read it. But the read surface is not one
shape, and this is the finding that constrains the design.

A launcher confines **processes**. Enumerating what can read a file:

| Class | Examples | Launcher covers? |
|---|---|---|
| Shell commands and their children | `bash cat .env`, a build script | **yes** — the whole subtree inherits the restriction |
| Components that *shell out* to read | `grep` (runs `rg`), `git`, `lsp` (language servers) | **yes**, if they exec through the launcher |
| Components that read **in-process** | `edit` (`read`/`write`/`replace_across`/`undo_last_edit`), `skills`, `repomap`, `observe`, `fetch`, `builder` | **no** — the component's own process opens the file; there is no child to wrap |

Measured on the current tree (in-process read/walk call sites): `edit` 7,
`lsp` 7, `skills` 6, `fetch` 4, `repomap` 3, `observe` 2, `git` 2, `builder` 2,
`grep` 0. Most of those read the path the model asked for.

So hiding a secret file is **two enforcements with different trust properties**:

1. **Kernel-enforced** (launcher): `bash` + descendants, and any component that
   execs through it. Strong — the syscall fails.
2. **Component-checked** (advisory): in-process readers consult a deny list
   before opening. **Not** kernel-enforced; a component that forgets it leaks,
   exactly as a tool that forgets `x-harness.writes` escapes the locks gate.

Design consequences, stated now so PR 1 is not overread:

- The read-deny list must be **data** (boot config or a per-workspace
  declaration), never a hardcoded `.env` list inside a shared component — the
  AGENTS.md language-agnostic rule generalizes to secrets.
- SANDBOX-PLAN §1 currently says "Filesystem reads: unrestricted; this does not
  protect secrets stored in readable files", and its PR 1 explicitly defers read
  protection. If `.env` hiding is wanted, that is a **separate increment**, and
  one that needs the component-side seam — not a bigger launcher.
- It also means the honest claim stays narrow: a launcher makes `.env`
  unreachable to *shells*; making it unreachable to *every* component is a
  whole-harness read-visibility problem, sibling to the locks gate's known gap
  (paths outside the gate are ungoverned).

The harness itself still reads `.env` at boot — that is the parent process, and
no launcher or deny list touches it. Hiding must therefore mean "hidden from
agent-invoked work", not "removed from the system".

## 6a. Decision: the read seam is worth having — but it is *scope*, not a deny list

**Decided:** we do want the component-side seam. `edit`'s `read` is the tool the
model would reach for, so refusing that one file at that one tool is a real,
useful outcome. The threat model is explicit: **stop the LLM from obtaining
`.env` through a tool call.** A component that *rewrites other components* to
remove the check is out of scope and unprotectable — the agent already owns the
source tree, and pretending otherwise would be the sort of overbroad claim
SANDBOX.md was withdrawn for.

**The sharper framing, and it is not a deny list.** Rather than a list of
forbidden files, each tool declares **the path scope it operates in**, and core
enforces the boundary. Most read tools already point at the conversation
workspace, so this is a declaration of what is already the intent — and the
harness, not the component, gets the final word:

```json
{"x-harness": {
   "reads": {"pathFields": ["path"]},
   "writes": {"paths": ["path"]}
}}
```

That single shape covers both halves of this document: the same resolution that
feeds `lock_acquire` also decides whether a read is in bounds, and a deny entry
(`.env`, `~/.ssh`, a deployment token) becomes just a *narrower* scope the
allowances cannot re-open. One policy language, two enforcement points.

**The seam already half-exists — core resolves, but does not check.**
`applyWorkspace` (`core/dispatch.nim`) resolves every declared path field against
the conversation workspace (including `cwdField`, deliberately workspace-relative
"so it can bound the pathFields it is paired with"), and
`injectWorkspaceContext` hands components `__workspace {root, roots}`. The locks
component already refuses with `E_WRITE_OUTSIDE` when a write claim leaves that
set. What is missing is the *read* half and the fail-closed half:

| Piece | State today |
|---|---|
| Resolve declared path args against the workspace | **exists** — `applyWorkspace` |
| Tell the component its workspace set | **exists** — `__workspace` |
| Refuse a *write* outside it | **exists** — `locks`, `E_WRITE_OUTSIDE` |
| Declare a tool's *read* scope | **absent** — no `reads` key anywhere |
| Refuse a *read* outside declared scope in core | **absent** — resolution is not containment |

That last row is the actual gap, and it is a small one: `applyWorkspace`
currently *rewrites* a relative path into an absolute one and never asks whether
the result still belongs to the conversation. An absolute path passes through
unchanged. So `read /somewhere/.env` and a relative reach out of the tree are
today both permitted, for every tool.

**Design rules for the increment:**

- **Fail closed by default.** A tool that declares no scope is the opaque case,
  exactly as with `writes` — the conservative default, so a forgotten key loses
  no protection. (This is the property that makes the seam trustworthy despite
  being component-side.)
- **Names add to the allowance; none subtract.** `~/.ssh`, `.env` and the
  harness's own `NIF_ROOT` control state sit *outside* the conversation
  workspace, so a workspace-bounded scope excludes them without a deny list —
  deny entries only matter for secrets that legitimately live inside a project
  tree (a checked-in `test.env`, fixture credentials). Keep those declarative
  and let the operator own them; never hardcode a filename in a shared
  component (AGENTS.md, language-agnostic core — generalized to secrets).
- **Honesty about what it is.** A path check is cooperative, like `writes`: it
  compares resolved strings and cannot defend against a symlink swapped between
  the check and the open, nor against a component that ignores its scope. Both
  limits are already recorded for the write gate and apply verbatim.
- **It does not replace the launcher.** This stops *our tools*; a shell command
  has no declaration to honor, which is why `bash` still needs the kernel
  backend. The two are complementary, not alternatives.

Confirming the loop, so the boundary is visibly closed: today a command can read
`.env` directly **and** a tool call can read it in-process. The launcher closes
the first, this seam closes the second, and neither claims to stop the agent
from editing the components themselves.

## 7. The locks connection — the claim is already the policy

Yes, and the fit is closer than it first looks. `WRITE-ARBITRATION.md` computes,
per dispatching call, **the exact path set a tool declares it will touch**
(`x-harness.writes` → resolved paths, or a subtree claim; wildcards folded to
their base directory). That is a write-root request in everything but name.

The two mechanisms are the same boundary at different strengths:

| | `locks` (shipped) | sandbox launcher (proposed) |
|---|---|---|
| Enforcement | **cooperative** — a refusal, via the dispatch gate | **kernel** — the syscall fails |
| Reaches | only calls that go through dispatch | every child process, transitively |
| Covers fabric native I/O, plugin installs, direct exec | no (documented) | yes |
| Cost | one bus round trip, ~1.5 ms | process spawn + backend |

That complementarity is the useful part. WRITE-ARBITRATION.md is explicit that
locks are advisory and cannot cover paths outside the gate; a kernel backend is
exactly what gives the same boundary teeth for the paths we already admit we
miss. And the data flow is nearly free: the resolved claim set is already
computed per call, so a guarded launch could take its writable set from the same
resolution that feeds `lock_acquire` — one source of truth, two enforcement
points, no second policy language.

Two honest limits, so this is not oversold:

- **Scope.** The lock set is per *call* and derived from the model's arguments.
  A sandbox needs a per *launch* root. The conversation workspace is the stable
  root; the claim subset is a refinement. It also must not silently *narrow* a
  legitimate command — an over-narrow launch breaks builds.
- **Direction of failure.** A lock refusal is a polite error the model can retry
  around. A sandbox denial is a failing syscall inside a command, often
  mid-build. Over-claiming in locks costs a retry; over-claiming in a sandbox
  costs a confusing `EPERM`. The conservative "over-claim is safe" rule the
  locks work adopted does **not** transfer unchanged.

## 8. Recommendation and open questions

Keep SANDBOX-PLAN's shape: opt-in, fail-closed, per-command, workspace-rooted,
honest reporting, no fallback. Add from this survey:

1. **Backend pair is bwrap + Seatbelt, not Landlock + Seatbelt, once read
   confinement is a goal.** The plan picked Landlock + Seatbelt partly to avoid
   a wrapper and a backend-selection layer; §5 shows that buys write-only
   protection. Landlock can stay as an opportunistic Linux backend only if it
   plainly reports that reads are unconfined — but then two Linux modes exist
   and the "two backends" simplicity argument is gone anyway. The plan's own §8
   licenses this re-comparison, and bwrap's user-namespace prerequisite (probe
   and refuse, as codex does) is the cost to accept explicitly.
2. **Write the NATS-loopback paragraph into the plan** (§4): the confined shell
   has no bus, and that closes the component-bypass path rather than only
   preventing exfiltration.
3. **Split read confinement into its own increment, with its own mechanism**
   (§6, §6a — decided). A launcher covers `bash` and shell-outs; in-process
   readers need the declared-scope seam in core. The increment is: add
   `x-harness.reads`, and make `applyWorkspace` *contain* rather than merely
   *resolve* — fail closed for a tool that declares no scope, so the enforcement
   lives in core and the component cannot opt out by omission.
4. **State the reachable-set goal as a separate milestone** from write
   protection, so "chroot" is not promised by a write-only release.

Open questions this survey does not settle:

- **Scales and paths.** The containment check compares resolved strings. What
  exactly is allowed — the workspace root, the workspace set (worktrees and
  sibling checkouts, per `workspaceRootsFor`), plus declared extras? And does a
  *read* scope need `cwdField` bounding the same way `writes` does?
- **Who owns the in-tree deny entries.** A project that legitimately keeps
  fixture credentials needs an operator-owned place to name them; that is a
  config decision, not a code one, and it must not become a hardcoded list.
- Does the Landlock ABI on our target machines permit read rules, and is the
  ergonomics acceptable if so? Only relevant if Landlock is kept at all.
- Can a guarded launch inherit the dispatch-time claim set without core growing
  a privileged execution API? SANDBOX-PLAN §5 warns against exactly that; a
  per-launch request through the existing approval transport is the alternative.
- Should a confined shell be *allowed* a bus client at all (a narrow
  publish-only principal), or should confinement always mean "no bus"? The
  former is the hostile-code project's problem.
- Do we want `strict`-style read profiles (gemini) or only the two-mode model
  (codex)? Our plan deliberately has two configuration states; read profiles
  would add a third axis — and the declared read scope is a fourth kind of
  policy data to keep declarative.

