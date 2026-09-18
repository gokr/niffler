# Worklist slice: (Y) Capabilities missing from MANUAL

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A114 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **`x-harness.runner`** — the fifth schema extension core honours, and it is undocumented in MANUAL *and* in AGENTS.md's extension list: a `hidden` tool with `runner: true` is exempt from a session's frozen tool allowlist (`core/dispatch.nim:1455-1473`).

## A115 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **`var/toolout/`** — where `bash` spills long captures (1 h TTL, per session; `components/bash/main.nim:27-34`); every spill path the model sees points there and no state table mentions it.

## A116 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **The other `var/` roots**: `mcp-results/`, `approval-sources/`, `review-receipts/`, `fabric-cache/`, `plugins/`, `nats-monitor-url`, `models/sources/`.

## A117 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **`.env` hardening**: 1 MiB cap, symlink/hardlink refusal, no variable expansion (`sdk/dotenv.nim:1-27,40-52`) — security-relevant and currently invisible.

## A118 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **Build/script-only knobs**: `NIF_BIN_DIR`, `NIF_LSP_BIN`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` — a reader cannot tell them from the runtime set.

## A120 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **Provider OAuth flow lifetime** (15 min, `components/provider/oauth.go:29`) and the fact that all three `provider_oauth_*` tools are `hidden` with their own timeouts (`oauth.go:145,169,185`).

## A121 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **`WARM_MAX_SERVERS = 2`** (`components/lsp/main.nim:743`) — the reason a warmup looks partial.

## A122 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **The session tool-allowlist cap of 32 names** (`core/conversation.nim:2429`).

## A123 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: From the companions, still missing and worth a MANUAL section rather than a line: the provider/**models/effort** mechanism (five effort states, no `none`, `reasoning_effort` sent only when set — `core/conversation.nim:2646`, `components/llm/main.go:436-441`), the **DeepSeek** specifics (`max_tokens` only, `finish_reason: aborted|insufficient_system_resource|length`, the stale `knownContext` ids — `components/llm/main.go:721-786`, `docs/research/DEEPSEEK.md` §1/§3/§4), the `agent_ask`/`agent_notices`/`agent_list` rows, and `fabric_help`.

## A124 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **Schema drift to fix in code, then document**: the `session` tool schema omits `discovery`/`tools`/`maxRounds`/`maxCalls`/`maxTokens` (`core/catalog.nim:184-196` vs `core/conversation.nim:2341,2427-2457`), declares `"enum": ["low","medium","high"]` for `thinking` while accepting `max` (`core/catalog.nim:198-200`), and the mismatch error text says "low, medium or high" (`core/conversation.nim:2647`).

## A150 (missing)
source: `mechanisms.md`

- MANUAL: MANUAL: absent (no `agent_ask`, `agent_notices`, `agent_list`, `agent_steer`, `agent_wait`, `agent_status`, `agent_stop`, `prompt_hint`, `lsp_servers`, `warmup`, `fabric_help`)
- CODE: `components/agent/main.nim:1346,1419,1484,1543`; `components/systemprompt/main.nim:130` (`prompt_hint`, hidden); `components/fabric/fabric.nim:654` (`fabric_help`)
- FIX: inventory them in the relevant sections (§Fabric, §LSP, §Systemprompt).

## A151 (missing)
source: `mechanisms.md`

- MANUAL: MANUAL: absent (restart handoff between UI instances)
- CODE: `~/git/niffler-tui/tui/handoff.go:1-30,60-111` (`handoffTTL = 120s`, sibling of the last-session file, `uiID` adopted by the successor's first register+claim)
- FIX: document under the UI registry that a `/restart` successor adopts the predecessor's ui id from a handoff record (TTL 120 s, per bus+workspace), so the conversation and "Niffler N" label survive.

