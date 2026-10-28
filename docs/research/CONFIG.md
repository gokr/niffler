# CONFIG — component-owned, schema-described configuration (decisions)

> **Status: implemented on `main`** (the `feat/settings` branch merged
> 2026-10-22; extended 2026-10-27). This supersedes the surface design in
> `SETTINGS.md` where the two differ; the per-key mechanics that survived
> (merge-patch validation, `expectRev`, application timing, the "no settings in
> the prompt prefix" rule) are enforced by the shipped surface. The `config`
> peer, `config_list`/`config_get`/`config_patch`/`config_reset`, the
> `config_declare` seam and instance-scoped storage are live. The wire contract
> is [CONFIG-CONTRACT.md](CONFIG-CONTRACT.md) and operation is
> [../MANUAL.md](../MANUAL.md#declared-configuration-the-config-component).
> Shared-scope settings remain a proposal (`config` is `instance`-only);
> nothing uses a single `settings:global` document, and
> `core/workspaceconfig.nim` has no production call site.
>
> Provenance: reconstructed from the `deepseek-search` conversation (audit at
> `6a47727`), which ended by creating the `feat/settings` worktree. The
> questions in §10 were settled by building it; delivery and remaining work are
> tracked in [CONFIG-TODO.md](CONFIG-TODO.md), and instance persistence is
> recorded in [INSTANCE-STORE.md](INSTANCE-STORE.md).

## 0. Baseline finding (the audit)

Niffler has **several configuration systems, not one**: process env, cwd
`.env`, `$NIF_ROOT/.env`, CLI flags, `manifest.yaml`, ~15 store kinds, several
JSON files (LSP registry, `NIF_MODELS_PATH`, `NIF_MODELS_OVERRIDE`, models
cache), TUI-local files, and instruction/skill discovery chains. Measured
consequences:

- There is **no universal precedence rule**; each subsystem resolves its own
  layers, and reload timing is inconsistent (boot-captured vs per-call).
- Discovery is the core defect: you must know a knob exists to set it, and
  nothing lists what is tunable at runtime.
- Scope confusion: per-conversation semantics (`NIF_PROFILE`,
  `NIF_MAX_TURN_ROUNDS`) are expressed as process-global env, so two
  conversations cannot want different defaults without a restart.
- The model has no window into any of it.

Qualifications that shape the plan:

- **Credentials already live in the store** (provider registry holds API keys
  and OAuth credentials), so "all secrets stay in env" is not true today.
- **`manifest.yaml` stays authoritative** for shipped component names; the
  store has not replaced it.
- Caches, journals, receipts, discovery files and build/package files
  (`var/models/api.json`, `var/processes/*.json`, `package.json`, `go.mod`,
  `.nimble`, `config.nims`, `Makefile`) are **not** competing settings stores
  and must not be swept into one.

## 1. The model (C1–C4)

**C1. Store-backed, component-owned, schema-described configuration is the
normal path** — not more env vars, not more user-edited JSON files.

**C2. Owners and homes:**

| Category | Home |
|---|---|
| Minimum bootstrap information | CLI arguments + a small set of `NIF_*` |
| Secrets needed before connecting | environment / `.env` |
| Component settings | store documents (owner's existing kind) |
| Existing structured config (providers, MCP, agents, toolsets, personas, heartbeats, conversation headers) | their existing store kinds — unchanged |
| Package/build declarations | `manifest.yaml`, `niffler.json`, dependency/build files |
| Instructions and skills | Markdown files |
| Generated state, caches, output | `var/` |
| Client-local preferences + connection discovery | one user directory (`~/.niffler`) |

**C3. No new human-edited settings files by default.** A second file format
would re-create the dead `~/.niffler/config.yaml` / `~/.niffler/config.json`
dead end. File import/export stays available as an *explicit operation*.

**C4. No permanent dual system.** Old env vars get a migration window, then are
removed. Keeping every var as a permanent override preserves exactly the two
competing systems this work exists to delete.

## 2. The schema contract (C5–C10)

**C5. Declarations are runtime data**: JSON Schema core plus a small amount of
application/UI metadata. Each owning component declares:

| Declaration | Purpose |
|---|---|
| stable schema id + version | identification, migration |
| document kind and id, or collection | where the values live |
| properties, types, defaults, bounds, enums | validation *and* generic forms |
| titles, descriptions | labels/help text |
| secret / write-only fields | redaction, password inputs |
| read-only fields | keeps counters, caches, cached MCP tool schemas out of editing |
| application timing | `immediate` \| `next turn` \| `next conversation` \| `component restart` |
| mutation route | which owner tool accepts changes |

**C6. Do not centralize everything into `settings:global`.** Ownership and
existing kinds stay; the unification is over **discovery, validation and
editing**, not storage. `settings:global` survives only if a genuine
harness-wide default needs a home (open question Q1).

**C7. Writes go through the owner's validation/application path.** A generic
editor must never blind-write arbitrary store documents: some records hold
credentials, cached tool schemas or internal counters. Rejecting a patch must
not partially apply — validate all, then one write with `expectRev`.

**C8. Revision checks** prevent lost updates (the store's existing `expectRev`
mechanics).

**C9. Generic interface**, four tools that feel built-in to the model:

- `config_list` — discover configurable domains
- `config_get` — values, defaults, revision, schema
- `config_patch` — validated, approval-gated changes
- `config_reset` — drop explicit values, back to defaults

**C10. One editing experience.** The TUI renders forms from the same
declarations; no hard-coded per-settings panels. Security-sensitive fields get
stricter treatment than presentation preferences: approval is necessary but not
sufficient — existing human-only controls and subagent restrictions still
apply.

## 3. Architecture boundary (C11–C12)

**C11.** Implement this as a **configuration component plus a generic
declaration seam in the SDK**, not as a large new subsystem in core. Core
already supplies routing and approval enforcement; it should not grow a
settings engine.

**C12.** Any required generic registration/SDK change (how a component
publishes its declaration) is **proposed separately and approved before
implementation**.

## 4. Per-owner migration (C13)

| Owner | Store-backed configuration |
|---|---|
| `models` | baseline URL, offline mode, refresh/cache policy, overrides |
| `lsp` | the server registry **itself**, warmup policy, executable search |
| `fetch` | extraction preferences, output limits, network policy |
| `repomap` | auto-append, admission thresholds |
| `logfile` / `observe` | retention, quotas, subscriptions, capture policy |
| `hooks` | event subscriptions, commands, deadlines |
| `agent` | default tier ladder, delegation behaviour |
| `deepseek` | web enablement, endpoint, request defaults |
| harness/session | default budgets, toolset, context-management policy |

**C13a. `models`: separate configuration from catalog content.** Store the
endpoint/offline/refresh preferences; store override patches **as data**, not a
path to another JSON file; keep downloaded catalogs and derived patches as
caches under `var/`.

**C13b. `lsp`: store the registry itself**, not a setting pointing at
`servers.json`.

## 5. `.env` semantics (C14)

- Existing process environment wins; dotenv only supplies otherwise-unset
  values.
- **Core** loads `$NIF_ROOT/.env`.
- **The TUI must not rely on generic loading**: cwd `.env` may supply
  *client/bootstrap* settings, but must never configure an already-running
  remote harness. Never implicitly copy local secrets to another instance.
- An arbitrary repository's `.env` must not silently change approval/security
  policy — relevant when starting a client inside an unfamiliar checkout.

## 6. Instructions and skills (C15–C18)

**C15. Instructions: AGENTS only.** Keep `AGENTS.override.md`, `AGENTS.md`
(plus its uppercase-extension compatibility spelling) and additive
`AGENTS.local.md`. **Remove automatic `CLAUDE.md` / `CLAUDE.MD` loading** — a
deliberate, documented compatibility change. Existing conversations keep their
frozen prompts; new conversations use the new discovery rules.

**C16. Skills: three normal sources, first match wins:**

1. workspace: `<workspace>/.agents/skills/`
2. user-installed: `~/.agents/skills/`
3. bundled: shipped skills, with compiled fallback

No automatic scanning of `.claude`, `.opencode` or multiple home directories;
offer an **explicit import/link operation** for compatibility instead.

**C17. A list/audit view shows shadowed copies** so precedence is visible
rather than guessed.

**C18. Remove `NIF_SKILLS_BUNDLED_DIR`.** Tests use explicit fixtures; product
configuration need not expose every internal test seam. "Workspace" means the
**conversation workspace**, not `NIF_ROOT` (today's code uses the harness root).

## 7. Client-local state (C19–C21)

**C19. One user directory, `~/.niffler/`** (same on Linux and macOS): client
preferences, aliases, seen/unread markers, input history, resume state, and
`skills/`. Instance routes were initially included; the subsequent decision in
§11 moves the authoritative fleet registry into the store, retaining only
minimal first-connection bootstrap information locally. This intentionally
favours a consistent Niffler convention over the XDG split (`~/.config` vs
`~/.local/state`) that the current implementation already mixes.

**C20. No SQLite in the TUI.** Consolidate the existing files under
`~/.niffler` first, keeping their formats. A client-local database is a
separate decision and must not be bundled into the settings redesign.

**C21. Client-local state stays a deliberate exception** to "everything in the
harness store", because the client must know how to connect before the store is
reachable, one TUI may talk to several independent harnesses, and
theme/locale/unread markers belong to the person, not a remote instance.

*Implemented already:* `niffler-tui` commit `fd9df56` — client files under
`~/.niffler/`, legacy files migrated once on first use, existing destinations
win, no SQLite.

## 8. Migration semantics (C22–C23)

**C22. Order — independently testable slices:**

1. Specify the configuration declaration and mutation contract.
2. Implement the shared configuration surface and the generic TUI editor.
3. Migrate **DeepSeek and models** as two small worked examples.
4. Move the **LSP registry** into the store.
5. Migrate remaining component env settings, by owner.
6. Consolidate TUI-local files under `~/.niffler`. *(done: `fd9df56`)*
7. Simplify instruction and skill discovery.

**C23. Migration imports existing values once**, with provenance and explicit
precedence, **reports conflicts**, and never silently overwrites stored
choices.

## 9. Plugin precedent (C24)

The DeepSeek plugin is the first worked example and sets the shape for
plugin-owned config:

- Settings live in a **component-owned store document** (`webEnabled` etc.),
  surfaced through a `deepseek_config` tool.
- **Tool schemas stay registered and stable** while running; enabled/disabled
  is enforced at dispatch, so toggling needs no restart and cannot churn the
  prompt prefix.
- **No silent fallback**: a store failure must not enable a paid capability or
  discard configuration.
- Credentials: prefer the active provider's **stored** credential over a stale
  env value (already shipped in the plugin) — a working precedent for the
  general store-over-env direction.

## 10. What this does not solve / open questions

- **Q1 — precedence contract.** `SETTINGS.md` states
  `conversation > store > env > default` with env as a permanent operator
  override; the newer shape keeps env for bootstrap/secrets only, with a
  migration window then removal. These conflict and must be settled
  explicitly before implementing either. *(Recommendation from the
  conversation: settle it as one written contract, not per subsystem.)*
- **Q2 — where declarations live**: published at component registration vs a
  static registry. Needs a small SDK/registration proposal (C12).
- **Q3 — `settings:global`'s fate** if ownership stays with existing kinds
  (C6).
- **Q4 — `core/workspaceconfig.nim`**: keep the workspace `.niffler/config.json`
  idea as read-only workspace policy, or fold it into component-owned
  declarations? It is dead code today and must not be advertised as working.
- **Q5 — boot-critical keys are excluded by design** (`NIF_ROOT`,
  `NIF_NATS_URL`, `NIF_NATS_SPAWN`, `NIF_STORE_BACKEND`, `NIF_STORE_TIDB_DSN`,
  `NIF_AUTOSTART*`): asking "which bus, which store" of the thing being
  reconfigured is circular. Secrets stay in `.env` / provider registry;
  `NIF_AUTO_APPROVE` stays env (a settings-UI entry would be a footgun) and
  `NIF_MOCK_*`/`NIF_TEST_*`/`NIF_SMOKE_*` stay test-only.
- **Q6 — scope**: a database is not an instance boundary. §11 requires an
  explicit instance dimension when several instances share the dataset.
- **Prompt-cache discipline**: no settings value is prompt content, so none of
  this may touch the frozen prefix — settings changes are announced as events
  (`ev.config.updated`), never spliced into a head.

## 11. Instance-aware persistence

### Confirmed requirements

- Several Niffler instances may share the same TiDB SQL dataset.
- Documents need an explicit instance column outside opaque JSON values.
- A dedicated `instances` table records stable Niffler identities and metadata.
- Configuration must be scoped per instance rather than implicitly per database.
- Move the fleet instance registry into the store instead of keeping an
  authoritative JSON registry. Transport details can remain document payloads.

Existing identity: `core/identity.nim` generates a persistent 128-bit hex ID
in `var/instance-id`. Prefer reusing this identity over names, filesystem roots
or database connection strings as the ownership key.

Current SQL keys are `(kind, id)`. With a shared dataset, unfiltered boot
restore and `--recover` enumerate the same `component` records; heartbeat
workers enumerate the same schedules; `provider:active` becomes global.
Scoping must therefore cover persistence operations, not just settings forms.

### Implementation (settled — see INSTANCE-STORE.md)

> This section was written as a proposal. It has since been **implemented and
> settled**; the authoritative record of what shipped is
> [INSTANCE-STORE.md](INSTANCE-STORE.md). Every question below was answered by
> building it:
>
> | question | answer as shipped |
> |---|---|
> | instance key/column | `instance_id`: 32-char lowercase hex, reusing `var/instance-id`; a real column on `docs`, not opaque JSON |
> | shared-record representation | transport/route detail stays document payload, never a SQL column; shared *settings* scope is refused until decided (`config` is `instance`-only) |
> | SQLite behaviour | identical logical contract in both engines (SQLite `00004`, TiDB `00003`); the same tests run against both |
> | legacy adoption | SQLite adopts its own legacy rows once; TiDB **never** adopts; both offer an explicit approval-gated `store_claim` |
> | default query scope | the store resolves its owner once at boot and uses it implicitly — never a tool argument, so a client cannot choose whose history it reads |
>
> One detail the implementation changed: TiDB cannot `DROP PRIMARY KEY`
> (clustered index, Error 8200), so that migration is a convergent table
> rebuild (docs/MANUAL.md "Store engines").

The original proposal follows, kept for the reasoning:

```
instances(instance_id PRIMARY KEY, ...metadata...)
docs(instance_id, kind, id, rev, value, updated_at)
PRIMARY KEY (instance_id, kind, id)
```

Keep values verbatim and kinds opaque. Implement identical logical behavior
in SQLite and TiDB; a local SQLite file is not a reason to use a different
ownership model. All paths need the dimension: put/get/list/delete/search,
revision conflicts, selftests and the derived SQLite FTS index. Cross-instance
pagination needs a composite cursor if such queries are eventually exposed.

The store process on each instance's bus could default to its owning instance,
preserving ordinary caller behavior. Exact wire fields and permitted explicit
cross-instance operations require a contract review. Optional new arguments
are still wire extensions, not "zero wire churn". Scope is not authentication:
credentials, bus trust and authorization need separate consideration.

Unresolved details to settle in implementation slices:

- Shared configuration: whether to introduce a separate shared namespace, and
  how instance values overlay shared values. No shared fallback or env
  precedence change has been approved merely by adding instance ownership.
- Registry metadata columns versus document metadata, registration lifecycle,
  foreign keys and retirement. Registry retirement must not silently delete
  document history. Missing/recreated/cloned identities require explicit rules.
- Legacy ownership migration: preserve existing SQLite histories and explicitly
  assign legacy shared rows; never have the first TiDB client claim everything.
- Identity distribution to children: reuse persistent identity; a new
  `NIF_INSTANCE_ID` override is a proposal, not a requirement already decided.
- Sharing providers/credentials, roaming conversations and explicit cross-scope
  views are separate decisions, not implied by shared physical storage.
- Application refresh across independent buses: local NATS events alone cannot
  invalidate caches in another instance.

### Fleet registry migration

Current source distinguishes two artifacts:

1. Harness `fleet` install/update/lifecycle tools use private verified receipt
   JSON files selected by `profile`; delegation snapshots receipts into
   `fleetjob` documents.
2. The TUI keeps named connection routes and identity pins in
   `~/.niffler/instances.json` (formerly XDG config).

Both must be accounted for by the store-backed registry work. Keep stable
instance identity separate from controller-specific SSH/Lima/Incus routes,
known-host policy, identity pins and approved operation authority. Import must
validate the same identity/route invariants as file loading. Preserve the
pinning and live verification checks on every remote mutation.

The client still needs a minimal way to reach its first store: explicit CLI
connection arguments or a bootstrap route. This is not justification for
keeping a second authoritative fleet registry. Specify initial connection,
offline behavior and one-time migration before changing TUI callers.

Track code, contract, migration and tests in [CONFIG-TODO.md](CONFIG-TODO.md).
