## agent component — subagent sessions (fabric Phase 1, docs/research/FABRIC.md).
##
## A subagent is a Niffler session like any other: its own runner process,
## resumed from the store, full toolset. This component is the thin surface
## the LLM drives:
## - agent_run: prepare a child runner (session_prepare — never core's
##   session tool, which stashes mid-turn), record lineage in the store,
##   run the child turn synchronously, return its final reply.
## - agent_steer: fire-and-forget mid-turn message injection into any
##   session (the runner's drainSteer consumes it between LLM rounds).
##
## Depth rule: a session spawned as a child (sessionmeta.parent set) cannot
## spawn children itself — recursion stops at one level. Approvals inside
## the child route to the driving client via the caller field; with no
## reachable human they are denied (never silently approved).

import std/[json, os]
import natswrapper
import niffler/sdk

let comp = newComponent("agent", "0.1.0")

const taskPreamble =
  "You are a subagent. Work autonomously on the task below using the " &
  "available tools. When done, report a concise final result — it is the " &
  "only thing the caller sees.\n\nTask:\n"

proc hasParent(sessionId: string): bool =
  ## True when the session was itself spawned as a subagent child.
  try:
    let meta = comp.request("store", "get",
      %*{"kind": "sessionmeta", "id": sessionId}, 10_000)
    return meta{"value"}{"parent"}.getStr("").len > 0
  except CatchableError:
    return false

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
    if hasParent(parentSession):
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
    # lineage before the turn, so a nested agent_run inside the child is
    # denied by hasParent
    try:
      discard comp.request("store", "put",
        %*{"kind": "sessionmeta", "id": child,
           "value": %*{"parent": parentSession}}, 10_000)
    except CatchableError:
      discard  # lineage is a guard, not a hard requirement
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
    let env = callEnvelope("session", sessArgs, "agent")
    let resp = comp.requestEnvelope(subject, env, timeoutMs)
    if resp.kind == ekError:
      return errResult(resp.error{"message"}.getStr("subagent failed"),
                       extra = %*{"sessionId": child})
    return okResult(%*{"sessionId": child,
                       "reply": resp.args{"reply"}.getStr(""),
                       "model": resp.args{"modelOverride"}.getStr("")}))

comp.tool:
  proc agent_steer(session_id: string, message: string): JsonNode =
    ## Inject a message into a RUNNING subagent turn (folded in between LLM
    ## rounds). Fire-and-forget: success means published, not processed.
    ## - session_id: The subagent session id returned by agent_run
    ## - message: The steering message for the running turn
    comp.emit(sessionSteerSubject(session_id), %*{"content": message})
    return okResult(%*{"published": true})

comp.run()
