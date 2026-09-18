# Worklist slice: component: expert

From `worklist.tsv` (18 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A314 (doc-edit)
source: `components/expert.md`

- MANUAL: **Cost knobs missing.** `JudgeMaxOutputTokens = 1536`, `JudgeReasoningEffort = "low"`, `ChatTimeoutMs = 120_000` — `main.nim:42-51`; note they are compile-time (a rebuild to change), and that the cap is best-effort (`main.nim:43-48`).

## A315 (doc-edit)
source: `components/expert.md`

- MANUAL: **Prefix budget unexplained.** "fixed cache-stable knowledge prefix" (`docs/MANUAL.md:2111`) should name the 80 % fill / 8 k reserve and `llm.llm_resolve` sizing — `main.nim:57-60`, `main.nim:404-412`.

## A316 (doc-edit)
source: `components/expert.md`

- MANUAL: **Prefix composition unstated.** Policy + the three bundled-only skills + the observed session's frozen exposure/allowlist (`core.prompt_preview`) + `discover` hints — `main.nim:266-357`, `main.nim:386-443`; skills trust boundary at `main.nim:50-56`/`296-322`.

## A317 (doc-edit)
source: `components/expert.md`

- MANUAL: **"No env vars" not stated.** The env table (`docs/MANUAL.md:261`) rightly has no expert row, but a reader looks for one; say so explicitly, and name `NIF_LOG_LEVEL` (`sdk/niffler/sdk.nim:492-509`) as the only env var that changes what you can see.

## A318 (doc-edit)
source: `components/expert.md`

- MANUAL: **Judge model selection undocumented.** Default judge = `llm`'s default model/provider; `expert_follow {model, provider}` overrides per follow and keeps judge cost off the worker's model (`main.nim:808-813`, `main.nim:551-553`, `components/llm/main.go:227`, `components/provider/main.go:123-125`).

## A319 (doc-edit)
source: `components/expert.md`

- MANUAL: **Runner-side limits absent.** One advisory per turn (`advisory-limit`) and identical-content rejection (`duplicate`) plus the full reason set — `core/dispatch.nim:1144-1160`; MANUAL `:2117-2120` lists only stale-turn/no-active-turn.

## A320 (doc-edit)
source: `components/expert.md`

- MANUAL: **Delivery gates underspecified.** High confidence, ≤1200-char message, non-empty `tools`, each tool normalized (backticks, `component.tool`) and present in the session's visible sets, tool textually named in the message, and ≥1 named tool not already used this turn (anti-repeat) — `main.nim:605-664` (cap 605-608, tool normalization 614-623, visibility 630-634, message-contains 636-641, anti-repeat 644-664).

## A321 (doc-edit)
source: `components/expert.md`

- MANUAL: **No store kinds / no durability stated.** All follow state is in-memory and dies with the process (`main.nim:220-241`); the only durable artifact is the folded `message` record (`core/conversation.nim:248-286`, `:991-1003`) — worth one line under Configuration.

## A322 (doc-edit)
source: `components/expert.md`

- MANUAL: **Observation triggers unlisted.** toolcall start/done, turn start/done, assistant text, token reasoning tail, and the context-pressure trigger at ≥80 % (`main.nim:709-793`); turn done clears the frame so advice can never cross turns (`main.nim:735-738`).

## A323 (doc-edit)
source: `components/expert.md`

- MANUAL: **Audit trail unmentioned.** `ev.log.expert` judgment lines with silence reasons (`main.nim:588-594`) — the operator's way to answer "why was it silent?".

## A324 (doc-edit)
source: `components/expert.md`

- MANUAL: **`expert_status` fields truncated.** MANUAL `:2131` lists counters but not `knowledgeVersion`, `liveTools`, `skills`, `prefixChars`, `prefixBudgetTokens`, `tokens{prompt,cached,completion}` — `main.nim:874-925` (frame/counters 883-906, aggregate 908-925).

## A325 (doc-edit)
source: `components/expert.md`

- MANUAL: **Only `expert_follow` appears in "Shipped policy".** `docs/MANUAL.md:1476` should say the whole `expert_*` set is on demand (`main.nim:832,851,871,925`).

## A326 (doc-edit)
source: `components/expert.md`

- MANUAL: **Arming is never shown.** Because all four tools are discover-only, the model cannot call them directly; MANUAL should give the operator path (`discover` + `invoke`, or `./var/bin/cli call expert_follow '{"session_id":"conv-…"}'` — cli usage `docs/MANUAL.md` "cli") and repeat that the component stays inert otherwise (`main.nim:37`).

## A327 (doc-edit)
source: `components/expert.md`

- MANUAL: **Manifest status not stated.** `optional` in the shipped table (`docs/MANUAL.md:69`) but actually autostarted (up to the boot profile), `restart: on-failure` — `manifest.yaml:230-234`.

## A328 (doc-edit)
source: `components/expert.md`

- MANUAL: **Tool docs are thin.** Only `expert_follow` documents its params; `expert_unfollow`/`expert_reload`/`expert_status` have no `- param:` lines (`main.nim:837-841`, `856-862`, `876-880`) — a MANUAL-side gap only in the sense that MANUAL must carry the `session_id` semantics.

## A329 (doc-edit)
source: `components/expert.md`

- MANUAL: **`ev.session.advice` payload documented incompletely.** MANUAL `:391` omits the `reason` field that the runner publishes (`core/conversation.nim:999-1001`).

## A331 (doc-edit)
source: `components/expert.md`

- MANUAL: **Bench config is not user configuration.** `bench/config.json:170` `expertJudge` (bench/README.md:231) — one "benchmark-only" note, or nothing at all in MANUAL.

## A332 (doc-edit)
source: `components/expert.md`

- MANUAL: **WIRE.md has only the advise subject** (`docs/WIRE.md:82`); the advice payload shape (`kind: "advisor"`, `source`, `knowledgeVersion`) is documented nowhere outside the source (`main.nim:476-486`) — a candidate one-liner in WIRE.md's advise entry rather than a MANUAL block.

