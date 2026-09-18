# Docs audit — `components/bash/` (Nim, 222 lines: `main.nim` only)

Scope: what the component offers, its one tool and flags, its configuration, and
how `docs/MANUAL.md` covers it. Read-only audit; every claim carries file:line.
Component version `0.1.0` (`components/bash/main.nim:10`). The execution engine
is shared SDK code, so this audit also cites `sdk/niffler/procutil.nim`
(`runCmd`/`capBytes`), which every shelling-out component uses.

## 1. What it offers

`bash` is the bootstrap-shipped classic tool and the agent's normal path to
self-extension: run a shell command via `bash -c`, write source files, then
compile with `builder` and spawn with `core` (`main.nim:1-8`). It is **one
tool**, `bash`, registered through the low-level `comp.tool` API because the
handler needs the raw `__session` context (`main.nim:104-107`, `122`). Every
command runs as the **leader of its own process group**, so a timeout (exit
124) or a cancelled turn (exit 130) kills the whole tree — no orphaned
grandchildren (`sdk/niffler/procutil.nim:60-66`, `97`, `123-132`). Combined
stdout+stderr is captured through a temp file, never a pipe (chatty children
would deadlock) (`procutil.nim:11-14`, `89`), then bounded twice and, when
large, spilled to a file the model pages with `read` (`main.nim:12-21`,
`160-188`). `run_in_background: true` turns the call into a *thin producer*
over the `processes` component: bash never blocks on or owns a long-running
child (`main.nim:131-152`). It is `required: true`, `autostart: true` in the
manifest (`manifest.yaml:22-27`) and one of the three components in
`--minimal` (MANUAL.md:39, 2265). Only `NIF_ROOT` is read from the environment
(`main.nim:31`; the sole `getEnv` call in the file).

## 2. Tools

| Tool | Purpose (doc comment) | `x-harness` flags | Exposure |
|---|---|---|---|
| `bash` | "Run a shell command (bash -c). Fresh shell per call: cd does not persist; pass cwd or use absolute paths. Set run_in_background for long-running commands (servers, watchers): the call returns an id at once and the process keeps running across turns — collect its incremental output with process_poll and stop it with process_kill." (`main.nim:118`) | `approval: "always"`, `timeoutMs: 60000`, `sessionId: true`, `workspace: {cwdField: "cwd"}` (`main.nim:119-120`); **no `effect`** → classified `"write"`; **no `onDemand`/`hidden`** → direct | direct (`main.nim:122`) |

Arguments (`main.nim:108-118`), `required = ["command"]`:

- `command: string` — "The command line to run" (`main.nim:109-110`).
- `timeoutMs: integer` — "Kill after this many ms (default 30000)"
  (`main.nim:111-112`); handler default `30_000` (`main.nim:128`).
- `run_in_background: boolean` — "Start as a background process instead of
  blocking: returns an id immediately (no timeout applies)…" (`main.nim:113-117`).
- `cwd: string` — "Working directory (default: workspace)" (`main.nim:116-117`);
  the runner injects the conversation workspace when absent (`main.nim:129`,
  `core/dispatch.nim:1437-1446`).

Private, runner-injected (not in the schema): `__session.session`
(`main.nim:123`; `core/dispatch.nim:1574-1581`) — present only because the
schema sets `sessionId: true`; a direct `cli` caller legitimately sees `""`
(`core/dispatch.nim:1576-1580`, docs/WIRE.md:315-316). Handler-side aliases:
none. No `process_start`-style `label` passes through, so a background job is
labelled by `processes` itself (`main.nim:142-146`).

Result shape (`main.nim:163-190`): `{text, exit_code, cancelled}` always;
`spill {path, bytes, lines}` only when output exceeded the transcript cap;
`{id, label, …}` (the `process_start` reply, plus a `text` line) when
`run_in_background`; `{error: "[E_BACKGROUND] …"}` when `processes` is
unreachable (`main.nim:147-152`).

## 3. Configuration

- **Env vars — exactly one:** `NIF_ROOT` (`main.nim:31`; the only `getEnv`
  call in the file). It decides where spills land: `$NIF_ROOT/var/toolout/`
  when set, else `getTempDir()` (`main.nim:31-32`). Everything else about
  `bash` is a compile-time constant or comes from core.
- **Output caps are constants, not configurable** — this is the biggest
  documentation gap:
  - `maxCaptureBytes = 2_000_000` (`main.nim:12-14`): hard bound on the whole
    capture; beyond it even the spilled file is cut head+tail with a marker
    telling the model to "re-run a narrower command (grep/head/tail/wc)"
    (`main.nim:160-162`).
  - `transcriptCapBytes = 12_000` (`main.nim:16-21`): what rides the
    conversation. Above it the full capture is spilled and the transcript gets
    head+tail plus a pointer line `[full output: <bytes> bytes, <lines> lines →
    <path> — page through it with read (offset/limit)]` (`main.nim:172-186`).
  - The truncation marker text itself is SDK-owned:
    `[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]`
    (`sdk/niffler/procutil.nim:153-166`). There is no `NIF_BASH_*` knob of any
    kind (verified: no other `getEnv`, no config file, no store record).
- **Spill location and lifetime:** `$NIF_ROOT/var/toolout/<session>/` (session
  id sanitized to `[A-Za-z0-9_-]`, `"direct"` for session-less callers)
  (`main.nim:29,33-39`), file name `<pid>-<epoch>-<counter>.out`
  (`main.nim:22-23`, `47-49`). Every spill sweeps files older than **1 hour**
  (TTL, non-fatal on error) (`main.nim:40-45`). If the write fails, `spill`
  is omitted and the transcript just carries the capped head+tail
  (`main.nim:50-51`, `184-186`). The returned `path` is absolute whenever
  `NIF_ROOT` is set, which is why `read` can open it (MANUAL.md:55).
- **Workspace / cwd / shell / env:**
  - Components run with **cwd = `NIF_ROOT`** (MANUAL.md:268), so a bare
    `bash pwd` is always the harness home.
  - Per-conversation `cwd` is *pinned* by core: an existing directory inside
    `NIF_ROOT`, immutable, persisted in the conversation header; core rewrites
    the `cwd` field at dispatch via `x-harness.workspace.cwdField` — empty,
    non-string or `"."` becomes the workspace, a relative value is resolved
    against the workspace, never against the process cwd
    (`core/dispatch.nim:1386-1387`, `1437-1446`; MANUAL.md:558-565).
  - The component turns that into a shell prefix: `cd -- <quoteShell(cwd)> ||
    exit $?` + newline + the command, so a bad cwd fails the call instead of
    silently running elsewhere (`main.nim:154-155`).
  - **Shell is always `bash -c`** with `execvp("bash", …)` on `$PATH`; there is
    no shebang/`sh`/interpreter config and no shell-type knob
    (`procutil.nim:89-100`). The command is wrapped in a subshell
    `( … ) > <tmp> 2>&1` so the redirection covers `;`/`&&` chains; a command
    containing `<<` gets the closing paren on its own line so a heredoc cannot
    swallow it (`procutil.nim:82-89`). stdout **and** stderr are merged
    (`procutil.nim:89`); stdin is inherited from the component (a background
    job instead gets /dev/null from `processes`, MANUAL.md:1041).
  - **Environment: inherited verbatim** from the `bash` process (which core
    spawned with `NIF_ROOT`, `.env` values, etc. — MANUAL.md:268). The
    component adds nothing and strips nothing; there is no per-conversation env
    injection seam. (`.env` is loaded by the SDK at component start,
    MANUAL.md:357-377.)
  - Child fds above stderr are marked `FD_CLOEXEC` before every spawn so the
    component never leaks its own pipes into the agent's commands
    (`procutil.nim:44-59`).
- **Timeout semantics (two different knobs, easy to conflate):** the *call*
  argument `timeoutMs` defaults to `30_000` and kills the process group with
  124 (`main.nim:112`, `128`); the *dispatch* budget is `x-harness.timeoutMs =
  60_000`, which bounds how long core waits for the reply, core default 120 s
  (`main.nim:119`; `core/dispatch.nim:1564-1567`, `151`). The timeout path
  polls `waitpid(WNOHANG)` every 50 ms and owns the kill: SIGTERM to the whole
  group, ~1 s grace, then SIGKILL, then reap (`procutil.nim:108-132`).
- **Cancellation (`cancel.bash`, process group):** a session runner that
  abandons an in-flight dispatch publishes an event envelope
  `cancel.<component> {sessionId, tool, ts}` (`core/dispatch.nim:1299-1306`;
  docs/WIRE.md:87-91, 296-307). Because the component's pump is *blocked inside
  the handler* while a command runs, the kill decision is taken in the wait
  loop: `runCmd` calls the `drainCancels(sessionId)` probe every 50 ms
  (`main.nim:156`, `60-64`; `procutil.nim:119-122`), which non-blockingly
  drains the `cancel.bash` subscription (`main.nim:71-73`, `77-79`). A fresh
  cancel (≤ `cancelFreshSeconds = 30.0`, `main.nim:65`) for this session sets
  the flag → exit **130** with `cancelled: true` (`main.nim:163`, `166`;
  `procutil.nim:132`); a cancel for *another* session is **stashed**, not
  dropped, because that session's request may still be queued behind the
  running command (`main.nim:61-64`, `90-93`). When the queued request is
  finally picked up, `wasCancelled` refuses it **without executing anything**,
  returning a synthetic `(exit 130 — cancelled by request)` result
  (`main.nim:96-102`, `124-126`). Core's side is cooperative: it publishes the
  cancel and waits a short grace for partial bytes
  (`core/dispatch.nim:1277-1288`) — a component that does not answer, or one
  that already finished, simply becomes a normal timeout/cancel
  (docs/WIRE.md:315-319).
- **Approval story:** the tool carries `approval: "always"` (`main.nim:119`),
  so *every* call is gated on a human before it executes, with no per-command
  allowlist and no read-only fast path (`core/dispatch.nim:1556-1563`;
  MANUAL.md:457-485, which lists `bash` first). Bypasses are conversation- or
  process-wide only: `/approvals auto` for one conversation, `NIF_AUTO_APPROVE=1`
  for headless runs, and the per-tool "don't ask again" record
  (MANUAL.md:330, 495-502). With no human reachable the call is **denied**
  (MANUAL.md:480-481). The `run_in_background` path does **not** produce a
  second prompt: bash calls `processes` directly over NATS
  (`main.nim:142`), bypassing core's dispatch-side gate, so the single `bash`
  approval covers the start (inferred from the code path; not executed here).
- **Background jobs vs the `processes` component:** fully documented already
  (MANUAL.md:1033-1083). bash forwards `command`, `workdir` (from `cwd`,
  `main.nim:134`) and the owning `session` (`main.nim:141`) with a 15 s
  request timeout (`main.nim:142`), returns the process id at once, and never
  owns, drains or reaps the child (`main.nim:131-133`, `143-146`). The
  finished job is announced back into the conversation by `processes`
  (MANUAL.md:1055-1065). Failure is explicit: `[E_BACKGROUND] … is the
  processes component running? … run the command synchronously instead`
  (`main.nim:147-152`; MANUAL.md:1082-1083). Documented and verified — but see
  the DELTA about the dispatch budget still applying to the start call.
- **Exit-status reporting:** the transcript gets `(exit N)` first, then an
  explanation appended in three cases: `124 — timed out after <timeoutMs>ms`,
  `130 — cancelled by request`, and `126 — found but not executable; run it
  via an interpreter, e.g. bash ./script.sh` (`main.nim:164-169`). Machine
  fields: `exit_code`, `cancelled` (`code == 130`) (`main.nim:163`). Codes
  originate in the SDK: `WEXITSTATUS` for a normal exit, `128 + WTERMSIG` when
  the command died by its own signal (e.g. 139 = SIGSEGV, 143 = SIGTERM)
  (`procutil.nim:113-116`), `124` timeout / `130` cancel
  (`procutil.nim:132`), `126` when the child could not `chdir` into `cwd`
  (`procutil.nim:99`), `127` when `bash` itself could not be executed
  (`procutil.nim:101`). If the capture file is missing entirely (unterminated
  heredoc, unbalanced quote — the subshell died before setting up the
  redirection) the output is replaced by `[no output captured — the command
  failed to parse or start; check quoting and heredoc termination]`
  (`procutil.nim:28-40`).
- **Self test:** `comp.selfTest` exercises the real exec path and the 1 s
  timeout kill (expects exit 124) (`main.nim:192-220`).

## 4. MANUAL placement

No dedicated section exists. Coverage today:

- MANUAL.md:55 — the shipped-components table row (the only real description,
  and a good one).
- MANUAL.md:39, 2265 — `--minimal` profile includes `bash`.
- MANUAL.md:457-459 — `bash` is the first entry in the approval-gated list;
  MANUAL.md:330, 495-502 the bypasses.
- MANUAL.md:412-419 — the bus table's `cancel.<component>` row (bash kills the
  command group).
- MANUAL.md:268 — `NIF_ROOT`, cwd = root.
- MANUAL.md:556-565 — conversation workspace / `cwd` pinning and the
  runner's path rewriting.
- MANUAL.md:1033-1083 — `processes`, with three bash cross-references
  (1037, 1058-1065, 1079-1083).
- MANUAL.md:1440, 1466 — tool-profile JSON and the "routine work" policy.
- MANUAL.md:1810-1811 (its logs), 2308-2310 (bench measurement excludes bash
  workload children).

**Proposed:** insert a new `## Shell commands (\`bash\`)` section at
**MANUAL.md:1033**, immediately before `## Background processes
(\`processes\`)` (which already reads as its continuation), or equivalently
after `## Language servers (\`lsp\`)` (ends MANUAL.md:1031). Subsections:
`### The tool` (schema, the two timeouts, result fields), `### Output: two
caps and a spill` (2 MB / 12 KB, `var/toolout/<session>/`, 1 h TTL, marker
text), `### Cancellation and exit codes` (124/126/127/130/128+N, the 30 s
freshness window, the stashed-cancel rule), `### Configuration` (only
`NIF_ROOT`; caps are constants), plus `### Background jobs` pointing at the
following section. Add one `## Contents` entry on MANUAL.md:20 (the `lsp` · `processes` line) and keep
MANUAL.md:55 as the summary. Note the sibling audit for `edit` proposes the
same insertion point, so the two new sections would land as `File tools
(\`edit\`)` → `Shell commands (\`bash\`)` → `Background processes
(\`processes\`)`.

## 5. DELTA list

- MANUAL absent (no section) | CODE: `main.nim:1-222` | FIX: add the section
  above — four prose cross-references exist, but nothing states the schema, the
  two timeouts, the caps, the spill directory or the exit-code table in one
  place. The table row (MANUAL.md:55) is a summary, not a chapter.
- MANUAL absent (`var/toolout` never mentioned) | CODE: `main.nim:27-49`,
  `176-179` | FIX: add — oversized captures spill to
  `$NIF_ROOT/var/toolout/<session>/<pid>-<epoch>-<counter>.out`, absolute and
  therefore readable with `read` (offset/limit); files older than **1 hour**
  are swept on each new spill, so a spill path from an old turn may be gone.
  MANUAL.md:55 calls it "a temp file pageable with `read`", which leaves the
  reader unable to find or predict it — and it is not
  `$TMPDIR` when `NIF_ROOT` is set (`main.nim:31-32`). Add a `var/` state-table
  row (MANUAL.md:41-48) too: `| var/toolout/ | bash spill files … | disposable,
  1 h TTL |`.
- MANUAL absent (cap numbers and their non-configurability) | CODE:
  `main.nim:12`, `16` | FIX: add — the hard capture bound is **2,000,000
  bytes** and the transcript cap **12,000 bytes**, both compile-time constants
  with **no env knob** (the component's only `getEnv` is `NIF_ROOT`,
  `main.nim:31`). A user who wants a bigger transcript budget must rebuild the
  component; a user hitting the 2 MB bound gets a marker telling the *model* to
  narrow the command, not the human a setting to raise.
- MANUAL:55 ("non-zero = failure; 124 = timeout, 130 = cancelled") | CODE:
  `main.nim:164-169`; `procutil.nim:113-116`, `99`, `101` | FIX: update — add
  the two codes the model will actually meet: `126` (cwd not enterable, from
  `chdir` failure — note the *tool* also uses 126 in its own status text for
  "found but not executable", `main.nim:167`), `127` (`bash` not resolvable on
  `PATH`), and the `128 + signal` convention for a command that killed itself
  (139/143). The `(exit N)` line is followed by combined stdout+stderr — that
  part MANUAL.md:55 gets right.
- MANUAL absent (parse/start failure output) | CODE: `procutil.nim:28-40` |
  FIX: add — when nothing could be captured (unterminated heredoc, unbalanced
  quote) the transcript shows `[no output captured — the command failed to
  parse or start; check quoting and heredoc termination]` instead of a bare
  code. Also worth one clause: a command containing `<<` is wrapped with the
  redirection on its own line (`procutil.nim:82-88`), i.e. heredocs are
  supported and tested (tests/t_bash.nim:49-53).
- MANUAL absent (truncation marker) | CODE: `procutil.nim:153-166` | FIX: add
  the literal marker shape `[... truncated <omitted> of <total> bytes (capped
  at <max>) — <hint> ...]` with head+tail kept, since the model's recovery
  behaviour (re-run narrower, or `read` the spill) depends on it, and `bash`
  passes two different hints (`main.nim:161-162`, `181-183`).
- MANUAL absent (30 s cancel-freshness window, stashed cancels) | CODE:
  `main.nim:60-102`, `124-126` | FIX: add — a `cancel.bash` is only honoured
  within **30 s** of its timestamp (`cancelFreshSeconds`, `main.nim:65`); a
  cancel for a *different* session is stashed and later turns that queued
  request into a synthetic `(exit 130 — cancelled by request)` **without
  running the command**. This is the only place the MANUAL/WIRE pair (296-319)
  understates the mechanism: the "components opt in by matching `sessionId`"
  wording describes the running case and misses the queued case.
- MANUAL:412-419 / WIRE docs (cancellation) | CODE: `main.nim:156`,
  `procutil.nim:119-122` | FIX: none needed beyond the above — exit 130 and the
  process-group kill are stated correctly in both docs; optionally add "the
  probe is polled every 50 ms, so cancellation is prompt but not instantaneous".
- MANUAL absent (two timeouts could be conflated) | CODE: `main.nim:112`,
  `119`, `128`; `core/dispatch.nim:151`, `1564-1567` | FIX: add one sentence —
  the argument (`timeoutMs`, default 30 s) controls the *command*; the schema's
  `x-harness.timeoutMs: 60000` controls how long *core* waits for the reply
  (core default 120 s). With `timeoutMs: 120000` the command can legally outlive
  the dispatch budget and the caller sees a dispatch timeout, not a tidy 124.
- MANUAL absent (`run_in_background` still has a dispatch budget) | CODE:
  `main.nim:113-117` ("no timeout applies"), `119` | FIX: clarify — "no timeout
  applies" to the *job* (the `processes` component owns it), but the `bash`
  call that starts it is still bounded by the 60 s dispatch budget and the
  start request's own 15 s (`main.nim:142`); if `processes` is slow to answer,
  the call fails with the dispatch error, not `[E_BACKGROUND]`.
- MANUAL absent (one approval, not two) | CODE: `main.nim:119`, `142`;
  `core/dispatch.nim:1556-1563` | FIX: add — a background start is approved
  once (the `bash` call); the component's internal `process_start` request goes
  straight over NATS and never passes core's approval gate. Correspondingly,
  `process_start` called *directly* (e.g. from `cli` or another component)
  **is** gated (MANUAL.md:1041). Note: reasoned from the dispatch path, not
  executed in this audit.
- MANUAL absent (no `effect`, therefore write-class) | CODE: `main.nim:119-120`
  (no `"effect"` key); `components/fabric/fabric.nim:218-233`
  (unclassified ⇒ `"write"`) | FIX: add — `bash` declares no
  `x-harness.effect`, so fabric's batch host classifies it as a **write** and
  runs it exclusively (never inside the read concurrency cap). Same note as the
  `edit` audit makes for `read`/`grep`; for `bash` the classification is the
  conservative and correct one, but the MANUAL's fabric chapter (MANUAL.md:1974-1996)
  never says which common tools serialize.
- MANUAL absent (shell, env, stdin) | CODE: `procutil.nim:82-101`;
  MANUAL.md:268 | FIX: add — the shell is always `bash -c` (`$PATH`-resolved,
  no override), stdout and stderr are merged in arrival order, the child
  inherits the component's environment (`NIF_ROOT`, `.env`, everything core
  exported) and stdin, and fds above stderr are `FD_CLOEXEC`-scrubbed before
  spawn. "Fresh shell per call: `cd` does not persist" (`main.nim:118`) is the
  one part already visible to the model.
- MANUAL absent (`self_test`) | CODE: `main.nim:192-220` | FIX: optional —
  `bash` implements `comp.selfTest` (real exec + a 1 s timeout kill expecting
  124) and `deep` is accepted with the same probes; no MANUAL or WIRE mention
  exists. Low value for users, useful for an operator verifying a fresh build.
- MANUAL:457-459, 330, 495-502 (approval gate) | CODE: `main.nim:119` |
  FIX: none — verified accurate: `bash` is gated on every call, denied when no
  human is reachable, bypassed only by `/approvals auto` or
  `NIF_AUTO_APPROVE=1`, with no per-command allowlist and no read-only path.
- MANUAL:1033-1083 (`processes` interplay) | CODE: `main.nim:131-152` |
  FIX: none — verified accurate, including the owning-session handoff, the
  exit notice, `[E_BACKGROUND]` when the component is absent, and "no timeout
  applies" to the job.
- MANUAL:268, 556-565 (workspace/cwd) | CODE: `main.nim:154-155`,
  `core/dispatch.nim:1437-1446` | FIX: none required — accurate. A one-line
  addition would help: the workspace arrives in the `cwd` argument and the
  component realizes it as `cd -- <cwd> || exit $?`, so a missing workspace
  directory surfaces as a failed call rather than as output from the wrong
  directory.
- MANUAL:39, 2265 (`--minimal`) and MANUAL.md:55 (manifest column) | CODE:
  `manifest.yaml:22-27` | FIX: none — `bash` is `required: true`,
  `autostart: true`; consistent with the MANUAL.

Finding count: 19 rows — 12 add, 3 update, 4 verified/no-change (one of which
carries an optional-add note).

## 6. Not user-facing

Nothing here is hidden or admin-only: `bash` is a plain, direct, always-visible
catalog tool and one of the three components in the minimal profile
(MANUAL.md:39, 2265). Two things are *invisible to the human but visible to the
model*, and should be documented as behaviour rather than as interfaces:

- the transcript/spill split — the transcript carries a pointer line and a
  head+tail window while the full capture lives in `var/toolout/`
  (`main.nim:172-186`), so what the human sees in a transcript is deliberately
  not the whole command output;
- the stashed-cancel refusal (`main.nim:96-102`, `124-126`), which produces a
  `(exit 130 …)` result for work that was never executed — an operator reading
  a transcript could otherwise conclude the command ran and was killed.

Operator-visible but low-level: the spill directory is disposable runtime state
under the gitignored `var/` tree (MANUAL.md:41), 1 h TTL, safe to delete at any
time; and the child-fd `FD_CLOEXEC` scrub (`procutil.nim:44-59`) is the reason
`bash` does not accumulate the harness's pipe handles. No secrets, no network
access, no persistence beyond `var/`.
