# JEV — the decision-model control layer

Research on **Jev** (TypeSafe AI's "System One" decision model, announced
2026-09-15), **OpenJEV** (`AlexWortega/openjev`, the MIT open reimplementation)
and the coding-harness integrations that grew around both within a week.
Nothing here is a plan yet; this doc is the map for deciding whether Niffler
gets a decision layer, and in what shape.

The field is days old — everything cited dates 2026-09-15..20 and vendor
interfaces (`jev-latest`) are already moving. That is the strongest argument
for writing against a normalized contract, not a vendor SDK.

## The two Jevs (and the rest of the zoo)

**Jev** is TypeSafe's flagship "System One" model: it does not generate text.
You send a `state` (string/object/array) plus typed `questions`; it answers all
of them in one parallel pass in 70–500 ms with calibrated probabilities. Three
question primitives, composable in code:

| Primitive | Asks | Returns |
|---|---|---|
| `noul` | Is this true? | probability 0–1 |
| `choice` | Which of these options? | choice + distribution + confidence (up to 255 options) |
| `score` | Which level on a rubric? | score + legend + probabilities + confidence |

Pricing: $0.042/M input tokens, output free (~$0.0004 per decision; TypeSafe
claims 20–200x LLM speed). API at `api.typesafe.ai`, models `jev-latest` /
`jev-1.13.0`, SDKs for Python/JS, docs at docs.typesafe.ai, tutorials at
learnjev.com. Guidance worth internalizing: ask one gut-check question per
entry and compose in code ("does this message convey urgency?", not "analyze
this message and determine the best course of action"); every question sees
the same state, evaluated in isolation; adding questions barely changes
latency; `confidence` is itself a first-class signal — "I don't know how far
this reaches" is a reason to stop, and a bare classifier cannot express it.

**OpenJEV** (`AlexWortega/openjev`, MIT) is the open-weights reimplementation
of the same primitive: Qwen3.5 fine-tuned as a 3-label NLI cross-encoder
(contradiction / entailment / neutral), last-token pooling, plain
cross-entropy. One cross-encoder reading premise+hypothesis is enough to
rerank answers, grade against a reference, guard content, and play games in
real time — hand it the state and a few candidate statements, argmax
entailment is the decision. Nothing is trained per task; strictly zero-shot on
everything shown. Checkpoints:

- `qwen3.5-0.8b-nli-v2s-long` — 0.8B, 4k context, CPU-plausible. MNLI
  86.2/87.1, ANLI r1 65.1, SciTail 93.2, RAGTruth AUROC 0.90, LLM-AggreFact
  avg bAcc 69.5. Serves the demo Space.
- `qwen3.5-4b-nli-v2` — **recommended**, 4B, text **and images** (images go in
  the premise via Qwen3.5 vision tokens). ANLI r3 0.42→0.63 vs v1, WANLI
  0.63→0.77, image claims 0.52→0.84, ARC-Challenge rerank 0.59→0.72, MMLU
  0.47→0.53, MNLI 0.91.
- `qwen3.5-35b-a3b-nli` — 35B-A3B MoE backbone, plus per-task MLP heads on the
  frozen last-token latent (`mlp_heads_35b/`, loadable with `LatentMLPHead`).

Ships `modeling_openjev.py` — `OpenJevCrossEncoder.predict`,
`predict_hypotheses`, `rerank`, `grade`, `latents` — and `code/` with the
trainer, data-mix builder and eval harness. Flashy but real demos: Doom from
pixels (10.4 kills/episode vs 1 for random play), and an iron pickaxe crafted
from nothing in real Minecraft — 11 milestones in ~22 decisions driven by a
backward-chaining scaffold where the jev model only ever checks statements
about inventory and world state.

**The rest of the zoo** (all independent, all open): `openjev.com` (now
renamed **SemIf**, "not affiliated with TypeSafe") — a browser-local demo on
Qwen3 0.6B / MiniCPM5 2B / Qwen3.5 4B, comparing reading choice logits vs
writing probabilities as tokens; `daseinlabs/open-jev` — Gemma 3 4B on MLX,
one-pass option scoring in ~90 ms, and it **implements the `/v1/systemone`
wire contract**, so it drops in behind a TypeSafe-shaped client;
`vinnylarouge/jevlike` — the training recipe plus Doom/chess checkpoints;
"Laya" — an OS Jev on CoreML doing 45 decisions/s on an M4;
`browser-use/jev-ultrafast` — dynamic indexed action spaces for a browser
agent.

## What harnesses use it for

The canonical catalogue is `Anil-matcha/awesome-jev-by-typesafe`
(`docs/coding-agent-use-cases.md`); learnjev.com's "Building an agent harness
with Jev" is the best single tutorial. The community framing, quoted because
it is the right boundary to copy: **a generative model drafts, plans, or
explains; Jev supplies bounded semantic judgments; code handles state,
arithmetic, policy, permissions, and side effects; humans take the ambiguous
or high-risk cases.** Jev is "a learned semantic branch instruction" — its
role is the harness **control layer**: selecting tools, grading traces,
detecting loops, checking completion, deciding when to escalate. And the
corollary the awesome list states outright: **Jev should not be the component
that grants a capability** — a high-confidence answer may present an option,
but the harness still checks user, repo, path, command, network policy and
approval state. That is precisely our `x-harness.approval` position.

The six best-fit workflows:

| Workflow | Jev's role |
|---|---|
| Model cascade | Classify difficulty/risk/context need → route to cheap vs. large reasoning model |
| Skill/tool selection | Choice over the full catalogue in one request (Hermes: all 182 skills ranked at once), paired with a Noul "does this turn need a tool at all?" |
| Command/tool-call safety | Gate destructive / credential / exfiltration intent before execution |
| Retrieval filtering | Rank files/docs/memories against the task |
| Patch verification | Score a diff against team conventions (semantic CI) |
| Loop/stall detection | Judge "has the agent tried this four times" from harness state |

The Choice-vs-Noul pairing matters: a Choice's probabilities sum to 1, so it
always nominates a winner even when nothing fits; the Noul is what gives the
harness permission to run no tool at all. The other trick worth stealing is
escalation on **uncertainty**: `blast_radius.confidence < 0.5 → ask_user`,
independent of what the model picked.

### Notable integrations

- **LangChain** — `TypeSafeClassifier` plus experimental `AutoModeMiddleware`
  that blocks risky tool calls before execute (shipped on launch week; read as
  a pattern demo, not a stable dependency).
- **pi-jev** (`y0usaf/pi-jev`) — a Pi extension, i.e. the same harness I run.
  A gate judges `bash`/`write`/`edit` pre-execution with 4 questions in one
  ~300 ms request (destructive 0.90, exfiltration 0.70, beyond-scope 0.85,
  impact 2.5); shadow mode by default, enforce mode asks the user; **every
  error path fails open**; identical inputs judged once per cache window and
  sibling calls from one assistant message share one in-flight request. An
  output judge reads `bash` results (secret leak + failure classification with
  a table-driven advice map). A `jev_ask` tool lets the model request the same
  typed judgment itself. It also documents "what leaves the machine" — every
  judgment sends the cwd, tool name, last user message and tool arguments
  (file contents included) to `api.typesafe.ai`.
- **jev-harness** (`Astro-Han/jev-harness`) — filters every tool result
  through Jev for relevance before the main model sees it, with an A/B
  harness. 30 tasks (Terminal-Bench 2.1 + DeepSWE), `deepseek-flash`:
  **25/30 vs 22/30 pass, $0.113 vs $0.127 cost per passing task**; the
  filtered arm is never worse on any DeepSWE task (6 wins, 0 losses, 3 ties,
  sign test p≈0.031); `meriyah` 49/49 tests vs 0/49 (unfiltered agent shown
  1.46M chars of output, ran out of time). Two empirical rules from its
  ablations: filter on the agent's **intent** (the reasoning from the turn
  that issued the call), not the task — task-relative relevance elided
  deliberate reads the agent then read back whole; and keep chunks on
  contains-signal, not majority-noise, with single-chunk outputs skipping the
  judge entirely. Raw output is always stored and retrievable — filtering is
  a routing decision, never destruction.
- **hermes-jev-skills** — model routing, memory, compaction, skill selection,
  computer/browser use for Hermes agents (also Claude Code and Codex).
- **agent-router, jev-gateway, stanley-code, SuperQode, fable-jev, reticle** —
  the same three ideas (route, gate, filter) in different wrappers.

## Niffler fit analysis

A decision component can implement **some** experiments through existing
plugin seams. Tool discovery advice is buildable without core edits; first-turn
model routing, pre-history result filtering, and approval pre-filtering are not.
The model's judgments remain language-agnostic, but wiring them into those
runner boundaries requires an explicit seam and a separate safety review.

### 1. Dynamic model selection (model cascade)

A `decide` component classifies the incoming turn (difficulty, risk, need for
repo context) and picks from the `models` registry. The constraint is our own
prompt-cache discipline, and it decides the shape:

- The conversation's request prefix is frozen. Intentional rebuilds are
  `reset:prune`, `reset:compact`, `reset:trim` and `reset:tools`; switching
  models mid-conversation also misses the provider cache but has no rebuild
  reason. So: route **once, before the first turn's resolution**, not per
  turn. There is currently no runner hook at that point: the earliest turn
  event fires after model resolution. A client can set `session {model}`
  before turn 1, but a standalone component cannot observe conversation birth
  and route reliably without a new pre-resolve seam or client cooperation.
- Subagent continuation freezes model/thinking/tools at the child's first
  turn — routing at `agent_spawn` time is equally clean and free of cache
  damage. Per-subagent routing is the natural place for a cascade: cheap
  model for well-specified edits, reasoning model for architecture turns.
- Mid-conversation "the turn is harder than the model" should stay effort
  steering (advice) or escalation, not a model swap.

### 2. Tool discovery selection

Niffler already has the machinery (`discover` + `invoke` +
`x-harness.onDemand`); it lacks a selector. Jev's Choice-over-catalogue (255
options, one request, ~300 ms) is exactly the right shape: rank which on-demand
tool schemas to surface for this turn, paired with a needs-tool Noul so
"surface nothing" is a legitimate answer. learnjev's rule applies verbatim:
if the selected tool changes the state or the available choices, make a second
call after loading it. Schema mutations ride the documented paths only —
`discover` schemas append to history, `invoke {sticky: true}` is the sole
direct-set rewrite — so a Jev picker never touches the frozen prefix.
Existing delivery seams include turn-bound `svc.session.<id>.advise` (the
`expert` precedent) and client-driven `session {discovery}`; both append
context rather than rewriting the frozen request prefix.

### 3. Other seams, in priority order

- **Tool-result filtering** (jev-harness pattern): score `bash`/`grep` output
  chunks for relevance to the turn's intent before they enter context; keep
  the raw output retrievable. Doing so **before** the result enters history
  needs a runner-side filter seam at `commitToolItem`; observe-only `hooks`
  cannot intercept it. Post-result advice is possible today, but cannot save
  the tokens already spent on the unfiltered output. This is not a plugin-only
  experiment.
- **Approval tiering**: `x-harness.approval` is the enforced boundary (terminal
  y/N, deny when no human is reachable). A Jev layer sits *below* it — decide
  which calls need the prompt at all, with escalation on low confidence as in
  pi-jev/learnjev. Never let it grant capability. Core's current approval
  chain has no pre-filter hook: publishing an `ev.approval.reply` verdict would
  instead grant capability and violates this boundary. Approval tiering needs
  a reviewed pre-filter seam, not a reply-publishing plugin.
- **Output judging** (pi-jev): secret-leak and failure-classification on
  `bash` output, one line appended to the tool result. Cheap, table-driven.
- **Loop/stall detection**: judge "same action, fourth attempt" from runner
  state; feeds the wake-budget/would-stop logic rather than the LLM.

### 4. Deployment: hosted vs self-hosted

- **TypeSafe hosted**: trivial (HTTP JSON, `TYPESAFE_API_KEY`), 70–500 ms,
  $0.0004/decision — but prompts, file contents and command arguments leave
  the machine. Niffler is local-first and its `.env` holds real keys; pi-jev's
  "what leaves the machine" section is the cautionary template.
- **Self-hosted OpenJEV**: MIT, nothing leaves. 0.8B is a plausible per-
  judgment CPU cost (the demo Space runs it); 4B v2 wants a GPU and adds
  image judgments; numbers are honestly published per benchmark (MNLI
  0.86–0.91, ANLI r1 0.65, ARC-Challenge rerank 0.72 — below the commercial
  model's 88% agreement, above "free"). `rerank`/`grade`/`predict_hypotheses`
  map cleanly onto our decision shapes. Serving is one component: a small
  Python sidecar (transformers), or builder-wrapped.
- The seam that makes the choice deferrable: write the component against the
  normalized `{state, questions}` contract that both `daseinlabs/open-jev`
  (`/v1/systemone`) and TypeSafe's SDK speak. Backend becomes config
  (`NIF_DECIDE_BACKEND=typesafe|openjev`), exactly the `lsp` provider-seam
  pattern. Start hosted to validate the judgments, swap to self-hosted when
  the questions are stable.

## The steal list

1. **The control-layer framing itself** — "Jev supplies bounded semantic
   judgments; code handles state, policy, permissions, side effects; Jev never
   grants a capability." Write this into whatever we build; it matches our
   approval enforcement line for line.
2. **Choice + Noul pairs for every selection** — never route on a Choice
   alone; the absolute "needs this at all?" question is what makes "do
   nothing" a legitimate route. Applies to tool discovery, model cascade and
   skill selection alike.
3. **Escalate on low confidence, not on wrong picks** — a calibrated model's
   "I don't know how far this reaches" is a first-class stop condition. Our
   approval prompts should fire on uncertainty, not only on flagged intent.
4. **Intent-conditioned tool-result filtering** — jev-harness's one real
   ablation: filter against the agent's stated intent for the step, keep
   contains-signal chunks, skip single-chunk outputs, always store the raw
   output and let `read` retrieve it. Filtering is routing, never destruction.
5. **Fail-open, coalesce, cache** (pi-jev engineering): one in-flight request
   shared by sibling calls, per-input cache window, every error path returns
   no verdict, dead endpoint reports once a minute. A decision layer in the
   hot path must be a no-op when broken.
6. **One gut-check question per entry, composed in code** — weightable
   factors, not prompt prose; when priorities shift, change a threshold, not
   a prompt.

## First spike (proposal: discovery only without core edits)

Build a hidden `decide` component (normalized `{state, questions}`, hosted
TypeSafe backend first, OpenJEV behind the same contract second) via
`builder` + `core.spawn`, then wire a `discover`-advisory scorer through
`svc.session.<id>.advise`. A/B it jev-harness style — same tasks, decision
layer on/off, pass + cost per passing task. First-turn model routing needs
an explicit pre-resolve seam or cooperating client; pre-history filtering
needs a runner-side filter seam. The filter experiment has evidence it can
win, not an implementation path through today's plugin API.

## Sources

- https://huggingface.co/AlexWortega/openjev (README/model card, checkpoints, benchmark numbers)
- https://typesafe.ai/blog/introducing-system-one-models-and-jev (announcement)
- https://docs.typesafe.ai — primitives, confidence, System One concepts
- https://learnjev.com/tutorials/agent-harness — control layer, gating, tool selection at catalogue scale, loop detection
- https://github.com/Anil-matcha/awesome-jev-by-typesafe/blob/main/docs/coding-agent-use-cases.md
- https://github.com/y0usaf/pi-jev — gate/output judge/`jev_ask` for the Pi harness
- https://github.com/Astro-Han/jev-harness (+ RESULTS.md) — tool-result filtering, A/B evidence
- https://github.com/kerpopule/hermes-jev-skills — routing/memory/skill selection
- https://github.com/daseinlabs/open-jev — one-pass option scoring, `/v1/systemone` contract
- https://github.com/vinnylarouge/jevlike — independent training recipe + checkpoints
- https://openjev.com (SemIf) — browser-local logits-vs-tokens demo
- https://github.com/browser-use/jev-ultrafast
- HN threads: TypeSafe announcement (506 comments), OpenJev/SemIf (708 points)
- No existing Niffler–Jev integration found (GitHub search, 0 results) — greenfield.
