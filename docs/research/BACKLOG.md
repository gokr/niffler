# Research backlog — unscheduled candidates

Status: deferred ideas, extracted from PLAN.md without treating them as a
release commitment. Shipped behavior belongs in [the manual](../MANUAL.md).

## Candidates

Unscheduled ideas, not implementation promises. Promote a candidate to
[the active plan](../PLAN.md) only with a bounded scope and acceptance gate.
Implementation summaries below are historical context; current status belongs
in the manual and active plan.

### Editing and tool results

- **Edit repair tier** — a repair hook tier behind the match cascade. The
  ambiguity half shipped (an ambiguous match is refused *with* its occurrence
  count, never fuzzied away); the learned repair tier did not
  ([FAST-APPLY.md](FAST-APPLY.md) §7.1–2,
  [OCTOFRIEND-STEAL.md](OCTOFRIEND-STEAL.md) #1).
- **`fastapply` merge-provider plugin** — opt-in, off by default; a
  `{path, instruction, lazy_edit}` peer behind the generic seam
  ([FAST-APPLY.md](FAST-APPLY.md) §7.3).
- **`fuzzy_replace` indent-drift rebase** — the cascade forgives indentation
  drift when *matching*, but splices `new_string` in the model's frame rather
  than the file's ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Opt-in `edit_lines`/`insert_lines`** — line-number sub-tools for big files
  ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Deterministic JSON-repair tier for tool arguments** — bounded fixups
  before schema validation
  ([OCTOFRIEND-STEAL.md](OCTOFRIEND-STEAL.md) "Smaller items").
- **`create` vs `rewrite`** — `create` refuses existing files; `rewrite`
  stays the last-resort whole-file escape
  ([OCTOFRIEND-STEAL.md](OCTOFRIEND-STEAL.md) "Smaller items").
- **Skip-atomic edit batches** — all-or-nothing multi-edit plans with
  explicit `tool-skip-output` records
  ([OCTOFRIEND-STEAL.md](OCTOFRIEND-STEAL.md) "Smaller items").
- **Checkpoints & rewind** — sidecar checkpoints over `edit`/`bash` with core
  rewind surfaces and a tool-run durability ledger. `undo_last_edit` is
  single-level per file, not a per-turn checkpoint
  ([REASONIX.md](REASONIX.md) #4, #12).

### Context, memory and payloads

- **`memory` component** — durable fact memory with subject keys, under the
  D3/D4 design constraints ([CODEWHALE.md](CODEWHALE.md) #1 + D3/D4,
  [REASONIX.md](REASONIX.md) #6,
  [MAKI-STEAL.md](MAKI-STEAL.md) #8).
- **Tool-produced images + normalize-on-entry** — the *transport* shipped
  (session `attachments` on all three protocols, billed by pixel area); what is
  missing is a vision `read`/screenshot path and the rewrite-as-they-enter-history
  discipline, so no component can poison a frozen prefix with an unsendable
  image ([PI-NEXT.md](PI-NEXT.md) #4,
  [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) A6,
  [OCTOFRIEND-STEAL.md](OCTOFRIEND-STEAL.md) "Smaller items",
  [CODEWHALE.md](CODEWHALE.md) D13).
- **Anthropic cache breakpoints + retention** — cache-write accounting shipped,
  and the OpenAI-family lanes cache implicitly, so nothing else in this row has
  a producer until the Anthropic path is actually exercised
  ([PI-NEXT.md](PI-NEXT.md) #3).
- **Prompt templates + per-directory system-prompt overrides** — prompt slots
  shipped (`prompt_hint`); the per-directory replace/append knobs did not
  ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §3.2, §4).
- **Deferred MCP connect** — lazy subdirectory instructions shipped
  (`AGENTS.local.md` and the git-root→cwd walk); the connect-as-its-own-
  permission-identity half did not ([MAKI-STEAL.md](MAKI-STEAL.md) #8).

### Agents, delegation and model policy

- **Agent definitions — implemented**: persona stays text;
  `agent` store documents supply technical birth defaults (persona, toolset,
  model/thinking, workspace and budgets) for roots and spawned children.
  Explicit arguments win; definitions cannot grant approval authority.
  `toolset` is canonical with legacy profile compatibility. Matching TUI source has `/agent` and `/toolset` pickers;
  definition-management editing UI remains pending. See
  [MANUAL.md](../MANUAL.md#agent-definitions) and [FLEET.md](FLEET.md) §6.
- **Heartbeat — implemented**: opt-in idle-seam scheduler,
  durable schedules and runner admission marks, rolling daily turn caps,
  busy-turn skips and append-only machinery-marked history. Completion delivery,
  cron expressions, daily token accounting and ledger retention remain pending.
  See [components/heartbeat/README.md](../../components/heartbeat/README.md).
- **Resident instances + fleet delegation** — a server-hosted harness in manual
  mode with an identity, a persona and a heartbeat, driven from any client;
  `fleet_*` delegates a task to a *conversation on another instance* over the
  existing `session` call ([FLEET.md](FLEET.md) §8–§9).
- **`team` teammates + a durable mailbox** — named teammates, three delivery
  lanes ([DSH-STEAL.md](DSH-STEAL.md) §5).
- **Subagent model tiers + structured outputs + visibility**
  ([MAKI-STEAL.md](MAKI-STEAL.md) #6).
- **Enforced `write_paths` for subagents**
  ([REASONIX.md](REASONIX.md) #7).
- **Worktree-per-conversation + worktree write-claims**
  ([CODEWHALE.md](CODEWHALE.md) D1,
  [OPENHANDS.md](OPENHANDS.md) §3.15).
- **Goal loop component** — judge + steer + durable job, "keep going until
  done" ([OPENHANDS.md](OPENHANDS.md) §3.3,
  [REASONIX.md](REASONIX.md) #15).
- **Stuck detection** — `stuck` as its own terminal state, dispatch
  fingerprint ring ([OPENHANDS.md](OPENHANDS.md) §3.2).
- **Evidence ledger + adjudicated completion claims** — the host, not the
  child, closes a claim ([REASONIX.md](REASONIX.md) #2).
- **Weak/editor model split + aux-model policy** — cheap models for
  summarize/commit/auxiliary calls ([AIDER.md](AIDER.md) #3,
  [CODEWHALE.md](CODEWHALE.md) D5,
  [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) C2).
- **Escalation ladder** — the `escalate` component: effort→model rungs, a
  give-up gate with wrap-up, down-escalation with hysteresis
  ([ESCALATION.md](ESCALATION.md)).
- **Approvals on calibrated uncertainty** — fire the human gate on "I don't
  know how far this reaches", not only on flagged intent
  ([JEV.md](JEV.md) #3).
- **Intent-conditioned tool-result filtering** — filter against the step's
  stated intent, always store the raw output
  ([JEV.md](JEV.md) #4).

### Fabric and orchestration

- **`fabric {api: true}` declarations on demand** — the open DSH steals phase C
  ([DSH-STEAL.md](DSH-STEAL.md) §4,
  [DSH-STEALS-PLAN.md](DSH-STEALS-PLAN.md) phase C).
- **monty-style code-execution refinements** — what its Python sandbox does
  better than fabric; the error-isolated `batch` fan-out and schema-pinned
  signature injection halves shipped
  ([MAKI-STEAL.md](MAKI-STEAL.md) #2).

### Session, UI and product surfaces

- **TUI companion work** (lands in the `niffler-tui` repo): truthful live
  surfaces, key/help single authority, declared layout-degradation tiers
  ([CODEWHALE-TUI.md](CODEWHALE-TUI.md) §2–4).
- **Context inspector** — the prompt decomposed layer by layer
  ([CODEWHALE-TUI.md](CODEWHALE-TUI.md) §6).
- **Gate/approval receipts + approval axes** — decision risk × presentation
  stakes ([CODEWHALE-TUI.md](CODEWHALE-TUI.md) §5,
  [OPENHANDS.md](OPENHANDS.md) §3.9).
- **Client-effect tools** — the UI executes designated calls with ack
  semantics ([OPENHANDS.md](OPENHANDS.md) §3.8).
- **Event grouping / thought hoisting** ([OPENHANDS.md](OPENHANDS.md)
  §3.7).
- **Overview panel + git prompt bar** ([OPENHANDS.md](OPENHANDS.md)
  §3.10).
- **Priced usage ledger + `/usage`** — per-turn usage accounting exists (it is
  the authoritative record compaction reads); what is missing is the
  price-at-turn-time ledger with peak-hour schedules and the surface that reads
  it ([OPENHANDS.md](OPENHANDS.md) §3.1,
  [AIDER.md](AIDER.md) #5, [MAKI-STEAL.md](MAKI-STEAL.md) #9,
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §4).
- **Session export / import / share**
  ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §3.5).
- **`question` forms + `/btw` side questions**
  ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Concurrent-session live-status picker**
  ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Git-first auto-commit + `/undo` discipline**
  ([AIDER.md](AIDER.md) #4).
- **Watch mode** — recorded, not endorsed; only if a user asks
  ([AIDER.md](AIDER.md) #7).
- **Delta-tracked live state for the web UI** — Chord-style path-coded deltas
  ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §4).

### Trust and security

- **Typed permission rules + static bash analysis**
  ([CODEWHALE.md](CODEWHALE.md) #3,
  [REASONIX.md](REASONIX.md) #3).
- **Tree-sitter-parsed bash permission scopes**
  ([MAKI-STEAL.md](MAKI-STEAL.md) #5).
- **Project trust gate** ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md)
  §2.3).
- **MCP OAuth2 + honest health verdicts; MCP client hardening** — the `oauth`
  support that shipped is the *provider* login path, not MCP
  ([OPENHANDS.md](OPENHANDS.md) §3.14,
  [REASONIX.md](REASONIX.md) #20, [MCP.md](MCP.md)).
- **Remote mode over an authenticated bus** — the bundled `nats-server`
  already accepts `--auth`, so the remaining work is `NIF_NAME` identity and
  the non-loopback/key-gated flags on the harness side
  ([OPENHANDS.md](OPENHANDS.md) §3.17,
  [REMOTE.md](REMOTE.md) §5–7).
- **OS keyring secrets** for provider keys
  ([CODEWHALE.md](CODEWHALE.md) D13).

### Providers and reliability

- **Strict tool-call sampling** where the provider supports it
  ([PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) A7).
- **Frozen-request unified retry** — the cost-split budget taxonomy and
  server `Retry-After` handling shipped; what is missing is retrying
  zero-content/missing-reasoning with the *identical* frozen request, and
  one-shot durable repair-consumption records
  ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §3.3,
  [REASONIX.md](REASONIX.md) #13).
- **Per-provider reasoning-protocol table** — `reasoning_effort` handling
  exists; a per-endpoint wire-shape table and reasoning-replay contracts do not
  ([REASONIX.md](REASONIX.md) #14).
- **Reflection loop** — lint/test/edit failures as typed retries with a cap
  ([AIDER.md](AIDER.md) #2).
- **Shell session env injection into `bash`**
  ([PI-NEXT.md](PI-NEXT.md) #2,
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §3.1).
- **Grep streaming early-kill** — output is already line-capped; the
  remaining half is killing the search once the cap is reached, plus rg/fd
  auto-download ([PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) A5, B5).

### Ecosystem, process and remote

- **Hooks with veto** — pre-tool-use block/ask inside the dispatch gate
  ([OPENHANDS.md](OPENHANDS.md) §3.5,
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §4,
  [CODEWHALE.md](CODEWHALE.md) #9 remainder,
  [REASONIX.md](REASONIX.md) #19).
- **Tool-surface lifecycle** — replay aliases + run checkpoints
  ([CODEWHALE.md](CODEWHALE.md) #5,
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §2.1).
- **Deferred tool loading beyond `onDemand`** — cache-preserving dynamic
  toolsets ([PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §2.2).
- **Architecture guard tests + specs with IDs**
  ([OPENHANDS.md](OPENHANDS.md) §3.12–13).
- **Eval harness with honest negatives + behavioral evals**
  ([REASONIX.md](REASONIX.md) #5,
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §3.6,
  [CODEWHALE.md](CODEWHALE.md) D2).
- **Supply-chain policies for packages** — pinned refs, min-release-age, an
  npm lifecycle-script stance (pairs with *Component package template* below;
  [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) §4,
  [MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Generated docs with a CI drift check** for the plugin/SDK API
  ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Slash-command scope cascade** — `/project:` `/user:` scoping; the skill
  discovery half shipped ([MAKI-STEAL.md](MAKI-STEAL.md) "Smaller items").
- **Claude-Code-wire-compatible headless mode** — `cli run` speaks NDJSON with
  our own schema; matching Claude Code's `stream-json` field names would make
  Niffler a drop-in in orchestrators built for it
  ([MAKI-STEAL.md](MAKI-STEAL.md) #11).
- **`cli` control-plane contract + one durable runtime for detached work**
  ([CODEWHALE.md](CODEWHALE.md) #6–7).
- **Modes and postures** as session policy
  ([CODEWHALE.md](CODEWHALE.md) D6).
- **Declarative plugin bundles + skills routing metadata**
  ([CODEWHALE.md](CODEWHALE.md) D7–8).
- **Lifecycle event outbox** ([CODEWHALE.md](CODEWHALE.md) D9;
  overlaps *durable Fabric/agent traces* below). Process-completion slice is
  implemented: durable record-before-notify, bounded wake/pull, post-append ack,
  direct-start ownership, orphan interruption recovery and seven-day acknowledged
  retention. Processes + retired/busy-runner contracts pass; fleet remains separate.
- **Fleet follow-ups** — delegation, remote job reconciliation, artifacts and
  background approvals; see [the active plan](../PLAN.md) and
  [FLEET-IMPLEMENTATION.md](FLEET-IMPLEMENTATION.md). Broader remote topology
  alternatives remain design history in [REMOTE.md](REMOTE.md).
- **Capability diagnostics** — a `doctor`-style probe over the live catalog
  ([REASONIX.md](REASONIX.md) #10).
- **Worker-aware Nim pump** — deferred until a mixed-stateful component
  outgrows replicas ([PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md)
  B1b, [PI_EFFICIENCY_B1B_THREADS.md](PI_EFFICIENCY_B1B_THREADS.md)).

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
