# SANDBOX-PLAN — implementing spawn-time component confinement

Status: **plan** for branch `feat/sandbox` (worktree `~/git/niffler-sandbox`).
Companion to [SANDBOX.md](SANDBOX.md) — the proposal; this document is the
build order. All code references are against `de4b1bd`.

## 0. Ground truth — the hooks this plan attaches to

| fact | where |
|---|---|
| Every component child is spawned by one supervisor; the command is assembled as `setpriv --pdeathsig TERM <binary> <args> … >> log` and run via `/bin/sh -c` | `core/supervisor.nim:139-152` (`startChild`) |
| `Child` fields today: `name, instance, binary, args, policy (= **restart** policy), wanted`; children added via `addChild` | `core/supervisor.nim:158-167` |
| Boot components come from `manifest.yaml` (`{name, build, binary, autostart, required, restart, replicas}`) via `loadManifest` | `core/niffler.nim:184-192`, boot loop `:405-420` |
| Components spawned by the agent (`core.spawn`) are **approval-gated** and persisted in the store; after a harness restart they are restored from the store record (`{binary, replicas, policy}`) | `core/dispatch.nim:181,186`; restore loop `core/niffler.nim:500-515` |
| Approval machinery with persisted per-conversation auto-approve ("grant without asking any client") exists | `core/approval.nim:40,243-244`; turn-tagged approvals `core/conversation.nim:818` |
| Binaries build to `var/bin/*` via nimble tasks | `niffler.nimble:23-30` |
| Test conventions: `tests/t_*.nim` with shared helpers; `t_autostart.nim` and `t_bash.nim` are the nearest references | `tests/` |

Three design decisions SANDBOX.md left open are **locked here**:

1. **Policy transport**: the supervisor writes each child's policy JSON to
   `var/run/sandbox/<name>-<instance>.json` and passes
   `--policy-file <path>` to the launcher. No argv quoting of JSON, nothing
   sensitive in the environment, and the path doubles as the audit record.
2. **Naming collision**: `Child.policy` already means *restart* policy. In
   M2 it is renamed to `Child.restart`; the new field is
   `Child.sandbox: SandboxPolicy`. Doing this in the same milestone that
   introduces the second "policy" avoids a permanent trap.
3. **Escapes are core-mediated.** A confined component cannot grant its
   children rights it does not have itself — Landlock/Seatbelt walls only
   tighten down the tree. The one unconfined process is core, so widened
   one-shot runs (M4) execute through a new hidden core tool
   `sandbox.exec {grant, argv, timeoutMs}` (approval-gated), never by the
   component re-exec'ing itself. This keeps "only core can build a wider
   wall, and only after a human said so" literally true.

Resolution algebra (used by M2 and M4): mode order
`none < read-only < workspace-write < danger-full-access`; network order
`none < local < open`; widen = mode/network step up + `writableRoots` union;
clamp = step down + roots intersection + `denyRead` preserved; a widen that
would cross into `danger-full-access` is reported as an *escape* in the
approval text. Active-mode report enum: `none | seatbelt | landlock |
landlock-net | bwrap | bwrap-net`, plus
`denyRead: supported | unsupported-by-backend`.

## 1. M1 — the launcher (`sandbox/`, no behavior change yet)

New files:

- `sandbox/sandbox.nim` — `SandboxPolicy` object (`mode`, `network`,
  `writableRoots`, `denyRead`, `required`), JSON parse/serialize, the
  clamp/widen algebra above, active-mode report strings. Shared by launcher
  and core (compiled into both).
- `sandbox/landlock.nim` — ABI probe
  (`landlock_create_ruleset` with `LANDLOCK_CREATE_RULESET_VERSION`), ruleset
  build for the FS part of the policy (handled accesses = the **write** set
  only in v1 — reads stay unconfined by design, per SANDBOX.md §10), path
  rules for workspace/temp/`var` per mode, `restrict_self`; returns the
  capability report (TCP network needs ABI ≥ 4 / kernel ≥ 6.7 — report
  `unsupported` below, never fail the launch unless `required`).
- `sandbox/seatbelt.nim` — profile generator per policy: allow
  `process-exec*`; broad `file-read*` **minus** `denyRead` denies (Seatbelt
  can subtract; report `supported`); `file-write*` per mode + roots + temp;
  `network-outbound` per policy (always allow localhost:4222 and the NATS
  monitor port); functional probe first (run a minimal profile on
  `/bin/true`, CodeWhale's pattern).
- `sandbox/niffler_sandbox.nim` — the launcher main: `--policy-file <path>`,
  `--check` (apply, print the active-mode JSON, exit — for tests and
  doctor), otherwise apply and `execvp` the remaining argv. Fail path:
  policy `required` + application failure → stderr line + **exit 125**
  (dsh's honest code); best-effort + failure → stderr warning + exec
  unconfined (the supervisor's report still shows the truth from the
  probe result the launcher prints to its log).
- `niffler.nimble` — build task → `var/bin/niffler-sandbox` (beside the
  existing tasks, `niffler.nimble:23-30`).
- `sandbox/bwrap.nim` — stub in M1 (returns `unsupported`), implemented in
  M4-adjacent work: userns probe + `--unshare-net` composition for
  `network: none` when Landlock lacks ABI 4. The Ubuntu 24.04 AppArmor userns
  restriction is the reason this is a *fallback with a probe*, never an
  assumption.

Acceptance: `niffler-sandbox --check --policy-file …` prints the real
active mode on both platforms; `required` + impossible policy exits 125;
policy parse/clamp/widen unit tests pass; landlock tests skip cleanly on
macOS and vice versa.

## 2. M2 — supervisor, manifest, spawn, doctor (the flip to default-on)

- `core/supervisor.nim` — `Child` gains `sandbox: SandboxPolicy` (and
  `policy` → `restart` rename); `startChild` command assembly becomes
  `setpriv --pdeathsig TERM niffler-sandbox --policy-file <path> -- <binary> …`
  whenever the resolved policy is not `danger-full-access`/off; the resolved
  active mode is stored on the child for status. Policy JSON written to
  `var/run/sandbox/` before spawn.
- `manifest.yaml` — optional `sandbox:` key per component entry; plus a
  built-in per-kind defaults table in core (bash `workspace-write` +
  `network: open`, `edit`/`write` `workspace-write` + `none`, `git`
  `workspace-write` + `local`, `grep`/`files` `read-only`, `fetch`
  temp + `open`, `llm`/`provider` `open` + no workspace write,
  `store`/`observe` data-dir + `local`) so components absent from the
  manifest still get sane walls.
- `NIF_SANDBOX=off | best-effort | required` (default `best-effort`),
  per-component override in the manifest wins.
- `core.spawn` (`core/dispatch.nim:186`) — schema gains optional `sandbox`
  (narrowing-only for manifest components; full policy for fresh
  agent-spawned components — the spawn approval the human already signs now
  covers the walls too); the policy is stored in the component's store
  record so the restore loop (`core/niffler.nim:500-515`) re-adds children
  **with their walls**.
- `doctor` + `status` — per running child:
  `{sandbox-active, denyRead, network}`; a child running unconfined under a
  non-off policy reports `none` loudly (the one dishonest failure mode is
  reporting, not enforcement).
- Docs: `docs/MANUAL.md` env table + a Sandbox section; `AGENTS.md` gains
  the invariant line: *every agent-reachable component runs under its
  declared sandbox policy; degradation is reported, never silent; only core
  can widen, only after approval.*

Acceptance: fresh boot on Linux and macOS → `doctor` lists per-component
active modes; a `required` component with a failing probe refuses to start
while the harness keeps serving; restored components keep their policies;
`NIF_SANDBOX=off` returns today's behavior exactly.

## 3. M3 — tests (folded into M1/M2 PRs, listed separately for review)

`tests/t_sandbox.nim`, `tests/t_sandbox_supervisor.nim`:

- policy parse + clamp/widen algebra (property-ish table cases);
- launcher `--check` on both platforms (skip-if-unsupported, mirroring the
  runtime's honesty in the test suite);
- `required` + impossible policy → exit 125, child not started, harness
  alive;
- inheritance: confined `/bin/sh -c 'touch /etc/sandbox-probe'` fails,
  workspace write succeeds, NATS port still reachable (a confined bash must
  not break the bus);
- restore path preserves `sandbox` across a simulated harness restart;
- `doctor` reports `none` when the launcher binary is missing.

## 4. M4 — escapes (v1.1, the grant flow)

- **Denial teaches** (`components/bash/main.nim` first, then `edit`): when a
  child fails with `EACCES`/`EPERM` and a sandbox was active, the tool
  result becomes
  `{sandboxDenied: {op, paths, grant: {writableRoots?/network?}}}` —
  append-only history, the frozen prefix is never touched (this is dsh's
  capability-advertisement-by-shape adapted to Niffler: the *denial text*
  carries the capability, not a mutated schema).
- **New hidden core tool** `sandbox.exec {grant, argv, timeoutMs}` —
  approval-gated like `spawn`; the supervisor runs a one-shot child under
  `base + grant` and returns `{exitCode, stdout(truncated)}` to the calling
  component. Only core can widen; the component cannot (see locked
  decision 3).
- **Scopes**: one-shot (default) / this-conversation (rides
  `core/approval.nim:40` per-conversation auto-approve) / this-project
  (new store record kind `sandboxgrant`, single-writer: core; policy
  resolution consults it). No client attached → fail closed (Reasonix's
  nil-approver rule). `danger-full-access` widen renders as an explicit
  *escape* in the approval text.
- `denyRead` grants for one-shot reads where the backend supports it;
  `unsupported-by-backend` refusals stay honest.

Acceptance: mock-approval tests (allow → one-shot succeeds, nothing
persists; deny → tool returns the denial; no client → fail closed);
conversation-scope auto-approve round trip; a project grant survives
restart; the escape approval text always names the exact paths/ports.

## 5. M5 — hard modes (v2, not in this branch's first PRs)

Documented Docker profile; `vm`/`remote` component sketch behind the same
spawn seam (Gondolin-style routing, Apple `container`, Boxlite watchlist,
OpenSandbox backend); Windows ACL restricted-token (dsh's
`sandbox-windows-acl` as reference).

## 6. Sequencing and PR shape

| PR | contents | size |
|---|---|---|
| 1 | M1 launcher + `sandbox.nim` + M3 launcher tests — **no supervisor change, zero boot-behavior risk**, mergeable independently | 2-3 d |
| 2 | M2 supervisor/manifest/spawn/doctor + M3 supervisor tests — the default-on flip | ~2 d |
| 3 | M4 escapes + tests | 3-4 d |

## 7. Risks and known sharp edges

- `Child.policy` rename ripples into restore/autostart code — mechanical,
  do it in PR 2 with the sandbox field.
- Log redirection (`>> logPath` in the `sh -c` assembly) happens **outside**
  the launcher: the fd is open before confinement, and Landlock checks paths
  at open time, so inherited fds keep working — assert this in tests rather
  than assume it.
- Components write nothing to disk directly (persistence is NATS → store),
  which is why FS walls are cheap for Niffler where they would break other
  harnesses; keep it that way — a component that starts writing local state
  files needs its policy reviewed, not an exception.
- `gh`/`ssh-agent`-style legitimate odd paths will generate real grant
  friction in dogfooding — that friction is the feature; watch it and tune
  project grants rather than widening defaults.
- sandbox-exec is semi-internal Apple surface; if it ever breaks, the
  launcher's probe/report design means the failure is visible, and the
  hard-mode track (Containerization/Boxlite) is the replacement path.

## 8. Definition of done

Fresh clone on Ubuntu 24.04 and on macOS: `nimble build`, boot, `doctor`
lists per-component active modes (never silently `none`); bash write outside
the workspace fails with a teaching denial; an approved grant rerun succeeds
exactly once; restored components keep their walls; `NIF_SANDBOX=off`
reproduces today's behavior bit-for-bit; `AGENTS.md` states the invariant.
