# Worklist slice: (Y) missing capability

From `worklist.tsv` (3 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A175 (missing)
source: `mechanisms.md`

- MANUAL: MANUAL: only "`/effort`" is named, at line 242 ("set through the `session` call (`/model`, `/effort` in UIs)")
- CODE: five states `"" | low | medium | high | max`, `""` = provider default shown as "auto" (`core/conversation.nim:211,2646`; `ui/frontend/src/lib/effort.ts:9-14`; TUI `ctrl+g`), forwarded as `reasoning_effort` **only when set** (`components/llm/main.go:436-441`)
- FIX: add an "Effort/thinking" subsection: the five values, that it is per-conversation and persisted in the header, and that providers without support never see the field (there is **no `none` state** — clearing to `""` is the only "off").

## A176 (missing)
source: `mechanisms.md`

- MANUAL: MANUAL: absent (DeepSeek output-cap and finish_reason handling)
- CODE: `components/llm/main.go:773-786` (DeepSeek honors only `max_tokens`; Niffler's default spelling is `max_completion_tokens`, a cap sent that way is ignored → 8K/64K/128K server defaults and `finish_reason: "length"`), `:721-745` (`aborted`/`insufficient_system_resource` become a retryable "stream error" despite HTTP 200; `length` logs a truncation warning), `:748-770` (anthropic `max_tokens`→`length`, `tool_use`→`tool_calls`)
- FIX: add a short "Output caps and finish_reason" subsection naming the DeepSeek spelling quirk and the three terminal reasons; this is the most-asked-about silent-truncation mechanism.

## A177 (code-bug?)
source: `mechanisms.md`

- MANUAL: MANUAL: absent (the `session` tool's `thinking` enum is wrong in core itself)
- CODE: `core/catalog.nim:198-200` declares `"enum": ["low","medium","high"]` while the same description lists `max`, and `core/conversation.nim:2646` accepts `""|low|medium|high|max`
- FIX: (code bug) add `"max"` to the enum; MANUAL should state the real five values + `""`.

