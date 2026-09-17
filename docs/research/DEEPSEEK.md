# DeepSeek support in Niffler — verified facts, gaps, plan

*Surveyed 2026-09-17 from `https://api-docs.deepseek.com` (Quick Start, API Guides,
API Reference, Agent Integrations, FAQ, Change Log + news). Every claim below carries
its page; the four raw fact sheets this summarizes were produced by subagents into
`var/deepseek-survey/` (disposable runtime state — this file is the durable copy).*

Niffler's DeepSeek lane is the OpenAI-compatible chat path in `components/llm`
(`providerName == "deepseek"`, base URL `https://api.deepseek.com`), plus the
`niffler-deepseek` plugin for account-level tools. This note records what that lane
must do differently, what is already right, and what to build next.

## 1. What the client must send (and must not)

| Fact (page) | Niffler today |
| --- | --- |
| `max_tokens` is the only documented length cap (1 … 393216); **`max_completion_tokens` does not appear in the Chat Completions reference**. Unset defaults: 8K non-thinking, 64K thinking, 128K at `reasoning_effort: max` (*Chat Completions API*, *Thinking Mode*) | **Was wrong**: the adapter sent only `max_completion_tokens`, so the cap was ignored and the server default applied. Fixed in `components/llm/main.go` (`lengthCap`): DeepSeek gets `max_tokens`, other lanes keep the OpenAI spelling (o-series reject `max_tokens`) |
| `reasoning_content` **must be echoed back in full on every later request when `tools` is present** — even for turns that made no tool call; otherwise HTTP 400 (*Thinking Mode → Tool Calls*) | Compliant: core stores the assistant `reasoning` field and the adapter's `chatMessage.UnmarshalJSON` maps it onto `reasoning_content`. Verified live (tool-using DeepSeek turns succeed) |
| Thinking mode is **on by default**, default effort `high`. `reasoning_effort` enum `none | low | high | max`; `none` disables thinking. Accepted aliases: `minimal→low`, `medium`/`xhigh`→`high`, `ultra→max` (*Thinking Mode*) | Niffler offers `auto/low/medium/high/max` — `medium` is therefore a no-op alias of `high` on DeepSeek and there is **no way to switch thinking off** (no `none` state) |
| `tool_choice: required` or a named tool is a **400 in thinking mode** (*Thinking Mode*) | Compliant: the adapter sends `parallel_tool_calls: true` and never a `tool_choice` |
| `temperature` is ignored in thinking mode; `presence_penalty`/`frequency_penalty` are deprecated no-ops; `top_p` is floor-raised to 0.95 (thinking) or forced to 1.0 (non-thinking) (*Thinking Mode*) | Compliant by omission (the adapter sends none of them) |
| `stream_options` requires `stream: true` (else 400); with `include_usage` every chunk carries `usage` (null except the last), and **no separate usage-only chunk is ever emitted** — the stats ride the last content chunk (*Chat Completions API*) | Compliant: the adapter reads `usage` from any chunk, not from a usage-only one |
| Queued requests: SSE `: keep-alive` comments and blank lines must be tolerated; the server closes a connection only if inference has not started within 10 minutes (*Rate Limit & Isolation*) | Handled by go-openai's SSE reader; core's stream budget (`NIF_LLM_*`) bounds the wait |

## 2. Cache economics — the frozen prefix is worth ~50× here

- Caching is automatic and prefix-based; a hit requires the request prefix to *fully
  match a persisted prefix unit*, so any mutation of earlier messages (trim, reorder,
  re-serialize, a mid-history system message) can drop the hit (*Context Caching*).
  Niffler's prompt-cache discipline (frozen system prompt + frozen tool schemas +
  append-only history) is exactly the right shape.
- Reported per turn as `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`, with the
  OpenAI-shaped alias `prompt_tokens_details.cached_tokens` (*Chat Completions API*).
  **Niffler already consumes the alias** (`core/conversation.nim` sums
  `prompt_tokens_details.cached_tokens`; the adapter forwards it) — measured 98.5% hit
  rate on this harness's own DeepSeek conversation.
- Pricing is peak/off-peak (off-peak = half; peak = Mon–Fri 01:00–04:00 and 06:00–10:00
  UTC). For `deepseek-flash` a cache hit is ~1/50 of a miss ($0.003 vs $0.15 per 1M
  off-peak) and output is 4× a miss ⇒ the prefix discipline is the dominant cost lever,
  and any per-turn cost figure must know the UTC window or it is wrong by 2×
  (*Models & Pricing*).
- `user_id` (regex `[a-zA-Z0-9\-_]{1,512}`) is a **KVCache isolation** knob: two ids do
  not share cache. A per-turn or per-conversation id would silently destroy hit rates;
  if Niffler ever sends it, it must be stable per installation (or deliberately traded
  for isolation) (*Chat Completions API*, *Rate Limit & Isolation*).

## 3. Model catalog (what the catalog should say)

| | `deepseek-flash` | `deepseek-v4-pro` |
| --- | --- | --- |
| context / max output | 1M / 384K | 1M / 384K |
| thinking | default on, effort `high` | same |
| vision | **yes** (images only in user messages; ≤384 tokens/image; `detail: low` downsamples 512×512) | **no** |
| concurrency (account-wide) | 2500 | 500 |
| status | the recommended default (cheapest, most concurrent, best benchmarks per *news260910*) | routing post-2026-09-14 documented inconsistently (pricing page promises service; *news260910* says it routes to V4.1-Flash) |

- Retired / aliased ids: `deepseek-v4-flash`, `deepseek-v4-flash-vision-exp` route to
  V4.1-Flash; `deepseek-chat` / `deepseek-reasoner` were discontinued 2026-07-24.
- **Gap:** Niffler's `knownContext` map (`components/llm/main.go`) still lists only the
  discontinued `deepseek-chat`/`deepseek-reasoner` at 1M, and the llm component's own
  model source registers `deepseek-flash`/`deepseek-v4-pro` with **ids only** — so
  `resolveContextWindow` falls past the catalog to the conservative 128k fallback unless
  a provider record carries an explicit context. The plugin should register a
  `deepseek_models_source` (x-models-source v1 merge patch) exactly like
  `niffler-synthetic`'s, carrying context/output limits, cost, `reasoning: true` and
  per-model input modalities.

## 4. Failure taxonomy and retry

- Terminal (never retry): 400 invalid format (including the `reasoning_content` and
  `tool_choice` traps above), 401 auth, **402 insufficient balance**, 422 invalid
  parameters (*Error Codes*).
- Transient: 429 (concurrency *or* TPM/RPM; **no rate-limit or `Retry-After` headers are
  documented**), 500, 503 (*Error Codes*, *Rate Limit & Isolation*).
- **HTTP 200 that is still a failure**: `finish_reason` ∈ {`insufficient_system_resource`,
  `aborted`} means the provider interrupted the generation; `length` means it was cut at
  the cap. A retry policy keyed on HTTP status records the first two as successful turns.
  Fixed: the adapter turns them into a transient `stream error`, `length` is logged and
  surfaced as `finish_reason` on the result, and `core/retry.nim` no longer treats every
  "insufficient" as billing (that made a *resource* interruption permanent).
- Error **body shape is not documented** (no `error.message` example) — parse
  defensively.
- Balance: `GET /user/balance` → `is_available` + `balance_infos[]` (strings, per
  currency); `is_available: false` predicts 402 (*Get User Balance*). The plugin already
  tracks this.

## 5. Surfaces worth adopting (plugin candidates)

- **Files API** (`POST/GET/DELETE /files`, free): reference an upload by `file_id`;
  raises inline payload limits (32 MiB → 64 MiB) and is the cheap path for repeated
  images (*Files API*).
- **Vision**: flash only; base64, URL, or `file_id`; ≤600 images; user messages only.
- **FIM completion** (beta base URL `https://api.deepseek.com/beta`, `POST /completions`):
  infill with `prompt`/`suffix`, **≤4K output, non-thinking only** — a code-completion
  tool rather than an agent turn.
- **Chat prefix completion** (same beta base): last message must be `assistant` with
  `prefix: true`; forces a shaped continuation (e.g. a fenced code block).
- **Responses / Anthropic lanes**: `https://api.deepseek.com/anthropic`;
  both are stateless (no `previous_response_id`), Anthropic ignores `cache_control`
  and `budget_tokens`, and the Anthropic-format toggle is
  `{"thinking": {"type": "enabled"|"disabled"}}` with effort under
  `output_config.effort` — note Niffler's Anthropic adapter sends
  `thinking: {type: adaptive}`, which DeepSeek's Anthropic surface does not document.

## 6. Backlog (prioritized)

1. ✅ DeepSeek length cap (`lengthCap`) and interrupted/truncated-turn visibility
   (adapter + `core/retry.nim`).
2. **`deepseek_models_source`** in the `niffler-deepseek` plugin — live ids plus limits,
   cost, `reasoning`, modalities (synthetic's source is the template).
3. **Thinking off**: add a `none` effort state end-to-end (core enum, both UIs), sent as
   `reasoning_effort: "none"` only to providers that define it — this is the first
   concrete case of the per-provider effort mapping noted in `ESCALATION.md:44`.
4. Align the plugin with the provider seam: the provider record has a `plugin` field
   whose doc example is `provider-deepseek`; the plugin currently ships a `deepseek`
   component (balance/history/models). Decide the naming and have the component subscribe
   to `ev.provider.switch` so its tools reflect the active provider.
5. Peak/off-peak-aware cost accounting (needs the UTC window; the catalog's single
   `cost` number cannot express it) and `completion_tokens_details.reasoning_tokens`
   accounting.
6. Balance preflight/guardrail (`is_available`, burn-down already tracked by the plugin)
   surfaced before a run rather than as a 402 mid-turn.
7. Files API + vision tools, and a FIM tool, in the plugin.
8. Decide the `user_id` policy (cache isolation vs concurrency sharding) and document it.
9. Concurrency awareness: 2500 (flash) / 500 (pro) per **account**, independent of API
   key; optional `user_id` sharding. Do not rely on headers.

## 7. Not documented (do not assert; probe live if it matters)

- `/v1` path support: the documented OpenAI base URL is bare `https://api.deepseek.com`
  and the balance endpoint is `GET /user/balance`. Niffler's shipped `.env` uses
  `https://api.deepseek.com/v1` and works empirically.
- Error/`Retry-After` header shapes (see §4), and any TPM/RPM numbers.
- `max_completion_tokens` (absent from the reference — treated as ignored).
