# Worklist slice: Layout of a running system

From `worklist.tsv` (28 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A001 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 36 the `components/` row enumerates 13 Nim + 3 Go components
- CODE: `ls components/` = 34 dirs — the enumeration omits `compaction`, `recall`, `repomap`, `processes`, `mcp`, `mcp-bridge`, `nats`, `store-sqlite`, `store-tidb`, `ctxtest` (context-window test fixture, not in the manifest: `components/ctxtest/main.nim:1-6`)
- FIX: replace the enumeration with "the component sources — see the table below"; the shipped-components table (line 50) is the inventory and is current.

## A002 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 45 `var/logs/`, `var/captures/` row
- CODE: also created under `var/`: `toolout/<session>/` (bash spills the transcript tail here, 1 h TTL sweep — `components/bash/main.nim:27-34`), `mcp-results/` (`components/mcp-bridge/operations.go:152`), `approval-sources/` (`core/approval.nim:99-121`, mode 0600), `review-receipts/` (`components/git/main.nim:364`), `fabric-cache/` (`components/fabric/fabric.nim:117`), `plugins/` (`components/plugins/main.nim:337`), `nats-monitor-url` (described at line 44 but not in this row)
- FIX: add them all here and to the state table at line 244 — `var/toolout/` in particular is where every bash spill path returned to the model points.

## A003 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 34 `core/` row ("bus bootstrap, supervisor, catalog, dispatch")
- CODE: the same dir also owns `conversation.nim` (the whole turn loop), `compaction.nim`, `approval.nim`, `retry.nim`, `uireg.nim`, `tty.nim`, `schema_validation.nim` (`ls core/`)
- FIX: mention the conversation loop/compaction/approval modules; today the row hides the largest file in core.

## A005 (doc-edit, dup:mechanisms.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 66 `builder` row "compiles agent-written Nim/Go source into binaries"
- CODE: `builder.build` accepts `files`/`defines` and is approval-gated + onDemand, and a second tool `builder.info` exists (`components/builder/main.nim:49-51,203`)
- FIX: "`builder.build {lang, name, source, files?, defines?}` (approval-gated, on-demand) plus on-demand `builder.info`". `[dup]` mechanisms.md.

## A008 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 70 `grep` row "optional (4 replicas)"
- CODE: `manifest.yaml:112-120` (`replicas: 4`) and both tools (`grep` direct with `parallel: true` at `components/grep/main.nim:52`, `files` onDemand at `:100`) ✔
- FIX: none.

## A017 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 158-181 engine bullets (sqlite one-statement put, goose migrations, `modernc.org/sqlite`, barrel two-key crash window, tidb MEDIUMTEXT/`utf8mb4_bin`)
- CODE: `components/store-sqlite/main.go:71-72,142,183,304-331` (goose migrations, `modernc.org/sqlite`, WAL, single upsert), `components/store-tidb/main.go:21-45,292` (MEDIUMTEXT rationale, `FOR UPDATE` compare-and-set), both engines keep the create-path rationale in their own headers
- FIX: keep, but see (Z): the engine *rationale* belongs in `research/STORE_V2.md`; MANUAL should carry the selection table and the "switching does not migrate" warning only.

## A018 (trim, dup:mechanisms.md §Z.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 195-229 (full `niffler-store-migrate` walkthrough: refusal text, `--root/--dry-run/--scan/--all`, "runs offline … never edits the source data … verifies per-kind counts")
- CODE: CODE: the tool is `Makefile`-built into `var/bin` and designed in `docs/research/STORE_V2.md` ("Moving data between engines")
- FIX: FIX (Z): keep the 6-line summary plus the refusal message (it is what an operator sees), move the flag walkthrough to a pointer at `docs/research/STORE_V2.md`. `[dup]` mechanisms.md §Z.

## A038 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 601-607 (replaceable `compaction_propose`, `NIF_COMPACTION_*` bounds, runner-owned paged `compaction_input` snapshot, validation of generation/digest/cut/schema/size, single `context_projection` commit with `expectRev`, "The component never writes conversation or projection records")
- CODE: `components/compaction/main.nim:216-219` (hidden + `runner: true`), no `storePut`/`storeDel` anywhere in `components/compaction` (verified by grep), `core/compaction.nim:47-58` (tool/timeout/call/token knobs) ✔
- FIX: none.

## A051 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — the OAuth *flow* lifetime is not stated
- CODE: `oauthFlowLifetime = 15 * time.Minute` (`components/provider/oauth.go:29`) means an abandoned login flow expires
- FIX: add "a started login flow expires after 15 minutes (`oauthFlowLifetime`); `provider_oauth_start` returns `expiresAt`".

## A106 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL ~185** — "All engines enforce single-writer the same way: one process owns the file (flock…)" contradicts the tidb bullet 40 lines above it ("No flock — the cluster is shared state by design"); tidb has no file and no flock (`components/store-tidb/main.go:15-21,292`).

## A141 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 36 "`components/` | shipped component sources: `bash`, `builder`, `store`, `plugins`, `skills`, `fetch`, `edit`, `grep`, `git`, `agent`, `fabric`, `expert`, `observe`, `logfile`, `hooks`, `dialog`, `systemprompt`, `cli`, `console` (Nim), `models`, `provider` and `llm` (Go) + the `llm-openai` swap-in example"
- CODE: `components/` actually contains 33 dirs, incl. `compaction`, `recall`, `repomap`, `processes`, `mcp`, `mcp-bridge`, `nats`, `store-sqlite`, `store-tidb`, `ctxtest` (`ls components/`)
- FIX: update the sentence to name the missing ones (`compaction`, `recall`, `processes`, `repomap`, `mcp` + `mcp-bridge`, `store-sqlite`/`store-tidb`, `nats`) or replace the enumeration with "see the Shipped-components table below".

## A152 (trim)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 146–229 (Store engines + Migrating between engines, incl. the full `niffler-store-migrate` output block)
- CODE: CODE/doc: `docs/research/STORE_V2.md` (the migrate command's own design doc, referenced at `manifest.yaml` store comment)
- FIX: FIX: keep the engine table + "switching does not migrate" warning, move the migrate CLI walkthrough to a pointer at `docs/research/STORE_V2.md`.

## A178 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 127-129 "One conversation = one process (`var/bin/session <sessionId>`), spawned by the system harness on demand. Clients keep calling `svc.core.call` (tool `session`); the system ensures a runner per session id and forwards the turn to `svc.session.<sessionId>.call`"
- CODE: `core/conversation.nim:2858-2901` (`ensureRunner`), `:2914-2946` (`routeSessionCall` publishes to a private `_INBOX` and tracks a `SessionForward`, 1800 s deadline) ✔
- FIX: keep, but add the two facts that change behaviour: the forward is asynchronous (core's main pump owns the inbox, so one long turn cannot block another conversation's runner, `conversation.nim:2948-2953`), and readiness is the runner appearing in the catalog, polled for up to 10 s after spawn (`conversation.nim:2875-2898`).

## A181 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 133-135 "it announces itself as component `session-<id>` with zero tools, seeds its catalog from `catalog {op: snapshot}` at startup"
- CODE: `core/session.nim:136-138` (`reg.publish` with `tools: []`), `:62-68` (snapshot seed, warning-only on failure) ✔
- FIX: accurate; add that the runner creates the conversation header at startup so the session appears in the sidebar before its first message (`core/session.nim:142`).

## A184 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (what deleting a conversation does to its runner)
- CODE: `core/dispatch.nim:406-461` (`conversation_delete`: `sup.removeChild(runnerName(sessionId))` + `cat.dropComponent`, then deletes the header, every message via `storeListAll`, `<sid>:tools`, `sessionmeta` and `agentjob` records, returning `deleted`)
- FIX: add to §Session runners: "`conversation_delete` (a gated core tool, hidden from the LLM) is the complete delete surface: it stops that conversation's runner first — a live turn would otherwise resurrect records — then removes the header, messages, frozen toolset, subagent lineage and jobs."

## A185 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 41 "`var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build`"
- CODE: `Makefile:291` (`components-inner` builds `var/bin/session`), path hard-coded at `core/conversation.nim:2881`
- FIX: accurate; no change.

## A211 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (MANUAL:459–460 writes `core.spawn`, `core.kill`, `core.remove`)
- CODE: the registered names are bare `spawn`/`kill`/`remove` (`core/catalog.nim:68,81,89`), and core does not gate them through the schema path at all — `handleCoreTool` asks by name before dispatch (`core/dispatch.nim:273–276`)
- FIX: add one sentence to the section: "Core's own destructive tools are named `spawn`, `kill`, `remove` and `conversation_delete`; they are gated by name inside `handleCoreTool`, not through a schema, so `x-harness.approval` appears on component tools only."

## A242 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 189–193 "`list` is a **page**, not a complete view: it is capped at 1000 items and returns `hasMore` plus an `nextAfter` id cursor. Pass `nextAfter` back as `after` to walk the rest"
- CODE: accurate, and the numbers behind it are: `limit` defaults to **100** and is clamped by `min(limit, 1000)` (`components/store/main.nim:130,151`), `after` is an *exclusive* full document id (`:145–150`), `nextAfter` is emitted only when `hasMore` and the page was non-empty and comes from the last **key**, not the last returned item, so an all-tombstoned page still advances (`:159–168`)
- FIX: add the missing default and the cursor rule — "`limit` defaults to 100 (max 1000); `after` is exclusive, so pass `nextAfter` (or `items[^1].id`) back verbatim; `nextAfter` is absent when `hasMore` is false. `core/dispatch.nim` `storeListAll` is the paging helper core uses for full-kind reads (resume, `session_info`, `conversation_delete`)."

## A250 (delta)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 189 typo "plus an `nextAfter` id cursor"; MANUAL:398–400 block formatting (a stray `#` in a comment column)
- CODE: FIX: "a `nextAfter` id cursor"; drop the stray comment markers.

## A256 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:190 "capped at 1000 items" without the `limit` default of 100, which is what a caller omitting `limit` actually gets (components/store/main.nim:130,151).

## A257 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:386–421 bus block is presented as the subject inventory but omits `ev.log.*`, `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`, `ev.fabric.*` (file:line in the table below).

## A277 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (`var/toolout` never mentioned)
- CODE: `main.nim:27-49`, `176-179`
- FIX: add — oversized captures spill to `$NIF_ROOT/var/toolout/<session>/<pid>-<epoch>-<counter>.out`, absolute and therefore readable with `read` (offset/limit); files older than **1 hour** are swept on each new spill, so a spill path from an old turn may be gone. MANUAL.md:55 calls it "a temp file pageable with `read`", which leaves the reader unable to find or predict it — and it is not `$TMPDIR` when `NIF_ROOT` is set (`main.nim:31-32`). Add a `var/` state-table row (MANUAL.md:41-48) too: `| var/toolout/ | bash spill files … | disposable, 1 h TTL |`.

## A279 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:55 ("non-zero = failure; 124 = timeout, 130 = cancelled")
- CODE: `main.nim:164-169`; `procutil.nim:113-116`, `99`, `101`
- FIX: update — add the two codes the model will actually meet: `126` (cwd not enterable, from `chdir` failure — note the *tool* also uses 126 in its own status text for "found but not executable", `main.nim:167`), `127` (`bash` not resolvable on `PATH`), and the `128 + signal` convention for a command that killed itself (139/143). The `(exit N)` line is followed by combined stdout+stderr — that part MANUAL.md:55 gets right.

## A297 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (`edit` (unique `old_string`, guarded fallback cascade, `replace_all`))
- CODE: `main.nim:1285-1298` (an `edits` array), `main.nim:803-810` (`E_OVERLAP`), `main.nim:798-838` (single atomic write)
- FIX: add — `edit` is inherently multi-edit: `edits[]` takes any number of `{old_string,new_string,replace_all?}` pairs, all matched against the *original* file, checked for overlap and no-change before anything is written, then applied in one atomic rename. There is no separate `multi_edit` tool; a stringified or single-object `edits` is accepted (`main.nim:735-741`). A batch that fails any pre-check leaves the file byte-identical.

## A304 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 ("guarded fallback cascade" is unnamed)
- CODE: `main.nim:612-616`, `249-257`, `588-592`
- FIX: update — name the cascade in order: per-line trailing whitespace → indentation drift → unicode punctuation (smart quotes/dashes) → block anchors with Levenshtein similarity ≥ 0.65 (≥ 3 lines) → double-escaped text. Every tier must still match exactly once (ambiguity is an error, never a reason to go fuzzier), and a fuzzy span grossly larger than `old_string` is refused with `E_SPAN_TOO_LARGE`.

## A305 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 ("`write` (atomic whole-file)")
- CODE: `main.nim:1317-1325`, `106-131`, `1210-1241`
- FIX: update — `write` creates the file and its parent directories, follows symlinks, preserves the target's permissions via `fchmod` on the temp file, renames atomically, and truncates on empty content; payload cap is 900000 bytes (`NIF_WRITE_MAX_BYTES`), deliberately under NATS's 1MB limit so oversized writes get a clear component error; it reports path, bytes, lines, digest and `overwrote`.

## A372 (doc-edit)
source: `components/git.md`

- MANUAL: **`var/review-receipts/` missing from the state table** (MANUAL:230-260; directory comes from `receiptsDir()` `main.nim:347-350`, files are `rr-<unix>-<fp8>.json` `main.nim:387`, `:397`).

## A404 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:66` "| `lsp` | Nim | optional | language-server seam: one `lsp` tool — `diagnostics` … `hover` —" (no `warmup`, no `lsp_servers`/`lsp_registry`)
- CODE: `components/lsp/main.nim:1063`, `:1082`, `:1087`, ops `:48-50`
- FIX: update row — replace "one `lsp` tool" with "the `lsp` tool (eight operations — add `warmup` to the list), plus `lsp_servers` (list the merged registry) and `lsp_registry` (add/remove a server entry, approval-gated); all on-demand". Keep the existing "never code" sentence.

