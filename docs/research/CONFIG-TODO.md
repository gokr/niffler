# Configuration implementation checklist

Active branch: `feat/settings`. Design: [CONFIG.md](CONFIG.md).
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
- [ ] Resolve the proposals in CONFIG.md §11 before SQL implementation:
  actual instance key/column, shared-record representation, consistent SQLite
  behavior, legacy ownership adoption and default query scope.
- [ ] Specify declaration discovery, owner mutation routing, supported schema
  subset, secrets/read-only handling, revision checks and application timing.
- [ ] Specify instance/shared/default precedence and sunset rules for env.
- [ ] Update WIRE and architecture notes with the reviewed contract.

### 1. AGENTS-only instructions (first implementation slice)

- [x] Remove CLAUDE candidates from birth-time and lazy instruction loading.
- [x] Contract tests: CLAUDE-only directories ignored (both spellings), AGENTS
  priority and additive local files retained; frozen existing prompts retained.
- [x] Update English/localized manuals, relevant comments and changelog.
- [x] Run `make test-systemprompt test-edit` (build prerequisites included).
  Both passed; log: `.scratch/instructions-test.log` (local, not committed).

### 2. Instance-aware document storage

- [ ] Add `instances` registry and document instance dimension to both engines.
  Schema-only registry migrations and preservation tests added; `make gotest`
  passed. `make test-store` and full `make test` passed (90 server tests).
  Registry API slice adds hidden validated instance_register/instance_list in
  both engines; make gotest, test-store and full make test passed (90 server
  tests). Core boot registration added; test-core passed. First full gate:
  89 passed, fleet-task wake test raced notice acknowledgement versus turn
  completion. Narrow rerun passed; test now retries only explicit mid-turn
  refusals before asserting budget decline. Narrow fleet-task test and full
  make test passed (90 server tests); git diff --check passed.
  Ownership-column migrations and owner-captured handlers now added with
  two-owner database tests. Existing process wiring still uses legacy owner;
  stable identity binding and adoption remain pending. make gotest, test-store
  and full make test passed (90 server tests). See [INSTANCE-STORE.md](INSTANCE-STORE.md).
- [x] Use existing persistent instance identity; binding resolved once at open
  (NIF_INSTANCE_ID, else var/instance-id, else legacy). SQLite adopts its own
  legacy rows once and refuses a different identity; TiDB never adopts.
- [x] Scope put/get/list/del/search, revision conflicts, selftest, and FTS;
  preserve verbatim values and correct pagination within a scope.
- [x] Document `NIF_INSTANCE_ID` as a bootstrap variable (manual + .env.example).
- [x] Explicit `store_claim` admin operation for legacy rows (dry run by
  default, collision refusal, bounded resumable batches, approval-gated).
- [ ] Two-instance tests: same kind/id isolation; no foreign restore/recover,
  heartbeat execution, grants, leases or settings; metadata registry roundtrip.
- [ ] Exercise TiDB against a real test database when available; don't treat
  SQLite-only tests as proof of TiDB DDL or concurrency correctness.

### 3. Fleet registry in the store

- [ ] Inventory fleet receipt files and TUI `instances.json`; define identity
  registry versus controller-specific routes/pins/receipts. Keep document
  payloads for transport details instead of SQL columns per transport.
- [ ] Add store-backed fleet instance CRUD and named-instance lookup through
  owner tools; retain live identity verification before remote actions.
- [ ] Import existing records once; conflict/invalid/identity-drift refusals;
  retain explicit export/import as interchange, not the authoritative registry.
- [ ] Migrate fleet install/adopt/update/lifecycle/delegation callers and tests.
- [ ] TUI: consume registry through the bus, with minimal local bootstrap
  information for the first connection and explicit offline behavior.
- [ ] Test outage, restart, migration, route/pin mismatch and multiple scopes.
  TUI changes require its repository in the authorized working set.

### 4. Generic configuration surface

- [ ] Implement schema declaration seam and shared validation helpers.
- [ ] Add configuration peer: config_list/get/patch/reset, owner-routed,
  approval-gated, revision-safe, redacted and instance-aware.
- [ ] Test invalid patches, resets, secret preservation, subagent restrictions,
  stale revisions, unavailable owner/store, and immediate/restart timing.
- [ ] Add schema-driven TUI editor in the TUI repository; no per-owner forms.

### 5. Owner migrations (each with its own tests and docs)

- [ ] DeepSeek web enablement/request defaults; stable schemas and paid-call gate.
- [ ] Models endpoint/offline/refresh policy and inline override patches.
- [ ] LSP registry data, warmup policy and executable search preferences.
- [ ] Fetch extraction/output/network preferences.
- [ ] Repomap automatic append/admission preferences.
- [ ] Logfile/observe retention, quotas, subscriptions and capture policy.
- [ ] Hooks commands, subscriptions and deadlines (security-sensitive).
- [ ] Agent defaults/delegation; harness/session birth and context defaults.
- [ ] Inventory remaining runtime env by owner; classify bootstrap, developer
  test seam, secret or migratable setting before removing any variable.

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
- [ ] Specify core/root dotenv versus client bootstrap dotenv; regressions for
  explicit remote connection paths and hostile repository approval overrides.

### 7. Acceptance and release readiness

- [x] Current discovery slices: build prerequisites and `make test` passed
  (90 server tests, plus Go and bench gates). Repeat after later code slices.
- [ ] Live isolated harness verification for SDK/store/conversation changes;
  two instances sharing one test TiDB dataset, without production migration.
- [ ] Update manual translations, migration docs, PLAN and changelog.
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
