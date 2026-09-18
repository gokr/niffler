# MANUAL.md CONFIGURATION audit — delta list

Scope: every *production* `NIF_*` env var read in `core/`, `components/`, `sdk/`,
`ui/`, `scripts/`, vs `docs/MANUAL.md` (2324 lines; env table = lines 266-351,
84 rows) and `.env.example`. Read-only audit; no builds/tests run in this pass.

Method: read sites enumerated with `rg '"NIF_[A-Z0-9_]+"'` + `getEnv(`/`os.Getenv(`
over core/, components/, sdk/, ui/, scripts/; name-hiding helpers followed
(`configInt` observe/logfile, `intEnv` repomap, `envDuration`/`envBool` models,
`envNonNegative` core/retry.nim). Every claim below cites a file:line I actually
read.

Row form: `- MANUAL: <line/quote> | CODE: <file:line, default, meaning> | FIX: …`

## A. Documented but stale / wrong

- MANUAL:340 `NIF_MCP_PROBE_TIMEOUT_MS` "…(overrides the 30s default and the call's own `timeoutMs` when higher)" | CODE: components/mcp/main.go:463-474 — `timeout := 30s`; `cfg.TimeoutMs` used only `if > 30_000`; the env value is then assigned **unconditionally last** (`if raw := os.Getenv("NIF_MCP_PROBE_TIMEOUT_MS"); ms > 0 { timeout = ms }`), so a *lower* env value wins too (mcp-bridge probes: components/mcp-bridge/main.go:437) | FIX: drop "when higher" → "(overrides both the 30 s default and the server's configured `timeoutMs`)"
- MANUAL:187 "All engines enforce single-writer the same way: one process owns the file (flock; kernel-released on crash), everyone else speaks envelopes." | CODE: components/store-tidb/main.go:99-142 — no `flock` in the tidb engine at all (MANUAL's own bullet at :181-183 says so, so the section contradicts itself); file-backed locks are components/store-sqlite/main.go:133 `acquireLock(dbPath + ".lock")` → `var/store.db.lock` and components/store/main.nim:48-50 `lockPath = path & ".lock"` → `var/barrel-db.lock` | FIX: "File-backed engines (sqlite, barrel) enforce single-writer with a flock beside the data file (`var/store.db.lock`, `var/barrel-db.lock`); the `tidb` engine takes no lock — the cluster's row locks arbitrate."
- MANUAL:330 `NIF_AUTO_APPROVE` "→ the approval gate (below) is bypassed" | CODE: core/approval.nim:263 `proc askContinue` returns true when `NIF_AUTO_APPROVE == "1"` **or** `NIF_AUTO_CONTINUE == "1"` — so AUTO_APPROVE also answers every `/limit` keep-going question with yes, which MANUAL:515-516 attributes to AUTO_CONTINUE alone (auto-approve in `proc ask` is :272) | FIX: append to the AUTO_APPROVE row: "also answers every `/limit` keep-going question with yes (implies `NIF_AUTO_CONTINUE`)"; and in the `/limit` prose: "`NIF_AUTO_CONTINUE=1` (or `NIF_AUTO_APPROVE=1`) answers …"
- MANUAL:367-369 "Loading rules (identical in the Nim SDK, Go SDK and the UI bridge): existing shell environment **always wins** over `.env`; `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order." | CODE: the order is *reversed* in the UI bridge — ui/bridge.go:71 `sdk.LoadDotEnv(filepath.Join(harnessRoot(), ".env"), ".env")` (root first, cwd second); since the first-loaded value wins (sdk/go/dotenv.go:24 `if os.Getenv(key) == ""`, sdk/dotenv.nim `if … not existsEnv(key)`, sdk/ts/src/dotenv.ts:36 `=== undefined`), the **harness-root `.env` wins in the UI** while the **launch-directory `.env` wins in the SDKs** | FIX: state the winner explicitly and split the UI out: "the first file that defines a key wins, so a launch-directory `.env` beats the root one — except in the UI bridge, which loads the root first (ui/bridge.go)".
- MANUAL:240 (state table, Environment/.env row) "components read env once at boot; a config change is `core.kill` + `core.spawn`" (repeated MANUAL:336 and MANUAL:879) | CODE: the supervisor passes **no env** to children — core/supervisor.nim:118-120 comment + :160 `startProcess("/bin/sh", workingDir = sup.root, …)` inherits core's environment, so a variable **exported in core's shell env** cannot be changed by kill+spawn at any level; children do re-read `.env` itself at their own boot (sdk/niffler/sdk.nim:771, sdk/go/component.go:414, sdk/ts/src/component.ts:242, core/session.nim:37) | FIX: "`.env` edits apply when the component is respawned (`core.kill` + `core.spawn`); a change to a variable *exported in the shell environment* requires restarting the harness — children inherit core's environment and shell env beats `.env`."
- MANUAL:296 `NIF_SKILLS_BUNDLED_DIR` default "`<repo>/skills`" is right but the *resolution source* is the build checkout, not `NIF_ROOT` | CODE: components/skills/main.nim:185-198 — no override → `currentSourcePath().parentDir.parentDir.parentDir / "skills"` (compile-time source path), falling back to `root / "skills"` only when the repo tree is absent | FIX: "(compiled-in source path of the component; `$NIF_ROOT/skills` only as fallback)".

## B. In the code but undocumented

- `NIF_LLM_PROVIDERS` entries accept four more keys than MANUAL:286 lists | CODE: components/llm/main.go:63-73 — the provider struct also unmarshals `protocol` (`openai-chat`/`openai-codex`/`anthropic`, :55-58), `authType`, `accountId`, `stripPrefix`; the same fields exist on stored provider records (components/provider/main.go:59-71) | FIX: extend the row's shape to `{baseUrl, apiKey, model, context, catalog, protocol?, authType?, accountId?, stripPrefix?}`.
- `NIF_REPO_ROOT` | CODE: components/ctxtest/main.nim:508,589,607 (`readFile(getEnv("NIF_REPO_ROOT") / …)`, no default → empty-string path when unset). ctxtest is **not** in manifest.yaml (manifest lists store, bash, builder, plugins, skills, systemprompt, recall, compaction, fetch, models, provider, llm, grep, mcp, edit, lsp, repomap, processes, git, observe, logfile, hooks, agent, expert, fabric), so it is a repo-local test component | FIX: add to MANUAL "Testing" next to `NIF_TEST_INSTALL`/`NIF_TEST_NETWORK`, or leave only in `.env.example` as it already is — but then say so.
- Build/install script variables | CODE: scripts/with-build-lock.sh:8,22 `NIF_BUILD_LOCK` (lock file path, default `.niffler-build.lock`), scripts/install.sh:43 `NIF_BIN_DIR` (install target dir), scripts/install-lsp.sh:22 `NIF_LSP_BIN` (default `$HOME/.local/bin`) | FIX: one "build/install script variables" line in Common tasks (`make install NIF_BIN_DIR=…` appears in AGENTS.md but not MANUAL).
- Store lock files absent from both `var/` inventories | CODE: `var/store.db.lock` (components/store-sqlite/main.go:133) and `var/barrel-db.lock` (components/store/main.nim:48). MANUAL:46-49 (layout table) and MANUAL:244 (state table) list `store.db` only; MANUAL:2303 (troubleshooting "two stores fight over the same data file") does not name the flock an operator must find | FIX: add `var/store.db.lock` / `var/barrel-db.lock` to the state table and the troubleshooting row.
- An **empty but exported** `NIF_NATS_URL` counts as unset | CODE: core/niffler.nim:323-324 `existsEnv("NIF_NATS_URL") and getEnv(...).len > 0`; scripts/install.sh:154 relies on `NIF_NATS_URL= NIF_NATS_SPAWN=1`. MANUAL:269 explains env-vs-.env but not the empty-value rule | FIX: add "(an empty `NIF_NATS_URL=` counts as unset)".
- `var/approval-sources/` is written (core/approval.nim:90, referenced at MANUAL:2086) but is missing from the state table's `var/` row (MANUAL:244) — same for `var/plugins/` (MANUAL:685) and `var/mcp-results/` (MANUAL:1135) | FIX: either complete the state row or point at the sections that own them.

## C. Documented but not in the code

**No rows.** All 84 rows of the env table (MANUAL:268-351) resolved to a read
site in production code, including the ones most likely to have rotted:
`NIF_MODELS_OFFLINE` (components/models/catalog.go:114), `NIF_OBSERVE_CAPTURE_BYTES`
(components/observe/main.nim:79), `NIF_LOGFILE_DIRECTORY_ENTRIES`
(components/logfile/main.nim:44), `NIF_MCP_DIRECT_THRESHOLD`
(components/mcp-bridge/operations.go:322), `NIF_REPOMAP_MIN_CENSUS`
(components/repomap/main.nim:178), `NIF_RUNNER_IDLE_S` (core/session.nim:156),
`NIF_STORE_TIDB_DSN` (components/store-tidb/main.go:71,99-104), `NIF_OAUTH_CALLBACK_HOST`
(components/provider/oauth.go:52-55). Documented **defaults** were spot-checked
against the constants and all matched (see "Verified correct" below), so there
are no stale-default rows either.

## D. Mechanism descriptions wrong or missing

- Home-bus claim/yield is described unconditionally (MANUAL:269-270) | CODE: core/niffler.nim:337-389 — the claim/probe/yield branch runs only when `not natsUrlFromEnv and isLoopbackNatsUrl(natsUrl)` (:345-346, `isLoopbackNatsUrl` at :204); a **non-loopback** `.env` `NIF_NATS_URL` (e.g. a gateway host) falls to the final `else`: core attaches to exactly that bus with no root-identity probe, so a remote `.env` URL can silently attach to a foreign harness | FIX: "(a non-loopback `.env` URL is attached to as given — no claim, no root check)".
- "The default store engine is sqlite" is stated without the silent fallback | CODE: core/niffler.nim:485-503 — when `NIF_STORE_BACKEND` is **unset** and `var/bin/store-sqlite` is missing, core warns and uses the manifest binary (`var/bin/store` = barrel) at :499-503, i.e. `var/barrel-db` may be the live database with no user opt-in; an *explicit* `NIF_STORE_BACKEND` never falls back (missing binary → `WARNING missing binary …`) | FIX: add to MANUAL:271/§Store engines.
- "`.env` is loaded from the current directory and from `$NIF_ROOT`" (MANUAL:262, :367-369) reads as if the two could differ for every process | CODE: supervised children run with cwd = NIF_ROOT (core/supervisor.nim:160 `workingDir = sup.root`), so both paths are the same file for components; the distinction only matters for core (core/niffler.nim:326), session runners (core/session.nim:37) and user-launched clients (components/cli/main.nim:244, components/console/main.nim:101, ui/bridge.go:71) | FIX: one clause — "for supervised children cwd == `NIF_ROOT`, so both paths are the same file; it matters for core, runners and hand-launched clients".
- Bus max-payload is documented (MANUAL:1930-1932) but not the boot-time **warning** core emits when an attached bus is below the harness payload size | CODE: core/niffler.nim:406-411 `natsConnection_GetMaxPayload` vs `natsMaxPayload`, message "bus at … caps messages at … bytes" | FIX: mention it in Troubleshooting ("long reply hangs → check this warning").
- `NIF_STORE_BACKEND` lock rules are only *implied* (MANUAL:2174-2177 "Exactly one process owns that file"): sqlite/barrel hold a flock for the process lifetime (components/store-sqlite/main.go:133, components/store/main.nim:48) while tidb's single-writer is `SetMaxOpenConns(1)` + `FOR UPDATE` (components/store-tidb/main.go:135-138) — the network engine has no file to own | FIX: state that no lock file exists for `tidb`; nothing to look for in `var/`.

## E. `.env.example` deltas

- Header promise "each line shows the built-in default as the commented value, so an uncommented line with the same value changes nothing" is false for six opt-in flags, where the commented value is the *enabled* state: `NIF_NATS_SPAWN=1`, `NIF_AUTOSTART=1`, `NIF_MODELS_OFFLINE=1`, `NIF_AUTO_APPROVE=1`, `NIF_REPOMAP_AUTOAPPEND=1`, `NIF_FETCH_ALLOW_PRIVATE=1` (same for the whole "Test & bench only" block, which is at least labelled) | CODE: defaults are unset/off (core/niffler.nim:343, :641; components/models/catalog.go:114; components/fetch/main.nim:177; components/repomap/main.nim:287) | FIX: prefix those lines "opt-in, not the default:" or write `#NIF_MODELS_OFFLINE=` with a separate example.
- Missing variables vs the MANUAL table: `NIF_AUTO_CONTINUE` (MANUAL:331) and the four `NIF_REPOMAP_MIN_*` gates (MANUAL:343-346; components/repomap/main.nim:178,184-186) — the file claims to be "a reference copy of every NIF_* variable" | FIX: add those five blocks.
- Stale example: "Non-`NIF_` vars (`DISCORD_TOKEN`, `SYNTHETIC_API_KEY`, ...) are read only by the specific components that document them" | CODE: `DISCORD_TOKEN` appears nowhere in the repo; `SYNTHETIC_API_KEY` only in bench/Makefile:535, bench/config.json and bench/run.mjs | FIX: drop `DISCORD_TOKEN`, keep `SYNTHETIC_API_KEY`.
- "Loading rules (identical in the Nim, Go and TypeScript SDKs)" | CODE: they differ on an empty-but-set variable — sdk/go/dotenv.go:24 treats `os.Getenv(key) == ""` as unset (so `.env` fills it), sdk/dotenv.nim uses `not existsEnv(key)` and sdk/ts/src/dotenv.ts:36 `=== undefined` (so `.env` does not) | FIX: "the Go SDK also treats an empty variable as unset"; add the cwd-vs-root winner sentence here too (see A).
- The `.env` precedence paragraph in `.env.example` does not say which of cwd / `$NIF_ROOT` wins, and neither does MANUAL:373-375 for the file itself | FIX: "the launch-directory `.env` wins when both define a key".

## Where MANUAL should be trimmed or restructured

- **The bus in one screen** (MANUAL:377-454) restates docs/WIRE.md subject-by-subject → keep the subject list as a pointer table, move the envelope/protocol prose out.
- **Store engines + Migrating between engines** (146-229) duplicate docs/research/STORE_V2.md and COMPACTION.md §2 (history, why sqlite, migration mechanics). Keep only: the three values, the DSN, the lock/flock rule, and a one-line pointer.
- **Context window** (524-637) and the compaction subsections duplicate docs/research/COMPACTION.md; the manual needs the `NIF_CTX_RESERVE` / `NIF_COMPACTION_*` rows and a pointer.
- **Fabric and subagents / continuation / fork** (1957-2089) is docs/WIRE.md's contract plus docs/research/FABRIC.md + FABRIC_GUIDE.md; keep the config rows (`NIF_AGENT_*`, `NIF_AGENT_MAX_DEPTH`) and point.
- **Observation and logs** (1725-1956) carries implementation detail (rotation boundary rules, `rawBase64`, byte budgets, quota arithmetic) that belongs in components/logfile + docs/research; keep the knob table.
- **Progressive tool discovery / Shipped policy** (1246-1500) duplicates the prompt-cache invariants already in AGENTS.md and WIRE.md; keep the policy table.
- **Layout of a running system** (31-49) + **Shipped components** (50-81) duplicate manifest.yaml and AGENTS.md; a pointer suffices.
- **Testing** (2179-2214) repeats the Makefile targets from AGENTS.md/Makefile — keep the two network opt-ins.
- Structurally: the env table is the manual's most valuable section and should stay canonical; the ~90 rows in `.env.example` are a second copy that drifts (see E). Pick one as the source of truth (suggest `.env.example` holds defaults, MANUAL holds behaviour) and sync the other.

## Could not determine

- Whether *any* code path re-reads `.env` between core boot and a child spawn other than the child's own `loadDotEnv` (I read core/niffler.nim, core/session.nim, core/supervisor.nim and the three SDK `run`/`Connect` entry points; no other loader found).
- The exact interaction of `NIF_MCP_PROBE_TIMEOUT_MS` with a per-call `x-harness.timeoutMs` for `mcp_add` (MANUAL:340's "the call's own timeoutMs"): I verified the server-config `TimeoutMs` path only.
- MANUAL:36 lists `dialog` as a component source; components/dialog/dialog.sh exists and is built by niffler.nimble:46 + Makefile:285 but is not in manifest.yaml — whether it counts as "shipped" is a docs-intent question, not verifiable from code.
- `.env.example`'s test-only block was verified by sampling (`NIF_STORE_BIN`, `NIF_SMOKE_CTX`, `NIF_CONF_KEEP`, `NIF_MOCK_*`, `NIF_FIXTURE_*`, `NIF_SWEBENCH_*`, `NIF_DEEPSWE_*` all exist in tests/ or bench/), not exhaustively — a full sweep of that block would need tests/ reading, out of scope here.
- Component-local clamps (e.g. `NIF_LOGFILE_MAX_BYTES` clamped to 104857600, components/logfile/main.nim:37-42; `NIF_HOOKS_TIMEOUT_MS` clamp 100–60000, components/hooks/main.nim:94) are documented only for hooks ("max 60000"); I did not audit every clamp for a MANUAL sentence to update.

## Verified correct (checked, no delta)

- `.env` precedence "shell env always wins" — sdk/dotenv.nim (`not existsEnv`), sdk/go/dotenv.go:24, sdk/ts/src/dotenv.ts:36; core loads it before bus resolution (core/niffler.nim:326).
- `provider` store records vs env fallback: MANUAL:249, :801, :852-856 match components/llm/main.go:263-281 (explicit arg → stored nickname, then `NIF_LLM_PROVIDERS`; default → active stored provider, else `NIF_OPENAI_*`) and components/provider/main.go:119-134.
- `NIF_STORE_BACKEND` values/refusal: core/niffler.nim:451 (guard), :485-492 (`quit` on unknown value) vs MANUAL:152-153.
- `NIF_STORE_TIDB_DSN`: components/store-tidb/main.go:99-128 ("no local default", UTC forced unless the DSN sets `time_zone`) vs MANUAL:275.
- Bus resolution `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222 and the `NIF_AUTOSTART`/idle/grace lifecycle: sdk/niffler/sdk.nim:615-652, sdk/go/harness.go:118-184, core/niffler.nim:641-688.
- Documented defaults all matched the code: `NIF_CTX_RESERVE` 16384 (core/conversation.nim:592,600), `NIF_MAX_TURN_ROUNDS` 1000 (core/conversation.nim:228-231), `NIF_MAX_DIRECT_TOKENS` 4000 (:1155), `NIF_LLM_*` retries 2/2/2 + cap 3600000 (core/retry.nim:35-38,56-61), `NIF_LLM_TIMEOUT_MS` 300000 (components/llm/main.go:1085-1091), `NIF_COMPACTION_*` 90000/4/2048 (core/compaction.nim:47-58), `NIF_MCP_DIRECT_THRESHOLD` 10, `NIF_OBSERVE_*` 2000/16777216/65536/32/2097152/67108864, `NIF_LOGFILE_*` 10485760/5/64/16777216/10000, `NIF_PROCESSES_*` 33554432/65536, `NIF_READ_OUTLINE_LINES` 1000 (components/edit/main.nim:48), `NIF_WRITE_MAX_BYTES` 900000 (:1206), `NIF_REPOMAP_MIN_*` 50/800/25/5, `NIF_MODELS_*` (models.dev URL, 5m TTL, 1h refresh, `0` disables), `NIF_ROOT` default `<binary>/../..`, `NIF_AGENT_*` tiers, `NIF_NPM_REGISTRY` (components/builder/main.nim:170-175), `NIF_GIT_MIRROR` (components/plugins/main.nim:355-360).
