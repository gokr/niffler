# Plan — open work

This is the short list of deliberately deferred work. Shipped behavior belongs
in the [manual](MANUAL.md); design history and proposals belong in
[research/](research/README.md). The **research candidates** below are the open
items that used to live only inside the research/steal docs — one line per
candidate, pointing at the doc that owns the design and effort detail.

**Reconciled 2026-10-09 against `main` (`5703af7`).** Every candidate was
re-checked against the code; fifteen rows moved to *Shipped foundations* and
seven more were narrowed to the part that is actually still open. The audit is
a grep-able claim, not a memory — the checklist that re-derives it is at the end
of this file.

## Recent reliability slices

- **Tool diet + result routing** — implemented on `feat/tool-diet-results`:
  retain eight direct tools; concise prompt/schema routing, raw-string result
  projection, workspace-relative/bounded file text, conditional recovery hints,
  hint-preserving discovery pages, exact source captures, and benchmark readiness
  plus telemetry. Verified: 69/69 bus tests, Go/vet, 11/11 Node tests; full31
  31/31 with −23.6% first-prompt tokens and −5.3% total tokens on the matched
  29 eight-tool tasks (model rounds rose 165→177). See the
  [retained CSV](../bench/reports/full31-tool-diet-low-report.csv). Code run:
  `full31-tool-diet-low-fdf2ae0` on `fdf2ae0`, first-party DeepSeek low, one
  round/task, jobs=2. The earlier `daa861a` run also passed 31/31 but exposed
  the symlink-display gap; its lower token total is not the headline. No nested
  grammar or globally demoted grep. Selection-policy unification and advanced
  schemas on demand remain separate experiments.

## Current priorities

- **Write arbitration between concurrent writers** — nothing arbitrates
  filesystem writes today: `core/dispatch.nim`'s leases cover the nested-call
  proxy only. Parallel dispatch, several conversations per workspace and
  pre-created worktrees are all shipped, so two session runners can interleave
  edits in one tree with no owner and no conflict signal. This is a correctness
  hole, not a safety one ([REASONIX.md](research/REASONIX.md) #7,
  [CODEWHALE.md](research/CODEWHALE.md) D1).
- **Evidence ledger + host-adjudicated completion claims** — a subagent settles
  with prose and nothing checks its citations against what the host actually
  observed. The seam exists (`agent`'s transcript-derived `resolveStale`); it
  simply does not adjudicate. Pairs with the structured-output half of the
  subagent row below ([REASONIX.md](research/REASONIX.md) #2).
- **Eval harness — completion-integrity class + metering proxy** — the
  decisions above are bench-gated and the bench still has no
  unsolvable-by-construction tasks with inverse-contract graders and no neutral
  request-boundary proxy whose divergence gates publishability
  ([REASONIX.md](research/REASONIX.md) #5).
- **Level 1 UI dynamism** — add `x-ui` schema hints and a generic renderer
  registry so components can describe how their tool results render
  ([CODEWHALE-TUI.md](research/CODEWHALE-TUI.md) §2–4,
  [OPENHANDS.md](research/OPENHANDS.md) §3.6).
- **Session branching / navigation** — provide a user-facing session tree,
  labels and derivation on top of the shipped continuation and fork contracts
  ([PI-NEXT.md](research/PI-NEXT.md) #5,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §2.4).
- **Settings** — implement the human/model settings surface described in
  [SETTINGS.md](research/SETTINGS.md), including precedence and persistence
  (schema-driven variant: [OPENHANDS.md](research/OPENHANDS.md) §3.11).
- **Optional sandboxing** — add an explicit OS/VM isolation component if
  running untrusted generated code becomes a requirement. Fabric guests are
  currently approved native code in bash's trust class, not a sandbox
  ([SANDBOX-PLAN.md](research/SANDBOX-PLAN.md),
  [CODEWHALE.md](research/CODEWHALE.md) #4,
  [REASONIX.md](research/REASONIX.md) #11). Deliberately last: SANDBOX-PLAN §6
  records that the agent edits the harness's own source tree — the control
  plane a workspace write guard cannot protect — so a VM/container deployment
  covers the real risk better and more cheaply than a new launcher.

## Research candidates

Moved here out of the research/steal docs so open work has one home. This is a
backlog, not a commitment list; promote an item to *Current priorities* when it
gets scheduled, and keep the rationale edits in the owning research doc.

### Editing and tool results

- **Edit repair tier** — a repair hook tier behind the match cascade. The
  ambiguity half shipped (an ambiguous match is refused *with* its occurrence
  count, never fuzzied away); the learned repair tier did not
  ([FAST-APPLY.md](research/FAST-APPLY.md) §7.1–2,
  [OCTOFRIEND-STEAL.md](research/OCTOFRIEND-STEAL.md) #1).
- **`fastapply` merge-provider plugin** — opt-in, off by default; a
  `{path, instruction, lazy_edit}` peer behind the generic seam
  ([FAST-APPLY.md](research/FAST-APPLY.md) §7.3).
- **`fuzzy_replace` indent-drift rebase** — the cascade forgives indentation
  drift when *matching*, but splices `new_string` in the model's frame rather
  than the file's ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Opt-in `edit_lines`/`insert_lines`** — line-number sub-tools for big files
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Deterministic JSON-repair tier for tool arguments** — bounded fixups
  before schema validation
  ([OCTOFRIEND-STEAL.md](research/OCTOFRIEND-STEAL.md) "Smaller items").
- **`create` vs `rewrite`** — `create` refuses existing files; `rewrite`
  stays the last-resort whole-file escape
  ([OCTOFRIEND-STEAL.md](research/OCTOFRIEND-STEAL.md) "Smaller items").
- **Skip-atomic edit batches** — all-or-nothing multi-edit plans with
  explicit `tool-skip-output` records
  ([OCTOFRIEND-STEAL.md](research/OCTOFRIEND-STEAL.md) "Smaller items").
- **Checkpoints & rewind** — sidecar checkpoints over `edit`/`bash` with core
  rewind surfaces and a tool-run durability ledger. `undo_last_edit` is
  single-level per file, not a per-turn checkpoint
  ([REASONIX.md](research/REASONIX.md) #4, #12).

### Context, memory and payloads

- **`memory` component** — durable fact memory with subject keys, under the
  D3/D4 design constraints ([CODEWHALE.md](research/CODEWHALE.md) #1 + D3/D4,
  [REASONIX.md](research/REASONIX.md) #6,
  [MAKI-STEAL.md](research/MAKI-STEAL.md) #8).
- **Tool-produced images + normalize-on-entry** — the *transport* shipped
  (session `attachments` on all three protocols, billed by pixel area); what is
  missing is a vision `read`/screenshot path and the rewrite-as-they-enter-history
  discipline, so no component can poison a frozen prefix with an unsendable
  image ([PI-NEXT.md](research/PI-NEXT.md) #4,
  [PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md) A6,
  [OCTOFRIEND-STEAL.md](research/OCTOFRIEND-STEAL.md) "Smaller items",
  [CODEWHALE.md](research/CODEWHALE.md) D13).
- **Anthropic cache breakpoints + retention** — cache-write accounting shipped,
  and the OpenAI-family lanes cache implicitly, so nothing else in this row has
  a producer until the Anthropic path is actually exercised
  ([PI-NEXT.md](research/PI-NEXT.md) #3).
- **Prompt templates + per-directory system-prompt overrides** — prompt slots
  shipped (`prompt_hint`); the per-directory replace/append knobs did not
  ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §3.2, §4).
- **Deferred MCP connect** — lazy subdirectory instructions shipped
  (`AGENTS.local.md` and the git-root→cwd walk); the connect-as-its-own-
  permission-identity half did not ([MAKI-STEAL.md](research/MAKI-STEAL.md) #8).

### Agents, delegation and model policy

- **`team` teammates + a durable mailbox** — named teammates, three delivery
  lanes ([DSH-STEAL.md](research/DSH-STEAL.md) §5).
- **Subagent model tiers + structured outputs + visibility**
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #6).
- **Enforced `write_paths` for subagents**
  ([REASONIX.md](research/REASONIX.md) #7).
- **Worktree-per-conversation + worktree write-claims**
  ([CODEWHALE.md](research/CODEWHALE.md) D1,
  [OPENHANDS.md](research/OPENHANDS.md) §3.15).
- **Goal loop component** — judge + steer + durable job, "keep going until
  done" ([OPENHANDS.md](research/OPENHANDS.md) §3.3,
  [REASONIX.md](research/REASONIX.md) #15).
- **Stuck detection** — `stuck` as its own terminal state, dispatch
  fingerprint ring ([OPENHANDS.md](research/OPENHANDS.md) §3.2).
- **Evidence ledger + adjudicated completion claims** — the host, not the
  child, closes a claim ([REASONIX.md](research/REASONIX.md) #2).
- **Weak/editor model split + aux-model policy** — cheap models for
  summarize/commit/auxiliary calls ([AIDER.md](research/AIDER.md) #3,
  [CODEWHALE.md](research/CODEWHALE.md) D5,
  [PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md) C2).
- **Escalation ladder** — the `escalate` component: effort→model rungs, a
  give-up gate with wrap-up, down-escalation with hysteresis
  ([ESCALATION.md](research/ESCALATION.md)).
- **Approvals on calibrated uncertainty** — fire the human gate on "I don't
  know how far this reaches", not only on flagged intent
  ([JEV.md](research/JEV.md) #3).
- **Intent-conditioned tool-result filtering** — filter against the step's
  stated intent, always store the raw output
  ([JEV.md](research/JEV.md) #4).

### Fabric and orchestration

- **`fabric {api: true}` declarations on demand** — the open DSH steals phase C
  ([DSH-STEAL.md](research/DSH-STEAL.md) §4,
  [DSH-STEALS-PLAN.md](research/DSH-STEALS-PLAN.md) phase C).
- **monty-style code-execution refinements** — what its Python sandbox does
  better than fabric; the error-isolated `batch` fan-out and schema-pinned
  signature injection halves shipped
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #2).

### Session, UI and product surfaces

- **TUI companion work** (lands in the `niffler-tui` repo): truthful live
  surfaces, key/help single authority, declared layout-degradation tiers
  ([CODEWHALE-TUI.md](research/CODEWHALE-TUI.md) §2–4).
- **Context inspector** — the prompt decomposed layer by layer
  ([CODEWHALE-TUI.md](research/CODEWHALE-TUI.md) §6).
- **Gate/approval receipts + approval axes** — decision risk × presentation
  stakes ([CODEWHALE-TUI.md](research/CODEWHALE-TUI.md) §5,
  [OPENHANDS.md](research/OPENHANDS.md) §3.9).
- **Client-effect tools** — the UI executes designated calls with ack
  semantics ([OPENHANDS.md](research/OPENHANDS.md) §3.8).
- **Event grouping / thought hoisting** ([OPENHANDS.md](research/OPENHANDS.md)
  §3.7).
- **Overview panel + git prompt bar** ([OPENHANDS.md](research/OPENHANDS.md)
  §3.10).
- **Priced usage ledger + `/usage`** — per-turn usage accounting exists (it is
  the authoritative record compaction reads); what is missing is the
  price-at-turn-time ledger with peak-hour schedules and the surface that reads
  it ([OPENHANDS.md](research/OPENHANDS.md) §3.1,
  [AIDER.md](research/AIDER.md) #5, [MAKI-STEAL.md](research/MAKI-STEAL.md) #9,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §4).
- **Session export / import / share**
  ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §3.5).
- **`question` forms + `/btw` side questions**
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Concurrent-session live-status picker**
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Git-first auto-commit + `/undo` discipline**
  ([AIDER.md](research/AIDER.md) #4).
- **Watch mode** — recorded, not endorsed; only if a user asks
  ([AIDER.md](research/AIDER.md) #7).
- **Delta-tracked live state for the web UI** — Chord-style path-coded deltas
  ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §4).

### Trust and security

- **Typed permission rules + static bash analysis**
  ([CODEWHALE.md](research/CODEWHALE.md) #3,
  [REASONIX.md](research/REASONIX.md) #3).
- **Tree-sitter-parsed bash permission scopes**
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #5).
- **Project trust gate** ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md)
  §2.3).
- **MCP OAuth2 + honest health verdicts; MCP client hardening** — the `oauth`
  support that shipped is the *provider* login path, not MCP
  ([OPENHANDS.md](research/OPENHANDS.md) §3.14,
  [REASONIX.md](research/REASONIX.md) #20, [MCP.md](research/MCP.md)).
- **Remote mode over an authenticated bus** — the bundled `nats-server`
  already accepts `--auth`, so the remaining work is `NIF_NAME` identity and
  the non-loopback/key-gated flags on the harness side
  ([OPENHANDS.md](research/OPENHANDS.md) §3.17,
  [REMOTE.md](research/REMOTE.md) §5–7).
- **OS keyring secrets** for provider keys
  ([CODEWHALE.md](research/CODEWHALE.md) D13).

### Providers and reliability

- **Strict tool-call sampling** where the provider supports it
  ([PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md) A7).
- **Frozen-request unified retry** — the cost-split budget taxonomy and
  server `Retry-After` handling shipped; what is missing is retrying
  zero-content/missing-reasoning with the *identical* frozen request, and
  one-shot durable repair-consumption records
  ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §3.3,
  [REASONIX.md](research/REASONIX.md) #13).
- **Per-provider reasoning-protocol table** — `reasoning_effort` handling
  exists; a per-endpoint wire-shape table and reasoning-replay contracts do not
  ([REASONIX.md](research/REASONIX.md) #14).
- **Reflection loop** — lint/test/edit failures as typed retries with a cap
  ([AIDER.md](research/AIDER.md) #2).
- **Shell session env injection into `bash`**
  ([PI-NEXT.md](research/PI-NEXT.md) #2,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §3.1).
- **Grep streaming early-kill** — output is already line-capped; the
  remaining half is killing the search once the cap is reached, plus rg/fd
  auto-download ([PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md) A5, B5).

### Ecosystem, process and remote

- **Hooks with veto** — pre-tool-use block/ask inside the dispatch gate
  ([OPENHANDS.md](research/OPENHANDS.md) §3.5,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §4,
  [CODEWHALE.md](research/CODEWHALE.md) #9 remainder,
  [REASONIX.md](research/REASONIX.md) #19).
- **Tool-surface lifecycle** — replay aliases + run checkpoints
  ([CODEWHALE.md](research/CODEWHALE.md) #5,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §2.1).
- **Deferred tool loading beyond `onDemand`** — cache-preserving dynamic
  toolsets ([PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §2.2).
- **Architecture guard tests + specs with IDs**
  ([OPENHANDS.md](research/OPENHANDS.md) §3.12–13).
- **Eval harness with honest negatives + behavioral evals**
  ([REASONIX.md](research/REASONIX.md) #5,
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §3.6,
  [CODEWHALE.md](research/CODEWHALE.md) D2).
- **Supply-chain policies for packages** — pinned refs, min-release-age, an
  npm lifecycle-script stance (pairs with *Component package template* below;
  [PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §4,
  [MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Generated docs with a CI drift check** for the plugin/SDK API
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Slash-command scope cascade** — `/project:` `/user:` scoping; the skill
  discovery half shipped ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Claude-Code-wire-compatible headless mode** — `cli run` speaks NDJSON with
  our own schema; matching Claude Code's `stream-json` field names would make
  Niffler a drop-in in orchestrators built for it
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #11).
- **`cli` control-plane contract + one durable runtime for detached work**
  ([CODEWHALE.md](research/CODEWHALE.md) #6–7).
- **Modes and postures** as session policy
  ([CODEWHALE.md](research/CODEWHALE.md) D6).
- **Declarative plugin bundles + skills routing metadata**
  ([CODEWHALE.md](research/CODEWHALE.md) D7–8).
- **Lifecycle event outbox** ([CODEWHALE.md](research/CODEWHALE.md) D9;
  overlaps *durable Fabric/agent traces* below).
- **Remote paths** — first-class Chetter support and/or a native fleet over
  NATS leaf nodes + a shared TiDB scope; shared prerequisites are `NIF_NAME`
  identity, bus auth and provisioning
  ([REMOTE.md](research/REMOTE.md) §6–7).
- **Capability diagnostics** — a `doctor`-style probe over the live catalog
  ([REASONIX.md](research/REASONIX.md) #10).
- **Worker-aware Nim pump** — deferred until a mixed-stateful component
  outgrows replicas ([PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md)
  B1b, [PI_EFFICIENCY_B1B_THREADS.md](research/PI_EFFICIENCY_B1B_THREADS.md)).

## Possible follow-ups

- **Resource-scoped batch effects** — relax Fabric's global write exclusion
  only after resource ownership can be declared safely.
- **Durable Fabric/agent traces** — store-backed retention for diagnostic
  lifecycle events; current logs are intentionally bounded and non-authoritative.
- **Component package template** — publish a reusable community-component
  template and release workflow.
- **JavaScript without compilation** — `sdk/ts` and `builder` support TypeScript;
  direct execution via a runtime such as `tsx` remains optional.
- **Pipewrap** — an NDJSON/stdio adapter for plain scripts that do not use an
  SDK.

## Shipped foundations

These were previously tracked here as plans and are now part of `main`:

- Context ledger, deterministic prune/trim, replaceable compaction, durable
  projections and recall, bounded provider-overflow recovery and a manual
  `/compact` trigger; see [research/COMPACTION.md](research/COMPACTION.md).
- Continuable and forked subagents, settlement notices (including the bounded
  autonomous wake that tells an idle parent its children finished), `agent_list`
  and the subagent model-tier ladder; see
  [MANUAL.md](MANUAL.md#fabric-and-subagents) and the historical runbook
  [research/SUBAGENTS-PLAN.md](research/SUBAGENTS-PLAN.md).
- Compiled-Nim Fabric guests, structured APIs, caching, cancellation, bounded
  execution, error-isolated `batch` fan-out and schema-pinned typed wrappers;
  see [FABRIC_GUIDE.md](FABRIC_GUIDE.md) and
  [COMPILED_PLAN.md](../components/fabric/docs/COMPILED_PLAN.md).
- SQLite (default) and TiDB store engines behind one contract (the barrel engine was removed in 0.4.0); see
  [MANUAL.md](MANUAL.md#store-engines) and
  [research/STORE_V2.md](research/STORE_V2.md).
- Pure-Nim NATS client, the configurable LSP registry and semantic operations,
  background processes, MCP bridges, self-documenting skills and repomap
  discovery.
- **Bounded tool results with a paged full re-read** — an oversized capture
  promotes to a durable `spill` document, the transcript keeps a bounded body
  plus a ref, and `context_recall` pages the original back
  ([REASONIX.md](research/REASONIX.md) #1).
- **Partial tool output survives a cancel or timeout** — a cooperative
  component's accumulated bytes come back with a `__partial` marker instead of
  being discarded ([MAKI-STEAL.md](research/MAKI-STEAL.md) #4).
- **Retry budgets split by what the error costs**, with a server `Retry-After`
  honored inside a floor and a cap
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #7).
- **Edit ambiguity errors name the failure** — an ambiguous `old_string` is
  refused with its occurrence count, never fuzzied away
  ([FAST-APPLY.md](research/FAST-APPLY.md) §7.1).
- **SSRF guard with DNS pinning** — the vetted address is the one connected to
  (`curl --resolve` per hop, re-vetted on every redirect)
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #10).
- **History search for the agent** — `context_recall {mode: "search"}` ranks
  over the whole canonical transcript, trimmed and compacted-away messages
  included ([REASONIX.md](research/REASONIX.md) #9).
- **Cache-write accounting** — the usage payload carries write tokens alongside
  reads, so a bench row no longer shows a structural zero
  ([PI-NEXT.md](research/PI-NEXT.md) #3).
- **Skill discovery compatibility** — the sibling agent directories
  (`.claude/skills`, `.agents/skills`, `.opencode/skills`) are read, not just
  our own ([MAKI-STEAL.md](research/MAKI-STEAL.md) "Smaller items").
- **Prompt slots** — internal components contribute aggregate or singleton
  prompt fragments through `prompt_hint`
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #12).
- **Lazy subdirectory instructions** — `AGENTS.local.md` and the git-root → cwd
  instruction walk feed the system prompt
  ([MAKI-STEAL.md](research/MAKI-STEAL.md) #8).
- **Worktree awareness** — a conversation's workspace set includes its git
  worktrees and same-origin siblings ([CODEWHALE.md](research/CODEWHALE.md) D1).
- **Image payloads across the wire** — session `attachments` reach the provider
  as the OpenAI multimodal array, Anthropic `source` blocks and Codex
  `input_image` items, billed by pixel area
  ([PI-NEXT.md](research/PI-NEXT.md) #4).
- **Length-stop policy** — a tool batch cut by a length finish is neutralized
  rather than applied ([PI_EFFICIENCY_PLAN.md](research/PI_EFFICIENCY_PLAN.md)
  B4).

## How to re-audit this file

The check is cheap and should run before a release cut. For each row, grep the
non-doc tree for its distinguishing symbol; a hit means the row has shipped (or
narrowed) and this registry is stale:

```bash
hit() { grep -rniE "$1" core components sdk | grep -viE 'docs/|_test'; }
hit 'spill|context_recall'          # bounded results + paged re-read
hit '__partial|partialArgs'         # partial output survives a cancel
hit 'rkRateLimitHint|Retry-After'   # retry budget taxonomy
hit 'prompt_hint'                   # prompt slots
hit '\.claude/skills'               # skill discovery compatibility
hit 'cacheWrite'                    # cache-write accounting
hit 'mode:.*search'                 # history search
hit 'modelTier'                     # subagent model tiers
hit 'worktree'                      # worktree awareness
hit 'finishLength'                  # length-stop policy
```

`grep -L '^Status:' docs/research/*.md` lists research documents with no status
banner; each should gain one when it is next touched. Two further lists are
open-work shelves of their own and must stay consistent with this file: the
*Explicitly not shipped* list in [FEATURES.md](FEATURES.md) and the candidate
list in [research/README.md](research/README.md).

A plan item is not an implementation promise. Update this file when work lands,
and record user-visible changes in [CHANGELOG.md](../CHANGELOG.md).
