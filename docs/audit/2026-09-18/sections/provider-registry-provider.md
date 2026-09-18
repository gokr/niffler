# Worklist slice: Provider registry (provider)

From `worklist.tsv` (8 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A047 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: the 13-row tool table
- CODE: all 13 names exist in `components/provider/main.go` (+ `provider_oauth_*` in `oauth.go:134,160,180`); measured flags: `provider_add` approval+onDemand (`:344`), `provider_update` hidden+approval (`:454`), `provider_list` onDemand (`:547`), `provider_switch` onDemand (`:587`), `provider_status`/`provider_active`/`provider_get`/`provider_use_environment` hidden (`:614,635,687,710`), `provider_models` onDemand 20 s (`:756`), `provider_export`/`provider_import` approval+onDemand (`:816,851`)
- FIX: the table is right about hidden/approval; add a flags column (hidden / approval / on-demand) so the "hidden client API" prose need not be parsed per row.

## A048 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 833-835 "Every credential read (`provider_active`, `provider_get`, status resolution) refreshes the token transparently when it is within 5 minutes of expiry and persists the rotated credential. The `llm` component never sees a refresh token."
- CODE: `components/provider/oauth.go:29-30` (`oauthFlowLifetime = 15m`, `oauthRefreshAhead = 5m`), `:557` (`refresh`) ✔
- FIX: none.

## A049 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 843-845 "ports stay fixed at 1455/53692 like the reference clients"
- CODE: `components/provider/oauth.go:63-65` (1455) and `:79-81` (53692) ✔
- FIX: none.

## A050 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 866-868 "`provider_models` … Disk-cached 5 min per endpoint (stale cache served when the probe fails)"
- CODE: `components/provider/models.go:28` (`modelsCacheTTL = 5 * time.Minute`), `:68-74` (`refresh` bypasses) ✔
- FIX: none.

## A387 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:286` `NIF_LLM_PROVIDERS` "`{nickname: {baseUrl, apiKey, model, context, catalog}}`"
- CODE: `main.go:62-74`, `:292-295`
- FIX: document the full provider object: `protocol` (default `openai-chat`; also `anthropic`, `openai-codex`), `authType` (default `api_key`), `accountId`, and `stripPrefix` — the latter rewrites `alibaba/glm-5.2` to `glm-5.2` for gateways that route on the canonical id (`main.go:508-511`, `:629-634`). Note that a malformed `NIF_LLM_PROVIDERS` JSON and a missing `apiKey` both fail the call explicitly.

## A389 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: absent (grep `finish_reason` = 0 hits; only `context-overflow` is described at `:620-629`)
- CODE: `main.go:726-750`, `:998-1020`
- FIX: add: the result carries `finish_reason` (`length` warns "truncated at the output cap"; unknown reasons pass through), and DeepSeek's `aborted` / `insufficient_system_resource` — HTTP 200 with an interrupted generation — are returned as a transient `stream error: …` so the retry policy sees them instead of recording a successful turn. Anthropic `max_tokens`/`end_turn`/`tool_use` and Codex `max_output_tokens`/`response.incomplete` are canonicalized onto the same vocabulary (`main.go:751-767`, `anthropic.go:161-167`, `codex.go:139-145`).

## A806 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1164-1168 `How a stream ended is reported in `finish_reason`: `length` means the output cap cut the reply short (`llm` logs a truncation warning), `tool_calls` means the model stopped to call tools`
- CODE: `components/llm-openai/main.go:155-190` — the result map carries `content`/`model`/`context`/`usage`/`tool_calls` but **never** `finish_reason`; the response struct does not even decode it (`:118-140`), so with this adapter core's `length` detection (`core/conversation.nim:2315-2325`) can never fire and a truncated reply is accepted as a normal answer
- FIX: add (one clause, or fix in code) — "An adapter that does not report `finish_reason` (the `llm-openai` example) disables this detection entirely: a reply cut at the cap is accepted as the final answer." (Better: decode `choices[0].finish_reason` in `components/llm-openai/main.go` and return it — `code-bug?`.)

## A807 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1161-1163 `Niffler's default spelling is `max_completion_tokens`; DeepSeek honors only `max_tokens`, so a cap sent the default way is ignored and the server's own default (8K/64K/128K, by model) applies — send `max_tokens` for DeepSeek endpoints.`
- CODE: `components/llm-openai/main.go:84-91` (sends `max_tokens: 32768` — the example is on the correct side of this warning, worth naming as the reference)
- FIX: none — verified accurate; optionally cite the example next to it.

