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
| `application` | `immediate` \| `next turn` \| `next conversation` \| `component restart` |
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
6. **Timing is reported, not enforced by config.** `application` tells the
   caller when a change takes effect; the owner decides what that means.
7. **No prompt content.** No config value enters a frozen prefix; a change is
   visible at the owner's next call (C5, prompt-cache discipline).
8. **Scope is organisation, not authorization** (§11.6.2): approval gates the
   mutation, the bus itself is trusted.

## Declaration lifecycle

Owners declare at startup (idempotent: same `domain` replaces the declaration,
`version` bumps are the owner's choice). `config_list` therefore distinguishes:

- **owner live, declaration present** — fully usable;
- **owner gone, declaration present** — listable, mutations refused;
- **nothing declared** — the domain does not exist; a component that never
  declared is not configured through this surface.
