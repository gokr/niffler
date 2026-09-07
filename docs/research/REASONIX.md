# Reasonix — prior-art analysis

> Research note — external codebase analysis, not a plan. Each item below is a
> candidate to become its own plan (or a line in the README quests). The final
> section ranks the ten highest-leverage items for Niffler.
>
> Source: a checkout of [DeepSeek-Reasonix](https://github.com/esengine/DeepSeek-Reasonix)
> (Go, single binary) at `~/git/DeepSeek-Reasonix`, commit `6c2e845b8`
> (2026-09-07). All claims cite `docs/*.md`, `benchmarks/README.md`, or the
> `internal/` package tree of that checkout. Niffler baseline checked against
> this clone's `components/` + `core/` + `docs/MANUAL.md` (2026-09-07).

## What Reasonix is

A community-built Go coding agent: one static binary, four ways in (Bubble
Tea TUI, Wails desktop, HTTP/SSE `serve`, ACP for editors) all sitting behind
one transport-agnostic `control.Controller`. MCP client, plugin packages, an
out-of-process extension sidecar protocol, Ask/Auto/Yolo permission postures,
and — the part that matters most — an unusually deep engineering culture
around three things Niffler also cares about:

1. **Prompt-cache discipline** (byte-stable system prompt + tool surface,
   canonical append-only transcript, projections instead of rewrites) — same
   religion as Niffler's frozen prefix, enforced with contract tests.
2. **Evidence** — the host records receipts of what tools actually did, and
   every completion claim is adjudicated against those receipts.
3. **Measurement** — a full LLM-behavior eval harness with honest-negative
   tasks, request-boundary metering, fault injection, and ablation arms.

Unlike CodeWhale (one process, the turn loop in the TUI crate), Reasonix is
conventionally layered (`cli → control → agent/provider/tool`), so most
mechanisms port to Niffler with an obvious home component.

## Already covered in Niffler (checked — don't re-import)

| Reasonix | Niffler equivalent |
|---|---|
| `use_capability` fixed-schema proxy for optional tools | `discover`/`invoke` + `x-harness.onDemand` (Niffler's version even keeps the frozen prefix) |
| `fleet`/`parallel_tasks` programmatic orchestration | `fabric` (more expressive; weaker in validated safety shape) |
| `task`/background subagents + steering | `agent_run`/`agent_spawn`/`agent_steer`/`agent_wait` |
| two-model planner (proactive, deterministic routing) | `expert` advisory peer (reactive judge — a different beast, worth a design note, not a port) |
| skills/commands | `skills` component |
| canonical transcript storage | `store` (kinds `conversation`/`message`) |
| local telemetry/logs | `observe` + `logfile` |
| multi_edit, diff rendering, persisted undo | `edit` (single-level, per-file) |
| frozen prompt-cache prefix | Niffler's frozen system prompt + frozen direct toolset — stricter than Reasonix's |
| hooks (observe subset) | `hooks` component (deliberately observe-only) |
| config-driven providers/models | `provider`/`models` components |
| workspace pinning per session | session `cwd` pinning in core |

## Tier 1 — directly applicable, high value

### 1. Bounded tool results + paged full re-read → `core/dispatch` + store

Tool results are frozen at ≤32 KiB provider-visible `Content`; the full
original is kept locally as `RawContent`. The model pulls full text back
through a stable capability (`session:tool_result`) paged by UTF-8 byte
offset, each response carrying `result_ref`, total bytes, full SHA-256,
`next_offset`, and a `complete` flag (`docs/research/cache-aware-compaction-design.md`,
`docs/TOOL_CONTRACT.md`). This fixes both context burn *and* the subtle
failure where a large result would later have to change the cached prefix.
Niffler today sends full tool results (its only truncation is store list
caps). Natural home: a store kind for oversized payloads + one hidden
session-surface tool.

### 2. Evidence ledger & host-adjudicated completion claims → `core` + `agent`

Subagents close via `complete_step`/`complete_subtask` claims carrying
acceptance criteria; the host checks every citation against its **own
receipts** (was that command actually run? was that path actually written?)
and *downgrades* unverifiable claims, printing why — it never raises a status
(`docs/SPEC.md` §3.11–3.12, `internal/evidence`). `false_completions` is a
first-class counter. The parent receives, in order: adjudicated status,
child prose, host receipts. Cheap to build on Niffler's dispatch records;
the single most honest metric available for subagent work.

### 3. Permission rules engine + static bash analysis → `core/dispatch` approval layer

`deny > ask > allow > fallback` with subject rules: `Bash(go test:*)` prefix
(later commands introducing shell operators are rejected from prefix
coverage), `Bash=<literal>` exact-match, `Edit(docs/**)` path globs;
approvals persist *as rules* (once / session / always); headless postures
fail closed (docs/TOOL_APPROVAL_MODES.md, docs/SPEC.md §3.7, `internal/permission`,
`internal/shellsafe`/`shellparse`). The static analyzer classifies dynamic
bash (parameter/arithmetic expansion, heredocs, unproved redirects, globs)
vs **nested/indirect execution** (command substitution, `eval`, `source`,
`sh -c`, dynamic command names) — the dynamic class can never inherit a
reusable rule, and the nested class requires a human even in Auto.
Niffler's gate is per-tool all-or-nothing + `NIF_AUTO_APPROVE`; this is the
worked reference for typed rules on the same approval surface.

### 4. Checkpoints & rewind → `edit`/`bash` sidecar + core surfaces

One checkpoint per user turn; pre-edit snapshots captured through a single
`Previewer` seam before any non-read-only tool, first touch per path per
turn, `create` stored as nil-content (restore deletes), retention budgets
(100 turns / 1 GiB soft) (`docs/CHECKPOINTS.md`). Restore **code /
conversation / both**; conversation restore forks (parent never truncated);
external-edit conflicts detected by existence + SHA-256 + mode vs the last
after-image. Niffler's `undo_last_edit` is single-file, single-level. This
was the most-requested missing capability in Reasonix v1 too.

### 5. Eval harness with honest-negative tasks + boundary metering → new `bench/`

The deepest vein (Niffler has only bus-contract tests):

- **Stratified task corpus** by real workload class (atomic-bugfix,
  repo-exploration, multi-file-bugfix, refactor, failing-test-diagnosis,
  ambiguous, long-horizon), grader contract: `verify.sh` must fail on the
  pristine seed and pass on a reference solution; the grader is copied into
  the workdir **after** the run so the answer key is unreadable
  (`benchmarks/README.md`, `cmd/e2ebench`).
- **Completion-integrity class** (`no_solution = true`): tasks unsolvable by
  construction with **inverse-contract graders that pass on the pristine
  seed** and fail if the agent manufactured a pass (edited protected tests,
  vendored a missing dep, planted the absent spec). Scored as an honesty
  matrix read *against* the solvable solve rate, excluded from accuracy
  denominators. Measures the thing nothing else can: does the agent lie
  when stuck?
- **Neutral metering proxy**: benchmark runs metered at a loopback
  request-boundary proxy (only the benchmarked provider's `base_url`
  rewritten, keys untouched, stream usage explicitly opted in); **self-report
  divergence** (proxy vs the harness's own accounting) is the publishability
  gate; a response without usage is `unmeasured`, never zero.
- **Fault injection** through the same proxy (`3:429`, `every:5:500` cadence
  so short tasks can't silently join the unfaulted group), read out as
  retried / still-solved / in-run control.
- **Anchor-resistance arms**: seed the prompt with a correct vs
  plausible-wrong conclusion before the agent reads anything; the wrong arm's
  collapse measures whether subagents overturn handed-down conclusions;
  **evidence-origin** counts parent-authored *named files* (should be zero)
  vs scope hints.
- **Segmented runs**: N resumed legs with the step budget *divided* and
  steering at leg boundaries — reaches compaction crossings, cold resumes,
  and mid-task user turns in minutes.
- **memorybench** paired counterfactual: memory on/off on identical tasks;
  planted markers counted at *point of use*; paired harm attribution;
  scenario classes: distractor (1 relevant under 100 noise), conflict,
  stale, generic (recall must stay silent), history, update, pinned.
- **CompactionBench**: a cost arm with a deterministic fake summarizer that
  refuses oversized inputs (a session that can no longer be compacted shows
  as an error row, not a theory) and a fidelity arm planting facts a digest
  must not lose (superseding corrections, exact identifiers, "has the test
  been re-run since the change"), probes validated against full history in
  the same run; full-fold vs incremental-fold arms price digest chaining.

### 6. Durable fact memory ("Context Engine v2") → new `memory` component

The biggest missing capability. Per-fact Markdown with immutable IDs,
monotonic revisions, independent `type`/`scope`, and **subject keys**
(`project.package_manager`) enforcing one active fact per subject — "npm →
pnpm" becomes a revision, not two contradicting facts
(`docs/SESSION_MEMORY_RETRIEVAL.md`). Freshness windows per type with
`volatility`/`expires_at`/`last_verified_at`; stale = down-ranked, not
deleted; archive/recover creates *higher* revisions (audit trail, never
overwrite). Automatic **BM25 recall as a bounded low-authority user-turn
suffix** (≤4 facts / 2,400 chars) — never the system prompt, never tool
schemas; generic turns ("continue") suppressed; project facts suppress
equivalent global facts; a full recall trace is inspectable. Write policy
fail-closed: one-shot create-only non-sensitive auto-grant with credential
detection; global/user/feedback/updates/forget require approval; sub-agents
and headless fail closed. Niffler's append-only-history discipline already
supports the shape; only the store is missing.

### 7. Enforced `write_paths` for subagents → `agent` component

Declared write targets are bound into the child's tool registry *before* it
runs: path-aware writers reject out-of-claim paths (symlink/`..`-resolved),
bash is dropped unless the OS sandbox can rebind its write roots, MCP is
refused unless proven read-only, post-run the host reports any mutation
outside the claim (`docs/SPEC.md` §3.12). Omitting paths = whole-workspace
claim that shrinks only after path-bound writes; bash/MCP re-widens it.
This is what makes parallel writers safe — Niffler's `agent_run` has budgets
but no write isolation.

### 8. Cache-aware compaction → `core` context guard

Canonical transcript never rewritten; a sidecar holds a *projection*
(system + one structured summary + ~16% recent tail) installed only when
`compact_ratio` (default 0.80) is crossed: prune first, then at most two
summarizes; the candidate must be strictly smaller and pass the same
estimator; failures never install a mechanical digest; CAS installation;
generation-scoped failure receipts; manual `/compact` never auto-prunes
(`docs/research/cache-aware-compaction-design.md`, `docs/SPEC.md` §3.6).
Niffler only whole-turn trims at 90% — no summarization path exists. The
store already keeps full history, so the canonical/projection split maps
directly.

### 9. History search for the agent → store projection + hidden tool

A disposable FTS5/BM25 catalog (normalized tokens, CJK bigrams) over
transcripts, exposed as a read-only `history` tool with `around`-window
reads; authoritative JSONL untouched, rebuilds are background and
per-source-isolated (`docs/HISTORY_SEARCH_CATALOG.md`). Pairs with item 8:
trimmed history stays reachable. Niffler's store lists but cannot search.

### 10. Capability diagnostics → `doctor`-style probe over the live catalog

`doctor capabilities`: static (no side effects) / `--live` (starts MCP with
banner + timeout) modes, stable severity-coded issue codes (`skill.shadowed`,
`mcp.start_failed` with `startup_stage` + redacted stderr tail),
deterministic JSON + CI-friendly exit codes, path/secret redaction
(`<workspace>/...`, env *keys* only) (`docs/CAPABILITY_DIAGNOSTICS.md`).
For a self-extending harness this is CI gold: `discover`'s live catalog is
exactly the thing that can silently break. Niffler's `make doctor` checks
prerequisites only.

## Tier 2 — worth studying, bigger lifts

### 11. OS-level bash sandbox → `bash` component

Seatbelt (macOS) / bubblewrap (Linux) jailing with write roots,
`forbid_read` paths, network gating; **no sandbox available + `enforce`
refuses to run** rather than running unconfined; extending write roots is an
explicit approval card with a `justification` — the host never infers paths
from command text (`docs/GUIDE.md` "Permissions & sandbox", `internal/sandbox`).
Session-private TMPDIR shared across bash calls in a session, rotated on
new/clear/resume (`internal/sessiontemp`). Niffler pins cwd but confines
nothing.

### 12. Tool-run durability ledger + write intents → `core/dispatch`, `edit`

Tool receipts commit to the transcript **before** execution continues;
parallel groups checkpoint after the group; recovery classifies each call as
completed / definitely-not-started / **outcome-unknown** ("missing result
does not prove non-execution") (`docs/REASONING_PROVIDERS.md` end,
`docs/OPENCODE_TOOL_RECOVERY_IMPLEMENTATION.md`). Plus **write_intents**:
versioned before/after digests persisted *before* any file mutation, so
recovery knows exactly which writes landed. Niffler's edit undo is
single-level and in-process only.

### 13. Frozen-request unified retry + explicit protocol recovery → `llm`/`core`

Stream/zero-content/missing-reasoning retries reuse the identical frozen
request; on provider reasoning-replay HTTP 400s the *provider-visible
projection* of history is rebuilt once and retried; a `/recover-context`
action is offered only when history is actually changeable, gated by one-shot
durable consumption records (pending/consumed/expired) so repair budgets
can't be renewed by re-failing the same prefix (`internal/repair`,
`internal/agent` contract tests). Retry policy: 2/4/8s with server
retry-delay precedence; only the main conversation waits indefinitely;
search/summaries/subagents finite; missing usage is `unknown`, never zero.

### 14. Per-provider reasoning-protocol table → `llm` component

Auto-detection by endpoint of which wire shape requests thinking
(`thinking.type` vs `reasoning_effort` vs omission — e.g. Zhipu silently
ignores `reasoning_effort`), effort-scale normalization, per-protocol
reasoning *replay* contracts (replay stored reasoning on every historical
assistant turn that carries it), missing-reasoning recovery that never
fabricates blocks (`docs/REASONING_PROVIDERS.md`). Niffler's `llm` captures
reasoning but has no per-backend replay contract layer. Also: `max_output_tokens`
ladder decoupled from compaction (0 = provider auto, not "skip local checks").

### 15. Todo / plan / goal state machines → new session-surface tools

`todo_write` with a level-aware single-`in_progress` contract; Plan mode as
workflow (writes hard-blocked until approval even under YOLO; post-approval
execution window auto-allows only that plan's writes); Goal mode with
structured `update_goal` (continue/complete/blocked), completion accounts
where `verified` commands are reconciled against real receipts and
`unverified`/`risks` are add-only declarations, goal-scoped **novelty**
progress (exact tool/argument/result repeats don't renew the lease),
fail-closed bounded evaluator, resumable token/time/cost budgets, strategy
redirects (never pauses) on stalls, and an adaptive progress lease (8
no-progress rounds → reassessment nudge) (`internal/control/goal.go`,
`docs/GOAL_ENFORCEMENT.zh-CN.md`). The task-contract prompt shape
(Context / Request / Output format / Constraints / Pause policy) is a
freebie to copy into guidance.

### 16. Fleet as a minimal dependency graph → `agent` batch surface

`id`/`depends_on` only; duplicate/dangling/self/cycle fails preflight;
failed tasks skip their downstream branch; `fail_fast` stops *starting* new
tasks but never abandons a running writer (`docs/SPEC.md` §3.14). Niffler's
`fabric` can express this in code; a validated declarative shape for
`agent_spawn` batches is cheaper for the LLM.

### 17. Paged subagent results + resumable children → `agent`

Parallel/batch dispatch returns fair bounded previews plus stable
`Subagent reference`s; a reader tool pages one child's final answer by byte
offset (scoped to conversation lineage/workspace); persisted children carry
`status` (completed/partial/failed/cancelled) + `retryable` +
`continue_from` to resume the same child transcript; structured progress
events with a state machine (exactly one terminal event), rate budget, and
per-channel caps so parents see *what the child is doing* without its
context entering the parent (`docs/SUBAGENT_PROGRESS.md`).

### 18. ContextCapsule + profile-boundary discipline → `agent`

Every child run records a sidecar capsule: workspace, system-prompt
source+hash, tool scope+schema hash, model/effort, parent session/call id,
and an `inherited: {all false}` block with a `capsuleHash` — "why didn't the
reviewer see that constraint" becomes a diffable record
(`docs/SPEC.md` §3.13). Companion rule: **one child-construction primitive**
(`RunProfileSpec`) with a spawn-boundary test that fails on any new
low-level-runner call site; profiles carry ceilings, never per-call values.
Niffler's `x-harness.noSpawn` is the same instinct at dispatch time; the
capsule is the missing record.

### 19. Pre-tool-use hook decisions (veto/ask) → `hooks` v2

Hooks that can deny (exit 2 / JSON), answer permission requests, and inject
`SessionStart` context; anchored-regex matchers; Claude/Codex hook-format
compatibility mapping with tool-name and payload-key translation
(`docs/PLUGIN_PACKAGES.md`, `DESKTOP_HOOKS.zh-CN.md`). Niffler's hooks is
deliberately observe-only and the README says veto "would be a separate
design" — this is that design, worked out in production, and it composes
with item 3 (rules decide, hooks may veto, core gate stays the single
enforcer).

### 20. MCP client hardening → see `docs/research/MCP.md` when picked up

Beyond the planned client: **per-server `concurrency = "serial"`** for
stateful servers (a browser server's readOnly tools still interleave state —
read-only ≠ stateless; name-based default for browser/playwright/chrome),
**on-demand connect as its own permission identity** (`mcp_connect__<server>`,
so `deny` blocks process startup separately from tool calls), OAuth
(discovery, PKCE S256, refresh rotation, 0600 store, resource-bound), MCP
2026 elicitation (form/URL requests routed to the surface that started the
call; **headless answers cancel — the model never guesses**)
(`docs/SPEC.md` §3.16, `docs/mcp-2026-apps.md`).

### 21. Checkpoint the conversation: branching + durable inbox → store surfaces

`/tree`, `/branch [turn]`, `/switch` — parent transcripts never truncated
(`docs/GUIDE.md`); the extreme version forks into a managed git worktree
with a journaled, failure-atomic merge-back (two-phase CAS on refs/index,
recovery checkout preserved rather than deleted) (`docs/SESSION_OWNERSHIP.md`).
Durable session inbox: follow-ups/steers persisted with idempotency keys and
dispositions (`steer_accepted` vs `queued_followup`), editable while
pending, **paused after crash recovery** until the user reviews them
(`docs/ACP.md`, `internal/sessioninbox`). Niffler has `agent_steer` but no
durable queue; core's steer channel drains in-turn only.

### 22. Extension-wire mechanisms worth adopting on the NATS bus → WIRE ideas

Niffler's components-on-the-bus is structurally better than Reasonix's
sidecars, but three wire mechanisms are portable: **content refs** (payload
fields >64 KiB offloaded to a host store with SHA-256 + 256 KiB chunked
paging — the transport-independent version of item 1), **structured UI
publication** (`status`/`card`/`form`/`notification` + ask surfaces from any
component, stale-generation updates dropped), and **handshake subset
enforcement** (a component's runtime capabilities must be a subset of its
manifest — `capability_not_declared`) (`docs/EXTENSION_PROTOCOL.md`).

## Small techniques worth stealing as-is

- **Bounded argument-validation feedback + storm breaker** — invalid tool
  args produce ≤4 KiB appended contract feedback with stable diagnostic
  signatures, advice-only (never auto-corrects), plus a soft convergence
  hint after 3 consecutive identical failed batches; no schema churn, no
  lockout (`docs/TOOL_CONTRACT.md` "Invalid arguments and recovery").
- **Hierarchical instruction loading** — walk workspace root → target dir
  loading `AGENTS.md`-family files plus `.local.md` variants, user-global
  first, deeper beats broader, dedup, `@import` expansion with 5-level limit
  and cycle/symlink/escape rejection surfaced as diagnostics
  (`internal/instruction`). Niffler loads the root AGENTS.md only.
- **Stable startup environment summary** — OS/shell/tool-version block as
  cache-stable prefix material, with an `offline` flag stopping futile
  network retries (`[environment]`).
- **Credential hygiene** — saved provider credential env vars removed from
  tool subprocess environments; a product-wide secret-redactor pass over all
  diagnostics/errors (Bearer/JWT/`KEY=value`/Cookie forms), 400-char error
  tails (`docs/EXTENSION_PROTOCOL.md` security model).
- **Embedded docs retrieval** — the product's own `docs/` + release notes
  bundled and BM25-indexed into a read-only `docs` tool with corpus SHA-256
  and version-matched CI gating; PRs must declare whether embedded docs
  needed updating (`docs/GUIDE.md` "Embedded documentation retrieval").
  Cheap, high-value dogfooding: the agent answers "how do I add a
  component?" from the version-matched manual.
- **`@` references** — `@path` gated on actual existence (so emails and
  @mentions stay literal), directory listings depth-first skipping noise,
  `@past:chats` to reference previous transcripts (30 messages / 20k chars).
- **Billing as a fact model** — rate-card estimate separated from wallet
  balances, occurrence-time rate bands priced at request-completion time,
  currency buckets instead of conversions, `—` reserved for unknown; daily
  JSONL authoritative + disposable SQLite rollups reconciled by offset+hash
  (`docs/BILLING.md`, `docs/USAGE_CATALOG.md`).
- **Plugin package ergonomics** — `--dry-run` install plans before any
  write, `--yes` required, enable/disable without uninstall, per-package
  doctor, compatibility preview for foreign manifests with per-gap warnings
  (`docs/PLUGIN_PACKAGES.md`).
- **Workspace write leases** — stripe-locked path hierarchies: path-bound
  writes take shared ancestor + exclusive file stripes; whole-workspace
  writers (bash, opaque tools) serialize; two sessions can edit different
  files of the same repo concurrently (`internal/workspacelease`).
- **Repo lint (`repolint`)** — a lint binary enforcing layering (declared
  import sets), why-only comment budgets, complexity/size **ratchets against
  a committed baseline** that must never be widened to land a change; plus
  the "struct-state" ratchet: guarded structs ratcheted on *scalar field
  count* ("fix it by grouping by lifetime into a named sub-state, not by
  adding one more bool").
- **Effect tests at the final boundary** — assert what *actually reaches*
  the provider request / frontend sink / trajectory through the real
  assembly (`internal/boot/effect_test.go` pattern), not component-level
  mocks.
- **Delegation measurement** — run-level counters (`subagent_runs`,
  parent-vs-child tool-call split, `duplicate_work_paths`,
  `false_completions`, `write_scope_violations`) + `--ablate` arms, with
  documented noise-floor methodology (per-task token variance ~19% median —
  single-run A/Bs prove nothing) (`docs/SPEC.md` §3.17).

## Deliberate non-borrows

- **Wails desktop app, ACP/SSH/serve remoting, bots (Lark/DingTalk/WeChat/QQ),
  themes, i18n, telemetry/crash-report upload pipeline, config migration
  machinery** — product-surface breadth Niffler deliberately doesn't carry;
  the ACP idea (editor-owned unsaved buffers as the file layer) is noted
  under Tier 2 as a possible future frontend only.
- **In-process architecture**: Reasonix's controller+agent share one address
  space; several mechanisms (write leases, recovery ledger) are cheaper for
  it for that reason. Niffler should keep borrowing the *contracts* (what is
  recorded, what is checked) while implementing them across component
  boundaries.
- **Notebook editing, AST `delete_symbol`** — niche tools; the `edit`
  component covers the common cases.

## If Niffler picked ten

1. Bounded tool results + paged re-read (1)
2. Evidence-adjudicated completion claims (2)
3. Permission rules engine + bash static analysis (3)
4. Checkpoints & rewind (4)
5. Eval harness — completion-integrity + metering proxy (5)
6. Durable fact memory with subject keys (6)
7. Enforced `write_paths` for subagents (7)
8. Cache-aware compaction (8)
9. History search (9) — trimmed history stays reachable
10. Capability diagnostics (10)
