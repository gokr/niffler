# Worklist slice: Session runners

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A179 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 132-133 "The runner is a supervised child (restart policy `never`)"
- CODE: `core/conversation.nim:2864-2874` `ct.sup.addChild(rname, bin, rpNever, @[sessionId])`; `core/supervisor.nim:14-16` (`RestartPolicy = never | on-failure`), `:41-49` (`parsePolicy` falls back to **on-failure** for unknown strings)
- FIX: add one clause: a runner that dies is **not** restarted — the next session call re-ensures it, and `ensureRunner` also reaps a corpse mid-wait so the replacement is spawned immediately (`conversation.nim:2889-2896`).

## A180 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 135-137 "Sessions are ephemeral: history lives in the store, so a fresh runner resumes the conversation on the next call."
- CODE: `core/session.nim:149-158` (idle clock + `NIF_RUNNER_IDLE_S`, default 600), `:166-170` (break, `retiring after Ns idle`), `:206-208` (`reg.depart` + close); the clock is stamped at **turn end**, not message receipt (`session.nim:198-202`)
- FIX: add "A runner with no session call for `NIF_RUNNER_IDLE_S` (default 600 s) retires gracefully (`reg.depart`) and is re-created on the next call; the timer is stamped when a turn finishes, so a long turn is activity, not idleness." The env table (line 347) states the timeout but no section explains the mechanism.

## A182 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (missing-binary failure)
- CODE: `core/conversation.nim:2869-2872` raises "session runner binary missing: … — run `make build`"
- FIX: add one Troubleshooting row: "session call fails with 'session runner binary missing' | `var/bin/session` was never built — `make build`".

## A183 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (the runner's other subjects)
- CODE: `core/session.nim:73-135` — besides `.call` (queue-subscribed at `:75`), the runner serves `svc.session.<id>.steer` (mid-turn steering), `.map` (repo-map auto-append), `.advise` (expert peer, answered from the idle slot), `.tool` (nested session-call proxy)
- FIX: add one sentence: "A runner serves four extra per-conversation subjects besides `.call` — `.steer`, `.tool`, `.advise` and `.map`; each carries the same session id, and their payloads are specified in docs/WIRE.md."

