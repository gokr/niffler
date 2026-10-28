# Configuration implementation checklist

Status: `feat/settings` merged to `main` (2026-10-22); checked items shipped,
unchecked items remain. Design: [CONFIG.md](CONFIG.md).
Use this checklist for progress; check items only after their acceptance tests
pass. Repository status is not a claim that installed binaries were updated.

## Agreed direction

- Store-backed, component-owned settings, runtime schemas, generic read/edit
  tools and schema-driven TUI forms; approved owner-routed mutations with CAS.
- Minimum bootstrap env, no new human-edited runtime settings files, one-time
  migrations with conflict reporting; no silent enablement on store outage.
- Explicit instance column on stored documents and a real `instances` table;
  opaque JSON values remain documents. SQLite and TiDB share the contract.
- Move the fleet instance registry into the store, not another authoritative
  JSON file. Inventory current fleet receipts and TUI routes first. Preserve
  identity pins, approved transport authority and offline/bootstrap access.
- AGENTS-only instructions; simplify skills to workspace, user, bundled.

## Delivery slices

### 0. Baseline and contract

- [x] Recover the design discussion from `deepseek-search` in the store.
- [x] Record the design and this implementation checklist.
- [x] Resolve the proposals in CONFIG.md §11 before SQL implementation:
  actual instance key/column, shared-record representation, consistent SQLite
  behavior, legacy ownership adoption and default query scope. Answered by
  building it; the answers are tabled in CONFIG.md §11 "Implementation" and
  [INSTANCE-STORE.md](INSTANCE-STORE.md).
- [x] Specify declaration discovery, owner mutation routing, supported schema
  subset, secrets/read-only handling, revision checks and application timing:
  [CONFIG-CONTRACT.md](CONFIG-CONTRACT.md) (enforced in components/config,
  `application` required with no default).
- [x] Specify instance/shared/default precedence and sunset rules for env.
  Precedence is `conversation header > store settings > env > code default`
  (CONFIG.md). Sunset follows the **authoritative-reader rule** in §5 below:
  a variable migrates only when its owner is its only reader; core-owned,
  secret, path, subscription-set and test-seam variables stay env by category.
- [x] Update WIRE and architecture notes with the reviewed contract.
  `ev.config.updated` is now in WIRE.md's event index (it was published but
  undocumented) and `config` is a row in ARCHITECTURE.md's peer table.

### 1. AGENTS-only instructions (first implementation slice)

- [x] Remove CLAUDE candidates from birth-time and lazy instruction loading.
- [x] Contract tests: CLAUDE-only directories ignored (both spellings), AGENTS
  priority and additive local files retained; frozen existing prompts retained.
- [x] Update English/localized manuals, relevant comments and changelog.
- [x] Run `make test-systemprompt test-edit` (build prerequisites included).
  Both passed; log: `.scratch/instructions-test.log` (local, not committed).

### 2. Instance-aware document storage

- [x] Add `instances` registry and document instance dimension to both engines.
  Schema-only registry migrations and preservation tests added. `make gotest`
  passed; `make test-store` and full `make test` passed (90 server tests).
  Registry API slice adds hidden validated instance_register/instance_list in
  both engines. Core boot registration added; test-core passed. Ownership-column
  migrations and owner-captured handlers added with two-owner database tests.
  Stable identity binding and adoption shipped (`store_claim`).
  **Live TiDB verified**: `go test ./...` 17/17 and `make test-store-tidb`
  pass against pingcap/tidb:v8.5.0 — which required fixing migration 3, since
  TiDB refuses `DROP PRIMARY KEY` and the engine had never booted (see below).
  See [INSTANCE-STORE.md](INSTANCE-STORE.md).
- [x] Use existing persistent instance identity; binding resolved once at open
  (NIF_INSTANCE_ID, else var/instance-id, else legacy). SQLite adopts its own
  legacy rows once and refuses a different identity; TiDB never adopts.
- [x] Scope put/get/list/del/search, revision conflicts, selftest, and FTS;
  preserve verbatim values and correct pagination within a scope.
- [x] Document `NIF_INSTANCE_ID` as a bootstrap variable (manual + .env.example).
- [x] Explicit `store_claim` admin operation for legacy rows (dry run by
  default, collision refusal, bounded resumable batches, approval-gated).
- [x] Store-layer two-instance tests: same kind/id isolation, per-instance
  revision sequence, scoped search index, delete isolation, pagination cursors,
  and binding refusing a different identity on the same file
  (`store-sqlite/scope_test.go`, `binding_test.go`, mirrored live in
  `store-tidb`).
- [ ] Harness-layer two-instance tests (no foreign restore/recover, heartbeat
  execution, grants, leases or settings) — these need two live harnesses, not
  two owners in one store.
- [x] Exercise TiDB against a real test database.
  `docker run -p 4000:4000 pingcap/tidb:v8.5.0`, then
  `NIF_STORE_TIDB_DSN='root@tcp(127.0.0.1:4000)/test' make test-store-tidb`
  (and `go test ./...` in `components/store-tidb`). Both pass as of this run.

  **It had never passed, because migration 3 could not apply on TiDB.**
  `00003_document_instances.sql` used
  `ALTER TABLE docs DROP PRIMARY KEY, ADD PRIMARY KEY(...)`; since TiDB v5.0
  every table has a clustered index, and v8.5 refuses with Error 8200
  (`Unsupported drop primary key when the table is using clustered index`).
  So the tidb engine could not boot AT ALL — every live test errored in
  `openStore`, and nothing caught it because this suite only runs when a DSN is
  set. The migration is now a table rebuild (create `docs_rebuild`, copy,
  atomic `RENAME TABLE`), written to converge on the half-applied state the old
  file left behind: `ADD COLUMN IF NOT EXISTS` first, so a database that
  already has `instance_id` keeps each row's owner instead of resetting it to
  `''`. Verified against a simulated half-applied database: PK rebuilt, an
  already-owned row kept its owner (`cccc…`), an unclaimed row stayed legacy.

  Two test bugs surfaced with it: `t_store.nim` crashed (SIGSEGV on a nil JSON
  node) reading `items` from the tidb engine's explicit
  `code: "unsupported"` vector refusal, and asserted sqlite's bm25
  ranked-paging shape on an engine that returns `ranked: false` by design
  (no index; issue #94). Both sections now branch on what the engine
  advertises and still assert its OWN contract. Also made the live TiDB tests
  re-runnable: they reuse one database, so a leftover document failed a
  first-put revision assertion on the second run.

### 3. Fleet registry in the store

- [x] Inventory fleet receipt files and TUI `instances.json`; identity registry
  (`instances` table) separated from controller routes (documents). Transport
  details stay payload fields, not SQL columns.
- [x] Store-backed fleet registry: `fleet_instances` (summaries, invalid entries
  reported) and `fleet_instance_import`; install/update record verified
  receipts. Live identity verification still gates every action.
- [ ] Import existing records once; conflict/invalid/identity-drift refusals;
  retain explicit export/import as interchange, not the authoritative registry.
- [ ] Migrate lifecycle callers to address registry instances by identity rather
  than a receipt path. Still true: `fleet_*` actions take `profile`
  (components/fleet/provision.nim `action(run, name, profile)`), deliberately,
  because the registry is not authority. TUI consumption is a separate
  repository change.
- [ ] TUI: consume registry through the bus, with minimal local bootstrap
  information for the first connection and explicit offline behavior.
- [ ] Test outage, restart, migration, route/pin mismatch and multiple scopes.
  TUI changes require its repository in the authorized working set.

### 4. Generic configuration surface

- [x] Implement schema declaration seam and shared validation helpers
  (`config_declare`; the supported subset is refused-by-name, never ignored).
- [x] Add configuration peer: config_list/get/patch/reset, owner-routed,
  approval-gated, revision-safe and redacted. Shared scope is refused until
  that decision is made (it is not silently treated as per-instance).
- [x] Test invalid patches, resets, secret redaction, stale revisions,
  unavailable owner and durable declarations. Contract:
  [CONFIG-CONTRACT.md](CONFIG-CONTRACT.md).
- [x] Subagent restrictions and per-property application timing enforcement
  (timing is reported to callers today; the owner decides what it means).
  `x-config.humanOnly` + caller classification from `sessionmeta.parent`
  (a subagent is refused, a human's conversation and a sessionless operator
  call are not, an unreadable lineage record fails closed); per-property timing
  reaches callers as `config_get.timings` and `config_patch.applies`. Contract:
  [CONFIG-CONTRACT.md](CONFIG-CONTRACT.md).
- [x] Add schema-driven TUI editor in the TUI repository; no per-owner forms.
  `/config` renders domains and fields from declarations (tui/config_command.go,
  config_editor.go), covering secret/readOnly/application. Now also surfaces
  `x-config.humanOnly` (list marker + form note; still editable by the human,
  since the restriction is on a model) and reports per-property application
  timing after a save ("saved · takes effect: component restart"), verified
  against a live harness. niffler-tui commit 29ce9d5.
  **Already built; only the new fields are missing.** `/config`
  (tui/config_command.go + config_editor.go) renders domains and fields from
  declarations with no per-owner forms, including secret/readOnly/application.
  Remaining work is small and blocked on the repo, not on design: surface
  `humanOnly` (a list marker and a form note) and honour `applies` in the
  "saved" note so a human is told a change lands next turn rather than
  immediately. Do not start while another conversation holds uncommitted
  changes there.

### 5. Owner migrations (each with its own tests and docs)

- [ ] DeepSeek web enablement/request defaults; stable schemas and paid-call gate.
  Not started. Note there is no `deepseek` component — it is a provider preset
  (`NIF_LLM_PROVIDERS` / the `provider` registry), so this is a provider-record
  schema rather than a component-owned domain. It is also precisely the field
  shape `x-config.humanOnly` was added for (a paid-call gate).
- [x] Models offline/refresh policy (`models.refresh`): `offline`,
  `cacheTtlSeconds`, `refreshIntervalSeconds`.
- [ ] ...plus a URL/path endpoint and inline override patches in that domain:
  `NIF_MODELS_URL`/`NIF_MODELS_PATH` and `NIF_MODELS_OVERRIDE` are still
  env-only, deliberately: an arbitrary URL or filesystem path is a deployment
  fact and a possible egress path, so exposing it to a model is a `humanOnly`
  decision, not a routine field.
- [x] LSP warmup policy (`lsp.warm`): `warmMax`, `warmCheap`, `warmTotal`.
- [ ] ...plus registry *data* and executable search preferences: the server
  registry is still `servers.json` (by design — it is language data, and
  `lsp_registry add` is the single-path mutation), and `NIF_LSP_BIN_DIRS` stays
  env (an executable search path is a deployment fact, same category as above).
- [x] Fetch extraction/network preferences (`fetch.network`): `allowPrivate`
  and `extractor`, with the `NIF_FETCH_ALLOW_PRIVATE`/`NIF_TRAFILATURA` env
  path retained. The test proves the stored opt-in both grants and revokes
  access without a restart.
- [x] Repomap automatic append/admission preferences (`repomap.gates`), with
  `NIF_REPOMAP_*` retained as the migration path and bench seam. The test
  changes a gate through `config_patch` and proves it applies without a restart.
- [x] Logfile retention/scan limits (`logfile.retention`). Its captured
  subject set intentionally stays a boot variable (it is a subscription, not a
  value).
- [x] Observe capture budgets (`observe.capture`): ring/probe/capture byte
  budgets. The capture directory and monitor URL stay variables (deployment
  paths). This migration forced the change-propagation seam from polling to
  `ev.config.updated`, because a store read in the idle seam starved the pump.
- [x] **Hooks: deliberately EXCLUDED, not deferred** (decision, not a TODO).
  A hook command is `sh -c` — shell execution. Exposing it through
  `config_patch` would let a model (or a subagent) obtain arbitrary shell
  execution via an approval prompt that reads "config_patch hooks.commands",
  which is far less legible than a human reading the command they approve.
  Same reasoning that keeps `NIF_AUTO_APPROVE` in env (§Q5). The subscription
  set is a tap set — boot-time by construction, like logfile's captured
  subjects — and the only remaining field is the timeout, which does not
  justify a domain. Hooks stay env-configured (`core.kill` + `core.spawn`).
- [x] **Agent delegation: EXCLUDED, and this one was learned by trying it.**
  `maxDepth`/`wakes` look like ideal settings, so they were migrated into an
  `agent.delegation` domain — and the slice was then reverted, because the
  authoritative enforcement is **in core**: `core/dispatch.nim` checks
  `NIF_AGENT_MAX_DEPTH` for every `noSpawn` tool *and says why* ("The check
  MUST live here, not in the component's handler: the handler blocks its
  component's pump for the child's whole turn"), and `core/conversation.nim`
  reads `NIF_AGENT_WAKES` for the wake budget. The component's copies are
  mirrors. A stored value would therefore change the mirror and not the
  authority — `maxDepth: 2` would appear to be accepted and do nothing on the
  path that actually refuses. Migrating these properly means teaching core to
  read the owner's record for a boot-adjacent value, which reintroduces exactly
  the "ask the thing being reconfigured" circularity §Q5 rejects. They stay
  environment, like the tier→model map (a model name is an environment fact
  too: a stored model would follow a copied database onto a machine that cannot
  serve it).
  **The lesson generalizes:** before exposing a variable, find its authoritative
  reader. If it is core, a component-level domain is a lie.
- [ ] Harness/session birth and context defaults (the remaining half of this
  item: `NIF_RUNNER_IDLE_S`, context-window defaults, birth-time compaction).
- [x] **The authoritative-reader rule** (learned by shipping the mistake):
  before exposing a variable as a setting, find who ENFORCES it.
  `rg -n 'NIF_YOUR_VAR' core/ sdk/` is the whole check. Three outcomes:
  - **only the owner reads it** → safe to migrate (repomap, fetch, logfile,
    models, lsp, observe — all verified);
  - **core reads it too** → a component domain is a LIE, because the stored
    value changes the mirror and not the rule (this is exactly how the
    `agent.delegation` slice went wrong: `maxDepth` is enforced in
    `core/dispatch.nim`, `wakes` in `core/conversation.nim`). Leave it in env,
    or accept that migrating it means teaching core to read an owner's record —
    which is the circularity §Q5 rejects for boot-adjacent values;
  - **it is a secret, a deployment path, a subscription set, or a test seam**
    → leave it in env by category (`.env`, `NIF_AUTO_APPROVE`, provider keys,
    `NIF_MODELS_URL`, `NIF_LOGFILE_SUBJECTS`, `NIF_MOCK_*`/`NIF_TEST_*`).
- [ ] Remaining inventory work (classification per variable, not new seams):
  `NIF_HOOKS_*` (excluded, see §5), `NIF_AGENT_MODEL_*` (environment fact),
  `NIF_RUNNER_IDLE_S`, context-window and birth-time compaction defaults
  (core-owned — apply the rule above), `NIF_REPOMAP_*` (already dual: stored
  value wins, env is the bench seam).

### 6. Discovery and client cleanup

- [x] TUI files consolidated under ~/.niffler without SQLite (prior work,
  reported commit fd9df56; verify current source before further TUI changes).
- [x] Skills precedence: conversation workspace/.agents/skills, ~/.agents/skills,
  bundled plus compiled fallback; retain shadow audit and explicit repository
  install/manual copy (no new import/link tool). User-root change to
  ~/.agents/skills passed test-skills and the full gate.
- [x] Remove implicit foreign-agent skill scans and NIF_SKILLS_BUNDLED_DIR;
  replace test dependency on that env with a compile-time bundled-tree fixture.
- [x] Survey local harness sources for explicit copy/import locations; evidence
  recorded in [SKILL-LOCATIONS.md](SKILL-LOCATIONS.md).
- [ ] Add optional external scan/import from a data-driven location registry;
  approval-gated copy, no overwrite by default, bounded safe tree handling.
- [x] Specify core/root dotenv versus client bootstrap dotenv; regressions for
  explicit remote connection paths and hostile repository approval overrides.
  Settled identically in all three SDKs (`sdk/dotenv.nim`, `sdk/go/dotenv.go`,
  `sdk/ts/src/dotenv.ts`): the only file read is `<root>/.env`, where the root
  is an explicit `NIF_ROOT` or a binary-derived directory that actually looks
  like a clone (`niffler.nimble` / `var/bin`). Containment is NOT enough, so a
  conversation workspace or plugin checkout inside the root is refused too.
  No trusted root means no `.env` at all, and a refusal prints one stderr line.
  Regressions: `tests/t_dotenv.nim` (`make test-dotenv`),
  `sdk/go/dotenv_test.go` (inside `make gotest`), `sdk/ts/test/dotenv.test.js`
  (`make test-dotenv-ts`); each was verified to fail against the old
  cwd-honouring behaviour. The Wails-hosted client's opposite load order is
  gone with it — there is only one order now.

### 7. Acceptance and release readiness

- [x] Current discovery slices: build prerequisites and `make test` passed
  (90 server tests, plus Go and bench gates). Repeat after later code slices.
- [ ] Live isolated harness verification for SDK/store/conversation changes;
  two instances sharing one test TiDB dataset, without production migration.
  Partly done: the **store layer** is verified against a live TiDB
  (`make test-store-tidb`, `go test ./...` in components/store-tidb), and two
  owners on one dataset are isolated there. What remains is the **harness**
  layer — two live harnesses, one dataset — which §2 tracks separately.
- [ ] Update manual translations, migration docs, PLAN and changelog.
  Changelog is current for every slice shipped so far. Still open: the
  translations (below) and `docs/PLAN.md`, whose last entry predates this
  branch's configuration/instance work.
  Known gap: `MANUAL.zh.md`/`MANUAL.zh-TW.md` have 56 `###` sections against 58
  in English — they are missing "Declared configuration (the `config`
  component)", "Pinned providers never reroute" and "GitHub CLI and a token".
  So the whole config surface (including `humanOnly`) has no localized
  documentation. A section-level refresh, not a line edit: translate those
  three, then re-sync the rest.
- [ ] Separate plugin/TUI commits, tests and release tracking. No implied
  production restart, migration or plugin release from source edits alone.

## Work log

- Committed baseline: 71dfaad (design/tracking), 75e22cf (AGENTS-only),
  bdd8760 (workspace and shared user skill roots). Scratch files excluded.
- Started instance-store foundation: new instances-table migrations in both
  engines, SQLite legacy-document preservation test and DSN-gated TiDB test.
  `make gotest`, `make test-store` and full `make test` exited 0 (90 server
  tests). Logs: `.scratch/instances-*-test.log`. Live TiDB validation remains
  conditional on a test DSN.

- Started: recovered discussion; captured instance-scoping and fleet-registry
  requirements. First bounded code slice: AGENTS-only instruction discovery.
- Validated: `make test-systemprompt test-edit` exited 0; systemprompt and edit
  contracts passed, including both CLAUDE spellings and AGENTS precedence.
  Full server gate remains required before merging.
- Skills slice: `make test-skills` passed after adding workspace load/resource,
  install/removal, per-call context reset, user-over-bundled and ignored legacy
  directory cases. Full `make test` exited 0: 90 server tests passed
  (jobs=7), including Go and bench prerequisites. `git diff --check` passed.
  Log: `.scratch/full-test.log` (local, not committed).
- User requested cross-harness ~/.agents/skills instead of ~/.niffler/skills.
  Updated runtime/install/removal, fixtures, manuals and design. test-skills
  and full make test exited 0 (90 server tests, Go and bench gates).
  Logs: `.scratch/skills-agents-test.log` and `.scratch/agents-full-test.log`.
  `git diff --check` passed. Existing user files were not moved.
