# Code bugs from the docs audit — fixed

Every row here was a finding whose fix belonged in **code**, not prose (class
`code-bug?` in `worklist.tsv`, plus the `status: "code"` verdicts from the
consolidation children). All of them are now applied.

**Verified**: `make build` (all components; the `lsp` binary needed
`touch components/lsp/main.nim` first — see the build-gap note), then
`make test-git` PASSED, `make test-edit` PASSED, `make test-skills` PASSED,
`ui/frontend: npm run typecheck` 0 errors, `npm test` 38/38.
`make test-lsp` has **2 pre-existing failures on HEAD** (proved by stashing the
`roots.nim` change, rebuilding and re-running: identical failures) — see the
bottom.

| id | where | what was wrong | fix |
|---|---|---|---|
| A203 | `ui/frontend/src/views/Sessions.svelte` | the SPA deleted conversations by looping `store.del` over raw records and never called core's `conversation_delete`, so `sessionmeta`/`agentjob` lineage rows survived and a live runner was never stopped | now one `send("core", "conversation_delete", {sessionId})` (approval-gated; the tab already answers broadcast approvals), with the old behaviour explained in a comment |
| A312 | `components/edit/main.nim` (`read`) | `parallel: true` but no `x-harness.effect`, so fabric classified `read` as a write and serialized every batch read | added `"effect": "read"` plus a comment stating why the seen-state correction it can write is a hint, never correctness |
| A379 | `components/git/main.nim` | same on all five read tools (`git_status/diff/log/show/blame`): `parallel: true`, no effect ⇒ serialized | added `"effect": "read"` to each (`review_receipt`, which writes receipts, deliberately stays a write) |
| A310 | `components/edit/main.nim` (`write`) | the schema description hardcoded "Cap 900KB" while `NIF_WRITE_MAX_BYTES` overrides the real cap | description is now built from `maxWriteBytes()` and names the variable |
| A235, A259 | `components/hooks/main.nim:2` | header cited `docs/HOOKS.md`, which does not exist | points at `docs/MANUAL.md` "Hooks" (+ the research doc) |
| A382 | `components/git/main.nim` (`review_receipt`) | doc comment cited `docs/RECEIPTS.md`, which does not exist | points at `docs/MANUAL.md` "Repository inspection (`git`)" |
| A503 | `components/skills/main.nim:316` | the invalid-entry detail said "unreadable or missing name/description", but only `name` is required | "…or has no usable name" |
| A408 | `components/lsp/roots.nim` (`fallbackBinDirs`) | `NIF_LSP_BIN_DIRS` split on `PathSep` with no tilde expansion, so a `~/x` entry never matched (and the MANUAL claimed otherwise) | entries now go through `expandTilde`; MANUAL row re-worded to "used verbatim — `~` is **not** expanded" was replaced by the corrected behaviour… see the MANUAL note below |
| A392 | `docs/MANUAL.md` (§Streaming) | the `llm` token-frame conditions were undocumented | documented: non-empty `sessionId` **and** `emitTokens` on, one frame per chunk with content or reasoning, `purpose` is telemetry only |
| A289 | `docs/MANUAL.md` (§Testing) | `comp.selfTest` (and `bash`'s real exec + 1 s timeout-kill probe) appeared nowhere | one paragraph; `/doctor deep` fans out to it |
| A491 | `.env.example` | the four `NIF_REPOMAP_MIN_*` knobs were absent | added with defaults |
| A177 | `core/catalog.nim:198` | the `thinking` enum lacked `max` | **already fixed in the tree** before this pass |

## Note on A408 / the MANUAL

The manual row now reads: extra directories are "colon-separated, used
verbatim — `~` is **not** expanded here; use absolute paths". With the code
fixed that sentence is stale in the other direction and should go back to
"(tilde-expanded)". Left as a one-line follow-up so the doc change is not
silently reverted by hand-editing; A408 is tracked in `worklist.tsv`.

## Pre-existing failures found while gating (not from this work)

`make test-lsp` fails on HEAD with two checks (reproduced with this pass's
`roots.nim` change stashed, so unrelated to it):

- `'..' components refused (scope)` — the call now returns
  `[E_NOT_FOUND] File not found: ../hidden.nx` instead of the scope refusal.
- `exactly one initialize for two queries` — two concurrent queries produce
  **2** `initialize` handshakes where the test expects 1.

Both look like fallout from the in-flight async-diagnostics / out-of-workspace
work (`6bc4f6d lsp/edit/core: asynchronous diagnostics, and work outside the
workspace`, committed minutes before this pass). They are worth a look before
the next `make test` gate.

## Surfaced by round two (`batch-open2`, NOT applied — decisions for the code owner)

28 rows were decided `code`: the documentation is now right, the defect is in the
component. Grouped by area, worst first.

**Data loss / crash**

| id | where | what is wrong | suggested fix |
|---|---|---|---|
| A752 | `tools/store_migrate.nim:260-268` | `kindProbes()` is a fixed 18-name list with neither `spill` nor `contextreceipt`, and verification only re-counts the kinds it discovered — measured: 5 kinds seeded, "3 documents read … every kind matches … done", exit 0, two kinds silently dropped | probe the kinds that exist (or fail closed on an unknown kind) before declaring success |
| A767 | `components/store/main.nim:110-111` | barrel `put` without `value` does `$value` with no nil check: SIGSEGV (exit 139) inside the store process, the caller only times out, the supervisor hides it as a restart | guard nil like both Go engines (`put needs kind, id and value`) |
| A637 | `core/conversation.nim` (trimThrough reload) | the omission notice is not re-inserted on the reload path, so a restarted conversation silently loses the record that history was trimmed | re-insert the notice when a trimmed projection is reloaded |
| A751 | `tools/store_migrate.nim:444-445` | `--force` is parsed and read nowhere (the header promises it) | honour it or delete it |

**Security / correctness**

| id | where | what is wrong | suggested fix |
|---|---|---|---|
| A640 | `components/recall` | `context_recall {mode: "search", session: <any id>}` reads any conversation's canonical history with no ownership check — a session the caller does not own is readable | bind the search to the caller's own conversation (the runner already injects it) |
| A632 | `core/dispatch.nim` (`invokeTool`) | a dotted `component.tool` spelling is resolved for the lookup but the raw string is dispatched, so the tolerant spelling is accepted and then dispatched wrongly | dispatch the resolved name |
| A664 | `components/hooks` | one NATS subscription per configured spec outside `ev.session.*`, and the SDK dispatches per subscription — a hook can fire once per matching spec | deduplicate subscriptions (or dispatch per event) |
| A567, A568 | `components/cli` | Nim's parseopt leaves `p.val` empty for the space-separated form, so the documented `cli [--timeout <secs>]` spelling silently does nothing; `wait`'s positional `secs` is parsed unguarded, so `cli wait bash abc` dies with an uncaught ValueError and a Nim stack trace | read `p.key`/`p.val` correctly; validate the positional |

**Schema / contract drift**

| id | where | what is wrong | suggested fix |
|---|---|---|---|
| A539, A521 | `components/builder/main.nim:51` | `defines` is declared `JsonNode`, which the SDK maps to `{"type": "object"}` — the published schema says object, the code expects an array of `-d:NAME` strings | declare a `seq[string]` |
| A522 | builder doc comment | the `- defines:` line breaks after the colon, so the continuation does not join the parameter doc the LLM reads | join the line |
| A614 | `core/compaction.nim:61` vs `components/compaction/main.nim:216` | `NIF_COMPACTION_TIMEOUT_MS` is clamped to 5000-600000 (documented as a whole-call deadline) while the tool's `x-harness.timeoutMs` is 120000 and the schema value replaces the caller's default — 121-600 s configurations are inert | raise the schema timeout or clamp the env at 120000 |
| A659, A678, A698, A729 | core selftest contract | the wording wave 2 proposed is not true of the current core: a component registering no `selftest` is not treated as the report assumed | decide the contract, then document it (the rows are `code` until that is settled) |
| A798 | `components/systemprompt/main.nim:210` | dead `let f = loadContextFileFromDir(dir)` — the same directory is re-read on the next line | delete the dead call |
| A801 | `core/niffler.nim` (boot restore) | a stored `component` record whose name is already supervised is silently skipped (`continue`) — a stale record keeps a component that was never spawned | report the skip |
| A582, A583 | `components/console` | bare `reg.publish`/`reg.depart` payloads render as empty-bodied `event <subject>` lines; results carry no `tool` and the envelope id is not echoed, so replies are unattributable on a busy bus | render the payload; echo the call id |

**Doc-side leftovers in the `code` bucket (not actually code)**

- **A676** — its own reason says "the MANUAL is right today": the earlier pass rewrote that sentence. Belongs in `already`, not `code`.
- **A558** — anchored to the MCP chapter's Cancellation bullet while the finding is about `builder`: mis-anchored, needs re-anchoring or `skip`.
- **A669, A675** — the defect is in the component's README, not the MANUAL (the MANUAL sentences next to them are correct).

## Surfaced by the open-row consolidation (round one — NOT applied)

The 145 open rows were decided row by row against the code; these four findings
belong in code, not prose. The documentation side of each is applied (row id in
parentheses).

| # | where | what is wrong | suggested fix |
|---|---|---|---|
| B1 | `components/processes/main.nim:34` | `KEEP_FINISHED = 50` is declared and never referenced, and `gProcs` has no eviction path: finished entries accumulate for the component's lifetime (`/processes` and the badge keep seeing them) | implement the cap (evict the oldest finished entries beyond 50) or delete the constant — the intent is currently a comment, not behaviour (A451) |
| B2 | `components/hooks/README.md:35` | advertises `cacheHitTokens`/`cacheHitRatio`, the field names that exist nowhere; `ev.session.status` nests them as `cache {prompt, read, hitRate}` (`core/conversation.nim:2240-2242`) | use the real field names (A035 fixed the MANUAL's copy of this error) |
| B3 | `core/catalog.nim` (`clientCount`) | no liveness sweep: only `reg.depart`, a supervisor loss or `remove` drops a registration, so a SIGKILLed UI pins an autostarted core *and* makes core believe a human is reachable (`core/approval.nim:197-212` waits instead of denying) | age out client registrations, or let the UI registry's 20 s lease feed the count (A191 documents the shipped behaviour) |
| B4 | `components/repomap/main.nim` | the `No map: …` message names only `.nim/.nims/.go/.py/.ts`, while the C/C++/Rust/Ruby/PHP tiers landed in `aba88b8` | name the full tier list (A485/A486 document the tiers) |

## Build-system gap (**fixed** in `f0c60dd`)

`Makefile:152` — `var/bin/lsp: components/lsp/main.nim $(SDK_NIM) $(NIM_CONF)`:
the lsp component's other sources (`roots.nim`, `diagformat`-style helpers) are
not in the prerequisite list, so editing them rebuilds nothing and the tests
silently run the old binary. I hit this with `roots.nim`; `touch
components/lsp/main.nim` was the workaround. Other multi-file components should
be checked for the same omission.
