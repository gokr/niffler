# What's next after compaction — priorities against Pi

> Historical prioritization note. The context/compaction work described below
> has since landed; the remaining rows are retained as an evidence-backed
> backlog. Current behavior is in [MANUAL.md](MANUAL.md).
>
> Follow-up to [PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) (the full difference map) and
> [research/COMPACTION.md](research/COMPACTION.md) (the compaction design record).
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
| 1 | Context-overflow classification + recover-and-retry | compaction dependency | small | **shipped** |
| 2 | Shell session env injection into `bash` | ergonomics | hours | **[verified]** gap, zero found |
| 3 | Cache: breakpoints (conditional), write accounting (small, real), retention (sits on breakpoints) | doctrine-completing | small | **[verified]**, narrower than first assessed |
| 4 | Image payloads across the wire (+ history normalization) | wire-level | medium | **[verified]** gap |
| 5 | Session branching / derivation | cheap core, UX bet | medium | **[verified]** absent |

Two commonly assumed candidates got demoted:

- **Compaction** itself is shipped ([COMPACTION.md](research/COMPACTION.md)) —
  item 1 is now part of its bounded overflow-recovery path, while part of 4
  (the trim-vs-summary gap) remains a separate wire-level question.
- **Session tree navigation** (`/tree`, `/fork`, `/clone`, labels, filters) is a
  UX product bet, not an architectural gap — see the "Demoted" section.

## 1. Context-overflow classification + recover-and-retry — shipped

Pi has a distinct error class for "prompt too long" and retries after
compacting. Niffler now has the corresponding bounded path: the Go LLM
adapter normalizes provider overflow responses to `context-overflow`, and the
runner performs one receipt-backed recovery attempt (compaction, then the
fallback pressure ladder). A second overflow is terminal, so a provider cannot
create an unbounded retry loop. Durable trim watermarks and provider-scale
accounting also make restart and admission behavior truthful.

The original gap analysis and proposed work are retained below only as the
historical motivation. See [MANUAL.md](MANUAL.md#context-window) and
[COMPACTION.md](research/COMPACTION.md) for the current contract.

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

## 3. Cache: what is real here, and what is not

This started as "we lack Pi's `PI_CACHE_RETENTION` knob". Two passes over the
source inverted the framing: part of the item is real but narrower than first
written, one layer was cut outright, and the dsh cache technique worth having
turned out to be already planned — in [COMPACTION.md](research/COMPACTION.md),
not here. What is left is small; the value of this section is mostly in
recording what *not* to build and why.

One vocabulary rule to take from the review
([CONTEXT-REVIEW.md](research/CONTEXT-REVIEW.md) §4): keep **mutation**
(`compact`, `trim`, `tools`), **trigger** (`pressure`, `overflow`, `manual`,
maybe `suspected-expiry`) and **observed cache outcome** as three separate
dimensions. Conflating them is what produced the cut idea below, and it is the
mistake to avoid when this work is actually done.

### 3.1 Explicit cache breakpoints — conditional, not universal

**[verified]** `components/llm/` emits no cache markers at all:
`grep -rn "cache_control" components/ core/ sdk/ ui/frontend/src/` returns
nothing. `anthropicRequest` (`components/llm/anthropic.go:200`) builds
`system` blocks and `tools` as plain `{"type": "text", "text": …}`;
messages likewise (`anthropicMessages`, line 234).

Whether that is a defect depends entirely on the provider, and the split is
sharp:

| Provider family | Caching | Does §3.1 matter? |
|---|---|---|
| OpenAI-compatible (DeepSeek, Synthetic, llmgateway — every bench lane) | automatic; nothing to send | **no** |
| Anthropic Messages (explicit `cache_control` breakpoints required) | needs markers | **yes** |

Niffler supports the Anthropic protocol path (`components/llm/anthropic.go`,
and Claude Pro/Max OAuth logins via `provider`) but **has never exercised it in
bench**: `bench/config.json` points every niffler lane at an OpenAI-compatible
`baseUrl`. So the non-zero cache reads in `bench/reports/*` are implicit
OpenAI-family caching and say nothing about the Anthropic path. (Asserted from
the request shape, not probed live; one call against a real Anthropic endpoint
is the confirmation step before acting on it.)

Pi emits markers, with a documented convention — "Anthropic-style
`cache_control` markers to the system prompt, last tool definition, and last
user, assistant, or tool-result text content" (`packages/ai/src/types.ts:626`)
— plus a compat flag for endpoints that reject them on tool definitions.

dsh is the useful counter-example, and it argues against treating this as a
defect at all. Its archived note *"Prune producer-less vocabulary variants"*
(implemented 2026-07-04) **deleted** `CacheHint` and the `cache?: CacheHint`
block fields: *"DeepSeek prompt caching is automatic, so the adapters map
`prompt_cache_hit_tokens` OUT of responses without ever sending a hint IN. This
was Anthropic-style `cache_control` surface with no provider that could honor
it."* Their admission rule — a variant returns the day it gains a real producer
— is the right lens for us too.

So: **build 3.1 only if and when the Anthropic path is actually used.** Until
then the right state is the one dsh arrived at after shipping the wrong one: no
dead cache vocabulary in our own core. Note the two dsh facts are consistent
and both instructive — dsh *deleted* its own `CacheHint` (its native DeepSeek
adapter caches implicitly and could never produce it), while for routed
`anthropic-messages` protocols it opts into pi-ai's cache surface on purpose
(§3.3). Own no unused cache vocabulary; enable the real one where a provider
honors it.

### 3.2 Cache **write** accounting — small, real, unconditional

**[verified]** this one does not depend on the provider choice: Niffler cannot
see what caching costs. `anthropic.go` parses `cache_creation_input_tokens`
(line 32) and folds it into `PromptTokens` (line 181) but never forwards a
distinct write figure; the usage payload (`main.go:826`) carries only
`prompt_tokens_details.cached_tokens`. Core accumulates `cachePrompt`/
`cacheRead` and derives `cacheHitRate` (`core/conversation.nim`) — reads only.

Visible consequence: every niffler row in `bench/reports/` shows `cache r/w`
with a **zero write column** (`11.6k/0`, `115.9k/0`, …), while Pi reports
`cacheWrite` and a separate `cacheWrite1h` (billed 2× input,
`packages/ai/src/models.ts:903`).

Caveat, so the evidence is not overstated: a zero write column is *not* proof
the OpenAI-family lanes fail to cache — implicit writes simply are not reported
in a comparable field. It is proof that Niffler's own reporting has no write
axis, which is the actual (and cheap) fix.

### 3.3 Retention — Pi's knob, sitting on 3.1

**[verified]** no `PI_CACHE_RETENTION` equivalent, and Pi's is a **write-time
TTL selection**, not an expiry watcher: `cacheRetention: "none" | "short" |
"long"` (`packages/ai/src/types.ts:108`), lowered per provider to Anthropic
`cache_control.ttl: "1h"`, OpenAI `prompt_cache_retention: "24h"` or
`prompt_cache_options.ttl: "30m"` on GPT-5.6+ (types.ts:634–651).

**The vocabulary is Pi's; the decision to use it is dsh's.** dsh's `llm-pi-ai`
package depends on `@earendil-works/pi-ai: ^0.85.1`, so `cacheRetention` is
imported from Pi (`config.ts:16`) rather than authored by dsh — but the relay
is not a blind passthrough. dsh classifies every compat field per protocol with
a `CompatDisposition` gate, and for `anthropic-messages` it explicitly *opts in*
(`catalog.ts:274`):

```ts
const ANTHROPIC_COMPAT_GATE = {
  supportsEagerToolInputStreaming: 'offer',
  supportsLongCacheRetention: 'offer',   // Anthropic cache_control.ttl: 1h
  supportsCacheControlOnTools: 'offer',  // cache_control on tool definitions
  supportsTemperature: 'offer',
  forceAdaptiveThinking: 'offer',
  allowEmptySignature: 'offer',
  supportsStrictTools: 'offer',
  sendSessionAffinityHeaders: 'withhold',   // cache-affinity routing
  supportsToolReferences: 'withhold',
  supportsMidConvoEffort: 'withhold',
  allowedFallbackModels: 'withhold',
} as const satisfies Record<keyof AnthropicMessagesCompat, CompatDisposition>
```

That is an active design position on Anthropic's cache extensions, not an
inherited default: dsh ships a genuine `anthropic-messages` route with both
long retention and tool-definition markers enabled, alongside its own native
`llm-deepseek` adapter (which uses `/chat/completions` — DeepSeek caches
implicitly, so that path needs none of this). Retained here so the distinction
is not lost: **the field is Pi's, the opt-in is dsh's**, and dsh using it is
evidence the Anthropic cache surface is worth having when that path is live.

Work, if the Anthropic path is in play: env + stored-provider field, mapped per
protocol in `components/llm/`, surfaced through `ev.session.status` so cache
metrics stay one source of truth. A TTL on a path with no breakpoints does
nothing, and a long-TTL write invisible to 3.2 cannot be justified — so this
is strictly "after 3.1 and 3.2", and only for providers that honor it.

### 3.4 What dsh actually does about cache (already planned, elsewhere)

Not retention. dsh's real technique is **making the auxiliary call
prefix-reusing** — `packages/compaction/compaction-basic/src/region.ts:518`:

> Reconstruct the last routed request's cacheable prefix for the shadowed
> region: the system prompt …, the header's tool schemas, then the region's own
> derived messages in surface order. The summarizer appends only the compaction
> instruction after this, so the call is a genuine prefix of the conversation
> and reuses the provider's KV cache.

The gain: the summarization call is a second full-context LLM request, and this
makes it a near-total cache hit by replaying the conversation's exact prefix
and appending only the instruction — for **automatic-caching providers too**,
which is what makes it worth more than everything above.

Niffler already plans this: [COMPACTION.md](research/COMPACTION.md) §4.3 step 3
— *"Try the prefix-reusing call: replay frozen system + tools + the covered
messages, append only the compaction instruction (dsh's cache trick)."* It is
filed in the right document for the right reason. Nothing to move; this section
records the cross-link so the two discussions do not drift apart.

[CONTEXT-REVIEW.md](research/CONTEXT-REVIEW.md) §4 refines the hedge: treat
prefix-reusing summarization as an **optional measured strategy, not the
compulsory first attempt on every cut**. A warm prefix can make the
summarization call cheaper, which is exactly why the attempt is worth *trying* —
but summaries cost tokens and latency and can lose information, so the decision
belongs to measurement, and the docs should not promise a win either way.

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
| Expiry-aware prefix surgery (`reset:expired`) | **Cut after review — and independently reached the same conclusion** ([CONTEXT-REVIEW.md](research/CONTEXT-REVIEW.md) §4, written against the earlier revision of this file). No population of deferrable prefix mutations exists: `reset:trim` is forced by pressure, `reset:tools` is model-requested, profiles resolve before any cache exists. Expiry is uncertain, partial and provider-specific; a warm prefix can make the *summarization call itself* cheaper; and zero cached tokens is not uniquely evidence of expiry (thresholds, routing, unsupported caching and serialization changes all explain it). Keep mutation, trigger and observed cache outcome as **separate dimensions**, and never let `reset:expired` conceal a tool/profile mutation — a cold cache is not permission to violate the frozen-prefix contract |
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
are overflow recovery, shell env injection, and — smaller than first assessed —
cache write accounting. Two of those are compaction dependencies, and the cache
item is conditional on running the Anthropic protocol path at all.
