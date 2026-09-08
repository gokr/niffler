## fabric mid-run cancellation tests (docs/FABRIC_GUIDE.md, issue #16).
##
## Boots a sandbox core (store + bash, no LLM) with the test-only stub
## component (components/ctxtest), the fabric component and the agent
## component. Drives parent turns whose stub LLM agent_spawns children that
## run fabric programs, then stops the child jobs mid-run:
##  - a busy-loop guest (logg() proving liveness) must end well before its
##    deadline, reporting a cancelled outcome (ev.fabric.done status
##    "cancelled"), with the fabric-exec child process gone;
##  - a second, queued fabric run must be unaffected by cancelling the first
##    (isolation: it still completes with status "done");
##  - a guest blocked inside a NESTED bash call must be terminated and the
##    nested bash process tree killed (the stop is published as cancel.bash
##    while the nested dispatch is in flight — the fabric run must still
##    end its guest; no marker, no orphan).
##
## Stops ride the agent_stop path (steer __cancel -> runner publishes
## cancel.<component>), exactly like t_agent's mid-tool cancellation test.

import std/[json, os, osproc, strutils, times]
import natswrapper
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc waitFor(cond: proc(): bool, secs: int, what: string): bool =
  ## Poll cond() until true or timeout; prints progress so a hang is visible.
  let deadline = epochTime() + secs.float
  while epochTime() < deadline:
    if cond(): return true
    sleep(250)
  echo "  (timed out waiting for: ", what, ")"
  return false

proc fetchJobId(nc: NatsConnection, parent: string): string =
  ## Read the parent transcript and extract the agent_spawn jobId.
  for i in 1 .. 8:
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

proc childOf(nc: NatsConnection, jobId: string): string =
  ## The agentjob record's sessionId (the spawned child session).
  let st = call(nc, "agent", "agent_status", %*{"jobId": jobId}, 10_000)
  result = st{"sessionId"}.getStr("")

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "fabric", "fabric-exec", "agent"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("fab-cancel", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  let fabExecBin = sandbox.sandboxBin("fabric-exec")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric",
                          sandbox.sandboxBin("fabric"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric-exec",
                          fabExecBin)
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))

  # compile the test-only stub component into the sandbox
  let ctxBin = sandbox.sandboxBin("ctxtest")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & ctxBin,
    repoRoot / "components" / "ctxtest" / "main.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 180_000) != 0:
    fail("ctxtest component failed to compile")
    quit(1)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")],
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
  let fabProc = startComponent(sandbox.sandboxBin("fabric"), url, root = root,
                               logFile = root / "var" / "test-logs" / "fabric.log")
  defer:
    if fabProc.running():
      fabProc.terminate()
      sleep(800)
      if fabProc.running(): fabProc.kill()
    fabProc.close()
  check("fabric registered", waitComponent(nc, "fabric"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # lifecycle + log stream: ev.fabric.done carries the terminal outcome,
  # ev.fabric.log carries the guest's logg() lines (liveness proof)
  var evSub: ptr natsSubscription
  let evSt = natsConnection_SubscribeSync(addr evSub, nc.conn,
                                          "ev.fabric.>".cstring)
  doAssert checkStatus(evSt)
  var logSub: ptr natsSubscription
  let logSt = natsConnection_SubscribeSync(addr logSub, nc.conn,
                                           "ev.fabric.log".cstring)
  doAssert checkStatus(logSt)
  var busyLogSeen = false
  proc drainLogs() =
    for i in 0 ..< 10:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, logSub, 0)
      if st != NATS_OK: break
      let env = parseJson($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if env{"payload"}{"s"}.getStr("").contains("fab-busy"):
        busyLogSeen = true
  # events drained between scenario phases; each drain call reports what it
  # found through `seen` buckets set by the caller via the closure below
  var events: seq[JsonNode]
  proc drainEvents() =
    for i in 0 ..< 200:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, evSub, 0)
      if st != NATS_OK: break
      let env = parseJson($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      events.add(env)

  proc waitCancelled(secs: int): tuple[seen: bool, wall: float] =
    ## Drain ev.fabric.> until a cancelled terminal outcome arrives (the
    ## job record can go terminal a hair before the fabric component
    ## finishes emitting its own cancelled event — poll, don't assume).
    let deadline = epochTime() + secs.float
    while epochTime() < deadline:
      drainEvents()
      for ev in events:
        let p = ev{"payload"}
        if p{"status"}.getStr("") == "cancelled" and p{"runId"} != nil:
          return (true, epochTime())
      sleep(200)
    (false, -1.0)

  # --- scenario A: a busy-loop guest is stopped well before its deadline ---
  # The child's turn is blocked inside the fabric tool while the guest
  # spins and logs; agent_stop lands mid-run. The runner publishes
  # cancel.fabric, the fabric component must terminate fabric-exec promptly
  # and report a cancelled outcome — the guest's deadline is 60s.
  discard call(nc, "core", "session",
               %*{"sessionId": "fcs-busy", "content": "go"}, 120_000)
  let busyJob = fetchJobId(nc, "fcs-busy")
  check("busy spawn returned a jobId", busyJob.startsWith("job-"), busyJob)
  check("busy child is running a fabric program",
        waitFor(proc(): bool = drainLogs(); busyLogSeen, 45,
                "first fab-busy logg line (guest liveness)"),
        "no fab-busy log within 45s — guest did not start?")

  # --- scenario B: a second fabric run queued behind the busy one ----------
  # Spawn a child whose fabric program finishes immediately. The fabric
  # component is one process: while the busy run holds its pump, the quick
  # child's fabric request queues at svc.fabric.call. Wait until the quick
  # child's runner has actually issued the dispatch (its assistant tool_call
  # is persisted before the fabric reply arrives), then cancel the busy run:
  # the queued run must NOT be cancelled or affected by the other run's stop.
  discard call(nc, "core", "session",
               %*{"sessionId": "fcs-quick", "content": "go"}, 120_000)
  let quickJob = fetchJobId(nc, "fcs-quick")
  check("quick spawn returned a jobId", quickJob.startsWith("job-"), quickJob)
  let quickChildId = childOf(nc, quickJob)
  check("quick child's fabric call is queued behind the busy run",
        waitFor(proc(): bool =
          for i in 1 .. 12:
            let m = call(nc, "store", "get",
                         %*{"kind": "message",
                            "id": quickChildId & ":" & align($i, 6, '0')},
                         10_000)
            if m{"error"} == nil and m{"value"}{"tool_calls"} != nil and
                ($m{"value"}{"tool_calls"}).contains("fabric"):
              return true
          false, 40,
          "quick child's fabric dispatch while the busy run still runs"),
        "quick fabric call never queued")

  # --- stop the busy run mid-guest -----------------------------------------
  let stopStart = epochTime()
  let stopping = call(nc, "agent", "agent_stop", %*{"jobId": busyJob}, 10_000)
  check("agent_stop arms the stop",
        stopping{"status"}.getStr("") == "stopping", $stopping)
  let busyWait = call(nc, "agent", "agent_wait",
                      %*{"jobId": busyJob, "timeoutMs": 20_000}, 60_000)
  let stopSecs = epochTime() - stopStart
  check("busy job terminalizes as stopped promptly",
        busyWait{"status"}.getStr("") == "stopped" and stopSecs < 10.0,
        $busyWait & " secs=" & $stopSecs.int)
  # the cancelled fabric outcome: ev.fabric.done status "cancelled", emitted
  # shortly after the stop (the guest's deadline was 60s — well before it)
  let cancelledRes = waitCancelled(10)
  check("cancelled run reports the cancelled outcome", cancelledRes.seen,
        $events)
  check("cancelled outcome arrived well before the 60s deadline",
        cancelledRes.seen and cancelledRes.wall - stopStart < 12.0,
        "cancelled seen " & $(cancelledRes.wall - stopStart).int &
        "s after stop")

  # --- scenario B asserts: the queued run was untouched --------------------
  let quickWait = call(nc, "agent", "agent_wait",
                       %*{"jobId": quickJob, "timeoutMs": 60_000}, 90_000)
  check("queued run completed as done (not cancelled)",
        quickWait{"status"}.getStr("") == "done" and
        quickWait{"reply"}.getStr("") == "fab-quick-done", $quickWait)
  var quickTranscript = ""
  let quickChild = childOf(nc, quickJob)
  for i in 1 .. 10:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": quickChild & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    quickTranscript.add(m{"value"}{"content"}.getStr(""))
  check("queued run's fabric program executed",
        quickTranscript.contains("fab-quick-ok"), quickTranscript)
  # a done (not cancelled) terminal event followed the cancelled one; drain
  # now so the quick run's ev.fabric.done (published when its guest ended,
  # just before the child's job record went terminal) is included
  drainEvents()
  var doneSeen = false
  var cancelledIdx = -1
  var doneIdx = -1
  for i, ev in events:
    let status = ev{"payload"}{"status"}.getStr("")
    if status == "cancelled": cancelledIdx = i
    elif status == "done": doneIdx = i
  doneSeen = doneIdx >= 0 and doneIdx > cancelledIdx
  check("second run announced done after the cancelled run", doneSeen,
        "cancelledIdx=" & $cancelledIdx & " doneIdx=" & $doneIdx)

  # --- no orphaned fabric-exec survives (busy + quick runs both finished) --
  sleep(600)  # give any stray child a chance to show itself
  check("no fabric-exec process survives cancelled + done runs",
        not processExists(fabExecBin), fabExecBin)

  # --- scenario C: guest blocked inside a NESTED bash call -----------------
  # The guest called bash (sleep 30 && touch a marker) through the bridge;
  # the stop lands while that nested dispatch is in flight, so the runner
  # publishes cancel.bash, not cancel.fabric. The fabric component must
  # still terminate the guest (cancel.> side-channel), and the bash
  # component must kill the sleep process tree: no marker, no orphan.
  let slowMarker = root / "var" / "fab-slowbash-marker"
  if fileExists(slowMarker): removeFile(slowMarker)
  discard call(nc, "core", "session",
               %*{"sessionId": "fcs-slowbash", "content": "go"}, 120_000)
  let slowJob = fetchJobId(nc, "fcs-slowbash")
  check("slowbash spawn returned a jobId", slowJob.startsWith("job-"),
        slowJob)
  events.setLen(0)
  var nestedBashSeen = false
  check("guest launched its nested bash call",
        waitFor(proc(): bool =
          drainEvents()
          for ev in events:
            let p = ev{"payload"}
            if p{"tool"}.getStr("") == "bash" and p{"seq"} != nil and
                p{"ok"} == nil:
              nestedBashSeen = true
          nestedBashSeen, 45,
          "ev.fabric.call.started for the nested bash call"),
        "nested bash never launched")
  sleep(400)  # let the nested sleep 30 settle into its process tree
  let slowStart = epochTime()
  discard call(nc, "agent", "agent_stop", %*{"jobId": slowJob}, 10_000)
  let slowWait = call(nc, "agent", "agent_wait",
                      %*{"jobId": slowJob, "timeoutMs": 20_000}, 60_000)
  let slowSecs = epochTime() - slowStart
  check("nested-bash job terminalizes as stopped promptly",
        slowWait{"status"}.getStr("") == "stopped" and slowSecs < 10.0,
        $slowWait & " secs=" & $slowSecs.int)
  sleep(500)
  check("nested bash process tree was killed (no orphan)",
        not processExists("fab-slowbash-marker"))
  check("cancelled nested bash command never finished (marker untouched)",
        not fileExists(slowMarker))
  let cancelled2 = waitCancelled(10).seen
  check("nested-bash fabric run reported the cancelled outcome", cancelled2,
        $events)
  check("nested-bash fabric-exec process is gone",
        not processExists(fabExecBin), fabExecBin)

  report("fabric-cancel")

main()
