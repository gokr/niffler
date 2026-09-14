## P1.3 continuation tests (docs/research/SUBAGENTS-PLAN.md).
##
## `agent_run`/`agent_spawn {session}` give an EXISTING child another turn
## instead of minting a fresh one, and every failure mode refuses EXPLICITLY
## (fail-closed) rather than silently starting something else:
##
## - continue-after-done reuses the same session and APPENDS to its
##   transcript (no re-primed task preamble);
## - frozen controls: model/thinking/tools/budgets are ignored on
##   continuation and the result reports the child's EFFECTIVE controls;
## - busy: `agent_run {session}` on a mid-turn child is refused with a
##   `busy` error (it promised a result NOW); `agent_spawn {session}`
##   queues instead (it promises work HAPPENS);
## - authorization: unknown session, root conversation and closed child
##   all fail closed with distinct reasons, and no child is minted;
## - close: marks the child closed (nothing deleted); later continuations
##   refuse; on agent_spawn it is applied by the job's completion;
## - the activation ledger (sessionmeta.activations, job activation) counts
##   each turn;
## - v1-shaped job records (no activation fields) stay readable.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
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
  let sandbox = newCoreSandbox("agentcont", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  let coreBin = sandbox.sandboxBin("niffler")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))

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
                                logFile = root / "var" / "test-logs" / "core.log")
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
                               logFile = root / "var" / "test-logs" / "ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- helpers -------------------------------------------------------------

  proc msgs(parent: string): seq[JsonNode] =
    ## All stored messages of a conversation, in id order.
    for i in 1 .. 80:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      result.add(m{"value"})

  proc toolJsons(parent: string): seq[JsonNode] =
    ## Tool-call results in a parent transcript, parsed. A component's
    ## errResult arrives as a SUCCESSFUL tool call whose value is
    ## {"ok": false, "error": ...} — dispatchSubjectCall returns resp.args
    ## verbatim; only exceptions become "ERROR: ..." strings.
    for m in msgs(parent):
      if m{"role"}.getStr("") != "tool": continue
      let content = m{"content"}.getStr("")
      if content.startsWith("{"):
        try: result.add(parseJson(content))
        except CatchableError: discard

  proc lastTool(parent: string): JsonNode =
    ## The most recent parsed agent tool result in a parent transcript.
    let all = toolJsons(parent)
    if all.len > 0: result = all[^1]

  proc userContents(session: string): seq[string] =
    for m in msgs(session):
      if m{"role"}.getStr("") == "user":
        result.add(m{"content"}.getStr(""))

  proc metaOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "sessionmeta", "id": child}, 10_000){"value"}

  proc headerOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "conversation", "id": child}, 10_000){"value"}

  proc jobRecord(jobId: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "agentjob", "id": jobId}, 10_000){"value"}

  proc waitJobDone(jobId: string): JsonNode =
    ## Poll one job record until it is terminal (the completion tap wrote it).
    for i in 0 ..< 120:
      result = jobRecord(jobId)
      if result != nil and
          result{"status"}.getStr("") notin ["running", "stopping"]:
        return
      sleep(250)
    result = jobRecord(jobId)

  proc waitClosed(child: string): bool =
    for i in 0 ..< 40:
      if metaOf(child){"closed"}.getBool(false): return true
      sleep(250)
    return metaOf(child){"closed"}.getBool(false)

  proc turn(parent: string) =
    ## Drive one parent turn (the stub LLM scripts the tool call).
    let r = call(nc, "core", "session",
                 %*{"sessionId": parent, "content": "go"}, 180_000)
    if r{"error"} != nil:
      fail("parent turn " & parent & " errored: " & $r)

  # =========================================================================
  # 1. continue-after-done + frozen controls + close (parent: cnt-main)
  # =========================================================================
  turn("cnt-main")            # stage 0: fresh agent_run, model mock-model
  let fresh = lastTool("cnt-main")
  let child = fresh{"sessionId"}.getStr("")
  check("fresh run returned a child session",
        child.startsWith("agent-"), $fresh)
  check("fresh run is not marked continued",
        fresh{"continued"}.getBool(false) == false, $fresh)
  check("fresh child has a lineage record",
        metaOf(child){"parent"}.getStr("") == "cnt-main", $metaOf(child))
  check("fresh child's header carries the requested model",
        headerOf(child){"model"}.getStr("") == "mock-model",
        $headerOf(child))

  turn("cnt-main")            # stage 2: agent_run {session}
  let cont = lastTool("cnt-main")
  check("continuation reuses the same session",
        cont{"continued"}.getBool(false) and
        cont{"sessionId"}.getStr("") == child, $cont)
  check("continuation activation is 2",
        cont{"activation"}.getInt(0) == 2, $cont)
  check("child saw the follow-up (same conversation)",
        cont{"reply"}.getStr("").contains("cnt-saw-followup"),
        cont{"reply"}.getStr(""))
  let eff = cont{"effective"}
  check("continuation reports effective controls",
        eff != nil and eff.kind == JObject, $eff)
  check("effective model is the child's frozen one",
        eff{"model"}.getStr("") == "mock-model", $eff)
  let uc = userContents(child)
  check("child transcript has two user turns", uc.len == 2, $uc.len)
  if uc.len == 2:
    check("first user turn carries the task preamble (fresh birth)",
          uc[0].startsWith("You are a subagent."), uc[0])
    check("continuation appends the bare follow-up (no preamble)",
          uc[1] == "CNT_FOLLOWUP report what you were told", uc[1])
  check("sessionmeta activations advanced to 2",
        metaOf(child){"activations"}.getInt(0) == 2, $metaOf(child))
  check("sessionmeta has firstActivationAt",
        metaOf(child){"firstActivationAt"}.getFloat(0) > 0, $metaOf(child))

  turn("cnt-main")            # stage 4: ignored overrides + close
  let cont2 = lastTool("cnt-main")
  check("override continuation did not error",
        cont2{"error"} == nil, $cont2)
  check("close accepted on a synchronous continuation",
        cont2{"closed"}.getBool(false), $cont2)
  check("second continuation activation is 3",
        cont2{"activation"}.getInt(0) == 3, $cont2)
  check("effective model STILL the frozen one (override ignored)",
        cont2{"effective"}{"model"}.getStr("") == "mock-model", $cont2)
  check("conversation header model unchanged by the override",
        headerOf(child){"model"}.getStr("") == "mock-model",
        $headerOf(child))
  check("child ran the closed turn",
        cont2{"reply"}.getStr("").contains("cnt-final"), $cont2)
  check("sessionmeta closed and activations 3",
        metaOf(child){"closed"}.getBool(false) and
        metaOf(child){"activations"}.getInt(0) == 3, $metaOf(child))

  # =========================================================================
  # 2. fail-closed authorization (parent: cnt-fail)
  # =========================================================================
  # a lineage record with NO parent field: the defensive "root conversation"
  # branch (sessionmeta exists, so it is known, but it names no parent)
  discard call(nc, "store", "put",
    %*{"kind": "sessionmeta", "id": "cnt-fake-root", "value": {}}, 10_000)

  turn("cnt-fail")            # stage 0: session "agent-does-not-exist"
  let unknown = lastTool("cnt-fail")
  check("unknown session refused explicitly",
        unknown{"error"}.getStr("").contains("unknown subagent session"),
        $unknown)

  turn("cnt-fail")            # stage 2: session = the caller itself
  let self = lastTool("cnt-fail")
  check("self-continuation refused explicitly",
        self{"error"}.getStr("").contains("cannot continue yourself"), $self)

  turn("cnt-fail")            # stage 4: a known record with no parent (root)
  let rootRes = lastTool("cnt-fail")
  check("root conversation refused explicitly",
        rootRes{"error"}.getStr("").contains("root conversation"), $rootRes)
  var fchildren = 0
  let metas = call(nc, "store", "list", %*{"kind": "sessionmeta"}, 10_000)
  if metas{"items"} != nil:
    for it in metas{"items"}:
      if it{"value"}{"parent"}.getStr("") == "cnt-fail":
        inc fchildren
  check("failed authorizations minted no child", fchildren == 0,
        $fchildren & " children already exist")

  turn("cnt-fail")            # stage 6: fresh spawn (background)
  let spawned = lastTool("cnt-fail")
  let fjob = spawned{"jobId"}.getStr("")
  check("fresh spawn returned a job", fjob.startsWith("job-"), $spawned)
  let fdone = waitJobDone(fjob)
  let fchild = fdone{"sessionId"}.getStr("")
  check("fresh spawn settled done",
        fdone{"status"}.getStr("") == "done", $fdone)
  check("spawned child has a lineage record",
        metaOf(fchild){"parent"}.getStr("") == "cnt-fail", $metaOf(fchild))

  turn("cnt-fail")            # stage 8: close the child
  let closedRes = lastTool("cnt-fail")
  check("close on a synchronous continuation reports closed",
        closedRes{"closed"}.getBool(false), $closedRes)
  check("closed child's record survives (nothing deleted)",
        metaOf(fchild) != nil and metaOf(fchild){"closed"}.getBool(false),
        $metaOf(fchild))

  turn("cnt-fail")            # stage 10: continue the closed child
  let afterClose = lastTool("cnt-fail")
  check("continuation of a closed child refuses explicitly",
        afterClose{"error"}.getStr("").contains("was closed"), $afterClose)

  # =========================================================================
  # 3. busy: agent_run {session} on a mid-turn child (parent: cnt-busy)
  # =========================================================================
  turn("cnt-busy")            # stage 0: spawn a child whose TOOL sleeps 8s
  var bchild = ""
  var bjob = ""
  for i in 0 ..< 60:
    for t in toolJsons("cnt-busy"):
      let sid = t{"sessionId"}.getStr("")
      if sid.startsWith("agent-"):
        bchild = sid
        bjob = t{"jobId"}.getStr("")
    if bchild.len > 0: break
    sleep(250)
  check("slow child exists", bchild.startsWith("agent-"), bchild)
  var turnStarted = false
  for i in 0 ..< 40:
    if msgs(bchild).len > 0:
      turnStarted = true
      break
    sleep(250)
  check("slow child's turn began", turnStarted, "no transcript yet")
  sleep(600)                  # margin for the ev.session.turn tap
  turn("cnt-busy")            # stage 2: agent_run {session} while mid-turn
  let busy = lastTool("cnt-busy")
  check("agent_run on a mid-turn child is refused with busy",
        busy{"code"}.getStr("") == "busy" and
        busy{"error"}.getStr("").contains("mid-turn"), $busy)
  check("busy refusal names the queueing alternative",
        busy{"error"}.getStr("").contains("agent_spawn"), $busy)
  check("busy refusal kept the same session id",
        busy{"sessionId"}.getStr("") == bchild, $busy)
  check("refused continuation started no turn",
        userContents(bchild).len == 1, $userContents(bchild).len)
  # stop the slow child so teardown is prompt (also exercises agent_stop on
  # a mid-tool-round child); the job's terminal record reads "stopped"
  let stopped = call(nc, "agent", "agent_stop", %*{"jobId": bjob}, 10_000)
  check("agent_stop accepted the running job",
        stopped{"error"} == nil and
        stopped{"status"}.getStr("") in ["stopping", "stopped"], $stopped)
  let stopDone = waitJobDone(bjob)
  check("stopped job terminalized",
        stopDone{"status"}.getStr("") == "stopped", $stopDone)

  # =========================================================================
  # 4. agent_spawn {session}: queues, ledgered; close applied on completion
  # =========================================================================
  turn("cnt-spawn")           # stage 0: fresh background spawn
  let firstRes = lastTool("cnt-spawn")
  let j1 = firstRes{"jobId"}.getStr("")
  check("background spawn returned a job", j1.startsWith("job-"), $firstRes)
  let first = waitJobDone(j1)
  let schild = first{"sessionId"}.getStr("")
  check("background child settled", first{"status"}.getStr("") == "done",
        $first)
  check("fresh background job is not a continuation",
        first{"continued"}.getBool(false) == false, $first)

  turn("cnt-spawn")           # stage 2: agent_spawn {session} — QUEUES
  let sc = lastTool("cnt-spawn")
  let j2 = sc{"jobId"}.getStr("")
  check("spawn continuation returned a job for the SAME child",
        j2.startsWith("job-") and sc{"sessionId"}.getStr("") == schild, $sc)
  let second = waitJobDone(j2)
  check("queued continuation ran to done",
        second{"status"}.getStr("") == "done", $second)
  check("job record carries the continuation marker",
        second{"continued"}.getBool(false), $second)
  check("job record carries the activation number",
        second{"activation"}.getInt(0) == 2, $second)
  check("child saw the queued follow-up",
        second{"reply"}.getStr("").contains("cnt-saw-followup"),
        second{"reply"}.getStr(""))
  check("sessionmeta activations advanced to 2",
        metaOf(schild){"activations"}.getInt(0) == 2, $metaOf(schild))
  check("child transcript appended the queued turn",
        userContents(schild).len == 2, $userContents(schild).len)

  turn("cnt-spawn")           # stage 4: agent_spawn {session, close}
  let sclose = lastTool("cnt-spawn")
  let j3 = sclose{"jobId"}.getStr("")
  check("spawn close accepted (queued, applied on completion)",
        sclose{"close"}.getBool(false) and j3.startsWith("job-"), $sclose)
  let third = waitJobDone(j3)
  check("final queued turn ran (activation 3)",
        third{"status"}.getStr("") == "done" and
        third{"activation"}.getInt(0) == 3, $third)
  check("close applied by the job's completion (child retired)",
        waitClosed(schild), $metaOf(schild))
  check("closed child survives in the store",
        metaOf(schild) != nil, "sessionmeta vanished")

  turn("cnt-spawn")           # stage 6: FRESH one-shot agent_run + close
  let oneshot = lastTool("cnt-spawn")
  let ochild = oneshot{"sessionId"}.getStr("")
  check("one-shot fresh close accepted",
        oneshot{"closed"}.getBool(false) and
        oneshot{"continued"}.getBool(false) == false, $oneshot)
  check("one-shot child retired in lineage",
        metaOf(ochild){"closed"}.getBool(false), $metaOf(ochild))

  # =========================================================================
  # 5. v1 job records (no activation fields) stay readable
  # =========================================================================
  let put = call(nc, "store", "put",
    %*{"kind": "agentjob", "id": "job-v1-legacy",
       "value": {
         "sessionId": schild, "parent": "cnt-spawn",
         "status": "done", "task": "legacy v1 record",
         "startedAt": now().toTime().toUnixFloat(),
         "endedAt": now().toTime().toUnixFloat(),
         "reply": "legacy"}}, 10_000)
  check("v1 record written", put{"error"} == nil, $put)
  let legacy = call(nc, "agent", "agent_status",
                    %*{"jobId": "job-v1-legacy"}, 10_000)
  check("v1 job record readable via agent_status",
        legacy{"status"}.getStr("") == "done" and
        legacy{"reply"}.getStr("") == "legacy", $legacy)
  let roster = call(nc, "agent", "agent_list",
    %*{"scope": "children",
       "__session": {"session": "cnt-spawn"}}, 10_000)
  check("agent_list tolerates v1 records",
        roster{"error"} == nil and roster{"count"}.getInt(0) >= 1, $roster)

  report("agentcont")

when isMainModule:
  main()
