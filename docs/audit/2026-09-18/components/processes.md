# Audit — `components/processes/` (Nim, 528 lines, one file)

Scope: `components/processes/main.nim` (528 lines), `manifest.yaml:172-181`,
`components/bash/main.nim:105-155`, `docs/MANUAL.md:1033-1083` (+ rows 55, 57,
246, 299-300), `docs/WIRE.md:317-343`, `core/conversation.nim:1005-1075`,
`tests/t_processes.nim`. Read-only audit; no builds/tests run.

Status: **already documented** in MANUAL (the section exists). Deltas are
numeric/semantic gaps, not a missing section. The one substantive doc defect is
an **unimplemented cap claim** (finding 1).

## 1. What it offers

- Long-running commands with an owner: start once, poll incremental output,
  kill explicitly — the contract `bash` deliberately does not have
  (`main.nim:1-11`; `manifest.yaml:172-175`).
- `process_start` forks the command as a process-group leader, stdin
  `/dev/null`, stdout/stderr appended to spool files under `var/processes/`,
  and returns an id immediately (`main.nim:295-329`).
- `process_poll` drains only bytes appended since the last poll from per-stream
  cursors — never a pipe, so the OS absorbs bursts (`main.nim:17-22, 218-247`).
- The component owns the child for its whole life: it reaps on a 500 ms idle
  tick (`main.nim:478-483`) and publishes an exit notice to the owning
  conversation (`main.nim:443-472`).
- Crash-safe by construction: children survive a SIGKILLed component and the
  next component life sweeps orphans via `registry.json` + /proc starttime
  (`main.nim:22-25, 115-143`).

## 2. Tools (exactly four)

All four are registered with `onDemand: true` → **discover-only** (kept out of
the frozen direct toolset; reached via `discover` + `invoke`)
(`main.nim:500, 514, 521, 526`; MANUAL:1079). Component name `processes`,
version `0.1.0` (`main.nim:441`).

| Tool | Purpose (from doc comment) | `x-harness` | line |
|---|---|---|---|
| `process_start {command, label?, workdir?}` | Start a long-running command detached; return its id | `approval: always`, `timeoutMs: 20000`, `onDemand`, `workspace: {cwdField: "workdir"}` | `main.nim:491-501` |
| `process_poll {id, waitMs?, filter?, tail?}` | Read *incremental* output; each poll returns only what was appended since the previous one | `timeoutMs: 30000`, `onDemand`, `effect: "read"` (no approval) | `main.nim:503-514` |
| `process_kill {id}` | Terminate the whole process group (SIGTERM → SIGKILL) | `approval: always`, `timeoutMs: 15000`, `onDemand` | `main.nim:516-521` |
| `process_list {}` | List ids, labels, commands, status | `timeoutMs: 10000`, `onDemand`, `effect: "read"` | `main.nim:523-526` |

- Params: `label` defaults to the first command word, truncated to 80 chars
  (`main.nim:290-292`); `waitMs` is clamped to `MAX_WAIT_MS = 25_000`
  (`main.nim:40, 335`); any non-empty `tail` re-reads the last
  `TAIL_BYTES = 64 KiB` of raw output and skips draining entirely
  (`main.nim:36, 339-361`); `filter` is a regex applied to the drained chunk
  while the cursor still advances past everything (`main.nim:250-262, 383-392`).
- Return fields are machine-readable as well as textual: `process_start` gives
  `id`/`label`/`pid`/`text` (`main.nim:325-329`); `process_poll` gives `id`,
  `label`, `status`, `exit_code`, `started_at`, `new_bytes`, `lines`, `matched`,
  `text` (`main.nim:405-410`); `process_list` gives `processes[]` with the same
  per-entry fields plus `command` (`main.nim:428, 435-436`).
- **Relation to `bash`**: `bash`'s `run_in_background: true` is a thin producer
  — it calls `processes.process_start` (15 s request timeout), rewrites the
  text to point at `process_poll`/`process_kill`, and returns without blocking
  (`components/bash/main.nim:131-149`). The two differ in one important way:
  bash forwards the owning `session` (`components/bash/main.nim:139`), which is
  what makes the exit notice possible; the schema of `process_start` carries no
  `x-harness.sessionId` (`main.nim:500`), so an LLM-invoked `process_start` is
  anonymous. If the component is down, bash returns `[E_BACKGROUND]` and tells
  the model to run synchronously (`components/bash/main.nim:149-153`;
  MANUAL:1080-1083).
- `bash` itself remains the default for anything that finishes: synchronous,
  timeout + output spill (`components/bash/main.nim:110-118`; MANUAL:55).

## 3. Configuration

Constants (`main.nim:31-40`) and the two env overrides:

| Setting | Env var | Default | file:line |
|---|---|---|---|
| Spool cap before truncation | `NIF_PROCESSES_SPOOL_CAP` | `SPOOL_CAP = 32 MiB` (33554432) | `main.nim:38, 42-47` |
| Bytes kept when truncating | — (hardcoded) | `SPOOL_KEEP = 2 MiB`, used as `min(2 MiB, cap div 2)` | `main.nim:39, 206` |
| Max new bytes per stream/poll | `NIF_PROCESSES_POLL_CHUNK` | `POLL_CHUNK = 64 KiB` (65536), clamped to `[1024, 1048576]` | `main.nim:35, 49-57` |
| Raw tail size for `tail=true` | — (hardcoded) | `TAIL_BYTES = 64 KiB` | `main.nim:36, 346` |
| Concurrent running processes | — (hardcoded) | `MAX_LIVE = 32` → `E_LIMIT` | `main.nim:33, 283` |
| Finished entries retained | — (**declared, never used**) | `KEEP_FINISHED = 50` — dead constant, see finding 1 | `main.nim:34` |
| Kill grace | — (hardcoded) | SIGTERM, `sleep 300`, refresh, SIGKILL, `sleep 100`, refresh | `main.nim:183-193` |
| Poll wait granularity / cap | `waitMs` arg only | slice 100 ms, cap 25 s | `main.nim:39-40, 335, 370` |
| Idle reap interval | — (hardcoded) | `onIdle(500)` ms | `main.nim:478` |

**Files and state (no store use at all).** `rootVarDir("processes")` =
`$NIF_ROOT/var/processes` (`sdk/subjects.nim:38-41`), holding `registry.json`
(`main.nim:104`), `pN.out` / `pN.err` spools (`main.nim:295-296`) and a
`nextId` counter persisted in the same file (`main.nim:106-113, 124`).
`registry.json` records **only running** entries — `{id, pid, starttime}` — so
the boot sweep has exactly what it needs (`main.nim:106-113`). `main.nim`
contains **no** `store`/`storePut`/`storeList` reference: this component writes
no store kind. The exit notice travels over the steer lane
`svc.session.<sanitized-id>.steer` with a
`{"notice": {kind: "process-exited", …}}` payload (`main.nim:461-472`), the same
lane subagent settlement notices use (`docs/WIRE.md:325-338`), and has **no
durable record** — the process entry itself is the record
(`docs/WIRE.md:340-343`).

**Child lifetime.**
- While the harness runs, nothing is killed automatically: the child outlives
  the turn that started it and is visible in every later turn
  (`main.nim:516-519`; MANUAL:1077).
- The owning **conversation** matters only for the notice: the runner folds a
  `process-exited` notice in as an appended, structurally marked user message
  — immediately if the parent is mid-turn (steer lane), otherwise at the top of
  the next turn (`core/conversation.nim:1005-1035, 1066-1075`;
  MANUAL:1997-2013). Turn end by itself does not touch the child.
- **Harness stops (graceful)**: `onDrain` kills every entry
  (`main.nim:484-488`), and `onDrain` fires on SIGTERM/SIGINT/`ev.sys.drain`
  (`sdk/niffler/sdk.nim:33, 393-397, 760`).
- **Component SIGKILLed**: children (process-group leaders) keep running; the
  next component start sweeps them by comparing the recorded /proc starttime
  (pid-reuse guard) and wipes stale spools (`main.nim:115-143`;
  `tests/t_processes.nim:270-299`). No PDEATHSIG is set in the fork child
  (`main.nim:305-318`) — the sweep, not the kernel, is the mechanism.

## 4. MANUAL placement

- The section **already exists**: `## Background processes (`processes`)` at
  `docs/MANUAL.md:1033`, body `1033-1083`, between
  `## Language servers (`lsp`)` (934) and `## External MCP servers (`mcp`)`
  (1085). Anchor `#background-processes-processes`.
- Other places that already point at it: shipped-components row
  `docs/MANUAL.md:57`, bash row with the `run_in_background` hand-off
  (`docs/MANUAL.md:55`), `var/` state row listing `processes/` spools
  (`docs/MANUAL.md:246`), env table rows `docs/MANUAL.md:299-300`.
- Wire-level description: `docs/WIRE.md:325-343` ("Settlement notices",
  process-exited paragraph).
- **Verdict: keep the heading and location; add no new section.** Every delta
  below is an edit inside 1033-1083 plus (optionally) two footnote lines in the
  env table. The section is the right size (51 lines) and the right place: a
  component contract, adjacent to lsp/mcp.

## 5. DELTA list (MANUAL vs code)

Ordered by importance. "→" is the proposed MANUAL edit.

1. **[wrong claim] The 50-finished-entry cap does not exist.**
   `KEEP_FINISHED = 50` (`main.nim:34`) is declared and **never referenced**;
   `gProcs` has no eviction path (`main.nim:76, 323`, only `clear()` at
   shutdown `main.nim:487`), so finished entries accumulate for the component's
   lifetime and `process_list` returns all of them (`main.nim:421-436`).
   MANUAL:1055-1056 asserts "the 50 most recent finished entries stay in the
   registry". → either implement the cap (evict oldest terminal entries past
   50) **or** replace the claim with "the registry keeps every process of this
   component's lifetime, running and finished; only running ones are persisted
   to `registry.json`".
2. **[missing number] Kill grace.** `process_kill` = SIGTERM → 300 ms → SIGKILL
   → 100 ms, hardcoded (`main.nim:183-193`); MANUAL:1044 says only "Terminate
   the whole process group". → add "(SIGTERM, 300 ms grace, then SIGKILL)".
3. **[missing number] What truncation keeps.** `truncateSpool` keeps
   `min(SPOOL_KEEP = 2 MiB, cap div 2)` bytes (`main.nim:39, 199-217`) and the
   truncating poll appends `[spool truncated to its tail — the cap was
   reached]` (`main.nim:404`). MANUAL:1051-1052 says only "truncated to its
   tail". → state "keeps the last 2 MiB (or half the cap, whichever is
   smaller)".
4. **[wrong scope] An LLM-invoked `process_start` is anonymous.** The tool
   schema has no `x-harness.sessionId` (`main.nim:500`), and only bash passes
   `session` (`components/bash/main.nim:139`); so `process_start` reached via
   `discover`/`invoke` never gets an exit notice. MANUAL:1069-1071 lists "a
   direct `process_start`, e.g. from `cli`" — → widen to "started by anything
   other than `bash run_in_background` (the model's own `invoke`, `cli`, a
   script)".
5. **[imprecise] "Processes die with the harness" (MANUAL:1077).** True for a
   graceful stop (`onDrain` → `killEntry` on every entry, `main.nim:484-488`,
   fired on SIGTERM/SIGINT/`ev.sys.drain`, `sdk/niffler/sdk.nim:33, 393-397`),
   but a SIGKILLed component leaves them running until the **next component
   start** sweeps them (`main.nim:115-143`). → "die when the `processes`
   component stops; if it is killed, the next start sweeps the orphans".
6. **[missing] Per-tool timeouts**: start 20 s, poll 30 s, kill 15 s, list 10 s
   (`main.nim:500, 514, 521, 526`). MANUAL:1043 documents only the 25 s
   `waitMs` cap. → one line in the table or Details.
7. **[missing] `workdir` fallback.** Schema says "default: workspace"
   (`main.nim:497`); core substitutes the conversation workspace when the field
   is empty or relative (`core/dispatch.nim:1437-1446`), so that default holds
   only for calls that go through core dispatch; a bare
   `cli call process_start` leaves it empty and the child inherits the
   component's cwd (`NIF_ROOT`). A non-existent `workdir` fails with
   `E_BAD_SHAPE` (`main.nim:291`). → one sentence.
8. **[missing] Env validation asymmetry.** `NIF_PROCESSES_POLL_CHUNK` is
   clamped to `[1024, 1048576]` (`main.nim:49-57`); `NIF_PROCESSES_SPOOL_CAP`
   is parsed without bounds (`main.nim:42-47`) and feeds
   `keep = min(2 MiB, cap div 2)` (`main.nim:206`) — a tiny/negative cap can
   empty a spool on the next poll. MANUAL:299-300 lists both as plain defaults.
   → add "clamped to 1 KiB-1 MiB" and "must exceed the keep size".
9. **[missing] Error codes**: `E_LIMIT` (≥32 live) `main.nim:283`, (fork
   failure) `main.nim:319`; `E_NOT_FOUND` `main.nim:270`; `E_BAD_SHAPE` (empty
   command `main.nim:277`, missing workdir `main.nim:291`, invalid filter regex
   `main.nim:256`). MANUAL lists none. → optional, low priority.
10. **[missing] Spool naming and boot wipe**: `var/processes/pN.out` / `pN.err`
    (`main.nim:295-296`), all `*.out`/`*.err` deleted at boot
    (`main.nim:130-141`), ids continue from the persisted `nextId` and never
    restart at `p1` (`main.nim:106-113, 124, 293-294`). MANUAL:246 mentions only
    "`processes/` spools". → half a line; useful for debugging.
11. **[missing] Must not be replicated.** `manifest.yaml:176-181` sets no
    `replicas` (→ 1), which is required: the registry is in-memory and this
    process is the single writer of `registry.json` and the spools. MANUAL
    never says so. → one sentence in Details (cross-ref AGENTS.md's
    stateless-only rule for replicas).
12. **[attribution] The peek UI is the niffler-tui plugin.** `process_list` +
    `process_poll {tail: "1"}` and the `bg N` status line live in
    `var/plugins/niffler-tui@main/tui/processes.go:5-10, 54, 77` and
    `…/tui/main.go:2741-2743`; nothing in `ui/frontend` or `core/tty.nim`
    references the process tools. MANUAL:1072 shows `bg 1 (7m)` without saying
    where it is rendered. → name the plugin (or drop the example).
13. **[verified, no change]** These MANUAL claims are exactly right and were
    re-checked: four tools + on-demand/discover-only (1079); 32 concurrent cap
    (1055, `main.nim:33, 283`); drain semantics and filter-cursor behaviour
    (1043, `main.nim:250-262, 383-392`); 64 KiB raw tail (1043,
    `main.nim:36, 346`); per-stream cursors and O_APPEND spools (1047-1052);
    exit notice text and its two lanes (1055-1071,
    `core/conversation.nim:1005-1075`); `E_BACKGROUND` fallback (1080-1083,
    `components/bash/main.nim:149-153`); boot sweep + pid-reuse guard
    (1074-1077, `main.nim:93-143`); env defaults (299-300).

## 6. Not user-facing

- Keep out of MANUAL: the cursor/truncation arithmetic (`main.nim:218-247`),
  `atomicWrite` temp-file publication (`main.nim:85-91`), the `onIdle(500)`
  reap interval, the `swept`/`notified` bookkeeping flags (`main.nim:73-74`),
  and the `session` argument of `process_start` (`main.nim:322`) — it is private
  plumbing supplied by bash, not a tool parameter, and must not be advertised.
- User-facing and worth keeping: the four tools, their approval/effect flags,
  the caps and env overrides, the spool directory, the exit notice, and the
  lifetime rules (survives turns; dies with the component/sweep).

**Finding count: 13** (1 wrong claim / doc-vs-code defect, 4 missing or
imprecise user-facing facts, 7 missing details of varying priority, 1
verified-OK list). No code was modified; report only.
