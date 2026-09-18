# Worklist slice: The store

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A015 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line ~185 "All engines enforce single-writer the same way: one process owns the file (flock; kernel-released on crash), everyone else speaks envelopes."
- CODE: this contradicts the section's own tidb bullet 40 lines above ("No flock — the cluster is shared state by design", MANUAL 173-181; `components/store-tidb/main.go:71` DSN, no lock file)
- FIX: "The file-backed engines are single-writer by flock (kernel-released on crash); tidb has no file to lock — the cluster is shared by design and row locks plus the rev counter arbitrate between harnesses."

## A016 (doc-edit, dup:mechanisms-obs.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 189-193 the `list` page paragraph (`nextAfter` back as `after`)
- CODE: accurate but incomplete — `limit` defaults to **100** and is clamped to 1000, `after` is exclusive, `nextAfter` is absent when `hasMore` is false (`components/store/main.nim:130,145-168`)
- FIX: add the default and the cursor rule; also fix the "an `nextAfter`" typo. `[dup]` mechanisms-obs.md.

## A092 (doc-edit, dup:mechanisms.md)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2172-2190 kind table, labelled "**Kinds in use by core**"
- CODE: omits `profile` (`core/dispatch.nim:394-402`), `approval`, `contextreceipt`, `compaction_input`, `context_projection`, `spill`, plus the component kinds `mcp` and the throwaway `selftest`
- FIX: apply the table in `mechanisms-obs.md` ("Kind / event inventory"). `[dup]` mechanisms.md + mechanisms-obs.md.

## A093 (doc-edit, dup:mechanisms-obs.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2171-2185 "`put` / `get` / `list` / `del` and rev-based optimistic concurrency (`put` accepts `expectRev` and fails with `rev-conflict` on mismatch)"
- CODE: `components/store/main.nim:171-178` (`del` hidden); the kind-restriction rule ("a session-bound caller may only write `fabricprog`; everything else is `forbidden-kind`, `'<kind>' is harness-managed`" at `:100-105`) is missing from MANUAL
- FIX: state both — it is the rule that explains why a model cannot corrupt the store. `[dup]` mechanisms-obs.md.

## A094 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2200 "Backend is the selected engine — SQLite at `var/store.db` by default, or BitBarrel at `var/barrel-db` with `NIF_STORE_BACKEND=barrel`. **Exactly one process owns that file**"
- CODE: accurate (tidb is deliberately absent from this sentence but the section should name it for symmetry) ✔
- FIX: add "or the DSN-shared TiDB engine (`NIF_STORE_TIDB_DSN`, no flock)".

## A162 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~2156 "`store` is a component like any other — put/get/list/del ..."
- CODE: `components/store-sqlite/main.go:112-115` + `:498` (del hidden)
- FIX: state that `del` is hidden/LLM-unreachable here too (core only).

## A243 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 2169–2196 §The store never mentions paging at all, while the only statement of it lives in §Store engines (189–193)
- CODE: the canonical contract is the store tool's own docstring (`components/store/main.nim:130–150`) and `core/dispatch.nim:202–235` (`storeListAll` vs capped `storeListItems` at `:189–200`)
- FIX: move/summarize the paragraph into §The store (with a cross-link from §Store engines) and add "everything in core that must see a whole kind goes through `storeListAll` — a single `list` silently truncated long transcripts on resume."

## A244 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 2172–2190 kind table
- CODE: the table omits core kinds actually written today — `profile` (`core/dispatch.nim:394`), `approval` (read `core/niffler.nim:580`, `core/session.nim:58`; written by clients), `contextreceipt` (`core/conversation.nim:296`), `compaction_input` (`:1424–1426`, read `:1315`), `context_projection` (`:1579`), `spill` (`:1196`)
- FIX: extend the table with those six, one row each, with a one-line value description (e.g. "`spill` | `<convId>:<n>` | oversized tool result spilled out of the context window"; "`approval` | `<sessionId>:<key>` | a client's 'don't ask again' grant, keyed by tool or `tool:<digest>` for program-shaped calls").

## A245 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 2172–2190 kind table, component kinds
- CODE: also missing `mcp` (server config records: `components/mcp/types.go:12`, written `components/mcp/main.go:581`, listed `:170`), and the transient `selftest` kind the store's own self-test writes and deletes (`components/store/main.nim:189,219`)
- FIX: add the `mcp` row (id = server name; the MCP section, MANUAL:1165–1198, describes the record but never names the kind) and note `selftest` is throwaway.

## A246 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (nothing says who may write which kind)
- CODE: a call arriving with a live session may only `put` curated kinds — everything except `fabricprog` is refused with `forbidden-kind`/`"<kind>' is harness-managed"` (`components/store/main.nim:100–105`); `del` is `hidden` from the LLM and core-only (`components/store/main.nim:171–178`)
- FIX: add to §The store: "A session-bound caller may only write curated kinds (`fabricprog` today); every other kind is harness-managed and refused with `forbidden-kind`. `get`/`list` are on-demand tools; `del` is hidden (core deletes records, the model cannot)."

## A247 (trim)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (minor)
- CODE: the store tool docstrings claim a kind inventory that is stale — `get` says "Kinds in use: conversation, message, component" (`components/store/main.nim:120–122`), `list` similar (`:130–135`)
- FIX: not a MANUAL change; if the docstrings stay, MANUAL's kind table should be the authoritative list (they are the LLM-visible text, so a pointer sentence in the section is cheap).

## A258 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:2172–2190 kind table is labelled "kinds in use by core" yet omits six core kinds and the `mcp` component kind (file:line in the table below).

