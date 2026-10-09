# Write arbitration and the evidence ledger — two proposals

> Design proposals. **Nothing implemented.** Two related holes, one ordering:
> A is a correctness fix, B is what makes A's receipts useful, and the eval
> harness (PLAN.md "Current priorities") is what stops either being asserted
> rather than measured. Open work has one home — [../PLAN.md](../PLAN.md).

Baseline: `main` at `e3fb00c` (2026-10-09).

## The one-paragraph statement of both

Nothing arbitrates filesystem writes: several conversations can share one
workspace, parallel dispatch is shipped, and `core/workspace.nim` declares a
working *set* (primary + worktrees + same-origin siblings). Two session runners
can therefore edit one file and the only artifact of the collision is whichever
write landed last. Separately, a subagent settles with **prose**: the completion
tap extracts the child's final reply and `resolveStale` derives whether the *job*
finished, never whether the *claims inside the reply* are true. Proposal A gives
writes an owner; Proposal B adjudicates claims against what the host actually
observed, and A is what makes B's most valuable column ("paths it really wrote")
a fact rather than an inference.

---

# Proposal A — write arbitration between concurrent writers

## A.1 The problem, precisely

`core/dispatch.nim`'s leases (`NestedLease`) are the **nested-call proxy**:
per-call, in-memory, keyed by lease id, validating that a nested call re-enters
through the live session lease. They are not filesystem ownership. Meanwhile the
things that *create* concurrent writers all shipped:

- parallel tool dispatch over distinct NATS inboxes (`x-harness.parallel`),
- several conversations sharing one workspace root,
- `core/workspace.nim`'s workspace set — primary + linked git worktrees +
  same-origin sibling checkouts, capped at `maxWorkspaceRoots = 8`.

There is no owner, no conflict signal and no way for a conversation to learn
another is mid-edit. The failure is silent by construction: both writes succeed,
the last one wins, and neither model can tell.

## A.2 Enforce at the dispatch gate; arbitrate in a peer component

Core's dispatch is the one place that sees every call *and* has the resolved
paths: `workspaceRootsFor(ct)` (`core/dispatch.nim:1556`) caches the set and
`pathInWorkspace` (line 1581) validates against it. The gate already hosts
`noSpawn` and `x-harness.approval`. This is that seam — no new pipeline, no
component-name switch in core.

### A.2.1 Declare the writer class in the schema (data, not code)

A new extension, sibling to `x-harness.effect`:

```jsonc
"x-harness.writes": {"paths": ["path", "target"]}   // path-bound writer
"x-harness.writes": {"root": true}                  // opaque writer
```

- **path-bound** — `edit`, `write`, `replace_across`: the named args hold file
  paths, resolved the same way `x-harness.workspace.pathFields` already resolves
  them.
- **opaque** — `bash`, `builder`, `plugins`, `mcp`, `fabric`, `hooks`: the call
  can touch anything under the workspace, so it claims the whole subtree.

This is the AGENTS.md-legal shape: no hardcoded component list in core, no
language knowledge, and a new component declares its own class. A component that
declares nothing is treated as **opaque** — the conservative default, so
forgetting to declare cannot lose protection.

### A.2.2 The `locks` component owns the stripe table

A new peer process, single writer of its own state (the `team`/`store`
precedent — not a core special case, not a store kind core owns).

- **Stripes are path hierarchies, not files.** A claim is the set of ancestor
  stripes plus one exclusive stripe per declared file: `(root)` shared, each file
  exclusive. Reasonix's `internal/workspacelease` is the worked model
  ([REASONIX.md](REASONIX.md) "Workspace write leases").
- **Acquire order is canonical** — sort stripes, ancestors before descendants —
  so two sessions claiming overlapping sets cannot deadlock by ordering.
- **Leases, not locks.** A lease carries
  `{leaseId, sessionId, tool, callId, paths, acquiredAt, ttlMs}`; the TTL is what
  makes a killed runner recoverable instead of wedging the workspace forever.
- **A denial is a normal tool error that names the holder**:
  `E_WRITE_BUSY: <path> is being modified by conversation <id> (edit, 4s ago)`.
  Naming the holder is the difference between a debuggable outcome and a mystery,
  and it enters as an append-only tool result — **no prefix change**.

### A.2.3 Where the lock lives in time

Acquire immediately before dispatch; release when the call completes (the call
id *is* the lease id). Because turns never nest within a conversation, contention
is necessarily cross-conversation — which is the real bug. A bounded wait budget
covers the legitimate case, so two sessions editing *different* files of one repo
still run concurrently: their stripes do not overlap.

### A.2.4 Fail-closed where it matters, fail-open where it does not

- **`locks` absent** (e.g. `--minimal`) → no arbitration, one warning. Making
  absence fatal would break a boot profile for a capability that only matters
  with concurrent writers — the `repomap`-absent posture.
- **`locks` present but unreachable** → **refuse the write**. This is the one case
  where silence is wrong: a lock table existed a moment ago and now a write would
  go unguarded.
- The distinction is stated once, in the component's schema description.

## A.3 Deliberate non-goals

- **No lock vocabulary in the frozen prefix.** The declaration is a schema field
  (frozen once at conversation start — sanctioned); the lock *state* never enters
  the prefix.
- **No core-side lock table.** In-memory in core would die with core and fork the
  component's authority. The bus makes a peer cheap.
- **No host-crossing leases.** Fleet arbitration is a different problem
  ([REMOTE.md](REMOTE.md) §6–7); a write lease is not a distributed-lock project.
- **No mandatory contention avoidance.** Serializing all writers globally would be
  correct and useless; the whole value is that disjoint paths stay parallel.

## A.4 Phasing and the tests that prove it

| phase | scope | test |
|---|---|---|
| 1 | `locks` component + dispatch gate + `edit`/`write` only | two sessions, one file: the second is refused and names the first; two sessions, different files of one repo: both succeed |
| 2 | opaque writers (`bash`, builder, plugins, mcp, fabric) | an opaque writer excludes a path-bound one; disjoint conversations stay parallel |
| 3 | crash/TTL + worktree claims | kill the holder → the lease expires → the next writer proceeds; a worktree root claims independently of the primary |

Effort: phase 1 ≈ 2–3 days (component ≈ 1, gate + schema ≈ 1, tests ≈ ½),
phase 2 ≈ 1 day of declarations plus tests.

**Interaction with a container sandbox** (the `NIF_BASH_SANDBOX_MAP` /
`NIF_BASH_NET` work landing alongside this): a `docker run … -v workspace`
container isolates *what a command can reach*; a write lease isolates *who owns
the file*. They are complementary, not alternatives — and a container that
bind-mounts the workspace **without** taking the root stripe is exactly the
concurrent-writer hazard this fixes. If the sandbox lands first, it must still
take the root stripe.

---

# Proposal B — evidence ledger + host-adjudicated completion claims

## B.1 The problem, precisely

A subagent settles with prose. The completion tap (`components/agent/main.nim`)
extracts the child's final reply; `resolveStale` derives a verdict from the
**transcript**, but that verdict is about whether the job finished — not whether
the claims inside the reply are true. So "I ran the tests and they pass" and "I
ran the tests and they pass, and here is the output" are indistinguishable to the
parent.

Everything needed to adjudicate already exists; it is simply not consulted:

- tool calls persist as `role: "tool"` messages carrying `tool_call_id` and
  `name` (`core/conversation.nim`),
- the `agentjob` record carries per-activation status and reply,
- turn records carry `turnId`/`outcome` as the authoritative per-turn accounting,
- `sessionmeta` holds durable lineage and `activations`.

## B.2 The host, not the child, closes a claim

Derive more, store less.

### B.2.1 Receipts are derived, not a new ledger

A receipt is a projection of records that already exist:
`(tool, normalized-args digest, outcome, mutation paths, exit signal)`. The
transcript walk `resolveStale` and `lastTranscript` already perform produces
them; once the child transcript is read for the verdict, the receipts fall out of
the same pass.

With Proposal A in place, `mutation paths` becomes **authoritative** rather than
inferred — the lock service knows exactly which paths a call claimed. The two
proposals compose: A produces the receipts B needs.

### B.2.2 A child may make a structured claim (optional; appends nothing to the parent)

Reuse the shape already in PLAN ([MAKI-STEAL.md](MAKI-STEAL.md) #6):
`agent_run`/`agent_spawn` gain an optional `output_schema`. The child receives a
session-local `structured_output` tool — added **before its first turn**, so it
freezes into the *child's* prefix and never touches the parent's. Invalid calls
are inline schema errors the child fixes in-run; finishing without calling it gets
at most two nudges, then the ordinary prose reply stands.

### B.2.3 Adjudication is downgrade-only

Against the receipts, each claim is classified:

- `verified` — a receipt supports it (the command was run; the path was written;
  the exit was 0).
- `unverified` — nothing contradicts it, nothing supports it. **Not** a failure.
- `contradicted` — a receipt refutes it (claimed a path it never wrote; claimed a
  passing command whose receipt shows nonzero).

Two rules keep it honest:

- **Only downgrade, never raise.** The host never turns `unverified` into
  `verified`, and never marks a child `failed` merely because a claim is
  unverifiable.
- **`unknown`, never `verified`.** An unreachable store yields `unknown`; a
  missing receipt is never evidence of success — the same discipline as the
  bench's "a response without usage is `unmeasured`, never zero".

### B.2.4 Surface it where the parent already looks

The settlement notice and `agent_status` carry, in this order: **adjudicated
status → child prose → host receipts**. Plus a `false_completions` counter on the
job record — the one number that makes the feature measurable, and the reason to
build it at all.

## B.3 Prompt-cache effect, stated per contributor

| contributor | effect |
|---|---|
| `x-harness.writes` declaration (A) | **frozen prefix** — a schema field; changes once at conversation start |
| `output_schema` / `structured_output` tool (B) | **the child's frozen prefix** — added before its first turn, invisible to the parent |
| adjudication, receipts, counters (B) | **neither** — job record + tool result; append-only at most |

## B.4 Deliberate non-goals

- **No new record kind initially.** If the projection proves insufficient,
  `agentjob` gains one `adjudication` object — not a parallel ledger that can
  drift from the transcript.
- **No claim language in the parent's prefix.** The parent learns the verdict from
  the settlement, which is append-only.
- **Not the permission-rules engine.** Typed permission rules + bash static
  analysis is its own PLAN row; conflating them makes both bigger.
- **No self-reported receipts.** A receipt a child writes about itself is prose
  with extra steps.

## B.5 Phasing and tests

| phase | scope | test |
|---|---|---|
| 1 | receipts + downgrade-only adjudication over **existing prose replies** — no schema change | `t_agent`: a child claims a write it did not make → `contradicted`; claims a passing test that exited nonzero → `contradicted`; an honest plain reply → `unverified`, not failed |
| 2 | optional `output_schema` + the nudge loop | an invalid call is an inline error; a missing call nudges twice then falls back; the child prefix is unchanged after its first turn |
| 3 | `false_completions` counter + the bench arm | the completion-integrity tasks (unsolvable by construction, inverse-contract graders) read the counter against the solve rate |

Effort: phase 1 ≈ 1–2 days (one transcript pass + settlement plumbing),
phase 2 ≈ 1–2 days, phase 3 folds into the eval-harness priority.
