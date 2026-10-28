# SEMANTIC-EDIT — language-server-driven surgical refactoring

> Status: **proposal, not implemented.** This document specifies a generic
> *apply a workspace edit* primitive and the refactoring tools that ride on it.
> It exists because a real defect in this repo was invisible to text editing:
> a regex rename rewrote `%*{"maxBytes": v}` **JSON keys** while missing call
> sites, twice, and no build or test could see it — only a downstream assertion.
>
> Basis: `components/lsp` (0.1.0, seven read operations), `components/edit`
> (0.3.0, exact-match cascade + persisted single-level undo),
> [FAST-APPLY.md](FAST-APPLY.md) §7 (language-specific power arrives as a
> plugin component over a generic seam), [AIDER.md](AIDER.md) §repo-map
> (tree-sitter already models per-language structure as data), and AGENTS.md's
> "language-agnostic core" invariant.

## 0. The insight

A language server already knows what a text substitution cannot:

| Operation | What the server returns | What text editing does instead |
|---|---|---|
| `textDocument/rename` | a `WorkspaceEdit`: every symbol occurrence, **with byte ranges** | renames every matching *string*, including JSON keys, comments, log messages |
| `textDocument/references` | the same set, read-only | grep, then guess which hits are symbols |
| `documentSymbol` | a typed tree of definitions with ranges | indentation heuristics |

**Verified in this repo, not assumed.** `nimtortoise` reports
`renameProvider: true`. Renaming `maxBytes` at its definition in

```nim
proc maxBytes(): int = 5
let cfg = %*{"maxBytes": 1, "keep": maxBytes()}
```

returns exactly two edits:

```
line 2, chars 5–13  -> budgetBytes     ← the definition
line 3, chars 36–44 -> budgetBytes     ← the call
```

The JSON key at line 3, chars 9–17 is **untouched**. That is the entire value
proposition: the edit set is computed by a parser, and the model never has to
reproduce unchanged text to describe the change.

## 1. Where this belongs (and where it must not)

Keeping `lsp` **read-only** is deliberate and should stay that way. The
component's value is being the generic seam that proves the language-agnostic
invariant: a registry of `{extension → server command}` with no language list
in code. Applying edits would give it transaction semantics, undo, approval
and write claims — and every future language inherits that risk.

The layering:

| Layer | Owner | Knows | Mutates |
|---|---|---|---|
| Language servers | `lsp` (existing) | no language; a registry | never |
| Compute a workspace edit, apply it | **`refactor`** (new) | no language; it *asks* `lsp` | via `edit`'s undo store |
| Text surgery + undo + claims | `edit` (existing) | no language | owns it |

`edit` already calls `lsp` for post-write diagnostics, so a component consuming
`lsp` is established practice, not a new pattern.

**Why not put it in `edit`.** `edit` is the component every session depends on
for reads and writes. An LSP round-trip inside it would make the most
latency-sensitive tool in the system depend on a language server being warm,
and `lsp` can be absent, slow, or configured to nothing. A separate component
keeps `edit`'s failure domain unchanged: if `refactor` is missing or its server
is cold, the model falls back to `edit` and loses nothing.

## 2. The primitive: one tool, one edit set

Everything else in this document is convenience over a single operation.

```
refactor_apply {
  edits: [ {path, start: {line, character}, end: {line, character}, newText} ... ]
  expectedHash: {path: sha256}     # optional but recommended
  label: string                    # "rename maxBytes -> budgetBytes"
}
→ {applied: n, files: [{path, linesChanged, rev}], undone: "undo_last_edit"}
```

Contract points, each grounded in an existing component rule:

- **Coordinates are LSP-shaped** (`line`, `character`, UTF-16 code units,
  zero-based) so a server's output passes through unmodified. The model-facing
  tools take 1-based lines like `edit` does; only `refactor_apply` is raw.
- **Edits apply bottom-up per file**, so earlier ranges never invalidate later
  offsets. Overlapping ranges within a file are refused, exactly as `edit`
  refuses overlapping `old_string` matches.
- **Every edit is verified against the current bytes** before anything is
  written: the original span must equal the text the server believed was there.
  A mismatch is `E_STALE` and refuses the whole set — the same digest rule
  `edit` already enforces via its seen-state.
- **All-or-nothing per call.** A workspace edit is one logical change; a
  partial application across files leaves a repository that compiles nowhere.
  Stage every file, then commit.
- **Undo goes through `edit`'s store** (`edit-undo`, keyed
  `"<session>:<abs path>"`), one entry per touched file, saved *before* writing
  and restored if the write fails. `undo_last_edit` then reverts a rename like
  any other edit — there is no second undo mechanism.
- **Approval + claims.** `approval: "always"`, `effect: "write"`,
  `writes: {paths: ["edits[].path"]}` so two conversations cannot interleave a
  rename. If the claim list cannot be computed from the arguments (it can here:
  the paths are in the call), fall back to `{root: true}`.

## 3. What rides on it

Each is a thin wrapper that asks `lsp` for the edit set and hands it to
`refactor_apply`. None of them contains language knowledge.

| Tool | Server operation | Notes |
|---|---|---|
| `refactor_rename {path, line, character, newName}` | `textDocument/rename` | the motivating case; refuses when the server has no `renameProvider` |
| `refactor_references {path, line, character}` | `textDocument/references` | read-only; the no-new-code fallback that works today |
| `refactor_organize_imports {path}` | `textDocument/codeAction` (kind `source.organizeImports`) | opt-in; servers disagree wildly about what this does |
| `refactor_quickfix {path, line, character}` | `textDocument/codeAction` | surface the server's own fixes as applicable edits |

**Explicitly out of scope for v1:** extract-function/method, move-to-module,
inline. They need `codeAction` with server-specific command payloads and
`workspace/applyEdit` round-trips (server→client requests), which today's `lsp`
pump does not handle — it only *sends*. Doing those honestly means adding a
server-request handler to `lsp`, which is its own slice.

## 4. The hard parts, stated plainly

1. **`workspace/applyEdit` is a server→client request.** `refactor_rename`
   needs only the *result* of `textDocument/rename`, which is plain data — fine
   today. `codeAction` with `isPreferred` command payloads is not. **Decision:
   v1 consumes only operations whose result is data the client applies.** This
   keeps `lsp` read-only in the strict sense (it never mutates, the client does)
   and avoids a protocol extension.

2. **Index staleness.** A server's ranges describe the file as it was when the
   server last read it. If the file changed since, the spans are wrong. The
   `expectedHash` check catches this and refuses — never "best effort" apply.
   `lsp` already does transient `didOpen`/`didClose` per query, so its ranges
   are as fresh as the query; the hash pins the window between query and write.

3. **Servers lie differently.** Each returns its own idea of a
   `WorkspaceEdit`: `changes` (map) vs `documentChanges` (array, versioned).
   Both shapes must be normalized by `lsp` before `refactor` sees them, so the
   tool contract is one shape regardless of server — the same discipline as
   `lsp`'s existing `diagnostics` normalization.

4. **No server, no refactor.** Absent/broken/unsupported must refuse with a
   clear reason naming the server and the missing capability, never fall back
   to text substitution. A silent fallback to regex is exactly the bug that
   motivated this document.

5. **Not every rename is safe.** A server's rename assumes the document set it
   knows. A dynamic `import`/eval/re-export the server cannot see means an
   occurrence is missed. `refactor_rename` should report the edit count and the
   files touched so the model — and the human reading the diff — can sanity
   check scope, and should recommend a build/test after a large one.

## 5. Why this shrinks the model's job

The `FAST-APPLY.md` argument applies directly: the real cost of an edit is
**output tokens per accepted change**. Today a rename means the model emits
every call-site context to anchor `old_string`, or asks for a diff it must get
exactly right. With `refactor_rename` it emits one line and one new name.

Honest A/B for this family is therefore *rounds-to-green* and *cost per task*,
not edit latency — the same conclusion FAST-APPLY.md §7 reaches for fast-apply.
A rename that would have been 800 output tokens becomes ~30.

## 6. Language X, zero code

Adding support for a language is **one registry entry** in `lsp`, which is
already true and already the invariant. Nothing in `refactor`, `edit` or core
learns the language: the writer applies ranges, the compute layer forwards
server output.

A **language-specific** tool (say a Nim-aware "add an exported proc to .nimble")
would be a plugin component speaking this same seam — per FAST-APPLY.md §7 item
3, opt-in and off by default. That is the correct home for per-language power;
it is not a reason to put a `case language` in a shared component.

## 7. Slice plan

1. **`lsp` result normalization** — accept `textDocument/rename` as a
   read-only operation returning a normalized `{files: [{path, edits}]}`
   (handles both `changes` and `documentChanges`). No writing anywhere.
2. **`refactor` component, one tool** — `refactor_apply` over an explicit edit
   set, with hash verification, bottom-up application, `edit`-store undo and
   write claims. Testable with hand-written edit sets; no server needed.
3. **`refactor_rename`** — thin wrapper over slice 1 + slice 2. This is the
   motivating feature and the first end-to-end proof (nimtortoise is installed
   on this machine, so it is testable today).
4. **Docs + a real repair** — run it on a repo-wide rename, record the before/
   after, and correct AGENTS.md's rename guidance from "use an LSP rename" to
   a concrete tool call.

Deliberately *not* in this plan: `codeAction` support, `workspace/applyEdit`
handling, extract/move/inline. They are worth doing after the primitive proves
itself.

## 8. Open questions

- **Should `refactor` apply, or should it hand the edit set to `edit`?** This
  document has it apply directly, reusing `edit`'s *undo store* rather than its
  tool. The alternative — `refactor` computes, the model calls `edit` — is more
  conservative but makes undo two calls and lets a model edit the set in
  transit. Leaning toward applying, since the verification (`expectedHash`) and
  the claim live at the same point as the write.
- **Per-file or per-call undo?** A rename touching 12 files as 12 separate undo
  entries means `undo_last_edit` only reverts one of them. Either record a
  single call-scoped undo group (needs a small `edit` extension) or state
  loudly that a workspace edit is N undos. Leaning toward a call-scoped group.
- **Do diagnostics gate the write?** `edit` already enqueues a post-write
  diagnostic check. A refactor should probably *not* gate on it (a rename
  legitimately breaks call sites in files the server could not see), but it
  should report before/after diagnostic counts when the server has them.
- **What is the failure mode when the workspace is huge?** A repo-wide rename
  can produce thousands of edits. Cap the edit count, cap files touched, and
  refuse rather than half-apply.
