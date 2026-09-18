# Worklist slice: Environment variables

From `worklist.tsv` (45 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A024 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: the 87-row table
- CODE: every documented name exists in code (checked name-by-name against `core/ components/ sdk/ ui/ scripts/ tests/ Makefile manifest.yaml .env.example`: zero misses) ✔
- FIX: none — this table is accurate and is the best section in the file.

## A025 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — shell/Makefile-only knobs are not listed anywhere
- CODE: `NIF_BIN_DIR` (`scripts/install.sh:43`), `NIF_LSP_BIN` (`scripts/install-lsp.sh:22`), `NIF_BUILD_LOCK` (`scripts/with-build-lock.sh:22`), `NIF_NATS_CLI` (`components/dialog/dialog.sh:44`), `NIF_STORE_BIN`, `NIF_REPO_ROOT` (test helpers), `NIF_CONF_KEEP`
- FIX: add a third short table "build/script knobs (not read by components)" with those five; today a reader cannot tell them from the runtime set.

## A026 (doc-edit, dup:mechanisms.md §X.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 368 "`.env.example` … is the complete reference: every `NIF_*` variable"
- CODE: `.env.example` omits `NIF_AUTO_CONTINUE`, `NIF_REPOMAP_MIN_CENSUS/_BYTES/_SYMBOLS/_FILES` while the MANUAL table lists them
- FIX: add the five lines to `.env.example`, or soften the sentence to "the reference copy of the documented runtime variables". `[dup]` mechanisms.md §X.

## A046 (trim)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 715-720 points at `gokr/niffler-weather` as the sample package
- CODE: `manifest.yaml:128-138` also documents the MCP bridge as a spawned-component example
- FIX: keep; add a pointer to `components/dialog/dialog.sh` (a whole bash component, no SDK) as the third reference shape.

## A110 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 239 and 895** — "a config change is `core.kill` + `core.spawn`" is incomplete: children inherit core's environment (`core/supervisor.nim:117-124`), so a variable exported only in the shell that launched core survives a kill+spawn unchanged.

## A262 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:330 `NIF_AUTO_APPROVE` "→ the approval gate (below) is bypassed"
- CODE: core/approval.nim:263 `proc askContinue` returns true when `NIF_AUTO_APPROVE == "1"` **or** `NIF_AUTO_CONTINUE == "1"` — so AUTO_APPROVE also answers every `/limit` keep-going question with yes, which MANUAL:515-516 attributes to AUTO_CONTINUE alone (auto-approve in `proc ask` is :272)
- FIX: append to the AUTO_APPROVE row: "also answers every `/limit` keep-going question with yes (implies `NIF_AUTO_CONTINUE`)"; and in the `/limit` prose: "`NIF_AUTO_CONTINUE=1` (or `NIF_AUTO_APPROVE=1`) answers …"

## A386 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:283` `NIF_OPENAI_CONTEXT` default cell "`models` catalog, then `llm` fallback"; `:108` "its small built-in model table and then a 128K fallback"
- CODE: `main.go:114-153`
- FIX: give the real order — stored provider `context`, then `NIF_OPENAI_CONTEXT`, then the catalog, then the built-in table, then 128000 — and name the built-in entries (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288), flagging that the table is code-resident and needs a source change for a new model.

## A394 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:308` `NIF_LLM_RETRY_AFTER_CAP_MS` "upper bound honored from a server `retry-after` hint"
- CODE: `main.go:536-578`
- FIX: name the mechanism: `llm` wraps the HTTP client, parses `Retry-After` (seconds or HTTP date), and appends `; retry-after-ms: <n>` to the provider's error message so core can honor the wait without each adapter depending on the same client library. Invalid/absent headers leave the error untouched.

## A398 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:279` `NIF_OPENAI_API_KEY` "Required for any conversation turn"
- CODE: `main.go:296-298`
- FIX: keep, but make the failure explicit: with no key at all the adapter refuses before any HTTP request with `provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`, which is a different symptom from the troubleshooting row's HTTP 401/403 (`:2318`, a key that exists but is rejected).

## A399 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (`stripPrefix`, `accountId` = 0 hits)
- CODE: `main.go:68-73`, `main.go:508-511`; `codex.go:41-52`
- FIX: fold into the provider-object documentation (delta 5) rather than a new paragraph: `stripPrefix` is the gateway workaround, and `accountId` is the ChatGPT account id used to build Codex request headers, derived from the JWT when the provider record does not carry one — a Codex call with neither fails with "OAuth token has no ChatGPT account id; sign in again".

## A441 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :288 `NIF_MODELS_PATH` "pinned local baseline catalog"
- CODE: catalog.go:581-589 — while it is set, `refreshBaseline` never fetches `NIF_MODELS_URL`, and the baseline status is `active` with that file as origin, so `force` cannot refresh it
- FIX: update — "While set, this file *is* the baseline: the component never downloads `NIF_MODELS_URL` (not even with `models_refresh {force:true}`), and changes to the file are picked up on the next refresh. Plugin sources and the override still apply."

## A442 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :292 `NIF_MODELS_CACHE_TTL` "minimum age before refetching the baseline"
- CODE: catalog.go:151-153 (`"0"` → 0) and 636-642 (`cacheTTL <= 0` ⇒ never fresh)
- FIX: update — "…; `0` disables the cache window so every refresh refetches the baseline."

## A458 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Env validation asymmetry.** `NIF_PROCESSES_POLL_CHUNK` is clamped to `[1024, 1048576]` (`main.nim:49-57`); `NIF_PROCESSES_SPOOL_CAP` is parsed without bounds (`main.nim:42-47`) and feeds `keep = min(2 MiB, cap div 2)` (`main.nim:206`) — a tiny/negative cap can empty a spool on the next poll. MANUAL:299-300 lists both as plain defaults. → add "clamped to 1 KiB-1 MiB" and "must exceed the keep size".

## A542 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "`NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default"
- CODE: `main.nim:170-171` (`--registry <url>` on `npm install`; empty → no flag)
- FIX: none [verified] — accurate; the row is the only TS-related fact in the MANUAL today.

## A543 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "**Build and script knobs** — read by the scripts around the harness, never by components: … `NIF_BUILD_LOCK` (lock file `scripts/with-build-lock.sh` flocks — exclusive for builds, shared for test runs) …"
- CODE: `scripts/with-build-lock.sh:22`, `Makefile:67-68`, `Makefile:581-582` (`clean` = `rm -rf var` under the exclusive lock), `components/builder/main.nim` (no lock call anywhere), `core/supervisor.nim:124` (children inherit the environment)
- FIX: update [delta] — the sentence is true about components, but it hides the consequence: `builder.build` runs **outside** the lock, so `make build`/`make clean` in a second terminal can race a runtime build — `clean` deletes `var/bin` and `var/build` under it. Add: "`builder.build` deliberately does not take this lock — stop the harness (or avoid `make clean`) while an agent is building a component."

## A601 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "`NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness, so they are not part of the runtime table below."
- CODE: components/dialog/dialog.sh:37-45 (`NIF_NATS_CLI` is the third fallback for the nats CLI of a spawned component)
- FIX: update to move `NIF_NATS_CLI` out of that list, e.g. "…`NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs… (`NIF_NATS_CLI` is the exception: the spawned bash component `dialog` reads it as the last fallback for the nats CLI, after `PATH` and `$HOME/go/bin/nats`)" [wrong]

## A602 (doc-edit)
source: `components/dialog.md`

- MANUAL: MANUAL: "`NIF_NATS_CLI` (the nats CLI `components/dialog/dialog.sh` drives)"
- CODE: components/dialog/dialog.sh:38-45 (PATH first, then `$HOME/go/bin/nats`, then `$NIF_NATS_CLI`)
- FIX: update to "`NIF_NATS_CLI` (the nats CLI `components/dialog/dialog.sh` drives — consulted only when `nats` is neither on `PATH` nor in `$HOME/go/bin`)" [doc-edit]

## A613 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "`NIF_COMPACTION_TIMEOUT_MS`" (its row says "whole candidate-call deadline (minimum 5000 ms) | `90000`")
- CODE: `core/compaction.nim:48`, `core/compaction.nim:52-53`, `core/compaction.nim:61`, `components/compaction/main.nim:216-217`, `core/dispatch.nim:1631-1642`
- FIX: update — "`NIF_COMPACTION_TIMEOUT_MS` | whole candidate-call deadline; clamped to 5000-600000, but the call's `x-harness.timeoutMs` caps the runner's wait at 120000, so values above 120 seconds only extend the component's own auxiliary deadline (the runner gives up first and the snapshot waits for the 600 s sweep) | `90000` |" — or fix the component's schema so the two agree.

## A614 (code-bug?)
source: `components/compaction.md`

- MANUAL: MANUAL: "whole candidate-call deadline (minimum 5000 ms)"
- CODE: `components/compaction/main.nim:216-217`, `core/compaction.nim:61`, `core/dispatch.nim:1637-1642`
- FIX: either raise `components/compaction/main.nim`'s `x-harness.timeoutMs` to core's 600000 clamp or clamp `NIF_COMPACTION_TIMEOUT_MS` at 120000 in `core/compaction.nim:61` — the documented "whole candidate-call deadline" is not true above 120 s today (code bug in the contract's own bounds; no test covers a >120 s configuration).

## A615 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "auxiliary summarization call budget granted to one attempt; a candidate reporting more calls than granted is rejected as invalid"
- CODE: `core/conversation.nim:1608-1616`, `components/compaction/main.nim:280-290`, `main.nim:302`
- FIX: add — "The shipped component always makes exactly one auxiliary call and reports `llmCalls: 1`; the budget exists for a summarizer that iterates. The granted count also scales `maxTotalInputTokens` and `maxTotalOutputTokens` in the request's `budget`."

## A616 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "per-call checkpoint output cap"
- CODE: `core/compaction.nim:63`, `components/compaction/main.nim:277`
- FIX: update — "per-call checkpoint output cap, clamped to 128-32768 and floored again at 128 by the shipped component | `2048`".

## A653 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "All components load `.env` (from the harness root and cwd, existing shell"
- CODE: components/grep/main.nim (no `getEnv`; only a `findExe("rg")` call at :26)
- FIX: none — [verified] the master table owes this component no row: the component reads no NIF_* variable at all, so the `.env` resolution this sentence describes applies to it unchanged, and its only host dependency (PATH to rg) belongs in the new chapter rather than the table.

## A672 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "| `NIF_HOOKS_TIMEOUT_MS` | per-hook timeout, clamped to 100–60000 ms; a timeout kills the hook and logs exit 124 | `10000` |"
- CODE: components/hooks/main.nim:93-97,78
- FIX: none — [verified] `clamp(parseInt(getEnv(...)), 100, 60_000)`, parse failure → `10000`, timeout → exit 124 via `runCmd`.

## A687 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_DIR` | JSONL output directory | `$NIF_ROOT/var/logs` |"
- CODE: components/logfile/main.nim:32-36
- FIX: update — [missing] "JSONL output directory (`$NIF_ROOT/var/logs` by default; an absolute path is used as-is, a relative one resolves against the harness root)".

## A688 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist | `ev.log.>` |"
- CODE: components/logfile/main.nim:204-227
- FIX: update — [missing] "comma-separated NATS patterns to persist (validated at boot: malformed, over-512-byte, more than 64 unique, or an empty list exits non-zero)".

## A689 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation | `10485760` |"
- CODE: components/logfile/main.nim:37-38
- FIX: update — [missing] append "; accepted range 256..104857600, outside it the component exits non-zero".

## A690 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables) | `5` |"
- CODE: components/logfile/main.nim:39,122-136
- FIX: update — [missing] append "; range 0..100, and generations above the value are deleted at every boot".

## A691 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl` | `64` |"
- CODE: components/logfile/main.nim:40-41,195-201
- FIX: update — [missing] append "; range 1..1024, files already present at boot count toward it".

## A692 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search` | `16777216` |"
- CODE: components/logfile/main.nim:42-43,350-360
- FIX: update — [missing] append "; range 1024..104857600, shared across all files of one search".

## A693 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query | `10000` |"
- CODE: components/logfile/main.nim:44-45,330-335,458-460
- FIX: update — [missing] append "; range 100..100000, applies to `logfile_paths` as well and is reported as `directoryTruncated`".

## A718 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_RING` | messages retained in observe's global ring | `2000` |"
- CODE: components/observe/main.nim:71
- FIX: update — [missing] append "; clamped 1..10000, outside it the component exits non-zero".

## A719 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_RING_BYTES` | approximate wire bytes retained in the global ring | `16777216` |"
- CODE: components/observe/main.nim:72-73
- FIX: update — [missing] append "; clamped 65536..104857600".

## A720 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_ENTRY_BYTES` | maximum retained bytes per observed message | `65536` |"
- CODE: components/observe/main.nim:74-75,143-147
- FIX: update — [missing] append "; clamped 1024..1048576, and a larger message is kept as a base64 preview of three quarters of the cap".

## A721 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_MAX_PROBES` | active + stopped probes retained at once | `32` |"
- CODE: components/observe/main.nim:78,410-413
- FIX: update — [missing] append "; clamped 1..256, and the next `observe_listen`/`observe_trace` fails with 'probe limit reached'".

## A722 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_PROBE_BYTES` | retained bytes per probe | `2097152` |"
- CODE: components/observe/main.nim:76-77,184-195
- FIX: update — [missing] append "; clamped 65536..16777216, entries are evicted oldest-first and a single entry above the cap is counted in `dropped`".

## A723 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_CAPTURE_DIR` | confined directory for `observe_dump` | `$NIF_ROOT/var/captures` |"
- CODE: components/observe/main.nim:81-85
- FIX: none — [verified] empty → `$NIF_ROOT/var/captures`, absolute → as-is, relative → resolved against the harness root.

## A724 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_CAPTURE_BYTES` | aggregate generated-capture quota; oldest files are pruned | `67108864` |"
- CODE: components/observe/main.nim:79-80,667-675
- FIX: update — [missing] append "; clamped 65536..1073741824, and when even pruning cannot fit a dump the tool fails with 'capture directory quota is exhausted'".

## A725 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `NIF_OBSERVE_MONITOR_URL` | explicit nats-server HTTP endpoint for an external/reused bus | core discovery file |"
- CODE: components/observe/main.nim:719-725
- FIX: none — [verified] empty falls back to `<NIF_ROOT>/var/nats-monitor-url`, then to a clear error.

## A755 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:398 "store engine selected at boot: `sqlite` (default → `var/bin/store-sqlite`)"
- CODE: `core/niffler.nim:451-470` (guard), `:493-501` (fallback)
- FIX: add — "An unset value that cannot be satisfied (no `var/bin/store-sqlite`) warns and falls back to `var/bin/store`; the un-migrated-barrel guard fires only for unset/`sqlite` and only while `var/store.db` does not exist yet."

## A756 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:399 "TiDB/MySQL DSN for the `tidb` store engine"
- CODE: `components/store-tidb/main.go:108-116,133-135,143-163`
- FIX: add — "The DSN needs the rights goose requires to apply its migrations (a fresh database, and again whenever a new migration ships). Its connect/read/write timeouts (5 s/60 s/30 s) and its single pooled connection are code-resident, not env-tunable."

## A757 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:387 "are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness"
- CODE: `tests/helpers.nim:291-311`, `Makefile:494,502`
- FIX: none (verified) — `NIF_STORE_BIN` is read only by the test helpers.

## A787 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:387 `NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness
- CODE: `components/ctxtest/main.nim:549,630,636,648,655,662,668,676` — `NIF_REPO_ROOT` is read by a *running component process* (the fixture) to load `components/fabric/examples/*.nim`; `tests/helpers.nim:331` reads it too
- FIX: update — "…and are never consulted by a shipped component (the test-only `ctxtest` fixture reads `NIF_REPO_ROOT` to load the fabric examples), so they are not part of the runtime table below."

## A804 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:406 `NIF_OPENAI_CONTEXT` … Resolution order: stored provider `context` → this → `models` catalog → `llm`'s built-in table (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288 — code-resident, so a new model needs a source change) → 128000`
- CODE: `components/llm-openai/main.go:47-57` — for the swap-in example the chain is **`NIF_OPENAI_CONTEXT` → a two-entry table (`deepseek-chat`/`deepseek-reasoner` 1M, `:40-43`) → 128000**; there is no provider, no `models` catalog and no `syn:large:text`/`zai-org/glm-5.3-flash` entry. The value is re-read per call (`:158`), unlike `llm`'s freeze-at-boot fields
- FIX: update — append to the row: "(the `llm-openai` swap-in example resolves only `NIF_OPENAI_CONTEXT` → a two-entry `deepseek-chat`/`deepseek-reasoner` table → `128000`, and re-reads the variable on every call)."

## A819 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:55-86 (table; the `mcp` row at 85 names the manager and its tools but not `mcp-bridge`) with MANUAL:38 (the table is the inventory of `components/`)
- CODE: `manifest.yaml:127-131` (`mcp` entry: the manager spawns one bridge per server; a bare `mcp-bridge` fails), `Makefile:222-223` and `:310-313` (built by `make build`, in the `components-inner` list), no manifest entry of its own
- FIX: add — extend the `mcp` row (or add a footnote under the table): "`mcp-bridge` (built by `make build` into `var/bin/mcp-bridge`, overridable with `NIF_MCP_BRIDGE_BIN`) is the per-server child the `mcp` manager supervises — it has no manifest entry and is never started by hand."

## A821 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:423 `| `NIF_MCP_BRIDGE_BIN` | explicit path of the mcp-bridge binary | `<root>/var/bin/mcp-bridge` |`
- CODE: `components/mcp/main.go:57-61` (read by the **manager**, not the bridge)
- FIX: none — verified accurate.

