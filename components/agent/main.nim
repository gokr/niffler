## agent component — subagent sessions (fabric Phase 1, docs/research/FABRIC.md).
##
## A subagent is a Niffler session like any other: its own runner process,
## resumed from the store, full toolset. This component is the thin surface
## the LLM drives:
## - agent_run: prepare a child runner (session_prepare — never core's
##   session tool, which stashes mid-turn), record lineage in the store,
##   run the child turn synchronously, return its final reply. Lineage
##   persistence and reads fail closed (no store, no spawning); child LLM
##   failures are reported as failures; approvals inside the child route to
##   the original interactive caller, not to this component. Idle child
##   runners retire themselves (NIF_RUNNER_IDLE_S, core/session.nim) and are
##   re-ensured on demand.
##
## Depth rule: a session spawned as a child (sessionmeta.parent set) cannot
## spawn children itself — recursion stops at one level. With no reachable
## human, approvals are denied (never silently approved).

import std/[json, os]
import natswrapper
import niffler/sdk

let comp = newComponent("agent", "0.1.0")

const taskPreamble =
  "You are a subagent. Work autonomously on the task below using the " &
  "available tools. When done, report a concise final result — it is the " &
  "only thing the caller sees.\n\nTask:\n"

proc hasParent(sessionId: string): bool =
  ## True when the session was itself spawned as a subagent child. Raises
  ## when the lineage store is unreachable — callers must fail closed.
  ## A session with no lineage record arrives as a not-found RESULT, not
  ## an error, so root sessions are unaffected.
  let meta = comp.request("store", "get",
    %*{"kind": "sessionmeta", "id": sessionId}, 10_000)
  return meta{"value"}{"parent"}.getStr("").len > 0

# low-level registration: the handler needs the raw __session injection
let runSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "Self-contained task for the subagent. It starts with a fresh context — include everything it needs (paths, goals, constraints), not a continuation of this conversation."},
  "model": {"type": "string",
            "description": "Optional model override for the subagent (e.g. a cheaper model for mechanical work)"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting for the subagent after this many ms (default 600000)"}
}, required = @["task"],
   description = "Run a task in a fresh subagent session (its own context, own tool loop) and return only its final reply. Use when a subtask needs exploratory judgment per step — search, debugging, reading code — and its intermediate work must not enter this conversation. For mechanical, well-understood sequences (fan-out, big data, known shape) prefer the fabric tool instead. The subagent cannot spawn further subagents.")
runSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 900_000,
                            "sessionContext": true, "noSpawn": true}
discard comp.tool("agent_run", runSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_run needs a live session context")
    var isChild = false
    try:
      isChild = hasParent(parentSession)
    except CatchableError as e:
      return errResult("cannot verify subagent lineage (store unreachable): " &
                       e.msg)
    if isChild:
      return errResult("subagents cannot spawn subagents (depth limit)")
    let task = toolArgs{"task"}.getStr("")
    if task.len == 0:
      return errResult("agent_run needs task")
    let child = "agent-" & newId()
    # prepare the runner directly (core's session tool would stash mid-turn)
    var prep: JsonNode
    try:
      prep = comp.request("core", "session_prepare",
                          %*{"sessionId": child}, 60_000)
    except CatchableError as e:
      return errResult("session_prepare failed: " & e.msg)
    let subject = prep{"subject"}.getStr("")
    if subject.len == 0:
      return errResult("session_prepare returned no subject",
                       extra = %*{"detail": $prep})
    # lineage before the turn, fail closed: an unrecorded child would pass
    # its own depth guard and could spawn grandchildren
    try:
      discard comp.request("store", "put",
        %*{"kind": "sessionmeta", "id": child,
           "value": %*{"parent": parentSession}}, 10_000)
    except CatchableError as e:
      return errResult("cannot record subagent lineage (store unreachable): " &
                       e.msg, extra = %*{"sessionId": child})
    var sessArgs = %*{"sessionId": child, "content": taskPreamble & task}
    # Subagent conversations get the same pluggable constitution as normal
    # ones: fetch the systemprompt component's prompt (best effort — the
    # runner's own fallback already covers a missing component) and set it
    # as the child's system message before the first turn. Frozen per
    # conversation like every other session.
    try:
      let sp = comp.request("systemprompt", "systemprompt",
        %*{"cwd": getEnv("NIF_ROOT", getCurrentDir()), "sessionId": child},
        5_000)
      let prompt = sp{"systemPrompt"}.getStr("")
      if prompt.len > 0:
        sessArgs["systemPrompt"] = %prompt
    except CatchableError:
      discard
    let model = toolArgs{"model"}.getStr("")
    if model.len > 0:
      sessArgs["model"] = %model
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(600_000)
    # approvals inside the child route to the original interactive caller
    # (injected as private context by the dispatch gate), not to this
    # component — which is blocked in this handler and could not answer
    let originalCaller = toolArgs{"__session"}{"caller"}.getStr("agent")
    let env = callEnvelope("session", sessArgs, originalCaller)
    let resp = comp.requestEnvelope(subject, env, timeoutMs)
    if resp.kind == ekError:
      return errResult(resp.error{"message"}.getStr("subagent failed"),
                       extra = %*{"sessionId": child})
    # a child whose LLM failed reports failure, not a text reply
    let turnError = resp.args{"turnError"}.getStr("")
    if turnError.len > 0:
      return errResult(turnError, extra = %*{"sessionId": child})
    return okResult(%*{"sessionId": child,
                       "reply": resp.args{"reply"}.getStr(""),
                       "model": resp.args{"modelOverride"}.getStr("")}))

comp.run()
