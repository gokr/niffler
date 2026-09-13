# What's next after compaction — priorities against Pi

> Follow-up to [PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) (the full difference map) and
> [research/COMPACTION.md](research/COMPACTION.md) (the compaction proposal).
> This file records the *decision* reached when asking: "after compaction lands,
> what does Pi do that Niffler should actually do something about?" — and
> deliberately separates findings backed by source from findings that are
> engineering guesses.
>
> Basis: Niffler `7b46ccd`, Pi `71dca871b` / 0.85.1. Every line marked
> **[verified]** was read from source during this analysis; guesses are marked
> **[bet]**.

## The ranking

| # | Item | Kind | Size | Status |
|---|---|---|---|---|
| 1 | Context-overflow classification + recover-and-retry | compaction dependency | small | **[verified]** gap |
| 2 | Shell session env injection into `bash` | ergonomics | hours | **[verified]** gap, zero found |
| 3 | Prompt cache retention knob | doctrine-completing | trivial | **[verified]** gap, volume **[bet]** |
| 4 | Image payloads across the wire (+ history normalization) | wire-level | medium | **[verified]** gap |
| 5 | Session branching / derivation | cheap core, UX bet | medium | **[verified]** absent |

Two commonly assumed candidates got demoted:

- **Compaction** itself is already a proposal ([COMPACTION.md](research/COMPACTION.md)) — items 1
  and part of 4 (the trim-vs-summary gap) are its dependencies, not new work.
- **Session tree navigation** (`/tree`, `/fork`, `/clone`, labels, filters) is a
  UX product bet, not an architectural gap — see the "Demoted" section.

## 1. Context-overflow classification + recover-and-retry

Pi has a distinct error class for "prompt too long"
(`packages/coding-agent/src/utils/overflow.ts`), triggers compaction on it, and
retries the request after compacting. Niffler treats overflow as a generic `llm`
error; the only pre-emptive defenses are the 75% warn / 90% trim thresholds
estimated from provider-reported usage.

This is **the trigger the `compaction` component needs** — `compaction_propose`
is useless if nothing classifies the failure that means "compact now". Also the
safety net: Niffler trims by *estimate*, and if the estimate is wrong the turn
simply dies.

Work: an error class in `core/retry.nim`'s classification family
(`isRetryableLlmError` today treats everything non-transient as fail-fast), a
provider-side detector in the `llm` adapters (`context_length_exceeded`,
Anthropic's `invalid_request_error` / "prompt is too long"), and a
recover-and-retry path that compacts (or trims harder) once and re-issues the
request. Small, and sequenced *with* compaction rather than after it.

**[verified]** `components/llm/` has no overflow branch; `core/retry.nim`
classifies auth/quota/bad-request as fail-fast and 429/5xx/overload as
retryable — overflow falls through neither path usefully.

## 2. Shell session environment injection

Pi injects per-command, resolved at command start
(`docs/environment-variables.md`): `PI_SESSION_ID`, `PI_SESSION_FILE`,
`PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`.

Niffler injects nothing — **[verified]**: `components/bash/main.nim` has no
`putEnv`/env assembly at all, and the MANUAL environment table contains no such
variables. The values are already available at dispatch (`__session` context),
so this is child-process environment assembly plus a documented set of
`NIF_SESSION_ID`, `NIF_MODEL`, `NIF_PROVIDER`, `NIF_REASONING_LEVEL`.

Why it is worth more than it looks: a command can then self-report provenance,
or call back into the harness (`cli call ...`) without the model smuggling ids
into command strings. Niffler's scripting story (`cli`, plugins CI, bench lanes)
is a differentiator, and this makes the shell a first-class citizen of it.
Constraint from [WIRE.md](WIRE.md): session context is injected only for tools
declaring `x-harness.sessionId`; injecting into session-dispatched `bash` calls
is the narrow, sanctioned shape (component-to-component calls keep their
explicit `__session`, never an ambient env).

## 3. Prompt cache retention knob

**[verified]** Niffler has no equivalent of `PI_CACHE_RETENTION=long` (Pi:
Anthropic 1h, OpenAI 24h). Niffler's entire doctrine is built on cache
*stability* — frozen prefix, append-only history, exactly two named prefix
resets, `cacheHitRatio` surfaced per turn — but the prefix is stable across
idle gaps no provider cache will survive, so a conversation resumed after lunch
pays a full rebuild with no policy to prevent it.

Work: a provider/llm-level retention setting (env + stored-provider field),
mapped per protocol in `components/llm/` (Anthropic cache-control TTL, OpenAI
extended retention where available), reported in `ev.session.status` so the
existing cache metrics stay the single source of truth.

**[bet]** the size of the win. This repo has no idle-gap measurements; the
correct move is instrumenting `cacheHitRatio` on resumed conversations before
building the policy. The knob is trivial either way.

## 4. Image payloads across the wire

The composition path is closed today, and this is the part that makes it
wire-level rather than a tool fix:

- **[verified]** [WIRE.md](WIRE.md) "Conventions": a result object carrying a
  string `text` field is the LLM-facing rendering — session runners put `text`
  verbatim into the tool message and *nothing else from the result reaches the
  transcript*. A text-only `read` component therefore cannot return an image
  block; there is no channel for it.
- **[verified]** The capability data already exists: `components/models/main.go`
  carries `input: enum[text, image, audio, video, pdf]`, and the seed has
  `attachment: true` for DeepSeek. Pi gates on exactly this
  (`model.input.includes("image")`) with a text fallback ("[Current model does
  not support images. The image will be omitted from this request.]").
- **[verified]** The non-obvious half is history normalization, not base64.
  Pi's `utils/tool-result-images.ts` rewrites images *as they enter history* —
  including ones produced by extensions, MCP bridges and screenshot tools, not
  just `read` — with auto-resize to 2000×2000 / ~4.5MB. Its own comment names
  the failure: an oversized image makes the provider reject **the whole
  conversation, not just the offending turn**. In a frozen-prefix architecture
  an unsendable history is the worst possible failure mode.

So the shape here is: a multimodal content form in the envelope/transcript (the
WIRE change), runner + Go `llm` adapter translation for all three wire protocols,
component-side image reads in `edit`, and the normalization discipline applied
at result-entry so no component can poison a conversation. Sequencing: WIRE spec
first, then normalize-on-entry, then reads.

## 5. Session branching / derivation

**[verified]** absent. Messages are linear `kind=message` docs with a monotonic
`seqNo` (`core/conversation.nim`); `conversation_delete` is the only
conversation-lifecycle op, and it exists precisely because deletes must clean
lineage, snapshots and agent jobs together.

Two distinct things are usually bundled as "session tree":

1. **Branching as data** — derive a conversation from message N of another:
   `parentId` on `message` docs plus a branch op. Cheap, and genuinely useful
   (retry a turn with a different model/tool profile without losing the tail).
2. **Tree as navigation** — `/tree`, `/fork`, `/clone`, labels, filters, branch
   summaries. This is where the cost and the product bet live.

The Niffler-specific reason for caution:

- **Branch summarization buys nothing here.** Pi's branch summary exists because
  jumping branches loses the summarized context; Niffler's store keeps full
  history, so a derived branch merely replays its own messages. If compaction
  lands, tree-summarization value approaches zero.
- **Branches are cache-partial by construction.** A fork from message N shares
  the root prefix and diverges at N — cache-wise it is a new conversation with a
  shared head. That is fine, but it means branching is a conversation-lifecycle
  op (peer of `conversation_delete`), not a UI affordance bolt-on.

Recommendation: implement (1) when a concrete need appears (likely the first
time someone wants "redo that turn better"), skip (2) until a user asks.

## Demoted — considered and not prioritized

| Candidate | Why not now |
|---|---|
| Session tree navigation (labels, filters, `/tree` UI) | UX bet; branching-as-data covers the practical need, and branch summaries are redundant with store-backed replay |
| Hooks with teeth (block/patch tool calls, rewrite results) | Deliberate design choice: `components/hooks` is observe-only, and a veto layer needs its own note on ordering, approval interaction and audit ownership |
| Project trust gate | Real, but a safety-policy item (see [research/PI_FEATURE_SCAN.md](research/PI_FEATURE_SCAN.md) §2.3), not an architecture gap |
| Prompt templates | Small convenience; skills already cover most of it |
| Evals package | Valuable, but blocked on compaction to be assertable; do after |
| Export/import/share | Small; the `cli` transcript recipe already covers the read path |
| Sandboxing | Neither harness has it; already scoped separately in [research/SANDBOX-PLAN.md](research/SANDBOX-PLAN.md) |

## One sentence

The genuinely missing **architectural** piece is image payloads crossing the
wire (with normalize-on-entry); the genuinely missing **high-leverage** pieces
are overflow recovery, shell env injection, and cache retention — none of which
are expensive, and two of them are compaction dependencies.
