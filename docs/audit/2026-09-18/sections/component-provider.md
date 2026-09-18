# Worklist slice: component: provider

From `worklist.tsv` (13 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A465 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:807/808 `provider_add {...}` and `provider_update {...}` omit **`stripPrefix`**.
- CODE: main.go:74, `main.go:340`, `main.go:450`; UI toggles it (App.svelte:189-196).
- FIX: update both rows → add `stripPrefix?`; prose: "`stripPrefix` sends model ids without the `vendor/` prefix for gateways (LLMgateway, devpass) that route on the canonical id, e.g. `glm-5.2` for `alibaba/glm-5.2`."

## A466 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:807 says `provider_add` "add an API-key provider"; it is an **upsert** whose response may report an update and whose first-provider auto-activation also applies to OAuth logins.
- CODE: main.go:395-437 (existing rev → op `update`), main.go:417-421; oauth.go:682-687.
- FIX: update → "add or overwrite an API-key provider (upsert by nickname; response redacted); the first provider — API-key or OAuth — becomes active automatically unless `active: false`."

## A468 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:817 "`provider_switch` — live-updates the LLM backend" and 866-872 do **not** mention **model-pin invalidation** — the highest-impact switch behavior.
- CODE: `llm` re-reads per call (llm/main.go:377-380); nothing server-side touches the conversation header; each client must drop the pin (ui/frontend/src/App.svelte:171-183, mirrored by the TUI var/plugins/…/backend.go:263).
- FIX: add after 872 → "A switch changes the backend, not the conversation: a pinned `modelOverride` still belongs to the previous provider and may not exist on the new one. Interactive clients therefore clear the pin when the switch actually moves the backend (the web UI and TUI do; a bare `provider_switch` call leaves it in place, so a stale pin can make the next turn fail until `/model default` is issued)."

## A469 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL has no `/provider` documentation; `/provider strip` and `/provider environment` are user entry points.
- CODE: ui/frontend/src/lib/slash.ts:78-92; App.svelte:159-166 (switch/environment), 189-196 (`strip` → `provider_update {stripPrefix}`).
- FIX: add to the provider section → "`/provider <nickname>` (alias `/providers`) switches the global backend; `/provider environment` returns to `NIF_OPENAI_*`; `/provider strip` toggles vendor-prefix stripping on the active provider. The UI's provider manager wraps the same tools (`provider_add/update/remove`, OAuth start/complete/cancel) with the approval prompt."

## A470 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:816 describes `provider_models` by behavior only; the tool's own schema description names two **non-existent modes** `providerListModel`/`providerExplicitModel`.
- CODE: CODE: main.go:747-755 vs properties `nickname`/`baseUrl`/`apiKey`/`refresh` (main.go:757-762).
- FIX: FIX (code, not MANUAL): rewrite the description to "pass `nickname` for a stored provider's credential, or `baseUrl`+`apiKey` for an endpoint not yet saved"; and in MANUAL add that args are mutually exclusive and a failed probe falls back to catalog ids (models.go:20-28, 67).

## A471 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:874-877 says `plugin` "may name a component that hooks provider-specific tools" but does not say the field is **inert** or how a plugin can even be reached.
- CODE: field only stored/summarized (main.go:69,87,110,339,450,521); no existence check, no spawn, no forwarding; the switch event carries no plugin name (main.go:993-998).
- FIX: update → "`plugin` is informational metadata naming the component that owns this provider's extra tools; the provider component does not start or validate it. The plugin must be spawned separately and subscribe to `ev.provider.switch`, comparing the announced `nickname` with the provider records it serves."

## A473 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:819 "if it was active, another one takes over" hides the **deterministic rule**.
- CODE: alphabetically first remaining nickname, else environment (`main.go:1019-1035`).
- FIX: append "(the alphabetically first remaining provider, else the `NIF_OPENAI_*` fallback)".

## A475 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:1478-1486 lists hidden tools but omits the three **OAuth** tools.
- CODE: oauth.go:145,168,185 (`hidden: true`).
- FIX: add "`provider_oauth_start/complete/cancel`" to the hidden list at 1483-1486 (or phrase it as "the credential-bearing `provider_*` OAuth tools").

## A476 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:2318 troubleshooting maps HTTP 401/403 only to `NIF_OPENAI_API_KEY`.
- CODE: a stored provider's key/token is the usual cause when one is active (main.go:131 vs 940-970; oauth.go:716-742).
- FIX: update → "check the active provider's key/token first (`provider_status` for a redacted view, `provider_list` for expiry); only with no active provider does `NIF_OPENAI_API_KEY` in `.env`/shell decide."

## A477 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:878-880 says the changed event is for interactive clients but never lists its `op` values or that refresh/login are included.
- CODE: ops `add`/`update`/`switch`/`remove`/`import`/`login`/`refresh` (main.go:430,532,578,900; oauth.go:690,741); payload has no credential (main.go:972-985); UI consumer App.svelte:421-426.
- FIX: append "(`op` is one of `add`, `update`, `switch`, `remove`, `import`, `login`, `refresh`; the payload is secret-free)".

## A478 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:817 "live-updates the LLM backend" can be read as a push; MANUAL:866-868 correctly says per-call resolution.
- CODE: `llm/main.go:377-380` (re-read each chat call).
- FIX: reword 817 → "make another stored provider active; the next chat call (and `llm_resolve`) uses it immediately." (No restart needed, no push involved.)

## A479 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:822-838 documents the three protocols but not the **API-key restriction**.
- CODE: `provider_add` rejects `openai-codex` with an API key (main.go:375) while `provider_update`'s schema enum still offers it (main.go:445) and never re-runs `validStoredProvider` (main.go:197-210, 527).
- FIX: add "API-key providers may use `openai-chat` or `anthropic` only; `openai-codex` requires a ChatGPT OAuth login."

## A480 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:807/808 omission of defaults.
- CODE: `withDefaults` main.go:138-183 (nickname `deepseek`/`openai` infer base URLs; model defaults per protocol; catalog defaults `openai`/`anthropic`).
- FIX: add a line after 820 → "Omitted fields get protocol defaults: `deepseek`/`openai` nicknames infer their base URLs, models default to `deepseek-chat` (chat), `gpt-5.4` (codex) or `claude-sonnet-4-6` (anthropic), and OAuth protocols infer their models.dev catalog id."

