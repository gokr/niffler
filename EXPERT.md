# Niffler Advisory Peer ("the expert")

Design sketch for a **non-interactive advisory peer** that follows one working
session on the bus and occasionally injects a steer when a separate LLM judges
that the working agent is not fully exploiting Niffler. Status: **phase 1
implemented** — the turn-bound wire surfaces (`ev.session.turn`, `turnId`
correlation, `svc.session.<id>.advise`) and the 1:1 `expert` component with
the LLM judgment contract and fail-closed delivery (`tests/t_expert.nim`,
mock-llm driven). Cached-token plumbing is in place: the `llm` adapter
forwards `prompt_tokens_details.cached_tokens`, core passes usage through,
and `expert_status` accumulates judgment prompt/cached/completion tokens.
Not yet built: judgment quality tuning against a real model, and anything
beyond one target session.

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

- the restrictive advisory policy in section 5;
- the direct/on-demand/hidden tool model and the `discover` + `invoke`
  workflow;
- live **non-hidden** component and tool descriptions captured at
  initialization;
- the self-extension path: inspect the ecosystem first, then write source,
  `builder.build`, `core.spawn`, and `discover`;
- plugin and skill discovery, including `plugin_search`-before-build;
- file-tool selection (`grep`/`files`, `read`/`edit`/`write`, read-only git
  tools, and when `bash` remains appropriate);
- context-economy guidance: keep large mechanical work out of the working
  transcript and spill oversized output;
- the fabric/subagent when-to-use matrix from
  [FABRIC.md](docs/research/FABRIC.md): direct loop for adaptive one-step work,
  `fabric` for mechanical known-shape orchestration and context isolation, and
  `agent_run` for exploratory work needing a fresh context. Fabric fan-out is
  currently sequential, not a parallel-speed mechanism.

The prefix must not contain hidden tool schemas. `x-harness.hidden` means
invisible to an LLM, including the expert LLM. A full catalog snapshot may be
used as local component data, but only its non-hidden projection may enter the
prompt.

Skills are not trusted merely because their names begin with `niffler-`.
Additional skill content must come from a reviewed allowlist. The expert records
a canonical knowledge version/hash so diagnostics and cache measurements can
identify the exact prefix used.

Knowledge is static between explicit reloads. A newly installed component does
not silently mutate the prefix. `expert_reload` rebuilds the reviewed projection
and starts a new cache epoch. Until then, concise current live-tool information
may be included in the variable observation suffix when needed.

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
  "liveRelevantTools": [
    {"name": "git_diff", "description": "..."}
  ]
}
```

Bounds are mandatory. Keep the current user request, the latest assistant text,
a capped reasoning tail, a small number of recent tool activities, truncated
arguments/results, and current context occupancy. Do not retain completed turns
or forward full tool results to the expert provider. Raw evidence remains local
unless it survives explicit size and redaction rules.

## 4. Best-effort scheduling

An expert evaluation may be scheduled after:

- the working turn starts;
- a working model round produces assistant text or reasoning;
- a tool call completes or fails;
- context pressure changes;
- events accumulated while the previous expert inference was running.

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
  "action": "steer",
  "message": "Use `git_diff` for the next comparison instead of another shell diff.",
  "reason": "The working session is manually reproducing a live dedicated tool.",
  "tools": ["git_diff"],
  "sources": ["git_diff schema"],
  "confidence": "high"
}
```

The fixed policy tells the model:

- Silence is healthy. Speak only when advice is high-confidence and likely to
  change the next action materially.
- Judge the working approach, not the user. Never reinterpret, replace, or
  correct the user's request.
- Advice is additive and actionable. Name the concrete next mechanism rather
  than saying "use better tools."
- Do not interrupt a valid approach merely because an alternative exists.
- Judge harness usage only: task-strategy advice (what to implement, which
  file to edit, when to run tests) is always silent — that is the working
  agent's job, not the expert's.
- Do not repeat advice already present in the observation.
- Never recommend a hidden, absent, or incompatible tool.
- Fabric is for mechanical known-shape orchestration and context isolation, not
  arbitrary shell work or promised parallel speed.
- The expert may suggest approval-gated work, but it never performs that work;
  the working session's normal human approval remains authoritative.
- Return `silent` when evidence is incomplete, stale, ambiguous, or merely a
  style preference.

The component validates the response. Unknown actions, malformed JSON,
oversized messages, non-high-confidence steers, any non-live/non-hidden name in
the structured `tools` array, model errors, and timeouts all become silence.
This validation is delivery policy, not a behavioral heuristic.

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
- a strict message length cap;
- no delivery after the turn changes;
- no automatic action by the expert.

## 7. Component surface

The component is registered with `client: false` and exposes administrative,
on-demand controls:

```nim
let comp = newComponent("expert", "0.1.0")

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
    ## Rebuild the reviewed non-hidden knowledge prefix and begin a new cache
    ## epoch. Does not change the followed working session.

comp.tool:
  proc expert_status(): JsonNode =
    ## Report target session, active turn, inference state, model, knowledge
    ## version, usage, last decision, accepted advice, and stale drops.
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
  versioned, and infrequent.
- **Prompt injection:** working-session content and external skills are
  untrusted model input. Delimit observations as evidence, use a reviewed skill
  allowlist, and prevent the expert from acquiring tools or action surfaces.
- **Approvals:** advice may suggest `core.spawn`, plugin installation, or another
  approved operation, but only the working session can request it through the
  normal approval gate.
- **Provider privacy:** following a session sends its bounded current-turn
  evidence to the expert's configured provider. `expert_follow` must make that
  explicit to the human.
- **Cache economics:** a large prefix has a cold-start cost and cached input is
  not necessarily free. Measure before broadening the knowledge bundle.

## 10. First build

Minimal honest prototype, in order:

1. Add `turnId` and `ev.session.turn` to the session event contract; propagate
   `turnId` through existing events and preserve structured tool errors.
2. Add the turn-bound `svc.session.<id>.advise` request/reply path, structured
   provenance, persistence metadata, and stale-turn rejection tests.
3. Build the one-target `expert_follow`/`unfollow`/`status` component with a
   bounded current-turn observation and latest-state coalescing.
4. Build a reviewed, non-hidden, versioned knowledge prefix containing the
   discovery, tool-selection, plugin, skill, self-extension, fabric, and
   subagent guidance.
5. Call the hidden `chat` tool directly with the fixed prefix plus one ephemeral
   observation. Give the model no tools and validate the `silent|steer` JSON
   contract.
6. Run live with one expert following one normal session. Verify that inference
   never delays the working turn, late answers are discarded, and accepted
   advice appears with clear provenance.
7. Expose cached-token usage where the provider reports it, then measure cold
   prefix cost, cache hits, completion cost, inference latency, silence rate,
   accepted advice, and stale-drop rate.
8. Tune the knowledge and policy prompt from observed judgment quality. Do not
   add multi-session following until the 1:1 design has useful precision and
   understandable cost.

The architecture is validated when an expert can follow one live session,
remain silent during reasonable work, occasionally deliver a useful steer in
time, and harmlessly lose any judgment that arrives too late.
