# Worklist slice: The store

From `worklist.tsv` (37 rows). `class` is one of
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

## A574 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "Direct bus callers (cli, tests, core) keep full access."
- CODE: components/cli/main.nim:112-114 (direct `svc.store.call`), components/store-sqlite/main.go:498 (`del` hidden from the LLM)
- FIX: fix: none — verified [verified]

## A622 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "the paged pre-compaction snapshot the compaction component verifies and the runner commits from"
- CODE: `core/conversation.nim:1405-1418` (`cleanupSnapshot`), `core/compaction.nim:26` (600 s sweep), `core/conversation.nim:2683`
- FIX: add — "transient: deleted as soon as the attempt settles, and orphaned pages from a crashed or timed-out attempt are swept after 600 seconds. Nothing must treat it as durable; only `context_projection` is."

## A623 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "the committed context projection (cut, checkpoint, generation) a runner reuses after compaction"
- CODE: `core/compaction.nim:333-360` (`buildProjectionRecord`), `core/conversation.nim:1684-1693` (single `expectRev` put), `core/conversation.nim:2677-2748` (reload)
- FIX: add — "one document per conversation, holding `version`, `generation`, `canonicalHigh`, the renderer id, the normalized `checkpoint`, the durable `covered` canonical range, the `retained` canonical id list, `prunes`, `measurements` and `provenance`; it is written once with `expectRev` on the previous generation and is the source of truth a restart rebuilds the provider view from."

## A642 (trim)
source: `components/recall.md`

- MANUAL: MANUAL: "an oversized tool result promoted out of the context window, addressable with"
- CODE: `core/conversation.nim:1287-1314`, `components/recall/main.nim:162-185`
- FIX: add — "Promotion is best-effort at append time: when it succeeds the notice names the `spill` ref; when it fails the message keeps only the temp-file pointer. A missing, empty or malformed spill document is refused loudly (never answered as an empty success), and the prune gate re-verifies the document before pruning, so a broken spill can never cost the last copy."

## A643 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "the committed context projection (cut, checkpoint, generation) a runner reuses after compaction"
- CODE: `components/recall/main.nim:195-217`
- FIX: add — "the resolver reads this record's `checkpoint` and `generation` when a notice names a `checkpoint` ref".

## A730 (doc-edit)
source: `components/store.md`

- MANUAL: :337-339 "It reads **every document** from the source engine over the bus contract (so **any engine pair works, including TiDB**)" — the kind set is a hardcoded 18-name probe list (`tools/store_migrate.nim:398-407`) that contains neither `spill` nor `contextreceipt`, so those documents are read by nobody and **silently dropped**. Measured: a barrel root seeded with `conversation`, `message`, `spill`, `contextreceipt` and `mcp` (one doc each, the store itself answering 5× `{"ok":true,"rev":1}`) migrated with `total: 3 documents read` … `wrote 3 documents into store.db` … `verified: every kind matches the source count` … `done.` — i.e. 2 of 5 documents lost **with a success report**, because the verification loop only re-counts the kinds it discovered. The source engine is also always `engineFor(root, "barrel")` (`:283-294`): a root whose data is in SQLite dies with "root already uses sqlite … nothing to migrate" even when `--to barrel` is passed (measured), so sqlite→barrel and tidb→anything do not work at all.

## A731 (doc-edit)
source: `components/store.md`

- MANUAL: :345-346 "Migration refuses to overlay an existing target database" — true in effect for the default target, but by accident and for the wrong reason: the reachable refusal is the *source* check `both store.db and barrel-db exist … ambiguous source; move one aside first` (`:290-292`), which is exactly the state a *successful* migration leaves behind (measured: the second run dies there). The overlay check itself (`:296-299`) can never fire for `--to sqlite` (the source check already guarantees `store.db` is absent) and for `--to tidb` it tests `fileExists(<root>/var/store-tidb.db)` — a marker file that nothing ever creates (`:78-84`), so migrating *into* a shared cluster overlays silently, with rev-bumping upserts.

## A732 (doc-edit)
source: `components/store.md`

- MANUAL: :347-348 "The same export/replay path moves data in **either direction**" — same as (1): only barrel→sqlite/tidb exists.

## A751 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL: absent (the migrate tool's `--force` does nothing)
- CODE: `tools/store_migrate.nim:11,40,289,444-445` (declared, documented in the header, parsed, never read)
- FIX: add (code bug) — either honour `--force` (overlay the target / tolerate a live store) or delete the flag and the two claims; the usage text does not list `--force` at all, so the header is the only place it is promised.

## A752 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL: absent (migrate drops kinds outside its probe list)
- CODE: `tools/store_migrate.nim:398-407` vs the live kinds `spill` (`core/conversation.nim:1305`) and `contextreceipt` (`core/conversation.nim:304`)
- FIX: add (code bug) — measured silent loss with a success report (§4.3); extend `kindProbes()` (and consider a kind-count tripwire that fails the run when the source's own probe list disagrees with what it discovered).

## A758 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL: absent (no statement that the store engines have **no** per-engine knobs)
- CODE: `components/store/main.nim` (only `NIF_ROOT`/`NIF_NATS_URL` via the SDK), `components/store-sqlite/main.go:127-153`, `components/store-tidb/main.go:99-135`
- FIX: add (small) — one line in §Store engines: "The engines have no store-specific environment knobs: file path, lock path, pragmas and timeouts are code-resident (`NIF_ROOT` decides the root, `NIF_STORE_BACKEND` the engine)."

## A760 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2869 "`get` and `list` are on-demand tools; `del` is hidden — core deletes records, the model cannot."
- CODE: `components/store/main.nim:89` (`put`: `{"onDemand": true, "sessionId": true}`), `:117`/`:129` (get/list onDemand), `:171` (del hidden); the same flags verbatim in `components/store-sqlite/main.go:264,358,404,498` and `components/store-tidb/main.go:229,347,393,487`
- FIX: update — "`put`, `get` and `list` are on-demand (discover-only); `del` is hidden — core deletes records, the model cannot. `put` also carries `x-harness.sessionId` (that is what makes the write fence below possible)." (The fuller statement already exists at :2066-2067; this keeps §The store from contradicting it.)

## A761 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2866-2867 "`store` is a component like any other — a document store over the bus with `put` / `get` / `list` / `del` and rev-based optimistic concurrency"
- CODE: `components/store-sqlite/main.go:106-117`, `components/store-tidb/main.go:79-90`, `sdk/niffler/sdk.nim:155-167`
- FIX: add (small) — the store also registers the hidden `selftest` tool on the barrel engine (`components/store/main.nim:181-232`): a real put/get/rev/list/del roundtrip core's `/doctor` can call.

## A762 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2883 "Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only"
- CODE: `components/provider/main.go:11,63,384` (true for `provider`), `components/mcp/types.go:19-21` + `components/mcp/main.go:85-88` (`mcp` `env`/`headers` values are stored verbatim too)
- FIX: update — "Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only. That covers the `mcp` records' `env`/`headers` values as well as `provider` keys, so any copy of `var/store.db`/`var/barrel-db` is a copy of them."

## A763 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2880 "| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |"
- CODE: `core/conversation.nim:266` (`convId & ":" & align($seqNo, 6, '0')`)
- FIX: update — "`<convId>:<seq>`, the sequence zero-padded to six digits (`…:000042`); the padding is what makes id-ordered paging match message order (see the boundary note in §6 — past 999 999 messages the width grows and lexicographic order stops matching)."

## A764 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2870 "A **session-bound caller may only write curated kinds**" ("(`fabricprog` today):", :2871)
- CODE: `components/store/main.nim:100-106`, `components/store-sqlite/main.go:281-290`, `components/store-tidb/main.go:246-255`, `core/dispatch.nim:1650-1656`
- FIX: none (verified) — the fence, the `forbidden-kind` code and the "direct bus callers keep full access" asymmetry are all exactly as written, on all three engines.

## A765 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2899 "Backend is the selected engine — SQLite at `var/store.db` by default"
- CODE: `core/niffler.nim:485-496`, `components/store-sqlite/main.go:81,135`, `components/store/main.nim:58`, `components/store-tidb/main.go:71`
- FIX: none (verified).

## A766 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:2907-2909 "everything in core that must see a whole kind goes through `storeListAll`"
- CODE: `core/dispatch.nim:224-266` (+ call sites in `core/conversation.nim:399`, `core/dispatch.nim:451,695`)
- FIX: none (verified) — the helper pages the cursor to exhaustion with a 10 000-page runaway guard.

## A767 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL: absent (barrel `put` without `value` kills the process)
- CODE: `components/store/main.nim:110-111` (`$value` on a nil `JsonNode`), `sdk/niffler/sdk.nim:723-725` (the pump catches `CatchableError` only)
- FIX: add (code bug) — measured: `put {"kind":"probe","id":"novalue"}` against `var/bin/store` returns no reply (the caller times out) and the process exits **139 (SIGSEGV)**; the same call against `store-sqlite` returns `{"error":"put needs kind, id and value"}` and the process stays up. Guard `value == nil` in the barrel handler (the Go engines already do). No MANUAL wording is needed beyond the "identical tools" qualifier under Shipped components.

## A768 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL: absent (the store's three-engine contract is not mentioned)
- CODE: `Makefile:491-503` (`test-store`, `test-store-sqlite`, `test-store-tidb` — the TiDB one prints `SKIP` without `NIF_STORE_TIDB_DSN`), `tests/t_store.nim:15-22`, `tests/t_store_paging.nim:1-13`
- FIX: add (small) — "The store contract is one test run against every engine: `make test-store` (the selected/default engine), `make test-store-sqlite`, `make test-store-tidb` (needs `NIF_STORE_TIDB_DSN`, otherwise SKIP); `t_store_paging` pins the `after`/`hasMore`/`nextAfter` cursor semantics that resume and migration depend on."

## A769 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL: absent (a phantom make target in the test's own header)
- CODE: `tests/t_store_paging.nim:11` ("`make test-store-paging` re-runs it against SQLite")
- FIX: add (code bug) — no such target exists (`grep -n store-paging Makefile` → 0 hits); the test runs inside `make test-server` via `TEST_NIM := tests/smoke.nim $(wildcard tests/t_*.nim)` (`Makefile:447`) and is re-run against another engine with `NIF_STORE_BIN=…`. Fix the comment (or add the target).

## A773 (doc-edit)
source: `components/store.md`

- MANUAL: **The barrel engine's `put` without `value` kills the store process** (measured: caller timeout + exit 139; sqlite/tidb answer cleanly). It is one line (`components/store/main.nim:110-111`) and the supervisor hides it as a restart.

## A774 (doc-edit)
source: `components/store.md`

- MANUAL: **Migration is one-directional and cannot be re-run on a migrated root** — MANUAL :337-338 and :347-348 claim otherwise, and the root a successful migration produces ("both store.db and barrel-db exist") is exactly the state the tool then refuses, so a user who rolls back with `NIF_STORE_BACKEND=barrel` must move the stale `var/store.db` aside before migrating again (undocumented). `--force` — the flag that sounds like the way out — is parsed and ignored.

## A775 (doc-edit)
source: `components/store.md`

- MANUAL: **The store's plaintext-secret note covers only `provider`** — `mcp` records keep `env`/`headers` values verbatim in the same file (`components/mcp/types.go:19-21`), so "the store file itself is the secret" needs to say so, and to say that any copy of the file is a copy of the credentials.

## A776 (doc-edit)
source: `components/store.md`

- MANUAL: **The docs drifted from the code on the small things a reader acts on**: `put` is missing from §The store's on-demand sentence (:2869) although §Shipped policy (:2066-2067) has it right; `var/` (:365) names only `store.db` and neither lock file; and NIF_STORE_BACKEND's unset-means-fallback behaviour (core warns and boots barrel when `store-sqlite` was never built) is nowhere in the MANUAL.

