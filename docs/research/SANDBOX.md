# Sandbox — component-level confinement for Niffler

Status: **proposal** (nothing here is implemented). Explored 2026-09-12 against
refreshed local checkouts of dsh, CodeWhale, DeepSeek-Reasonix, pi, OpenHands
(Agent Canvas), OpenCode (+ its archived Go original), and the Boxlite project
notes. Companions: [DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) §5 (dsh's
Landlock launcher) and its steal #3, [CODEWHALE.md](CODEWHALE.md) (their
sandbox mapping), [DSH-STEAL.md](DSH-STEAL.md) §1 (the sieve used below).

The recommendation in one sentence: **confine every component at the single
point Niffler already spawns them — `core/supervisor.nim:150` — using
Seatbelt on macOS and Landlock on Linux, with dsh's honesty semantics
(probe, report the mode actually active, fail closed only when required).**
Not per-command wrapping, not containers by default.

## 0. The problem shape

Today bash is raw and no sandbox exists anywhere in the harness
(DEEPSEEK-HARNESS.md §5, *Niffler* column). The approval gate is a UX
control, not isolation — OpenCode's SECURITY.md states the industry
consensus most blunty: "OpenCode does **not** sandbox the agent. The
permission system exists as a UX feature... not designed to provide security
isolation," and it lists sandbox escapes as out of scope for exactly that
reason. CodeWhale opens its threat model with the same rule: "an approval is
not a sandbox."

Niffler's architecture is the gift here. Every capability is already a child
Unix process spawned by one supervisor; the only doorway to a confined
component is NATS; the model has no path to a process that is not a
component's child. The process topology is waiting to become the security
model.

## 1. Why spawn-time beats the alternatives in Niffler

- **Inheritance makes per-component equal per-command, for free.** Landlock,
  Seatbelt and bwrap restrictions all survive `execve`: confining the `bash`
  component confines every command the agent ever runs; confining `git`
  confines every git invocation; a compromised component stays inside the
  wall. dsh/CodeWhale/Reasonix wrap *commands* because their shell tool is
  the seam they have; Niffler's unit of deployment is the component process,
  which is strictly better — `bash` is one component among many, and there
  is no second exec path to forget to wrap.
- **The bus becomes the boundary.** A confined component can reach NATS
  (localhost:4222) plus what its policy allows — nothing else. Capability =
  component = process = policy.
- **One choke point, one policy surface.** The supervisor assembles every
  child command in one place (it already prefixes `setpriv --pdeathsig TERM`
  there, `core/supervisor.nim:139-150`); the sandbox launcher slots into the
  same assembly. Session runners, spawned components, and later children all
  inherit.

## 2. Policy model

One `SandboxPolicy` per component, declared in the manifest
(`x-harness.sandbox`) and applied by the supervisor at spawn:

```json
{
  "mode": "read-only | workspace-write | danger-full-access",
  "network": "none | local | open",
  "writableRoots": ["/etc/myapp"],
  "denyRead": ["~/.ssh", "~/.aws"],
  "required": false
}
```

- `mode` follows dsh's vocabulary (`docs/subsystems/sandbox.md`): FS effects
  only; `read-only` permits required sinks (`/dev/null`, temp);
  `workspace-write` adds the conversation workspace plus the backend's temp
  area; `danger-full-access` bypasses confinement and is reported as such.
- Defaults per component kind (tunable, product decision): bash
  `workspace-write` + `network: open`; `edit`/`write` `workspace-write` +
  `none`; `git` `workspace-write` + `local`; `grep`/`files` `read-only`;
  `fetch` temp-write + `open`; `llm`/`provider` `open` network, no workspace
  write; `store`/`observe` data-dir write + `local`. NATS reachability is
  always permitted (`local`).
- **Spawn may narrow, never widen.** A session (or a subagent posture —
  this composes with the read-only clamps discussed in
  [ESCALATION.md](ESCALATION.md) §4.6) can clamp a component's policy down;
  widening past the manifest requires the escape flow (§4).
- `required: true` flips that component from best-effort to fail-closed.

## 3. Platform matrix

| | macOS | Linux |
|---|---|---|
| primitive | **Seatbelt** — generate a profile per policy, spawn via `/usr/bin/sandbox-exec -f` | **Landlock** — syscalls 444–446 + `PR_SET_NO_NEW_PRIVS`, applied by a tiny launcher that installs the ruleset on itself then `exec`s the component (the dsh `native/landlock-run` pattern: "installs the ruleset *on itself* then `exec`s — confinement inherits across `execve`, invoker stays free") |
| dependencies | none (sandbox-exec ships with macOS) | none — pure syscalls, kernel ≥ 5.13 (2021); no bwrap install, no userns policy fight |
| FS | broad read; writes limited by mode; **denyRead works** (profile deny rules) | same via path rules; **denyRead does not work** — Landlock is allowlist-only (a broad-read rule for `/` cannot subtract `~/.ssh`); report `denyRead: unsupported-by-backend` honestly |
| network | deny `network-outbound` except localhost:4222 + approved endpoints; per-host allows possible | Landlock TCP bind/connect needs kernel 6.7+ (ABI 4); below that, `bwrap --unshare-net` **if** unprivileged userns works — probe it (Ubuntu 23.10+/24.04 restrict userns via AppArmor; this genuinely fails on stock systems). Otherwise report the truth: network restriction unavailable |
| probe | run a minimal profile first (CodeWhale's functional probe; dsh: "actually restricting is the only honest signal", `main.c:273`) | create a test ruleset and restrict a child `/bin/true`; functional, not version-gated |
| required + failure | child not started, exit 125, spawn returns the error — the turn keeps working with other tools | same |

Command assembly in the supervisor becomes
`niffler-sandbox --policy <json> -- setpriv --pdeathsig TERM <binary> …`
(wrapper first so it execs down the chain; PDEATHSIG survives `execve`).
The launcher is ~150 lines of Nim; NATS itself (`core/niffler.nim:55`) stays
unconfined infrastructure in v1 — it is not agent-reachable surface.

## 4. Escapes — grants beyond the workspace

Inevitable: a deploy needs to write `/etc/myapp/nginx.conf`, a build needs
`~/.cache/ccache`, a login flow needs `~/.config/gh`. The design principle
is **narrow grants, not binary escapes**: rerun under a *widened policy*,
one-shot by default.

1. **Denial teaches.** A confined child hits `EACCES`/`EPERM` (or a
   `denyRead` path, or a blocked endpoint); the component returns a
   structured denial result naming what was refused and the exact
   `grant {writableRoots?, network?, denyRead?}` argument that would allow a
   rerun. This is dsh's capability-advertisement-by-shape
   (`tool-bash/src/index.ts:258`) adapted to Niffler's frozen prefix: the
   schema never mutates mid-conversation — the *denial text* carries the
   capability, as an append-only tool result.
2. **Approval is human by default.** The grant request routes through the
   existing approval gate. Fail-closed when no client is attached (Reasonix's
   `EscapeApprover` — "Nil means fail closed",
   `internal/sandbox/escape.go`). "An approval is not a sandbox" still holds:
   the approval authorizes a *policy*, enforcement stays in the kernel.
3. **Scopes.** This-command (default: one-shot rerun under the widened
   policy) / this-conversation (rides `core/approval.nim:40`'s persisted
   per-conversation auto-approve — already wired, `:243-244`) / this-project
   (persisted as a `sandboxgrant` store record, single-writer: core). The UI
   labels a widened-to-`none` rerun as what it is — an escape — Reasonix's
   precedent, but the preferred offer is always the minimal widen.
4. **No self-serve widening.** The model can *request*; it can never grant.
   `required` policies and the no-client path fail closed; only an explicit
   human (or a pre-granted project rule) opens a hole, and the hole is as
   small as the request.

Per-host network allowlists ("allow api.github.com, nothing else") are a
macOS-only luxury (Seatbelt rules); on Linux the network toggle is binary
unless traffic goes through an allowlisting proxy component — a possible
follow-up, honestly out of scope here.

## 5. Reporting and honesty

- `doctor` and `status` report the **actually active** mode per component:
  `seatbelt`, `landlock`, `landlock-net`, `bwrap`, `none` — plus
  `denyRead: supported|unsupported-by-backend`. Never claim confinement that
  is not real: CodeWhale ships a seccomp module it refuses to advertise
  because it is not wired into launch; dsh reports `partial` on Windows.
- `NIF_SANDBOX=off | best-effort | required` (default **best-effort**),
  overridable per component in the manifest. Best-effort degrades loudly
  (spawn result + doctor show it); `required` refuses to start the child.
- The turn-context suffix and tool results may *mention* active confinement;
  they never claim it when the mode is `none`.

## 6. Sieve

| invariant | check |
|---|---|
| Peers, not frameworks | the launcher is enforcement, not capability — capabilities stay components. It sits beside the existing `setpriv` prefix in the supervisor, not beside it as a new subsystem |
| Prompt-cache discipline | policies never touch the prefix; denial/grant material is append-only history and tool results; no mid-conversation schema mutation (that is why advertisement rides denial text, not tool schemas) |
| Store single-writer | `sandboxgrant` records owned by core (it owns approvals today); supervisor keeps its child table as now |
| No `asyncdispatch` | the launcher is a blocking exec; policy application is synchronous at spawn |
| Fail-closed where correctness lives | `required` policies, escapes with no client, `denyRead` on backends that cannot honor it (refuse the grant rather than pretend) |
| Fail-open where convenience lives | default best-effort posture degrades with a report; the harness never crashes because a probe failed |

## 7. Landscape and steal list

| project | posture | steal |
|---|---|---|
| dsh | deepest kernel sandbox: Landlock via raw-syscall launcher, Linux bwrap, macOS Seatbelt, Windows ACL restricted-token; modes; per-shell consumers; capability advertisement only when confinement is active; fail-closed shared escalation (`sandbox/src/escalation.ts:8`) | the launcher pattern + exit 125; modes vocabulary; advertisement-only-when-active; "actually restricting is the only honest signal" (`main.c:273`) |
| CodeWhale | Seatbelt (auto-probe) + opt-in bwrap; honest `none` reporting; unwired seccomp **not advertised**; external backends (OpenSandbox service, ShannonNet signed-capability workers) | the functional probe; reporting table (`macos-seatbelt`/`linux-bwrap`/`none`); "an approval is not a sandbox" threat-model framing |
| Reasonix | Go `internal/sandbox`: bwrap (Linux, ephemeral tmpfs), Seatbelt (darwin); **fail-closed escape approver** — nil approver = fail closed, one-shot unconfined rerun, session-scoped remember (`internal/sandbox/escape.go`) | the escape-approval flow behind §4; the install-hint error message (`sandbox.go:87`) |
| pi | core runs all-permissions; isolation as opt-in patterns: Gondolin QEMU micro-VM extension routing built-in tools, plain Docker, OpenShell, Docker Sandboxes; example extension over `@anthropic-ai/sandbox-runtime` | the containerization doc as the hard-mode pattern; the extension-routed-tools shape for a future `vm` component |
| OpenHands | whole-process: Docker sandbox mode is the *recommended* install (all-in-one agent-server image, `PROJECTS_PATH` mount); self-hosting treats the VM as the boundary; DefenseClaw governance alongside | the "sandboxed is the default recommendation" product posture; the honest Option-1 warning |
| OpenCode | explicitly none; "the permission system is not a sandbox" in SECURITY.md | the written trust boundary we agree with — and the reason approvals alone are not enough |
| Boxlite (`boxlite-ai/boxlite`) | embeddable micro-VM ("light enough to embed on your laptop... The SQLite of sandbox"), hardware isolation, no daemon; early/closed as of 2026-09 | watchlist: if it opens, it is the drop-in upgrade for the hard mode — hardware isolation without Docker or QEMU |
| Apple Containerization (`container`) | Linux micro-VMs on macOS 26/Apple Silicon | the future easy hard mode on macOS; requires OS + arch not everyone has |
| Codex CLI *(from memory — not verified locally)* | native Landlock + Seatbelt in Rust | a second reference implementation of the same platform pair |

## 8. What not to do

- Per-command wrapping only — non-bash components stay naked and the model
  cannot tell.
- Setuid helpers (firejail's track record) or root-required confinement.
- Silent degradation to unconfined — the one dishonest failure mode.
- Promising network isolation on pre-6.7 kernels without bwrap.
- Making Docker/micro-VM the default (breaks "clone and run on a laptop").
- Letting the model widen its own policy without an approval.

## 9. Scope

**v1** — `niffler-sandbox` launcher (Landlock + Seatbelt paths, functional
probe, exit 125), `x-harness.sandbox` in manifests, supervisor command
assembly, `NIF_SANDBOX` envs, `doctor`/`status` reporting. Zero new
dependencies on either platform.

**v1.1** — escapes (§4): denial notices, grant arguments, approval routing,
`sandboxgrant` records, `denyRead` where the backend supports it.

**v2** — hard-mode patterns: documented Docker profile, then a `vm`/`remote`
component (Gondolin-style routing, Apple `container`, Boxlite, OpenSandbox)
behind the same spawn seam.

Tests worth writing on day one: probe matrix (old kernels, Ubuntu userns
denials, missing sandbox-exec), honest-degradation assertions (report says
`none` when it is none), inheritance checks (confined component's children
are confined), and an escape flow that fails closed with no client.

## 10. Open questions

- bash's default network posture (`open` for usability vs `local` + grant
  flow) — product decision, listed as tunable in §2.
- Seatbelt: generated per-policy profiles vs a small static set per mode.
- Grant persistence UX: does a project-level `sandboxgrant` survive in the
  store or live in a config file the user can review in git?
- Landlock handled-access sets: v1 handles FS writes only (reads unconfined
  by design); when to opt into handling more.
- Windows: dsh's ACL restricted-token backend is the reference when someone
  needs it.
