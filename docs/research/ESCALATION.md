# Escalation — dynamic model and thinking selection

Status: **proposal** (nothing here is implemented). Explored 2026-09-11 against
niffler@HEAD and `~/git/deepseek-harness`@HEAD. Companions:
[EXPERT.md](EXPERT.md) (the observing peer), [CODEWHALE.md](CODEWHALE.md)
(named cache-miss reasons, `--model auto` routing), and
[DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) / [DSH-STEAL.md](DSH-STEAL.md)
(dsh research). dsh findings below were read directly from the repo, not from
the earlier research notes.

The idea: a conversation should be able to **escalate** — first thinking
effort, then model — when it is failing, **give up honestly** when the ladder
is exhausted, and **de-escalate** back to a cheap route when the work becomes
routine again (test, commit, push). Three questions decide the design:
who notices the failure, who decides to give up, and who decides it is safe
to come back down.

## 1. What Niffler can already do (verified)

The switching mechanics exist today. Only the decision-maker is missing.

| capability | where |
|---|---|
| Conversation-scoped model override; a model-only `session` call persists and resolves **without inference** | `core/conversation.nim:1218` (`handleSessionCall`), `:1349-1356`; `docs/MANUAL.md:388` |
| Per-conversation thinking effort (`""` / low / medium / high / max), validated and persisted the same way | `core/conversation.nim:1356-1358` |
| Both survive runner restarts in the conversation header | `core/conversation.nim:154-155` (`modelOverride`, `thinkingEffort`), `:292` (`persistConversationRuntime`) |
| Per-turn resolution: `llm_resolve` once at turn start; the new model's context window reaches the context guard **before** inference; the model is then pinned across every tool round of the turn | `core/conversation.nim:570` (`resolveTurnConfig`), `:793-795` |
| Effort forwarded per round as `reasoning_effort`; llm maps it per provider (Anthropic → adaptive thinking) | `core/conversation.nim:918-919`; `components/llm/main.go:422-426`; `components/llm/anthropic.go:229` |
| Cache cost of a switch is bounded and nameable: model/thinking are request params, not prefix; the CodeWhale borrow doc already lists `change:model` / `change:thinking` as the legitimate named miss reasons | `docs/research/CODEWHALE.md:84` |
| Introspection: `session_info` / `prompt_preview` surface `model`, `modelOverride`, `provider`, `thinkingEffort`; the turn status event carries the used model and effort | `core/dispatch.nim:554-555`, `:627`; `core/conversation.nim:1009-1015` |
| Per-job escalation **by delegation**: `agent_run {task, model?, thinking?, maxRounds?, maxCalls?, maxTokens?}` | `docs/MANUAL.md:1570` |
| Model catalog the LLM can read: `models_list/get/resolve` (onDemand) with capabilities, limits, prices | `components/models/main.go:93-204` |
| UI switching: model selector; effort cycle `"" → low → medium → high → max` | `ui/frontend/src/lib/effort.ts:10-12` |
| An observing peer with judgment infrastructure: multi-target expert follows sessions, injects fail-closed advice as marked user messages | `docs/research/EXPERT.md`; `core/conversation.nim:612` (`drainAdvisories`) |
| Give-up hard ceiling already exists: round / call / token budgets end a turn as budget-exhausted | `core/conversation.nim:1170`, `:1083`, `:885` |

### The gap

- **The model cannot switch itself.** `session` is `x-harness.hidden` and
  unreachable through `invoke` (`core/dispatch.nim:876`); it is UI/CLI-only.
  The LLM's only model lever today is choosing a route for a *subagent*.
- **No policy.** Nothing watches turn outcomes, counts consecutive failures,
  or moves a rung. No escalation budget, no cooldown, no notices.
- **No per-route effort metadata.** `thinking` is a global enum; the catalog
  knows a model reasons (`reasoning` flag) but not which efforts it supports.
  dsh models this properly (§3.2).
- **Small bug while we are here:** the `session` tool schema enum omits `"max"`
  (`core/catalog.nim:188`) while the handler accepts it
  (`core/conversation.nim:1356`) and the UI offers it (`effort.ts:12`).

## 2. Prior art across harnesses

| harness | mid-convo switch | thinking control | automatic escalation | verification |
|---|---|---|---|---|
| Niffler | yes — header override, turn-pinned | global low…max | none | this repo |
| pi | `/model` (Ctrl+L); `--model pattern:thinking` | `off…max`, per-model `thinkingLevelMap`; `supportsMidConvoEffort` = per-turn effort for Claude, with `drop_block` thinking-binding controls | none found in docs | README:181, `docs/models.md:261,397` |
| Claude Code | `/model` mid-session; model-change attribution arrives as a conversation note | per-model effort; `ultrathink` keyword = one turn at high effort | no built-in; `PreModelSwitch`/`PostModelSwitch` hooks are the bolt-on point | public CHANGELOG (0.2.44; hooks; "Fixed switching models with /model re-sending every tool definition (a prompt-cache miss)") |
| Gemini CLI | `/model` | thinking levels | **yes** — Auto routes Pro/Flash per *task complexity*, not failure | repo docs `cli/model.md` |
| CodeWhale | `--model auto` per-turn routing to a concrete model + thinking level; designated aux model ("Fin") for cheap internal calls | routing emits both | yes — declared up front, not failure-driven | `docs/research/CODEWHALE.md` D5 |
| dsh | yes — mutable selection + ACP config, step-pinned, with a durable switch notice | adapter-owned per-route effort ladders | none | repo, §3 |
| Cursor / Windsurf | "auto" model selection, background thinking | — | plausibly yes | memory, unverified |

Conclusion: **nobody verified ships failure-driven, budgeted, bidirectional
escalation with an observing judge.** The pieces are scattered: CodeWhale has
up-front auto routing, dsh has the give-up protocol, Claude Code has the
hook seam, pi has the per-model effort vocabulary — and Niffler already has
the switching mechanics plus an expert peer. The composition is the idea.

## 3. What dsh actually has

### 3.1 Mid-conversation switching, first-class (`packages/core/agent/src/model-selection.ts`)

A mutable `ModelSelection {provider, model, reasoningEffort?}` per Agent,
coupled by three waterfall listeners: prompt assembly snapshots the selection,
request routing applies it, and `agent/pre-step` appends the switch notice.
Semantics:

- **Step-pinned, like Niffler's turn-pinning.** "A concurrent switch takes
  effect on a later step instead of splitting the two surfaces." Never
  mid-request.
- **A durable user-role notice on route change:**
  `[model changed: assistant turns above this point were generated by X; the
  session continues with Y]` — persisted in the transcript, provider names
  only when crossing providers, **effort-only changes add no notice**, and the
  notice repeats if the request fails before header persistence.
- Niffler flips the header silently instead. For a *bidirectional* ladder the
  notice matters (the stronger model should know the failure history came
  from a weaker one; the cheaper model should know what was already
  verified) — but every bounce costs one message, which makes hysteresis
  (§4.5) more important, not less.

Client surface: ACP exposes the selection as two session-config options,
`model` and `reasoning_effort`, pinned per admitted turn
(`packages/acp/acp/src/model-control.ts:16-17`, `pinTurn`). Production
switching is client-driven only; `agent-default-model` is just the
settings-backed default for *new* agents.

### 3.2 Effort as per-route capability data

`LlmReasoningEffortInfo {id, name, description?}` and
`LlmModelReasoningInfo {efforts, defaultEffort}` are adapter-owned per
provider/model route (`packages/llm/llm/src/types.ts:318-338`); the DeepSeek
adapter publishes `off/low/high/max` plus off-only variants for
thinking-incapable models (`packages/llm/llm-deepseek/src/adapter.ts:168-194`).
The UI can therefore render the *model's* effort ladder, not a global one.
Niffler's hardcoded enum cannot express "no max on this model" or per-route
defaults. pi's `thinkingLevelMap` (with holes) is the same idea from the
client side.

### 3.3 Per-job routes, with a governor

- Subagent delegation takes optional `provider` / `model` / reasoning-effort /
  token overrides; continuable children snapshot the resolved route in their
  durable descriptor for cold resume (`docs/subsystems/subagent.md:40,263`).
- `ctx.subagentModelSelection` is a settings owner restricting delegation to
  **exact allowed routes** (`subagent.md:472-484`) — a governor for per-job
  model choice, which is exactly what an escalation ladder needs so a
  runaway policy cannot route to arbitrary priced models.
- Workflow phases carry per-phase `{provider, model}`: model-authored
  orchestration declares target models up front
  (`packages/workflow/tool-workflow/src/index.ts:139,157`).

### 3.4 No automatic escalation — confirmed

The only "escalation" in dsh is sandbox permission escalation
(`sandbox/src/escalation.ts`; DEEPSEEK-HARNESS.md §5). The llm stream is a
waterfall, "so retry/routing/replay are just listeners"
(`llm/llm/src/index.ts:1122` via DEEPSEEK-HARNESS.md §6) — the seam exists,
but nothing ships a routing or escalation listener. The prior research notes
walked past exactly this line.

### 3.5 The goal give-up protocol (the prize)

`docs/subsystems/goal.md`, `packages/goal/tool-goal`:

- Autonomous goal rounds under a hard `maxGoalRounds` cap; durable phases
  `active / paused / blocked / complete`.
- **The model itself** reports the terminal state each round (`complete` or
  `blocked` via `update_goal`).
- **Anti-flapping gate:** a model-sourced `blocked` call is *mechanically
  rejected* until the same condition has persisted for
  `blockedAfterConsecutiveRounds` (default **3**) consecutive rounds — "the
  model judges whether the same condition actually persisted and must
  describe it in `blocked_reason`" (README:55). A human stops immediately.
- The block reason is durable and **machine-routable**:
  `GoalBlockReason {code, message}` — "a stable lower-kebab-case
  classification chosen by the blocking policy... for routing"
  (`goal.md:32`); autonomous blocks persist under the stable code
  `model-reported` (README:40).
- Terminal rounds defer a `<goal_complete>` / `<goal_blocked>` wrap-up
  instruction forcing a grounded closing report — "Report only what earlier
  rounds and tool results in this session actually establish"
  (`packages/goal/tool-goal/src/wrapup.ts`).
- `resume` re-arms blocked goals (human, via `/goal resume` or Web).

Read: the LLM decides, a deterministic gate enforces persistence-before-give-up,
and a structured reason survives for routing — **and nothing routes on it
yet.** That hook is where an escalation policy plugs in: block after N rounds
→ escalate the route → resume.

## 4. The Niffler design

### 4.1 Application point: turn boundaries only

The turn-pinned model (`runTurn` resolves once, pins across rounds) is the
right invariant — keep it. Escalation is a **model-only `session` call between
turns**, which already persists and resolves without inference. Mid-turn
switching is excluded by design (coherence and cache); if a turn is failing
that badly, ending it and escalating the next one is the honest move.

Cache: a model change re-reads the prefix once on the new provider (named
`change:model`); a same-model thinking bump keeps the KV cache entirely.

### 4.2 The ladder

Rungs are `(model, thinking)` pairs ordered by cost/capability, e.g.:

```
rung 0: fast/cheap model, thinking "" (provider default)   ← conversation entry
rung 1: same model, thinking high
rung 2: strong model, thinking medium
rung 3: strong model, thinking high
rung 4: strongest model, thinking max                      ← top; give-up lives here
```

Configured as a store record owned by the policy component (single-writer
sieve) with env fallbacks. Needs per-route effort metadata (steal 2) so the
policy climbs only rungs the route actually supports. Every rung change
updates the conversation selection via `session`, emits an escalation event,
and (for model changes) appends the switch notice (steal 1).

### 4.3 Who decides — three candidates, one hybrid

- **A. Deterministic signal policy** (the spine). The runner already emits
  everything needed on the bus: tool errors (`ev.session.toolcall` with
  error/result), retry exhaustion (B3), and budget-exhausted turn ends with
  error text (`conversation.nim:885-891,1083,1170`). A policy component
  counts consecutive failed turns per conversation, applies cooldown, and
  moves one rung per threshold crossing. Cheap, explainable, no judge lag.
- **B. Expert-judged** (the arbiter). Extend the expert component from
  advice-only to structured verdicts (`escalate|deescalate|hold` + rung) —
  it already has multi-target following, bounded turn observations, a
  cache-stable knowledge prefix, and fail-closed delivery. Use it when the
  deterministic signals are ambiguous (tool "succeeded" but the model is
  clearly flailing).
- **C. In-band self-escalation** (optional). A visible tool letting the model
  request its own upgrade, with a mandatory reason and the same caps. A stuck
  model is a poor judge of its own stuckness; if built at all, it goes behind
  the governor and the same budget.

Recommendation: **A as the spine, B as the arbiter, C optional** — the same
split the expert already embodies ("deterministic code gathers evidence and
enforces delivery safety; the expert model decides").

### 4.4 Give-up (dsh's protocol, rebased)

- The policy counts consecutive failed turns **at the top rung**; give-up is
  mechanical: only after K (default 3) consecutive failures — the dsh
  anti-flapping gate. The model may *propose* giving up (a tool or a marked
  reply); the gate still enforces persistence before accepting it.
- On give-up: persist a routable reason `{code, message}` (steal 4), defer a
  grounded wrap-up instruction as a user-role message so the closing turn
  states what was done, what failed, and what it needs (steal 5), and leave
  the conversation resumable. A human stop (steer/cancel) always wins
  immediately, and budget exhaustion remains the hard ceiling that already
  exists.
- Auto-resume after give-up is the escalation analog of dsh's goal `resume`:
  only ever onto a *stronger* route, only if the ladder allows (steal 7).

### 4.5 Down-escalation and hysteresis

- Deterministic phase signal: a streak of cheap, read-only/test/commit-family
  tool calls with no failures — the exact "work is done, now just
  test/commit/push" phase — drops one rung; the expert can also issue
  `deescalate`.
- Never drop below the conversation's entry rung unless the human asked.
- **Hysteresis is not optional in a bidirectional ladder:** up after N
  consecutive failures (small, e.g. 2); down only after M consecutive clean
  turns (larger, e.g. 5) plus a checkpoint; a cooldown between any two
  moves; one rung per move. Every bounce costs a provider cache re-read and
  (with steal 1) a notice.

### 4.6 Topology and the sieve (DSH-STEAL §1 style)

A new **`escalate` component** — a peer on the bus, like `expert`:

| invariant | check |
|---|---|
| Peers, not frameworks | escalate is a component process, not a core mode. v1 needs **zero core changes**: it subscribes `ev.session.*`, counts, and applies `svc.session.<id>.call {model?, thinking?}` — the same wire surface the UI uses |
| Prompt-cache discipline | model/thinking are request params, never prefix; the switch notice is append-only history; no new prefix contributor |
| Store single-writer | escalate owns an `escalation` record kind (state, counters, reason codes, rung history). Conversation headers stay core's; the *selection* moves through `session`, which core already persists |
| No `asyncdispatch` | standard synchronous pump; thresholds evaluated on event arrival |
| Fail-open where convenience lives | a missing/dead escalate component costs escalation, never a turn — the conversation runs exactly as today |
| Fail-closed where correctness lives | the give-up gate and the routes governor are in the policy itself; a malformed ladder config disables escalation rather than improvising |
| Approvals | `session {model, thinking}` is approval-free today (the UI does it mid-conversation); escalation inherits that, bounded by the governor |

The expert extension (B) reuses its existing judgment contract; the judge's
prefix gains the ladder + current counters, and the verdict schema replaces
free-text advice for this lane. Fail-closed delivery is already its contract.

## 5. Steal list

| # | steal | dsh origin | Niffler host |
|---|---|---|---|
| 1 | Durable model-switch notice (model changes only; effort-only silent; repeats until header persists) | `agent/src/model-selection.ts` | runner appends the notice message on a model rung change |
| 2 | Per-route effort capability data (effort list + default per model) | `llm/llm/src/types.ts:318`; `llm-deepseek/adapter.ts:168` | `models` component catalog extension; `session` validates `thinking` against the route |
| 3 | Consecutive-blocked give-up gate (default 3) | `tool-goal/README.md:55` | policy counter in the `escalation` record |
| 4 | Machine-routable reason `{code, message}` | `goal.md` `GoalBlockReason` | escalation event payload + store record; consumed by expert/policy |
| 5 | Grounded terminal wrap-up instruction | `tool-goal/src/wrapup.ts` | deferred user-role message on the give-up turn |
| 6 | Allowed-routes governor | `subagent.md:472` (`ctx.subagentModelSelection`) | escalate config: approved route set + per-conversation rung budget |
| 7 | Resume-as-escalation | goal `resume` re-arms blocked | auto-resume on a stronger route after a give-up, only if the ladder allows |

## 6. Open questions

- **Notice economics.** With steal 1, a bouncy ladder pays one message per
  model move; is a per-conversation cap on total rung moves the right
  constraint, or a cooldown alone?
- **Counter ownership.** The failed-turn counter lives in escalate's own
  record, but turn outcomes arrive via `ev.session.turn` / `done {error}` —
  is error-text classification (budget vs provider vs model failure)
  deterministic enough, or does it need an expert judgment too?
- **Escalate vs delegate.** `agent_run {model, thinking}` already exists.
  Self-escalation keeps the (large, cached) parent context; delegation keeps
  the parent cheap but re-primes from scratch. Heuristic: escalate when the
  failure is *reasoning* (same context would help); delegate when it is
  *volume* (fresh context would help).
- **Compaction interaction.** Does a `reset:trim` reset the failure counter?
  (Probably yes — trim correlates with long struggles.)
- **Cost telemetry.** `ev.session.status` already carries provider/model/
  tokens per turn; add the current rung so spend per rung is measurable.

## 7. Smallest first step

v1 with zero core changes: the `escalate` component — env-configured ladder,
failure counter over `ev.session.turn`, model-only `session` calls, an
`escalation` store record, and `ev.escalation.*` events. Then: the switch
notice (small runner change), the give-up gate with wrap-up, the expert
verdict lane, and per-route effort metadata in `models` — in that order,
each independently useful.
