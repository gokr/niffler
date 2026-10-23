# Configuration contract (slice 4)

Status: implemented by `components/config` plus this document. Design:
[CONFIG.md](CONFIG.md) §1–§2 (C5–C10). Delivery status:
[CONFIG-TODO.md](CONFIG-TODO.md).

## Shape

A **declaration** is a JSON document an owning component publishes about one
configurable domain. It is runtime data, not an SDK type, and it is published
through a bus tool (`config_declare`), so no SDK or registration change is
needed (C12) and a component written in any language can own settings.

```json
{
  "domain":  "deepseek.web",          // stable id, unique per owner
  "version": 1,                        // declaration revision (migration)
  "owner":   "deepseek",               // component that answers get/patch/reset
  "ownerTool": "deepseek_config",      // its tool; "" when it owns no state
  "title":   "DeepSeek web tools",
  "description": "Search and fetch against DeepSeek's paid web APIs.",
  "kind":    "deepseek-config",        // store kind holding the values
  "id":      "web",                    // store id; "" for a collection
  "scope":   "instance",               // instance (only value implemented)
  "schema":  { "$schema": "...", "type": "object", "properties": { ... },
               "additionalProperties": false },
  "application": "immediate"           // fallback timing for every property
}
```

**Per-property metadata** lives in the schema, under `x-config`:

| key | meaning |
|---|---|
| `title`, `description` | label/help for a generated form |
| `secret` | write-only: reads report `set: true`, never the value |
| `readOnly` | excluded from patches (counters, caches, derived state) |
| `application` | `immediate` \| `next turn` \| `next conversation` \| `component restart` — **required, no default** |
| `default` (JSON Schema) | the value used when the owner has no explicit value |

`scope` other than `instance` is refused today: shared settings need the
shared-namespace decision that [CONFIG.md](CONFIG.md) §11.7 deliberately left
open, and a store document is already instance-scoped.

## Tools

| tool | effect | approval | notes |
|---|---|---|---|
| `config_declare` | write | no | hidden; internal infrastructure, like `instance_register`. Records a declaration; never grants authority |
| `config_list` | read | no | on-demand; domains, titles, owner availability |
| `config_get` | read | no | values, defaults, revision, schema, secrets redacted |
| `config_patch` | write | **always** | merge patch, validated, revision-checked |
| `config_reset` | write | **always** | drop explicit values |

## Rules

1. **The owner is the only writer.** `config_patch`/`config_reset` forward to
   the declaration's `ownerTool`; `config` never writes an owner's store
   document. A component owning no state (`ownerTool: ""`) refuses mutation.
2. **Validate before apply.** The patch is checked against the declaration's
   schema subset (`type`, `properties`, `required`, `enum`, `minimum`,
   `maximum`, `minLength`, `maxLength`, `additionalProperties`) and against
   `readOnly`/`secret` rules. An unsupported keyword in a declaration is
   refused at declare time — silently ignoring a constraint would report a
   validation that never happened.
3. **Revisions.** `config_patch` takes `expectRev`; the owner performs the
   compare-and-set. `config_get` reports the current revision so a UI can pin
   it. A stale revision is a normal `rev-conflict` error, never a lost update.
4. **Secrets.** A `secret` property is redacted on read (`{"set": true}`), its
   default is not reported, and `config_patch` accepts a value without echoing
   it. Unsetting a secret needs an explicit `null`.
5. **Owner unavailable.** The declaration stays listable (it is durable), but
   `config_get`/`config_patch` report the owner as unavailable rather than
   inventing values. No silent fallback to defaults.
6. **Timing is reported, not enforced by config — but it is REQUIRED.** The
   owner decides what a value means; `config` refuses a declaration that omits
   `application`, because a silent "immediate" default let an owner promise
   more than it delivered (observe captures its byte caps at creation and must
   say `component restart`). Both owner helpers make it a typed argument
   (`Application` in Nim, `Declaration.Application` in Go).
7. **No prompt content.** No config value enters a frozen prefix; a change is
   visible at the owner's next call (C5, prompt-cache discipline).
8. **Scope is organisation, not authorization** (§11.6.2): approval gates the
   mutation, the bus itself is trusted.

## The rule that decides whether a variable may be a domain

Before exposing a variable, find who **enforces** it:
`rg -n 'NIF_YOUR_VAR' core/ sdk/`. If core reads it too, a component-level
domain is a lie — the stored value changes a mirror and not the rule. That is
how the `agent.delegation` slice failed: `maxDepth` is enforced in
`core/dispatch.nim` (whose comment explains the check cannot live in the
component's handler) and `wakes` in `core/conversation.nim`. Secrets,
deployment paths, subscription sets and test seams stay in env by category.

## Owner helper (Nim)

`sdk/niffler/configowner.nim` is the owner half, deliberately wire-free so it
needs no envelope, store-contract or cross-SDK change:

| helper | purpose |
|---|---|
| `OwnerStore(kind, id)` | where the owner keeps its values (`{"values": {...}}`) |
| `ownerOp(store, args)` | answers `get`/`patch`/`reset`, with compare-and-set |
| `declareConfig(declaration)` | idempotent, best-effort declaration after registration |
| `settingStr/Bool/Int(values, name, envName, dflt)` | one setting: **stored value > env > default** |

| `newOwnerSnapshot` / `watchConfig` | for owners whose values are read deep in code with no component handle |
| `ownerToolSchema` | the hidden schema every owner tool shares |

Rules the helper encodes, each learned the hard way:

- **Declare after `comp.run()`'s registration**, from the idle seam — a request
  issued before the component is on the bus has no connection.
- **An explicit `null` in a patch unsets a value.** That is how a secret is
  cleared; it is not the same as omitting the property.
- **Never block in the idle seam.** It runs on the main pump thread, so a
  blocking request there starves every message the component owes. This bit
  twice: a store read per tick stalled for the full store timeout in a
  component run WITHOUT a harness (every component contract test starts
  components standalone, which is why the suite caught it), and a 10s
  declaration timeout per tick starved `observe`'s tap delivery outright. The
  seam now does one short best-effort declaration and nothing else.
  Note what this is NOT: a running harness always has a store — `store` is
  `required: true` and autostarted, and the config component depends on it.
  The storeless case is a component standing alone, which components must
  tolerate (their tools report "store unreachable" instead of hanging), not a
  harness configuration anyone runs on purpose.
- **Owners learn about changes by EVENT, not by polling.** `config` publishes
  `ev.config.updated {domain, owner, rev}` after every applied change, and
  `watchConfig` reloads the snapshot from that handler. Polling was the earlier
  design; the event is free when nothing changes.

Two consequences worth stating: a component that misses the event keeps its
last values until its next real read (no correctness hole — the values are a
cache of the owner's record), and a publish failure can never fail a mutation
that already succeeded.

The env fallback is the migration path: while an owner's variable exists,
`stored > env > default` means a stored choice wins and an existing deployment
keeps working unchanged.

## Declaration lifecycle

Owners declare at startup (idempotent: same `domain` replaces the declaration,
`version` bumps are the owner's choice). `config_list` therefore distinguishes:

- **owner live, declaration present** — fully usable;
- **owner gone, declaration present** — listable, mutations refused;
- **nothing declared** — the domain does not exist; a component that never
  declared is not configured through this surface.
