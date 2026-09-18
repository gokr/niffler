# Worklist slice: Hooks

From `worklist.tsv` (20 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A230 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 887–889 "the decoded event payload is piped to the command's stdin as pretty JSON, the command itself is never interpolated with event data, failures and timeouts (default 10s, max 60s) are logged and never fatal"
- CODE: exact, with two limits MANUAL omits — the payload is capped at 256 000 bytes with `\n...[truncated]` appended (`components/hooks/main.nim:40,63–67`), and the payload travels via a temp file `niffler-hook-<pid>-<n>.json` piped in as `cat <file> | <command>` (`:76–84`)
- FIX: append "Payloads are capped at 256 KB (a truncation marker is appended) and handed to the hook through a temp file, so a hook can `cat` stdin or seek it."

## A231 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 892–894 example config block
- CODE: `NIF_HOOKS_TIMEOUT_MS` is clamped to 100–60000 (`components/hooks/main.nim:112–115`) — MANUAL:338 already says "values above 60000 are clamped", but the prose example block gives no floor, and the hook runs through `sh -c` with the SDK's `runCmd`, whose timeout kill exits 124 (`:88–90`, `sdk/procutil`)
- FIX: add "(floor 100 ms; a timeout kills the process group and logs exit 124)".

## A232 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 898 "`NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"` # subjects to watch"
- CODE: matching is first-spec-wins (`components/hooks/main.nim:52–58`), the component always taps `ev.session.>` and adds one tap per configured spec outside that namespace, so both a concrete subject and a trailing-`>` prefix work (`:118–135`); a spec whose command env var is unset is silently dropped at boot (`:105–109`)
- FIX: add "Matching is first-match-wins over the comma-separated list; a subject whose `NIF_HOOKS_<SUBJECT>` is unset is ignored at startup (the component logs `watching …` only for the ones it will run)."

## A233 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 884 "The `hooks` component (off by default)"
- CODE: off-by-default is `manifest.yaml:212–218` (`autostart: false`, `required: false`, `restart: on-failure`) while the binary is still built by `make all` (`Makefile:266–269`, `:298`)
- FIX: append "(built anyway, so enabling it is `NIF_HOOKS_*` + `core.spawn hooks var/bin/hooks` — no rebuild needed)".

## A234 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (nothing says where hook failures land)
- CODE: hook stdout/stderr go to the hook's own stderr → the supervisor's `var/logs/hooks.log` (`core/supervisor.nim:126–138,202`), never into logfile's `var/logs/*.jsonl` (logfile only persists what it hears, default `ev.log.>`)
- FIX: add to the section: "Failures are written to the component's own stderr, which the supervisor captures in `var/logs/hooks.log` — hook output never appears in logfile's JSONL, which persists bus traffic only."

## A235 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 906–907 "Worked examples … live in `components/hooks/README.md`"
- CODE: the README exists (116 lines, `components/hooks/README.md`) — but the component's own header comment points at `docs/HOOKS.md` (`components/hooks/main.nim:2`), and **`docs/` contains no HOOKS.md**
- FIX: fix the code comment (not MANUAL) to cite `components/hooks/README.md`, or add the missing doc.

## A660 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "Hook stdout and stderr go to the component's own log, `var/logs/hooks.log`"
- CODE: components/hooks/main.nim:78-81; sdk/niffler/procutil.nim:83-89,132
- FIX: update — [wrong] replace the sentence with "A **failing** hook's combined output is echoed to the component's stderr and lands in `var/logs/hooks.log` (the supervisor redirects child output there); a hook that exits 0 has its stdout and stderr discarded. Neither path writes into logfile's JSONL, which persists bus traffic only." Reproduced: with `NIF_HOOKS_EV_LOG_ERROR='echo HOOK-STDOUT; echo HOOK-STDERR 1>&2; true'` and one published `ev.log.error`, the log holds the two banner lines and neither marker; with `'echo FAIL-OUT; echo FAIL-ERR 1>&2; exit 3'` it holds `hooks: exit 3 on ev.log.error`, `FAIL-OUT` and `FAIL-ERR`. `README.md:6-8` states the failing-hook fact correctly, so the MANUAL sentence is the outlier.

## A661 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "payload is piped to the command's stdin as pretty JSON — written to a temp"
- CODE: components/hooks/main.nim:59-66,73-78
- FIX: add — [missing] after that clause: "the payload handed over is the event *payload* — the envelope (`{v, id, kind}`) is stripped, and a message that is not an envelope passes through as raw bytes — written to `getTempDir()/niffler-hook-<pid>-<n>.json` with default file permissions (it contains model output, so treat it like a capture directory) and piped in by `cat`, so `jq .payload.x` — never `jq .x` — is the hook idiom."

## A662 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "Matching is first-match-wins over the"
- CODE: components/hooks/main.nim:49-55,116-133
- FIX: update — [missing] after that clause: "only exact subjects and a trailing `>` prefix match — a `*` token never fires (the derived variable name would also contain a literal `*`), and a `>` spec fires for every message on the bus, `_INBOX.*` replies included. Keep the list disjoint." Reproduced: `NIF_HOOKS_EVENTS="ev.log.*"` logs `watching ev.log.*`, the tap matches a published `ev.log.error`, and the command still never runs.

## A663 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "Subject → env name: dots and `>` become `_`, uppercased"
- CODE: components/hooks/main.nim:37-40; components/hooks/README.md:26-28,100-108
- FIX: update — [wrong] append "so a spec that ends in `>` ends in a doubled underscore: `ev.log.>` → `NIF_HOOKS_EV_LOG__`, `ev.session.>` → `NIF_HOOKS_EV_SESSION__`". The code comment (`main.nim:38-39`) and the README's mapping line and "keep a private error tail" example all claim `NIF_HOOKS_EV_LOG_`, which is silently inert: reproduced — with that name `hooks.log` shows only `watching ev.log.error`, with the doubled name both hooks are configured.

## A664 (code-bug?)
source: `components/hooks.md`

- MANUAL: MANUAL: "comma-separated list, and a subject whose `NIF_HOOKS_<SUBJECT>` is unset at"
- CODE: components/hooks/main.nim:121-133; sdk/niffler/sdk.nim:169-173,837-843
- FIX: update the code, not the MANUAL (code bug) — [code-bug?] one NATS subscription is created per configured spec and the SDK dispatches per binding, so a message matching two specs is delivered twice and both deliveries run the *same* first-match command. Reproduced: `NIF_HOOKS_EVENTS="ev.log.error,ev.log.>"` with `NIF_HOOKS_EV_LOG_ERROR='cat >> a.jsonl'` and `NIF_HOOKS_EV_LOG__='cat >> b.jsonl'` gives 2 lines in `a.jsonl` and 0 in `b.jsonl` for one published event. Fix: dedupe per delivered message, or reject overlapping specs at boot; `tests/t_hooks.nim` covers a single spec only. Until then the MANUAL clause above should end "keep the list disjoint".

## A665 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "The `hooks` component (off by default — an autostart flag, not a build one:"
- CODE: components/hooks/main.nim:107-109 (zero tools)
- FIX: add — [missing] "It registers no tools at all — the interface is the environment plus the bus; configured with no `NIF_HOOKS_<SUBJECT>` set it logs `watching nothing, staying up` and keeps running."

## A666 (trim)
source: `components/hooks.md`

- MANUAL: MANUAL: "desktop notification, sound alert, email, webhook, error tail — live in"
- CODE: components/hooks/README.md:32-37; core/conversation.nim:1745,1762-1768; docs/WIRE.md:169-207
- FIX: add — [missing] name the useful subjects here and point at the bus inventory: "the events worth watching are `ev.session.turn` (turn boundaries), `ev.session.done` (carries `reply`), `ev.session.status` (per LLM round), `ev.session.context` (warn/trim/reset) and `ev.log.<component>`; their payload fields are listed under [The bus in one screen](#the-bus-in-one-screen)."

## A667 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "failures and timeouts (default 10s, max 60s) are logged and never fatal,"
- CODE: components/hooks/main.nim:78-83; sdk/niffler/procutil.nim:117-132
- FIX: none — [verified] a non-zero exit and a timeout both log to the component's stderr and never raise; the timeout kills the process group and reports exit 124.

## A668 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "approval decisions live in core's dispatch gate."
- CODE: components/hooks/main.nim:8-12,114-135
- FIX: none — [verified] the observe-only claim holds: the component has no tools and never touches core's approval path.

## A669 (code-bug?)
source: `components/hooks.md`

- MANUAL: MANUAL: "which persists bus traffic only."
- CODE: components/hooks/README.md:4-8
- FIX: update the README, not the MANUAL (code bug) — [code-bug?] `README.md:4-8` still reads "the firing subject is in `$NIF_HOOK_SUBJECT`... actually just stdin": no such variable exists anywhere in the tree (`grep -rn NIF_HOOK_SUBJECT` → the README only), so the sentence should be deleted; the MANUAL claim it sits next to (hook output going to `var/logs/hooks.log`) is itself corrected by the first row of this group.

## A670 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "| `NIF_HOOKS_EVENTS` | comma-separated bus subjects the hooks component watches; trailing `>` wildcards work. Read at boot — a config change is `core.kill` + `core.spawn` | `ev.session.turn` |"
- CODE: components/hooks/main.nim:100-105
- FIX: none — [verified] default `"ev.session.turn"`, comma-split, stripped, empty entries skipped, only listed subjects considered; "trailing `>` wildcards work" is right (and the `*` limitation is the row above).

## A671 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "| `NIF_HOOKS_<SUBJECT>` | the shell command run for one watched subject (dots and `>` become `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`); event payload piped to stdin as JSON | unset |"
- CODE: components/hooks/main.nim:37-40,103-105
- FIX: update — [wrong] "the shell command run for one watched subject (uppercased, every `.` and `>` becomes `_`: `ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` → `NIF_HOOKS_EV_LOG__` — a trailing dot and a trailing `>` each contribute an underscore); event payload piped to stdin as JSON".

## A674 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "ev.session.turn        {sessionId, turnId, phase: start|done, content?, error?}"
- CODE: core/conversation.nim:1762-1768,2915-2917
- FIX: none — [verified] that is the whole `ev.session.turn` payload; there is no `reply` field, and this inventory is the right place for the Hooks section to point at.

## A675 (code-bug?)
source: `components/hooks.md`

- MANUAL: MANUAL: "ev.session.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}"
- CODE: components/hooks/README.md:34; core/conversation.nim:1745
- FIX: update the README, not the MANUAL (code bug) — [wrong] `README.md:34` claims `reply` rides `ev.session.turn`; it rides `ev.session.done` (as the MANUAL and `docs/WIRE.md:207` both say). Every README example built on `.payload.reply` (the sound gate, "email a session summary") therefore emits nothing on `ev.session.turn`; the examples should subscribe to `ev.session.done` or read `.payload.content` from `ev.session.turn`'s `start` phase.

