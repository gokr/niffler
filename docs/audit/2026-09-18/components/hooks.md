# Audit — `components/hooks/` (Nim, `main.nim`, 138 lines + `README.md` 116 lines)

Scope: `components/hooks/main.nim` (the component), `components/hooks/README.md`
(its user-facing doc), `manifest.yaml:212-221`, the SDK surfaces it uses
(`sdk/niffler/sdk.nim:169-173` tap, `:837-843` bindings,
`sdk/niffler/procutil.nim:70-133` `runCmd`), `tests/t_hooks.nim`,
`core/conversation.nim:1740-1768` and `:2225-2245` (the event producers) and
`docs/MANUAL.md` — section `## Hooks`, the shipped row, the `NIF_HOOKS_*` env
rows. Read-only audit: no builds, no source or MANUAL edits. Three findings were
**reproduced live** by driving the built `var/bin/hooks` against a private
nats-server (scratch drivers written for the probe, deleted afterwards).

> **Line-number drift:** the numbers below are `docs/MANUAL.md` as it stood
> while this report was written (2850 lines); the concurrent consolidation pass
> kept editing it (3072 lines by the end, `## Hooks` ≈1137→1247, the
> `NIF_HOOKS_*` env rows ≈430→465, the `ev.session.*` inventory ≈494→532). The
> quotes are the durable anchor — every row's quote was re-verified against the
> file — so re-resolve a number by searching its quote.

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
- Never fatal, never asynchronous: the hook runs synchronously *inside* the
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
- Ships **off**: `manifest.yaml:216-221` sets `autostart: false` (the only such
  component in the observation trio) with the reason in the manifest comment; a
  hookless boot is not an error — the component logs `hooks: no hooks configured
  (set NIF_HOOKS_<EVENT>, see components/hooks/README.md) — watching nothing,
  staying up` and keeps running (`main.nim:107-109`).

## 2. Tools

**None.** For the record, the fields the audit brief asks for: no `approval`,
no `onDemand`, no `hidden`, no `replicas` (`manifest.yaml:216-221`:
`autostart: false`, `required: false`, `restart: on-failure`, no `replicas` → 1).
The observable interface is the environment plus the bus, not tools.

### How a hook is configured (data, not code)

Four environment variables, read once at boot (`main.nim:90-105`):

| Var | Read at | Semantics |
|---|---|---|
| `NIF_ROOT` | `main.nim:90` | root used only to locate `.env` (`loadDotEnv(".env", root / ".env")`, `main.nim:91`); defaults to `getCurrentDir()` |
| `NIF_HOOKS_EVENTS` | `main.nim:100` | comma-separated subject specs; default `"ev.session.turn"`. Entries are `.strip()`ed, empty ones skipped (`main.nim:101-102`). Only listed subjects are considered — a `NIF_HOOKS_*` command for an unlisted subject is inert |
| `NIF_HOOKS_<SUBJECT>` | `main.nim:103` | the command. The name is derived: uppercase + `.`→`_` + `>`→`_` (`hookEnvFor`, `main.nim:37-40`): `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` → **`NIF_HOOKS_EV_LOG__`** (two underscores — the trailing `.` *and* the `>` each become `_`; verified by running the binary: with the documented single-underscore name the spec is silently dropped), `>` → `NIF_HOOKS__`, `ev.session.>` → `NIF_HOOKS_EV_SESSION__`. A spec whose variable is empty/unset never becomes a hook (`main.nim:104-105`) |
| `NIF_HOOKS_TIMEOUT_MS` | `main.nim:93-97` | default `10000`, clamped to `100..60000`; an unparsable value silently falls back to `10_000` (a **clamp**, not the fail-loud `configInt` convention observe/logfile use — `sdk/niffler/sdk.nim:268-284`) |

Example config from the README, mirrored in the MANUAL:

```bash
NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

### Which events can be subscribed to

- Any concrete subject or trailing-`>` prefix; `matchHook` is exact-equality or
  `startsWith(prefix)` (`main.nim:49-55`), first match in the comma-separated
  list wins (`main.nim:51-54`).
- **Transport**: one always-on tap on `ev.session.>` whenever at least one hook
  is configured (`main.nim:116`), plus one tap per configured spec that is
  *not* under `ev.session.` (`main.nim:124-133`). Spec matching happens in the
  handler; the tap is only transport (`main.nim:118-120`).
- Events worth watching today (`components/hooks/README.md:32-37`,
  `docs/WIRE.md:169-207`, MANUAL:484-524): `ev.session.turn` (per turn,
  `{sessionId, turnId, phase: start|done, content?, error?}` —
  `core/conversation.nim:1762-1768`, `:2915-2917`), `ev.session.done`
  (`{sessionId, turnId?, reply}` — the one carrying the reply text,
  `core/conversation.nim:1745`), `ev.session.status` (per LLM round),
  `ev.session.context` (warn/trim/reset reasons), `ev.log.<component>` (via
  `ev.log.>`), plus anything else on the bus.
- **`*` is not a usable spec token** (reproduced): `matchHook` understands only
  exact names and trailing `>` (`main.nim:49-55`), so
  `NIF_HOOKS_EVENTS="ev.log.*"` with `NIF_HOOKS_EV_LOG_*='cat >> out'` logs
  `watching ev.log.*`, the tap does match a published `ev.log.error`, and the
  command still never runs. A `>` spec *does* fire — for **every** message on
  the bus, including `_INBOX.*` replies.

### Timeout and failure semantics

| Situation | What happens | Evidence |
|---|---|---|
| Hook exits non-zero | `hooks: exit <code> on <subject>` plus the hook's combined output is written to the component's stderr; the component continues | `main.nim:79-81` |
| Hook exceeds `NIF_HOOKS_TIMEOUT_MS` | `runCmd` SIGTERMs the hook's process group, then SIGKILLs, returns **124** | `main.nim:78`; `sdk/niffler/procutil.nim:117-132` |
| Fork/write/remove failure | `hooks: failed on <subject>: <msg>` on stderr; never re-raised | `main.nim:82-83` |
| Hook exits 0 | **its stdout/stderr are discarded** — `runCmd` captures them into a temp file which `main.nim:78-81` ignores on code 0 (reproduced) | `sdk/niffler/procutil.nim:70-133` |
| Component killed mid-hook | the payload temp file in `getTempDir()` leaks (removal is in `finally`, `main.nim:84-86`); the hook child is a process-group leader whose parent is gone | `main.nim:73-86` |

## 3. Configuration

Every variable the component reads is in the §2 table (`NIF_ROOT`,
`NIF_HOOKS_EVENTS`, `NIF_HOOKS_<SUBJECT>`, `NIF_HOOKS_TIMEOUT_MS`); there are no
others (`grep -n 'getEnv' components/hooks/main.nim` → lines 90, 95, 100, 103).
All three `NIF_HOOKS_*` rows exist in the MANUAL env table. No store use, no
files outside the payload temp file, no `var/` artefacts. Supervision:
`manifest.yaml:216-221` (`autostart: false`, `required: false`,
`restart: on-failure`). A hook's output that matters reaches the operator only
through the component's log (`core/supervisor.nim:126-131`), and only when the
hook failed — see the first row in §5.

## 4. How `docs/MANUAL.md` covers it today

The section **exists**: `## Hooks` (MANUAL:1137 while this report was written),
body 1139-1171, directly after the last `## Provider registry (provider)`
subsection paragraph and before `## Fetch`. Anchor `#hooks`. Current text, line
by line (quotes are the anchor; line numbers are the revision read):

- **MANUAL:1139-1141** —
  > ``The `hooks` component (off by default — an autostart flag, not a build one:
  > `make build` compiles the binary like every component, so enabling it is
  > `NIF_HOOKS_*` plus `spawn {name: "hooks", binary: "<root>/var/bin/hooks"}`)``
- **MANUAL:1142-1148** — "runs operator shell commands when selected bus events
  fire — the observe-only subset of CodeWhale's hooks (docs/research/CODEWHALE.md).
  A hook is a plain process: the decoded event payload is piped to the command's
  stdin as pretty JSON — written to a temp file and `cat` into the hook, never
  interpolated into the command line — failures and timeouts (default 10s, max
  60s) are logged and never fatal, and a payload is capped at 256 KB with a
  truncation marker appended. There is deliberately no steering/veto: approval
  decisions live in core's dispatch gate."
- **MANUAL:1150-1152** — "Configuration is env-based, read at boot (a `.env`
  change applies to the respawned component; a variable exported in core's shell
  needs a harness restart):"
- **MANUAL:1161-1167** — "Subject → env name: dots and `>` become `_`,
  uppercased (`ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`). Worked examples
  — desktop notification, sound alert, email, webhook, error tail — live in
  `components/hooks/README.md`. Matching is first-match-wins over the
  comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at
  boot is ignored — the component logs `watching …` only for the hooks it will
  run."
- **MANUAL:1169-1171** (**wrong**, see §5) — "Hook stdout and stderr go to the
  component's own log, `var/logs/hooks.log` (the supervisor redirects child
  output there) — never into logfile's JSONL, which persists bus traffic only."

Other touchpoints: the shipped row (`| `hooks` | Nim | off by default | …`),
the three `NIF_HOOKS_*` env rows, and a Contents bullet (`- [Hooks](#hooks)`).

**Explicitly absent from the MANUAL** (all of it lives in `main.nim` and/or the
README today): the set of events worth subscribing to; that a `*` token silently
never fires while `>` matches every message on the bus including inbox replies;
that the hook receives the *envelope payload* (envelope stripped) with raw
pass-through for non-envelope input; that a hookless boot stays up and that the
component registers zero tools; that a **successful** hook's output is discarded;
where the payload temp file lives and with what permissions; the real env-name
spelling for a trailing-`>` spec; and that `tests/t_hooks.nim` / `make
test-hooks` exist while no `selftest` does.

## 5. DELTA list

Rows are the findings in the audit's machine-parsed shape, grouped by the current
MANUAL section they land in. `[class]` marks the ledger class; `FIX` starts with
the verb, and the proposed wording/evidence is in the row. §1–§4 hold the
long-form reasoning.

## Hooks

- MANUAL: "Hook stdout and stderr go to the component's own log, `var/logs/hooks.log`" | CODE: components/hooks/main.nim:78-81; sdk/niffler/procutil.nim:83-89,132 | FIX: update — [wrong] replace the sentence with "A **failing** hook's combined output is echoed to the component's stderr and lands in `var/logs/hooks.log` (the supervisor redirects child output there); a hook that exits 0 has its stdout and stderr discarded. Neither path writes into logfile's JSONL, which persists bus traffic only." Reproduced: with `NIF_HOOKS_EV_LOG_ERROR='echo HOOK-STDOUT; echo HOOK-STDERR 1>&2; true'` and one published `ev.log.error`, the log holds the two banner lines and neither marker; with `'echo FAIL-OUT; echo FAIL-ERR 1>&2; exit 3'` it holds `hooks: exit 3 on ev.log.error`, `FAIL-OUT` and `FAIL-ERR`. `README.md:6-8` states the failing-hook fact correctly, so the MANUAL sentence is the outlier.
- MANUAL: "payload is piped to the command's stdin as pretty JSON — written to a temp" | CODE: components/hooks/main.nim:59-66,73-78 | FIX: add — [missing] after that clause: "the payload handed over is the event *payload* — the envelope (`{v, id, kind}`) is stripped, and a message that is not an envelope passes through as raw bytes — written to `getTempDir()/niffler-hook-<pid>-<n>.json` with default file permissions (it contains model output, so treat it like a capture directory) and piped in by `cat`, so `jq .payload.x` — never `jq .x` — is the hook idiom."
- MANUAL: "Matching is first-match-wins over the" | CODE: components/hooks/main.nim:49-55,116-133 | FIX: update — [missing] after that clause: "only exact subjects and a trailing `>` prefix match — a `*` token never fires (the derived variable name would also contain a literal `*`), and a `>` spec fires for every message on the bus, `_INBOX.*` replies included. Keep the list disjoint." Reproduced: `NIF_HOOKS_EVENTS="ev.log.*"` logs `watching ev.log.*`, the tap matches a published `ev.log.error`, and the command still never runs.
- MANUAL: "Subject → env name: dots and `>` become `_`, uppercased" | CODE: components/hooks/main.nim:37-40; components/hooks/README.md:26-28,100-108 | FIX: update — [wrong] append "so a spec that ends in `>` ends in a doubled underscore: `ev.log.>` → `NIF_HOOKS_EV_LOG__`, `ev.session.>` → `NIF_HOOKS_EV_SESSION__`". The code comment (`main.nim:38-39`) and the README's mapping line and "keep a private error tail" example all claim `NIF_HOOKS_EV_LOG_`, which is silently inert: reproduced — with that name `hooks.log` shows only `watching ev.log.error`, with the doubled name both hooks are configured.
- MANUAL: "comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at" | CODE: components/hooks/main.nim:121-133; sdk/niffler/sdk.nim:169-173,837-843 | FIX: update the code, not the MANUAL (code bug) — [code-bug?] one NATS subscription is created per configured spec and the SDK dispatches per binding, so a message matching two specs is delivered twice and both deliveries run the *same* first-match command. Reproduced: `NIF_HOOKS_EVENTS="ev.log.error,ev.log.>"` with `NIF_HOOKS_EV_LOG_ERROR='cat >> a.jsonl'` and `NIF_HOOKS_EV_LOG__='cat >> b.jsonl'` gives 2 lines in `a.jsonl` and 0 in `b.jsonl` for one published event. Fix: dedupe per delivered message, or reject overlapping specs at boot; `tests/t_hooks.nim` covers a single spec only. Until then the MANUAL clause above should end "keep the list disjoint".
- MANUAL: "The `hooks` component (off by default — an autostart flag, not a build one:" | CODE: components/hooks/main.nim:107-109 (zero tools) | FIX: add — [missing] "It registers no tools at all — the interface is the environment plus the bus; configured with no `NIF_HOOKS_<SUBJECT>` set it logs `watching nothing, staying up` and keeps running."
- MANUAL: "desktop notification, sound alert, email, webhook, error tail — live in" | CODE: components/hooks/README.md:32-37; core/conversation.nim:1745,1762-1768; docs/WIRE.md:169-207 | FIX: add — [missing] name the useful subjects here and point at the bus inventory: "the events worth watching are `ev.session.turn` (turn boundaries), `ev.session.done` (carries `reply`), `ev.session.status` (per LLM round), `ev.session.context` (warn/trim/reset) and `ev.log.<component>`; their payload fields are listed under [The bus in one screen](#the-bus-in-one-screen)."
- MANUAL: "failures and timeouts (default 10s, max 60s) are logged and never fatal," | CODE: components/hooks/main.nim:78-83; sdk/niffler/procutil.nim:117-132 | FIX: none — [verified] a non-zero exit and a timeout both log to the component's stderr and never raise; the timeout kills the process group and reports exit 124.
- MANUAL: "approval decisions live in core's dispatch gate." | CODE: components/hooks/main.nim:8-12,114-135 | FIX: none — [verified] the observe-only claim holds: the component has no tools and never touches core's approval path.
- MANUAL: "which persists bus traffic only." | CODE: components/hooks/README.md:4-8 | FIX: update the README, not the MANUAL (code bug) — [code-bug?] `README.md:4-8` still reads "the firing subject is in `$NIF_HOOK_SUBJECT`... actually just stdin": no such variable exists anywhere in the tree (`grep -rn NIF_HOOK_SUBJECT` → the README only), so the sentence should be deleted; the MANUAL claim it sits next to (hook output going to `var/logs/hooks.log`) is itself corrected by the first row of this group.

## Environment variables

- MANUAL: "| `NIF_HOOKS_EVENTS` | comma-separated bus subjects the hooks component watches; trailing `>` wildcards work. Read at boot — a config change is `core.kill` + `core.spawn` | `ev.session.turn` |" | CODE: components/hooks/main.nim:100-105 | FIX: none — [verified] default `"ev.session.turn"`, comma-split, stripped, empty entries skipped, only listed subjects considered; "trailing `>` wildcards work" is right (and the `*` limitation is the row above).
- MANUAL: "| `NIF_HOOKS_<SUBJECT>` | the shell command run for one watched subject (dots and `>` become `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`); event payload piped to stdin as JSON | unset |" | CODE: components/hooks/main.nim:37-40,103-105 | FIX: update — [wrong] "the shell command run for one watched subject (uppercased, every `.` and `>` becomes `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` → `NIF_HOOKS_EV_LOG__` — a trailing dot and a trailing `>` each contribute an underscore); event payload piped to stdin as JSON".
- MANUAL: "| `NIF_HOOKS_TIMEOUT_MS` | per-hook timeout, clamped to 100–60000 ms; a timeout kills the hook and logs exit 124 | `10000` |" | CODE: components/hooks/main.nim:93-97,78 | FIX: none — [verified] `clamp(parseInt(getEnv(...)), 100, 60_000)`, parse failure → `10000`, timeout → exit 124 via `runCmd`.

## Layout of a running system

- MANUAL: "| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |" | CODE: manifest.yaml:216-221; components/hooks/main.nim:1-138 | FIX: none — [verified] `autostart: false`, `restart: on-failure`, no `replicas`, and no tools; the "off by default" and the pointer are both correct (the "registers no tools" clause belongs in the chapter, first group above).

## The bus in one screen

- MANUAL: "ev.session.turn        {sessionId, turnId, phase: start|done, content?, error?}" | CODE: core/conversation.nim:1762-1768,2915-2917 | FIX: none — [verified] that is the whole `ev.session.turn` payload; there is no `reply` field, and this inventory is the right place for the Hooks section to point at.
- MANUAL: "ev.session.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}" | CODE: components/hooks/README.md:34; core/conversation.nim:1745 | FIX: update the README, not the MANUAL (code bug) — [wrong] `README.md:34` claims `reply` rides `ev.session.turn`; it rides `ev.session.done` (as the MANUAL and `docs/WIRE.md:207` both say). Every README example built on `.payload.reply` (the sound gate, "email a session summary") therefore emits nothing on `ev.session.turn`; the examples should subscribe to `ev.session.done` or read `.payload.content` from `ev.session.turn`'s `start` phase.
- MANUAL: "ev.session.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}" | CODE: components/hooks/README.md:35; core/conversation.nim:2240-2243 | FIX: update the README, not the MANUAL (code bug) — [wrong] `README.md:35` lists `cacheHitTokens`/`cacheHitRatio` under `ev.session.status`; core publishes a nested `cache {prompt, read, hitRate}` object instead. (The MANUAL's own sentence about the cache economy carries the same wrong names — tracked separately as a `## Context window` finding.)

## Observation and logs

- MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero" | CODE: components/hooks/main.nim:93-97; sdk/niffler/sdk.nim:268-284 | FIX: none — [verified] the sentence is scoped to `NIF_OBSERVE_*`/`NIF_LOGFILE_*`, whose knobs go through `configInt` and kill the component when out of range; `hooks` deliberately clamps instead, which its own env row states.

## Testing

- MANUAL: "`/doctor deep` additionally fans out to each component's own self test over" | CODE: tests/t_hooks.nim:1-69; Makefile:517 (`test-hooks`); `grep -c selftest components/hooks/main.nim` → 0 | FIX: add — [missing] a Verification line in `## Hooks`: "`tests/t_hooks.nim` (`make test-hooks`) publishes `ev.session.turn` and asserts the configured command receives the event payload on stdin; the component registers no `selftest`, so `/doctor deep` reports it as not implementing one."

Finding count for this component: 19 rows — 9 in `## Hooks`, 3 env, 1 shipped row, 3 bus inventory, 1 observation bounds, 1 testing, 1 README-hygiene row folded into the first group. Classes: 5 `wrong` (one MANUAL-side, four in the `components/hooks/README.md`/code comment that the MANUAL points at), 5 `missing`, 2 `code-bug?` (per-subscription duplicate firing and the phantom `NIF_HOOK_SUBJECT`), 7 `verified` — three of the non-verified findings were reproduced live against the built `var/bin/hooks`.

## 6. Not user-facing

- `hookCounter`/temp-file naming (`main.nim:42-44`, `:72-74`), the `Hook` tuple
  and `matchHook` internals (`main.nim:46-55`), and the exact `runCmd`
  capture/`quoteShell` mechanics.
- The `try/except CatchableError` around envelope decoding (`main.nim:59-64`) —
  only its consequence (raw pass-through) is user-visible.
- `loadDotEnv` path resolution and `NIF_ROOT`'s default (`main.nim:90-91`) —
  covered by the global `.env` story.
- The stale file-header comment that the command "runs through `sh -c`"
  (`main.nim:13-14`, repeated `:67-71`) when `runCmd` execs **bash**
  (`sdk/niffler/procutil.nim:90`), and the dead `let cmd = matchHook(hooks, s)`
  at `main.nim:126` — bugs, not doc.
