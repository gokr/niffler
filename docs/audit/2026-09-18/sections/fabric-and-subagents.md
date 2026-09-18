# Worklist slice: Fabric and subagents

From `worklist.tsv` (9 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A086 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1988-1996 driver signatures list `thinking?`
- CODE: `components/agent/main.nim:977,1121` accept it and it is frozen at the child's first turn (like `model`), which the table explains for `session` continuations but not for a fresh child
- FIX: one clause "(a fresh child's `thinking`/`model`/`tools`/budgets are frozen at its first turn, exactly as `session` freezes them)".

## A165 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 1988/1989 driver signatures "`agent_run {task, session?, close?, fork?, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}`"
- CODE: `components/agent/main.nim:977,1121` both schemas also take **`modelTier`** (`weak|medium|strong`, resolves via `NIF_AGENT_MODEL_*`, clamped to the parent)
- FIX: add `modelTier?` to both rows and note it is mutually exclusive with `model`.

## A166 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 1994 "`agent_list {scope?}` ... `scope: "descendants"` walks the whole tree (**depth 1 today**)"
- CODE: `components/agent/main.nim:1536-1538,1567,1638` — `descendants` **recurses** the whole tree, `children` is depth 1; real nesting exists whenever `NIF_AGENT_MAX_DEPTH > 1` (`core/dispatch.nim:1477-1490`)
- FIX: delete "(depth 1 today)"; say "`descendants` recurses the whole tree (bounded by `NIF_AGENT_MAX_DEPTH`)".

## A167 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: absent from the agent tool table (`agent_run`, `agent_spawn`, `agent_status`, `agent_wait`, `agent_stop`, `agent_steer`, `agent_list`, `agent_notices`)
- CODE: **`agent_ask`** (`components/agent/main.nim:1419`, approval-gated, 900 s)
- FIX: add a row: "`agent_ask {session_id, question}` — one mid-flight question to a live child".

## A168 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 1958-1996 (fabric row, approval manifests, guards, guest API, context economy) matches CODE `components/fabric/fabric.nim:108-129` (fabric-exec + var/fabric-cache), `:622` (approval always), `:654` (`fabric_help`) ✔; note `manifest.yaml`'s own comment ("guests run in the Nim VM") is the stale one — MANUAL is right that it compiles a private process.

## A169 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 2017-2075 (continuation is append-only, authorization by `sessionmeta.parent`, activation ledger, fork cut/provenance) matches `docs/WIRE.md` "Subagent continuation"/"Subagent fork" and `components/agent/main.nim:493,585,752,1113,1216` ✔ (no delta).

## A237 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (`var/approval-sources/` is nowhere in MANUAL, not even the `var/` row of the state table at MANUAL:244, which lists `logs/`, `captures/`, `processes/` …)
- CODE: `core/approval.nim:99–121` creates `$NIF_ROOT/var/approval-sources/<digest>.nim` with mode 0600
- FIX: add `approval-sources/` (0600 program source awaiting/recorded for approval) to the `var/` row and to §Approvals.

## A340 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2084 ("The executor child holds no NATS connection and no credentials")
- CODE: components/fabric/fabric.nim:120-126
- FIX: extend the clause — "…no NATS connection, no credentials and no inherited `NIF_*` environment: the child gets only `PATH`, `HOME`, `TMPDIR` and the cache path."

## A341 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:1987 ("an identical program is cached in `var/fabric-cache`")
- CODE: components/fabric/fabric.nim:535-536, 538-560 (64 entries / 128 MB LRU eviction)
- FIX: add "cache is self-bounded (64 entries / 128 MB, evicted least-recently-stored)" — otherwise a user reading the MANUAL expects unbounded growth.

