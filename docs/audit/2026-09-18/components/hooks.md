# Audit — `components/hooks/` (Nim, `main.nim`, 138 lines + `README.md` 116 lines)

Scope: `components/hooks/main.nim` (the component), `components/hooks/README.md`
(its user-facing doc), `manifest.yaml:212-221`, the SDK surfaces it uses
(`sdk/niffler/sdk.nim:169-173` tap, `:837-843` bindings,
`sdk/niffler/procutil.nim:70-133` `runCmd`), `tests/t_hooks.nim`,
`core/conversation.nim:1740-1768` (the `ev.session.turn` producer) and the
current `docs/MANUAL.md` — section `## Hooks` at MANUAL:1137-1171, shipped row
MANUAL:84, env rows MANUAL:430-432. Read-only audit: no builds, no edits.

## 1. What it offers

- Event-driven shell commands: when a configured bus subject fires, the
  component runs an operator-supplied command once, with the event payload on
  stdin. It is the observe-only subset of CodeWhale's hooks by design — no
  steering/veto, because Niffler's approval gate lives inside core's dispatch
  path (`main.nim:8-12`).
- **Zero tools.** There is no `comp.tool` registration anywhere in the file
  (`grep -c 'comp.tool' components/hooks/main.nim` → 0); the component exists
  purely as a bus tap (`main.nim:114-135`). Tool-name space is untouched, and
  the model can never see it.
- Never fatal, never blocking the bus: the hook runs synchronously *inside* the
  SDK's serialized tap handler (`main.nim:78`), so a slow hook delays the
  component's own message pump for up to `NIF_HOOKS_TIMEOUT_MS`. The failure
  paths (non-zero exit, exception) only write to the component's stderr
  (`main.nim:79-83`); `runHook` never raises out of the handler.
- Payload handling: the raw wire bytes are decoded; when they form an envelope
  the hook receives `envelope.payload` pretty-printed, otherwise the bytes pass
  through unchanged (`main.nim:57-64`) — so a hook sees the *event payload*, not
  the envelope. Payloads are capped at `maxPayloadBytes = 256_000` bytes with
  `"\n...[truncated]"` appended (`main.nim:34-35`, `:65-66`).
- Delivery: the payload is written to a temp file and the command is wrapped as
  `cat <file> | <command>` (`main.nim:73-78`) — never interpolated into the
  command line. `runCmd` then executes that with `bash -c` as a process-group
  leader and owns the timeout kill (`sdk/niffler/procutil.nim:83-101`,
  `:117-132`), so a timed-out hook tree dies whole.
- Ships **off**: `manifest.yaml:212-221` sets `autostart: false` (the only such
  component in the observation trio) with the reason in the manifest comment; a
  hookless boot is not an error — the component logs
  `hooks: no hooks configured (set NIF_HOOKS_<EVENT>, see
  components/hooks/README.md) — watching nothing, staying up` and keeps running
  (`main.nim:107-109`).

## 2. Tools

**None.** For the record, the fields the audit brief asks for: no `approval`,
no `onDemand`, no `hidden`, no `replicas` (manifest `manifest.yaml:216-221`:
`autostart: false`, `required: false`, `restart: on-failure`, no `replicas` →
1). The observable interface is the environment + the bus, not tools.

### How a hook is configured (data, not code)

Three environment variables, read once at boot (`main.nim:90-105`):

| Var | Read at | Semantics |
|---|---|---|
| `NIF_ROOT` | `main.nim:90` | root used only to locate `.env` (`loadDotEnv(".env", root / ".env")`, `main.nim:91`); defaults to `getCurrentDir()` |
| `NIF_HOOKS_EVENTS` | `main.nim:100` | comma-separated subject specs; default `"ev.session.turn"`. Entries are `.strip()`ed, empty ones skipped (`main.nim:101-102`). Only listed subjects are considered — a `NIF_HOOKS_*` command for an unlisted subject is inert |
| `NIF_HOOKS_<SUBJECT>` | `main.nim:103` | the command. The name is derived: uppercase + `.`→`_` + `>`→`_` (`hookEnvFor`, `main.nim:37-40`): `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` → `NIF_HOOKS_EV_LOG_`, `>` → `NIF_HOOKS__`. A spec whose variable is empty/unset never becomes a hook (`main.nim:104-105`) |
| `NIF_HOOKS_TIMEOUT_MS` | `main.nim:93-97` | default `10000`, clamped to `100..60000`; an unparsable value silently falls back to `10_000` (note: **clamp**, not the fail-loud `configInt` convention observe/logfile use — `sdk/niffler/sdk.nim:268-284`) |

Real config example from the README, and the same shape in MANUAL:1154-1159:

```bash
NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

### Which events can be subscribed to

- Any concrete subject or trailing-`>` prefix; `matchHook` is exact-equality or
  `startsWith(prefix)` (`main.nim:49-55`), first match in the comma-separated
  list wins (`main.nim:51-54`; MANUAL:1164 says the same).
- **Transport**: one always-on tap on `ev.session.>` whenever at least one hook
  is configured (`main.nim:116`), plus one tap per configured spec that is
  *not* under `ev.session.` (`main.nim:124-133`). The spec matching is done in
  the handler; the tap is only transport (the code says so at `main.nim:118-120`).
- Useful events today (README:32-37 + `docs/WIRE.md:169-190` + MANUAL:490-510):
  `ev.session.turn` (per turn, `{sessionId, turnId, phase: start|done,
  content?, error?}` — `core/conversation.nim:1762-1768`, `:2915-2917`),
  `ev.session.status` (per LLM round), `ev.session.context` (warn/trim/reset
  reasons), `ev.log.<component>` (via `ev.log.>`), plus anything else on the bus.
- **`*` is not a usable spec token.** `matchHook` understands only exact names
  and trailing `>` (`main.nim:49-55`), so `NIF_HOOKS_EVENTS=ev.log.*` silently
  never fires (the tap matches, the match function never does). Additionally the
  derived env name would contain a literal `*` (`main.nim:37-40`), which most
  shells cannot export cleanly. A `>` spec *does* fire — for **every** message on
  the bus, including `_INBOX.*` replies (tap `>`, `matchHook(">")` matches
  everything).

### Timeout and failure semantics

| Situation | What happens | Evidence |
|---|---|---|
| Hook exits non-zero | `hooks: exit <code> on <subject>` plus the hook's combined output is written to the component's stderr; the component continues | `main.nim:79-81` |
| Hook exceeds `NIF_HOOKS_TIMEOUT_MS` | `runCmd` SIGTERMs the hook's process group, then SIGKILLs, returns **124** | `main.nim:78`; `sdk/niffler/procutil.nim:117-132` |
| Fork/write/remove failure | `hooks: failed on <subject>: <msg>` on stderr; never re-raised | `main.nim:82-83` |
| Hook exits 0 | **its stdout/stderr are discarded** — `runCmd` captures them into a temp file which is read into `r.output` and dropped (`main.nim:78-81` ignores `r.output` on code 0) | `sdk/niffler/procutil.nim:70-133` |
| Component killed mid-hook | the payload temp file in `getTempDir()` leaks (removal is in `finally`, `main.nim:84-86`); the hook child is a process-group leader whose parent is gone | `main.nim:73-86` |

## 3. Configuration

Every variable the component reads is in the §2 table (`NIF_ROOT`,
`NIF_HOOKS_EVENTS`, `NIF_HOOKS_<SUBJECT>`, `NIF_HOOKS_TIMEOUT_MS`); there are no
others (`grep -n 'getEnv' components/hooks/main.nim` → lines 90, 95, 100, 103).
All three `NIF_HOOKS_*` rows exist in the MANUAL env table at 430-432.
No store use, no files outside the payload temp file, no `var/` artefacts.
Supervision: `manifest.yaml:216-221` (`autostart: false`, `required: false`,
`restart: on-failure`); a hook's own output that matters reaches the operator
only through the component's log `var/logs/hooks.log`
(`core/supervisor.nim:126-131`) — see finding 1, which is about what actually
reaches it.

## 4. How `docs/MANUAL.md` covers it today

The section **exists**: `## Hooks` at MANUAL:1137, body 1139-1171, directly after
the last `## Provider registry (`provider`)` subsection paragraph (ends 1135)
and before `## Fetch` (1173). Anchor `#hooks`. Exact current text (line-by-line, quoted):

- MANUAL:1139-1141:
  > `The `hooks` component (off by default — an autostart flag, not a build one:`
  > `` `make build` compiles the binary like every component, so enabling it is ``
  > `` `NIF_HOOKS_*` plus `spawn {name: "hooks", binary: "<root>/var/bin/hooks"}`) ``
- MANUAL:1142-1148:
  > `runs operator shell commands when selected bus events fire — the observe-only subset of CodeWhale's hooks`
  > `(docs/research/CODEWHALE.md). A hook is a plain process: the decoded event`
  > `payload is piped to the command's stdin as pretty JSON — written to a temp`
  > `file and `cat` into the hook, never interpolated into the command line —`
  > `failures and timeouts (default 10s, max 60s) are logged and never fatal,`
  > `and a payload is capped at 256 KB with a truncation marker appended. There is deliberately no steering/veto:`
  > `approval decisions live in core's dispatch gate.`
- MANUAL:1150-1152:
  > `Configuration is env-based, read at boot (a `.env` change applies to the`
  > `respawned component; a variable exported in core's shell needs a harness`
  > `restart):`
- MANUAL:1161-1167:
  > `Subject → env name: dots and `>` become `_`, uppercased`
  > `(`ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`). Worked examples —`
  > `desktop notification, sound alert, email, webhook, error tail — live in`
  > `` `components/hooks/README.md`. Matching is first-match-wins over the ``
  > `` `comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at ``
  > `boot is ignored — the component logs `watching …` only for the hooks it will`
  > `run.`
- MANUAL:1169-1171 (**wrong**, see finding 1):
  > `Hook stdout and stderr go to the component's own log, `var/logs/hooks.log``
  > `(the supervisor redirects child output there) — never into logfile's JSONL,`
  > `which persists bus traffic only.`

Other MANUAL touchpoints: shipped row MANUAL:84 (`| `hooks` | Nim | off by
default | runs operator shell commands when selected bus events fire
(observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |` — correct);
env rows MANUAL:430-432 (all three correct, including the 100–60000 ms clamp and
exit 124); Contents bullet MANUAL:27 (`- [Hooks](#hooks)`).

**Explicitly absent from the MANUAL** (all of it is in `main.nim` and/or
`README.md` today):

- the set of events worth subscribing to (the README table at README:32-37 and
  the `ev.*` inventory at MANUAL:490-510 are never connected);
- that a `*` token in a spec silently never fires, and that `>` subscribes to
  every message on the bus including `_INBOX.*` replies (`main.nim:49-55`,
  `:124-133`);
- that the hook receives the *envelope payload* (envelope stripped), with raw
  pass-through for a non-envelope message (`main.nim:57-64`);
- that a hookless boot stays up (`main.nim:107-109`);
- that **successful** hook output is discarded (finding 1);
- where the payload temp file lives (`getTempDir()`, `main.nim:73-74`) and that
  it is written with default file permissions;
- that the component registers zero tools;
- that `NIF_HOOKS_TIMEOUT_MS` is clamped while observe/logfile's bounds are
  fatal (`main.nim:93-97` vs `sdk/niffler/sdk.nim:268-284`);
- tests: `tests/t_hooks.nim` + `make test-hooks` (`Makefile:517`) are never
  named (the Observation section's Verification subsection names
  `t_observe`/`t_logfile` at MANUAL:2441/2447).

## 5. DELTA list (classed)

1. **[wrong] The hook's output does not reach `var/logs/hooks.log`, except on
   failure.** MANUAL:1169-1171 claims "Hook stdout and stderr go to the
   component's own log". In code, `runCmd` captures the hook's stdout+stderr
   into its own temp file (`sdk/niffler/procutil.nim:83-89`, `:132`) and
   `main.nim:79-81` writes `r.output` to the component's stderr **only when the
   exit code is non-zero**; on success the output is read and discarded. The
   hook's output reaches `hooks.log` only via the component's own stderr
   (`core/supervisor.nim:126-131`). `README.md:8-9` states this correctly
   ("Output of a failing hook goes to the supervisor log"), so the MANUAL
   sentence is the outlier. Fix: reword to the failing-hook-only fact.
2. **[wrong] `components/hooks/README.md:34` invents a `reply` field.** The
   README's payload table says `ev.session.turn` carries `reply`; the producer
   emits only `{sessionId, turnId, phase, content?, error?}`
   (`core/conversation.nim:1762-1768`, doc at `:1740`), MANUAL:494 lists exactly
   those fields, and `docs/WIRE.md:169` agrees. The README's own jq examples
   (`jq -r .payload.reply // empty`, the "email a session summary" example) are
   built on it. Fix belongs in the README (this is not a MANUAL edit), but the
   MANUAL section should link the payload inventory at MANUAL:490-510 so the
   reader is not left with the README's table.
3. **[wrong] `components/hooks/README.md:35` names payload keys that do not
   exist.** `cacheHitTokens` / `cacheHitRatio` are not emitted by
   `ev.session.status`; core publishes a nested `cache {prompt, read, hitRate}`
   object (`core/conversation.nim:2240-2243`). Same class of error as the
   already-tracked MANUAL:734 wording.
4. **[code-bug?] Overlapping specs run the hook twice.** One NATS subscription
   is created per configured spec (`sdk/niffler/sdk.nim:169-173`, `:837-843`) and
   the SDK dispatches per binding, so a message matching two specs is delivered
   twice; both deliveries call `matchHook`, which returns the *same* first match
   (`main.nim:121-123`, `:131-133`). Concrete example:
   `NIF_HOOKS_EVENTS="ev.log.error,ev.log.>"` fires the `ev.log.error` command
   twice for every error. `tests/t_hooks.nim` covers only a single spec. Fix:
   dedupe per message, or reject overlapping specs at boot.
5. **[missing] The watchable-event list.** MANUAL never says which subjects are
   useful; the README's table and the `ev.*` inventory (MANUAL:490-510) are the
   real source. Fix: point at MANUAL:490-510 explicitly and name the three
   README rows (`ev.session.turn`, `ev.session.status`, `ev.log.<component>`).
6. **[missing] Spec-matching reality.** `*` silently never fires and `>`
   matches every bus message (`main.nim:49-55`, `:116-133`) — a footgun that
   produces either nothing or one process per bus message. MANUAL:430's "trailing
   `>` wildcards work" is true but incomplete. Fix: one sentence in the section.
7. **[missing] What the hook actually receives.** "the decoded event payload is
   piped … as pretty JSON" (MANUAL:1143-1145) is right but silent on the two
   consequential details: the envelope (`v`/`id`/`kind`) is stripped
   (`main.nim:59-64`), so `jq .payload.x` — not `jq .x` — is the idiom; and a
   non-envelope payload is passed through as raw bytes.
8. **[missing] Hookless boot.** `main.nim:107-109` keeps the component up and
   logs `watching nothing, staying up`; spawning `hooks` without env is
   therefore harmless. README:110-116 says it; MANUAL does not.
9. **[missing] Successful-hook output is discarded** (same code as finding 1,
   different consequence for the operator: a hook that prints diagnostics and
   exits 0 leaves no trace). Worth one clause in the same rewrite.
10. **[missing] Payload temp file.** `getTempDir()/niffler-hook-<pid>-<n>.json`
    (`main.nim:73-74`), written with `writeFile` and default umask permissions
    (`main.nim:76`), removed in `finally` (`main.nim:84-86`) — but leaked by a
    SIGKILL. The payload contains model output, which MANUAL's own Boundary
    paragraph (2230-2234) treats as admin-only data. One sentence, and a
    `setFilePermissions` fix is a plausible code change.
11. **[delta] `NIF_HOOKS_TIMEOUT_MS` clamps instead of failing.** `main.nim:93-97`
    vs the `configInt` convention (`sdk/niffler/sdk.nim:268-284`) used by
    observe/logfile, which exits non-zero on an out-of-range value. MANUAL:432
    documents the clamp correctly, so this is an inconsistency note (and, if the
    behaviour changes, the MANUAL row must change with it).
12. **[delta] Zero tools / no `selftest`.** The component registers no tool
    (`grep -c comp.tool` → 0) and no `selftest` (`grep -c selftest` → 0), while
    `tests/t_hooks.nim` and `make test-hooks` exist (`Makefile:517`). State the
    first so readers stop looking for `hooks_*` tools; name the test in the
    MANUAL Verification list.
13. **[code-bug?] Stale comment: "`sh -c`".** The file header says the hook
    command "runs through `sh -c`" (`main.nim:13-14`, repeated `:67-71`), but
    `runCmd` execs **bash** (`sdk/niffler/procutil.nim:90`). The README and
    MANUAL never name the shell, so only the comment is wrong. Also dead at
    `main.nim:126`: `let cmd = matchHook(hooks, s)` is computed and never used.
14. **[code-bug?] `NIF_HOOKS_SUBJECT` in the README.** README:5-7 still reads
    "the firing subject is in `$NIF_HOOK_SUBJECT`... actually just stdin" — no
    such variable exists anywhere in the tree (`grep -rn NIF_HOOK_SUBJECT` →
    README only). The author's correction is visible in the sentence; the
    variable should be deleted.
15. **[verified] MANUAL's Hooks facts that are right** (re-checked, no edit):
    off-by-default is an autostart not a build flag and the exact `spawn` call
    (1139-1141 vs `manifest.yaml:216-221`); the payload cap 256 KB and the
    truncation marker (1146-1147 vs `main.nim:34-35`, `:65-66`); timeout
    default 10 s / max 60 s (1146 vs `main.nim:95`); the temp-file + `cat` +
    no-interpolation mechanism (1144-1146 vs `main.nim:73-78`); the env-name
    mapping and the two worked-example lines (1161-1163 vs `main.nim:37-40`);
    first-match-wins and unset-var-is-ignored (1164-1167 vs `main.nim:49-55`,
    `:100-105`); the three env-table rows including "a timeout kills the hook
    and logs exit 124" (430-432 vs `main.nim:78`,
    `sdk/niffler/procutil.nim:117-132`); the shipped row (84).

## 6. Machine-parsed rows

### Hooks

- MANUAL: "Hook stdout and stderr go to the component's own log, `var/logs/hooks.log`\n(the supervisor redirects child output there) — never into logfile's JSONL,\nwhich persists bus traffic only." | CODE: components/hooks/main.nim:78-81; sdk/niffler/procutil.nim:83-89,132 | FIX: update — "A **failing** hook's combined output is echoed to the component's stderr and lands in `var/logs/hooks.log` (the supervisor redirects child output there); a hook that exits 0 has its stdout and stderr discarded. Neither path writes into logfile's JSONL, which persists bus traffic only."
- MANUAL: "runs operator shell commands when selected bus events fire — the observe-only subset of CodeWhale's hooks\n(docs/research/CODEWHALE.md). A hook is a plain process: the decoded event\npayload is piped to the command's stdin as pretty JSON — written to a temp\nfile and `cat` into the hook, never interpolated into the command line —" | CODE: components/hooks/main.nim:59-66,73-78 | FIX: add after "never interpolated into the command line —": "the payload handed over is the event *payload*, not the envelope (`{v, id, kind}` is stripped; a non-envelope message passes through as raw bytes), capped at 256 KB and written to `getTempDir()/niffler-hook-<pid>-<n>.json` with default file permissions —"
- MANUAL: "Subject → env name: dots and `>` become `_`, uppercased\n(`ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`). Worked examples —\ndesktop notification, sound alert, email, webhook, error tail — live in\n`components/hooks/README.md`. Matching is first-match-wins over the\ncomma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at\nboot is ignored — the component logs `watching …` only for the hooks it will\nrun." | CODE: components/hooks/main.nim:49-55,116-133 | FIX: update — after "first-match-wins over the comma-separated list" insert: "only exact subjects and a trailing `>` prefix match (a `*` token never fires — the derived variable name would also contain a literal `*`), a `>` spec fires for every message on the bus including `_INBOX.*` replies, and specs that overlap fire the same first-match command once per matching subscription, so keep the list disjoint"; add the payload inventory pointer "the payload fields of the useful events are listed under [The bus in one screen](#the-bus-in-one-screen)"
- MANUAL: "The `hooks` component (off by default — an autostart flag, not a build one:\n`make build` compiles the binary like every component, so enabling it is\n`NIF_HOOKS_*` plus `spawn {name: \"hooks\", binary: \"<root>/var/bin/hooks\"}`)" | CODE: components/hooks/main.nim:107-109 | FIX: add — "it registers no tools at all: configured but with no `NIF_HOOKS_<SUBJECT>` set it simply logs `watching nothing, staying up`."
- MANUAL: "failures and timeouts (default 10s, max 60s) are logged and never fatal," | CODE: components/hooks/main.nim:78-83; sdk/niffler/procutil.nim:117-132 | FIX: none — verified: non-zero exit and timeout both log to the component's stderr and never raise; the timeout kills the process group and reports exit 124
- MANUAL: "| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |" | CODE: manifest.yaml:216-221; components/hooks/main.nim:1-138 | FIX: none — verified (no replicas, `autostart: false`, `restart: on-failure`, zero tools)

### Environment variables

- MANUAL: "| `NIF_HOOKS_EVENTS` | comma-separated bus subjects the hooks component watches; trailing `>` wildcards work. Read at boot — a config change is `core.kill` + `core.spawn` | `ev.session.turn` |" | CODE: components/hooks/main.nim:100-105 | FIX: none — verified: default `"ev.session.turn"`, comma-split, stripped, empty entries skipped, only listed subjects considered
- MANUAL: "| `NIF_HOOKS_<SUBJECT>` | the shell command run for one watched subject (dots and `>` become `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`); event payload piped to stdin as JSON | unset |" | CODE: components/hooks/main.nim:37-40,103-105 | FIX: none — verified: mapping is uppercase + `.`/`>` → `_`; an empty command drops the spec
- MANUAL: "| `NIF_HOOKS_TIMEOUT_MS` | per-hook timeout, clamped to 100–60000 ms; a timeout kills the hook and logs exit 124 | `10000` |" | CODE: components/hooks/main.nim:93-97,78 | FIX: none — verified: `clamp(parseInt(getEnv(...)), 100, 60_000)`, parse failure → `10000`, timeout → exit 124 via `runCmd`

### Layout of a running system

- MANUAL: "| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |" | CODE: components/hooks/main.nim (no `comp.tool`), manifest.yaml:216-221 | FIX: none — verified: the row's "off by default" matches `autostart: false`; add "no tools" only in the chapter (row above)

### Observation and logs

- MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero\nrather than silently substituting a default." | CODE: components/hooks/main.nim:93-97 | FIX: none — verified: the sentence is scoped to `NIF_OBSERVE_*`/`NIF_LOGFILE_*` (`sdk/niffler/sdk.nim:268-284` requires the value to be in range); `hooks` deliberately clamps instead, which its own env row states

### The bus in one screen

- MANUAL: "ev.session.turn        {sessionId, turnId, phase: start|done, content?, error?}" | CODE: core/conversation.nim:1762-1768,2915-2917 | FIX: none — verified: this is the whole payload; there is no `reply` field (add the pointer from the Hooks section to this inventory, see the Hooks row above)

### Testing

- MANUAL: "`tests/t_observe.nim` covers exact-once taps, wildcard boundaries, registration" | CODE: tests/t_hooks.nim:1-69; Makefile:517 (`test-hooks`) | FIX: add a Verification line to the Hooks section: "`tests/t_hooks.nim` (`make test-hooks`) publishes `ev.session.turn` and asserts the configured command receives the event payload on stdin; the component registers no `selftest`"

### Approvals

- MANUAL: absent (no hooks tool in the approval list) | CODE: components/hooks/main.nim (no tools; hook commands run with the harness's own trust level) | FIX: none — verified: nothing for the approval gate to name, though the code comment at `main.nim:67-69` states the trust assumption

## 7. Not user-facing

- `hookCounter`/temp-file naming (`main.nim:42-44`, `:72-74`), the `Hook` tuple
  and `matchHook` internals (`main.nim:46-55`), and the exact `runCmd`
  capture/`quoteShell` mechanics.
- The `try/except CatchableError` around envelope decoding (`main.nim:59-64`) —
  only its consequence (raw pass-through) is user-visible.
- `loadDotEnv` path resolution and `NIF_ROOT`'s default (`main.nim:90-91`) —
  covered by the global `.env` story at MANUAL:453+.
- The dead `let cmd = matchHook(hooks, s)` at `main.nim:126` — bug, not doc.

**Finding count: 15** (3 wrong-doc items — one in MANUAL, two in
`components/hooks/README.md`; 2 code-bug? candidates — duplicate firing on
overlapping specs and the stale `sh -c` comment; 8 MANUAL gaps/deltas;
2 verified-OK blocks).
