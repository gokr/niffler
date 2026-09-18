# Worklist slice: Expert advisory peer (expert)

From `worklist.tsv` (5 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A087 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2111-2119 ("armed explicitly with `expert_follow {session_id}` (approval-gated, off by default) … only high-confidence steers naming live, non-hidden tools are delivered, through `svc.session.<id>.advise` … late advice is rejected (`stale-turn`/`no-active-turn`), never queued")
- CODE: `components/expert/main.nim:799-834` (`expert_follow`, `comp.tools[^1].schema["x-harness"]` assigned after registration at `:831`), `:37` ("inert until expert_follow names a target session"), `:801,818` (`provider` parameter) — the advise rejection codes are literal in `core/dispatch.nim:1147` (`no-active-turn`) and `:1151` (`stale-turn`)
- FIX: none.

## A088 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2123-2129 tool table (4 tools incl. `expert_unfollow`, `expert_reload`, `expert_status`)
- CODE: exactly four (`components/expert/main.nim:800,835,854,874`), all onDemand (`:851,871,925`) ✔
- FIX: none.

## A089 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2133 "Accepted advice is folded as a marked user message (`[Niffler advisor: expert] ...`), persisted, and announced on `ev.session.advice`"
- CODE: exact — the fold inserts `"[Niffler advisor: " & source & "] " & content` as a `user` message and emits `advice` with `source`/`reason` (`core/conversation.nim:993-1004`; `source` defaults to `"advisor"`, the component sends `"expert"`)
- FIX: none.

## A313 (doc-edit)
source: `components/expert.md`

- MANUAL: **No published economics numbers.** MANUAL `:2133-2136` says "cooldown, latest-state coalescing" without values; add `MaxJudgmentsPerTurn = 2`, `EvalCooldownMs = 8_000`, `MaxActivities = 8`, `MaxField = 400`, `MaxReasoningTail = 2000`, `MaxMessage = 1200` — `components/expert/main.nim:33-41`.

## A330 (doc-edit)
source: `components/expert.md`

- MANUAL: **Research-doc pointer is generic.** `docs/MANUAL.md:2109-2110` cites `research/EXPERT.md` wholesale; point at §2/§4/§5/§6/§8 for design internals so the MANUAL stops being read as the spec.

