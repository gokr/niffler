# OpenHands Agent Canvas — what to steal from a server-first control plane

> Research note — external codebase analysis, one file, not a plan. The
> checkout at `~/git/harnesses/OpenHands` is **Agent Canvas** only (`28464621d`,
> 2026-09-13): the React/TS frontend. The agent loop, tools and API live in
> sibling repos (`software-agent-sdk`, `typescript-client`, `extensions`,
> `automation`) that are *not* checked out here, so every claim below is either
> cited from this repo or read from its docs describing those repos.
>
> Niffler baseline: this clone's `core/`, `components/`, `ui/`,
> `docs/MANUAL.md` (commit `6be9748`, 2026-09-13). Companion docs:
> [REMOTE.md](REMOTE.md) (OpenHands as the remote-runtime prior art),
> [../PI-VS-NIFFLER.md](../PI-VS-NIFFLER.md),
> [CODEWHALE.md](CODEWHALE.md) (permission rules),
> [../MANUAL.md](../MANUAL.md) (approvals, discovery, MCP).

## 0. What OpenHands *is*, in one paragraph

OpenHands is the one harness in the tracked set built **server-first**: an
Agent Server owns the sandbox, the tool executors, per-conversation state and
the event stream; the browser is a thin canvas over REST + WebSocket. That
single architectural choice explains almost everything on this list — because
the UI never touches the machine, it can be a *product*: multi-backend
switching, per-conversation budgets, transcripts, cost meters, git control
bars, automations, ACP passthrough to other agents. The parts worth stealing
are therefore mostly **product-grade control surfaces and two protocol ideas**,
not agent-loop internals. It is also the harness whose *shape* Niffler most
resembles (addressable control plane, sessions as first-class objects) while
sharing almost none of its implementation.

## 1. What it has that Niffler does not (the inventory)

Grouped by where the value is. "Niffler today" is the honest baseline.

### A. Agent-loop / model-plane features

| OpenHands | Mechanism (where seen) | Niffler today |
|---|---|---|
| **Per-conversation cost meter** — `max_budget_per_task`, live `cost` per run, USD totals per conversation and per automation run | `StartConversationPayloadBase.max_budget_per_task` (`src/api/agent-server-adapter.ts:73`), `CostSection`/`BudgetDisplay` (`metrics-modal/cost-section.tsx`), `AutomationRun.cost` (`src/types/automation.ts`) | `models` seed carries `cost.input/output/cache_read` (`components/models/seed.json`) but **nothing reads it**; usage accounting is tokens only (`conversation.nim` `promptTokens`/`cacheRead`) |
| **Stuck detection** — a distinct `execution_status: "stuck"`, not an error | `stuck_detection: true` on every conversation start (`agent-server-adapter.ts:1248`), `ExecutionStatus.STUCK` (`types/agent-server/core/base/common.ts:74`) | Round/call/token budgets end a turn as `budget-exhausted` (`conversation.nim:888`, `:1107`); no *repetition* detector — dispatch has only a naive exact-repeat guard for advice (`dispatch.nim:85`) |
| **Goal loop** — `/goal [--max N] <objective>` runs the agent, an LLM judge audits completion, re-prompts until done or capped; live status banner + inline finish | `hooks/chat/use-goal-interceptor.ts`, `stores/goal-store.ts`, `GoalStatusBanner`, SDK goal prompts filtered from chat (`should-render-event.ts`) | Nothing. Closest is ESCALATION.md's *proposal* (nothing implemented): a give-up gate, not a completion loop |
| **Condenser (auto + manual compaction)** — threshold-triggered LLM summarization, a *user-visible* "Compact context" action with tokens-freed feedback, and a settings page | `enable_default_condenser`, `condenser_max_size` (`src/types/settings.ts:131`), `routes/condenser-settings.tsx`, `compact-context-button.tsx` (`POST /conversations/{id}/condense`) | `reset:trim` — whole-turn drops with a `[context trimmed]` marker. COMPACTION.md is a design doc; nothing shipped |
| **Auxiliary model profile for title generation** — `autotitle: true` + a *separate* `title_llm_profile` | `agent-server-adapter.ts:1087-1088, 1249-1251` | Auto-title is the first non-blank line of the user's message (`conversation.nim:1203`), no LLM call. AIDER.md already flagged "weak model for auxiliary calls" |
| **Security analyzer + confirmation mode as *policy objects*** — `security_analyzer: "llm" \| "none"`, `confirmation_mode: bool`, and per-action `SecurityRisk` (LOW/MEDIUM/HIGH) shown on the tool card | `types/settings.ts:128-129`, `SecurityRisk` (`core/base/common.ts:59`), `tool-visualizers/bash.tsx` risk badge | Approval is binary on the whole call (`x-harness.approval: "always"`); no risk classification, no per-action confirmation toggle |
| **`max_iterations`, posted per conversation** | `settings.ts:130` | `maxRounds`/`maxCalls`/`maxTokens` exist per session *and* per `agent_run` job (`catalog.nim`, MANUAL §Fabric) — Niffler is **ahead** here |
| **Persistent memory as an agent setting** (`agent_context.load_memory`) | `agent-server-adapter.ts` comment block; global preference applied to profile-resolved agents | `AGENTS.md` chain into the system prompt (`systemprompt`) + `skills`; no opt-in per-conversation memory toggle |
| **Multimodal input** (image content parts; image upload in chat, image E2E test) | `TextContent`/image content (`core/base/common.ts:85`), `tests/e2e/mock-llm/conversations/mock-llm-image-upload.spec.ts` | No image path anywhere: `conversation.nim` builds text-only messages; `llm` Go adapter has no image content mapping (verified by grep) |

### B. Harness / plumbing features

| OpenHands | Mechanism | Niffler today |
|---|---|---|
| **ACP passthrough** — drive Claude Code / Codex / Gemini CLI as the agent *inside* the same UI, provider registry sourced upstream | `docs/ACP_AGENTS.md`, `api/acp-service/`, `constants/acp-providers.ts` | `llm` component speaks provider protocols directly (openai/anthropic/codex OAuth); no "run another harness as the loop" mode |
| **Session hooks with veto** — `PreToolUse`/`PostToolUse`/`UserPromptSubmit`/`SessionStart`/`SessionEnd`/`Stop`, each with `matcher`, `command`, `timeout`, `async`, `blocked`, `reason`; workspace `.openhands/hooks.json`; UI modal listing them | `types/agent-server/core/events/hook-execution-event.ts`, `api/hooks-service.ts`, `conversation-panel/hooks-modal.tsx` | `hooks` component is explicitly **observe-only** (docs/MANUAL.md §Hooks): fires on bus subjects, can never block. Veto was consciously deferred |
| **MCP: OAuth2 + 6 auth strategies + health probes + per-server test with a read-only probe tool** | `types/mcp-auth.ts` (`none/api_key/bearer/basic/header/oauth2`), `api/mcp-health/probe-mcp-server-health.ts` (`verified` vs `connectivity-only`) | `mcp` component has `${NAME}` secret-by-reference, redirect-origin refusal, approval, drift, lazy sessions — strong — but only static headers; no OAuth dance, no health state machine, no "probe tool actually invoked" verification |
| **Per-conversation git worktree by default** (`worktree: true`) plus child conversations with `isolation: "worktree" \| "shared"` | `agent-server-adapter.ts` (`worktree`), `launch-child-conversation-client-tool.ts` | `cwd` pins a workspace inside `NIF_ROOT` (MANUAL §Context window); DSH-STEALS-PLAN has isolated worktrees for subagents as **deferred** fabric work |
| **Client tools** — the frontend registers tool *schemas* into the conversation; the server acks immediately and the *browser* executes the effect, reporting back as a user message | `canvas-ui-client-tool.ts` (drive the UI: navigate to file, open tab, show preview), `launch-child-conversation-client-tool.ts` (spawn a sibling conversation), `client_tools` on the start payload (`agent-server-adapter.ts:1241`) | No equivalent. A UI-effect tool would today be a normal bus tool the UI happens to subscribe to — but nothing formalizes "the client *is* the tool executor" |
| **Multi-backend registry** with specs BM-001..003 (auto-switch on connect, same page on switch, fallback on removal, never stale) | `specs/backend-management.md`, `api/backend-registry/`, `contexts/active-backend-context` | REMOTE.md calls these exact specs "a good spec to steal"; nothing implemented (`NIF_NAME` identity, fleet UI are planned) |

### C. UI / product surfaces (the actual differentiator)

OpenHands' UI is where its investment shows. All of it rides the event
stream that Niffler already publishes (`ev.session.*`), so these are
*renderers and affordances*, not architecture:

| Surface | Where | Niffler today |
|---|---|---|
| **Typed tool visualizers** — a registry keyed by action/observation `kind`; bash renders a code block + output pane + exit badge + risk warning, file editor renders a diff, search renders hit lists, task renders a tracker, markdown renders a preview; unknown kinds fall back to markdown | `components/features/chat/tool-visualizers/{define.ts,dispatcher.tsx,bash/,file-editor/,search/,task/,primitives/}` | `views/ToolRun.svelte`: one generic `<details>` card, a `preview()` heuristic on `command`/`path`/`filePath`, then a JSON dump. `docs/PLAN.md` "Level 1 UI dynamism" (`x-ui` hints + generic renderer registry) and Level 2 (builder-compiled Svelte modules) are the planned equivalents — **nothing shipped** |
| **Event grouping** — consecutive groupable events fold into one collapsible card; thoughts are *hoisted out* of collapsed groups into the main stream; dedicated renderings (Finish/Think/hooks/errors/task tracker/markdown artifacts) break groups | `conversation-events/chat/group-events.ts` | Chats emit each tool call separately; the TUI has tool levels (brief/full/off), the SPA has the same three levels but no folding |
| **Conversation overview panel** — pinned sections (workspace, git), git sub-parts (changes/repository/branch/commits/PRs) with per-part pinning persisted per conversation | `conversation-overview-panel.tsx`, `conversation-overview-sections.ts` | Nothing; the SPA has a chat and a session list |
| **Git control bar** — pull/push/commit/PR/branch buttons that *generate prompts* rather than executing (agent does the git) | `chat/git-control-bar*.tsx`, `utils/utils.ts` `getCreatePRPrompt(...)`, `conversation/conversation-git-actions-menu.tsx` | `git` component is read-only inspection (`git_status/diff/log/show/blame`); no UI affordance, no prompted-git pattern |
| **Right-side tabbed panel** — files (tree + viewer + diff mode), terminal (xterm), browser (screenshots + get_state), VS Code deep-link, planner (`PLAN.md` rendered live from a *helper conversation*), task list | `routes/*-tab.tsx`, `conversation/tabs/` | SPA has no file browser, terminal, or diff view; the desktop app is chat+sessions+components |
| **Terminal (xterm + browser screenshot) tab** | `components/features/terminal`, `browser` | No terminal component at all (`processes` is the *tool* for long-running commands; no UI) |
| **Transcript export** (markdown/HTML) with a complete-events loader | `conversation/transcript-export-modal.tsx`, `utils/transcript-export/` | AGENTS.md documents a store→markdown recipe for humans; no product feature |
| **Conversation management** — archive, tags, folders/groups, pin, rename, "hide older", per-conversation local state, active-conversation sidebars | `conversation-panel/*`, `conversation-panel-list-helpers.ts` | Sessions list with rename + delete (`views/Sessions.svelte`) |
| **Notifications + tab-title emoji per state** + sound on `AWAITING_USER_INPUT`/`FINISHED`/`AWAITING_USER_CONFIRMATION` | `hooks/use-agent-notification.ts`, `utils/agent-state-emoji.ts`, `use-app-title.ts` | None |
| **Schema-driven settings pages** — the server publishes agent/conversation settings *schemas* (sections, fields, prominence critical/major/minor, per-field metadata); the UI renders them generically with basic/advanced/all views and a dirty-state diff-save | `utils/sdk-settings-schema.ts` (513 lines), `settings/sdk-settings/sdk-section-page.tsx`, `schema-field.tsx` | Config is env vars + `.env` + per-component JSON (MANUAL §Environment variables); the SPA has hand-built forms (provider, MCP) |
| **Slash-command menu with per-command pickers + macros** | `components/features/chat/slash-command-menu.tsx`, `controls/macros-submenu.tsx` (`setMessageToSend` prompt macros), suggestions on empty chat | Niffler has a **richer** declarative slash registry (`ui/frontend/src/lib/slash.ts`: component-published commands, param sources, subcommands, completion, aliases) — but no macros/suggestions and the TUI shares the design |
| **i18n** — 15 locales, ~2.4k message keys, CI completeness check | `src/i18n/translation.json` (1.9 MB), `scripts/check-translation-completeness.cjs` | `ui/frontend/src/lib/i18n.svelte.ts` has en/zh/zh-TW inline (156 keys × 3) |
| **Automations** — cron + webhook triggers, JMESPath filters, run history with phases/costs/status counts, templates, export/import, per-automation git sync | `types/automation.ts`, `api/automation-service/`, `routes/automation-*.tsx`, `manifests/` (declarative setup schemas) | `agent_spawn` gives durable background *jobs*; no schedule, no webhook, no run history UI, no templates |

### D. Engineering / process

| OpenHands | Where | Niffler today |
|---|---|---|
| **Machine-enforced architecture guards as tests** — `src/api/no-direct-agent-server-calls.test.ts` scans every `.ts/.tsx` and fails on `axios(`, `fetch('/api/…')`, direct `HttpClient` construction outside an allowlist; the review guide says "repeated review guidance should become a lint rule, compiler boundary, or architecture test" | `src/api/no-direct-agent-server-calls.test.ts`, `.agents/skills/custom-codereview-guide.md` | No equivalent guard: nothing prevents a component from reaching around the bus, or a UI from calling a component directly. `t_approval_manifest.nim` is the closest (it asserts approval annotations) |
| **Specs as living checkboxes** — `specs/*.md` with IDs (`BM-001`, `MCP-001`, `WUP-001`) and `- [x]` assertions, each referenced by tests | `specs/backend-management.md`, `specs/mcp-settings.md` | Design docs are prose (REBOOT, WIRE, MANUAL); no ID'd assertions that tests cite |
| **Mock-LLM E2E** — a scripted OpenAI-compatible server (`TestLLM` trajectories) + Playwright, so full UI flows run in CI without a provider; mock-ACP server for the ACP path; live E2E separate | `tests/e2e/mock-llm/scripts/mock-llm-server.py`, `playwright.mock-llm.config.ts`, `docs/TESTING_MATRIX.md` | `tests/mock_llm.nim` plays the same role at the bus level (scripted envelopes) — Niffler's version is arguably *cleaner*; the missing half is UI E2E |
| **Ad-hoc HTTP allowlist test** (same idea, narrower) | included above | — |

## 2. What OpenHands *lacks* that Niffler has (so the picture is fair)

Worth stating, because several "steals" above interact with these:

- **Component processes / self-extension.** OpenHands extension points are
  *files in a repo* (plugins, skills, canvas extensions) installed into a
  server-owned directory; an extension can affect the UI (same-realm JS) or
  the agent, but cannot be a new capability process mid-conversation. Niffler's
  `builder` + `core.spawn` has no analogue there. Canvas Extensions is the
  closest (see §4.1) and it is UI-only, trusted-code, no permissions.
- **A real wire contract.** OpenHands' "wire" is REST + a WS event stream with
  per-version compatibility shims (`agent-server-compatibility.ts`, `MIN_AGENT_SERVER_VERSION_FOR_*` constants, and comments like "older agent-servers ignore the field"). Niffler has one envelope spec, and the `cli`/`console` are same-protocol citizens; OpenHands has no scriptable bus face.
- **Tool profiles / progressive discovery.** `discover`/`invoke` with a frozen
  direct set and explicit cache-effect reporting has no OpenHands equivalent —
  its toolset is whatever the agent/profile exposes.
- **Fabric / programmable tool calling** — no equivalent.
- **Approvals as a bus protocol** with directed-then-broadcast fallback and
  fail-closed when no human is reachable (`ev.approval.*`). OpenHands has
  confirmation *mode* (a setting the server enforces) and hook veto, but the
  human-attachment protocol is a Niffler idea.
- **Multi-language SDKs** (Nim/Go/TS) with the envelope as a ~200-line portable
  artifact. OpenHands' SDK is Python (server) + generated TS client.

## 3. The steal list, ranked

Each item: what it is, why it fits Niffler, the shape, effort.

### 3.1 Cost accounting from the catalog we already ship — **small, high value**

`components/models/seed.json` already carries `cost: {input, output, cache_read}`
per model (from models.dev), and `conversation.nim` already persists
`promptTokens`, `cachePrompt`, `cacheRead`, `completion_tokens` per message.
The only missing step is arithmetic.

Borrow OpenHands' *surface*, not its implementation: a per-conversation
`costUsd` derived at the same place usage is accumulated, persisted in the
conversation header, emitted in `ev.session.status` (alongside
`cacheHitRatio`, which Niffler already computes better than OpenHands does),
and rendered by the SPA/TUI as a small `$0.0123` chip. Add an optional
`NIF_MAX_COST_USD` (or per-session `maxCostUsd`) that ends the turn like
`maxTokens` does — that's the `max_budget_per_task` half, and it slots into
the *existing* budget-exhausted path in `conversation.nim:~885`.

Deliberately **not** the OpenHands shape: no separate "budget" object, no
progress bar (Niffler has no cost *cap* concept in config), and no USD in the
prompt-cache path — it's an audit/guard number, not a model input.

Cache effect: pure append — cost lands in `ev.session.status` and the header;
**no** frozen-prefix change. COMPACTION/CONTEXT-REVIEW economics stay intact.

Effort: a day including tests (`t_ctx_accounting.nim` already asserts usage
accounting; extend it). Note it also makes bench reports comparable with the
OpenHands/pi numbers already in `bench/`.

### 3.2 Stuck detection — **small, distinct from budgets**

OpenHands ships `stuck_detection: true` and a distinct terminal state; the
failure mode it names is real and Niffler's budgets are the *wrong* tool
(they cap spend, they don't notice a loop). Niffler's session loop has
everything needed to detect it cheaply, deterministically, at dispatch:

- a dispatch fingerprint ring (tool + normalized args) per turn;
- repetition of the *same* fingerprint ≥ N times, or alternating A/B ≥ N
  pairs, with no workspace-state change (`git status` hash or mtime high-water)
  → end the turn as `stuck` (a new terminal error like `budget-exhausted`,
  not a new status enum in core);
- optionally one *steer* through the existing `svc.session.<id>.steer` channel
  before giving up ("you have called X with identical arguments 4 times") —
  the expert peer already proves that channel works mid-turn.

The event contract is where OpenHands' UI experience is instructive: emit
`ev.session.status {stuck: true, reason, fingerprint}` so a UI can render the
distinct state (banner, emoji, notification) without core knowing about UIs.

Cache effect: append-only (a steer is an appended message; the terminal error
is a tool/message record). Do **not** implement as a "re-prompt with a nudge"
that rewrites history — that's OpenHands' goal-loop mechanism and it costs
prefix stability (see §3.3).

Effort: 1–2 days + a `t_stuck.nim` using the mock LLM's repeat trajectory.

### 3.3 Goal loop — **medium; build it in `fabric`/`agent`, not core**

OpenHands' `/goal --max N` is: start a loop, after each run ask an LLM judge
"is this objective done?", re-prompt if not, stream status events, cap it.
Two of three pieces already exist in Niffler:

- the completion judge ≈ the `expert` component's constrained-JSON judge over
  a cache-stable prefix;
- the "re-prompt" is an appended steer — `svc.session.<id>.steer` is exactly
  this, already used by expert and TUI;
- the cap is `maxRounds`/`maxTokens`/`maxCostUsd`.

So the Niffler-shaped version is a **`goal` component** (or a fabric
`program`): `goal_start {objective, maxIterations?, budgets?}` spawns a
durable job (reuse the `agent` component's job record shape — status/wait/
stop for free), runs the conversation, after each turn asks the judge with a
deliberately small, *cache-stable* judge prefix and only the tail evidence,
and steers with "not yet: <verdict>" or stops "done". It emits
`ev.goal.status` for UIs.

Honest cost: OpenHands' implementation injects judge re-prompts as *user*
messages and then has to filter them back out of the UI by matching prompt
text (`should-render-event.ts` has a comment calling this "Brittle by
design"). Niffler should not repeat that: give the re-prompt a marker field
in the message record (`goal: {iteration, verdict}`) so rendering, trimming
and compaction can treat it structurally from day one. ESCALATION.md's give-up
gate is the natural sibling — same judge call, opposite verdict.

Effort: 2–4 days as a component; it is mostly a consumer of shipped surfaces.

### 3.4 Compaction with a manual trigger — **the COMPACTION.md plan plus a button**

OpenHands' condenser gives a threshold *and* a user-visible "Compact context"
action that reports tokens freed. COMPACTION.md already designs the
transaction (propose → validate → persist, cache-aware, replace `reset:trim`).
The steal is small but real:

1. the `compaction_propose` component owner keeps the automatic path;
2. add a *client-triggered* variant: `session {op: "compact"}` (or a hidden
   `compact` core tool) that runs the same transaction on demand and reports
   `ev.session.context {reason: "reset:compact", trimmed, tokensFreed}`;
3. the UI shows it exactly where OpenHands does: next to the context meter,
   promoted once fill passes the warning threshold (`CONTEXT_FILL_WARNING_PERCENT
   = 70`), disabled while the agent is mid-turn.

Cache effect: this is a *sanctioned* prefix change, and the existing reason
vocabulary (`reset:trim`, `reset:tools`) must learn `reset:compact` so
`cacheHitRatio` regressions are legible rather than mysterious.

Effort: falls out of COMPACTION.md; the button is hours.

### 3.5 Hooks with veto — **medium, must sit inside the dispatch gate**

OpenHands' `PreToolUse` hook can `block` with a `reason`, and the UI renders
hook execution events (command, exit code, blocked, stdout/stderr, matcher,
async, timeout). Niffler's `hooks` component explicitly declined this:
"a hooks component that could veto calls would need to sit inside that gate —
a separate, carefully-designed plan."

That plan is worth writing now, because OpenHands' event shape answers most
of its design questions: `{hook_event_type, hook_command, success, blocked,
reason, exit_code, tool_name, action_id, stdout, stderr, additional_context,
hook_input}`. The Niffler-shaped version:

- **where**: core dispatch, between approval and execution — the only place
  that can veto a call *and* the only place that already re-validates schemas;
- **contract**: `x-harness.hooks` on the schema (or config in the component)
  declaring which events apply — but *execution* must stay out of core. So the
  gate asks a component (`svc.hooks.check`, request/reply, short timeout) and
  fails **closed on timeout only for explicitly blocking hooks**, open
  otherwise — the opposite default of OpenHands' `async` hooks, and consistent
  with Niffler's "deny when no human is reachable" posture;
- **events**: `preTool` (blockable), `postTool`, `userPromptSubmit`,
  `sessionStart`, `sessionEnd`, `stop` — mirroring OpenHands' six types;
- **audit**: `ev.hook.execution` events (append-only history, not frozen
  prefix) so UIs can render what a hook did. Niffler's per-message audit
  metadata (`createdAt`, `turnId`, `durationMs`) already sets the tone.

Interaction to settle first: an approval-gated tool with a *blocking* hook —
what does the UI show, and does the hook run before or after the human? The
sane answer: hooks run first (cheap, deterministic), the human approval is
the last gate; a hook that vetoes never reaches the human.

Effort: 2–4 days across core + component + tests; the payoff is that hooks
become a real policy seam (format-on-write, deny-list enforcement, audit)
instead of notifications.

### 3.6 Typed tool visualizers — **the UI's biggest gap, medium-large**

This is the single most visible difference between the two products. Niffler
publishes *rich* tool calls over the bus (`args`, `result`, `error`,
`durationMs`, `callId`, `phase`) and renders them as JSON in a `<details>`.
OpenHands renders bash as command+output+exit, edits as diffs, searches as hit
lists, and falls back to markdown — and, crucially, keys the registry by the
*typed event kind* (`defineVisualizer({actionKinds, observationKinds, Body})`
with `dispatcher.tsx` falling back when nothing matches).

Niffler's plan already exists (`docs/PLAN.md` "Level 1 UI dynamism":
`x-ui` hints + generic renderer registry; Level 2: builder-compiled Svelte
modules served from the store). The steal is prioritization and the fallback
discipline:

1. **Ship Level 1 generic renderers first** (markdown, code, diff, table,
   output pane, JSON tree) and a `preview` heuristic per tool — i.e. steal the
   *primitives* (`tool-visualizers/primitives/{code-block,diff-view,
   output-pane,key-value-grid,file-path-chip,markdown-file-preview}`) as the
   first vocabulary;
2. declare hints *in the schema* (`x-ui: {view, summary}`) so a component's
   tool gets a usable UI without UI code — the same "policy rides the schema"
   discipline as `x-harness` policy keys;
3. only then Level 2 (component-supplied modules). Note OpenHands' trust
   stance for the analogous Canvas Extensions: *trusted same-realm code, no
   sandbox, no granular permissions, install ≠ enable, hot enable, best-effort
   cleanup* — and their explicit warning that this is a product consent
   invariant, not proof of human presence. Niffler's `ui/README.md` already
   reasons about the same table (tool component = strong isolation, UI module =
   weak); borrow the *disclosure language*, keep the catalog gate.

Cache effect: none (rendering is client-side; and per WIRE.md, `text` is the
LLM-facing rendering while everything else in the result is machine data for
"fabric programs, tests, UIs" — this is exactly that clause being cashed in).

Effort: Level 1 ~2–3 days; Level 2 a project (and already a quest).

### 3.7 Event grouping and the "hoist thoughts out" rule — **small**

Two lines of reasoning in `group-events.ts` are worth copying verbatim:

- consecutive tool calls fold into one collapsible run (Niffler's SPA renders
  a run card but never *folds* long stretches; the TUI's tool levels are
  orthogonal);
- **reasoning is hoisted out of collapsed groups** so it stays in the main
  stream, and dedicated renderings (finish/think/error/task/markdown-artifact)
  act as group breakers.

For Niffler this maps onto `ev.session.toolcall` (`phase: start|done`) plus
the assistant's reasoning field; the renderer decides grouping, no bus change.
Effort: hours in the SPA, days in the TUI if desired.

### 3.8 Client tools — **medium; formalize "the UI executes this call"**

The `canvas_ui_control` tool is a *schema registered by the frontend* whose
server-side executor is a no-op; the actual effect happens in the browser,
which watches the event stream and dispatches (`tools/canvas_ui_tool.py`
docstring). `launch_child_conversation` is the same pattern with a
*result* channel faked by posting a user message back with a prefix
(`CHILD_CONVERSATION_RESULT_PREFIX`) — and the code comments admit this is the
only way to hand the agent the outcome, that the chat has to hide it, and that
"client tools are acknowledged before the browser has done any work".

Niffler's version is strictly better-defined because the bus *is* bidirectional:

- `x-harness.clientEffect: true` on a schema → the runner dispatches it to
  whatever interactive client holds the conversation (the `ui` registry
  already tracks exactly that: numbered clients with renewable leases and
  per-conversation ownership, `core/uireg.nim`);
- the client replies on the call's reply subject with the real result —
  a genuine tool result, not a faked user message;
- no human? **deny** (same posture as approvals), and the schema description
  should say so.

Two concrete payoffs: a `canvas`-style tool ("open this file / show this
preview / switch tab") that makes the agent's work *visible* in the SPA, and
spawning a sibling conversation — which Niffler gets almost for free
(`session` with a new id + a lineage record; the `agent` component already
models parent/child relations).

Cache effect: prompt-facing schema changes once per conversation start
(normal); results are appended history. Note the OpenHands wart to avoid:
their client tool schemas are cached **per tool name for the server process's
life** and a re-registration with a different schema is *rejected*
(`ClientToolSchemaConflictError`) — Niffler's catalog is hot, so don't
introduce a name-keyed schema freeze; treat it like any tool registration.

Effort: 2–3 days (core dispatch + ui registry routing + SPA handler + tests).

### 3.9 A tool/action risk classification — **small-medium, cheap signal**

OpenHands classifies each action `LOW/MEDIUM/HIGH` (an LLM security analyzer
by default, "none" as an option) and shows the risk on the tool card; the
analyzer is a pluggable policy object. Niffler has the *gate* (approval) but
no *gradient*: every approval is equally scary, so humans either read
everything or rubber-stamp (`NIF_AUTO_APPROVE=1`).

A Niffler-shaped version needs no LLM: the schema already carries enough
(`x-harness.approval`, `effect: read|write`, plus the component identity —
`bash`/`fabric` are universal writers; `edit`/`write` are workspace writers).
Derive a coarse class (read / workspace-write / harness-write / arbitrary-code)
at dispatch and:
- render it in the approval prompt and the UI (the human's decision gets
  cheaper);
- let approval policy be *class-based* per conversation (`approve: read+write`
  vs `approve: harness-write`) — a superset of today's binary flag, and the
  honest answer for headless runs;
- optionally let a component override the class in its schema
  (`x-harness.risk: "high"`), which keeps language/domain knowledge out of core.

Cache effect: none (dispatch-side). Effort: 1–2 days, mostly the policy
surface and its tests (`t_approval_manifest.nim` is the natural home).

### 3.10 The overview panel and git control bar — **small, high polish/effort ratio**

Both are *pure UI* over data Niffler already has:

- **Overview panel**: for Niffler it's `cwd` (workspace), `git_status` summary,
  repo/branch, recent commits, and the conversation's context/cost chips —
  rendered as a pinned, per-conversation panel. The interesting design detail
  is the *pin denylist persistence* (`unpinnedOverviewSections` as an inverse
  list, empty = all pinned) so new sections appear by default for existing
  users.
- **Git control bar**: buttons that *generate prompts*. Niffler's `git`
  component is read-only by design, and this pattern is how you keep it that
  way while giving the user one-click actions: the button sets the input box
  text (`getCreatePRPrompt(provider)`) and never touches the repo itself.

Effort: 1–2 days in the SPA, plus optional terminal/preview tabs later.

### 3.11 Schema-driven settings — **medium; the config story the MANUAL hints at**

OpenHands serves `/api/settings/agent-schema` + `conversation-schema` and the
UI renders sections/fields generically with prominence tiers
(`critical`/`major`/`minor`), a basic/advanced/all toggle, dotted-key
get/set, dirty-state diff-save, and a resilience rule worth quoting: treat
anything that doesn't look like a schema as unsupported, and never collapse
"unsupported", "unreachable" and "empty" into one UI state.

Niffler's config is env vars, `.env`, and per-component JSON records
(`provider`, `mcp`, `lsp_registry`). A `settings` component that **publishes
the schema of its own knobs** (including, eventually, core's env-only ones)
would let both UIs auto-render the same panels, and let a component announce
its settings without a UI change — the same discipline as tool schemas. This
is a bigger change than it looks (it implies the settings component owns
persistence for at least some knobs), so mark it as a *quest*, not a steal.

Effort: medium-large; the *pattern* (schema + prominence + one obvious writer)
is the borrow, and it can start as read-only ("show me the effective config
and where each value came from" — `llm_resolve` already returns provenance).

### 3.12 Architecture guards as tests — **tiny, pays every week**

`no-direct-agent-server-calls.test.ts` mechanically forbids the shortcut
every reviewer flags. Niffler's equivalents are concrete and currently absent:

- **component→core boundary**: no component may import from `core/` (the SDK
  is the only bridge). A grep-level test in `tests/` (like the OpenHands
  scanner: walk the tree, fail on matches, allow an explicit list) would make
  ARCHITECTURE.md enforceable instead of aspirational.
- **envelope purity**: `sdk/envelope.nim` imports only `std/[json, os,
  times]` today (AGENTS.md says the codec stays pure `std/json` runtime data so
  SDKs stay portable) — assert the set can't grow quietly.
- **UI→bus boundary**: `ui/frontend/src/**` may only reach the harness through
  `nats.ts` (`send`/`subscribe`) — assert no `fetch(`/direct HTTP, mirroring
  their rule.
- **docs invariants**: `t_approval_manifest.nim` already asserts part of the
  approval contract; the same style can assert one-player-spawn-style
  invariants for `x-harness.*` keys (every `x-harness` key the runner honors is
  documented in WIRE.md).

Effort: hours. Highest leverage per line of code on this whole list.

### 3.13 Specs with IDs and checkbox assertions — **tiny**

`MCP-001: Sparse mutations preserve sibling servers … - [x] …`. Each spec ID
is cited by tests and code comments. Niffler's research/plan docs are prose
and its plans are long; converting *new* work (starting with the compaction
plan and the hooks-veto plan) into ID'd, test-cited assertions would make
"is this done?" mechanical. This is a process steal, not code.

### 3.14 MCP OAuth2 — **medium; the one real MCP gap**

Niffler's MCP support is broad (lazy sessions, secret-by-reference, drift,
prompts as slash commands, resources, registry, per-server isolation,
credential origin rules) and in two respects *ahead* of OpenHands
(frozen-schema-on-removal semantics; the registry search; approval integration).
The gaps are:

1. **OAuth2** (`MCP_AUTH_STRATEGIES` includes `oauth2`; the agent server runs
   the dance and exposes start/status endpoints with an `oauth_state`), while
   Niffler only does static headers. For remote/hosted MCP servers this is the
   difference between "works" and "needs a copied bearer token".
2. **Health as a state machine**: `verified` requires the read-only probe tool
   to have been advertised *and invoked* without error; anything else that
   connects is labeled `connectivity-only` and "never silently upgraded"
   (`probe-mcp-server-health.ts`). Niffler's `mcp_servers` reports "registered
   tools, session status, last error" — a natural place to add the same
   honest two-level verdict and auth-failure sniffing (their regex maps
   `401/403|unauthorized|invalid token` to a *credentials* failure kind, since
   the transport layer can only say "connection failed").
3. **`mcp_test`-style dry run with a chosen tool + args**, so a user validates
   a server by actually calling something.

Effort: OAuth is the bulk (a browser dance needing a callback listener — the
`fetch` component or a small `oauth` component could own it); the health
labels and the probe call are hours.

### 3.15 Worktree-per-conversation — **medium, already deferred in DSH-STEALS-PLAN**

OpenHands defaults `worktree: true` and gives child conversations an explicit
`isolation: worktree|shared` choice, with the honest doc language: worktree
children "will NOT see this conversation's uncommitted or committed work";
`shared` is opt-in with an explicit conflict warning. Niffler pins `cwd` but
has no branch/dir isolation, and multiple conversations writing one workspace
is a live footgun (the fabric/agent docs already discuss write-claims).

The Niffler shape: `session {cwd, worktree?}` creating
`var/worktrees/<sessionId>` (or a git worktree under the repo), with the
lineage record carrying which isolation a child got. DSH-STEALS-PLAN phase B
already lists "forked children"; this is the supporting mechanism. Effort is
real (cleanup, `git` tool scoping, approval semantics for a new dir) — a
medium plan of its own.

### 3.16 Terminal/browser/preview panes — **large; park it**

The file/diff/terminal/browser tabs are a *product*, and they require
components Niffler doesn't have (a terminal PTY service, a browser driver,
artifact preview). Note two separable ideas:

- **a preview artifact path**: Niffler already spills large results to files
  (`var/fetch`, `var/mcp-results`, `var/fabric-artifacts`). One `preview`
  bus subject the SPA turns into a rendered pane (markdown/image/HTML in a
  sandboxed iframe) would make every existing spill *visible*.
- **the client tool for tab switching** (§3.8) — the cheapest half, and it
  works with whatever panes exist.

Effort: park the panes; the client tool is the enabler worth doing first.

### 3.17 Remote access: one ingress port + key-gated public mode — **small-medium**

REMOTE.md names bus security as Niffler's first remote prerequisite ("bind
beyond loopback and gate who may publish `svc.>`") and sizes it as "small".
OpenHands ships the *product* answer worth reading, because it avoids the
protocol question entirely (`docs/SELF_HOSTING.md`):

- **one ingress port** (`127.0.0.1:8000`) fronts static UI, agent server and
automation by path; nginx only ever knows that one port, and the docs' default
posture is "nothing inbound except SSH from your IP" — the firewall, not the
app, is the boundary;
- **`LOCAL_BACKEND_API_KEY` + `--public`** flips from "key baked into the
frontend" to "the user pastes it once, the UI shows a key-entry screen"; every
`/api/*` call carries `X-Session-API-Key`;
- an explicit warning that anything reachable from the LAN is in the threat
model, plus an SSH-tunnel path for people who don't want to open ports.

Niffler's translation is already half-designed: `NIF_NATS_URL` *is* the single
ingress (SSH-tunnel it and nothing else is needed); what's missing is (a)
`--auth`/TLS flags passed to the spawned `components/nats` build (it supports
them today, core never uses them — REMOTE.md §5), and (b) a client-side story
for the token, which the SDKs' `ensureHarness` probe is the natural home for.
The steal is the *posture language*: loopback by default, one optional port,
key-gated public mode, and "the firewall is the boundary, not the app".

Effort: small if scoped to the auth flag + token plumbing; medium if a
`--public`-style UI entry path comes with it.

## 4. Three things worth studying closely (not necessarily copying)

### 4.1 Canvas Extensions — the ecosystem shape Niffler should *not* copy literally

`specs/canvas-extensions.md` is the most thought-through extension model in
the tracked set, and it is instructive precisely because Niffler's is the
opposite:

- **theirs**: extension = *code in the UI's realm* (pages, panels, renderers,
  themes, slots), installed on the backend machine, trusted, no sandbox, hot
  enable, install≠enable as a *consent invariant* ("an agent may install, the
  user enables"), updates preserve enabled state, distribution = git
  coordinates resolved and pinned by the server, and a versioned host API
  (`apiVersion: "1"`) with manifest-declared contributions validated against
  registration IDs;
- **ours**: extension = *a process on the bus*, isolated, approval-gated at
  spawn, discoverable, with schema-carried policy. Nothing is trusted.

The lesson to steal is not the mechanism but the **governance vocabulary**:
versioned host API, manifest-declared surfaces *validated* against what the
extension actually registers, install-vs-enable separation, and an explicit
non-goals list. If Niffler ever ships UI modules (Level 2), those four
decisions are the ones to reuse — including the honest disclosure that
same-realm UI code cannot be sandboxed.

### 4.2 The typed-client discipline

`AGENTS.md` + `no-direct-agent-server-calls.test.ts` implement a rule Niffler
states but does not enforce: *one sanctioned way to reach the backend*.
OpenHands' version is heavier (a generated client package in a separate repo
with its own release train — and the cost is visible: version-skew
compatibility shims everywhere, `MIN_AGENT_SERVER_VERSION_FOR_*` constants,
comments about "older agent-servers ignore the field"). Niffler's answer —
one envelope spec, versioned by discipline — is lighter and better; the
*enforcement* is what's missing (§3.12), not the client.

### 4.3 They filter their own machinery out of the chat, badly, on purpose

Two mechanisms leak into the transcript and the UI has to hide them again:
goal-loop re-prompts (matched by *prompt text prefixes*) and client-tool
results (a user message with a magic prefix). Both carry comments admitting
the brittleness. This is a direct warning for Niffler's own loops (goal,
escalation, expert): give internal re-prompts and synthetic results **structural
markers on the message record**, not text conventions, so trimming,
compaction, rendering and replay can all treat them as machinery.

## 5. Not worth stealing

- **Splitting the product across four repositories** (`frontend / sdk /
  typescript-client / extensions`). It buys independent release trains for a
  company-sized team and costs version-skew shims at every boundary; Niffler's
  single-clone-one-instance is the point.
- **REST + per-backend URLs as the control plane.** Niffler's bus already
  gives multi-backend pub/sub, events and approvals; REMOTE.md's analysis
  stands.
- **`agent_settings` blobs passed on every conversation start** (with
  encrypted/redacted round-trips, "secrets_encrypted", profile-vs-inline
  mutual exclusion, and enriching client-side before send). It is complexity
  born of "the client owns the config document"; Niffler's provider records +
  `.env` + component-owned config is simpler. (The *schema* half of §3.11 is
  the good part.)
- **PostHog-grade telemetry architecture** (client identity, consent state
  machine, separate staging/prod keys, deterministic `$insert_id`s). Not a
  fit for a personal harness; the privacy postures are already covered by
  Niffler's "no telemetry" default.
- **The i18n table at this scale** (15 locales, ~2.4k keys, CI completeness
  checker). Not until there is a product team.
- **The barrel of version-compat shims** (`agent-server-compatibility.ts`,
  "absent entirely when the automation service is older than the release…").
  A consequence of independent deployables; Niffler's bus clients should
  instead *fail loudly on unknown envelopes* — the same fail-closed instinct
  as approvals.

## 6. Ranked summary

| # | Steal | Effort | Why now |
|---|---|---|---|
| 1 | **Cost accounting + optional cost cap** (§3.1) | small | Data is already shipped; closes the gap to every bench in the field; feeds `maxBudget` guards |
| 2 | **Architecture guard tests** (§3.12) | tiny | Makes three documented invariants mechanical; pays off every future change |
| 3 | **Stuck detection** (§3.2) | small | A real failure mode budgets can't catch; uses the existing steer channel |
| 4 | **Typed tool visualizers, Level 1** (§3.6) | medium | The single most visible product gap; unblocks Level 2; cashing in WIRE.md's "machine data for UIs" clause |
| 5 | **Client-effect tools** (§3.8) | medium | Turns the agent's work visible in the SPA; spawns siblings properly; Niffler's bus makes it cleaner than the original |
| 6 | **Manual compaction trigger** (§3.4) | small | Falls out of COMPACTION.md; gives users agency without waiting for auto-heuristics |
| 7 | **Hooks with veto** (§3.5) | medium | Requires the deliberate core-gate design the component deferred; OpenHands supplies the event vocabulary |
| 8 | **Goal loop in a component** (§3.3) | medium | Reuses expert's judge + steer + agent jobs; gives the "keep going until done" affordance |
| 9 | **Risk classes in approvals** (§3.9) | small-medium | Makes the human gate usable at scale; no LLM needed |
| 10 | **Overview panel + git-prompt bar** (§3.10) | small | Pure UI over existing tool data; makes the UI feel like a workspace |
| 11 | **MCP OAuth2 + honest health** (§3.14) | medium | The only real MCP gap; health labels are hours |
| 12 | **Event grouping / thought hoisting** (§3.7) | small | Renderer-only; big readability win for long tool runs |
| 13 | **Schema-driven settings** (§3.11) | medium-large | Quest-grade; start read-only with provenance |
| 14 | **Worktree per conversation** (§3.15) | medium | Already deferred in DSH-STEALS-PLAN; safety as conversations multiply |
| 15 | **Specs with IDs** (§3.13) | tiny | Process change; adopt for the next plan doc |
| 16 | **Terminal/preview panes** (§3.16) | large | Park; the client tool (§3.8) is the enabler |
| 17 | **Bus auth + key-gated remote mode** (§3.17) | small-medium | The prerequisite REMOTE.md already flagged; the bundled NATS server has the flags |

### The three ideas that are genuinely *someone else's*, worth reading on their own

1. **Client tools as a protocol** (§3.8) — a tool whose executor is the UI,
   with ack semantics and a documented schema-freeze hazard. Niffler can do it
   with a real result channel.
2. **A separate terminal state for "stuck"** (§3.2) — the UI treats it as its
   own thing (emoji, notification, banner), which is only possible because the
   *protocol* names it. Niffler's `budget-exhausted` error kind is the same
   move; "stuck" deserves a sibling.
3. **Hooks as six typed lifecycle events with `blocked`/`reason`** (§3.5) —
   the vocabulary is portable even if the execution model changes.

## 7. Sizing

| Piece | Effort | Notes |
|---|---|---|
| Cost accounting + `maxCostUsd` (§3.1) | 1 day | Arithmetic on shipped data; `t_ctx_accounting.nim` extension |
| Architecture guard tests (§3.12) | hours | Four grep-style scanners in `tests/` + a `make test` entry |
| Stuck detection (§3.2) | 1–2 days | Dispatch fingerprint ring + terminal error + `ev.session.status` field |
| Tool visualizers Level 1 (§3.6) | 2–3 days | Primitives + `x-ui` hints + registry + fallback |
| Client-effect tools (§3.8) | 2–3 days | Dispatch routing via `core/uireg.nim` + SPA handler + tests |
| Manual compaction (§3.4) | hours (on top of COMPACTION.md) | New `reason: "reset:compact"`; UI button next to the meter |
| Hooks with veto (§3.5) | 2–4 days | Core gate + `svc.hooks.check` + events + fail-closed rules |
| Goal loop component (§3.3) | 2–4 days | Judge (expert-style) + steer + durable job; structural markers in the record |
| Approval risk classes (§3.9) | 1–2 days | Derived class + class-based policy + schema override |
| Overview panel + git prompt bar (§3.10) | 1–2 days | Pure UI; pin-denylist persistence pattern |
| MCP OAuth2 (§3.14) | medium | Browser dance + callback listener; health labels separate & small |
| Event grouping (§3.7) | hours (SPA) | Renderer-only |
| Schema-driven settings (§3.11) | medium-large | Quest; read-only provenance view first |
| Worktree per conversation (§3.15) | medium | Milestone of its own; DSH-STEALS-PLAN touches it |
| Specs with IDs (§3.13) | hours | Adopt in the next plan doc |
| Terminal / browser / preview panes (§3.16) | large | Park; ship the client tool first |
| Bus `--auth` + key-gated remote mode (§3.17) | small-medium | Core passes flags the bundled server already supports; completes REMOTE.md's §5 gap |
| ACP passthrough | large, dubious | Letting Niffler *be* the ACP client to other harnesses is a different product; the `llm` component's protocol support already covers the direct path |

Recommendation: the first four rows are same-week work and strictly additive
(cost, guards, stuck, visualizers). Client-effect tools and hooks-veto are the
two that change what Niffler can *do*, and both hinge on the same insight
OpenHands demonstrates: the control plane can host policy and presentation
without the agent loop knowing. Do not copy the four-repo split, the REST
control plane, or the settings-blob protocol; Niffler's one-wire shape is
strictly the better base — these steals are about *surfaces*, not structure.
