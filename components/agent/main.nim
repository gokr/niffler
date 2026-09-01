## agent component — subagent sessions (docs/research/FABRIC.md).
##
## A subagent is a Niffler session like any other: its own runner process,
## resumed from the store, full toolset. This component is the thin surface
## the LLM drives:
##
## - agent_run: synchronous — prepare a child runner (session_prepare —
##   never core's session tool, which stashes mid-turn), record lineage,
##   run the child turn, return its final reply.
## - agent_spawn: background — same preparation, then the child turn is
##   published fire-and-forget with a reply inbox this component taps; the
##   handler returns {jobId, sessionId} immediately. The tap records the
##   terminal job state in the store (kind agentjob) and emits
##   ev.agent.done — so late status lookups and waits never miss it.
## - agent_status: non-blocking durable lookup.
## - agent_wait: poll the durable record until terminal (for workflows
##   that need the result; blocks this component's pump, like agent_run).
## - agent_stop: mark a running job "stopping"; the terminal record says
##   "stopped" when the child turn ends (the process itself is not killed —
##   kill-on-timeout still bounds a runaway turn).
## - agent_steer: fire-and-forget injection into a live child turn
##   (meaningful only for spawned jobs — agent_run blocks the caller).
##
## Depth rule: a session spawned as a child (sessionmeta.parent set) cannot
## spawn children itself. Lineage persistence and reads fail closed. Child
## LLM failures are reported as failures; approvals inside a child route to
## the original interactive caller. Idle child runners retire themselves
## (NIF_RUNNER_IDLE_S) and re-ensure on demand.

import std/[json, os, strutils, tables, times]
import natswrapper
import niffler/sdk

let comp = newComponent("agent", "0.1.0")

const taskPreamble =
  "You are a subagent. Work autonomously on the task below using the " &
  "available tools. When done, report a concise final result — it is the " &
  "only thing the caller sees.\n\nTask:\n"

proc sanitizeSessionId(s: string): string =
  ## Mirror of the runner's subject sanitization (core/conversation.nim):
  ## session ids become NATS subject tokens, keep alnum/-/_.
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '-')

proc hasParent(sessionId: string): bool =
  ## True when the session was itself spawned as a subagent child. Raises
  ## when the lineage store is unreachable — callers must fail closed.
  ## A session with no lineage record arrives as a not-found RESULT, not
  ## an error, so root sessions are unaffected.
  let meta = comp.request("store", "get",
    %*{"kind": "sessionmeta", "id": sessionId}, 10_000)
  return meta{"value"}{"parent"}.getStr("").len > 0

proc prepareChild(parentSession, task, model: string): tuple[
    ok: bool, error: string, subject: string, child: string] =
  ## Depth-guarded child-runner preparation + fail-closed lineage.
  var isChild = false
  try:
    isChild = hasParent(parentSession)
  except CatchableError as e:
    return (false, "cannot verify subagent lineage (store unreachable): " &
                    e.msg, "", "")
  if isChild:
    return (false, "subagents cannot spawn subagents (depth limit)", "", "")
  let child = "agent-" & newId()
  # prepare the runner directly (core's session tool would stash mid-turn)
  var prep: JsonNode
  try:
    prep = comp.request("core", "session_prepare",
                        %*{"sessionId": child}, 60_000)
  except CatchableError as e:
    return (false, "session_prepare failed: " & e.msg, "", "")
  let subject = prep{"subject"}.getStr("")
  if subject.len == 0:
    return (false, "session_prepare returned no subject", "", "")
  # lineage before the turn, fail closed: an unrecorded child would pass
  # its own depth guard and could spawn grandchildren
  try:
    discard comp.request("store", "put",
      %*{"kind": "sessionmeta", "id": child,
         "value": %*{"parent": parentSession}}, 10_000)
  except CatchableError as e:
    return (false, "cannot record subagent lineage (store unreachable): " &
                    e.msg, "", "")
  result = (true, "", subject, child)

proc childSessArgs(child, task, model: string): JsonNode =
  ## The child session call: task preamble, optional model override, and
  ## the conversation's pluggable constitution (systemprompt component,
  ## best effort — the runner's own fallback covers a missing component).
  result = %*{"sessionId": child, "content": taskPreamble & task}
  try:
    let sp = comp.request("systemprompt", "systemprompt",
      %*{"cwd": getEnv("NIF_ROOT", getCurrentDir()), "sessionId": child},
      5_000)
    let prompt = sp{"systemPrompt"}.getStr("")
    if prompt.len > 0:
      result["systemPrompt"] = %prompt
  except CatchableError:
    discard
  if model.len > 0:
    result["model"] = %model

proc originalCaller(toolArgs: JsonNode): string =
  ## Approvals inside the child route to the original interactive caller
  ## (injected as private context by the dispatch gate), not to this
  ## component — which may be blocked in a handler and could not answer.
  toolArgs{"__session"}{"caller"}.getStr("agent")

# low-level registration: the handler needs the raw __session injection
let runSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "Self-contained task for the subagent. It starts with a fresh context — include everything it needs (paths, goals, constraints), not a continuation of this conversation."},
  "model": {"type": "string",
            "description": "Optional model override for the subagent (e.g. a cheaper model for mechanical work)"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting for the subagent after this many ms (default 600000)"}
}, required = @["task"],
   description = "Run a task in a fresh subagent session (its own context, own tool loop) and return only its final reply. Use when a subtask needs exploratory judgment per step — search, debugging, reading code — and its intermediate work must not enter this conversation. For mechanical, well-understood sequences (fan-out, big data, known shape) prefer the fabric tool instead. For background work use agent_spawn instead. The subagent cannot spawn further subagents.")
runSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 900_000,
                            "sessionContext": true, "noSpawn": true}
discard comp.tool("agent_run", runSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_run needs a live session context")
    let task = toolArgs{"task"}.getStr("")
    if task.len == 0:
      return errResult("agent_run needs task")
    let prep = prepareChild(parentSession, task,
                            toolArgs{"model"}.getStr(""))
    if not prep.ok:
      return errResult(prep.error)
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(600_000)
    let env = callEnvelope("session",
      childSessArgs(prep.child, task, toolArgs{"model"}.getStr("")),
      originalCaller(toolArgs))
    let resp = comp.requestEnvelope(prep.subject, env, timeoutMs)
    if resp.kind == ekError:
      return errResult(resp.error{"message"}.getStr("subagent failed"),
                       extra = %*{"sessionId": prep.child})
    # a child whose LLM failed reports failure, not a text reply
    let turnError = resp.args{"turnError"}.getStr("")
    if turnError.len > 0:
      return errResult(turnError, extra = %*{"sessionId": prep.child})
    return okResult(%*{"sessionId": prep.child,
                       "reply": resp.args{"reply"}.getStr(""),
                       "model": resp.args{"modelOverride"}.getStr("")}))

let spawnSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "Self-contained task for the subagent (same contract as agent_run)"},
  "model": {"type": "string",
            "description": "Optional model override for the subagent"}
}, required = @["task"],
   description = "Start a subagent task in the BACKGROUND and return {jobId, sessionId} immediately. The job runs autonomously; agent_status checks it without blocking, agent_wait blocks until it finishes, agent_steer injects a message into the live turn, agent_stop marks it for stopping. Terminal state (done/failed/stopped) is durable and announced as ev.agent.done, so a late wait cannot miss it. Use agent_run instead when you need the result right away. The subagent cannot spawn further subagents.")
spawnSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 60_000,
                              "sessionContext": true, "noSpawn": true}
discard comp.tool("agent_spawn", spawnSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_spawn needs a live session context")
    let task = toolArgs{"task"}.getStr("")
    if task.len == 0:
      return errResult("agent_spawn needs task")
    let prep = prepareChild(parentSession, task,
                            toolArgs{"model"}.getStr(""))
    if not prep.ok:
      return errResult(prep.error)
    let jobId = "job-" & newId()
    # durable record BEFORE the fire-and-forget publish, so a completion
    # that races the spawn cannot arrive at an unknown job
    try:
      discard comp.request("store", "put",
        %*{"kind": "agentjob", "id": jobId,
           "value": %*{"sessionId": prep.child, "parent": parentSession,
                       "status": "running",
                       "task": task[0 ..< min(task.len, 200)],
                       "startedAt": epochTime()}}, 10_000)
    except CatchableError as e:
      return errResult("cannot record job (store unreachable): " & e.msg,
                       extra = %*{"sessionId": prep.child})
    let env = callEnvelope("session",
      childSessArgs(prep.child, task, toolArgs{"model"}.getStr("")),
      originalCaller(toolArgs))
    let data = env.encode()
    let inbox = "_INBOX.agentjob." & jobId
    let st = natsConnection_PublishRequest(c.nc.conn, prep.subject.cstring,
      inbox.cstring, data.cstring, data.len.cint)
    if not checkStatus(st):
      discard c.request("store", "put",
        %*{"kind": "agentjob", "id": jobId,
           "value": %*{"sessionId": prep.child, "parent": parentSession,
                       "status": "failed",
                       "error": "publish failed: " & getErrorString(st)}},
        10_000)
      return errResult("could not start the job: " & getErrorString(st),
                       extra = %*{"jobId": jobId,
                                  "sessionId": prep.child})
    return okResult(%*{"jobId": jobId, "sessionId": prep.child,
                       "steer": "svc.session." &
                                sanitizeSessionId(prep.child) & ".steer"}))

let statusSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Non-blocking lookup of a background subagent job: returns its durable status (running/done/failed/stopped/stopping), session id, and — when terminal — the final reply or error. Does not wait; use agent_wait for that.")
discard comp.tool("agent_status", statusSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_status needs jobId")
    try:
      let job = c.request("store", "get",
        %*{"kind": "agentjob", "id": jobId}, 10_000)
      if job{"ok"}.getBool(false):
        return okResult(job{"value"})
      return errResult("unknown job '" & jobId & "'", code = "not-found")
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

let waitSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting after this many ms (default 600000)"}
}, required = @["jobId"],
   description = "Block until a background subagent job reaches a terminal state (done/failed/stopped) and return its durable result — including for jobs that finished long ago (late waits read the store). Terminal states carry the child's final reply, or the failure reason for failed jobs.")
waitSchema["x-harness"] = %*{"timeoutMs": 900_000}
discard comp.tool("agent_wait", waitSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_wait needs jobId")
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(600_000)
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while true:
      # the completion tap shares this serialized pump: without pumping it
      # here, a reply arriving during the wait would sit queued forever
      discard c.pumpTaps(100)
      var job: JsonNode
      try:
        job = c.request("store", "get",
          %*{"kind": "agentjob", "id": jobId}, 10_000)
      except CatchableError as e:
        return errResult("cannot read job (store unreachable): " & e.msg)
      if not job{"ok"}.getBool(false):
        return errResult("unknown job '" & jobId & "'", code = "not-found")
      let value = job{"value"}
      let status = value{"status"}.getStr("running")
      if status != "running":
        return okResult(value)
      if epochTime() >= deadline:
        return errResult("job '" & jobId & "' still running after " &
          $timeoutMs & "ms — poll agent_status instead of waiting again",
          code = "timeout", extra = %*{"jobId": jobId, "status": status})
      sleep(250))

let stopSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Mark a running background subagent job for stopping. The child turn is not killed outright — it ends when the model finishes or the turn times out, and the job's terminal record then says \"stopped\" (the reply, if any, is kept). Re-calling is harmless.")
discard comp.tool("agent_stop", stopSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_stop needs jobId")
    try:
      let job = c.request("store", "get",
        %*{"kind": "agentjob", "id": jobId}, 10_000)
      if not job{"ok"}.getBool(false):
        return errResult("unknown job '" & jobId & "'", code = "not-found")
      let value = job{"value"}
      let status = value{"status"}.getStr("running")
      if status != "running":
        return okResult(value)
      value["status"] = %"stopping"
      discard c.request("store", "put",
        %*{"kind": "agentjob", "id": jobId, "value": value}, 10_000)
      return okResult(%*{"status": "stopping", "sessionId":
                          value{"sessionId"}.getStr("")})
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

comp.tool:
  proc agent_steer(session_id: string, message: string): JsonNode =
    ## Inject a message into a RUNNING background subagent turn (folded in
    ## between LLM rounds). Fire-and-forget: success means published, not
    ## processed. Only meaningful for agent_spawn jobs — agent_run blocks
    ## its caller until the child is done.
    ## - session_id: The child session id returned by agent_spawn
    ## - message: The steering message for the running turn
    if session_id.len == 0 or message.len == 0:
      return errResult("agent_steer needs session_id and message")
    comp.emit("svc.session." & sanitizeSessionId(session_id) & ".steer",
              %*{"content": message})
    return okResult(%*{"published": true})

# Terminal job recording: the runner replies on the job's reply inbox; this
# tap is the single writer of the terminal state, so status lookups and
# waits see the same durable record no matter when they run.
discard comp.tap("_INBOX.agentjob.>",
  proc(c: Component, subject: string, data: string) =
    let parts = subject.split('.')
    if parts.len < 3: return
    let jobId = parts[2]
    let r = decode(data)
    if r.kind != ekResult: return
    var status = "done"
    let turnError = r.args{"turnError"}.getStr("")
    if turnError.len > 0: status = "failed"
    var value = %*{"sessionId": r.args{"sessionId"}.getStr(""),
                   "status": status,
                   "endedAt": epochTime()}
    if turnError.len > 0:
      value["error"] = %turnError
    else:
      value["reply"] = %r.args{"reply"}.getStr("")
    try:
      # preserve spawn-time fields and honor a stop request
      let job = c.request("store", "get",
        %*{"kind": "agentjob", "id": jobId}, 10_000)
      if job{"ok"}.getBool(false):
        let prior = job{"value"}
        value["parent"] = prior{"parent"}
        value["task"] = prior{"task"}
        value["startedAt"] = prior{"startedAt"}
        if prior{"status"}.getStr("") == "stopping" and status == "done":
          value["status"] = %"stopped"
      discard c.request("store", "put",
        %*{"kind": "agentjob", "id": jobId, "value": value}, 10_000)
    except CatchableError:
      discard  # the durable record stays "running"; status reports it
    c.emit("ev.agent.done", %*{"jobId": jobId,
                                "sessionId": value{"sessionId"},
                                "status": value{"status"}}))

comp.run()
