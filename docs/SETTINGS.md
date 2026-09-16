# SETTINGS — a settings surface over the store (design)

> Plan, not implemented. Goal: every knob a *human or model* might want to
> change lives in the store and is editable from a `/settings` command,
> instead of being an environment variable you had to know about. Environment
> stays what it is good at — boot decisions and secrets (see
> MANUAL.md "State and configuration").
>
> Baseline: main @ the repomap merge; conv-controls (`/approvals`, `/limit`)
> read from its worktree as the pattern to follow.

## 0. The problem, measured

109 `NIF_*` variables exist; ~86 are production, 19 test/bench-only. They
work, and MANUAL.md documents them — but they have three real costs:

1. **Discovery**: you must know a var exists to set it. Nothing lists what is
   tunable at runtime.
2. **Scope confusion**: `NIF_PROFILE` and `NIF_MAX_TURN_ROUNDS` are
   *per-conversation semantics* expressed as process-global env. Two
   conversations cannot want different defaults; changing one means
   restarting the harness.
3. **No model access**: the agent cannot read or set any of this. A model
   that might benefit from knowing "the user prefers budget-capped maps" has
   no surface.

## 1. Precedence — the one rule

```
conversation header  >  store settings (global defaults)  >  env  >  code default
```

- **Conversation header** (`conversation` kind, per conversation): what the
  UI and model set with `/model`, `/effort`, `/profile`, `/approvals`,
  `/limit` today. Unchanged — this doc does not move it.
- **Store settings** (new kind `settings`, id `global`): defaults for *new*
  conversations and harness-wide behavior. Written by `/settings`. Never
  written by components.
- **Environment**: unchanged for boot (`NIF_ROOT`, `NIF_NATS_URL`,
  `NIF_STORE_BACKEND`, `NIF_AUTOSTART*`) and for *secrets* (`.env`). For
  promoted tuning vars, env becomes the override that beats the store —
  "shell env wins" stays the rule operators already trust.
- **Code default**: what `getEnv(name, default)` says today.

Env keeps winning so an operator can always pin behavior from outside
(systemd unit, bench adapter, CI) without touching the database. The store
fills the *unset* case, which is exactly the gap: today unset means "code
default", and there is no place between that and editing `.env`.

## 2. What moves to store settings (phase 1)

Only vars that are (a) safe to change at conversation granularity and (b)
already semantically per-conversation or per-new-conversation:

| Setting | Env today | Store key | Applies |
|---|---|---|---|
| default tool profile | `NIF_PROFILE` | `profile` | new conversations |
| default max rounds | `NIF_MAX_TURN_ROUNDS` | `maxRounds` | per turn, when the conversation has no explicit maxRounds (read inside `runTurn` today) |
| thinking effort default | (provider default) | `thinking` | new conversations |
| model default | `NIF_OPENAI_MODEL` | `model` | new conversations, only when no active provider |
| context reserve | `NIF_CTX_RESERVE` | `ctxReserve` | admission, read per turn (`outputReserve()`) |
| repomap auto-append | `NIF_REPOMAP_AUTOAPPEND` | `repomapAutoAppend` | per `ev.workspace.opened` (already read per event) |
| read outline threshold | `NIF_READ_OUTLINE_LINES` | `readOutlineLines` | read per call |
| write cap | `NIF_WRITE_MAX_BYTES` | `writeMaxBytes` | read per call |

Deliberately **not** moved, ever: `NIF_ROOT`, `NIF_NATS_URL`,
`NIF_NATS_SPAWN`, `NIF_STORE_BACKEND`, `NIF_STORE_TIDB_DSN`, `NIF_AUTOSTART*`
(boot identity — circular through the store they would configure);
`NIF_OPENAI_API_KEY` and all secrets (`.env`; runtime secrets already have a
home — the provider registry); `NIF_AUTO_APPROVE` (headless escape hatch; a
settings UI entry would be a footgun, bench sets it programmatically);
`NIF_MOCK_*`/`NIF_TEST_*`/`NIF_SMOKE_*` (test-only, 19 vars).

Everything else (observe ring sizes, logfile rotation, lsp bin dirs, fetch
spools, mcp thresholds, hooks) stays env for now: component-local tuning with
no cross-conversation meaning. Promoting them later is mechanical once the
plumbing exists (§5).

## 3. Mechanics

### 3.1 One read path, in the SDK

```nim
# sdk: the only new primitive
proc setting*(cat: Catalog, name: string, default: string): string
  ## store kind "settings", id "global" → JSON object; env var
  ## "NIF_" & toUpperSnake(name) overrides when set; cache with the
  ## catalog (store rev busts it).
```

Call sites change from `getEnv("NIF_X", d)` to `setting(cat, "x", d)`. That
is the entire per-component diff — no new tools, no new subjects. Components
that do not adopt it keep working unchanged (env still works for everything).

### 3.2 Who writes it

A `settings` control surface on core, next to `session`:

```
settings {op: "get"}                         → the merged view (env-annotated)
settings {op: "set", patch: {...}}           → JSON Merge Patch onto settings:global
settings {op: "reset", keys: [...]}          → delete keys (fall back to env/default)
```

- Approval-gated like every mutation (`x-harness.approval: always`).
- Validation mirrors conv-controls': unknown keys and out-of-range values are
  refused with a structured error; the patch is never partially applied
  (validate all, then one `storePutRev` with `expectRev`).
- An `ev.settings.updated` event announces the change (same role as
  `ev.catalog.updated` for the slash table).

### 3.3 When changes take effect

Three classes, stated per key in the schema (no magic):

- **next conversation** (profile, model, thinking): read when a conversation
  header is first built. Nothing to restart.
- **per turn** (maxRounds when no per-session value, ctxReserve): the read is
  already inside the turn loop/admission — `setting()` swaps for `getEnv()`
  at the same site, so a store change applies to the next turn of any
  conversation without an explicit per-session override.
- **per event / per call** (repomapAutoAppend, writeMaxBytes,
  readOutlineLines): the owning code already re-reads at each event or call;
  the diff keeps that shape, swapping `getEnv` for `setting`.

Nothing requires component restart. That is the point of choosing only
per-turn/per-call/per-event/new-conversation keys in phase 1; boot-critical
keys are excluded by design (§2).

### 3.4 The `/settings` command

Builtin slash command, subcommands declared in the registry (the drift-guard
pattern — dispatch, completion and docs all read one table):

```
/settings                     # the merged view: name, value, source
                              # (conversation | global | env | default)
/settings set maxRounds 80    # → settings {op:"set"}; persisted
/settings set thinking high   # → same, new-conversation default
/settings unset maxRounds     # → settings {op:"reset"}
/settings get ctxReserve      # one key, with its source
```

Reads need no gate; writes are approval-gated. UI renders it from the same
declared schema it renders `/provider` from — no bespoke panel in phase 1.

Model access: `settings {op: "get"}` is also exposed as an onDemand,
read-effect tool so the model can *see* current settings when a task depends
on them. The model never gets `set` — settings are the human's, the same way
approvals are.

## 4. What this does NOT solve (stated plainly)

- **Per-component tuning env** (observe rings, logfile rotation, fetch spools,
  hooks, lsp): stays env in phase 1. These are operator/ops-level, rarely
  touched, and their components read env at boot — promoting them means each
  component adopts `setting()` and defines restart semantics. Mechanical, but
  not free; do it when a knob is actually wanted at runtime.
- **Secrets**: stay in `.env` / provider registry. The store is a database
  file; provider credentials already live there behind redaction, but boot
  secrets (bus DSN, TiDB DSN) predate the store and must.
- **Multi-root**: settings are per `NIF_ROOT` (the store is). That matches how
  everything else scopes.

## 5. Phasing

1. **P1 — plumbing**: SDK `setting()`, core `settings` control op, store kind
   `settings` (id `global`), `ev.settings.updated`, promote the eight §2
   keys, tests (merge-patch validation, precedence env>store>default, crash
   safety via `expectRev`).
2. **P2 — surface**: `/settings` builtin + UI rendering + onDemand read tool.
3. **P3 — adoption**: move remaining per-turn/per-call component knobs as
   wanted; each is a two-line diff plus a test.

P1+P2 are ~2–3 days. Nothing in the phase plan touches the frozen system
prompt (settings are not prompt content), so no prompt-cache interaction.

## 6. Non-steals

- No settings *file* (JSON/YAML): the store is the database; a second
  source of truth would re-create the `~/.niffler/config.yaml` dead end
  (niffler-old wrote one; current Niffler never reads it).
- No live editing of boot-critical env — "which bus, which store" cannot be
  answered from the thing being reconfigured.
- No model-writable settings.
