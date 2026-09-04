# Niffler Advisory Peer ("the expert")

Design sketch for a **non-interactive advisory peer** that follows one working
session on the bus and occasionally injects a steer when a separate LLM judges
that the working agent is not fully exploiting Niffler. Status: **phase 2** —
the turn-bound wire surfaces (`ev.session.turn`, `turnId` correlation,
`svc.session.<id>.advise`), the 1:1 `expert` component with the LLM judgment
contract and fail-closed delivery (`tests/t_expert.nim`, mock-llm driven), and
a knowledge prefix rebuilt around **tool-selection correctness**: the judge's
mission is to keep the working session on the correct Niffler tool, the prefix
carries the OBSERVED SESSION's own tool view (frozen direct exposure + frozen
allowlist via `core.prompt_preview`, on-demand hints via `discover` — never
the global LLM toolset, which overstates what an older or allowlisted session
can call), plus the reviewed bundled skills `niffler-tools` (when to use every
core component/tool) and `niffler-fabric` (how to construct fabric programs).
Because the prefix is cached per follow it may fill up to 80% of the judge's
context window (resolved via `llm.llm_resolve`, minus a reserve for the
observation); a steer may therefore carry real how-to — component AND exact
tool to invoke, invocation argument shape, or a minimal fabric program
sketch. Cached-token plumbing is in place: the `llm` adapter forwards
`prompt_tokens_details.cached_tokens`, core passes usage through, and
`expert_status` accumulates judgment prompt/cached/completion tokens.
Not yet built: judgment quality tuning against a real model at this new
prefix size, and anything beyond one target session.

The working session should keep its small frozen direct toolset and
task-focused transcript, as described in
[progressive tool discovery](docs/MANUAL.md#progressive-tool-discovery). The
expert carries broader Niffler knowledge in a separate, cache-stable prompt and
sees a bounded view of the working session's current turn. It never performs
work for the agent. Its only possible action is a short, attributable steer.

The first design is deliberately **one expert to one working session**. The
expert is best-effort: it may fail to produce advice before the working agent
moves on, and that is preferable to adding latency to the working loop. There
is no backlog of stale judgments and no attempt to keep up with several
sessions.

## 1. Boundary and goals

The expert is an ordinary component and peer on NATS, not part of core and not
part of the working session's loop. This preserves the core/component boundary:
the expert can be stopped, replaced, rebuilt, or removed without affecting the
conversation.

The initial design optimizes for:

- **LLM judgment, not hard-coded behavioral heuristics.** Deterministic code
  gathers evidence and enforces delivery safety; the expert model decides
  whether the evidence warrants an intervention.
- **No structural latency.** The working session never waits for expert
  inference.
- **Default silence.** Most expert calls should return no advice.
- **Current-turn awareness without a growing expert transcript.** Each expert
  call sees a bounded observation of the active working turn, but those
  observations and judgments are not appended to an expert conversation.
- **Cache-stable knowledge.** A fixed, versioned system prefix is identical
  across expert calls until an explicit knowledge reload starts a new cache
  epoch.
- **Fail closed.** Invalid output, unavailable knowledge, timeout, uncertainty,
  or a late answer all produce silence.

The expert is not a normal Niffler session runner. A normal runner persists and
replays every user and assistant message, so its context would grow with every
observation. The expert instead calls the hidden `chat` tool directly with a
fresh two-part request:

```text
system: fixed expert policy + curated Niffler knowledge
user:   bounded observation of the working session's current turn
```

The provider still receives the fixed prefix on every call; prompt caching can
reuse it when the selected provider supports prefix caching. "Expert session"
therefore means one logical inference lane bound to one working session, not a
persisted conversation process.

## 2. Knowledge prefix

The fixed system prefix contains reviewed, model-facing knowledge:

- the restrictive advisory policy in section 5, framed around the mission:
  tool selection — the judge's only job is to keep the worker on the correct
  Niffler tool for the job;
- the **reviewed bundled skills** `niffler-tools` and `niffler-fabric`,
  loaded from the `skills` component at build time. The `SkillAllowlist`
  const IS the trust boundary: only those names load, and only when the
  returned copy's source is `bundled` — a project/home skill shadowing a
  bundled name is refused and the static fallback knowledge takes its
  place. `niffler-tools` is the when-to-use authority for every core
  component and tool (edit vs write, files vs grep, git_* vs shell git,
  bash's remaining jobs, discover/invoke, plugins, skills, self-extension,
  agent_run/fabric matrix); `niffler-fabric` is the guest-program
  construction authority (imports, typed mode, callTool, batch, logg,
  finish, patterns, budgets, pitfalls) — this is what lets a steer sketch a
  working fabric program instead of saying "use fabric";
- the **observed session's own tool view**: its frozen direct tool names and
  frozen tool allowlist via `core.prompt_preview` (read-only store
  provenance), joined with global catalog descriptions, plus on-demand
  hints from `discover` filtered by the same allowlist. The global LLM
  toolset is NOT advertised: a session created before a component existed,
  or frozen with an allowlist, cannot call tools outside its own view, and
  the expert must not recommend them. An expert armed before the session's
  first turn has no exposure yet — it falls back to the global direct set
  and rebuilds at the first turn start (the exposure and allowlist are
  frozen there, so later turns no-op);
- the self-extension path, plugin/skill discovery, file-tool selection,
  context-economy and fabric/subagent guidance — these live in the skills;
  the static fallback block (used when the skills component is absent, e.g.
  `--minimal`) carries the same content in condensed form.

The prefix must not contain hidden tool schemas. `x-harness.hidden` means
invisible to an LLM, including the expert LLM. A full catalog snapshot may be
used as local component data, but only its non-hidden projection may enter the
prompt.

**Prefix sizing.** The prefix is sent on every judgment but cached per follow,
so the economics favor filling deep: the budget is 80% of the judge's resolved
context window (`llm.llm_resolve`, honoring the follow's model/provider
overrides) minus a fixed reserve (`PrefixObsReserveTokens`) for the
observation and the verdict. Over budget, tool descriptions shrink first
(lowest value per byte) and only as a last resort the tail is truncated with
an explicit marker. An unresolvable context window means no budget: everything
loads. `expert_status` reports prefix size, budget, and loaded skills so cache
economics stay measurable.

Knowledge is static between explicit reloads and the turn-start rebuilds
described above. `expert_reload` rebuilds the reviewed projection (including
re-reading the skills) and starts a new cache epoch. The expert records a
canonical knowledge version/hash so diagnostics and cache measurements can
identify the exact prefix used.

## 3. Observation contract

Current session events use fixed subjects such as `ev.session.toolcall` and
carry `sessionId` in their payloads. There is no scoped
`ev.session.<id>.>` stream. The expert subscribes to `ev.session.>`, filters for
its one target session, and discards all other traffic.

The current wire is not sufficient for reliable LLM judgment:

- the user's current request is not emitted as a session event;
- session events do not carry a turn identifier;
- `ev.session.toolcall` is emitted only after completion;
- tool errors are flattened to a string in that event;
- a reasoning-only model round may not produce an `ev.session.assistant`
  event, although reasoning token deltas appear on `ev.session.token`.

Before active steering, add a correlated event contract:

```json
ev.session.turn {
  "sessionId": "conv-123",
  "turnId": "turn-456",
  "phase": "start|done",
  "content": "the user request, present on start"
}

ev.session.toolcall {
  "sessionId": "conv-123",
  "turnId": "turn-456",
  "callId": "call-789",
  "phase": "start|done",
  "tool": "bash",
  "args": {},
  "result": {},
  "error": "...",
  "errorCode": "no-tool"
}
```

`turnId` should also be added to `ev.session.token`, `assistant`, `context`,
`steer`, and `done`. The completion event retains its current `error` string for
existing consumers and adds `errorCode`; the start event omits result/error.

For its target, the expert keeps one bounded in-process observation frame:

```json
{
  "sessionId": "conv-123",
  "turnId": "turn-456",
  "userRequest": "...",
  "recentActivity": [
    {
      "tool": "bash",
      "argsSummary": "...",
      "resultSummary": "...",
      "error": null
    }
  ],
  "assistantText": "...",
  "reasoning": "...",
  "context": {"usedTokens": 42000, "limit": 128000},
  "visibleTools": {"discovered": ["git_diff", "grep"]}
}
```

Bounds are mandatory. Keep the current user request, the latest assistant text,
a capped reasoning tail, a small number of recent tool activities, truncated
arguments/results, current context occupancy, and the names of on-demand tools
the session has already discovered (the direct set lives in the prefix; the
discovered list is the only part of the tool view that can change mid-session).
Do not retain completed turns or forward full tool results to the expert
provider. Raw evidence remains local unless it survives explicit size and
redaction rules.

## 4. Best-effort scheduling

An expert evaluation may be scheduled after:

- a tool call starts (tool + arguments are already real usage evidence), with
  completion enriching the same observation;
- context pressure crosses 80%;
- events accumulated while the previous expert inference was running.

The implemented scheduler deliberately does **not** judge at turn start (a
request alone is not evidence of harness misuse), begins on the first actual
tool call so advice can arrive while it runs, caps inference at two judgments
per turn, and stops after accepted advice. This is the token budget,
not a heuristic about what advice to give.

These are inference scheduling points, not rules about what advice to give. The
expert model receives the observation and makes that judgment.

Only one inference may be active. The observer uses latest-state coalescing:

1. An event updates the observation frame.
2. If no inference is active, snapshot the frame and query the expert model.
3. Events arriving during inference update the latest frame and mark it dirty.
4. When inference returns, use its answer only if the same `turnId` is still
   active.
5. If dirty, evaluate the newest consolidated frame instead of replaying every
   queued event.
6. If the turn ended, discard the answer and clear the frame.

This is intentionally lossy. The expert may miss an opportunity, but it must
not delay the worker or catch up by injecting obsolete advice.

The Nim SDK serializes handlers on its main thread. A blocking `chat` request in
an event handler would stop observation until inference returns and then risk
processing every queued event separately. The component therefore needs a
small polling/state-machine loop, an SDK deferred-work hook, or a worker child
process so event ingestion remains cheap and queued events can be consolidated.
It does not add threads or callbacks to the Nim SDK. This is an implementation
detail inside the replaceable component, not a new core mechanism.

## 5. LLM judgment contract

The expert model has no tools. It receives the fixed knowledge prefix and one
ephemeral observation message, then returns constrained JSON:

```json
{"action": "silent", "reason": "The working approach is reasonable"}
```

or:

```json
{
```json
{
  "action": "steer",
  "message": "discover the git component and invoke `git_diff` with
              {repo: ".", args: ["HEAD~1"]} for the next comparison instead
              of another shell diff.",
  "reason": "The working session is manually reproducing a live dedicated tool.",
  "tools": ["git_diff"],
  "confidence": "high"
}
```

A steer toward `fabric` carries a minimal program sketch (imports, tool
calls, `finish()` return) drawn from the embedded `niffler-fabric` skill —
the judge never says "use fabric" without showing the program.

The fixed policy tells the model:

- **Mission: tool selection.** The judge's only job is to keep the working
  session on the correct Niffler tool for the job — which harness mechanism
  should do the work, and how to reach it. Task strategy (what to
  implement, which file to edit, when to run tests) is the worker's job on
  any harness and is always silent.
- Silence is healthy. Speak only when advice is high-confidence and likely to
  change the next action materially.
- Judge the working approach, not the user. Never reinterpret, replace, or
  correct the user's request.
- Name the exact mechanism: for on-demand tools, the component AND the tool
  to invoke, with the invocation's argument shape; for fabric, a program
  sketch. "Use better tools" is not advice.
- Only tools in the observation's session-visible listings are steerable;
  an allowlisted session cannot reach anything outside its list, not even
  via discover.
- Do not interrupt a valid approach merely because an alternative exists.
- Do not repeat advice already present in the observation.
- The expert may suggest approval-gated work, but it never performs that
  work; the working session's normal human approval remains authoritative.
- Return `silent` when evidence is incomplete, stale, ambiguous, or merely a
  style preference.

The component validates the response. Unknown actions, malformed JSON,
oversized messages, non-high-confidence steers, a missing/empty `tools` array,
any tool not in the observed session's visible set, a tool not named verbatim
in backticks in the message, model errors, and timeouts all become silence.
One further gate is **observation-grounded, not phrase-matched**: the steer
must name at least one tool the worker is not already using in the current
activity frame — a steer that only repeats the worker's current toolset is
task-strategy or repetition, never a tool change. (The earlier English phrase
blacklist — "run the tests", "read the file" — was removed: those steers can
only name tools already in the frame, so the structural check catches them
without matching words.) This validation is delivery policy, not a behavioral
heuristic.

Observations and model judgments are not appended to subsequent expert calls.
Every call starts again with the identical system prefix and one current
observation. There is no growing expert transcript.

## 6. Turn-bound advice

The existing `svc.session.<id>.steer` channel is fire-and-forget, queues only
`{content}`, and can fold a late message into a later turn. User type-ahead may
want that behavior; autonomous advice must not have it.

Add a separate conditional request/reply surface:

```json
svc.session.<id>.advise {
  "sessionId": "conv-123",
  "turnId": "turn-456",
  "kind": "advisor",
  "source": "expert",
  "content": "...",
  "reason": "...",
  "sources": ["..."],
  "knowledgeVersion": "sha256:...",
  "expiresAt": 0
}
```

The runner accepts the advice only while the named turn is active. It returns
`{accepted: true}` or `{accepted: false, reason: "stale-turn|no-active-turn|..."}`.
The runner must also service this subject while idle so late requests are
rejected rather than left queued for the next turn.

Accepted advice is folded into the model-visible history with a distinct marker,
for example:

```text
[Niffler advisor: expert] Use `git_diff` for the next comparison instead of
another shell diff.
```

Core persists structured advisory metadata separately on the message and emits
it through `ev.session.steer` or a dedicated `ev.session.advice` event. The Go
LLM adapter already decodes messages into typed provider messages, so internal
metadata can be retained by Niffler without forwarding unknown fields to the
provider.

`source` is provenance, not a cryptographic signature. Niffler's current bus
trust model allows peers to self-declare identity. The metadata is for model,
human, and diagnostic attribution within that trusted bus.

Initial delivery limits:

- at most one accepted expert steer per working turn;
- no repeated advice hash within the bound session;
- a strict message length cap (1200 chars — room for a program sketch or
  invocation args, not just a tool name);
- no delivery after the turn changes;
- no automatic action by the expert.

## 7. Component surface

The component is registered with `client: false` and exposes administrative,
on-demand controls:

```nim
let comp = newComponent("expert", "0.2.0")

comp.tool:
  proc expert_follow(session_id: string, model: string = "",
                     provider: string = ""): JsonNode =
    ## Follow one working session. Replaces any current target, clears the
    ## observation frame, and starts a new best-effort advisory lane.

comp.tool:
  proc expert_unfollow(): JsonNode =
    ## Stop following and discard pending observations and judgments.

comp.tool:
  proc expert_reload(): JsonNode =
    ## Rebuild the reviewed non-hidden knowledge prefix (including the
    ## bundled skills) and begin a new cache epoch. Does not change the
    ## followed working session.

comp.tool:
  proc expert_status(): JsonNode =
    ## Report target session, active turn, inference state, model, knowledge
    ## version, loaded skills, prefix size/budget, usage, last decision,
    ## accepted advice, and stale drops.
```

`expert_follow` is explicit and off by default. Its schema should be on-demand
and approval-gated because it authorizes a background component to observe and
influence a conversation. The first build does not automatically follow
subagents or switch targets based on bus activity.

The implementation subscribes to `ev.session.>`, filters the target payload,
maintains the bounded frame, requests `llm.chat` directly with `stream: false`
and no tools, validates the result, and conditionally calls the target runner's
`advise` subject. It never calls working tools itself.

## 8. Cost and observability

Unlike deterministic rules, the LLM-driven design pays for judgments that end
in silence. The expected optimization is cached input, not zero inference.
Prompt caching is provider- and model-dependent and cached input may be
discounted rather than free.

Niffler currently reports only `prompt_tokens`, `completion_tokens`, and
`total_tokens`. It does not expose cache-hit details. Before claiming a cost
win, extend the LLM result and usage plumbing to preserve provider fields such
as `prompt_tokens_details.cached_tokens` when available.

The expert should emit bounded diagnostic events or logs for:

- target and knowledge-version changes;
- judgment start/end and latency;
- `silent` versus `steer` decisions;
- prompt, cached, and completion tokens when reported;
- accepted and rejected advice;
- stale judgments discarded after a turn change;
- observations coalesced while inference was active;
- model, parse, validation, and timeout failures.

Do not log full user requests, reasoning, tool arguments, results, or generated
advice by default. Diagnostics should carry hashes, counts, rule-free reason
categories, and bounded redacted previews only when explicitly enabled.

## 9. Known sharp edges

- **Timeliness:** the working session may finish another model/tool round before
  the expert answers. Best-effort plus turn-bound rejection is the intended
  behavior; the working loop must never wait.
- **Inference cadence:** querying after every token or event would be wasteful.
  Coalesce model/token bursts and evaluate meaningful snapshots.
- **Reasoning volume:** reasoning tokens can dwarf the useful evidence. Keep a
  capped tail and prefer the final reasoning field when available.
- **Knowledge churn:** reloads invalidate the stable prefix. Make them explicit,
  versioned, and infrequent — the turn-start rebuild only fires when the
  session's visible tool set or allowlist actually changed (practically: the
  first turn after an early follow).
- **Skill shadowing:** a project/home skill with the same name as a bundled
  one wins in the skills component's search order. The expert refuses any
  copy whose source is not `bundled` — the allowlist alone is not enough.
- **Prompt injection:** working-session content and external skills are
  untrusted model input. Delimit observations as evidence, use the reviewed
  skill allowlist + bundled-source check, and prevent the expert from
  acquiring tools or action surfaces.
- **Approvals:** advice may suggest `core.spawn`, plugin installation, or another
  approved operation, but only the working session can request it through the
  normal approval gate.
- **Provider privacy:** following a session sends its bounded current-turn
  evidence to the expert's configured provider. `expert_follow` must make that
  explicit to the human.
- **Cache economics:** the deep prefix (skills + tool hints, up to 80% of the
  judge context) has a cold-start cost and cached input is not necessarily
  free. The budget trim and `expert_status` prefix metrics exist to measure
  it; re-tune `PrefixFillRatio`/`PrefixObsReserveTokens` from observed
  cache-hit and latency data before broadening the knowledge bundle further.
- **Steer length:** a 1200-char steer (fabric sketch) is real content folded
  into the worker's history. One accepted steer per turn and the
  tool-change gate bound the damage; watch the bench's expert columns for
  noise before raising the cap again.

## 10. Build history

1. Add `turnId` and `ev.session.turn` to the session event contract; propagate
   `turnId` through existing events and preserve structured tool errors. (done)
2. Add the turn-bound `svc.session.<id>.advise` request/reply path, structured
   provenance, persistence metadata, and stale-turn rejection tests. (done)
3. Build the one-target `expert_follow`/`unfollow`/`status` component with a
   bounded current-turn observation and latest-state coalescing. (done)
4. Build a reviewed, non-hidden, versioned knowledge prefix containing the
   discovery, tool-selection, plugin, skill, self-extension, fabric, and
   subagent guidance. (done — now session-scoped: frozen exposure +
   allowlist via `core.prompt_preview`, skills via the bundled allowlist)
5. Call the hidden `chat` tool directly with the fixed prefix plus one ephemeral
   observation. Give the model no tools and validate the `silent|steer` JSON
   contract. (done)
6. Run live with one expert following one normal session. Verify that inference
   never delays the working turn, late answers are discarded, and accepted
   advice appears with clear provenance. (done)
7. Expose cached-token usage where the provider reports it, then measure cold
   prefix cost, cache hits, completion cost, inference latency, silence rate,
   accepted advice, and stale-drop rate. (plumbing done; the deep-prefix
   measurements at 80% fill are open)
8. Tune the knowledge and policy prompt from observed judgment quality. Do not
   add multi-session following until the 1:1 design has useful precision and
   understandable cost. (in progress — mission reframe + skill-backed
   knowledge landed; live-judgment tuning remains)

The architecture is validated when an expert can follow one live session,
remain silent during reasonable work, occasionally deliver a useful steer in
time, and harmlessly lose any judgment that arrives too late.
