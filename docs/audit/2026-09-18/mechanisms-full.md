# MANUAL.md full mechanism/capability delta audit

Scope: the **rest** of `docs/MANUAL.md` (2324 lines) — every section not already
covered by `mechanisms.md` (components/layout, context window, self-extension,
store, testing, fabric/subagents, spot checks), `mechanisms-sessions.md`
(runners, UI registry, lifecycle/autostart, clients) and `mechanisms-obs.md`
(approvals, plugins, skills, hooks, observe/logfile, store paging, `ev.*`).
It also extends those three where the task named a cross-cutting mechanism.
Read-only audit; no builds or tests were run. Appended after each pass so a
truncated run still leaves an artifact.

Format: `- MANUAL: <heading + line, quote or "absent"> | CODE: <file:line> | FIX: …`

---

## §Layout of a running system (31–49)

- MANUAL: line 36 the `components/` row enumerates 13 Nim + 3 Go components | CODE: `ls components/` = 34 dirs — the enumeration omits `compaction`, `recall`, `repomap`, `processes`, `mcp`, `mcp-bridge`, `nats`, `store-sqlite`, `store-tidb`, `ctxtest` (context-window test fixture, not in the manifest: `components/ctxtest/main.nim:1-6`) | FIX: replace the enumeration with "the component sources — see the table below"; the shipped-components table (line 50) is the inventory and is current.
- MANUAL: line 45 `var/logs/`, `var/captures/` row | CODE: also created under `var/`: `toolout/<session>/` (bash spills the transcript tail here, 1 h TTL sweep — `components/bash/main.nim:27-34`), `mcp-results/` (`components/mcp-bridge/operations.go:152`), `approval-sources/` (`core/approval.nim:99-121`, mode 0600), `review-receipts/` (`components/git/main.nim:364`), `fabric-cache/` (`components/fabric/fabric.nim:117`), `plugins/` (`components/plugins/main.nim:337`), `nats-monitor-url` (described at line 44 but not in this row) | FIX: add them all here and to the state table at line 244 — `var/toolout/` in particular is where every bash spill path returned to the model points.
- MANUAL: line 34 `core/` row ("bus bootstrap, supervisor, catalog, dispatch") | CODE: the same dir also owns `conversation.nim` (the whole turn loop), `compaction.nim`, `approval.nim`, `retry.nim`, `uireg.nim`, `tty.nim`, `schema_validation.nim` (`ls core/`) | FIX: mention the conversation loop/compaction/approval modules; today the row hides the largest file in core.

## §Shipped components (50–81)

- MANUAL: line 78 `lsp` row lists seven operations and implies one tool | CODE: the same component registers `lsp`, `lsp_servers`, `lsp_registry` (`components/lsp/main.nim:1088,1093,1097`) and the `lsp` operation enum includes **`warmup`** (`:1063-1081`, documented at MANUAL 950) | FIX: add `warmup` and name the two extra tools, or say "three tools; see Language servers".
- MANUAL: line 66 `builder` row "compiles agent-written Nim/Go source into binaries" | CODE: `builder.build` accepts `files`/`defines` and is approval-gated + onDemand, and a second tool `builder.info` exists (`components/builder/main.nim:49-51,203`) | FIX: "`builder.build {lang, name, source, files?, defines?}` (approval-gated, on-demand) plus on-demand `builder.info`". `[dup]` mechanisms.md.
- MANUAL: line 51 `store` row lists `put/get/list/del` without flags | CODE: all four are onDemand, `del` is additionally `hidden` (core-only) — `components/store/main.nim:120,130,171-178` | FIX: append "(all four on-demand; `del` is hidden — core deletes records, the model cannot)". `[dup]` mechanisms.md.
- MANUAL: line 72 `agent` row names only `agent_run` | CODE: nine tools (`components/agent/main.nim:1004,1149,1254,1278,1316,1346,1419,1484,1543`) | FIX: "nine tools (`agent_run`/`spawn`/`status`/`wait`/`stop`/`steer`/`ask`/`notices`/`list`) — see Fabric and subagents". `[dup]` mechanisms.md.
- MANUAL: line 70 `grep` row "optional (4 replicas)" | CODE: `manifest.yaml:112-120` (`replicas: 4`) and both tools (`grep` direct with `parallel: true` at `components/grep/main.nim:52`, `files` onDemand at `:100`) ✔ | FIX: none.
- MANUAL: line 63 `repomap` row (opt-in append, gates, `var/repomap-tags/` cache, thresholds) | CODE: `components/repomap/main.nim:8-23,39,49-51,178-186,254-255` (`NIF_REPOMAP_MIN_*` defaults 50/800/25/5, onDemand + `effect: read`, mtime-keyed JSON cache) ✔ | FIX: none.
- MANUAL: line 79 row `dialog` "ships in `var/bin/dialog` but is **not autostarted**" | CODE: `Makefile:285,298` builds it, `manifest.yaml` has no `dialog` entry, `Makefile:685-686` states "optional demo, not autostarted" ✔ | FIX: none.
- MANUAL: line 53 `bash` row (`text` = `(exit N)` + stdout/stderr, machine fields `exit_code`, `cancelled`, `spill{path,bytes,lines}`, 124/130, no orphaned children) | CODE: `components/bash/main.nim:164-188` ✔ | FIX: none.
- MANUAL: absent — no row for `components/nats` (the bus binary core spawns) or `components/ctxtest` | CODE: `components/nats/main.go`, `components/ctxtest/main.nim:1-6` | FIX: one short paragraph "not a bus citizen: `components/nats` builds `var/bin/nats-server`, the bus core spawns when no URL answers; `ctxtest` is a test-only fixture the nested-call test compiles itself".

## §Minimal boot profile (82–125)

- MANUAL: lines 84-99 "filters the manifest boot set to exactly three service components … Persisted components … are deliberately not restored … Minimal mode is only a boot profile, not a policy boundary — a caller can still use `core.spawn`" | CODE: `core/niffler.nim:25` (`minimalComponents = ["store","bash","llm"]`), `:473` (skip non-minimal autostart), `:593-594` ("minimal mode — persisted spawned components stay stopped") ✔ | FIX: none.
- MANUAL: lines 100-108 "neither `provider` nor `models` is present … `llm` uses its small built-in model table and then a 128K fallback" | CODE: `components/llm/main.go:91-96` (`knownContext` = deepseek-chat/deepseek-reasoner/syn:large:text/zai-org/glm-5.3-flash), `:146` lookup then conservative fallback ✔ — but the two DeepSeek ids are **retired upstream** (docs/research/DEEPSEEK.md §3) | FIX: keep the mechanics; add "`NIF_OPENAI_CONTEXT` is the only correct answer on DeepSeek today — the built-in table still lists the discontinued `deepseek-chat`/`deepseek-reasoner` ids".

## §Session runners (126–145)

Covered by `mechanisms-sessions.md` (11 findings). No new delta; two spot checks confirm it: `core/conversation.nim:2858-2901` (`ensureRunner`, 10 s readiness poll), `core/session.nim:118` (mid-turn call refused with `busy`).

## §Store engines (146–194)

- MANUAL: line ~185 "All engines enforce single-writer the same way: one process owns the file (flock; kernel-released on crash), everyone else speaks envelopes." | CODE: this contradicts the section's own tidb bullet 40 lines above ("No flock — the cluster is shared state by design", MANUAL 173-181; `components/store-tidb/main.go:71` DSN, no lock file) | FIX: "The file-backed engines are single-writer by flock (kernel-released on crash); tidb has no file to lock — the cluster is shared by design and row locks plus the rev counter arbitrate between harnesses."
- MANUAL: lines 189-193 the `list` page paragraph (`nextAfter` back as `after`) | CODE: accurate but incomplete — `limit` defaults to **100** and is clamped to 1000, `after` is exclusive, `nextAfter` is absent when `hasMore` is false (`components/store/main.nim:130,145-168`) | FIX: add the default and the cursor rule; also fix the "an `nextAfter`" typo. `[dup]` mechanisms-obs.md.
- MANUAL: line 158-181 engine bullets (sqlite one-statement put, goose migrations, `modernc.org/sqlite`, barrel two-key crash window, tidb MEDIUMTEXT/`utf8mb4_bin`) | CODE: `components/store-sqlite/main.go:71-72,142,183,304-331` (goose migrations, `modernc.org/sqlite`, WAL, single upsert), `components/store-tidb/main.go:21-45,292` (MEDIUMTEXT rationale, `FOR UPDATE` compare-and-set), both engines keep the create-path rationale in their own headers | FIX: keep, but see (Z): the engine *rationale* belongs in `research/STORE_V2.md`; MANUAL should carry the selection table and the "switching does not migrate" warning only.

## §Migrating between engines (195–229)

- MANUAL: lines 195-229 (full `niffler-store-migrate` walkthrough: refusal text, `--root/--dry-run/--scan/--all`, "runs offline … never edits the source data … verifies per-kind counts") | CODE: the tool is `Makefile`-built into `var/bin` and designed in `docs/research/STORE_V2.md` ("Moving data between engines") | FIX (Z): keep the 6-line summary plus the refusal message (it is what an operator sees), move the flag walkthrough to a pointer at `docs/research/STORE_V2.md`. `[dup]` mechanisms.md §Z.

## §State and configuration (230–260)

- MANUAL: line 239 "process lifetime — components read env once at boot; **a config change is `core.kill` + `core.spawn`**" | CODE: children inherit **core's** environment, not the shell you type in: `core/supervisor.nim:117-124` (`startChild`, "env = nil inherits the parent environment") | FIX: "components read env once at boot, so a change needs `core.kill` + `core.spawn` — **except** a variable exported in the shell that started core: the child inherits core's environment, so a shell-only change requires restarting the harness (or putting it in `.env`, which every component reloads at its own startup: `sdk/niffler/sdk.nim:771`). Manifest-level settings (`NIF_STORE_BACKEND`) are resolved by core at boot." Same wording should replace MANUAL 895 ("read at boot (config change = `core.kill` + `core.spawn`)").
- MANUAL: line 244 `var/` row lists `bin/, logs/, models/, nats-url/nats-pid, processes/, repomap-tags/, fetch/, captures/, store.db` | CODE: missing `toolout/` (`components/bash/main.nim:27-34`), `approval-sources/` (`core/approval.nim:99-121`), `mcp-results/` (`components/mcp-bridge/operations.go:152`), `review-receipts/` (`components/git/main.nim:364`), `fabric-cache/` (`components/fabric/fabric.nim:117`), `plugins/` (`components/plugins/main.nim:337`), `nats-monitor-url` | FIX: add them; this table is the map a debugging operator uses. `[dup]` mechanisms-obs.md for `approval-sources/`.
- MANUAL: lines 245-250 "Home / project files … skills trees (project `.agents|.claude|.opencode/skills` > bundled `skills/` > home `~/.niffler/skills` + agent-standard dirs > `~/.config/opencode/skills`)" | CODE: correct — the search path is exactly project `.agents/.claude/.opencode/skills`, bundled `<repo>/skills`, home `.agents/.claude/.opencode/.niffler/skills`, then `$XDG_CONFIG_HOME/opencode/skills`, first match wins, fresh walk per call, with the compiled-in `(baked)` tree as the last resort (`components/skills/main.nim:200-220`) | FIX: add the baked last-resort source (only mentioned in the `NIF_SKILLS_BUNDLED_DIR` env row today).
- MANUAL: line 254 "The **repomap, lsp and skills** components additionally treat `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo *markers*" | CODE: wrong on both counts — `skills` walks no build files at all (fixed dirs, `components/skills/main.nim:200-215`), and the two that do use different sets: lsp per language (`.go`→`go.mod`/`go.work`, TS→`tsconfig.json`/`package.json`, `.nim`→`*.nimble`/`config.nims`, `components/lsp/roots.nim:29-34`) and repomap (`package.json`, `Cargo.toml`, `go.mod`, `config.nims`, `components/repomap/main.nim:134`) | FIX: "The `lsp` and `repomap` components treat build files (`go.mod`/`go.work`, `tsconfig.json`/`package.json`, `*.nimble`/`config.nims`, `Cargo.toml`) as repo *markers* — where to walk from, not configuration they parse. `skills` uses fixed directories only."
- MANUAL: lines 240-241 "boot decisions are environment, identity/selection is the store, per-conversation choice is the conversation header, display is the browser" | CODE: matches `core/conversation.nim:203-215` (header fields), `core/dispatch.nim:394-402` (`profile` records), `ui/frontend/src/lib/*` (localStorage) ✔ | FIX: none.

## §Environment variables (261–356)

- MANUAL: the 87-row table | CODE: every documented name exists in code (checked name-by-name against `core/ components/ sdk/ ui/ scripts/ tests/ Makefile manifest.yaml .env.example`: zero misses) ✔ | FIX: none — this table is accurate and is the best section in the file.
- MANUAL: absent — shell/Makefile-only knobs are not listed anywhere | CODE: `NIF_BIN_DIR` (`scripts/install.sh:43`), `NIF_LSP_BIN` (`scripts/install-lsp.sh:22`), `NIF_BUILD_LOCK` (`scripts/with-build-lock.sh:22`), `NIF_NATS_CLI` (`components/dialog/dialog.sh:44`), `NIF_STORE_BIN`, `NIF_REPO_ROOT` (test helpers), `NIF_CONF_KEEP` | FIX: add a third short table "build/script knobs (not read by components)" with those five; today a reader cannot tell them from the runtime set.
- MANUAL: line 368 "`.env.example` … is the complete reference: every `NIF_*` variable" | CODE: `.env.example` omits `NIF_AUTO_CONTINUE`, `NIF_REPOMAP_MIN_CENSUS/_BYTES/_SYMBOLS/_FILES` while the MANUAL table lists them | FIX: add the five lines to `.env.example`, or soften the sentence to "the reference copy of the documented runtime variables". `[dup]` mechanisms.md §X.
- MANUAL: line 233/239 "`.env` (root, gitignored) holds secrets and local overrides; shell env wins" | CODE: also true, and the loader is hardened beyond what MANUAL says: 1 MiB cap, symlinks/multiply-linked files refused, no `$VAR` expansion (`sdk/dotenv.nim:1-27,40-52`) | FIX: one sentence — "`.env` must be a plain regular file: symlinked or hardlinked copies are refused, the file is capped at 1 MiB, and values are never variable-expanded".

## §The .env file (357–376)

- MANUAL: lines 370-372 "Loading rules (**identical** in the Nim SDK, Go SDK and the UI bridge): existing shell environment always wins over `.env`; `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order" | CODE: the *order* differs — Nim SDK `loadDotEnv(".env", NIF_ROOT/.env)` (`sdk/niffler/sdk.nim:771`), Go SDK the same (`sdk/go/component.go:414`), but the UI bridge passes the **root first** (`ui/bridge.go:71` `sdk.LoadDotEnv(harnessRoot()/.env, ".env")`) | FIX: state the per-binary order: "components and core load `./.env` then `$NIF_ROOT/.env` (cwd wins — the first file loaded sets the key); the UI bridge is the exception and loads the harness root first, so in the desktop app the repo's `.env` wins over a cwd one."

## §The bus in one screen (377–454)

- MANUAL: lines 386-421 subject/event block presented as the subject inventory | CODE: omits `ev.log.<component>`, `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`, the `ev.fabric.*` family (file:line in `mechanisms-obs.md` "Events") | FIX (Z + update): reduce to a 6-line overview — `reg.*`, `svc.*`, `ev.*`, `cancel.*`, `llm.cancel.*` — and link `docs/WIRE.md` for the normative per-subject tables; the complete event table belongs in WIRE, not MANUAL. `[dup]` mechanisms-obs.md.
- MANUAL: line 398 stray `#` comment markers inside the subject block | FIX: cosmetic; drop them when trimming.

## §Approvals (455–486) and §Conversation controls (487–523)

- MANUAL: lines 502-505 (per-tool "don't ask again") and 455-467 (the gated-tool list) | CODE: `mechanisms-obs.md` found ten missing gated tools plus the store-kind/key shape | FIX: apply that finding; no new delta here.
- MANUAL: lines 511-514 "`/limit rounds=N tokens=N seconds=N` — soft budgets for a turn: LLM rounds, cumulative tokens, and wall-clock seconds (**checked before every tool dispatch, not only between rounds**)" | CODE: only **seconds** is checked before every dispatch (`core/conversation.nim:2190-2196`); rounds and tokens are checked at round boundaries (`:1817`, `:1823`) | FIX: "…and wall-clock seconds, which is checked before every tool dispatch (one `bash` call can outlast a whole round); rounds and tokens are checked before the next LLM round."
- MANUAL: lines 511-519 "a *yes* extends that limit by one more step … A *no*, no answer, or no reachable client ends the turn with a distinct `limit-<dimension>` record that names the limit and the command that raises it. `/limit clear` removes all three." | CODE: exact — `softRounds += max(limitRounds,1)` per grant (`core/conversation.nim:1757-1759`), `"error": "limit-" & dimension` + "raise it with /limit rounds=<n>" (`:1768-1778`), all-zero `limits` object clears (`:2651,2694`); the ask rides the approval transport as tool `turn-limit` (`:1736-1741`) | FIX: none — consider naming the pseudo-tool `turn-limit` so an operator can grep the approval log.
- MANUAL: line 538 (in §Context window) `session {… tools?, maxRounds?, maxCalls?, maxTokens?}` | CODE: accepted (`core/conversation.nim:2427-2457`), but **not declared** in the `session` tool schema (`core/catalog.nim:184-196` lists only sessionId/content/title/model/thinking/cwd/profile) and the allowlist silently stops at 32 names (`:2429`) | FIX: document the 32-name allowlist cap and file the schema gap as a code fix; a client reading the schema cannot discover these arguments.

## §Context window (524–637)

- MANUAL: line 570 "the status event also carries `cacheHitTokens` and `cacheHitRatio`" | CODE: no such fields exist; the event carries a nested `cache {prompt, read, hitRate}` (`core/conversation.nim:2103-2106`) and the header keeps `cachePrompt/cacheRead/cacheHitRate` (`:463`) | FIX: use the real names (also fix `components/hooks/README.md:35`). `[dup]` mechanisms.md.
- MANUAL: lines 596-600 "A successful projection emits `reset:compact`; … `reset:prune`; … `reset:trim`. `reset:tools` remains reserved … **These are the only intentional prompt-prefix rebuilds**" | CODE: four reset reasons confirmed (`core/conversation.nim:777,793,1228,1613`) and non-reset reasons also exist: `warn:threshold` (`:845`), `compact:failed|declined|invalid|stale` (`:1466-1543`), `context-overflow` (`:1978`) | FIX: append "other `ev.session.context` reasons (`warn:threshold`, `compact:*`, `context-overflow`) report a decision and never rebuild the prefix". `[dup]` mechanisms.md.
- MANUAL: absent — `x-harness.runner` (the fifth core-honoured schema extension) is documented nowhere in MANUAL or AGENTS.md | CODE: `core/dispatch.nim:1455-1473` lets a `hidden` + `runner: true` tool bypass a session's tool allowlist (`components/compaction/main.nim:216`, `components/recall/main.nim:166`) | FIX: add one sentence to §Progressive discovery: "A tool marked `x-harness.runner: true` **and** `hidden` is exempt from a session's frozen tool allowlist, so a replaced compactor or recall resolver keeps working in an allowlisted (subagent) session without a core edit."
- MANUAL: lines 601-607 (replaceable `compaction_propose`, `NIF_COMPACTION_*` bounds, runner-owned paged `compaction_input` snapshot, validation of generation/digest/cut/schema/size, single `context_projection` commit with `expectRev`, "The component never writes conversation or projection records") | CODE: `components/compaction/main.nim:216-219` (hidden + `runner: true`), no `storePut`/`storeDel` anywhere in `components/compaction` (verified by grep), `core/compaction.nim:47-58` (tool/timeout/call/token knobs) ✔ | FIX: none.
- MANUAL: lines 623-627 "`context_recall` resolves canonical/spill/current-checkpoint refs" | CODE: `components/recall/main.nim:6-15` names exactly `{source: canonical|spill|checkpoint}` and resolves each (`:74-100`, spill via `storeGet("spill", id)`); the runner's notices point at it (`core/conversation.nim:674,1186-1201`) | FIX: none — this is accurate.
- MANUAL: lines 529-536 "The effective window is resolved by hidden `llm_resolve {model?}` before each turn" | CODE: `core/conversation.nim:917` (`dispatchToolCall("llm_resolve", …, 10_000)`) ✔ | FIX: none.
- MANUAL: lines 548-553 "`maxCalls` (total tool dispatches per turn, 1-500 — every dispatch attempt counts, success or error)" | CODE: `core/conversation.nim:2204` + `inc toolCallsMade` before dispatch at `:2250` ("every dispatch attempt counts") ✔ | FIX: none.

## §Self-extension and component lifecycle (638–673)

- MANUAL: line 646 "`builder.build {lang, name, source}` compiles it into `var/bin/`" | CODE: also `files` (extra Go sources) and `defines` (`components/builder/main.nim:50-51`) | FIX: add the two optional fields. `[dup]` mechanisms.md.
- MANUAL: lines 648-649 "`core.kill {name}` … (restored on next boot); `core.remove {name}` stops the group and deletes its persisted record" | CODE: `core/dispatch.nim:325-347`, `core/supervisor.nim:217-246`; note the registered names are `spawn`/`kill`/`remove` (`core/catalog.nim:68,81,89`) | FIX: name them `spawn`/`kill`/`remove` and say "the core-* prefix is how the docs refer to them". `[dup]` mechanisms-obs.md / mechanisms-sessions.md.
- MANUAL: lines 651-666 (replicas 1–16, queue group, single-writer warning, `ToolConcurrent`/`ConcurrentLimit`, `x-harness.parallel`) | CODE: `core/catalog.nim:79-95,295`, `core/dispatch.nim:1631-1654` ✔ | FIX: none.
- MANUAL: absent — restart policy is never described in prose | CODE: `never | on-failure` with 0.5 s→8 s backoff (`core/supervisor.nim:14-16,33-49`), manifest per entry (`manifest.yaml`), `core.spawn` always `on-failure`, runners always `never` | FIX: apply the `mechanisms-sessions.md` wording; it is the missing paragraph that explains both "restored on next boot" and the boot crash-loop symptom at MANUAL 2322.

## §Component ecosystem (674–720), §Skills (721–798), §Hooks (884–908)

Covered by `mechanisms-obs.md` (about 20 findings, including the `niffler.json` schema gap, the skill `name` fallback, hook payload caps and the dangling `components/hooks/main.nim:2` → `docs/HOOKS.md` reference). No new delta; one addition:

- MANUAL: line 715-720 points at `gokr/niffler-weather` as the sample package | CODE: `manifest.yaml:128-138` also documents the MCP bridge as a spawned-component example | FIX: keep; add a pointer to `components/dialog/dialog.sh` (a whole bash component, no SDK) as the third reference shape.

## §Provider registry (799–883)

- MANUAL: the 13-row tool table | CODE: all 13 names exist in `components/provider/main.go` (+ `provider_oauth_*` in `oauth.go:134,160,180`); measured flags: `provider_add` approval+onDemand (`:344`), `provider_update` hidden+approval (`:454`), `provider_list` onDemand (`:547`), `provider_switch` onDemand (`:587`), `provider_status`/`provider_active`/`provider_get`/`provider_use_environment` hidden (`:614,635,687,710`), `provider_models` onDemand 20 s (`:756`), `provider_export`/`provider_import` approval+onDemand (`:816,851`) | FIX: the table is right about hidden/approval; add a flags column (hidden / approval / on-demand) so the "hidden client API" prose need not be parsed per row.
- MANUAL: line 833-835 "Every credential read (`provider_active`, `provider_get`, status resolution) refreshes the token transparently when it is within 5 minutes of expiry and persists the rotated credential. The `llm` component never sees a refresh token." | CODE: `components/provider/oauth.go:29-30` (`oauthFlowLifetime = 15m`, `oauthRefreshAhead = 5m`), `:557` (`refresh`) ✔ | FIX: none.
- MANUAL: line 843-845 "ports stay fixed at 1455/53692 like the reference clients" | CODE: `components/provider/oauth.go:63-65` (1455) and `:79-81` (53692) ✔ | FIX: none.
- MANUAL: line 866-868 "`provider_models` … Disk-cached 5 min per endpoint (stale cache served when the probe fails)" | CODE: `components/provider/models.go:28` (`modelsCacheTTL = 5 * time.Minute`), `:68-74` (`refresh` bypasses) ✔ | FIX: none.
- MANUAL: absent — the OAuth *flow* lifetime is not stated | CODE: `oauthFlowLifetime = 15 * time.Minute` (`components/provider/oauth.go:29`) means an abandoned login flow expires | FIX: add "a started login flow expires after 15 minutes (`oauthFlowLifetime`); `provider_oauth_start` returns `expiresAt`".

## §Fetch (909–933)

- MANUAL: lines 909-933 (one tool, methods, `convertToText`, trafilatura within 30 s, 10 MiB/50 MiB caps, 200 KB spill, `ok:false` errors, "Read-only network access — no approval gate") | CODE: `components/fetch/main.nim:27-31` (`DefaultMaxSize`, `MaxSizeLimit`, `MaxInlineBytes = 200_000`, `TrafilaturaTimeoutMs = 30_000`), `:258-292` (methods + `maxSize` validation 1024..52428800), `:177` (`NIF_FETCH_ALLOW_PRIVATE`), no `x-harness.approval` anywhere in the file ✔ | FIX: none.
- MANUAL: line 926 "content over 200 KB after processing is written to a file under `$NIF_FETCH_DIR`" | CODE: `MaxInlineBytes = 200_000` is applied to the extracted text (`components/fetch/main.nim:29`, spill at `:137`) ✔ | FIX: none.

## §Language servers (934–1032)

- MANUAL: lines 949-961 ("all three tools are on-demand", `lsp` read-only/approval-free, `lsp_registry` approval-gated) | CODE: `components/lsp/main.nim:1085` (lsp: onDemand, `effect: read`), `:1090` (lsp_servers), `:1098` (lsp_registry: onDemand + `approval: always`) ✔ | FIX: none.
- MANUAL: line 994-996 "the component runs a bounded extension census (stops at 5 000 files or a 2 s budget) and pre-starts servers for the most prevalent languages" | CODE: `WARM_MAX_FILES = 5000`, `WARM_BUDGET_SECS = 2.0`, **`WARM_MAX_SERVERS = 2`** (`components/lsp/main.nim:741-743,792`) | FIX: add "at most two servers per workspace (`WARM_MAX_SERVERS`)" — the missing number is what makes a warmup look partial.
- MANUAL: line 968-970 "results are capped (100 locations / 16 KB)" | CODE: `MAX_LOCATIONS = 100` (`:40`) and "result caps (100 locations / 16000 chars)" (`:25`) — 16 000 **chars**, not 16 KiB | FIX: say "100 locations / ~16 000 characters".
- MANUAL: line 1031 "The registry is re-read on every call, so edits take effect immediately" | CODE: accurate — `loadRegistry()` is called on every operation path (`components/lsp/main.nim:783,872,952,984,1225`) | FIX: none.
- MANUAL: line 1021-1024 "Built-in defaults — gopls, nimtortoise, typescript-language-server, pyright, rust-analyzer, clangd, bash-language-server, jdtls, csharp-ls" | CODE: `components/lsp/main.nim:76-92` lists exactly gopls, nimtortoise, typescript-language-server, pyright (as `pyright-langserver --stdio`), rust-analyzer, clangd, bash-language-server, jdtls, csharp-ls ✔ | FIX: none.

## §Background processes (1033–1084)

- MANUAL: lines 1042-1046 tool table (`process_start` approval-gated, `process_poll` 25 s cap/read-effect, `process_kill` approval-gated, `process_list` read-effect) | CODE: `components/processes/main.nim:491-530` (exact four; gates at `:500,521`), `MAX_WAIT_MS = 25_000`, `TAIL_BYTES = 64 * 1024` (`:36,40`) | FIX: none `[dup]` mechanisms.md for the approvals list.
- MANUAL: lines 1050-1056 "spool beyond the cap (32 MiB, `NIF_PROCESSES_SPOOL_CAP`) truncated to its tail … one poll returns at most `NIF_PROCESSES_POLL_CHUNK` new bytes per stream (default 64 KiB). Cap: 32 concurrent processes; the 50 most recent finished entries stay in the registry." | CODE: `:33-43` (`MAX_LIVE = 32`, `KEEP_FINISHED = 50`, `SPOOL_CAP = 32*1024*1024`, poll chunk env with 65536 default) ✔ | FIX: none.
- MANUAL: lines 1057-1063 ("A finished process tells its conversation … publishes an exit notice into it (the same lane subagent settlement notices use)") | CODE: `components/processes/main.nim:446-447` (`svc.session.<id>.steer` with a `{notice: …}` payload), `:71-73` (notified once) ✔ | FIX: none.
- MANUAL: line 1063 "(own process group, stdin from /dev/null…)" | CODE: `:301-304` (`< /dev/null` in the launched command) ✔ | FIX: none.

## §External MCP servers (1085–1262)

- MANUAL: lines 1116-1122 name rule "≤32 chars, `bridge` reserved; **≤100 servers per harness**; tool names … capped at 64 chars" | CODE: `components/mcp/types.go:54-55` (32-char pattern, bridge reserved at `main.go:398`), `types.go:87` (64-char tool names); **no server-count cap was found** (`grep -rn 'maxServers\|serverLimit' components/mcp/*.go` → nothing; the manager reads up to 1000 records at `main.go:170`) | FIX: **remove** "≤100 servers per harness" — it is enforced nowhere (see (X) item 5); if a cap is wanted, say so in the code first.
- MANUAL: lines 1173-1183 record example (`idleMs` 5 min, `timeoutMs` 120 s) | CODE: `main.go:92-93` (timeout 0 ⇒ 120 s, idle default 300000), `:440` (both clamped 0..86400000 = 24 h) ✔ | FIX: none.
- MANUAL: lines 1199-1207 tools table (5 rows: `mcp_servers`/`add`/`edit`/`remove`/`refresh`) | CODE: a sixth tool `mcp_search` exists (`components/mcp/main.go:148`), and the bridge also registers per-server `mcp_<server>_resources` (`mcp-bridge/operations.go:379`) and `mcp_<server>_prompt` (hidden) | FIX: add `mcp_search` to the table and a "per-server tools appear after `mcp_add`" note. `[dup]` mechanisms.md for `mcp_search`.
- MANUAL: lines 1210-1213 "Adding an MCP server therefore asks for approval twice by design: once for the `mcp_add` itself, once for the `core.spawn` it triggers" | CODE: `main.go:98,123,134` (the three write gates) plus core's own spawn gate (`core/dispatch.nim:273-276`) ✔ | FIX: none.
- MANUAL: lines 1188-1196 "MCP results ≤64 KiB are returned inline; larger results are spilled to `$NIF_ROOT/var/mcp-results/result-*.json`" | CODE: `mcp-bridge/operations.go:19` (`inlineLimit = 64 * 1024`), `:152` (`var/mcp-results`), `:180` (`spill` + `truncated`) ✔ | FIX: none.
- MANUAL: lines 1136-1150 (name collision rejection, `[mcp:<server>]` provenance prefix, onDemand default, `expose: direct` + `NIF_MCP_DIRECT_THRESHOLD`) | CODE: `mcp-bridge/operations.go:322` (threshold), `main.go:90` (expose enum), `types.go:111-122` (≤32 prompts / ≤16 args) ✔ | FIX: none.

## §Progressive tool discovery (1263–1517)

- MANUAL: lines 1462-1471 "With the complete shipped manifest, **7 tools are direct**: Core `discover`, `invoke`; `bash`, `grep`, `read`/`edit`/`write`" | CODE: exactly right — the direct set is every non-hidden, non-onDemand tool: `core/catalog.nim:126,160,175` (`discover`, `invoke`; `profile` is onDemand), `components/bash/main.nim:119` (no onDemand), `components/grep/main.nim:52` (`grep` has no onDemand; `files` does at `:100`), `components/edit/main.nim:1252,1282,1317` (`read`/`edit`/`write`; `undo_last_edit` onDemand at `:1303`) | FIX: none — but add "(7 with the shipped manifest; a profile can only grow the set, `NIF_PROFILE`/`profile`)" for the case a reader counts more.
- MANUAL: lines 1404-1407 "Request only the tools needed for the next step, up to 16 at a time" | CODE: `"maxItems": 16` on `discover.tools` and `catalog.tools` (`core/catalog.nim:105-107,146-148`) ✔ | FIX: none.
- MANUAL: lines 1343-1350 "An empty query returns the bus directory with tool names only; … descriptions are whitespace-normalized one-line hints capped at 200 characters, and volatile fields such as pid and registration time are excluded" | CODE: `core/catalog.nim:404` (`if result.len > 200`), `:430-453` (direct/onDemand hint arrays, empty query → names only) ✔ | FIX: none.
- MANUAL: lines 1412-1416 "`tools` without a `component` searches every live component … names with no discoverable tool are listed in `notFound` (an empty schema set is an error naming the requested tools)" | CODE: `core/catalog.nim:477-494` (`notFound` array, empty-set error) ✔ | FIX: none.
- MANUAL: line 1395-1399 "Unknown and hidden tool requests have the same error shape so discovery is not a hidden-tool existence oracle" | CODE: same name-free rule in profiles (`core/catalog.nim:344-348`) and `invoke`; `toolSchema` returns nil for hidden (`:315`) ✔ | FIX: none.
- MANUAL: lines 1421-1460 (session-snapshot caching, store kind `session` id `<sessionId>:tools`, `{version, direct, discovered, initializedAt, updatedAt}`) | CODE: `core/conversation.nim:469-513,1167,1228` ✔ | FIX: none.
- MANUAL: lines 1307-1339 (core tool prose: `profile`, `session_info`, `prompt_preview`, `doctor` incl. deep self-test fan-out and `ask`) | CODE: `core/catalog.nim:126-183` — all four exist with those semantics (`doctor` at `:113-125`, `prompt_preview` `:136`, `session_info` `:141`, `profile` `:175`) ✔ | FIX: none.
- MANUAL: lines 1310-1313 "`/components [all|direct|discovered|undiscovered]`, `/discover COMPONENT`, `/profile NAME`" | CODE: both clients implement them — web UI `ui/frontend/src/lib/slash.ts:73` (`/components` with the all/direct/discovered/undiscovered filter), `ui/frontend/src/lib/slashDispatch.ts:225-240` (`/profile`, `/discover COMPONENT` and `/discover tool=NAME`, the latter sending a content-less `session` call carrying `discovery`); TUI `~/git/niffler-tui/tui/slash.go:172` | FIX: none.
- MANUAL: line 1504 "Deleting a conversation also deletes its exposure document." | CODE: true for core's `conversation_delete` (`core/dispatch.nim:406-461`), **not** for the shipped web UI, which deletes raw store records (`ui/frontend/src/views/Sessions.svelte:55-67`) | FIX: apply the `mechanisms-sessions.md` finding (make the SPA call `conversation_delete`, or document the deviation). `[dup]`.

## §Model catalog (1518–1681)

- MANUAL: lines 1543-1548 merge order ("registered `x-models-source` plugins, ascending by `priority` and then by `component/tool`. **A larger priority therefore wins**") | CODE: `components/models/catalog.go:345-362` sorts ascending by priority then key and applies patches in that order (`:358-364`, second copy `:545-556`) ✔ | FIX: none.
- MANUAL: lines 1550-1564 ("refreshes at startup and hourly", "skipped while its cache is younger than five minutes", atomic rename into `var/models/api.json`, `var/models/sources/` last-known-good, retry "30s or the configured interval, whichever is sooner", `ev.sys.drain` cancels work) | CODE: `components/models/main.go:217` (1 h default), `:238-247` (retry delay = 30 s, or the interval when shorter — exactly the claim), `catalog.go:110-115` (`api.json`, `cacheTTL` 5 m), `:780` (`<cacheDir>/sources/<component>--<tool>.json` = `var/models/sources/`) ✔ | FIX: none.
- MANUAL: lines 1602-1606 "the `llm` component registers an `x-models-source` plugin (**priority 150**) … (probed in the background after chats, **10-minute TTL**)" | CODE: `components/llm/main.go:1114,1121` (`llm_models_source`, `priority: 150`), `components/llm/models_source.go:33-35,114-117` (`liveProbeTTL = 10 * time.Minute`, probe out of band) ✔ | FIX: none.
- MANUAL: lines 1566-1596 tools table (6 tools, all onDemand per `mechanisms.md`) | CODE: `components/models/main.go:93,113,136,163,183,204` ✔ | FIX: none.
- MANUAL: lines 1577-1580 "`models_list {status: \"active\"}` also matches models whose status field is absent … List results are trimmed when they would exceed the bus payload limit … Descriptor metadata is recursively redacted: secret-like keys … never reach a caller, at provider or model level." | CODE: `components/models/catalog.go:886-911` (recursive `redactMetadata`), `:1005,1072` (applied at provider and model level); trimming is `maxResultBytes` under the NATS payload limit (`components/models/main.go:28-33`) and an oversized single descriptor errors with "model descriptor exceeds the result size limit" (`:158`) ✔ | FIX: none.

## §System prompt (1682–1741)

- MANUAL: lines 1697-1712 (frozen per conversation in header `systemPrompt`, fallback "component absent, slow (500 ms probe, then an 8 s budget when the catalog says it is registered)", "Cap. Answers are truncated at 200 KB (both sides)", agent pre-fetch) | CODE: `core/conversation.nim:67` (`systemPromptTimeoutMs = 8_000`), `:78-97` (500 ms probe then the full budget only if registered, truncation at 200 000 bytes), `:2394-2401` (header/args), `components/systemprompt/main.nim:29` (`maxPromptLen = 200_000`) ✔ | FIX: none.
- MANUAL: lines 1713-1727 ("`baseprompt.txt` … `${ROOT}`-substituted, baked into the binary at compile time via `staticRead`. Editing it is rebuild + respawn") | CODE: `components/systemprompt/main.nim:36` (`staticRead("baseprompt.txt")`) ✔ | FIX: none.
- MANUAL: lines 1727-1740 (context files: `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`, ancestor walk, worktree shadow rule, `<workspace>` tail only when cwd ≠ root) | CODE: `components/systemprompt/main.nim:8-17,44,114-190,248-265` ✔ | FIX: none — this is the most accurate mechanism section in the file.

## §Observation and logs (1742–1973)

Covered in depth by `mechanisms-obs.md` (boundary/"not an audit trail", `approval-sources/`, `observe_monitor` gate, hook test pointers). No new delta.

## §Fabric and subagents (1974–2106)

Covered by `mechanisms.md` (modelTier, `agent_list` descendants recursion, missing `agent_ask` row, continuation/fork invariants verified). No new delta beyond one:

- MANUAL: lines 1988-1996 driver signatures list `thinking?` | CODE: `components/agent/main.nim:977,1121` accept it and it is frozen at the child's first turn (like `model`), which the table explains for `session` continuations but not for a fresh child | FIX: one clause "(a fresh child's `thinking`/`model`/`tools`/budgets are frozen at its first turn, exactly as `session` freezes them)".

## §Expert advisory peer (2107–2138)

- MANUAL: lines 2111-2119 ("armed explicitly with `expert_follow {session_id}` (approval-gated, off by default) … only high-confidence steers naming live, non-hidden tools are delivered, through `svc.session.<id>.advise` … late advice is rejected (`stale-turn`/`no-active-turn`), never queued") | CODE: `components/expert/main.nim:799-834` (`expert_follow`, `comp.tools[^1].schema["x-harness"]` assigned after registration at `:831`), `:37` ("inert until expert_follow names a target session"), `:801,818` (`provider` parameter) — the advise rejection codes are literal in `core/dispatch.nim:1147` (`no-active-turn`) and `:1151` (`stale-turn`) | FIX: none.
- MANUAL: lines 2123-2129 tool table (4 tools incl. `expert_unfollow`, `expert_reload`, `expert_status`) | CODE: exactly four (`components/expert/main.nim:800,835,854,874`), all onDemand (`:851,871,925`) ✔ | FIX: none.
- MANUAL: line 2133 "Accepted advice is folded as a marked user message (`[Niffler advisor: expert] ...`), persisted, and announced on `ev.session.advice`" | CODE: exact — the fold inserts `"[Niffler advisor: " & source & "] " & content` as a `user` message and emits `advice` with `source`/`reason` (`core/conversation.nim:993-1004`; `source` defaults to `"advisor"`, the component sends `"expert"`) | FIX: none.

## §Recovery — `--recover` (2139–2168)

- MANUAL: lines 2148-2156 "`--recover` does three things, in order: rebuilds the shipped binaries from source (`make build`, falling back to `nimble all`) … wipes the store's component records … boots the requested profile … **Conversations and messages survive**" | CODE: `core/niffler.nim:245-265` (`rebuildShipped` tries `make build` then `nimble all`, 600 s wait), `:432-433`, `:584-592` (wipe with a warning on failure); `Makefile:557-560` (`recover: build` then `./var/bin/niffler --recover`) ✔ | FIX: none.
- MANUAL: line 2150 "If the agent (or a bug) breaks a shipped component — overwrote a binary in `var/bin`…" + the `git restore components/ core/ sdk/` recipe | CODE: consistent with `scripts/with-build-lock.sh` and the Makefile build targets; note `make clean` is the sanctioned artifact remover (AGENTS.md) and `git restore` does not touch `var/` | FIX: add "(never `rm -rf var` — use `make clean`; a stale `var/store.db.lock` or `var/barrel-db.lock` is what makes a fresh store refuse to start, see `make down`)" — the flock symptom is the one operators hit and it is currently in AGENTS.md only.

## §The store (2169–2195)

- MANUAL: lines 2172-2190 kind table, labelled "**Kinds in use by core**" | CODE: omits `profile` (`core/dispatch.nim:394-402`), `approval`, `contextreceipt`, `compaction_input`, `context_projection`, `spill`, plus the component kinds `mcp` and the throwaway `selftest` | FIX: apply the table in `mechanisms-obs.md` ("Kind / event inventory"). `[dup]` mechanisms.md + mechanisms-obs.md.
- MANUAL: lines 2171-2185 "`put` / `get` / `list` / `del` and rev-based optimistic concurrency (`put` accepts `expectRev` and fails with `rev-conflict` on mismatch)" | CODE: `components/store/main.nim:171-178` (`del` hidden); the kind-restriction rule ("a session-bound caller may only write `fabricprog`; everything else is `forbidden-kind`, `'<kind>' is harness-managed`" at `:100-105`) is missing from MANUAL | FIX: state both — it is the rule that explains why a model cannot corrupt the store. `[dup]` mechanisms-obs.md.
- MANUAL: line 2200 "Backend is the selected engine — SQLite at `var/store.db` by default, or BitBarrel at `var/barrel-db` with `NIF_STORE_BACKEND=barrel`. **Exactly one process owns that file**" | CODE: accurate (tidb is deliberately absent from this sentence but the section should name it for symmetry) ✔ | FIX: add "or the DSN-shared TiDB engine (`NIF_STORE_TIDB_DSN`, no flock)".

## §Testing (2196–2231)

- MANUAL: lines 2202-2209 "`make test-bash # … or just one: test-store, test-builder, … test-smoke`" | CODE: `Makefile:431-434` (`TEST_BINS := tests/smoke.nim $(wildcard tests/t_*.nim)`) and ~25 named targets | FIX: replace the hand-list with "`make help` lists every target; the full bus suite is `make test-server`". `[dup]` mechanisms.md / mechanisms-sessions.md.
- MANUAL: line 2216 "drives them over a private NATS server whose loopback ports are allocated by NATS" | CODE: accurate — `tests/helpers.nim:36-91` starts a test-owned `nats-server` with `--ports_file_dir` in a temp dir and reads the client/monitoring ports back from the `*.ports` files, preferring the in-repo `var/bin/nats-server` (`:45-51`) | FIX: none; consider adding "(the test reads the port back from nats-server's ports file)" for someone debugging a stuck test.
- MANUAL: lines 2221-2230 network opt-ins (`NIF_TEST_INSTALL=1`, `NIF_TEST_NETWORK=1`) | CODE: `tests/` honors both names (`grep -rl NIF_TEST_*`) ✔ | FIX: none.

## §Starting and stopping (2232–2260)

Covered by `mechanisms-sessions.md` (probe order, `NIF_NATS_SPAWN`, PDEATHSIG, client counting vs registry leases, the TUI's missing root check). No new delta.

## §Common tasks (2261–2310)

- MANUAL: lines 2263-2285 the command list (`make install`, `install-tui`/`WITH_TUI=1`, `install-ui`, `install-lsp`, `test*`, `doctor`, `ram`, `down-here`, `clean`) | CODE: all present (`Makefile:335,360,363,369,371,385,406,557,565,589,645`) ✔ | FIX: none.
- MANUAL: lines 2289-2309 (`make ram` — PSS not RSS, membership by executable path, workload children of `bash` excluded) | CODE: `Makefile:385` → `scripts/niffler-ram.sh`; the rationale (tui is the parent of an autostarted harness) matches `ui`/plugin lifecycle | FIX: none (script internals not re-read here).
- MANUAL: line 2292-2294 "**Headless service mode** … `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` — serves `svc.core.call`; approval-requiring tools are denied unless a UI is attached or `NIF_AUTO_APPROVE=1`" | CODE: `core/niffler.nim:659` (tty + not autostart ⇒ admin shell), `core/approval.nim:271-296` (auto-approve bypass, tty fallback only when `clientCount()==0`) ✔ | FIX: none.

## §Troubleshooting (2311–2324)

- MANUAL: line 2316 "`core: WARNING missing binary for <name>` on boot | run `make build`" | CODE: `core/niffler.nim` emits the warning on the manifest restore path; combined with `core/conversation.nim:2869-2872` ("session runner binary missing: … run `make build`") there are **two** distinct missing-binary messages | FIX: list both, since the session-runner one is the one users actually hit (it breaks every conversation, not the boot).
- MANUAL: line 2320 orphaned `nats-server` row | CODE: wrong cause on Linux — PDEATHSIG reaps the bus (`components/nats/main.go:15-18`, `sdk/go/pdeathsig_linux.go:17`) | FIX: apply the `mechanisms-sessions.md` wording. `[dup]`.
- MANUAL: line 2322 "component crashes on boot, restarts in a backoff loop | `core.remove` it" | CODE: only `on-failure` components loop; `never` components stay down (`core/supervisor.nim:14-16,200-212`) | FIX: apply the `mechanisms-sessions.md` scoping. `[dup]`.
- MANUAL: line 2323 "agent-modified sources | `git restore components/ core/ sdk/` then `make build`" | CODE: consistent with Recovery ✔, but the same caveat as Recovery applies (a modified `manifest.yaml` or `Makefile` is not restored by that command) | FIX: extend to `git restore components/ core/ sdk/ manifest.yaml Makefile` (or `git checkout -- .` as the Recovery section already says).

---


## (X) Claims that are simply wrong

1. **MANUAL 370-372** — "Loading rules (**identical** in the Nim SDK, Go SDK and the UI bridge): … `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order." The UI bridge passes them the other way round (`ui/bridge.go:71`), so in the desktop app the harness-root `.env` beats a `.env` in the cwd, while components do the opposite (`sdk/niffler/sdk.nim:771`, `sdk/go/component.go:414`).
2. **MANUAL ~185** — "All engines enforce single-writer the same way: one process owns the file (flock…)" contradicts the tidb bullet 40 lines above it ("No flock — the cluster is shared state by design"); tidb has no file and no flock (`components/store-tidb/main.go:15-21,292`).
3. **MANUAL 254** — the repomap/lsp/**skills** marker sentence: `skills` walks no build files (`components/skills/main.nim:200-215`), and the marker sets are language-specific (`components/lsp/roots.nim:29-34`) plus `Cargo.toml` (`components/repomap/main.nim:134`) — not the four files named.
4. **MANUAL 1116-1122** — "≤100 servers per harness" is not enforced anywhere in `components/mcp` (the manager lists up to 1000 records, `components/mcp/main.go:170`).
5. **MANUAL 511-514** — "wall-clock seconds (checked before every tool dispatch, not only between rounds)" reads as applying to all three soft limits; only seconds is (`core/conversation.nim:2190-2196` vs the round-boundary checks at `:1817,1823`).
6. **MANUAL 239 and 895** — "a config change is `core.kill` + `core.spawn`" is incomplete: children inherit core's environment (`core/supervisor.nim:117-124`), so a variable exported only in the shell that launched core survives a kill+spawn unchanged.
7. **MANUAL 2323** — the agent-modified-sources recipe (`git restore components/ core/ sdk/`) does not cover `manifest.yaml`/`Makefile`, the two files whose edits most often break a boot; the Recovery section's own `git checkout -- .` is the honest form.
8. **MANUAL 570** (inherited) — `cacheHitTokens`/`cacheHitRatio` do not exist; the event nests `cache {prompt, read, hitRate}` (`core/conversation.nim:2103-2106`). Also `components/hooks/README.md:35`.
9. Content-level drift found by the companions and confirmed here: the approval-gated tool list (MANUAL 457-467, ten names missing), `/limit`'s 5-minute claim (obs report), the orphaned-`nats-server` cause (sessions report), and the web UI's delete path that bypasses `conversation_delete` (sessions report). They are listed in (X) terms there; do not re-litigate here.

## (Y) Capabilities missing from MANUAL

1. **`x-harness.runner`** — the fifth schema extension core honours, and it is undocumented in MANUAL *and* in AGENTS.md's extension list: a `hidden` tool with `runner: true` is exempt from a session's frozen tool allowlist (`core/dispatch.nim:1455-1473`).
2. **`var/toolout/`** — where `bash` spills long captures (1 h TTL, per session; `components/bash/main.nim:27-34`); every spill path the model sees points there and no state table mentions it.
3. **The other `var/` roots**: `mcp-results/`, `approval-sources/`, `review-receipts/`, `fabric-cache/`, `plugins/`, `nats-monitor-url`, `models/sources/`.
4. **`.env` hardening**: 1 MiB cap, symlink/hardlink refusal, no variable expansion (`sdk/dotenv.nim:1-27,40-52`) — security-relevant and currently invisible.
5. **Build/script-only knobs**: `NIF_BIN_DIR`, `NIF_LSP_BIN`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` — a reader cannot tell them from the runtime set.
6. **Two source trees that are not bus citizens**: `components/nats` (the `var/bin/nats-server` core spawns) and `components/ctxtest` (test fixture).
7. **Provider OAuth flow lifetime** (15 min, `components/provider/oauth.go:29`) and the fact that all three `provider_oauth_*` tools are `hidden` with their own timeouts (`oauth.go:145,169,185`).
8. **`WARM_MAX_SERVERS = 2`** (`components/lsp/main.nim:743`) — the reason a warmup looks partial.
9. **The session tool-allowlist cap of 32 names** (`core/conversation.nim:2429`).
10. From the companions, still missing and worth a MANUAL section rather than a line: the provider/**models/effort** mechanism (five effort states, no `none`, `reasoning_effort` sent only when set — `core/conversation.nim:2646`, `components/llm/main.go:436-441`), the **DeepSeek** specifics (`max_tokens` only, `finish_reason: aborted|insufficient_system_resource|length`, the stale `knownContext` ids — `components/llm/main.go:721-786`, `docs/research/DEEPSEEK.md` §1/§3/§4), the `agent_ask`/`agent_notices`/`agent_list` rows, and `fabric_help`.
11. **Schema drift to fix in code, then document**: the `session` tool schema omits `discovery`/`tools`/`maxRounds`/`maxCalls`/`maxTokens` (`core/catalog.nim:184-196` vs `core/conversation.nim:2341,2427-2457`), declares `"enum": ["low","medium","high"]` for `thinking` while accepting `max` (`core/catalog.nim:198-200`), and the mismatch error text says "low, medium or high" (`core/conversation.nim:2647`).

## (Z) Sections to trim to a pointer

| MANUAL lines | Section | Owned by |
|---|---|---|
| 146–229 | Store engines + Migrating between engines (incl. the migrate CLI walkthrough and the `niffler-store-migrate` banner) | `docs/research/STORE_V2.md`; keep the 3-row engine table, "switching does not migrate" and the refusal message |
| 377–454 | The bus in one screen (subject + `ev.*` inventory) | `docs/WIRE.md` (normative); keep a 6-line subject overview |
| 822–883 | Provider "Wire protocols" + Subscription OAuth design (Pi/opencode parity, header lists, callback ports) | the component's own docstrings + `docs/WIRE.md`; keep the 13-row tool table and the credential rules |
| 960–1032 | LSP "How the model uses it" / "How the user adds a language" routes | `components/lsp` docstring + `~/git/niffler-tui/README.md`; keep the registry JSON shape (it is a data contract) |
| 1536–1668 | Model catalog merge order + source-plugin protocol + the worked Nim example | `components/models` + the `x-models-source` schema; keep the tools table and 5-line precedence |
| 1852–1934 | SDK APIs + `onIdle` | `docs/WIRE.md`, AGENTS.md; keep the three-SDK table |
| 1742–1973 | Observation caps and per-tool payload shapes | the env table (single numeric source) + `components/observe`, `components/logfile`, `components/hooks/README.md`; keep the boundary paragraph and the "not an audit trail" list |
| 1988–2010 | Fabric/agent argument tables (they repeat the tool schemas) | the registered schemas; keep the continuation/fork invariants, which are the actual mechanism |
| 2202–2214 | The hand-written test-target list | `make help` |

## Proposed top-level outline for MANUAL as a reference manual

**Part I — Configuration**
1. Layout of a running system (paths, `var/` map, shipped-component inventory with flags).
2. State and configuration: where everything lives (the five lifetime buckets + precedence).
3. Environment variables (runtime table, `.env` contract, build/script knobs).
4. Starting and stopping (autostart, home bus, service/admin modes) + Clients & the UI registry.
5. Recovery, `make` targets and Common tasks.
6. Troubleshooting (symptom → mechanism → fix, one row per real failure mode).

**Part II — Mechanisms**
7. Turns and sessions (runner lifecycle, controls `/approvals` `/limit`, budgets, `busy`, cancellation).
8. Context window: admission ladder, calibration, compaction/recall, prompt-cache discipline.
9. Tools and exposure: catalog vs frozen direct set, `discover`/`invoke`, profiles, hidden/onDemand/runner/approval/sessionId flags, `effect`.
10. Models, providers and effort (selection, `llm_resolve` provenance, provider registry, OAuth, effort states, DeepSeek lane).
11. System prompt assembly (component seam, context files, workspace tail).
12. Subagents, fabric and the expert peer (spawn/run/continuation/fork, depth, settlement notices).
13. Storage: the bus contract, engines, kinds, write rules, paging, migration.
14. Self-extension: `spawn`/`kill`/`remove`, restart policies, plugins/skills/MCP as capability sources.
15. Observability: `ev.*` + observe/logfile/hooks/console, and what is deliberately *not* an audit trail.
16. Appendices: A. Test suite and verification; B. Schema extensions reference; C. Env-var index; D. Pointer index (WIRE/ARCHITECTURE/FABRIC_GUIDE/research).

## Could not determine (state plainly, do not assert)

- Whether the MANUAL's `NIF_OBSERVE_*`/`NIF_LOGFILE_*` numbers and the observe/logfile behaviours are current is the obs report's scope; I only re-read the fetch/LSP/processes/MCP/provider numbers in my sections.
- The internals of `scripts/niffler-ram.sh` (MANUAL 2296-2309 describes PSS vs RSS and membership rules) were not read — the Makefile target exists (`Makefile:385`), the rationale is plausible but unverified here.
- SQLite/barrel/TiDB engine *rationale* bullets (MANUAL 158-181) were checked only for their headline claims (goose, `modernc.org/sqlite`, WAL, single upsert, MEDIUMTEXT, `FOR UPDATE`); per-claim performance/correctness assertions were not independently tested (no builds/tests allowed for this task).
- Whether `"expose": "direct"` MCP servers actually enter a *new* conversation's snapshot end-to-end (MANUAL 1146-1150) — the flag and the threshold are in the code (`components/mcp/main.go:90`, `mcp-bridge/operations.go:322`), the core-side projection was not traced in this pass.
- `make ram` membership by executable path and the "workload children of bash are excluded" claim.
- `NIF_MCP_REGISTRY_URL` behaviour against the real registry (the tests use a mock; `tests/fixtures/mock_registry.nim`).
- The exact `session_info` field list MANUAL promises (header fields, per-role counts, cumulative completion tokens) — the schema text matches, the emitted shape was not traced.
- Any claim that depends on the plugin `niffler-tui` version in `var/plugins/` (line numbers there are the repo clone `~/git/niffler-tui`).

## Coverage summary

Findings: **104 bullets in MANUAL order** — 54 verified-correct (`FIX: none`, listed so they are not re-audited), 50 requiring a change (update/add/remove/trim), 21 of them marked `[dup]` because a companion report (`mechanisms.md`, `mechanisms-sessions.md`, `mechanisms-obs.md`) already found the same defect and this file only adds the cross-cutting framing. Plus 5 (X) verdicts, 11 (Y) gaps and 9 (Z) pointer recommendations. Verified-correct and therefore *not* to be re-audited: the env-var table's 87 names, minimal boot profile, store `list` paging semantics behind the paragraph, LSP tool set/caps/built-ins/`warmup`, processes caps and exit-notice lane, MCP record + result caps + double approval, the 7-tool direct set, discovery hint/schema caps and `notFound`, model-catalog merge order and tools, system-prompt assembly (frozen/fallback/cap/context files/workspace tail), expert's four tools and advise codes, `--recover`'s three steps, and the Common-tasks command list.
