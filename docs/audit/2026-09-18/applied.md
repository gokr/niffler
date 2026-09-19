# Applied — parent batch (layout, state & configuration)

Repo: `/home/gokr/git/nifflerprod` @ `6bc4f6d` + working tree. English
`MANUAL.md` only (the zh manuals lag by design; re-sync separately).

37 rows of `sections/layout-of-a-running-system.md` and
`sections/state-and-configuration.md` were reviewed against the current tree.
`docs/MANUAL.md` grew 2373 → 2400 lines; `git diff --stat docs/MANUAL.md`
shows the change.

## Applied

| id | what changed |
|---|---|
| A001, A141 | `components/` row: 22-name enumeration → "one directory per component … the inventory is the [Shipped components] table" |
| A002, A020, A372 | `var/` table: added `toolout/`, `approval-sources/`, `mcp-results/`, `review-receipts/`, `fabric-cache/`, `plugins/`, `models/`, `processes/`, `repomap-tags/`, `fetch/` rows |
| A003 | `core/` row names `conversation.nim` (turn loop, largest module) + `compaction/approval/retry/uireg/tty` |
| A005 | `builder` row: `build {lang, name, source, files?, defines?}` (approval-gated, on demand) + `info`; Nim/Go/**TypeScript** |
| A051 | §Subscription OAuth: a started flow expires after 15 min, `provider_oauth_start` returns `expiresAt` (`components/provider/oauth.go:29,244-250`) |
| A106 | §Store engines: "file-backed engines (`sqlite`, `barrel`) … `tidb` has no file to lock" (the sentence contradicted the tidb bullet) |
| A178 | §Session runners: the forward is asynchronous (core's pump owns the inbox); readiness = runner in the catalog, polled up to 10 s (`core/conversation.nim:2858-2901,2948-2953`) |
| A181 | §Session runners: the runner writes the conversation header at startup (`core/session.nim:142`) |
| A184 | §Session runners: `conversation_delete` — stops the runner first, then header/messages/toolset/lineage/jobs (`core/dispatch.nim:406-461`) |
| A242, A256 | §Store `list`: `limit` default 100 (clamped 1000), `after` exclusive, `nextAfter` absent when `hasMore` is false |
| A250 | typo "an `nextAfter`" → "a `nextAfter`" |
| A277 | `bash` row: spill path is `var/toolout/` (absolute, in `spill.path`, 1 h sweep) — was "a temp file" |
| A279 | `bash` row: exit codes 126 (cwd / not executable), 127 (no `bash`), 139/143 (128 + signal) added |
| A297, A304, A305 | `edit` row: `edits[]` multi-edit, the named fallback cascade (… Levenshtein ≥ 0.65), `write` semantics + `NIF_WRITE_MAX_BYTES` = 900000 |
| A404 | `lsp` row: added `warmup`, `lsp_servers`, `lsp_registry` (approval-gated) |
| A019, A110, A264 | env-at-boot: `.env` change = `core.kill`/`core.spawn`, but a variable exported in core's shell needs a harness restart (state table + hooks row) |
| A021 | state table: the compiled-in `(baked)` skills tree as the last resort |
| A022 | precedence paragraph: markers are `lsp`/`repomap` only, with their real build-file sets; `skills` uses fixed dirs |
| A027 | `.env` hardening: regular file only, 1 MiB cap, no `$VAR` expansion |
| A105 | `.env` loading: SDKs (cwd first) vs the UI bridge (root first, `ui/bridge.go:71`) — the "identical" claim was wrong |
| A464 | store kind table: provider credentials are **plaintext** at rest (redaction is response-only) |

## Skipped (verified correct)

A008 (grep replicas), A023, A038 (compaction contract), A185 (Makefile builds
`var/bin/session`), A008/A023/A038/A185 class `verified`.

## Already fixed by the 13:31 docs pass, or by code that moved

- A211 — §Approvals already lists bare `spawn`/`kill`/`remove` and
  `conversation_delete`.
- A460 — `var/processes/` spool naming (`pN.out`/`pN.err`, boot wipe) is a
  half-line detail; left for the processes section pass.
- A250 (2nd half) — the `#` comment markers in the bus block are inconsistent
  but intentional; no change.

## Deferred

- **A017, A018, A152** — trim recommendations: the store-engine *rationale*
  and the `niffler-store-migrate` flag walkthrough belong in
  `research/STORE_V2.md`; keep the selection table + the "switching does not
  migrate" warning. This is the (Z) pass, not a wording fix.
- **A257** — the bus block's `ev.*` subject inventory is incomplete
  (`ev.log.*`, `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`,
  `ev.fabric.*`); belongs with the observation/`ev.*` section pass.

## Subagent edit sets, applied

Six children wrote their edit sets before their turns were cut (the
incremental-write steer worked; batch-4 produced nothing). Applied with
`apply_edits.py`, which validates every `old_string` (exactly one occurrence)
*before* writing, then applies in id order — all-or-nothing, so a collision
aborts the batch instead of half-applying it. `edits/applied-ids.txt` is the
authoritative list of what landed, and `status.py` folds it together with the
verdicts:

```
ledger rows: 515
  applied                185
  open                   145
  decided:skip           125
  decided:already         45
  code                     9
  unclear                  6
```

| set | rows applied | highlights |
|---|---|---|
| batch-7 | 15 | lsp result cap is 16 000 *characters*; store kind table + paging cross-link; `recovery` recipe names `manifest.yaml`/`Makefile`; the hooks chapter (payload cap, temp-file hand-off, 100 ms clamp floor, exit 124, first-match-wins, where failures land, `off by default` = autostart-only) |
| batch-8 | 27 | **new chapter** `## Repository inspection (git)`; session-runner semantics; restart policy + backoff (1 s doubling to 8 s); lsp registry/refusal/budget details; mcp (`mcp_search`, the unenforced `≤100` claim removed, deferred tool sets) |
| batch-5a | 18 | `edit` staleness gate / undo store / read caps / unchanged-read stub; env rows (script-only knobs, `NIF_AUTO_APPROVE` implying `/limit` continue, provider object fields, retry-after parsing, `NIF_MODELS_OFFLINE` ≠ offline seed) |
| batch-1 | 26 of 60 | skills frontmatter/licence/shadowing, `repo>` — *partial*: the child was cut before it finished its slices |
| batch-3 | 22 of 60 | fetch and the common-tasks rows — *partial* |
| batch-5b | 28 of 28 | fabric/provider/environment set |
| batch-2 (lean retry) | 19 of 59 apply | mixed; 24 rows were already fixed by earlier sets |
| batch-6 (lean retry) | 36 of 59 apply | models catalog, repomap, provider registry, skills precedence |

Two corrections the children caught that the parent pass had left wrong: the
skill-tree precedence is **project > bundled > home > config** (A499 — my
owing edit had said "home shadows bundled"), and the store tool docstrings
still advertise a three-kind list (A247, filed as a code note).

`docs/MANUAL.md` is now 2839 lines (+466), with one new `## ` chapter and four
new `### ` sections.

## Still open (145 rows)

`python3 status.py --open` lists them per section. The clusters are the sets
that never delivered: `component: expert` (18), `Starting and stopping` (13),
`Context window` (12), `component: llm` (12), `component: provider` (10),
`Background processes` (9), `Fabric and subagents` (9) — i.e. what batch-4
never wrote and what batches 1/3 were cut before reaching — plus the deferred
`Layout` rows (A017/A018/A152 trims, A257 `ev.*` inventory) and the 6
deliberately `unclear` repomap rows.

## Code bugs — fixed

All of the code-side rows were fixed in this pass; `code-bugs.md` carries the
per-row detail, the verification commands and the two pre-existing `test-lsp`
failures found while gating. Source files touched: `components/edit/main.nim`
(`read` effect, dynamic `write` cap), `components/git/main.nim` (five read
tools' effect, doc pointer), `components/hooks/main.nim` (doc pointer),
`components/skills/main.nim` (invalid-entry wording), `components/lsp/roots.nim`
(tilde expansion), `ui/frontend/src/views/Sessions.svelte` (delete through
`conversation_delete`), plus the `llm` streaming and `/doctor deep` paragraphs in
the MANUAL.

Gates run: `make build`; `make test-git|edit|skills` PASSED; `npm run
typecheck` 0 errors; `npm test` 38/38. `make test-lsp` fails 2 checks that are
**pre-existing on HEAD** (proved with this pass's change stashed).

## Code-bug candidates surfaced by this batch

None of these rows required a code change; all were documentation drift. The
code-bug list is maintained in the batch summaries (`edits/batch-N.summary.md`).

## Open-row consolidation — `batch-open-1..6` (applied)

The 145 rows `status.py --open` still listed were split by section across six
children. Each re-verified its rows against the then-current MANUAL (2850 lines)
and the code, and wrote `edits/batch-open-<N>.json`. Applied in one pass by
`apply_edits.py` (all-or-nothing, id order):

| | |
|---|---:|
| apply | 71 |
| already | 60 |
| skip | 20 |

`docs/MANUAL.md` 2850 → 3072 lines. The ledger is now **applied 256 / decided
105 / skip 145 / code 9 — no open rows**.

| set | sections | rows |
|---|---|---:|
| batch-open-1 | component: expert, component: provider | 28 |
| batch-open-2 | Starting and stopping, Context window | 25 |
| batch-open-3 | component: llm, Background processes, observations and logs | 28 |
| batch-open-4 | Fabric and subagents, component: processes, The bus in one screen | 23 |
| batch-open-5 | Layout, Shipped components (×2), component: repomap | 24 |
| batch-open-6 | false-claim slices, State/configuration, System prompt, Common tasks, Contents | 23 |

**Cross-batch overlap.** Two rows turned out to be duplicate fixes of paragraphs
another set had already rewritten. Found by simulating the whole pass in id
order *before* applying — a check no single child could make, since each proved
its anchors against a MANUAL no sibling had edited:

- `A112` ⊂ `A035` — both fix the status-event paragraph (the fields are
  `cache {prompt, read, hitRate}`, not `cacheHitTokens`/`cacheHitRatio`). A035's
  draft also claimed the web UI shows a percentage; A112's evidence says
  otherwise, so A035's parenthetical was corrected with it (web UI: `⚡
  <cached>/<prompt>` numbers per message plus the split in `/info`; TUI chip:
  `cache NN%`). A112 is `already`/superseded.
- `A208` ⊂ `A191` — both state that the autostarted core counts `reg.publish`
  `client` registrations, not the 20 s `ui` lease, and that a SIGKILLed client
  pins the core (and core's approval reachability) until the catalog drops it.
  A191 says it in the same paragraph; A208 is `already`/superseded.

Both supersessions carry their reasoning in the row's `status`/`reason`, so the
record shows why an `apply` row did not land. One manual repair followed the
apply: A035's patch had leaked a process note into the prose and one paragraph
ran long — both fixed by hand in `docs/MANUAL.md` and in the source row.

## Round two — `batch-open2-1..8` (applied)

The second wave's 307 still-open rows, split by `partition_open.py` into eight
balanced batches (that script slices only what `status.py` reports open, so
round one's `batch-N.txt` record is untouched). Each child re-verified against
the current MANUAL and the code, then wrote `edits/batch-open2-<N>.json`:

| | |
|---|---:|
| apply | 146 |
| already | 85 |
| code (see code-bugs.md) | 28 |
| skip | 48 |

The round was verified as a *round* before applying — `simulate_round.py`,
written for this: every anchor unique, and still unique after the earlier rows
of the round have landed, no duplicate ids, no drafting apparatus in a proposed
`new_string`, a warning when the MANUAL has moved past
`edits/anchor-revision.txt`. It applies in id order exactly as `apply_edits.py`
does, so a collision is found before a single byte is written. Verdict:
**146/146, MANUAL 3082 → 3448 lines**, then two hand repairs (below).

**What the round-level check caught that no child could:**

- **A784 ⊂ A547** — a genuine collision, not a duplicate: A547 (open2-4) rewrites
the same sentence and does not keep A784's wording, so in id order A784's anchor
is gone before it is reached. Re-anchored past A547's replacement, with its
`new_string` rewritten so it cannot reintroduce the pre-A547 text and silently
undo A547. (The A579/A584 pair *is* order-independent — that child deliberately
kept the shared sentence verbatim — which is why the check reports collisions
rather than assuming them.)
- **Two of my own checks were wrong**, both fixed: the simulator's apply loop
read `new` from the leakage-check loop above it (a Python scoping leak), so every
row was replaced by the last row's text — that manufactured `−91 lines` and three
phantom failures; and the leakage guard flagged the word "superseded" in
legitimate prose about checkpoints. A check that is itself wrong is worse than no
check: it launders a wrong claim.

**Hand repairs after the apply** (both recorded here because they are edits to
text a row produced): the TOC entry `[Search (`grep`)](#search-grep)` dangled —
the section is `### `grep` in detail` — so it now points at `#grep-in-detail`;
and the "Build and script knobs" note, already one 512-character line before the
round, had grown to 865 and is re-wrapped. Final state: 3459 lines, 29 `##`
headings, **no broken internal links**, no ledger ids in the prose, fences
balanced.
