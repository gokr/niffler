# Audit: `components/llm` (Go, 3052 lines incl. tests) — docs/MANUAL.md coverage

Read-only audit. Every claim below was seen in the cited file:line. Lines in
`main.go`/`codex.go`/`anthropic.go`/`models_source.go` are the component's own.

## 1. What it offers

- The single inference adapter every conversation turn goes through: one hidden
  `chat` tool that resolves a backend, sends the request, streams the answer and
  returns the result shape core's loop consumes (`components/llm/main.go:1127`,
  `:998-1052`).
- Three wire lanes, selected by the provider's `protocol`: OpenAI-compatible
  Chat Completions (default), OpenAI Codex / ChatGPT Responses (`codex.go:37`),
  Anthropic Messages (`anthropic.go:73`) — `main.go:503-528`.
- Backend resolution with provenance: explicit `provider` arg → stored provider
  registry → `NIF_LLM_PROVIDERS` → `NIF_OPENAI_*` (`main.go:266-300`), plus
  context/output-window resolution (`main.go:114-177`) and gateway model-id
  stripping (`main.go:629-634`).
- Streaming with live token events, per-call cancellation, usage/cache
  accounting, tool-call aggregation, retry semantics (Retry-After surfacing,
  context-overflow classification), and history repair for truncated streams.
- Also the live model-id discovery source for the `models` catalog
  (`x-models-source` v1, priority 150) — `main.go:1114-1122`, `models_source.go:25-95`.

## 2. Tools (all three are `hidden`; none is in any conversation's direct set)

| Tool | Purpose (schema description / doc comment) | x-harness flags | Reachability |
|---|---|---|---|
| `chat` | Infer one completion (`messages`, `tools`, `model`, `provider`, `sessionId`, `cancelId`, `stream`, `emitTokens`, `purpose`, `reasoning_effort`, `maxTokens`) | `hidden: true, runner: true, timeoutMs: chatTimeoutMs()` (`main.go:1154`, `:1084-1091`) | Called by core's conversation loop/UIs by name (`core/conversation.nim:1892-1901`); not LLM-visible (hidden), not discover-only (no `onDemand`) |
| `llm_resolve` | "Resolve the effective provider, model and context window without exposing credentials or making an inference request" (`main.go:1100-1112`) | `hidden: true, runner: true, timeoutMs: 10000` (`main.go:1107`) | Hidden client API (session UI/`/model`); returns provider, model, catalog, context+source, output+source, protocol, authType, `hasKey` (`main.go:1067-1079`) |
| `llm_models_source` | "Live model ids observed per provider; x-models-source v1 patch" (`main.go:1114-1122`) | `hidden: true` only; also `x-models-source {version: 1, priority: 150}` (`main.go:1121`) | Internal: called by the `models` component on its refresh cycle; errors `"no live model data yet"` until a chat has probed (`models_source.go:91`) |

- No `x-harness.approval` and no `x-harness.onDemand` anywhere in the component.
- `x-harness.runner: true` is what exempts `chat`/`llm_resolve` from a session's
  tool allowlist (`core/dispatch.nim:1470-1474`) — undocumented in MANUAL.
- Both `chat` and `llm_resolve` are registered `ToolConcurrent` (explicit
  shared-state audit: only read-only package maps) — `main.go:1093-1099`,
  `:1126-1127`.

## 3. Configuration

Env vars read by this component (grep of `os.Getenv` in `components/llm/`):

| Var | file:line | Default | Meaning |
|---|---|---|---|
| `NIF_OPENAI_BASE_URL` | `main.go:223` | `https://api.openai.com/v1` | default provider endpoint |
| `NIF_OPENAI_MODEL` | `main.go:227` | `deepseek-chat` | default model |
| `NIF_OPENAI_API_KEY` | `main.go:234` | — | credential; absent → `provider "default": no API key` (`main.go:296-298`) |
| `NIF_OPENAI_PROVIDER` | `main.go:236` | — | catalog provider id for the default connection (else inferred from hostname/`deepseek-` prefix/`NIF_LLM_PROVIDERS` nickname — `main.go:201-221`) |
| `NIF_LLM_PROVIDERS` | `main.go:241` | `{}` | JSON `{nickname: provider}`; a parse error is fatal to the call (`main.go:241-249`) |
| `NIF_OPENAI_CONTEXT` | `main.go:122` | — | context window override, 2nd in precedence (`main.go:118-126`) |
| `NIF_LLM_TIMEOUT_MS` | `main.go:1085` | `300000` | `chat` `x-harness.timeoutMs`, read once at registration |

`provider` JSON fields honored (`main.go:62-74`): `baseUrl, apiKey, model,
context, catalog, protocol, authType, accountId, stripPrefix`; `protocol`
defaults `openai-chat`, `authType` defaults `api_key` (`main.go:292-295`).

Context/output resolution (provenance strings returned by `llm_resolve`):
- context: provider `context` → `NIF_OPENAI_CONTEXT` → `models_get` catalog
  `model.limit.context` → builtin map `deepseek-chat`/`deepseek-reasoner`
  `1000000`, `syn:large:text` `524288`, `zai-org/glm-5.3-flash` `524288`
  (`main.go:91-97`) → fallback `128000` (`main.go:78`); catalog calls are
  bounded at 1.5s (`main.go:128`).
- output: catalog `model.limit.output` → fallback `32768` (`main.go:84-90`,
  `:156-176`); per-call `maxTokens` only lowers it (`main.go:500-501`).
- provider/model: stored `provider_active` (1.5s timeout, re-read per chat, so
  `provider_switch` is live) → `provider_get {nickname}` → env table
  (`main.go:323-389`).

Files under `var/`: **none written by this component** (no `os.Create`/
`WriteFile`/`MkdirAll` in `components/llm/`). Its log line per request goes to
`var/logs/llm.log` via the supervisor (`core/supervisor.nim:130-133`). The live
model-id cache is process-local memory only (`models_source.go:40-53`), unlike
the `provider` component's 5-minute disk cache.

Store kinds: none read or written directly. It reaches the store only through
peers — `models_get` (`main.go:130`, `:160`), `provider_active`/`provider_get`
(`main.go:379-385`).

Manifest: `manifest.yaml:105-107` — `lang: go`, `autostart: true`,
`required: true`, `restart: on-failure`, **no `replicas`** (single instance, the
SDK's default queue group; safe because every handler is request-local).

## 4. MANUAL placement

- Existing: `### Shipped components` row (`docs/MANUAL.md:59`) and the
  `--minimal` list (`:95`); env rows `:279-286`, `:309`; bus/streaming
  `:417-422`; context window `:530-534`; provider registry `:799-883`; model
  catalog live sources `:1585-1599`; troubleshooting `:2318`.
- **No `## llm` section exists.** Proposed: a new `## LLM adapter (`llm`)` heading
  inserted after the provider-registry section, i.e. at the blank line before
  `## Hooks` (`docs/MANUAL.md:884`); it should sit next to `## Provider registry
  (`provider`)` (:799) and `## Model catalog (`models`)` (:1518) since it consumes
  both, with the tools table (section 2) and the resolution chains (section 3).

## 5. DELTA list

1. - MANUAL: `:59` "streaming chat adapter (hidden `chat` tool; …)" and `:95` — no tool inventory | CODE: `components/llm/main.go:1099-1122` (three tools) | FIX: add a three-row tools table (name, purpose, `hidden/runner/timeoutMs`, who calls it). State that `llm_resolve` is the credential-free client probe and `llm_models_source` is the hidden `x-models-source` v1 source the `models` component calls.
2. - MANUAL: `:530-534` "The result includes secret-free provider, model, catalog and context provenance" | CODE: `main.go:1067-1079` returns `output`, `outputSource`, `protocol`, `authType`, `hasKey` too | FIX: extend that sentence (and `:1595-1599`) to say `llm_resolve` also reports the resolved output window with its provenance and the provider's protocol/authType/hasKey. Note it still needs a resolvable provider: with no stored and no env credential it fails instead of reporting a window (`main.go:266-300`).
3. - MANUAL: absent (output window / `resolveOutputWindow` appear nowhere; grep `outputSource` = 0 hits) | CODE: `main.go:84-90`, `:156-176` | FIX: add a paragraph: the max-output window comes from the catalog's `model.limit.output`, else a deliberate 32768 default chosen because without an explicit cap the provider applies its own server-side cap and truncates long answers mid-stream. Per-call `maxTokens` (e.g. the expert judge's tiny verdicts) only ever lowers the resolved value (`main.go:500-501`), and the Codex lane ignores it entirely (`main.go:509-510`).
4. - MANUAL: `:283` `NIF_OPENAI_CONTEXT` default cell "`models` catalog, then `llm` fallback"; `:108` "its small built-in model table and then a 128K fallback" | CODE: `main.go:114-153` | FIX: give the real order — stored provider `context`, then `NIF_OPENAI_CONTEXT`, then the catalog, then the built-in table, then 128000 — and name the built-in entries (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288), flagging that the table is code-resident and needs a source change for a new model.
5. - MANUAL: `:286` `NIF_LLM_PROVIDERS` "`{nickname: {baseUrl, apiKey, model, context, catalog}}`" | CODE: `main.go:62-74`, `:292-295` | FIX: document the full provider object: `protocol` (default `openai-chat`; also `anthropic`, `openai-codex`), `authType` (default `api_key`), `accountId`, and `stripPrefix` — the latter rewrites `alibaba/glm-5.2` to `glm-5.2` for gateways that route on the canonical id (`main.go:508-511`, `:629-634`). Note that a malformed `NIF_LLM_PROVIDERS` JSON and a missing `apiKey` both fail the call explicitly.
6. - MANUAL: absent (grep `max_tokens` = 0 hits) | CODE: `main.go:770-784` (`lengthCap`) | FIX: document that the cap is sent as `max_completion_tokens` for every openai-chat provider **except** DeepSeek, which documents only `max_tokens` and silently ignores the other spelling (server default 8K non-thinking / 64K thinking then applies). Anthropic always receives the resolved window as `max_tokens` (`anthropic.go:212`).
7. - MANUAL: absent (grep `finish_reason` = 0 hits; only `context-overflow` is described at `:620-629`) | CODE: `main.go:726-750`, `:998-1020` | FIX: add: the result carries `finish_reason` (`length` warns "truncated at the output cap"; unknown reasons pass through), and DeepSeek's `aborted` / `insufficient_system_resource` — HTTP 200 with an interrupted generation — are returned as a transient `stream error: …` so the retry policy sees them instead of recording a successful turn. Anthropic `max_tokens`/`end_turn`/`tool_use` and Codex `max_output_tokens`/`response.incomplete` are canonicalized onto the same vocabulary (`main.go:751-767`, `anthropic.go:161-167`, `codex.go:139-145`).
8. - MANUAL: `:242` mentions `/effort`; no `reasoning_effort` value set or lane behavior anywhere (grep `reasoning_effort` in MANUAL = 0 hits) | CODE: `main.go:437-440`, `:1147-1149`; `anthropic.go:231-234`; `codex.go:208-212` | FIX: document that `thinking`/`reasoning_effort` accepts `low|medium|high|max` (empty = provider default) and is **only sent when non-empty**, so providers that do not support it never see the field; openai-chat forwards the field verbatim, Codex converts it to `reasoning {effort, summary: "auto"}`, Anthropic to `thinking {type: adaptive, display: summarized}` + `output_config.effort` (plus the interleaved-thinking beta on OAuth). Add that the `session` schema enum lists only `low/medium/high` while the description and core's validation accept `max` (`core/catalog.nim:198`, `core/conversation.nim:2646`) — a real inconsistency.
9. - MANUAL: `:422` "Abort an in-flight call by publishing to `llm.cancel.<sessionId>`" | CODE: `main.go:474-486` | FIX: add the two preconditions and the escape hatch: the subscription is armed only when the call is streamed (`stream: true`; core always sets it, `core/conversation.nim:1895`), and the subject uses `cancelId` when the caller supplies one, defaulting to `sessionId`. Auxiliary callers rely on that: compaction cancels `llm.cancel.compaction.<sessionId>…` so a user's turn stop cannot kill (or be killed by) a summarization call (`components/compaction/main.nim:278-288`).
10. - MANUAL: `:403`/`:417-421` `ev.llm.token {sessionId, content, reasoning}` | CODE: `main.go:953-963`, `codex.go:333-341` | FIX: note that frames are emitted only for calls with `emitTokens` true (default; auxiliary callers pass false so partial output never appears as assistant text) and a non-empty `sessionId`, one frame per stream chunk with either content or reasoning. Mention the `purpose` argument as telemetry-only (logged with provider/model/effort/ttft/tok-s) and that it never changes provider behavior (`main.go:433-436`, `main.go:886-902`).
11. - MANUAL: `:566-573` documents `prompt_tokens_details.cached_tokens` for cache hits | CODE: `main.go:1037-1052`; `anthropic.go:186-200`; `codex.go:325-331` | FIX: add the lane definitions: openai-chat forwards the provider's usage verbatim; Anthropic synthesizes `prompt_tokens = input + cache_read + cache_creation` but reports only `cache_read_input_tokens` as cached tokens (cache writes are billed at write rates); Codex maps the Responses usage object. The `usage` object exists only when the provider actually reported non-zero tokens (`usageSeen`).
12. - MANUAL: `:308` `NIF_LLM_RETRY_AFTER_CAP_MS` "upper bound honored from a server `retry-after` hint" | CODE: `main.go:536-578` | FIX: name the mechanism: `llm` wraps the HTTP client, parses `Retry-After` (seconds or HTTP date), and appends `; retry-after-ms: <n>` to the provider's error message so core can honor the wait without each adapter depending on the same client library. Invalid/absent headers leave the error untouched.
13. - MANUAL: absent (`repair`, `sanitizeMessages`, "truncated tool call" = 0 hits in MANUAL) | CODE: `main.go:636-723` | FIX: add one or two sentences: before sending, assistant `tool_calls` arguments in replayed history are repaired (unterminated strings/containers closed, unrecoverable payloads become `{}`) so a strict backend cannot 400 a session poisoned by an earlier truncated stream; this runs on text only and never executes anything.
14. - MANUAL: `:1585-1589` describes the live source accurately (priority 150, background probe after chats, 10-minute TTL) but never names `llm_models_source` | CODE: `models_source.go:25-95`, `:136-140`; `main.go:1114-1122` | FIX: name the tool and add its bounds: one probe per (catalog provider, base URL) key per 10 minutes, 8s probe timeout, in-memory only (a restart loses the ids until the next chat), `GET {baseUrl}/models`, Codex excluded because the ChatGPT backend exposes no such route, and the tool errors `"no live model data yet"` until the first successful probe.
15. - MANUAL: absent (`runner` flag semantics; grep "x-harness.runner" in MANUAL = 0 hits) | CODE: `main.go:1107`, `:1154`; `core/dispatch.nim:1470-1474` | FIX: document `x-harness.runner: true` where the hidden-tool flags are explained (tool-schema extension list / discovery section): a hidden tool that a session runner may call even when the session's `tools` allowlist would exclude it — which is why a restrictive profile can never lock out `chat` or `llm_resolve`.
16. - MANUAL: `:279` `NIF_OPENAI_API_KEY` "Required for any conversation turn" | CODE: `main.go:296-298` | FIX: keep, but make the failure explicit: with no key at all the adapter refuses before any HTTP request with `provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`, which is a different symptom from the troubleshooting row's HTTP 401/403 (`:2318`, a key that exists but is rejected).
17. - MANUAL: absent (`stripPrefix`, `accountId` = 0 hits) | CODE: `main.go:68-73`, `main.go:508-511`; `codex.go:41-52` | FIX: fold into the provider-object documentation (delta 5) rather than a new paragraph: `stripPrefix` is the gateway workaround, and `accountId` is the ChatGPT account id used to build Codex request headers, derived from the JWT when the provider record does not carry one — a Codex call with neither fails with "OAuth token has no ChatGPT account id; sign in again".
18. - MANUAL: `:1482` lists "LLM `chat`/`llm_resolve`" among tools whose registration the catalog projection covers | CODE: consistent | FIX: none — recorded as a verified-correct claim (no change).

## 6. Not user-facing

Nothing in this component is internal-only, so there is no "not user-facing"
inventory line: every item above is operator- or client-visible (a tool a UI
calls, an env var, a wire event, or an error string a user reads). The one
honest inventory statement is negative — `components/llm` registers **no store
kind of its own** and writes **no file under `var/`**; its only persistent
trace is the supervisor-owned `var/logs/llm.log`.

## Counts

- Findings/deltas: **18** (17 requiring MANUAL changes, 1 verified-correct).
- Wrong or stale MANUAL claims found: **0 outright wrong**; 3 incomplete to the
  point of misleading (`:283` precedence, `:286` provider shape, `:530-534`
  resolution provenance without `output`).
- Claims MANUAL makes that I could not confirm are absent-by-design and want
  wording added: `max_tokens`-only DeepSeek, `finish_reason`/interruption
  surfacing, `reasoning_effort` value set.
