## agent component tests (fabric Phase 1, docs/research/FABRIC.md).
##
## Boots a sandbox core (store + bash, no LLM) with the test-only stub
## component (components/ctxtest) and the agent component. Drives parent
## turns whose stub LLM calls agent_run; child sessions (their own runners,
## stub-scripted) attempt a nested agent_run (denied by the depth guard),
## run bash, or force an LLM failure. Asserts the full loop: delegated
## child-runner prep, lineage metadata, synchronous reply, depth guard,
## child LLM failure surfaced as a failure, and idle runner retirement.

import std/[json, os, osproc, strutils, times]
import natswrapper
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered (robust
  ## against fast registrations that precede a reg.publish subscription).
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "agent"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("agent", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  let coreBin = sandbox.sandboxBin("niffler")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))
  # NOTE: sandbox intentionally kept on failure for post-mortem (cleaned by OS)

  # compile the test-only stub component into the sandbox
  let ctxBin = sandbox.sandboxBin("ctxtest")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & ctxBin,
    repoRoot / "components" / "ctxtest" / "main.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("ctxtest component failed to compile")
    quit(1)

  let (server, url, monUrl) = startNatsMonitoring()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(coreBin, url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "2")],
                                logFile = "/tmp/opencode/core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running(): coreProc.kill()
      sleep(200)
    if coreProc != nil: coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = "/tmp/opencode/ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = "/tmp/opencode/agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- one parent turn: stub LLM calls agent_run ----------------------------
  let parentId = "agt-parent"
  let turn = call(nc, "core", "session",
                  %*{"sessionId": parentId, "content": "go"}, 120_000)
  check("parent turn completed",
        turn{"reply"}.getStr("") == "agent-turn-done", $turn)

  # agent_run result in the parent transcript: child session id + reply
  var agentResult = JsonNode(nil)
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": parentId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    if content.contains("\"reply\""):
      try: agentResult = parseJson(content)
      except CatchableError: discard
  check("agent_run returned a child session",
        agentResult != nil and
        agentResult{"sessionId"}.getStr("").startsWith("agent-") and
        agentResult{"reply"}.getStr("") == "subagent-done",
        if agentResult != nil: $agentResult else: "no agent_run result")
  let childId = (if agentResult != nil: agentResult{"sessionId"}.getStr("")
                 else: "")

  # --- child transcript: depth guard denied, bash ran -----------------------
  var childTranscript = ""
  for i in 1 .. 8:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": childId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    childTranscript.add($m{"value"}{"content"}.getStr(""))
  check("depth guard denied nested agent_run",
        childTranscript.contains("subagents cannot spawn subagents"),
        childTranscript)
  check("child ran bash", childTranscript.contains("agent-ok"),
        childTranscript)

  # --- lineage: the child session carries its parent in the store ----------
  let meta = call(nc, "store", "get",
                  %*{"kind": "sessionmeta", "id": childId}, 10_000)
  check("child sessionmeta records parent",
        meta{"value"}{"parent"}.getStr("") == parentId, $meta)

  # --- child LLM failure is a failure, not a successful text reply ----------
  # The stub chat raises for a task carrying the marker; agent_run must
  # surface the runner's turnError instead of an ok reply.
  let failParent = "agt-llmfail"
  let failTurn = call(nc, "core", "session",
                      %*{"sessionId": failParent, "content": "go"}, 120_000)
  check("failing parent turn completed",
        failTurn{"reply"}.getStr("") == "agent-turn-done", $failTurn)
  var failResult = JsonNode(nil)
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": failParent & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    if content.contains("llm error") or content.contains("\"error\""):
      try: failResult = parseJson(content)
      except CatchableError: discard
  check("child LLM failure reported as a failure",
        failResult != nil and failResult{"error"}.getStr("").len > 0 and
        failResult{"error"}.getStr("").contains("llm error"),
        if failResult != nil: $failResult else: "no agent_run failure result")
  check("child failure carries the session id",
        failResult != nil and
        failResult{"sessionId"}.getStr("").startsWith("agent-"),
        if failResult != nil: $failResult else: "no agent_run failure result")

  # --- idle retirement: quiet runners self-exit (NIF_RUNNER_IDLE_S=2) -------
  # The parent runner still exists right after the turn; after the idle
  # window it departs (reg.depart → dropped from the catalog). Watch the
  # catalog rather than probing the runner: a direct session call would
  # refresh its idle clock. Poll because turn starts are delayed by the
  # 5s systemprompt fallback window, so the retire clock starts late.
  var retired = false
  for i in 0 ..< 30:
    sleep(1000)
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{"session-" & childId} == nil:
      retired = true
      break
  check("idle child runner retired", retired)
  let reensured = call(nc, "core", "session",
                       %*{"sessionId": childId, "model": ""}, 30_000)
  check("retired runner re-ensured on demand",
        reensured{"error"} == nil, $reensured)

  # --- background jobs: spawn, status, wait, steer, stop, failure -----------
  var doneSub: ptr natsSubscription
  let doneSt = natsConnection_SubscribeSync(addr doneSub, nc.conn,
                                            "ev.agent.done".cstring)
  doAssert checkStatus(doneSt)
  defer: natsSubscription_Destroy(doneSub)
  var startedSub: ptr natsSubscription
  let startedSt = natsConnection_SubscribeSync(addr startedSub, nc.conn,
                                               "ev.agent.started".cstring)
  doAssert checkStatus(startedSt)
  defer: natsSubscription_Destroy(startedSub)

  proc fetchJobId(parent: string): string =
    for i in 1 .. 6:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      let content = m{"value"}{"content"}.getStr("")
      let marker = content.find("\"jobId\":\"job-")
      if marker >= 0:
        let start = marker + "\"jobId\":\"".len
        var stop = start
        while stop < content.len and content[stop] != '"': inc stop
        return content[start ..< stop]
    return ""

  let spawnParent = "agt-spawn"
  let spawnTurn = call(nc, "core", "session",
                       %*{"sessionId": spawnParent, "content": "go"}, 120_000)
  check("spawn parent turn completed",
        spawnTurn{"reply"}.getStr("") == "agent-turn-done", $spawnTurn)
  let jobId = fetchJobId(spawnParent)
  check("agent_spawn returned a jobId immediately",
        jobId.startsWith("job-"), jobId)
  let st1 = call(nc, "agent", "agent_status", %*{"jobId": jobId}, 10_000)
  check("agent_status reports the job",
        st1{"status"}.getStr("") in ["running", "done"], $st1)
  let waited = call(nc, "agent", "agent_wait",
                    %*{"jobId": jobId, "timeoutMs": 60_000}, 90_000)
  check("agent_wait returns the terminal reply",
        waited{"status"}.getStr("") == "done" and
        waited{"reply"}.getStr("") == "subagent-done", $waited)
  var doneSeen = false
  for i in 0 ..< 20:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, doneSub, 300)
    if st != NATS_OK: break
    let ev = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if ev{"payload"}{"jobId"}.getStr("") == jobId:
      doneSeen = ev{"payload"}{"status"}.getStr("") == "done"
      break
  check("ev.agent.done announced the terminal state", doneSeen)
  var startedSeen = false
  for i in 0 ..< 20:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, startedSub, 300)
    if st != NATS_OK: break
    let ev = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if ev{"payload"}{"jobId"}.getStr("") == jobId:
      startedSeen = ev{"payload"}{"sessionId"}.getStr("").startsWith("agent-")
      break
  check("ev.agent.started announced the job", startedSeen)
  let late = call(nc, "agent", "agent_wait", %*{"jobId": jobId}, 30_000)
  check("late agent_wait reads the durable record",
        late{"status"}.getStr("") == "done", $late)

  # failure: a spawned child whose LLM fails records a failed job
  let failSpawn = "agt-spawnfail"
  discard call(nc, "core", "session",
               %*{"sessionId": failSpawn, "content": "go"}, 120_000)
  let failJob = fetchJobId(failSpawn)
  check("failed spawn returned a jobId", failJob.startsWith("job-"), failJob)
  let failed = call(nc, "agent", "agent_wait",
                    %*{"jobId": failJob, "timeoutMs": 60_000}, 90_000)
  check("failed job reports the child LLM failure",
        failed{"status"}.getStr("") == "failed" and
        failed{"error"}.getStr("").contains("llm error"), $failed)

  # steering a spawned job's child: fire-and-forget publish
  let steer = call(nc, "agent", "agent_steer",
                   %*{"session_id": waited{"sessionId"}.getStr(""),
                      "message": "wrap it up"}, 10_000)
  check("agent_steer publishes to the live child",
        steer{"ok"}.getBool(false) and steer{"published"}.getBool(false),
        $steer)

  # stop on an already-terminal job just returns the record
  let stopped = call(nc, "agent", "agent_stop", %*{"jobId": jobId}, 10_000)
  check("agent_stop on a finished job returns the record",
        stopped{"status"}.getStr("") == "done", $stopped)

  # --- real cancellation: agent_stop ends a running job's child turn --------
  # The stub child takes one deliberate bash round (sleep 4); the stop
  # lands while it runs — the runner's between-rounds cancel flag ends the
  # turn, and the terminal record reads "stopped".
  let stopParent = "agt-stop"
  discard call(nc, "core", "session",
               %*{"sessionId": stopParent, "content": "go"}, 120_000)
  let stopJob = fetchJobId(stopParent)
  check("stop spawn returned a jobId", stopJob.startsWith("job-"), stopJob)
  sleep(600)
  let stopping = call(nc, "agent", "agent_stop", %*{"jobId": stopJob}, 10_000)
  check("agent_stop arms the stop",
        stopping{"status"}.getStr("") == "stopping", $stopping)
  let stopWait = call(nc, "agent", "agent_wait",
                      %*{"jobId": stopJob, "timeoutMs": 30_000}, 60_000)
  check("cancelled job terminates as stopped",
        stopWait{"status"}.getStr("") == "stopped", $stopWait)

  # --- restart recovery: stale non-terminal records resolve honestly -------
  # (a) a completed turn whose completion tap was missed (agent was down):
  #     the transcript's final assistant reply synthesizes "done"
  let staleChild = "agent-stale-done"
  discard call(nc, "store", "put",
    %*{"kind": "message", "id": staleChild & ":000001",
       "value": %*{"role": "assistant", "content": "stale reply",
                   "conversationId": staleChild}}, 10_000)
  let staleJob = "job-staledone"
  discard call(nc, "store", "put",
    %*{"kind": "agentjob", "id": staleJob,
       "value": %*{"sessionId": staleChild, "parent": "agt-parent",
                   "status": "running", "task": "stale",
                   "startedAt": epochTime()}}, 10_000)
  let staleStatus = call(nc, "agent", "agent_status",
                         %*{"jobId": staleJob}, 15_000)
  check("stale running job with a final reply resolves done",
        staleStatus{"status"}.getStr("") == "done" and
        staleStatus{"reply"}.getStr("") == "stale reply", $staleStatus)
  # (b) a turn whose runner died without a final reply: "failed — interrupted"
  let deadJob = "job-deadchild"
  discard call(nc, "store", "put",
    %*{"kind": "agentjob", "id": deadJob,
       "value": %*{"sessionId": "agent-deadchild", "parent": "agt-parent",
                   "status": "running", "task": "dead",
                   "startedAt": epochTime()}}, 10_000)
  let deadStatus = call(nc, "agent", "agent_status",
                        %*{"jobId": deadJob}, 15_000)
  check("stale running job with a dead runner resolves failed",
        deadStatus{"status"}.getStr("") == "failed" and
        deadStatus{"error"}.getStr("").contains("interrupted"), $deadStatus)

  # --- reasoning-effort passthrough: the child's LLM sees what was sent ----
  let thinkParent = "agt-think"
  discard call(nc, "core", "session",
               %*{"sessionId": thinkParent, "content": "go"}, 120_000)
  var thinkReply = ""
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": thinkParent & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    if content.contains("thinking:"): thinkReply = content
  check("thinking effort reaches the child's LLM",
        thinkReply.contains("thinking:high"), thinkReply)

  # --- job time budget: exceeded budgets cancel with agent_stop semantics --
  let budgetParent = "agt-budget"
  discard call(nc, "core", "session",
               %*{"sessionId": budgetParent, "content": "go"}, 120_000)
  let budgetJob = fetchJobId(budgetParent)
  check("budget spawn returned a jobId", budgetJob.startsWith("job-"),
        budgetJob)
  # budget is 2000ms; observe lazily at ~3.5s, then wait out the child turn
  sleep(3500)
  let budgetStatus = call(nc, "agent", "agent_status",
                          %*{"jobId": budgetJob}, 15_000)
  check("exceeded budget flips the job to stopping",
        budgetStatus{"status"}.getStr("") == "stopping", $budgetStatus)
  let budgetWait = call(nc, "agent", "agent_wait",
                        %*{"jobId": budgetJob, "timeoutMs": 30_000}, 60_000)
  check("budget-cancelled job terminates as stopped",
        budgetWait{"status"}.getStr("") == "stopped", $budgetWait)

  report("agent")

main()
