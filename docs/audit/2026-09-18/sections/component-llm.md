# Worklist slice: component: llm

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A383 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:59` "streaming chat adapter (hidden `chat` tool; …)" and `:95` — no tool inventory
- CODE: `components/llm/main.go:1099-1122` (three tools)
- FIX: add a three-row tools table (name, purpose, `hidden/runner/timeoutMs`, who calls it). State that `llm_resolve` is the credential-free client probe and `llm_models_source` is the hidden `x-models-source` v1 source the `models` component calls.

## A384 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:530-534` "The result includes secret-free provider, model, catalog and context provenance"
- CODE: `main.go:1067-1079` returns `output`, `outputSource`, `protocol`, `authType`, `hasKey` too
- FIX: extend that sentence (and `:1595-1599`) to say `llm_resolve` also reports the resolved output window with its provenance and the provider's protocol/authType/hasKey. Note it still needs a resolvable provider: with no stored and no env credential it fails instead of reporting a window (`main.go:266-300`).

## A385 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (output window / `resolveOutputWindow` appear nowhere; grep `outputSource` = 0 hits)
- CODE: `main.go:84-90`, `:156-176`
- FIX: add a paragraph: the max-output window comes from the catalog's `model.limit.output`, else a deliberate 32768 default chosen because without an explicit cap the provider applies its own server-side cap and truncates long answers mid-stream. Per-call `maxTokens` (e.g. the expert judge's tiny verdicts) only ever lowers the resolved value (`main.go:500-501`), and the Codex lane ignores it entirely (`main.go:509-510`).

## A388 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (grep `max_tokens` = 0 hits)
- CODE: `main.go:770-784` (`lengthCap`)
- FIX: document that the cap is sent as `max_completion_tokens` for every openai-chat provider **except** DeepSeek, which documents only `max_tokens` and silently ignores the other spelling (server default 8K non-thinking / 64K thinking then applies). Anthropic always receives the resolved window as `max_tokens` (`anthropic.go:212`).

## A389 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (grep `finish_reason` = 0 hits; only `context-overflow` is described at `:620-629`)
- CODE: `main.go:726-750`, `:998-1020`
- FIX: add: the result carries `finish_reason` (`length` warns "truncated at the output cap"; unknown reasons pass through), and DeepSeek's `aborted` / `insufficient_system_resource` — HTTP 200 with an interrupted generation — are returned as a transient `stream error: …` so the retry policy sees them instead of recording a successful turn. Anthropic `max_tokens`/`end_turn`/`tool_use` and Codex `max_output_tokens`/`response.incomplete` are canonicalized onto the same vocabulary (`main.go:751-767`, `anthropic.go:161-167`, `codex.go:139-145`).

## A390 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:242` mentions `/effort`; no `reasoning_effort` value set or lane behavior anywhere (grep `reasoning_effort` in MANUAL = 0 hits)
- CODE: `main.go:437-440`, `:1147-1149`; `anthropic.go:231-234`; `codex.go:208-212`
- FIX: document that `thinking`/`reasoning_effort` accepts `low|medium|high|max` (empty = provider default) and is **only sent when non-empty**, so providers that do not support it never see the field; openai-chat forwards the field verbatim, Codex converts it to `reasoning {effort, summary: "auto"}`, Anthropic to `thinking {type: adaptive, display: summarized}` + `output_config.effort` (plus the interleaved-thinking beta on OAuth). Add that the `session` schema enum lists only `low/medium/high` while the description and core's validation accept `max` (`core/catalog.nim:198`, `core/conversation.nim:2646`) — a real inconsistency.

## A391 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:422` "Abort an in-flight call by publishing to `llm.cancel.<sessionId>`"
- CODE: `main.go:474-486`
- FIX: add the two preconditions and the escape hatch: the subscription is armed only when the call is streamed (`stream: true`; core always sets it, `core/conversation.nim:1895`), and the subject uses `cancelId` when the caller supplies one, defaulting to `sessionId`. Auxiliary callers rely on that: compaction cancels `llm.cancel.compaction.<sessionId>…` so a user's turn stop cannot kill (or be killed by) a summarization call (`components/compaction/main.nim:278-288`).

## A392 (code-bug?)
source: `components/llm.md`

- MANUAL: - MANUAL: `:403`/`:417-421` `ev.llm.token {sessionId, content, reasoning}`
- CODE: `main.go:953-963`, `codex.go:333-341`
- FIX: note that frames are emitted only for calls with `emitTokens` true (default; auxiliary callers pass false so partial output never appears as assistant text) and a non-empty `sessionId`, one frame per stream chunk with either content or reasoning. Mention the `purpose` argument as telemetry-only (logged with provider/model/effort/ttft/tok-s) and that it never changes provider behavior (`main.go:433-436`, `main.go:886-902`).

## A395 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (`repair`, `sanitizeMessages`, "truncated tool call" = 0 hits in MANUAL)
- CODE: `main.go:636-723`
- FIX: add one or two sentences: before sending, assistant `tool_calls` arguments in replayed history are repaired (unterminated strings/containers closed, unrecoverable payloads become `{}`) so a strict backend cannot 400 a session poisoned by an earlier truncated stream; this runs on text only and never executes anything.

## A396 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:1585-1589` describes the live source accurately (priority 150, background probe after chats, 10-minute TTL) but never names `llm_models_source`
- CODE: `models_source.go:25-95`, `:136-140`; `main.go:1114-1122`
- FIX: name the tool and add its bounds: one probe per (catalog provider, base URL) key per 10 minutes, 8s probe timeout, in-memory only (a restart loses the ids until the next chat), `GET {baseUrl}/models`, Codex excluded because the ChatGPT backend exposes no such route, and the tool errors `"no live model data yet"` until the first successful probe.

## A397 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (`runner` flag semantics; grep "x-harness.runner" in MANUAL = 0 hits)
- CODE: `main.go:1107`, `:1154`; `core/dispatch.nim:1470-1474`
- FIX: document `x-harness.runner: true` where the hidden-tool flags are explained (tool-schema extension list / discovery section): a hidden tool that a session runner may call even when the session's `tools` allowlist would exclude it — which is why a restrictive profile can never lock out `chat` or `llm_resolve`.

## A399 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (`stripPrefix`, `accountId` = 0 hits)
- CODE: `main.go:68-73`, `main.go:508-511`; `codex.go:41-52`
- FIX: fold into the provider-object documentation (delta 5) rather than a new paragraph: `stripPrefix` is the gateway workaround, and `accountId` is the ChatGPT account id used to build Codex request headers, derived from the JWT when the provider record does not carry one — a Codex call with neither fails with "OAuth token has no ChatGPT account id; sign in again".

