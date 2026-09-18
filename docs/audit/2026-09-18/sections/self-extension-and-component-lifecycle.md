# Worklist slice: Self-extension and component lifecycle

From `worklist.tsv` (10 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A042 (doc-edit, dup:mechanisms.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 646 "`builder.build {lang, name, source}` compiles it into `var/bin/`"
- CODE: also `files` (extra Go sources) and `defines` (`components/builder/main.nim:50-51`)
- FIX: add the two optional fields. `[dup]` mechanisms.md.

## A043 (doc-edit, dup:mechanisms-obs.md)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 648-649 "`core.kill {name}` … (restored on next boot); `core.remove {name}` stops the group and deletes its persisted record"
- CODE: `core/dispatch.nim:325-347`, `core/supervisor.nim:217-246`; note the registered names are `spawn`/`kill`/`remove` (`core/catalog.nim:68,81,89`)
- FIX: name them `spawn`/`kill`/`remove` and say "the core-* prefix is how the docs refer to them". `[dup]` mechanisms-obs.md / mechanisms-sessions.md.

## A044 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 651-666 (replicas 1–16, queue group, single-writer warning, `ToolConcurrent`/`ConcurrentLimit`, `x-harness.parallel`)
- CODE: `core/catalog.nim:79-95,295`, `core/dispatch.nim:1631-1654` ✔
- FIX: none.

## A045 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — restart policy is never described in prose
- CODE: `never | on-failure` with 0.5 s→8 s backoff (`core/supervisor.nim:14-16,33-49`), manifest per entry (`manifest.yaml`), `core.spawn` always `on-failure`, runners always `never`
- FIX: apply the `mechanisms-sessions.md` wording; it is the missing paragraph that explains both "restored on next boot" and the boot crash-loop symptom at MANUAL 2322.

## A158 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~646 "`builder.build {lang, name, source}` compiles it into `var/bin/`"
- CODE: `components/builder/main.nim:50-51` also accepts `files` (extra Go sources) and `defines`
- FIX: "`builder.build {lang, name, source, files?, defines?}`".

## A159 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 651-666 (replicas 1–16, queue group, single-writer warning, `ToolConcurrent`/`ConcurrentLimit`, `x-harness.parallel`)
- CODE: CODE: `core/catalog.nim:79-95` (spawn/kill/remove replicate semantics), `core/dispatch.nim:1631-1654` (parallel + approval/noSpawn/session-context exclusions) ✔ (no delta).

## A160 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~669 "spawned components are recorded in the store (kind `component`)"
- CODE: CODE: `core/dispatch.nim:318` (put), `:344`/`core/niffler.nim:590` (del on remove) ✔.

## A187 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 648-649 "`core.kill {name}` stops every replica temporarily (restored on next boot); `core.remove {name}` stops the group and deletes its persisted record"
- CODE: `core/dispatch.nim:325-347`; `core/supervisor.nim:217-246` (`removeChild` sets `wanted = false`, SIGTERMs the whole group, 600 ms grace, SIGKILL, drops the children)
- FIX: accurate for components; add one clause for runners: "`core.kill {name: "session-<id>"}` is also only temporary — the next session call re-ensures that runner from the store, which is why the tty `status` line reports live runners as supervised children."

## A188 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (restart policies never described in prose)
- CODE: `core/supervisor.nim:14-16,33-49`; `core/niffler.nim:513-514` (per-manifest-entry `restart`, unknown → `on-failure`); `core/niffler.nim:600-620` (restore path re-reads the persisted `policy`)
- FIX: add: "Each supervised child carries a restart policy — `never` or `on-failure` (the default; 0.5 s→8 s exponential backoff, `supervisor.nim:33-39`). The manifest sets it per component, `core.spawn` always uses `on-failure`, and session runners are always `never`."

## A800 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:928-931 `**Persistence of shape**: spawned components are recorded in the store (kind `component`) and restored on normal boot.` (and MANUAL:896-897 `kill {name}` stops every replica temporarily (restored on next boot); `remove {name}` stops the group and deletes its persisted record.)
- CODE: `core/niffler.nim:600-604` — the restore loop **skips** a stored record whose name is already in the manifest (`# shipped manifest definition wins`), with no warning; `remove` leaves no tombstone, so a manifest component always returns at boot regardless of `kill`/`remove`
- FIX: update — append: "A stored record whose name is also declared in `manifest.yaml` is skipped on restore (the shipped definition wins, silently), so replacing a shipped component means editing the manifest — `kill`+`spawn` under the same name only holds for the current boot."

