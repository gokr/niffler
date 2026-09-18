# Docs audit — `components/provider/` (Go, 1035 + 867 + 219 LOC)

Read-only audit. No builds/tests run. All claims cite `file:line`.

## 1. What it offers

- A **store-backed registry of LLM backends**, kind `provider` (id = nickname) plus the
  `provider:active` marker doc (`main.go:29-30`, `main.go:203-206`, `main.go:990`); tools
  add/update/list/status/switch/active/get/use_environment/remove/models/export/import and
  subscription-OAuth start/complete/cancel (15 tools total).
- `llm` re-resolves the default backend on **every** chat call from the active store provider
  (`llm/main.go:377-380`), so a switch takes effect immediately without restarting anything;
  absent/inactive falls back to `NIF_OPENAI_*` and `NIF_LLM_PROVIDERS`
  (`main.go:118-136`, `main.go:940-970`).
- Two auth types — `api_key` (plaintext field) and `oauth` (`{access,refresh,expires,accountId}`,
  `main.go:49-74`) — across three protocols: `openai-chat` (API-key default), `openai-codex`,
  `anthropic` (`main.go:193-210`). The component owns login, refresh and storage; `llm` never
  receives a refresh token (`oauth.go:29-30`, `oauth.go:716-742`).
- `plugin` is **inert metadata** on a provider record (`main.go:69`): nothing reads it; the only
  coupling is the `ev.provider.switch` event emitted on activation (`main.go:987-999`) that a
  separately-spawned plugin component is expected to subscribe to.
- Live model-id probing (`provider_models`) with a 5-minute disk cache under
  `$NIF_ROOT/var/models-served` (`models.go:28`, `models.go:52-62`).

## 2. Tools

None of the 15 is in the frozen direct set. `provider_update`/`status`/`active`/`get`/
`use_environment` and the three OAuth tools are `hidden` (component/core-only); the rest are
`onDemand` (reachable only via `discover` + `invoke`). Confirmed by
`tests/t_provider.nim:474-485`.

| Tool | Purpose (schema `description`, main.go/oauth.go) | `x-harness` flags | Exposure |
|---|---|---|---|
| `provider_add` | Add or update an API-key provider; optionally set active (main.go:329) | approval always, timeoutMs 30000, onDemand (`main.go:344`) | discover-only |
| `provider_update` | Update non-secret settings, preserving the credential; non-empty apiKey rotates it (main.go:440) | **hidden**, approval always, timeoutMs 30000 (`main.go:454`) | hidden |
| `provider_remove` | Remove a configured provider (main.go:541) | onDemand (`main.go:547`) | discover-only |
| `provider_list` | List all providers and which is active, keys redacted (main.go:584) | onDemand (`main.go:587`) | discover-only |
| `provider_status` | Effective active provider, no API key (main.go:611) | **hidden** (`main.go:614`) | hidden |
| `provider_use_environment` | Clear the stored active marker so `llm` uses `NIF_OPENAI_*` (main.go:633) | **hidden**, approval always (`main.go:635`) | hidden |
| `provider_switch` | Set the active provider; live-updates the backend and notifies plugins (main.go:652) | onDemand (`main.go:658`) | discover-only |
| `provider_active` | Active provider config **with** credential for routing (main.go:684) | **hidden** (`main.go:687`) | hidden |
| `provider_get` | One stored provider incl. credential, by nickname (main.go:704) | **hidden** (`main.go:710`) | hidden |
| `provider_models` | Model ids the `/models` endpoint serves; nickname or explicit baseUrl+apiKey (main.go:747) | onDemand, timeoutMs 20000 (`main.go:756`) | discover-only |
| `provider_export` | Export all providers incl. keys and refresh tokens (main.go:813) | approval always, timeoutMs 30000, onDemand (`main.go:816`) | discover-only |
| `provider_import` | Import JSON from export; merges, existing updated (main.go:845) | approval always, timeoutMs 30000, onDemand (`main.go:851`) | discover-only |
| `provider_oauth_start` | Start ChatGPT/Claude subscription login; poll `complete` (oauth.go:136) | **hidden**, timeoutMs 30000 (`oauth.go:145`) | hidden |
| `provider_oauth_complete` | Poll a login, store the provider when done; `code` fallback (oauth.go:162) | **hidden**, timeoutMs 30000 (`oauth.go:168`) | hidden |
| `provider_oauth_cancel` | Cancel a pending login, close its listener (oauth.go:182) | **hidden**, timeoutMs 10000 (`oauth.go:185`) | hidden |

## 3. Configuration

**Env vars.** `NIF_OPENAI_API_KEY` (main.go:131), `NIF_OPENAI_BASE_URL` default
`https://api.openai.com/v1` (main.go:119-121), `NIF_OPENAI_MODEL` default `deepseek-chat`
(main.go:123-125, `defaultModel` main.go:36), `NIF_OPENAI_PROVIDER` → catalog id
(main.go:134), `NIF_LLM_PROVIDERS` (consumed by `llm`, `llm/main.go:241`),
`NIF_OAUTH_CALLBACK_HOST` default `127.0.0.1` (oauth.go:52-56), `NIF_ROOT` → served-model
cache dir (models.go:52). No other provider-specific env knobs exist (grep of all three files).

**Store kinds/ids.** Only kind `provider`: `<nickname>` = full `Provider` record incl.
plaintext secret; id `active` = `{nickname, updatedAt}` marker (`main.go:203-206`, written
`main.go:990`, read `main.go:912-918`). A broken/stale marker is silently deleted on read
(`main.go:964-967`). All writes go through `storeClient` (main.go:217-308); OAuth writes at
`oauth.go:681` (login) and `oauth.go:738` (refresh).

**Secrets.** `apiKey` is a plain JSON field; OAuth stores access + refresh token + expiry +
accountId (`main.go:49-74`). Nothing encrypts them at rest; `provider_export` emits them and
`provider_import` accepts them (`main.go:813-905`). Redaction is presentation-only
(`providerSummary`, main.go:77-95) on add/update/list/status/oauth-complete.

**Defaults** (`withDefaults`, main.go:138-183): nickname `deepseek`/`openai` infers a base URL;
protocol `openai-codex` → `https://chatgpt.com/backend-api`, `anthropic` →
`https://api.anthropic.com`; model `gpt-5.4` / `claude-sonnet-4-6` / `deepseek-chat`; catalog
`openai` / `anthropic` per OAuth protocol.

**`plugin` contract + events.** `plugin` names a component (e.g. `provider-deepseek`) but the
provider component never checks, spawns or configures it (only stored/echoed,
main.go:69,87,110,339,450). On activation it emits `ev.provider.switch
{nickname, previous, source, at}` (store: main.go:993-998; environment: nickname `"default"`,
source `environment`, main.go:1011-1015). Every mutation additionally emits secret-free
`ev.provider.changed {op, nickname, active, source, at}` (main.go:972-985) with op
`add`/`update`/`switch`/`remove`/`import` (main.go:430,532,578,900) or `login`/`refresh` (oauth.go:690,741). Consumers: the web UI reloads providers + effective config on
any `ev.provider.` subject (ui/frontend/src/App.svelte:421-426); the TUI plugin listens to
`ev.provider.switch` (var/plugins/niffler-tui@main/tui/main.go:2971). No shipped component
consumes them.

**OAuth specifics.** Fixed callback ports 1455 (OpenAI) and 53692 (Anthropic) (oauth.go:63,79,81);
flow lifetime 15 min, refresh 5 min ahead of expiry (oauth.go:29-30); stored OAuth fields
serialized from the token response (oauth.go:585-600). Device flow OpenAI-only (oauth.go:210).

## 4. MANUAL placement

Existing: heading `## Provider registry (\`provider\`)` at **docs/MANUAL.md:799** (section
runs to line 882, before `## Hooks` at 884). Tools table 806-820; wire protocols 822-838;
subscription OAuth 839-860; approvals/llm-resolution/plugin/events bullets 862-882. Related
mentions: shipped-components row 61; minimal profile 99-108; store "credentials included" 241;
precedence 249; env table 279-286, 349; bus event table 401-402; approval list 461-463;
discovery shipped-policy 1478-1486; store kind table 2182; troubleshooting 2318.
**Proposed:** keep 799 and 822-882; add a "Exposure and client entry points" subsection under
799 (after the tools table) and a "Switch semantics" paragraph; fix 2182 and 2318 in place.

## 5. DELTA list

- MANUAL:2182 `| provider | nickname (plus the active marker doc) | **redacted-at-rest** LLM provider registry` — WRONG, and contradicts MANUAL:241 ("credentials included"). | CODE: secrets stored plaintext, main.go:49-74, 403, oauth.go:681,738; redaction is response-only, main.go:77-95. | FIX: update → "`{nickname, authType, protocol, apiKey|oauth{access,refresh,expires,accountId}, baseUrl, model, catalog, context, plugin, stripPrefix}`; **credentials are stored in plaintext — the store file itself is the secret**; tools return redacted summaries." (2 sentences; fold into the kind-table cell.)
- MANUAL:807/808 `provider_add {...}` and `provider_update {...}` omit **`stripPrefix`**. | CODE: main.go:74, `main.go:340`, `main.go:450`; UI toggles it (App.svelte:189-196). | FIX: update both rows → add `stripPrefix?`; prose: "`stripPrefix` sends model ids without the `vendor/` prefix for gateways (LLMgateway, devpass) that route on the canonical id, e.g. `glm-5.2` for `alibaba/glm-5.2`."
- MANUAL:807 says `provider_add` "add an API-key provider"; it is an **upsert** whose response may report an update and whose first-provider auto-activation also applies to OAuth logins. | CODE: main.go:395-437 (existing rev → op `update`), main.go:417-421; oauth.go:682-687. | FIX: update → "add or overwrite an API-key provider (upsert by nickname; response redacted); the first provider — API-key or OAuth — becomes active automatically unless `active: false`."
- MANUAL:806-820 table gives no **exposure/flags** column and never says every admin tool is `onDemand` (or hidden). | CODE: main.go:344,454,547,587,614,635,658,687,710,756,816,851; oauth.go:145,168,185; `tests/t_provider.nim:474-485`. | FIX: add a column or one line before 806: "None of these tools is in a conversation's frozen direct set: `provider_add`/`remove`/`list`/`switch`/`models`/`export`/`import` are `x-harness.onDemand` (reachable only through `discover` + `invoke`), and `provider_update/status/active/get/use_environment` plus the three OAuth tools are `x-harness.hidden` (components/core only, refused by `invoke`)."
- MANUAL:817 "`provider_switch` — live-updates the LLM backend" and 866-872 do **not** mention **model-pin invalidation** — the highest-impact switch behavior. | CODE: `llm` re-reads per call (llm/main.go:377-380); nothing server-side touches the conversation header; each client must drop the pin (ui/frontend/src/App.svelte:171-183, mirrored by the TUI var/plugins/…/backend.go:263). | FIX: add after 872 → "A switch changes the backend, not the conversation: a pinned `modelOverride` still belongs to the previous provider and may not exist on the new one. Interactive clients therefore clear the pin when the switch actually moves the backend (the web UI and TUI do; a bare `provider_switch` call leaves it in place, so a stale pin can make the next turn fail until `/model default` is issued)."
- MANUAL has no `/provider` documentation; `/provider strip` and `/provider environment` are user entry points. | CODE: ui/frontend/src/lib/slash.ts:78-92; App.svelte:159-166 (switch/environment), 189-196 (`strip` → `provider_update {stripPrefix}`). | FIX: add to the provider section → "`/provider <nickname>` (alias `/providers`) switches the global backend; `/provider environment` returns to `NIF_OPENAI_*`; `/provider strip` toggles vendor-prefix stripping on the active provider. The UI's provider manager wraps the same tools (`provider_add/update/remove`, OAuth start/complete/cancel) with the approval prompt."
- MANUAL:816 describes `provider_models` by behavior only; the tool's own schema description names two **non-existent modes** `providerListModel`/`providerExplicitModel`. | CODE: main.go:747-755 vs properties `nickname`/`baseUrl`/`apiKey`/`refresh` (main.go:757-762). | FIX (code, not MANUAL): rewrite the description to "pass `nickname` for a stored provider's credential, or `baseUrl`+`apiKey` for an endpoint not yet saved"; and in MANUAL add that args are mutually exclusive and a failed probe falls back to catalog ids (models.go:20-28, 67).
- MANUAL:874-877 says `plugin` "may name a component that hooks provider-specific tools" but does not say the field is **inert** or how a plugin can even be reached. | CODE: field only stored/summarized (main.go:69,87,110,339,450,521); no existence check, no spawn, no forwarding; the switch event carries no plugin name (main.go:993-998). | FIX: update → "`plugin` is informational metadata naming the component that owns this provider's extra tools; the provider component does not start or validate it. The plugin must be spawned separately and subscribe to `ev.provider.switch`, comparing the announced `nickname` with the provider records it serves."
- MANUAL:857-859 names only `NIF_OAUTH_CALLBACK_HOST`; the environment-fallback nickname/defaults are missing. | CODE: `environmentProvider()` returns nickname `"default"` (main.go:127-136), base URL default `https://api.openai.com/v1` (main.go:120-121), model default `deepseek-chat` (main.go:123-125); switch-to-environment announces nickname `"default"` (main.go:1012). | FIX: extend 857 → "The fallback backend presents itself as nickname `default` (`source: environment`) with `NIF_OPENAI_BASE_URL` default `https://api.openai.com/v1` and `NIF_OPENAI_MODEL` default `deepseek-chat`; `provider_use_environment` clears the marker, it does not delete stored providers."
- MANUAL:819 "if it was active, another one takes over" hides the **deterministic rule**. | CODE: alphabetically first remaining nickname, else environment (`main.go:1019-1035`). | FIX: append "(the alphabetically first remaining provider, else the `NIF_OPENAI_*` fallback)".
- MANUAL:881 calls `provider:active` "a plain store doc — remove or overwrite it"; shape and self-healing are unstated. | CODE: `{nickname, updatedAt}` (main.go:203-206), written with `expectRev` 0 (main.go:990); an empty/dangling marker is auto-deleted when read (main.go:964-967). | FIX: append "{nickname, updatedAt}; a dangling or empty marker is cleaned up automatically on the next read, so `provider_remove`/`provider_use_environment` need no manual repair."
- MANUAL:1478-1486 lists hidden tools but omits the three **OAuth** tools. | CODE: oauth.go:145,168,185 (`hidden: true`). | FIX: add "`provider_oauth_start/complete/cancel`" to the hidden list at 1483-1486 (or phrase it as "the credential-bearing `provider_*` OAuth tools").
- MANUAL:2318 troubleshooting maps HTTP 401/403 only to `NIF_OPENAI_API_KEY`. | CODE: a stored provider's key/token is the usual cause when one is active (main.go:131 vs 940-970; oauth.go:716-742). | FIX: update → "check the active provider's key/token first (`provider_status` for a redacted view, `provider_list` for expiry); only with no active provider does `NIF_OPENAI_API_KEY` in `.env`/shell decide."
- MANUAL:878-880 says the changed event is for interactive clients but never lists its `op` values or that refresh/login are included. | CODE: ops `add`/`update`/`switch`/`remove`/`import`/`login`/`refresh` (main.go:430,532,578,900; oauth.go:690,741); payload has no credential (main.go:972-985); UI consumer App.svelte:421-426. | FIX: append "(`op` is one of `add`, `update`, `switch`, `remove`, `import`, `login`, `refresh`; the payload is secret-free)".
- `provider_models` cache location/TTL are undocumented. | CODE: `$NIF_ROOT/var/models-served`, 5 min fixed, stale-served-on-error (models.go:28,52-67). | FIX: extend 816 → "cache is per endpoint on disk at `$NIF_ROOT/var/models-served`, valid 5 minutes; a failed probe serves the stale cache, and only a provider never probed falls back to catalog ids."
- MANUAL:817 "live-updates the LLM backend" can be read as a push; MANUAL:866-868 correctly says per-call resolution. | CODE: `llm/main.go:377-380` (re-read each chat call). | FIX: reword 817 → "make another stored provider active; the next chat call (and `llm_resolve`) uses it immediately." (No restart needed, no push involved.)
- MANUAL:822-838 documents the three protocols but not the **API-key restriction**. | CODE: `provider_add` rejects `openai-codex` with an API key (main.go:375) while `provider_update`'s schema enum still offers it (main.go:445) and never re-runs `validStoredProvider` (main.go:197-210, 527). | FIX: add "API-key providers may use `openai-chat` or `anthropic` only; `openai-codex` requires a ChatGPT OAuth login."
- OAuth conversion semantics undocumented. | CODE: logging in over an existing provider with a different protocol clears baseUrl/catalog/model (oauth.go:668-679); the stored credential type cannot be swapped via `provider_update` (main.go:490-493); OAuth protocol cannot be changed (main.go:501-503). | FIX: add one sentence at 848-856 → "Signing in with the same nickname replaces its credential and, if the protocol differs, resets endpoint/catalog/model to the new protocol's defaults. `provider_update` can never turn an OAuth login into an API-key provider (or vice versa): remove and re-add."
- MANUAL:807/808 omission of defaults. | CODE: `withDefaults` main.go:138-183 (nickname `deepseek`/`openai` infer base URLs; model defaults per protocol; catalog defaults `openai`/`anthropic`). | FIX: add a line after 820 → "Omitted fields get protocol defaults: `deepseek`/`openai` nicknames infer their base URLs, models default to `deepseek-chat` (chat), `gpt-5.4` (codex) or `claude-sonnet-4-6` (anthropic), and OAuth protocols infer their models.dev catalog id."

## 6. Not user-facing

- `storeClient` (main.go:212-308), `activeDoc` plumbing (main.go:912-935), OAuth token
  exchange/refresh internals and the callback HTTP server (oauth.go:353,557-620), model-list
  cache mechanics (models.go), and the package doc block (main.go:1-21) are implementation.
- `models_test.go` / `oauth_test.go` are unit-only; MANUAL should not name them.
- The `plugin` field is user-visible (stored, echoed in list/status) but currently has no
  first-party consumer in this repo (`grep` finds only comments/vars; `var/plugins/niffler-tui`
  listens to `ev.provider.switch` without using `plugin`) — document it as a convention, not a
  wired feature.
