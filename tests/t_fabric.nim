## fabric component tests (fabric Phase 2, docs/research/FABRIC.md).
##
## Boots a sandbox core (store + bash, no LLM) with the stub component
## (components/ctxtest) and the fabric component. Drives one session turn
## whose stub LLM issues three fabric calls: a happy-path program (guest
## calls bash through the bridge, logs, finishes with one value), a
## compile-error program (real Nim diagnostics returned), and a budget
## program (infinite call loop dies at maxCalls). Asserts the results from
## the persisted transcript and the ev.fabric.log activity stream.

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

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "fabric", "fabric-exec", "agent", "grep"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("fabric", ["store", "bash"])
  let root = sandbox.root
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric",
                          sandbox.sandboxBin("fabric"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric-exec",
                          sandbox.sandboxBin("fabric-exec"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "grep",
                          sandbox.sandboxBin("grep"))
    # NOTE: fabric-exec bakes the worktree's fabricguest path at compile
    # time — the test runs from the same worktree, so it resolves

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
                                logFile = "/tmp/opencode/core-fab.log")
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

  # capture the activity stream: the guest's logg() must surface as
  # ev.fabric.log events while the turn runs
  var logSub: ptr natsSubscription
  let logSt = natsConnection_SubscribeSync(addr logSub, nc.conn,
                                           "ev.fabric.log".cstring)
  doAssert checkStatus(logSt)
  var logLines = 0

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = "/tmp/opencode/ctxtest-fab.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let fabProc = startComponent(sandbox.sandboxBin("fabric"), url, root = root,
                               logFile = "/tmp/opencode/fabric.log")
  defer:
    if fabProc.running():
      fabProc.terminate()
      sleep(800)
      if fabProc.running(): fabProc.kill()
    fabProc.close()
  check("fabric registered", waitComponent(nc, "fabric"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = "/tmp/opencode/agent-fab.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))
  let grepProc = startComponent(sandbox.sandboxBin("grep"), url, root = root,
                                 logFile = "/tmp/opencode/grep-fab.log")
  defer:
    if grepProc.running():
      grepProc.terminate()
      sleep(800)
      if grepProc.running(): grepProc.kill()
    grepProc.close()
  check("grep registered", waitComponent(nc, "grep"))

  # save a program into the model-curated library before the turn: the
  # fabric tool fetches and runs it by name
  let libProg = "import fabricguest\n" &
    "finish(jobj(jpair(\"lib\", jesc(\"stored-ok\"))))\n"
  let put = call(nc, "store", "put",
                 %*{"kind": "fabricprog", "id": "fab-lib-test",
                    "value": %*{"code": libProg,
                                "description": "t_fabric library fixture"}},
                 10_000)
  check("library program stored", put{"ok"}.getBool(false), $put)

  let sessionId = "fab-test"
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sessionId, "content": "go"}, 600_000)
  check("turn completed",
        turn{"reply"}.getStr("") == "fabric-turn-done", $turn)

  # count ev.fabric.log events delivered while the turn ran
  for i in 0 ..< 10:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, logSub, 300)
    if st != NATS_OK: break
    natsMsg_Destroy(msg)
    inc logLines
  check("coalesced guest logs surfaced as ev.fabric.log", logLines >= 3,
        "received " & $logLines & " of 3 expected log frames")

  # the three fabric results live in the persisted transcript: user(1),
  # assistant(2), tool(3), assistant(4), tool(5), assistant(6), tool(7)
  var transcript = ""
  var selectedTranscript = ""
  for i in 1 .. 42:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": sessionId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    transcript.add(content)
    if i >= 20: selectedTranscript.add(content)

  check("guest bash call through the bridge succeeded",
        transcript.contains("fabric-ok"), transcript)
  check("compile error returned real diagnostics",
        transcript.contains("diagnostics") and
        transcript.contains("Error"), transcript)
  check("maxCalls budget enforced",
        transcript.contains("maxCalls budget exceeded"), transcript)
  check("timed out guest returns an actionable error",
        transcript.contains("fabric-exec timed out"), transcript)
  check("malformed argsJson is rejected explicitly",
        transcript.contains("invalid argsJson"), transcript)
  check("maxCalls range is enforced",
        transcript.contains("maxCalls must be in 1..1000"), transcript)
  check("timeoutMs range is enforced",
        transcript.contains("timeoutMs must be in 1..300000"), transcript)
  check("oversized result retained as an artifact",
        transcript.contains("artifactPath"), transcript)
  var artifactPrivate = false
  let artifactDir = root / "var" / "fabric-artifacts"
  if dirExists(artifactDir):
    for kind, path in walkDir(artifactDir):
      if kind == pcFile:
        artifactPrivate = getFilePermissions(path) ==
          {fpUserRead, fpUserWrite}
  check("artifact is created mode 0600", artifactPrivate)
  check("selected tool executes with a valid catalog pin",
        transcript.contains("selected-ok"), selectedTranscript)
  check("selected mode rejects tools outside its allowlist",
        transcript.contains("is not selected for this Fabric run"),
        selectedTranscript)
  check("typed wrappers preserve explicit optional zero values",
        selectedTranscript.contains("optionalString") and
        selectedTranscript.contains("optionalInt") and
        selectedTranscript.contains("optionalBool") and
        selectedTranscript.contains("dash-value") and
        selectedTranscript.contains("keyword"), selectedTranscript)
  check("typed wrappers preserve omission separately from explicit values",
        selectedTranscript.contains("\"omitted\":{\"requiredValue\":\"only\"}"),
        selectedTranscript)
  check("typed wrapper scalar mismatch is a compile error",
        selectedTranscript.contains("type mismatch") and
        selectedTranscript.contains("requiredValue"), selectedTranscript)
  check("typed wrapper enum remains host-enforced",
        selectedTranscript.contains("declared enum values"), selectedTranscript)
  check("ambiguous wrapper keeps exact raw callTool fallback",
        selectedTranscript.contains("foo_bar") and
        selectedTranscript.contains("fooBar"), selectedTranscript)
  check("style-insensitive property collision omits typed wrapper",
        selectedTranscript.contains("ctx_collision") and
        selectedTranscript.contains("undeclared"), selectedTranscript)
  check("live catalog replacement invalidates a pinned run",
        selectedTranscript.contains("changed after the Fabric schema snapshot"),
        selectedTranscript)
  check("checked-in typed examples execute end to end",
        transcript.contains("grepDone") and transcript.contains("rawBytes") and
        transcript.contains("agentReply"), transcript)

  # hybrid: fabric program -> agent_run -> subagent session -> reply
  check("hybrid fabric->agent_run returned the subagent reply",
        transcript.contains("subagent-done"), transcript)
  check("outer Fabric lease restored after agent_run",
        transcript.contains("lease-restored"), transcript)

  # program library: a dedicated turn runs the stored program by name
  let libTurn = call(nc, "core", "session",
                     %*{"sessionId": "fab-lib", "content": "go"}, 120_000)
  check("library turn completed",
        libTurn{"reply"}.getStr("") == "lib-turn-done", $libTurn)
  var libTranscript = ""
  for i in 1 .. 4:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": "fab-lib:" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    libTranscript.add(m{"value"}{"content"}.getStr(""))
  check("stored program ran by name",
        libTranscript.contains("stored-ok"), libTranscript)

  # bounded batch: independent calls overlap on the host, one failing item
  # is isolated in its slot, outcomes come back in input order
  var evSub: ptr natsSubscription
  let evSt = natsConnection_SubscribeSync(addr evSub, nc.conn,
                                          "ev.fabric.>".cstring)
  doAssert checkStatus(evSt)
  defer: natsSubscription_Destroy(evSub)
  let batchStart = epochTime()
  let batchTurn = call(nc, "core", "session",
                       %*{"sessionId": "fab-batch", "content": "go"}, 120_000)
  let batchSecs = epochTime() - batchStart
  check("batch turn completed",
        batchTurn{"reply"}.getStr("") == "batch-turn-done", $batchTurn)
  var batchTranscript = ""
  for i in 1 .. 4:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": "fab-batch:" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    batchTranscript.add(m{"value"}{"content"}.getStr(""))
  # the guest measured the overlap itself: bash's end timestamp falls
  # inside ctx_sleep's wall-clock window only if both were on the bus
  # at the same time (serialized would place it a second past the end)
  check("batch items ran concurrently",
        batchTranscript.contains("\"concurrent\":true"), batchTranscript)
  check("batch keeps input order, budgets, and per-item failures",
        batchTranscript.contains("\"items\":4") and
        batchTranscript.contains("\"nope\":\"no component provides tool") and
        batchTranscript.contains("\"b3\":true"),
        batchTranscript)

  # lifecycle events: correlated started/call/done frames on the bus
  var evStarted = 0
  var evCallDone = 0
  var evCallFail = 0
  var evDone = 0
  var evDoneOk = false
  var evDoneCalls = -1
  for i in 0 ..< 80:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, evSub, 200)
    if st != NATS_OK: break
    let env = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    let p = env{"payload"}
    if p{"selected"} != nil: inc evStarted
    elif p{"status"} != nil:
      inc evDone
      evDoneOk = evDoneOk or p{"status"}.getStr("") == "done"
      if p{"status"}.getStr("") == "done":
        evDoneCalls = p{"calls"}.getInt(-1)
    elif p{"seq"} != nil:
      inc evCallDone
      if not p{"ok"}.getBool(false): inc evCallFail
  check("ev.fabric.started announces each run", evStarted >= 1,
        "started=" & $evStarted)
  check("ev.fabric.call.done covers every nested call", evCallDone >= 4,
        "call.done=" & $evCallDone)
  check("ev.fabric.call.done records per-item failure", evCallFail >= 1,
        "call failures=" & $evCallFail)
  check("ev.fabric.done announces the terminal state",
        evDone >= 1 and evDoneOk, "done=" & $evDone)
  check("ev.fabric.done reports the real call count", evDoneCalls == 4,
        "done.calls=" & $evDoneCalls)

  # output schema: the wrapper's declared outputSchema types the return
  let outTurn = call(nc, "core", "session",
                     %*{"sessionId": "fab-out", "content": "go"}, 120_000)
  check("output-schema turn completed",
        outTurn{"reply"}.getStr("") == "out-turn-done", $outTurn)
  var outTranscript = ""
  for i in 1 .. 4:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": "fab-out:" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    outTranscript.add(m{"value"}{"content"}.getStr(""))
  check("typed output schema returns a typed value",
        outTranscript.contains("typed-ok") and
        not outTranscript.contains("Error"), outTranscript)

  # event metadata from the fab-out runs (selected mode, one valid run,
  # one budget-rejected run that must never announce started)
  var outStarted = 0
  var outComponent = ""
  var outResultBytes = 0
  var outDoneCalls = -1
  for i in 0 ..< 40:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, evSub, 300)
    if st != NATS_OK: break
    let env = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    let p = env{"payload"}
    if p{"selected"} != nil:
      inc outStarted
    elif p{"status"} != nil:
      outDoneCalls = p{"calls"}.getInt(-1)
    elif p{"seq"} != nil:
      if p{"ok"} != nil:
        if p{"ok"}.getBool(false):
          outResultBytes = p{"resultBytes"}.getInt(0)
      elif p{"component"}.getStr("").len > 0:
        outComponent = p{"component"}.getStr("")
  check("rejected program never announces ev.fabric.started",
        outStarted == 1, "started=" & $outStarted)
  check("ev.fabric.call.started names the pinned component",
        outComponent == "ctxtest", outComponent)
  check("ev.fabric.call.done reports result size", outResultBytes > 0,
        "resultBytes=" & $outResultBytes)
  check("ev.fabric.done reports budget usage", outDoneCalls == 1,
        "done.calls=" & $outDoneCalls)

  # the subagent really ran: fetch its transcript via the returned sessionId
  var childT = ""
  var marker = transcript.find("sessionId\\\":\\\"agent-")
    # the fabric result is embedded as an escaped JSON string
  var markerText = "sessionId\\\":\\\""
  if marker < 0:
    markerText = "\"sessionId\":\""
    marker = transcript.find(markerText & "agent-")
  if marker >= 0:
    let start = marker + markerText.len
    var stop = start
    while stop < transcript.len and
          (transcript[stop] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
      inc stop
    let cid = transcript[start ..< stop]
    for i in 1 .. 12:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": cid & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      childT.add(m{"value"}{"content"}.getStr(""))
  check("hybrid subagent ran bash in its own session",
        childT.contains("agent-ok"), childT)

  report("fabric")

main()
