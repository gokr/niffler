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
| 3 | Cache **write** path: explicit breakpoints + write accounting, then retention and expiry-aware prefix surgery | doctrine-completing | small → medium | **[verified]** deeper than first thought |
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

## 3. Cache write path: breakpoints, accounting, retention, expiry-aware surgery

This item grew during review. It started as "we lack Pi's `PI_CACHE_RETENTION`
knob"; checking the request builders found that the *read* half of the cache
economy is instrumented and the *write* half is absent. Three layers, in
dependency order.

### 3.1 Explicit cache breakpoints (prerequisite)

**[verified]** `components/llm/` emits no cache markers at all:
`grep -rn "cache_control" components/ core/ sdk/ ui/frontend/src/` returns
nothing. `anthropicRequest` (`components/llm/anthropic.go:200`) builds
`system` blocks and `tools` as plain `{"type": "text", "text": …}` with no
`cache_control` field; messages likewise (`anthropicMessages`, line 234).

Anthropic's prompt cache requires explicit breakpoints; the OpenAI-compatible
endpoints Niffler mostly talks to cache implicitly. So the read-side numbers
Niffler collects are largely *OpenAI-family implicit caching*, and the Anthropic
protocol path — which the repo supports and which OAuth subscription logins
use — has no caching being requested at all. (Asserted from the request shape,
not probed live; a one-shot call against a real Anthropic endpoint is the
confirmation step before building on it.)

Pi does emit them, with a documented convention ("Anthropic-style
`cache_control` markers to the system prompt, last tool definition, and last
user, assistant, or tool-result text content", `packages/ai/src/types.ts:626`),
including a compat flag for providers that reject markers on tool definitions.

### 3.2 Cache **write** accounting

**[verified]** Niffler cannot see what caching costs. `anthropic.go` parses
`cache_creation_input_tokens` (line 32) and folds it into `PromptTokens`
(line 181) but never forwards it as a distinct write figure; the usage payload
(`main.go:826`) carries only `prompt_tokens_details.cached_tokens`. Core's
metrics (`core/conversation.nim`) accumulate `cachePrompt`/`cacheRead` and
derive `cacheHitRate` — reads only.

The visible consequence is in `bench/reports/`: every niffler row shows
`cache r/w` with a **zero write column** (`11.6k/0`, `115.9k/0`, …) while Pi
reports `cacheWrite` and a separate `cacheWrite1h` (billed 2× input,
`packages/ai/src/models.ts:903`). Without a write figure there is no way to
evaluate whether a cache policy pays for itself — which is exactly the
question §3.3 and §3.4 raise.

Caveat on the bench evidence: the zero-write column is *not* proof that the
OpenAI-family lanes fail to cache, since implicit writes are not reported in a
comparable field. It is proof that Niffler's own reporting has no write axis.

### 3.3 Retention as an explicit TTL choice

**[verified]** no `PI_CACHE_RETENTION` equivalent. Pi's is a **write-time TTL
selection**, not an expiry watcher: `cacheRetention: "none" | "short" | "long"`
(`packages/ai/src/types.ts:108`), lowered per provider to Anthropic
`cache_control.ttl: "1h"`, OpenAI `prompt_cache_retention: "24h"` or
`prompt_cache_options.ttl: "30m"` on GPT-5.6+ (types.ts:634–651).

Work: env + stored-provider field, mapped per protocol in `components/llm/`,
surfaced through `ev.session.status` so cache metrics stay one source of truth.
Small once 3.1/3.2 exist — and it is 3.1/3.2 that make it meaningful, since a
TTL on a path with no breakpoints does nothing, and an expensive long-TTL
write made invisible by 3.2 cannot be justified.

### 3.4 Expiry-aware prefix surgery — a Niffler-only idea

Niffler's doctrine already says every prefix change must be *named*; there are
exactly two today (`reset:trim`, `reset:tools`). This adds a third kind, and it
exploits the fact that a cold cache is the only moment a prefix change is free:

> if the conversation's prefix cache has (probably) expired, any prefix
> mutation we were deferring — a sticky `invoke` promotion, a compaction cut,
> a tool-profile change — should happen **now**, because the rebuild is already
> being paid for.

The scheduling argument is clean and it composes with item 1: compaction
invalidates the prefix by definition, so triggering it at a known-cold moment is
strictly cheaper than on a warm one. Emitted as `reset:expired`, which carries
its own meaning rather than borrowing `reset:tools`.

**[bet]** on knowability, and this is the honest caveat. Cache expiry is not
observable in advance — providers do not guarantee the TTL and may evict
earlier. What is available:

- **pre-hoc**: timestamp arithmetic against the configured TTL
  (`lastRequestAt` plus the effective retention), a probabilistic guess;
- **post-hoc ground truth only**: `cached_tokens == 0` on a byte-identical
  prefix *is* evidence of expiry — but it arrives after the decision the policy
  needed to make.

So the policy is opportunistic, not deterministic: "we are probably cold, spend
the change now", with the correctness of that guess learned on the next turn.
State needed is cheap and belongs where `cachePrompt`/`cacheRead` already live
— the conversation header, which persists across runner restarts: a
`lastRequestAt`, the effective TTL, and a count of how often the guess was
wrong (so the heuristic can be tuned rather than trusted).

Sequencing: 3.1 → 3.2 → 3.3, and 3.4 only once the first three make the
trade-off measurable. 3.1/3.2 are correctness/diagnosis work, not tuning; 3.4
is the piece worth writing up on its own, because nothing in Pi has it.

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
are overflow recovery, shell env injection, and the cache *write* path — none
of which are expensive, and two of them are compaction dependencies.
