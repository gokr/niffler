# Worklist slice: Layout of a running system

From `worklist.tsv` (88 rows). `class` is one of
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

## A008 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 70 `grep` row "optional (4 replicas)"
- CODE: `manifest.yaml:112-120` (`replicas: 4`) and both tools (`grep` direct with `parallel: true` at `components/grep/main.nim:52`, `files` onDemand at `:100`) ✔
- FIX: none.

## A012 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — no row for `components/nats` (the bus binary core spawns) or `components/ctxtest`
- CODE: `components/nats/main.go`, `components/ctxtest/main.nim:1-6`
- FIX: one short paragraph "not a bus citizen: `components/nats` builds `var/bin/nats-server`, the bus core spawns when no URL answers; `ctxtest` is a test-only fixture the nested-call test compiles itself".

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

## A119 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **Two source trees that are not bus citizens**: `components/nats` (the `var/bin/nats-server` core spawns) and `components/ctxtest` (test fixture).

## A149 (missing)
source: `mechanisms.md`

- MANUAL: MANUAL: absent (never mentions the core `ui` tool, the UI registry, leases or display numbers)
- CODE: `core/catalog.nim:203-215` (hidden tool `ui`, ops register/renew/release/claim/release_session/owner), `core/uireg.nim:1-30,33,60-124` (UUID → "Niffler N" monotonic numbering, 20 s renewable lease, one live UI per conversation, lazy sweep)
- FIX: add a "Clients and the UI registry" subsection: register/renew/release, claim/release_session/owner semantics, lease 20 s, numbers monotonic per harness lifetime, coordination not authentication.

## A152 (trim)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 146–229 (Store engines + Migrating between engines, incl. the full `niffler-store-migrate` output block)
- CODE: CODE/doc: `docs/research/STORE_V2.md` (the migrate command's own design doc, referenced at `manifest.yaml` store comment)
- FIX: FIX: keep the engine table + "switching does not migrate" warning, move the migrate CLI walkthrough to a pointer at `docs/research/STORE_V2.md`.

## A170 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 1106 `observe_request` "... approval-gated and limited to 30 seconds"
- CODE: `components/observe/main.nim:376` `timeoutMs: 35_000`
- FIX: "35 s (`x-harness.timeoutMs`)".

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

## A197 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (the `ui` core tool, the registry, its ops)
- CODE: `core/catalog.nim:213-224` (hidden core tool `ui`, ops `register|renew|release|claim|release_session|owner`), `core/uireg.nim:1-124`
- FIX: add "Clients and the UI registry": interactive frontends announce a client-supplied UUID, receive a display number ("Niffler 1", "Niffler 2", …) and a 20 s lease they must renew; `claim` gives one live UI a conversation, `release_session`/`release` give it back, `owner` reports the holder; expired entries are swept lazily on every registry decision, so no timer thread exists (`uireg.nim:52-59,65-77`); numbers are monotonic per harness lifetime and never reused (`uireg.nim:11-12,84-88`); a claim by a non-owner answers `{ok: false, owner, number}` (`uireg.nim:97-102`) and a `renew` for an expired id answers `{ok: false}`, forcing re-register + re-claim (`uireg.nim:89-95`). Say plainly that this is coordination between cooperating UIs, **not** authentication (`uireg.nim:10-13`).

## A211 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (MANUAL:459–460 writes `core.spawn`, `core.kill`, `core.remove`)
- CODE: the registered names are bare `spawn`/`kill`/`remove` (`core/catalog.nim:68,81,89`), and core does not gate them through the schema path at all — `handleCoreTool` asks by name before dispatch (`core/dispatch.nim:273–276`)
- FIX: add one sentence to the section: "Core's own destructive tools are named `spawn`, `kill`, `remove` and `conversation_delete`; they are gated by name inside `handleCoreTool`, not through a schema, so `x-harness.approval` appears on component tools only."

## A237 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (`var/approval-sources/` is nowhere in MANUAL, not even the `var/` row of the state table at MANUAL:244, which lists `logs/`, `captures/`, `processes/` …)
- CODE: `core/approval.nim:99–121` creates `$NIF_ROOT/var/approval-sources/<digest>.nim` with mode 0600
- FIX: add `approval-sources/` (0600 program source awaiting/recorded for approval) to the `var/` row and to §Approvals.

## A242 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 189–193 "`list` is a **page**, not a complete view: it is capped at 1000 items and returns `hasMore` plus an `nextAfter` id cursor. Pass `nextAfter` back as `after` to walk the rest"
- CODE: accurate, and the numbers behind it are: `limit` defaults to **100** and is clamped by `min(limit, 1000)` (`components/store/main.nim:130,151`), `after` is an *exclusive* full document id (`:145–150`), `nextAfter` is emitted only when `hasMore` and the page was non-empty and comes from the last **key**, not the last returned item, so an all-tombstoned page still advances (`:159–168`)
- FIX: add the missing default and the cursor rule — "`limit` defaults to 100 (max 1000); `after` is exclusive, so pass `nextAfter` (or `items[^1].id`) back verbatim; `nextAfter` is absent when `hasMore` is false. `core/dispatch.nim` `storeListAll` is the paging helper core uses for full-kind reads (resume, `session_info`, `conversation_delete`)."

## A257 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:386–421 bus block is presented as the subject inventory but omits `ev.log.*`, `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`, `ev.fabric.*` (file:line in the table below).

## A279 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:55 ("non-zero = failure; 124 = timeout, 130 = cancelled")
- CODE: `main.nim:164-169`; `procutil.nim:113-116`, `99`, `101`
- FIX: update — add the two codes the model will actually meet: `126` (cwd not enterable, from `chdir` failure — note the *tool* also uses 126 in its own status text for "found but not executable", `main.nim:167`), `127` (`bash` not resolvable on `PATH`), and the `128 + signal` convention for a command that killed itself (139/143). The `(exit N)` line is followed by combined stdout+stderr — that part MANUAL.md:55 gets right.

## A281 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (truncation marker)
- CODE: `procutil.nim:153-166`
- FIX: add the literal marker shape `[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]` with head+tail kept, since the model's recovery behaviour (re-run narrower, or `read` the spill) depends on it, and `bash` passes two different hints (`main.nim:161-162`, `181-183`).

## A298 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (no mention of the read/write staleness gate)
- CODE: `main.nim:786-797` (rationale `main.nim:410-424`)
- FIX: add — when a conversation's last-observed digest of a file differs from disk (external edit, or a `bash` mutation since the read/write), `edit` refuses with `E_STALE` *before* matching, because `old_string` may occur exactly once in text the model has never seen. Fix is to re-read and redo the edit; session-less callers (`cli`, other components) are not tracked and skip the gate.

## A300 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL absent (undo semantics)
- CODE: `main.nim:864-900`, `522-546`
- FIX: add — `undo_last_edit` is **single-level per file** (the previous edit only, not a stack), **persisted across restarts** and keyed by absolute path, and reverts content, BOM and line endings exactly. It is refused with `E_UNDO_STALE` when the file was modified or deleted after the edit — and in that case the stale record is *discarded*, so the undo is gone for good; the model is told to re-read and edit forward. The undo record is written before the file, so a store failure refuses the edit with `E_UNDO_UNAVAILABLE` rather than losing the ability to revert.

## A301 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (read description) / absent elsewhere
- CODE: `main.nim:466-472`, `979-985`, `44` (`MIN_STUB_BYTES = 512`), `54-61`
- FIX: add — a *full* re-read of a file ≥512 bytes that this conversation previously read in full and that is byte-identical returns `[unchanged] <path>: N bytes, M lines, digest <sha1>` instead of the text; the model passes `force: true` (or any offset/limit window) to force a re-dump. Windowed reads and small files always re-dump.

## A304 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 ("guarded fallback cascade" is unnamed)
- CODE: `main.nim:612-616`, `249-257`, `588-592`
- FIX: update — name the cascade in order: per-line trailing whitespace → indentation drift → unicode punctuation (smart quotes/dashes) → block anchors with Levenshtein similarity ≥ 0.65 (≥ 3 lines) → double-escaped text. Every tier must still match exactly once (ambiguity is an error, never a reason to go fuzzier), and a fuzzy span grossly larger than `old_string` is refused with `E_SPAN_TOO_LARGE`.

## A306 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 vs CODE (`edit` cannot create files)
- CODE: `main.nim:159-167`
- FIX: add one clause — `edit` only changes *existing* text files: a missing path is `E_NOT_FOUND`, an empty file `E_EMPTY`, both pointing at `write` as the way to create content. This is the most common confusion between the two tools and is currently implied only by the error text.

## A372 (doc-edit)
source: `components/git.md`

- MANUAL: **`var/review-receipts/` missing from the state table** (MANUAL:230-260; directory comes from `receiptsDir()` `main.nim:347-350`, files are `rr-<unix>-<fp8>.json` `main.nim:387`, `:397`).

## A404 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:66` "| `lsp` | Nim | optional | language-server seam: one `lsp` tool — `diagnostics` … `hover` —" (no `warmup`, no `lsp_servers`/`lsp_registry`)
- CODE: `components/lsp/main.nim:1063`, `:1082`, `:1087`, ops `:48-50`
- FIX: update row — replace "one `lsp` tool" with "the `lsp` tool (eight operations — add `warmup` to the list), plus `lsp_servers` (list the merged registry) and `lsp_registry` (add/remove a server entry, approval-gated); all on-demand". Keep the existing "never code" sentence.

## A486 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL: absent (no language-coverage statement anywhere)
- CODE: CODE: `tags.nim:57-78, 224-233`, `main.nim:121-141`
- FIX: FIX (in the proposed section): "Tag coverage is two tiers: tree-sitter for Go, Python, TypeScript, JavaScript, C, C++, Rust and Ruby (grammars vendored under `components/repomap/csrc/`, queries in `components/repomap/queries/`), and a native Nim tagger for `.nim`/`.nims` because the Nim grammar's generated parser is 40 MB. Unlisted extensions contribute no symbols."

## A529 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |"
- CODE: `components/builder/main.nim:75`, `103`, `145`, `195` (every `build` returns `<root>/var/bin/<name>`)
- FIX: update [doc-edit] — add "; agent-built components (`builder.build`) land here too, beside the system binaries"

## A530 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "| `var/build/` | source files of agent-built components (builder's scratch dir) |"
- CODE: `main.nim:74`, `84` (Nim: one `<name_>.nim`), `107` (Go: `<name>/` with `go.mod`/`main.go`/`go.sum`), `152` (TS: `<name>/` with `package.json`/`tsconfig.json`/`node_modules/`/`dist/`)
- FIX: update [doc-edit] — "; for Go and TypeScript it is a whole project directory (generated `go.mod`, `package.json`/`tsconfig.json`, `node_modules`), never pruned. It is the **only** copy of an agent-built component's source — deleting `var/` orphans the persisted `component` record"

## A533 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "compiles agent-written Nim/Go/TypeScript source into binaries: `build {lang, name, source, files?, defines?}` (approval-gated, on demand) and `info` (on demand: the per-language source skeleton and SDK locations)"
- CODE: `main.nim:49` (`approval: always`, `timeoutMs: 300000`, `onDemand: true`), `main.nim:203` (`info`, `onDemand` only), **live** `catalog {op:schemas}` returns exactly those two tools, `required: [lang,name,source]`
- FIX: none [verified] — the row is right about both tools, the five arguments, the gate and the exposure; only depth is missing (see the next rows).

## A534 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "`info` (on demand: the per-language source skeleton and SDK locations)"
- CODE: `main.nim:206-213` (returns `langs`, `sdk`, `sdkGo`, `sdkTs`, `naming`, `flow`, `nim`, `go`, `ts`), **live** `info` result (same nine keys), `tests/t_builder.nim:49-52` (compiles `info{"go"}` verbatim as a Go component — the skeleton is the contract)
- FIX: update [doc-edit] — "`info` (on demand) returns the SDK paths (`sdk`/`sdkGo`/`sdkTs`), the global tool-naming rule, the build→spawn→discover `flow` string, and a complete compiling skeleton per language — the fastest way to write a component that builds on the first try."

## A535 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "`build {lang, name, source, files?, defines?}`"
- CODE: `main.nim:76-78` (`validComponentName`), `main.nim:25-34` (`validGoSourceName`), `main.nim:36-45` (`validDefine`), `main.nim:89` (`defines.kind == JArray`), `main.nim:111-130` (Go-only `files`)
- FIX: add [missing] — the row should carry the rules an agent must satisfy before calling: `name` is 1–64 chars of `a-z0-9` and single hyphens (that is the traversal guard — `../escape` is refused with `name must be 1-64 lowercase letters, digits, and single hyphens`); `files` is **Go only** (≤64 flat `*.go` sources, ≤2 MB total, no `main.go`, no `*_test.go`, no directories) and is silently ignored by Nim/TS builds; `defines` is **Nim only** (`-d:NAME`, `[A-Za-z0-9_.]`, ≤64 chars) and a non-array value is silently ignored.

## A538 (code-bug?)
source: `components/builder.md`

- MANUAL: MANUAL: absent (the 300000 ms `x-harness.timeoutMs` of `build` and the per-command budgets inside it)
- CODE: `main.nim:49` (`timeoutMs: 300000`), `core/dispatch.nim:1638-1641` (enforced), `main.nim:96-99` (Nim `runCmd` with no timeout → 120 000 ms default, `sdk/niffler/procutil.nim:70`)
- FIX: code bug [code-bug?] — the advertised 300 s does not match any Nim build's real budget: pass an explicit `300_000` to the Nim `runCmd` (or lower the schema to what is true), because today the dispatch timeout fires while a listener-based `bash`-style partial reply is unavailable.

## A559 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |"
- CODE: components/cli/main.nim:1-15 (no `reg.publish` in the file at all); manifest.yaml (no `cli` entry); Makefile:256-257, 308-310; scripts/install.sh:110
- FIX: fix: none — the row is right, including the empty Manifest cell [verified]

## A560 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`)"
- CODE: components/cli/main.nim:76-95 (only the catalog read; no `reg.publish` anyway)
- FIX: add "(`cli` is a pure client — it never publishes `reg.publish`, so it never shows up in `catalog` and `cli wait cli` can never succeed)" [missing]

## A561 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "the inventory is the [Shipped components](#shipped-components) table below, which is the part that has to stay current"
- CODE: manifest.yaml (25 entries), Makefile:308-310 (`cli`, `console`, `dialog` built but not spawned)
- FIX: fix: none — keeping `cli`/`console`/`dialog` out of the manifest and listing them as `—` is correct [verified]

## A577 (verified)
source: `components/console.md`

- MANUAL: MANUAL: "| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |"
- CODE: components/console/main.nim:1-11 (zero tools), :72-74 (`reg.publish`), Makefile:253-254, manifest.yaml (no `console` entry), scripts/install.sh:111
- FIX: fix: none — the row is right, including the empty Manifest cell [verified]

## A578 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: "on-demand bus viewer (renders every envelope on stdout)"
- CODE: components/console/main.nim:39-56 (registration payloads render as bare `event <subject>` lines; results lose their tool name), :101-107 (no signal handling, no `reg.depart`)
- FIX: add "It is a stream viewer, not a registration viewer: bare `reg.publish`/`reg.depart` payloads show as `event reg.publish` with an empty body, a result shows its args but not the tool that produced it, and a killed console stays in the catalog until core restarts" [missing]

## A591 (verified)
source: `components/dialog.md`

- MANUAL: MANUAL: "demo component written entirely in bash — nats CLI + jq, no SDK, no compile step"
- CODE: components/dialog/dialog.sh:1-19 (header), Makefile:297-300 (`cp $< $@ && chmod +x $@`; nimble:all_internal identical), manifest.yaml (no `dialog` entry)
- FIX: fix: none — verified [verified]

## A592 (code-bug?)
source: `components/dialog.md`

- MANUAL: MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer."
- CODE: components/dialog/dialog.sh:107-141 (backends), :167-184 (handlers), :82/:95 (`x-harness.timeoutMs` 45000/120000, nothing else)
- FIX: add "Neither tool is approval-gated and neither is on-demand, so once `dialog` is spawned both sit in every new conversation's direct toolset; `dialog_show` returns `{ok, shown, via: zenity|notify|log, kind}`, `dialog_ask` `{ok, answer: yes|no|timeout}`, and without a display (`DISPLAY` unset or zenity missing) `dialog_ask` answers `timeout` immediately without asking anyone." [missing]

## A593 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool)."
- CODE: components/dialog/dialog.sh:15-17 (the script's own header: "Spawning is approval-gated like every new component"), core/catalog.nim:79-95 (`spawn` carries `approval: \"always\"`), core/dispatch.nim:1630-1633
- FIX: update to "…spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` — core's `spawn` is approval-gated, so a human confirms the component itself; the two dialog tools are not gated afterwards." [doc-edit]

## A594 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "Prereqs: natscli, jq, zenity — `make setup` installs all three"
- CODE: components/dialog/dialog.sh:37-45 (nats CLI required; missing → `nats: command not found`, exit 127), :152-163 (`jq` required to parse the envelope), :113/:122/:127 (`zenity`/`notify-send` optional; log fallback), Makefile:589-593 (`setup` → `install-natscli install-jq install-zenity`), Makefile:628-640 (`doctor`)
- FIX: update to "Prereqs: the nats CLI and `jq` (both hard — without them the component cannot start); `zenity` (or `notify-send`) only for the visible part, and only with `DISPLAY` set — `make setup` installs all three, `make doctor` checks them." [doc-edit]

## A595 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer"
- CODE: components/dialog/dialog.sh:51 (log path `${NIF_ROOT:-$HOME}/var/logs/dialog.log`), core/supervisor.nim:131-148 (a spawned child's stdout/stderr land in the same `var/logs/dialog.log`)
- FIX: add "Both tools append `dialog: …` lines to `$NIF_ROOT/var/logs/dialog.log` (`$HOME/var/logs/dialog.log` when `NIF_ROOT` is unset) — the same file core redirects the spawned child's stdout into." [doc-edit]

## A596 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "demo component written entirely in bash — nats CLI + jq, no SDK, no compile step"
- CODE: components/dialog/dialog.sh:24-34 (bus = `NIF_NATS_URL` → `./var/nats-url` → 4222; `NIF_ROOT` ignored), core/supervisor.nim:160 (`workingDir = NIF_ROOT` is why the spawned case works)
- FIX: add "It resolves the bus from the **current directory** (`./var/nats-url`, then 127.0.0.1:4222) — `NIF_ROOT` is not consulted, so the documented `spawn` path works because core starts children with cwd = the harness root, while a hand-started copy from another directory silently targets 4222." [missing]

## A597 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "Ships in `var/bin/dialog` (`make build`) but is **not autostarted**"
- CODE: components/dialog/dialog.sh:212 (only trap kills the reply child), `grep -c reg.depart dialog.sh` → 0, core/supervisor.nim:193-204 (core drops a *child's* registration on death)
- FIX: add "(when you `spawn` it, core drops its registration on exit; a copy you started by hand stays in the catalog until core restarts, like `console`)" [missing]

## A598 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer."
- CODE: components/dialog/dialog.sh:208 (no `x-harness.effect` ⇒ fabric classifies both as write-effect), :82/:95
- FIX: add "(neither tool declares `x-harness.effect`, so the fabric batch host treats them as writes — a program that only asks a question runs exclusively)" [missing]

## A599 (code-bug?)
source: `components/dialog.md`

- MANUAL: MANUAL: "`dialog_ask` asks the user a yes/no question and returns the answer"
- CODE: components/dialog/dialog.sh:139-142 (zenity `--question` rc 0/1/other → yes/no/timeout; zenity's own rc 5 = timeout), :175-184 (headless ⇒ instant `timeout`), :174-175 (raw `kind` echoed although the window normalized it)
- FIX: code bug — distinguish "nobody can answer" (no display) from "the human let it time out" in the result, and echo the `kind` that was actually used; `shown: true` with `via: "log"` or after a failed zenity/notify-send also claims something that did not happen (`|| true` at :118/:123) [code-bug?]

## A603 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "default replaceable `compaction_propose` implementation: verifies runner-owned paged snapshots, chooses a permitted cut, and returns a structured checkpoint candidate"
- CODE: `components/compaction/main.nim:64-105` (verification), `main.nim:107-121` (cut choice), `main.nim:296-303` (candidate)
- FIX: none — verified accurate, including "the runner alone validates and commits projections" (`core/conversation.nim:1591-1593`, `core/compaction.nim:201-330`).

## A604 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "default replaceable `compaction_propose` implementation"
- CODE: `components/compaction/main.nim:216-217`, `core/catalog.nim:431-433`, `core/dispatch.nim:288-290`
- FIX: add — after the sentence, state the exposure: "The tool is `hidden` + `x-harness.runner: true` (timeout 120 s, read-effect): never offered to a model, never listed by `discover`, never reachable through `invoke` — only a runner or another component calls `svc.compaction.call` directly. With the component absent or killed, summarization is simply off and the remaining ladder — lossless prune, then the lossy fallback rung, then `context-recovery-required` — still runs."

## A628 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint"
- CODE: `components/recall/main.nim:143-217` (three ref sources), `main.nim:238` (`onDemand`)
- FIX: none — verified accurate, including "on-demand" and the three sources.

## A629 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint"
- CODE: `components/recall/main.nim:222-236` (parameters), `main.nim:28-31` (caps), `main.nim:243-287` (modes)
- FIX: add a tool table to the Context window section — "`context_recall {ref?, mode?, query?, session?, role?, offset?, limit?}` — `ref` is one `{source, id}` object or an array of them (`source` is `canonical`, `spill` or `checkpoint`); `mode: full` (default) pages the document (`offset`/`limit`, 256 KB per page), `mode: match` greps one document's lines, `mode: search` greps the conversation's whole canonical `message` history and returns up to `limit` one-line hits whose `id` can then be read in full as a `canonical` ref. Defaults: 2000 lines (full), 50 matches (match), 20 hits (search)."

## A648 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |"
- CODE: components/grep/main.nim:52,100; manifest.yaml:116-124
- FIX: update — [doc-edit] append "; params, caps, exit codes and the effect classification are in [Search (``grep``)](#search-grep)". The row is otherwise verified correct (direct `grep`, on-demand `files`, .gitignore-aware, 4 replicas), but it must gain the two facts a reader cannot derive from it: `grep` is the *direct* tool while `files` is discover-only, and neither declares `x-harness.effect`, so the fabric batch host schedules both as writes (`components/fabric/fabric.nim:226-228`, `:309`, `:327`) exactly as the MANUAL already warns for `bash` and `fetch`.

## A649 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: absent
- CODE: components/grep/main.nim:1-131; manifest.yaml:116-124
- FIX: add — [missing] a new chapter titled `Search (grep)` before the `Language servers (lsp)` chapter, with the text proposed in §4 of this report, plus a Contents bullet. It is the only place that can explain what `ripgrep-backed search` really costs: Nothing in the MANUAL documents the parameters and clamps (`main.nim:55-58`, `:96`, `:98`, `:103-104`, `:125`), the 32 KB head+tail byte cap (`main.nim:18`, `:45-50`; `sdk/niffler/procutil.nim:153-165`), the line-cap marker (`sdk/niffler/procutil.nim:167-187`; asserted at `tests/t_grep.nim:113-116`), rg's `--max-columns 300` omission (`main.nim:75`), the exit-code contract and empty-result markers (`main.nim:34-50`, `:127-128`), absolute result paths (`main.nim:88-96`) or the ignore/glob rules (`main.nim:80-86`, `:115-119`).

## A650 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: absent
- CODE: components/grep/main.nim:26-31,43-44
- FIX: add — [missing] one sentence in the `ripgrep-backed search` component row (or the new chapter): "rg resolves through `PATH`; when it is missing both tools answer exit 127 with an install hint and suggest falling back to `bash grep -rn`" — the component returns exactly that text (`main.nim:28-30`) and only `make setup`/`make doctor` install ripgrep today.

## A673 (trim)
source: `components/hooks.md`

- MANUAL: MANUAL: "| `hooks` | Nim | off by default | runs operator shell commands when selected bus events fire (observe-only; JSON on stdin, env-configured; see [Hooks](#hooks)) |"
- CODE: manifest.yaml:216-221; components/hooks/main.nim:1-138
- FIX: none — [verified] `autostart: false`, `restart: on-failure`, no `replicas`, and no tools; the "off by default" and the pointer are both correct (the "registers no tools" clause belongs in the chapter, first group above).

## A694 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) |"
- CODE: components/logfile/main.nim:292,448; manifest.yaml:205-210
- FIX: update — [doc-edit] append "— both tools are on demand, and neither declares `x-harness.effect`, so the fabric batch host schedules even `logfile_search` as a write". The rest is verified: two on-demand tools, `autostart: true`, `required: false`, `restart: on-failure`, no `replicas` (a single-writer sink must not be replicated).

## A726 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring (see [Observation and logs](#observation-and-logs)) |"
- CODE: components/observe/main.nim:297-769; manifest.yaml:198-203
- FIX: update — [doc-edit] append "— all twelve tools are on demand, and none declares `x-harness.effect`, so the fabric batch host schedules even `observe_events`/`observe_logs` as writes". The rest is verified: twelve tools, `autostart: true`, `required: false`, `restart: on-failure`, and no `replicas` (impossible here: ring and probes are process-local).

## A733 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:44 "| `var/store.db` | the SQLite store's data file (default engine) — **single-writer**: exactly one `store` process may open it. Older harnesses/migrated roots use `var/barrel-db` instead |"
- CODE: `core/niffler.nim:444-470` (the guard requires `store.db` to be absent), `tools/store_migrate.nim:296-312` (a migrated root keeps both files)
- FIX: update — "Older, un-migrated harnesses still use `var/barrel-db`; a migrated root keeps that file untouched next to `var/store.db` (which is what the engine then reads). Each engine also locks its own file: `var/store.db.lock` / `var/barrel-db.lock`."

## A734 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:44 "**single-writer**: exactly one `store` process may open it"
- CODE: `components/store-sqlite/main.go:162-176`, `components/store/main.nim:39-51`, `tests/t_store.nim:44-51`
- FIX: none (verified) — the flock, its non-blocking exit(1), and the second-writer rejection are all real; the same rule is stated again at :3067.

## A735 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL:59 "Engines register under the same name with identical tools"
- CODE: `components/store/main.nim:181-232` (barrel registers a hidden `selftest`), `components/store-sqlite/main.go:106-117` and `components/store-tidb/main.go:79-90` (four tools only; no `SelfTest` exists in `sdk/go`)
- FIX: update — "the same four tools (`put`/`get`/`list`/`del`); the barrel engine additionally registers the hidden `selftest` (the Go engines do not — `/doctor` reports them as not implementing one)".

## A736 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:59 "`store-sqlite` (Go, SQLite + goose migrations, `var/store.db`) is the **default**; `barrel` (`var/bin/store`) and `tidb` remain selectable with `NIF_STORE_BACKEND`"
- CODE: `core/niffler.nim:485-496`, `manifest.yaml:14-18`
- FIX: none (verified) — manifest `required: true`, `restart: on-failure`, and the default is genuinely sqlite.

## A737 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:275 "core resolves the manifest entry's binary accordingly and refuses to boot on an unknown value"
- CODE: `core/niffler.nim:493-501`
- FIX: add — "An unset `NIF_STORE_BACKEND` is a default, not a demand: if `var/bin/store-sqlite` was never built, core warns and boots the manifest binary `var/bin/store` (barrel) instead. An explicit value is a demand — a missing binary is only warned about, never silently substituted with another engine's database."

## A738 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:289 "its `put` is a two-key sequence" ("… a crash between them can update content without its revision", :289-291)
- CODE: `components/store/main.nim:107-112,121-123,155`
- FIX: add — "…and for a *new* document the doc key is written with no rev key, which both `get` and `list` read as absent (`rev == 0`): the document is unreachable until it is written again."

## A739 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:277 "**sqlite** (default, `var/bin/store-sqlite`, Go): the same document contract on SQLite"
- CODE: `components/store-sqlite/main.go:140-153`, `migrations/00001_init.sql`
- FIX: add (small) — the bullet stops at "one atomic statement": say the pragmas are code-resident, not configurable (`_txlock=immediate`, WAL, `synchronous(NORMAL)`, `busy_timeout` 10 s, one pooled connection), and that the goose migration is applied automatically at startup (the file prints one line per applied migration).

## A740 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:292 "**tidb** (`var/bin/store-tidb`, Go): the same schema over the MySQL protocol (go-sql-driver)"
- CODE: `components/store-tidb/main.go:108-135,143-163`
- FIX: add — the DSN user needs the rights goose requires to create its version table and apply migrations (on a fresh database, and again whenever a new migration ships); connect/read/write timeouts are hardcoded (5 s / 60 s / 30 s); the engine runs on a single pooled connection (one session, so the `FOR UPDATE` transaction's statements stay together), so N harnesses on one cluster hold N connections and share no pool.

## A741 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:302 "No flock — the cluster is shared state by design; row locks (`SELECT … FOR UPDATE`, pessimistic transactions) arbitrate writers and the rev counter stays the optimistic-concurrency check."
- CODE: `components/store-tidb/main.go:12-17,258-327`
- FIX: none (verified) — accurate, including the `ClientFoundRows` requirement behind "rev counter stays the check".

## A742 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:294-296 "`NIF_STORE_TIDB_DSN` points at the cluster (`root@tcp(host:4000)/niffler`; single-node docker: `docker run -p 4000:4000 pingcap/tidb`)"
- CODE: `components/store-tidb/main.go:99-107`
- FIX: none (verified) — empty DSN refuses to boot with that example in the message.

## A743 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:310 "`list` is a **page**, not a complete view: `limit` defaults to 100 and is clamped to 1000, and the reply carries `hasMore` plus a `nextAfter` id cursor."
- CODE: `components/store/main.nim:151-168`, `components/store-sqlite/main.go:428-478`, `components/store-tidb/main.go:417-467`
- FIX: none (verified) — `limit` default 100 / cap 1000, exclusive `after`, `hasMore` = page-full, `nextAfter` absent when `hasMore` is false. Both local engines passed `tests/t_store_paging.nim` in this audit (2500 docs, 3 pages, tombstone hole; run: barrel + sqlite, see §7).

## A744 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:337 "It reads every document from the source" ("engine over the bus contract (so any engine pair works, including TiDB),", :338)
- CODE: `tools/store_migrate.nim:398-407` (an 18-name hardcoded probe list; `spill` `core/conversation.nim:1305` and `contextreceipt` `core/conversation.nim:304` are absent), `:364-386` (the verification only re-counts discovered kinds)
- FIX: update (claim is false) — "It reads every document **of the kinds it probes** (a fixed candidate list — a kind added later is silently skipped, and the per-kind verification cannot notice); the same offline export/replay path is what any engine pair would use."

## A745 (code-bug?)
source: `components/store.md`

- MANUAL: MANUAL:337-338 "(so any engine pair works, including TiDB)"
- CODE: `tools/store_migrate.nim:283-294` (the source is always `engineFor(root, "barrel")`; a SQLite-only root dies "root already uses sqlite … nothing to migrate")
- FIX: update (claim is false) — "the migration direction implemented today is barrel → sqlite (or `--to tidb`, see the DSN caveat below); moving out of SQLite or TiDB is not wired up."

## A746 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:345 "Migration refuses to overlay an existing" ("… target database;", :346)
- CODE: `tools/store_migrate.nim:290-299, 78-84` (the reachable refusal is the *source* check "both store.db and barrel-db exist … ambiguous source"; the overlay check tests `fileExists(<root>/var/store-tidb.db)`, a marker nothing creates)
- FIX: update — "Migration refuses to run on a root that holds both `var/barrel-db` and `var/store.db` (the state a previous migration leaves) and never writes to the source; for `--to tidb` there is no local target to protect — the replay upserts into the DSN database."

## A747 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:347 "The same export/replay path moves data in either" ("… direction.", :348)
- CODE: `tools/store_migrate.nim:283-299`
- FIX: remove — measured: `--root <sqlite-only root> --to barrel` dies "root already uses sqlite … nothing to migrate".

## A748 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:335 "`niffler-store-migrate` (in `var/bin`) runs **offline**" ("… and it never edits the source data", :337)
- CODE: `tools/store_migrate.nim:152-236, 310-369`
- FIX: none (verified) — own nats on an ephemeral port, engines started one at a time, source only ever `list`ed.

## A749 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:340 "(`--root`, `--to <engine>`, `--dry-run`, `--scan [<top>]`, `--all [<top>]`)"
- CODE: `tools/store_migrate.nim:396-420, 430-450` (the parser also accepts `--force`, `--quiet`, `-q` and `--version`)
- FIX: add — `--quiet`/`--version` exist and are unlisted; do **not** list `--force`: it is parsed and then read nowhere (the header promises it at `:11`, nothing honours it). Add the trap in the same paragraph: a migrated root holds both `var/barrel-db` and `var/store.db`, so re-running the tool on it — e.g. after the documented rollback (`NIF_STORE_BACKEND=barrel`) plus new barrel history — fails "ambiguous source; move one aside first"; the way back is to move the stale `var/store.db` aside (or delete it).

## A750 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:344 "`--scan` finds the top directory, sibling clones, and benchmark trees"
- CODE: `tools/store_migrate.nim:108-147`
- FIX: none (verified) — prunes `.git`/`node_modules`/`nimcache`; a root counts as un-migrated only when `barrel-db` exists and `store.db` does not (`:90-106`).

## A772 (doc-edit)
source: `components/store.md`

- MANUAL: **`niffler-store-migrate` silently loses whole kinds** and then reports success (MANUAL :337 "every document" is false; `tools/store_migrate.nim:398-407`). Measured: 2 of 5 documents dropped, "verified: every kind matches the source count", exit 0. This is the only finding in this report that can destroy user data, and the MANUAL currently promises the opposite.

## A777 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:55-86 (table: `store`…`dialog`, no `nats-server` row), against MANUAL:38 which declares that table the inventory of `components/` (`[already applied]` for the *sentence* — it now names `components/nats`; the **table row is still absent**)
- CODE: `components/nats/main.go:1-14`, `components/nats/go.mod:1-4` (module `nats`, nats-server v2.14.6), `Makefile:262-266` (`var/bin/nats-server`), `Makefile:310-313` (it is in the `components-inner` binary list), `manifest.yaml` (no entry)
- FIX: add — `| `nats-server` | Go | **not in the manifest** | the bus itself as a first-class component: a faithful rebuild of the official `nats-server` main (pinned in `components/nats/go.mod`), built by `make build` into `var/bin/nats-server` and preferred by core over a PATH install, so no NATS prerequisite is needed. Deliberately *not* a bus component — core starts it before the bus exists, it registers no tools, and `core.spawn` cannot start it. Niffler adds one flag, `--max_payload <bytes>` (core passes 8388608); on Linux it sets `PR_SET_PDEATHSIG` so no orphaned bus outlives its harness |`

## A780 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (how the bundled bus is obtained: `make build` compiles it; `make doctor` reports/explains it; there is no `make install-nats` — the target is a stub that says so)
- CODE: `Makefile:262-266`, `Makefile:620-623` (`nats-server: OK` / `built from source by 'make build' (components/nats)`), `Makefile:698-699` (`install-nats` prints "nothing to install")
- FIX: add — one bullet under **Attach to any bus**: "The bus binary ships with the repo: `make build` compiles `components/nats` into `var/bin/nats-server` (there is nothing to install — `make install-nats` only says so, and `make doctor` reports `nats-server: OK` or explains that it is built from source)."

## A786 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:55-86 (table, no `ctxtest`/`ctxsink` row) with MANUAL:38 (which, in the current revision, **`[already applied]`**, names `components/ctxtest` as "a fixture the nested-call tests (`t_fabric`, `t_agent`) compile for themselves" — two of the twelve tests that use it, and still not in the table)
- CODE: `components/ctxtest/` is one of the directory's 34 component dirs but is not shipped: `manifest.yaml` has no entry, `Makefile:305-313` does not build it, its own header says so (`main.nim:1-8`)
- FIX: add — one sentence under the Shipped-components table (MANUAL:86): "`components/ctxtest/` is the exception to "one directory per component = shipped": it is the contract tests' own fixture (a stub LLM plus schema/nested-call probes, registering the components `ctxtest` and `ctxsink`) — not in this table, not in `manifest.yaml`, and never built by `make build`."

## A802 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:64 `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml``
- CODE: `manifest.yaml:250-254` (`# Minimal example adapter (same tool contract, no streaming). Swap it back in place of `llm` to test: comment out llm, uncomment llm-openai.`), `components/llm-openai/main.go:199-215` (`sdk.New("llm-openai", "0.1.0")`, one `chat` tool), `core/catalog.nim:652-665` (a duplicate tool name is rejected: "catalog: rejecting … missing or duplicate tool name")
- FIX: add — one sentence right after the `llm` row (or a footnote on the row): "The example cannot run *alongside* `llm`: `chat` is a globally unique tool name, so `llm` must be commented out when `llm-openai` is uncommented (`manifest.yaml`). `make build` builds `var/bin/llm-openai` either way, so the swap is one manifest edit plus a harness restart."

## A803 (code-bug?)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:64 (`minimal non-streaming example`)
- CODE: `components/llm-openai/main.go:203-212` (schema: `messages`/`tools`/`model` only), `:170-189` (the result carries no `finish_reason`/`provider`/`reasoning`), `components/llm/main.go:1140` (the `llm` component also registers `llm_resolve`, which the example does not), `core/conversation.nim:1783-1785` (`except CatchableError: discard  # older/replaced llm components can still serve chat` — core tolerates the missing `llm_resolve`), `core/conversation.nim:2220-2221` (core takes the window from the chat reply's `context`, so the example's own table still arms the context guard)
- FIX: add — replace "swap it in via `manifest.yaml`" with a short labelled paragraph: "**What the example does and does not do.** It implements the `chat` contract's core — OpenAI-compatible Chat Completions, tool calls, usage, a context window the guard can use (core reads `context` from the reply, so a swapped-in adapter still arms context admission) — and deliberately nothing else: no `ev.llm.token` streaming deltas, no `llm.cancel.<sessionId>` abort (an in-flight HTTP call runs to its own 300 s timeout), no `reasoning_effort`/thinking passthrough, no provider-registry routing, no `finish_reason` (so core cannot see `length` truncation), no `llm_resolve` (core degrades gracefully: the turn proceeds, model resolution falls back to the request's own model). Stacked with its hardcoded `max_tokens: 32768` and its two-entry context table (`deepseek-chat`/`deepseek-reasoner`, else 128 000), that is the whole example."

## A820 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:49 `| `var/approval-sources/`, `var/mcp-results/`, `var/review-receipts/`, `var/fabric-cache/`, `var/plugins/` | approval prompt payloads, MCP bridge results, `review_receipt` fingerprints, compiled fabric programs and installed plugin clones — all disposable |`
- CODE: `components/mcp-bridge/operations.go:140-161` (creates `$NIF_ROOT/var/mcp-results` 0700 and writes `result-*.json` via `os.CreateTemp`), `:148` (root = `NIF_ROOT`, `.` when unset)
- FIX: none — verified accurate; optionally add "(nothing prunes them — the directory grows until an operator clears it)", matching the `fetch` spool note at MANUAL:1310-1312.

