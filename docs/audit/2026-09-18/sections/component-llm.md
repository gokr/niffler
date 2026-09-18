# Worklist slice: component: llm

From `worklist.tsv` (8 rows). `class` is one of
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

## A397 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (`runner` flag semantics; grep "x-harness.runner" in MANUAL = 0 hits)
- CODE: `main.go:1107`, `:1154`; `core/dispatch.nim:1470-1474`
- FIX: document `x-harness.runner: true` where the hidden-tool flags are explained (tool-schema extension list / discovery section): a hidden tool that a session runner may call even when the session's `tools` allowlist would exclude it — which is why a restrictive profile can never lock out `chat` or `llm_resolve`.

