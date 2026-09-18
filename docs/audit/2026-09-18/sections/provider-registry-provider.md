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

## A466 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:807 says `provider_add` "add an API-key provider"; it is an **upsert** whose response may report an update and whose first-provider auto-activation also applies to OAuth logins.
- CODE: main.go:395-437 (existing rev → op `update`), main.go:417-421; oauth.go:682-687.
- FIX: update → "add or overwrite an API-key provider (upsert by nickname; response redacted); the first provider — API-key or OAuth — becomes active automatically unless `active: false`."

## A473 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:819 "if it was active, another one takes over" hides the **deterministic rule**.
- CODE: alphabetically first remaining nickname, else environment (`main.go:1019-1035`).
- FIX: append "(the alphabetically first remaining provider, else the `NIF_OPENAI_*` fallback)".

## A474 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:881 calls `provider:active` "a plain store doc — remove or overwrite it"; shape and self-healing are unstated.
- CODE: `{nickname, updatedAt}` (main.go:203-206), written with `expectRev` 0 (main.go:990); an empty/dangling marker is auto-deleted when read (main.go:964-967).
- FIX: append "{nickname, updatedAt}; a dangling or empty marker is cleaned up automatically on the next read, so `provider_remove`/`provider_use_environment` need no manual repair."

## A478 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:817 "live-updates the LLM backend" can be read as a push; MANUAL:866-868 correctly says per-call resolution.
- CODE: `llm/main.go:377-380` (re-read each chat call).
- FIX: reword 817 → "make another stored provider active; the next chat call (and `llm_resolve`) uses it immediately." (No restart needed, no push involved.)

