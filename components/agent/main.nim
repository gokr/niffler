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
## - agent_stop: cancel a running job for real — publish llm.cancel.<child>
##   (aborts an in-flight streaming LLM request) and the runner's
##   svc.session.<child>.cancel channel (ends the turn between rounds).
##   The terminal record says "stopped" (the reply, if any, is kept).
## - agent_steer: fire-and-forget injection into a live child turn
##   (meaningful only for spawned jobs — agent_run blocks the caller).
##
## Restart recovery: non-terminal job records are reconciled lazily — on
## boot and on every status/wait — against the live catalog and the child
## transcript: a completed turn whose completion tap was missed synthesizes
## the terminal record from the transcript; a turn whose runner died is
## recorded as interrupted.
##
## Depth rule: a session spawned as a child (sessionmeta.parent set) cannot
## spawn children itself. Lineage persistence and reads fail closed. Child
## LLM failures are reported as failures; approvals inside a child route to
## the original interactive caller. Idle child runners retire themselves
## (NIF_RUNNER_IDLE_S) and re-ensure on demand.

import std/[json, os, sets, strutils, tables, times]
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

proc publishCancel(c: Component, child: string) =
  ## Two-channel turn cancellation: the llm side-channel aborts an in-flight
  ## streaming request; a __cancel control message on the proven steer
  ## channel ends the turn between rounds (the runner's pumpSteer raises the
  ## flag runTurn checks before the next LLM round — riding the steer
  ## subscription rather than a dedicated one keeps the connection's pump
  ## surface unchanged).
  c.emit("llm.cancel." & sanitizeSessionId(child), %*{"sessionId": child})
  c.emit("svc.session." & sanitizeSessionId(child) & ".steer",
         %*{"__cancel": true})

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

proc childSessArgs(child, task, model, thinking: string,
                   toolArgs: JsonNode = nil): JsonNode =
  ## The child session call: task preamble, optional model override and
  ## reasoning effort, optional tool allowlist and round budget (frozen
  ## per-session controls enforced by core), and the conversation's
  ## pluggable constitution (systemprompt component, best effort — the
  ## runner's own fallback covers a missing component).
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
  if thinking.len > 0:
    result["thinking"] = %thinking
  if toolArgs != nil:
    # never embed a possibly-nil JsonNode in %* (SIGSEGVs at toUgly)
    if toolArgs{"tools"} != nil and toolArgs{"tools"}.kind == JArray:
      result["tools"] = toolArgs{"tools"}
    let mr = toolArgs{"maxRounds"}.getInt(0)
    if mr >= 1 and mr <= 20:
      result["maxRounds"] = %mr
    # per-job budgets (frozen per-session controls enforced by core): total
    # tool dispatches and cumulative tokens for the child's whole turn
    let mc = toolArgs{"maxCalls"}.getInt(0)
    if mc >= 1 and mc <= 500:
      result["maxCalls"] = %mc
    let mt = toolArgs{"maxTokens"}.getInt(0)
    if mt >= 1:
      result["maxTokens"] = %mt

proc originalCaller(toolArgs: JsonNode): string =
  ## Approvals inside the child route to the original interactive caller
  ## (injected as private context by the dispatch gate), not to this
  ## component — which may be blocked in a handler and could not answer.
  toolArgs{"__session"}{"caller"}.getStr("agent")

var stopArmed = initHashSet[string]()
  ## Jobs whose stop cancellation was already (re-)published. A stop request
  ## is re-armed exactly once per component incarnation — the first time a
  ## resolveStale sees the job stopping with its runner alive (the original
  ## publish may have been lost while this component was down). Re-arming on
  ## every status/wait poll would flood the child's cancel channel.

# --- restart recovery --------------------------------------------------------
# Non-terminal job records must not lie: after this component restarts (or a
# harness restart killed a child runner), status/wait resolve the record
# against the live catalog and the child transcript.

proc runnerAlive(sessionId: string): bool =
  ## Presence of the child's session runner in the live catalog. Any failure
  ## reads as absent: resolution prefers an honest terminal record over a
  ## job stuck "running" forever.
  try:
    let snap = comp.request("core", "catalog", %*{"op": "components"}, 10_000)
    let comps = snap{"components"}
    if comps == nil: return false
    return comps{"session-" & sanitizeSessionId(sessionId)} != nil
  except CatchableError:
    return false

proc lastTranscript(sessionId: string): tuple[role, content: string] =
  ## Last persisted message of the child conversation (best effort: any
  ## store failure returns empty, which reads as "no evidence").
  try:
    let lst = comp.request("store", "list",
      %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 1000},
      10_000)
    let items = lst{"items"}
    if items == nil: return ("", "")
    var last: JsonNode = nil
    for item in items:
      if item{"id"}.getStr("").startsWith(sessionId & ":"):
        last = item{"value"}
    if last != nil:
      return (last{"role"}.getStr(""), last{"content"}.getStr(""))
  except CatchableError:
    discard
  return ("", "")

proc resolveStale(jobId: string, value: JsonNode): JsonNode =
  ## Reconcile one non-terminal job record. Rules:
  ## - runner alive: the turn may still complete (the tap will catch it);
  ##   only re-publish a lost stop request for "stopping" jobs. No change.
  ## - runner gone + transcript ends with an assistant reply: the turn
  ##   completed while this component was down (completion tap missed) —
  ##   synthesize the terminal record from the transcript.
  ## - runner gone without a final reply: the turn died with the runner —
  ##   record it as interrupted (stopping jobs read "stopped", not failed).
  ## Returns the updated value, or nil when the record was left alone.
  let status = value{"status"}.getStr("running")
  if status != "running" and status != "stopping": return nil
  let child = value{"sessionId"}.getStr("")
  if child.len == 0: return nil
  if runnerAlive(child):
    if status == "running" and jobId notin stopArmed and
        value{"budgetMs"}.getInt(0) > 0 and
        (epochTime() - value{"startedAt"}.getFloat(0)) * 1000.0 >
            value{"budgetMs"}.getFloat(0):
      # Time budget exhausted (enforced lazily on observation): cancel the
      # turn with agent_stop semantics; the completion tap — or a later
      # poll after the child dies — terminalizes the record as "stopped".
      stopArmed.incl(jobId)
      value["status"] = %"stopping"
      try:
        discard comp.request("store", "put",
          %*{"kind": "agentjob", "id": jobId, "value": value}, 10_000)
      except CatchableError:
        return nil
      publishCancel(comp, child)
      return value
    if status == "stopping" and jobId notin stopArmed:
      # the original stop may have been lost while this component was down;
      # re-arm exactly once per incarnation (never per poll)
      stopArmed.incl(jobId)
      publishCancel(comp, child)
    return nil
  var updated = value
  let (role, content) = lastTranscript(child)
  if role == "assistant":
    updated["status"] = %(if status == "stopping": "stopped" else: "done")
    updated["reply"] = %content
  else:
    updated["status"] = %(if status == "stopping": "stopped" else: "failed")
    updated["error"] = %"interrupted — child runner gone before completion"
  updated["endedAt"] = %epochTime()
  try:
    discard comp.request("store", "put",
      %*{"kind": "agentjob", "id": jobId, "value": updated}, 10_000)
  except CatchableError:
    return nil  # cannot persist — leave the record alone rather than lie
  comp.emit("ev.agent.done", %*{"jobId": jobId,
                                "sessionId": updated{"sessionId"},
                                "status": updated{"status"}})
  return updated

proc reconcileAll() =
  ## Boot-time pass over every non-terminal job (best effort).
  try:
    let lst = comp.request("store", "list",
      %*{"kind": "agentjob", "limit": 1000}, 10_000)
    let items = lst{"items"}
    if items == nil: return
    for item in items:
      let jobId = item{"id"}.getStr("")
      if jobId.len == 0: continue
      discard resolveStale(jobId, item{"value"})
  except CatchableError:
    discard

# low-level registration: the handler needs the raw __session injection
let runSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "Self-contained task for the subagent. It starts with a fresh context — include everything it needs (paths, goals, constraints), not a continuation of this conversation."},
  "model": {"type": "string",
            "description": "Optional model override for the subagent (e.g. a cheaper model for mechanical work)"},
  "thinking": {"type": "string",
               "description": "Optional reasoning effort for the subagent (e.g. low/high; passed to the child's turns)"},
  "tools": {"type": "array",
            "description": "Optional tool allowlist for the subagent (frozen for the child conversation; it may dispatch only these tools)"},
  "maxRounds": {"type": "integer",
                "description": "Optional tool-round budget per child turn (1-20, default 20)"},
  "maxCalls": {"type": "integer",
               "description": "Optional total tool-dispatch budget for the child's turn (1-500); the turn ends as budget-exhausted once it is spent"},
  "maxTokens": {"type": "integer",
                "description": "Optional cumulative token budget for the child's turn (provider-reported tokens across LLM rounds); the turn ends as budget-exhausted once it is spent"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting for the subagent after this many ms (default 600000)"}
}, required = @["task"],
   description = "Run a task in a fresh subagent session (its own context, own tool loop) and return only its final reply. Use when a subtask needs exploratory judgment per step — search, debugging, reading code — and its intermediate work must not enter this conversation. For mechanical, well-understood sequences (fan-out, big data, known shape) prefer the fabric tool instead. For background work use agent_spawn instead. The subagent cannot spawn further subagents.")
runSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 900_000,
                            "sessionContext": true, "noSpawn": true,
                            "onDemand": true}
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
      childSessArgs(prep.child, task, toolArgs{"model"}.getStr(""),
                    toolArgs{"thinking"}.getStr(""), toolArgs),
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
            "description": "Optional model override for the subagent"},
  "thinking": {"type": "string",
               "description": "Optional reasoning effort for the subagent (e.g. low/high; passed to the child's turns)"},
  "tools": {"type": "array",
            "description": "Optional tool allowlist for the subagent (frozen for the child conversation; it may dispatch only these tools)"},
  "maxRounds": {"type": "integer",
                "description": "Optional tool-round budget per child turn (1-20, default 20)"},
  "maxCalls": {"type": "integer",
               "description": "Optional total tool-dispatch budget for the child's turn (1-500); the turn ends as budget-exhausted once it is spent"},
  "maxTokens": {"type": "integer",
                "description": "Optional cumulative token budget for the child's turn (provider-reported tokens across LLM rounds); the turn ends as budget-exhausted once it is spent"},
  "timeoutMs": {"type": "integer",
                "description": "Optional job budget in ms: once exceeded, the job is cancelled (agent_stop semantics) the next time it is observed via agent_status/agent_wait"}
}, required = @["task"],
   description = "Start a subagent task in the BACKGROUND and return {jobId, sessionId} immediately. The job runs autonomously; agent_status checks it without blocking, agent_wait blocks until it finishes, agent_steer injects a message into the live turn, agent_stop cancels it for real. Terminal state (done/failed/stopped) is durable and announced as ev.agent.done, so a late wait cannot miss it. Use agent_run instead when you need the result right away. The subagent cannot spawn further subagents.")
spawnSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 60_000,
                              "sessionContext": true, "noSpawn": true,
                              "onDemand": true}
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
    var record = %*{"sessionId": prep.child, "parent": parentSession,
                    "status": "running",
                    "task": task[0 ..< min(task.len, 200)],
                    "startedAt": epochTime()}
    let budgetMs = toolArgs{"timeoutMs"}.getInt(0)
    if budgetMs > 0:
      record["budgetMs"] = %budgetMs
    try:
      discard comp.request("store", "put",
        %*{"kind": "agentjob", "id": jobId, "value": record}, 10_000)
    except CatchableError as e:
      return errResult("cannot record job (store unreachable): " & e.msg,
                       extra = %*{"sessionId": prep.child})
    let env = callEnvelope("session",
      childSessArgs(prep.child, task, toolArgs{"model"}.getStr(""),
                    toolArgs{"thinking"}.getStr(""), toolArgs),
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
    comp.emit("ev.agent.started", %*{"jobId": jobId,
                                     "sessionId": prep.child,
                                     "parent": parentSession})
    return okResult(%*{"jobId": jobId, "sessionId": prep.child,
                       "steer": "svc.session." &
                                sanitizeSessionId(prep.child) & ".steer"}))

let statusSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Non-blocking lookup of a background subagent job: returns its durable status (running/done/failed/stopped/stopping), session id, and — when terminal — the final reply or error. Does not wait; use agent_wait for that.")
statusSchema["x-harness"] = %*{"onDemand": true}
discard comp.tool("agent_status", statusSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_status needs jobId")
    try:
      let job = c.request("store", "get",
        %*{"kind": "agentjob", "id": jobId}, 10_000)
      if job{"ok"}.getBool(false):
        var value = job{"value"}
        # lazy restart recovery: a non-terminal record is reconciled against
        # the live catalog and the child transcript before it is reported
        let resolved = resolveStale(jobId, value)
        if resolved != nil: value = resolved
        return okResult(value)
      return errResult("unknown job '" & jobId & "'", code = "not-found")
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

let waitSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting after this many ms (default 600000)"}
}, required = @["jobId"],
   description = "Block until a background subagent job reaches a terminal state (done/failed/stopped) and return its durable result — including for jobs that finished long ago (late waits read the store). Terminal states carry the child's final reply, or the failure reason for failed jobs.")
waitSchema["x-harness"] = %*{"timeoutMs": 900_000, "onDemand": true}
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
      var value = job{"value"}
      # lazy restart recovery: same reconciliation as agent_status, so a
      # wait on a stale record resolves it instead of blocking forever
      let resolved = resolveStale(jobId, value)
      if resolved != nil: value = resolved
      let status = value{"status"}.getStr("running")
      # "stopping" is NOT terminal: keep waiting until the completion tap
      # (or lazy recovery) lands done/failed/stopped
      if status != "running" and status != "stopping":
        return okResult(value)
      if epochTime() >= deadline:
        return errResult("job '" & jobId & "' still " & status & " after " &
          $timeoutMs & "ms — poll agent_status instead of waiting again",
          code = "timeout", extra = %*{"jobId": jobId, "status": status})
      sleep(250))

let stopSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Cancel a running background subagent job: aborts its in-flight LLM request and ends the child turn (between tool rounds, promptly after the current tool returns). The job's terminal record says \"stopped\" — the reply, if any, is kept. Re-calling is harmless; stopping an already-terminal job just returns the record.")
stopSchema["x-harness"] = %*{"onDemand": true}
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
      if status != "running" and status != "stopping":
        return okResult(value)
      if status != "stopping":
        value["status"] = %"stopping"
        discard c.request("store", "put",
          %*{"kind": "agentjob", "id": jobId, "value": value}, 10_000)
      let child = value{"sessionId"}.getStr("")
      if child.len > 0:
        publishCancel(c, child)
      return okResult(%*{"status": "stopping", "sessionId": child})
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

comp.tool(%*{"onDemand": true}):
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
      # preserve spawn-time fields and honor a stop request: any terminal
      # state while a stop was requested reads "stopped" — the turn may end
      # via llm.cancel (an error) or between rounds (clean), and the reply,
      # if one was produced, is kept either way
      let job = c.request("store", "get",
        %*{"kind": "agentjob", "id": jobId}, 10_000)
      if job{"ok"}.getBool(false):
        let prior = job{"value"}
        value["parent"] = prior{"parent"}
        value["task"] = prior{"task"}
        value["startedAt"] = prior{"startedAt"}
        # never embed a possibly-nil JsonNode in %* (SIGSEGVs at toUgly)
        if prior{"budgetMs"} != nil:
          value["budgetMs"] = prior{"budgetMs"}
        if prior{"status"}.getStr("") == "stopping":
          value["status"] = %"stopped"
      discard c.request("store", "put",
        %*{"kind": "agentjob", "id": jobId, "value": value}, 10_000)
    except CatchableError:
      discard  # the durable record stays "running"; status reports it
    c.emit("ev.agent.done", %*{"jobId": jobId,
                                "sessionId": value{"sessionId"},
                                "status": value{"status"}}))

reconcileAll()
comp.run()
