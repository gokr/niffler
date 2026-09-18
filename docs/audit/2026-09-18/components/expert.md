# Docs audit — `components/expert/` (Nim, 927 lines, 1 file)

Scope: `/home/gokr/git/nifflerprod` @ working tree (read-only audit; report only).
Component: `components/expert/main.nim` (927 lines), binary `var/bin/expert`,
manifest `manifest.yaml:230-234` (autostart: true, required: false, restart: on-failure).
Peer docs: `docs/research/EXPERT.md` (513 lines, §1-§10), `docs/MANUAL.md` §2107-2137, `docs/WIRE.md:82`.

## 1. What it offers

- A single non-interactive **advisory peer process**: it taps `ev.session.>` (`main.nim:795-797`), keeps one bounded in-memory frame per followed session, and asks the hidden `chat` tool (`llm`) to judge whether the working agent picked the right *Niffler mechanism* (`main.nim:80-153` policy).
- Arming is explicit: inert until `expert_follow {session_id}` (module doc `main.nim:37`, tool doc `main.nim:800-810`); multi-target — every followed session keeps its own frame, knowledge prefix, judgment budget and counters (`main.nim:175-219` `Follow` type, `main.nim:806-810`).
- Only high-confidence steers that name a session-visible tool the worker is *not* already using reach the worker, through the turn-bound `svc.session.<id>.advise` request/reply (`main.nim:475-499`; `sdk/subjects.nim:69-71`).
- Accepted advice is folded into the working transcript as a marked user message and persisted; nothing is ever queued across a turn boundary (`core/conversation.nim:994-1003`, `core/dispatch.nim:1144-1160`).
- Best-effort by construction: the working session never awaits the judge; one global judge lane, shared cooldown, latest-state coalescing, fail-closed on any parse/validation/transport error (`main.nim:675-707`, `main.nim:22-35`, `main.nim:37`).

## 2. Tools

All four tools are `x-harness.onDemand: true` → **discover-only**, never part of a conversation's frozen direct set; none carries `x-harness.hidden`, `sessionId`, `sessionContext`, `workspace` or `effect` (absent `effect` = `"write"` for fabric batch scheduling).

| Tool | Purpose (doc comment) | Flags | Direct vs discover-only |
|---|---|---|---|
| `expert_follow {session_id, model?, provider?}` | follow a working session; re-follow resets its frame; use when you want a knowledgeable peer to keep the conversation on the correct Niffler tool (`main.nim:800-820`) | `{"approval":"always","onDemand":true}` (`main.nim:831-832`) | discover-only; human-gated |
| `expert_unfollow {session_id?}` | stop following; with id drop that follow, without drop all; pending judgments abandoned (`main.nim:837-853`) | `{"onDemand":true}` (`main.nim:851`) | discover-only |
| `expert_reload` | rebuild every followed session's knowledge prefix against the live catalog (new cache epoch) after installing/removing components or editing bundled skills (`main.nim:856-873`) | `{"onDemand":true}` (`main.nim:871`) | discover-only |
| `expert_status {session_id?}` | per-follow frame/knowledge version/counters, or aggregate targets + lifetime diagnostics; no transcript content (`main.nim:876-925`) | `{"onDemand":true}` (`main.nim:925`) | discover-only |

- Tool name → doc-comment purpose is the only LLM-visible text: no `- param:` line exists for `session_id` on follow/unfollow/status beyond follow's (`main.nim:808-813`) — only `expert_follow`'s params are documented.
- **Advise surface (not a tool)**: `svc.session.<id>.advise`, a NATS request/reply call envelope `{sessionId, turnId, kind:"advisor", source:"expert", content, reason, knowledgeVersion}` (`main.nim:476-486`); caller is any bus client but only the *addressed session runner* can accept it (`core/dispatch.nim:1113-1160`).
- Runner acceptance gates, in order (`core/dispatch.nim:1141-1160`): `bad-envelope`, `no-active-turn`, `wrong-session`, `stale-turn` (turnId mismatch → never queued), `empty`, `duplicate` (identical to the previous accepted content), `advisory-limit` (**one advisory per turn**); reply is `{accepted, reason}`.

## 3. Configuration

**The component reads no environment variables at all** — `grep -n 'getEnv|NIF_' components/expert/main.nim` has zero matches (the sole `NIF_` hit is prose in the `provider` param doc, `main.nim:812`). There is no `NIF_EXPERT_*` knob and no row in `docs/MANUAL.md` §261's env table.

Everything else is compile-time or per-follow:

| Knob | Value | Where |
|---|---|---|
| judge model / provider | per follow; empty = the follow's default → `llm`'s own resolution | `expert_follow {model, provider}` (`main.nim:808-813`), applied to `llm.chat` (`main.nim:546-548`); nil → `components/llm/main.go:227` `NIF_OPENAI_MODEL`, else active provider (`components/provider/main.go:123-125` `NIF_OPENAI_MODEL`, fallback `deepseek-chat` at `provider/main.go:39`) |
| named judge providers | `NIF_LLM_PROVIDERS` nicknames / stored provider | param doc `main.nim:812`; `components/llm/main.go:241-263` |
| judge output cap | `JudgeMaxOutputTokens = 1536` (compile-time) | `main.nim:43-49`, sent `main.nim:545` |
| judge reasoning effort | `"low"` (compile-time) | `main.nim:48-51`, sent `main.nim:546` |
| judge call timeout | `ChatTimeoutMs = 120_000` | `main.nim:42`, applied `main.nim:552` |
| judgments per turn | `MaxJudgmentsPerTurn = 2` | `main.nim:38` (gate `main.nim:681-683`) |
| cooldown between judgments | `EvalCooldownMs = 8_000`, shared component-wide | `main.nim:39-41`, gate `main.nim:687-691` |
| observation window | `MaxActivities = 8`, `MaxField = 400`, `MaxReasoningTail = 2000` | `main.nim:33-35`; trims `main.nim:749-751`, `main.nim:764-766`, `main.nim:790` |
| advisory message cap | `MaxMessage = 1200` chars | `main.nim:36-37`, gate `main.nim:605-608` |
| prefix budget | `PrefixFillRatio = 0.80` of the judge context minus `PrefixObsReserveTokens = 8_000`, resolved via `llm.llm_resolve` | `main.nim:57-60`, `main.nim:404-412` |
| prefix skills allowlist | `["niffler-tools","niffler-fabric","niffler-harness"]`, bundled source only | `main.nim:50-56`, source check `main.nim:296-322` |
| observability level | `NIF_LOG_LEVEL` (default `info`) gates the judgment audit line | `sdk/niffler/sdk.nim:492-509`; the audit call is `info` (`main.nim:591-594`) |

- Prefix content is **adaptive, not static**: `expertPolicy` (`main.nim:80-153`) + loaded bundled skills (fallback `expertFallbackKnowledge`, `main.nim:155-173`) + the *observed session's* frozen direct set and allowlist from `core.prompt_preview` (`main.nim:266-294`) + on-demand hints from `core.discover` filtered by that allowlist (`main.nim:324-357`); versioned `"md5:<prefix>"` (`main.nim:442`) and rebuilt at `expert_reload` or at a turn start when exposure first appears (`main.nim:444-462`, `main.nim:731-733`).
- **Store kinds: none.** The expert writes no store records (no `store*` call in `main.nim`); all follow state is in-process (`main.nim:220-241`) and is lost on restart or `core.kill`.
- **How advice reaches the transcript**: accepted payload → `ct.adviseStream.queue` (`core/dispatch.nim:1159-1160`) → `drainAdvisories` builds `{"role":"user","content":"[Niffler advisor: expert] …"}` and `ctxAppend`s it (`core/conversation.nim:991-1003`) → persisted as kind `message`, id `<convId>:<seq>` with `conversationId`/`createdAt` (`core/conversation.nim:248-286`) → `ev.session.advice {sessionId, turnId, source, content, reason}` published at `core/conversation.nim:2703` (payload built at `core/conversation.nim:999-1001`).
- Judgment audit: every parsed judgment logs `ev.log.expert` with `{action, reason, message, confidence}` — silence reasons included (`main.nim:588-594`); token accounting per follow and lifetime (`main.nim:570-578`, `main.nim:903-906` / `921-924`).
- Bench-only: `bench/config.json:170` `expertJudge` (bench/README.md:231) is a benchmark harness knob, not a harness configuration.

## 4. MANUAL placement

Existing coverage is correct and in the right place — extend, don't move:

- `docs/MANUAL.md:2107` `## Expert advisory peer (`expert`)` (TOC `docs/MANUAL.md:27`); cross-references already exist: `:36` (component sources), `:69` (shipped-components table, "optional"), `:387-388` (advise subject in "The bus in one screen"; `docs/WIRE.md:82`), `:460` (approvals list, `expert_follow`), `:1476` ("Shipped policy" → on-demand orchestration).
- What the section already does well: tools table with lifetimes (`:2128-2131`), the `[Niffler advisor: expert]` marker + `ev.session.advice` (`:2121-2123`), stale-turn/no-active-turn rejection (`:2117-2120`), and design invariants (`:2133-2137`).
- **Proposed** (keep `## Expert advisory peer (`expert`)` at `:2107`): add `### Configuration` after the tools table (`:2132`) carrying §3's table — chief line "the component reads no environment variables; its knobs are compile-time constants in `components/expert/main.nim` and per-follow `model`/`provider` args", plus default-judge resolution via `llm`/`provider`; add `### Arming it` (discover-only tools → `discover`+`invoke`, or `./var/bin/cli call expert_follow '{"session_id":"conv-…"}'`; inert until then) and `### Verification` (the shape other component sections use): `expert_status`, `ev.log.expert`, `./var/bin/console`/`observe` for `ev.session.advice`.
- **Point, don't duplicate**: `docs/research/EXPERT.md` owns the design and the judge internals — §1 boundary/goals, §2 knowledge prefix, §3 observation contract, §4 best-effort scheduling, §5 LLM judgment contract, §6 turn-bound advice, §7 component surface, §8 cost and observability, §9 known sharp edges, §10 build history (`docs/research/EXPERT.md:46,85,142,216,256,326,380,421,448,484`). MANUAL should cite those section numbers instead of restating the policy prompt (it currently doesn't restate it — keep it that way) and keep MANUAL's own voice for operator-facing how-to (arming, knobs, what you observe, troubleshooting).

## 5. DELTA list

1. **No published economics numbers.** MANUAL `:2133-2136` says "cooldown, latest-state coalescing" without values; add `MaxJudgmentsPerTurn = 2`, `EvalCooldownMs = 8_000`, `MaxActivities = 8`, `MaxField = 400`, `MaxReasoningTail = 2000`, `MaxMessage = 1200` — `components/expert/main.nim:33-41`.
2. **Cost knobs missing.** `JudgeMaxOutputTokens = 1536`, `JudgeReasoningEffort = "low"`, `ChatTimeoutMs = 120_000` — `main.nim:42-51`; note they are compile-time (a rebuild to change), and that the cap is best-effort (`main.nim:43-48`).
3. **Prefix budget unexplained.** "fixed cache-stable knowledge prefix" (`docs/MANUAL.md:2111`) should name the 80 % fill / 8 k reserve and `llm.llm_resolve` sizing — `main.nim:57-60`, `main.nim:404-412`.
4. **Prefix composition unstated.** Policy + the three bundled-only skills + the observed session's frozen exposure/allowlist (`core.prompt_preview`) + `discover` hints — `main.nim:266-357`, `main.nim:386-443`; skills trust boundary at `main.nim:50-56`/`296-322`.
5. **"No env vars" not stated.** The env table (`docs/MANUAL.md:261`) rightly has no expert row, but a reader looks for one; say so explicitly, and name `NIF_LOG_LEVEL` (`sdk/niffler/sdk.nim:492-509`) as the only env var that changes what you can see.
6. **Judge model selection undocumented.** Default judge = `llm`'s default model/provider; `expert_follow {model, provider}` overrides per follow and keeps judge cost off the worker's model (`main.nim:808-813`, `main.nim:551-553`, `components/llm/main.go:227`, `components/provider/main.go:123-125`).
7. **Runner-side limits absent.** One advisory per turn (`advisory-limit`) and identical-content rejection (`duplicate`) plus the full reason set — `core/dispatch.nim:1144-1160`; MANUAL `:2117-2120` lists only stale-turn/no-active-turn.
8. **Delivery gates underspecified.** High confidence, ≤1200-char message, non-empty `tools`, each tool normalized (backticks, `component.tool`) and present in the session's visible sets, tool textually named in the message, and ≥1 named tool not already used this turn (anti-repeat) — `main.nim:605-664` (cap 605-608, tool normalization 614-623, visibility 630-634, message-contains 636-641, anti-repeat 644-664).
9. **No store kinds / no durability stated.** All follow state is in-memory and dies with the process (`main.nim:220-241`); the only durable artifact is the folded `message` record (`core/conversation.nim:248-286`, `:991-1003`) — worth one line under Configuration.
10. **Observation triggers unlisted.** toolcall start/done, turn start/done, assistant text, token reasoning tail, and the context-pressure trigger at ≥80 % (`main.nim:709-793`); turn done clears the frame so advice can never cross turns (`main.nim:735-738`).
11. **Audit trail unmentioned.** `ev.log.expert` judgment lines with silence reasons (`main.nim:588-594`) — the operator's way to answer "why was it silent?".
12. **`expert_status` fields truncated.** MANUAL `:2131` lists counters but not `knowledgeVersion`, `liveTools`, `skills`, `prefixChars`, `prefixBudgetTokens`, `tokens{prompt,cached,completion}` — `main.nim:874-925` (frame/counters 883-906, aggregate 908-925).
13. **Only `expert_follow` appears in "Shipped policy".** `docs/MANUAL.md:1476` should say the whole `expert_*` set is on demand (`main.nim:832,851,871,925`).
14. **Arming is never shown.** Because all four tools are discover-only, the model cannot call them directly; MANUAL should give the operator path (`discover` + `invoke`, or `./var/bin/cli call expert_follow '{"session_id":"conv-…"}'` — cli usage `docs/MANUAL.md` "cli") and repeat that the component stays inert otherwise (`main.nim:37`).
15. **Manifest status not stated.** `optional` in the shipped table (`docs/MANUAL.md:69`) but actually autostarted (up to the boot profile), `restart: on-failure` — `manifest.yaml:230-234`.
16. **Tool docs are thin.** Only `expert_follow` documents its params; `expert_unfollow`/`expert_reload`/`expert_status` have no `- param:` lines (`main.nim:837-841`, `856-862`, `876-880`) — a MANUAL-side gap only in the sense that MANUAL must carry the `session_id` semantics.
17. **`ev.session.advice` payload documented incompletely.** MANUAL `:391` omits the `reason` field that the runner publishes (`core/conversation.nim:999-1001`).
18. **Research-doc pointer is generic.** `docs/MANUAL.md:2109-2110` cites `research/EXPERT.md` wholesale; point at §2/§4/§5/§6/§8 for design internals so the MANUAL stops being read as the spec.
19. **Bench config is not user configuration.** `bench/config.json:170` `expertJudge` (bench/README.md:231) — one "benchmark-only" note, or nothing at all in MANUAL.
20. **WIRE.md has only the advise subject** (`docs/WIRE.md:82`); the advice payload shape (`kind: "advisor"`, `source`, `knowledgeVersion`) is documented nowhere outside the source (`main.nim:476-486`) — a candidate one-liner in WIRE.md's advise entry rather than a MANUAL block.

## 6. Not user-facing (report only)

- No UI surface for advice: `grep -rn 'advisor|advice' ui/frontend/src` returns **zero** hits, so `ev.session.advice` is not rendered by the SPA; the human sees advice only as the folded transcript message (and in logs/`console`/`observe`). MANUAL should tell the reader where to look rather than implying a UI affordance.
- The advise subject is an internal component→runner contract (`main.nim:475-499`, `core/dispatch.nim:1113`); it is not a tool, not callable from the catalog, and needs no operator documentation beyond "the runner accepts it only for the live turn".
- The four tools being discover-only means the *operator* interaction with this component is arming (`expert_follow`) and reading (`expert_status`, `ev.log.expert`); nothing in the component is configured through the environment, files, or a registry.
