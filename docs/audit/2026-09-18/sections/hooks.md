# Worklist slice: Hooks

From `worklist.tsv` (6 rows). `class` is one of
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

