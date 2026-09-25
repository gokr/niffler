## t_compaction — replaceable compaction seam integration (§4–§8).
##
## Uses the enforcing deterministic mock LLM and real SQLite store/core/
## session runner/default compactor. It proves candidate commit, temporary
## snapshot cleanup, canonical immutability, projection reload after a runner
## crash, and a second compaction that absorbs the first checkpoint.

import std/[json, os, osproc, streams, strtabs, strutils, times]
import natsnim
import ../sdk/envelope
import helpers

const oldMarker = "OLD-CANONICAL-BULK-7Q"

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for i in 0 ..< secs * 5:
    try:
      let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
      if snap{"components"}{name} != nil: return true
    except CatchableError:
      discard
    sleep(200)

proc stopHard(p: var Process) =
  if p != nil and p.running():
    p.terminate()
    sleep(800)
    if p.running(): p.kill()
    sleep(300)
  if p != nil: p.close()
  p = nil

proc seqOf(id: string): int =
  let colon = id.rfind(':')
  if colon >= 0:
    try: return parseInt(id[colon + 1 .. ^1])
    except ValueError: discard

proc putDoc(nc: NatsConnection, kind, id: string, value: JsonNode) =
  let r = call(nc, "store", "put",
    %*{"kind": kind, "id": id, "value": value}, 10_000)
  doAssert r{"ok"}.getBool(false), "put " & kind & "/" & id & ": " & $r

proc getDoc(nc: NatsConnection, kind, id: string): JsonNode =
  let r = call(nc, "store", "get", %*{"kind": kind, "id": id}, 10_000)
  if r{"ok"}.getBool(false): r{"value"} else: nil

proc listDocs(nc: NatsConnection, kind: string;
              prefix = ""): seq[JsonNode] =
  let r = call(nc, "store", "list",
    %*{"kind": kind, "idPrefix": prefix, "limit": 1000}, 10_000)
  if r{"items"} != nil:
    for item in r{"items"}: result.add(item)

proc subscribeEvents(nc: NatsConnection, subject: string): ptr natsSubscription =
  ## Sync subscription for ev.session.<id>.<kind> frames — the gauge-relevant
  ## status frames and the context frames are published by the runner, so a
  ## test can assert what a UI would receive.
  doAssert checkStatus(natsConnection_SubscribeSync(addr result, nc.conn,
                                                   subject.cstring))

proc drainEvents(sub: ptr natsSubscription): seq[JsonNode] =
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 1)
    if st == NATS_TIMEOUT: break
    doAssert checkStatus(st)
    let env = decode($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if env.payload != nil: result.add(env.payload)

proc seedMessages(nc: NatsConnection, convId: string, firstSeq, pairs,
                  bodyBytes: int, markFirst = true): int =
  result = firstSeq
  for pair in 0 ..< pairs:
    let marker = if pair == 0 and markFirst: oldMarker & " " else: ""
    let userBody = marker & "old objective " & $pair & " " &
                   repeat("u", bodyBytes)
    putDoc(nc, "message", convId & ":" & align($result, 6, '0'),
      %*{"role": "user", "content": userBody,
         "conversationId": convId, "createdAt": epochTime()})
    inc result
    putDoc(nc, "message", convId & ":" & align($result, 6, '0'),
      %*{"role": "assistant", "content": "old result " & $pair & " " &
          repeat("a", bodyBytes), "conversationId": convId,
          "createdAt": epochTime()})
    inc result

proc requestLog(path: string): seq[JsonNode] =
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      try: result.add(parseJson(line))
      except CatchableError: discard

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))
  for name in ["niffler", "session", "compaction", "recall", "bash"]:
    if not fileExists(repoRoot / "var" / "bin" / name):
      fail("missing " & name & " binary — run `make build` first")
      quit(1)

  let sandbox = newCoreSandbox("compaction",
    ["store", "bash", "llm", "compaction", "recall"])
  let root = sandbox.root
  defer: removeDir(root)
  var fixtureProc: Process
  defer: stopHard(fixtureProc)
  # Replace llm in the immutable binary snapshot with the deterministic mock.
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off", "--path:" & repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"), repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, 120_000) != 0:
    fail("mock llm failed to compile")
    quit(1)
  compiler.close()
  let fixtureCompiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off", "--path:" & repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("fixture-compaction"),
    repoRoot / "tests" / "compaction_contract" / "fixture.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(fixtureCompiler, 120_000) != 0:
    fail("contract fixture compactor failed to compile")
    quit(1)
  fixtureCompiler.close()

  let logPath = root / "mock-requests.log"
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let extra = @[
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MOCK_CTX", "16000"),
    # Keep a large output reserve so admission compacts around 9k input
    # while the auxiliary summarization request still has a 16k provider
    # window. This separates trigger pressure from summarizer capacity.
    ("NIF_CTX_RESERVE", "7000"),
    ("NIF_MOCK_LOG", logPath),
    ("NIF_MOCK_HISTORY_MARKER", oldMarker),
    ("NIF_COMPACTION_TOOL", "compaction_propose")]
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-compaction.log")
  defer: coreProc.stopHard()
  doAssert waitComponent(nc, "store"), "store did not register"
  doAssert waitComponent(nc, "llm"), "mock llm did not register"
  doAssert waitComponent(nc, "compaction"), "compaction did not register"

  let convId = "conv-compaction-" & $int(epochTime())
  putDoc(nc, "conversation", convId,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt",
       "modelOverride": "mock-parent-model", "title": "compaction fixture"})
  let nextSeq = seedMessages(nc, convId, 1, 8, 2200)
  let seededCount = nextSeq - 1

  let first = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "CURRENT-OBJECTIVE-GEN1",
       "tools": ["bash"]}, 180_000)
  check("first pressured turn completes", first{"turnError"}.getStr("").len == 0,
        first{"turnError"}.getStr(""))
  let projection1 = getDoc(nc, "context_projection", convId)
  check("runner-marked compactor commits in an allowlisted session",
        projection1 != nil and projection1{"generation"}.getInt(0) == 1,
        (if projection1 == nil: "projection missing" else: $projection1))
  check("projection records the default replaceable tool",
        projection1{"provenance"}{"tool"}.getStr("") == "compaction_propose")
  let firstLog = requestLog(logPath)
  check("auxiliary compaction chat uses a distinct cancellation id", block:
    var found = false
    for row in firstLog:
      if row{"purpose"}.getStr("") == "compaction":
        found = row{"sessionId"}.getStr("").startsWith("compaction.") and
          row{"cancelId"}.getStr("") == row{"sessionId"}.getStr("") and
          not row{"emitTokens"}.getBool(true)
    found)
  check("auxiliary compaction chat inherits the parent model/provider", block:
    var inherited = false
    for row in firstLog:
      if row{"purpose"}.getStr("") == "compaction":
        inherited = row{"model"}.getStr("") == "mock-parent-model" and
          row{"provider"}.getStr("") == "mock-provider"
    inherited)
  check("auxiliary tools retain the exact main-call descriptions and schemas", block:
    var auxiliaryTools, mainTools: JsonNode
    for row in firstLog:
      if row{"purpose"}.getStr("") == "compaction":
        auxiliaryTools = row{"tools"}
      elif row{"sessionId"}.getStr("") == convId:
        mainTools = row{"tools"}
    auxiliaryTools != nil and mainTools != nil and auxiliaryTools == mainTools and
      auxiliaryTools.len > 0 and
      auxiliaryTools[0]{"function"}{"description"}.getStr("").len > 0)
  check("auxiliary compaction chat is marked for telemetry",
        block:
          var found = false
          for row in firstLog:
            if row{"purpose"}.getStr("") == "compaction": found = true
          found)
  check("checkpoint is structured and runner-renderable",
        projection1{"checkpoint"}{"objective"}.getStr("").len > 0 and
        projection1{"renderer"}.getStr("") == "checkpoint-v1")
  check("settled snapshot input was cleaned up",
        listDocs(nc, "compaction_input", convId & ":").len == 0)
  let afterFirstCount = listDocs(nc, "message", convId & ":").len
  check("canonical history remains immutable and append-only",
        afterFirstCount > seededCount, $afterFirstCount)
  check("canonical marker still resolves after compaction", block:
    var found = false
    for item in listDocs(nc, "message", convId & ":"):
      if item{"value"}{"content"}.getStr("").contains(oldMarker): found = true
    found)

  # Manual compaction (docs/WIRE.md "Conversation controls"): a content-less
  # control call runs the same compactor with no LLM turn and no user message,
  # so a conversation can be compacted on demand rather than only at pressure.
  # A fresh conversation with the same seeded bulk proves the manual trigger
  # alone drives the commit (nothing here is near the window).
  block manualCompact:
    let manualConv = "conv-compaction-manual-" & $int(epochTime())
    putDoc(nc, "conversation", manualConv,
      %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt",
         "title": "manual compact fixture"})
    discard seedMessages(nc, manualConv, 1, 8, 2200, markFirst = false)
    # Subscribe before the call: these are the frames a UI consumes, and the
    # manual path publishes them while the control call runs.
    let statusSub = subscribeEvents(nc, "ev.session." & manualConv & ".status")
    let contextSub = subscribeEvents(nc, "ev.session." & manualConv & ".context")
    defer:
      discard natsSubscription_Unsubscribe(statusSub)
      discard natsSubscription_Unsubscribe(contextSub)
    let manual = call(nc, "core", "session",
      %*{"sessionId": manualConv, "compact": true}, 180_000)
    check("manual compact commits without an LLM turn",
          manual{"ok"}.getBool(false) and
          manual{"compacted"}.getBool(false) and
          manual{"beforeTokens"}.getInt(0) > manual{"afterTokens"}.getInt(0),
          $manual)
    let manualProjection = getDoc(nc, "context_projection", manualConv)
    check("manual compact installs a checkpoint projection",
          manualProjection != nil and
          manualProjection{"generation"}.getInt(0) == 1 and
          manualProjection{"renderer"}.getStr("") == "checkpoint-v1" and
          manualProjection{"provenance"}{"tool"}.getStr("") == "compaction_propose",
          (if manualProjection == nil: "projection missing"
           else: $manualProjection))
    check("manual compact records the manual trigger",
          manualProjection != nil and
          manualProjection{"provenance"}{"trigger"}.getStr("") == "manual",
          (if manualProjection == nil: "projection missing"
           else: $manualProjection{"provenance"}))
    check("manual compact appends no user message",
          listDocs(nc, "message", manualConv & ":").len == 16,
          $listDocs(nc, "message", manualConv & ":").len)
    check("manual compact ran no main-call chat", block:
      var mainCalls = 0
      for row in requestLog(logPath):
        if row{"sessionId"}.getStr("") == manualConv: inc mainCalls
      mainCalls == 0)

    # The context gauge reads `usedTokens` from a status frame, and the commit
    # zeroes the measured prompt size (the projection has not been through a
    # provider). Without this frame the gauge keeps the pre-compaction number
    # until the next turn — the whole point of the manual-path emission.
    var estimatedTokens = -1
    var estimatedGen = 0
    var carriedContext = false
    for ev in drainEvents(statusSub):
      if ev{"reason"}.getStr("") != "reset:compact": continue
      if ev{"estimated"}.getBool(false):
        estimatedTokens = ev{"usedTokens"}.getInt(-1)
      estimatedGen = ev{"generation"}.getInt(0)
      carriedContext = ev{"context"} != nil
    check("manual compact publishes the estimated usedTokens a gauge needs",
          estimatedTokens == manual{"afterTokens"}.getInt(-2) and
          estimatedTokens > 0 and estimatedGen == 1 and carriedContext,
          "estimated=" & $estimatedTokens & " gen=" & $estimatedGen &
          " context=" & $carriedContext)
    var sawContextReset = false
    for ev in drainEvents(contextSub):
      if ev{"reason"}.getStr("") == "reset:compact":
        sawContextReset = ev{"beforeTokens"}.getInt(0) > 0
    check("manual compact emits the reset:compact context event",
          sawContextReset)

  block truncatedManualCompact:
    coreProc.stopHard()
    var truncatedExtra = extra
    truncatedExtra.add(("NIF_MOCK_COMPACTION_LENGTH", "1"))
    coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
      root = root, extra = truncatedExtra,
      logFile = root / "var" / "test-logs" / "core-compaction-truncated.log")
    doAssert waitComponent(nc, "store"), "store did not register for truncated fixture"
    doAssert waitComponent(nc, "llm"), "llm did not register for truncated fixture"
    doAssert waitComponent(nc, "compaction"), "compaction did not register for truncated fixture"
    let truncatedConv = "conv-compaction-truncated-" & $int(epochTime())
    putDoc(nc, "conversation", truncatedConv,
      %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt",
         "title": "truncated compact fixture"})
    discard seedMessages(nc, truncatedConv, 1, 8, 2200, markFirst = false)
    let truncatedStatus = subscribeEvents(nc,
      "ev.session." & truncatedConv & ".status")
    defer: discard natsSubscription_Unsubscribe(truncatedStatus)
    let truncated = call(nc, "core", "session",
      %*{"sessionId": truncatedConv, "compact": true}, 180_000)
    check("manual compact reports a truncated summary precisely",
          not truncated{"compacted"}.getBool(true) and
          truncated{"reason"}.getStr("").contains("summary-output-truncated") and
          truncated{"status"}.getStr("").contains("Declined"), $truncated)
    # A decline must NOT announce a size: the gauge would show a number for a
    # compaction that never happened (and the old measured one stays valid).
    var declineFrames = 0
    for ev in drainEvents(truncatedStatus):
      if ev{"reason"}.getStr("") == "reset:compact" and
         ev{"estimated"}.getBool(false):
        inc declineFrames
    check("declined compaction publishes no estimated size", declineFrames == 0,
          $declineFrames)
    check("truncated compaction installs no projection",
          getDoc(nc, "context_projection", truncatedConv) == nil)
    check("truncated compaction cleans its settled snapshot",
          listDocs(nc, "compaction_input", truncatedConv & ":").len == 0)
    coreProc.stopHard()
    coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
      root = root, extra = extra,
      logFile = root / "var" / "test-logs" / "core-compaction-after-truncated.log")
    doAssert waitComponent(nc, "store"), "store did not re-register after truncated fixture"
    doAssert waitComponent(nc, "llm"), "llm did not re-register after truncated fixture"
    doAssert waitComponent(nc, "compaction"), "compaction did not re-register after truncated fixture"

  # Append new canonical history behind the committed high-water mark, then
  # kill the entire harness. The restarted session runner must rebuild from
  # projection1 + retained canonical + these >canonicalHigh appends, never
  # replay projection1's covered span.
  var highest = 0
  for item in listDocs(nc, "message", convId & ":"):
    let id = item{"id"}.getStr("")
    let colon = id.rfind(':')
    if colon >= 0:
      try: highest = max(highest, parseInt(id[colon + 1 .. ^1]))
      except ValueError: discard
  discard seedMessages(nc, convId, highest + 1, 7, 2200, markFirst = false)
  let logBeforeRestart = requestLog(logPath).len
  coreProc.stopHard()
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-compaction-restart.log")
  doAssert waitComponent(nc, "store"), "store did not re-register"
  doAssert waitComponent(nc, "llm"), "mock llm did not re-register"
  doAssert waitComponent(nc, "compaction"), "compaction did not re-register"

  let second = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "CURRENT-OBJECTIVE-GEN2"}, 180_000)
  check("turn resumes cleanly after projection commit + runner crash",
        second{"turnError"}.getStr("").len == 0,
        second{"turnError"}.getStr(""))
  let projection2 = getDoc(nc, "context_projection", convId)
  check("second compaction advances the durable generation",
        projection2 != nil and projection2{"generation"}.getInt(0) == 2,
        (if projection2 == nil: "projection missing" else: $projection2))
  check("second checkpoint absorbs the first checkpoint",
        projection2{"checkpoint"}{"objective"}.getStr("").contains(
          "<context_checkpoint generation=\"1\""),
        projection2{"checkpoint"}{"objective"}.getStr(""))
  let currentRecall = call(nc, "recall", "context_recall",
    %*{"ref": {"source": "checkpoint", "id": convId & "#ck2"}}, 15_000)
  check("checkpoint recall resolves the durable current projection",
        currentRecall{"ok"}.getBool(false) and
        currentRecall{"generation"}.getInt(0) == 2 and
        currentRecall{"checkpoint"}{"objective"}.getStr("") ==
          projection2{"checkpoint"}{"objective"}.getStr(""), $currentRecall)
  let oldRecall = call(nc, "recall", "context_recall",
    %*{"ref": {"source": "checkpoint", "id": convId & "#ck1"}}, 15_000)
  check("superseded checkpoint refs fail clearly after absorption",
        not oldRecall{"ok"}.getBool(true) and
        oldRecall{"error"}.getStr("").contains("superseded"), $oldRecall)
  let logAfter = requestLog(logPath)
  var reloadedCheckpoint = false
  var resurrectedCovered = false
  var postRestartLog: seq[string]
  for i in logBeforeRestart ..< logAfter.len:
    postRestartLog.add($logAfter[i])
    if logAfter[i]{"checkpoint"}.getBool(false): reloadedCheckpoint = true
    # The compaction auxiliary call sees checkpoint1 and newly appended bulk,
    # but never the generation-1 covered marker: reload began at covered.to.
    if logAfter[i]{"historyMarker"}.getBool(false): resurrectedCovered = true
  check("post-restart provider requests contain the durable checkpoint",
        reloadedCheckpoint)
  check("covered canonical bulk was not resurrected after restart",
        not resurrectedCovered,
        "covered1=" & (if projection1 == nil: "missing"
                       else: $projection1{"covered"}) &
        " log=" & postRestartLog.join(" | "))
  check("second settled snapshot was cleaned up",
        listDocs(nc, "compaction_input", convId & ":").len == 0)

  # A corrupt projection is never silently ignored in favor of replaying its
  # canonical transcript. The fresh runner returns the stable recoverable
  # error before any provider call (§6.2).
  let corruptId = "conv-corrupt-projection-" & $int(epochTime())
  putDoc(nc, "conversation", corruptId,
    %*{"createdAt": epochTime(), "systemPrompt": "sys"})
  putDoc(nc, "message", corruptId & ":000001",
    %*{"role": "user", "content": "must not silently replay"})
  putDoc(nc, "context_projection", corruptId,
    %*{"version": 1, "generation": 1, "canonicalHigh": 1,
       "renderer": "unknown-renderer", "checkpoint": {},
       "covered": {"from": corruptId & ":000001",
                   "to": corruptId & ":000001"},
       "retained": [corruptId & ":000001"], "prunes": []})
  let corrupt = call(nc, "core", "session",
    %*{"sessionId": corruptId, "content": "continue"}, 30_000)
  check("corrupt projection fails with explicit recovery-required",
        corrupt{"error"}.getStr("").contains("context-recovery-required"),
        $corrupt)

  # Headline autonomous-turn case: no older user turn exists. Eight complete
  # large tool groups force middle-span cuts after the latest request. The
  # request remains canonical/retained verbatim while checkpoints absorb old
  # groups; every provider request stays within the enforcing mock's window.
  coreProc.stopHard()
  var autonomousExtra = extra
  autonomousExtra.add(("NIF_MOCK_ROUNDS", "8"))
  autonomousExtra.add(("NIF_MOCK_TOOLCMD",
    "head -c 30000 /dev/zero | tr '\\0' 'z'"))
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = autonomousExtra,
    logFile = root / "var" / "test-logs" / "core-compaction-autonomous.log")
  doAssert waitComponent(nc, "store"), "store did not register for autonomous fixture"
  doAssert waitComponent(nc, "llm"), "mock llm did not register for autonomous fixture"
  doAssert waitComponent(nc, "compaction"), "compaction did not register for autonomous fixture"
  let autonomousId = "conv-autonomous-" & $int(epochTime())
  let logBeforeAutonomous = requestLog(logPath).len
  let autonomous = call(nc, "core", "session",
    %*{"sessionId": autonomousId,
       "content": "AUTONOMOUS-OBJECTIVE-MUST-STAY-VISIBLE",
       "tools": ["bash"]}, 240_000)
  check("one autonomous multi-tool turn compacts and completes",
        autonomous{"turnError"}.getStr("").len == 0 and
        autonomous{"reply"}.getStr("").contains(
          "AUTONOMOUS-OBJECTIVE-MUST-STAY-VISIBLE"),
        "error=" & autonomous{"turnError"}.getStr("") &
        " reply=" & autonomous{"reply"}.getStr(""))
  let autonomousProjection = getDoc(nc, "context_projection", autonomousId)
  check("autonomous compaction committed a middle-span projection",
        autonomousProjection != nil and
        autonomousProjection{"generation"}.getInt(0) >= 1 and
        seqOf(autonomousProjection{"covered"}{"from"}.getStr("")) > 1,
        (if autonomousProjection == nil: "projection missing"
         else: $autonomousProjection{"covered"}))
  check("latest autonomous user request remains retained canonically", block:
    var found = false
    if autonomousProjection != nil:
      for id in autonomousProjection{"retained"}:
        if id.getStr("") == autonomousId & ":000001": found = true
    found)
  check("projection records retained prunes as executable refs",
        autonomousProjection != nil and
        autonomousProjection{"prunes"} != nil and
        autonomousProjection{"prunes"}.len > 0 and
        autonomousProjection{"prunes"}[0]{"ref"}{"id"}.getStr("").len > 0 and
        autonomousProjection{"prunes"}[0]{"ref"}{"source"}.getStr("") == "spill")
  var autonomousRejected = 0
  let autonomousLog = requestLog(logPath)
  for i in logBeforeAutonomous ..< autonomousLog.len:
    if autonomousLog[i]{"rejected"}.getBool(false): inc autonomousRejected
  check("autonomous admission never sent an over-window request",
        autonomousRejected == 0, $autonomousRejected)
  coreProc.stopHard()
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-autonomous-reload.log")
  doAssert waitComponent(nc, "store"), "store did not register for middle reload"
  doAssert waitComponent(nc, "llm"), "llm did not register for middle reload"
  let autonomousReload = call(nc, "core", "session",
    %*{"sessionId": autonomousId, "content": "AFTER-MIDDLE-RELOAD"}, 180_000)
  check("middle-span projection reloads after a runner restart",
        autonomousReload{"error"}.getStr("").len == 0 and
        autonomousReload{"turnError"}.getStr("").len == 0,
        $autonomousReload)

  # Cancellation during the auxiliary stream: the core publishes
  # cancel.compaction, the default component relays it to the distinct
  # llm.cancel.<cancelId>, and no projection is committed.
  coreProc.stopHard()
  var cancelExtra = extra
  cancelExtra.add(("NIF_MOCK_COMPACTION_SLEEP_MS", "8000"))
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = cancelExtra,
    logFile = root / "var" / "test-logs" / "core-compaction-cancel.log")
  doAssert waitComponent(nc, "store"), "store did not register for cancel fixture"
  doAssert waitComponent(nc, "llm"), "llm did not register for cancel fixture"
  doAssert waitComponent(nc, "compaction"), "compaction did not register for cancel fixture"
  let cancelConv = "conv-compaction-cancel-" & $int(epochTime())
  putDoc(nc, "conversation", cancelConv,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  discard seedMessages(nc, cancelConv, 1, 8, 2200)
  var cancelEnv = newStringTable()
  cancelEnv["NIF_NATS_URL"] = url
  cancelEnv["NIF_ROOT"] = root
  cancelEnv["PATH"] = getEnv("PATH")
  let cancelCall = startProcess(sandbox.sandboxBin("cli"),
    args = @["call", "session", $ %*{
      "sessionId": cancelConv, "content": "CANCEL-ME",
      "tools": ["bash"]}], env = cancelEnv,
    options = {poStdErrToStdOut, poUsePath})
  sleep(1200)
  let cancelAt = epochTime()
  nc.publish("svc.session." & cancelConv & ".steer",
    Envelope(v: 1, id: "cancel-compaction", kind: ekEvent,
      payload: %*{"__cancel": true}).encode())
  discard cancelCall.waitForExit(10_000)
  let cancelOutput = cancelCall.outputStream.readAll()
  let cancelDuration = epochTime() - cancelAt
  cancelCall.close()
  check("compaction cancellation aborts the auxiliary call promptly",
        cancelDuration < 6.0 and cancelOutput.contains("cancel"),
        "took " & $cancelDuration & "s: " & cancelOutput[0 ..< min(cancelOutput.len, 500)])
  check("cancelled compaction leaves no projection",
        getDoc(nc, "context_projection", cancelConv) == nil)

  # §8 negative case: a concurrent projection writer wins the optimistic
  # commit. A foreign generation lands during the auxiliary window; the
  # runner must decline (never overwrite), leave the foreign record
  # byte-identical, clean the snapshot, and still finish the turn on the
  # deterministic trim rung.
  let conflictConv = "conv-compaction-conflict-" & $int(epochTime())
  putDoc(nc, "conversation", conflictConv,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  discard seedMessages(nc, conflictConv, 1, 8, 2200)
  var conflictEnv = newStringTable()
  conflictEnv["NIF_NATS_URL"] = url
  conflictEnv["NIF_ROOT"] = root
  conflictEnv["PATH"] = getEnv("PATH")
  let conflictCall = startProcess(sandbox.sandboxBin("cli"),
    args = @["call", "session", $ %*{
      "sessionId": conflictConv, "content": "CONFLICT-ME",
      "tools": ["bash"]}], env = conflictEnv,
    options = {poStdErrToStdOut, poUsePath})
  var conflictWindow = false
  for i in 0 ..< 100:
    if listDocs(nc, "compaction_input", conflictConv & ":").len > 0:
      conflictWindow = true
      break
    sleep(100)
  check("conflict scenario reached the compaction window", conflictWindow)
  let foreignRecord = %*{"generation": 7, "renderer": "checkpoint-v1",
                         "note": "foreign concurrent writer"}
  putDoc(nc, "context_projection", conflictConv, foreignRecord)
  discard conflictCall.waitForExit(120_000)
  let conflictOutput = conflictCall.outputStream.readAll()
  conflictCall.close()
  let conflictAfter = getDoc(nc, "context_projection", conflictConv)
  var conflictResult: JsonNode
  try: conflictResult = parseJson(conflictOutput)
  except CatchableError: discard
  check("concurrent projection writer wins; runner declines without overwrite",
        conflictAfter != nil and conflictAfter == foreignRecord and
        conflictAfter{"generation"}.getInt(0) == 7,
        $conflictAfter)
  check("conflicted turn still completed on the trim rung",
        conflictResult != nil and
        conflictResult{"reply"}.getStr("").len > 0 and
        not conflictOutput.contains("context-recovery-required"),
        conflictOutput[0 ..< min(conflictOutput.len, 400)])
  check("conflicted attempt cleaned its snapshot input",
        listDocs(nc, "compaction_input", conflictConv & ":").len == 0)

  # §8 negative case: a real steering message (content, not __cancel)
  # published while the auxiliary call is in flight. It is append-only
  # history: folded after settlement, re-admitted with the checkpoint, and
  # never covered by the projection's cut.
  let steerConv = "conv-compaction-steer-" & $int(epochTime())
  putDoc(nc, "conversation", steerConv,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  discard seedMessages(nc, steerConv, 1, 8, 2200)
  var steerEnv = newStringTable()
  steerEnv["NIF_NATS_URL"] = url
  steerEnv["NIF_ROOT"] = root
  steerEnv["PATH"] = getEnv("PATH")
  let steerCall = startProcess(sandbox.sandboxBin("cli"),
    args = @["call", "session", $ %*{
      "sessionId": steerConv, "content": "STEER-HOST-TURN",
      "tools": ["bash"]}], env = steerEnv,
    options = {poStdErrToStdOut, poUsePath})
  var steerWindow = false
  for i in 0 ..< 100:
    if listDocs(nc, "compaction_input", steerConv & ":").len > 0:
      steerWindow = true
      break
    sleep(100)
  check("steer scenario reached the compaction window", steerWindow)
  nc.publish("svc.session." & steerConv & ".steer",
    Envelope(v: 1, id: "steer-during-compaction", kind: ekEvent,
      payload: %*{"content": "focus on the summary metrics"}).encode())
  discard steerCall.waitForExit(120_000)
  let steerOutput = steerCall.outputStream.readAll()
  steerCall.close()
  var steerResult: JsonNode
  try: steerResult = parseJson(steerOutput)
  except CatchableError: discard
  var steerMsgId = ""
  for item in listDocs(nc, "message", steerConv & ":"):
    if item{"value"}{"content"}.getStr("").startsWith(
        "Steer: focus on the summary metrics"):
      steerMsgId = item{"id"}.getStr("")
  let steerProjection = getDoc(nc, "context_projection", steerConv)
  check("steer published during compaction is folded canonically",
        steerMsgId.len > 0 and steerResult != nil and
        steerResult{"reply"}.getStr("").len > 0,
        "steerId=" & steerMsgId & " out=" &
        steerOutput[0 ..< min(steerOutput.len, 300)])
  check("steering did not block the compaction commit",
        steerProjection != nil and
        steerProjection{"generation"}.getInt(0) == 1 and
        steerProjection{"renderer"}.getStr("") == "checkpoint-v1",
        $steerProjection)
  check("projection cut excludes the folded steer message",
        steerMsgId > steerProjection{"covered"}{"to"}.getStr(""),
        steerMsgId & " vs " & $steerProjection{"covered"})
  block:
    var foldedInProviderRequest = false
    for entry in requestLog(logPath):
      if entry{"sessionId"}.getStr("") == steerConv and
          entry{"purpose"}.getStr("") == "" and
          entry{"steer"}.getBool(false) and
          entry{"checkpoint"}.getBool(false) and
          not entry{"rejected"}.getBool(false):
        foldedInProviderRequest = true
    check("post-compaction provider request carries checkpoint and steer",
          foldedInProviderRequest)

  # Interchangeability/conformance: keep the projection produced by the
  # default implementation, replace the selected tool with the deterministic
  # fixture under another name, restart the runner, and compact the same
  # conversation again. The fixture owns no store/projection writes; the
  # runner must still enforce the identical commit/reload contract.
  coreProc.stopHard()
  var fixtureExtra = extra
  fixtureExtra.add(("NIF_COMPACTION_TOOL", "fixture_compaction_propose"))
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = fixtureExtra,
    logFile = root / "var" / "test-logs" / "core-compaction-fixture.log")
  doAssert waitComponent(nc, "store"), "store did not register for fixture conformance"
  doAssert waitComponent(nc, "llm"), "llm did not register for fixture conformance"
  fixtureProc = startComponent(sandbox.sandboxBin("fixture-compaction"), url,
    root = root, extra = @[("NIF_FIXTURE_CHECKPOINT_ONLY", "1")],
    logFile = root / "var" / "test-logs" / "fixture-compaction.log")
  doAssert waitComponent(nc, "fixture-compaction"),
    "fixture compactor did not register after restart; running=" & $fixtureProc.running() &
    " log=" & (if fileExists(root / "var" / "test-logs" / "fixture-compaction.log"):
      readFile(root / "var" / "test-logs" / "fixture-compaction.log") else: "<missing>")
  var conformanceHigh = 0
  for item in listDocs(nc, "message", convId & ":"):
    let id = item{"id"}.getStr("")
    let colon = id.rfind(':')
    if colon >= 0:
      try: conformanceHigh = max(conformanceHigh,
                                 parseInt(id[colon + 1 .. ^1]))
      except ValueError: discard
  discard seedMessages(nc, convId, conformanceHigh + 1, 7, 2200,
                       markFirst = false)
  let fixtureTurn = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "FIXTURE-COMPACTOR-TURN",
       "tools": ["bash"]}, 180_000)
  let fixtureProjection = getDoc(nc, "context_projection", convId)
  check("fixture compactor passes the same runner contract",
        fixtureTurn{"turnError"}.getStr("").len == 0 and
        fixtureProjection != nil and
        fixtureProjection{"generation"}.getInt(0) == 3 and
        fixtureProjection{"provenance"}{"tool"}.getStr("") ==
          "fixture_compaction_propose" and
        fixtureProjection{"checkpoint"}{"objective"}.getStr("") ==
          "fixture-compactor-installed",
        $fixtureTurn & " / " & $fixtureProjection)
  check("projection written by the default compactor reloads under fixture",
        fixtureProjection{"renderer"}.getStr("") == "checkpoint-v1" and
        fixtureProjection{"covered"}{"from"}.getStr("").len > 0)

  check("checkpoint-only replacement records canonical coverage endpoints",
    fixtureProjection{"covered"}{"from"}.getStr("").startsWith(convId & ":") and
    fixtureProjection{"covered"}{"to"}.getStr("").startsWith(convId & ":"))
  stopHard(fixtureProc)
  coreProc.stopHard()
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = fixtureExtra,
    logFile = root / "var" / "test-logs" / "core-checkpoint-only-reload.log")
  doAssert waitComponent(nc, "store") and waitComponent(nc, "llm")
  let checkpointOnlyReload = call(nc, "core", "session", %*{
    "sessionId": convId, "content": "AFTER-CHECKPOINT-ONLY-REPLACEMENT"}, 180_000)
  check("checkpoint-only replacement survives a runner restart",
    checkpointOnlyReload{"ok"}.getBool(false) and
    checkpointOnlyReload{"turnError"}.getStr("").len == 0,
    $checkpointOnlyReload)

  # §8 negative case: a component that ignores its granted auxiliary budget.
  # The fixture reports provenance.llmCalls = 99 against a budget of 4; the
  # runner must reject the candidate as invalid, commit nothing, and still
  # complete the turn on the deterministic trim rung.
  stopHard(fixtureProc)
  coreProc.stopHard()
  var liarExtra = extra
  liarExtra.add(("NIF_COMPACTION_TOOL", "fixture_compaction_propose"))
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = liarExtra,
    logFile = root / "var" / "test-logs" / "core-compaction-liar.log")
  doAssert waitComponent(nc, "store"), "store did not register for liar fixture"
  doAssert waitComponent(nc, "llm"), "llm did not register for liar fixture"
  fixtureProc = startComponent(sandbox.sandboxBin("fixture-compaction"), url,
    root = root, extra = @[("NIF_FIXTURE_LLM_CALLS", "99")],
    logFile = root / "var" / "test-logs" / "fixture-compaction-liar.log")
  doAssert waitComponent(nc, "fixture-compaction"),
    "lying fixture compactor did not register; running=" & $fixtureProc.running() &
    " log=" & (if fileExists(root / "var" / "test-logs" / "fixture-compaction-liar.log"):
      readFile(root / "var" / "test-logs" / "fixture-compaction-liar.log") else: "<missing>")
  let liarConv = "conv-compaction-liar-" & $int(epochTime())
  putDoc(nc, "conversation", liarConv,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  discard seedMessages(nc, liarConv, 1, 8, 2200)
  let liarTurn = call(nc, "core", "session",
    %*{"sessionId": liarConv, "content": "LIAR-COMPACTOR-TURN",
       "tools": ["bash"]}, 180_000)
  check("candidate exceeding maxLlmCalls is rejected",
        liarTurn{"turnError"}.getStr("").len == 0 and
        getDoc(nc, "context_projection", liarConv) == nil,
        $liarTurn)
  check("budget-rejected attempt still completed the turn",
        liarTurn{"reply"}.getStr("").len > 0,
        $liarTurn)

  # Regression: a conversation that trimmed BEFORE it ever compacted used to
  # be unable to compact at all. trimTurns puts the omission notice at
  # projection index 1 and permittedCuts' preferred cut starts there, so
  # covered.from was the notice id and the commit guard refused it — silently,
  # generation after generation, while the ladder trimmed. The offered set is
  # now reconciled with the guard and the refused exit is always reported.
  stopHard(fixtureProc)
  coreProc.stopHard()
  # Phase 1: compaction disabled, so pressure runs the lossy trim rung and the
  # projection ends up notice-first with no checkpoint at all.
  var trimFirstExtra = extra
  trimFirstExtra.add(("NIF_COMPACTION_TOOL", ""))
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = trimFirstExtra,
    logFile = root / "var" / "test-logs" / "core-compaction-trimfirst.log")
  doAssert waitComponent(nc, "store"), "store did not register for trim-first fixture"
  doAssert waitComponent(nc, "llm"), "llm did not register for trim-first fixture"
  let trimFirstConv = "conv-compaction-trimfirst-" & $int(epochTime())
  putDoc(nc, "conversation", trimFirstConv,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  # Seed enough bulk that pressure trims (compaction is disabled), while what
  # survives the trim is still far larger than a checkpoint — otherwise the
  # strict-reduction check has nothing to reduce and this would test nothing.
  discard seedMessages(nc, trimFirstConv, 1, 5, 8000)
  let trimmedTurn = call(nc, "core", "session",
    %*{"sessionId": trimFirstConv, "content": "TRIM-FIRST-TURN",
       "tools": ["bash"]}, 180_000)
  check("pressure with compaction disabled completes on the trim rung",
        trimmedTurn{"turnError"}.getStr("").len == 0, $trimmedTurn)
  let trimFirstHeader = getDoc(nc, "conversation", trimFirstConv)
  check("the lossy trim recorded its watermark and committed no projection",
        getDoc(nc, "context_projection", trimFirstConv) == nil and
        trimFirstHeader != nil and
        trimFirstHeader{"trimThrough"}.getInt(0) > 0,
        (if trimFirstHeader == nil: "header missing" else: $trimFirstHeader))

  # Phase 2: compaction available again; the manual rung (no LLM turn) must
  # resolve the notice-starting cut to canonical coverage and commit.
  coreProc.stopHard()
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-compaction-after-trim.log")
  doAssert waitComponent(nc, "store"), "store did not re-register"
  doAssert waitComponent(nc, "llm"), "llm did not re-register"
  doAssert waitComponent(nc, "compaction"), "compaction did not re-register"
  let afterTrimContextSub = subscribeEvents(nc,
    "ev.session." & trimFirstConv & ".context")
  defer: discard natsSubscription_Unsubscribe(afterTrimContextSub)
  let afterTrim = call(nc, "core", "session",
    %*{"sessionId": trimFirstConv, "compact": true}, 180_000)
  let afterTrimProjection = getDoc(nc, "context_projection", trimFirstConv)
  check("a trimmed conversation can now commit a checkpoint",
        afterTrim{"ok"}.getBool(false) and
        afterTrim{"compacted"}.getBool(false) and
        afterTrimProjection != nil and
        afterTrimProjection{"generation"}.getInt(0) == 1,
        $afterTrim & " / " &
        (if afterTrimProjection == nil: "projection missing"
         else: $afterTrimProjection))
  check("the checkpoint's durable coverage is canonical, not the notice",
        afterTrimProjection != nil and
        afterTrimProjection{"covered"}{"from"}.getStr("").startsWith(
          trimFirstConv & ":") and
        afterTrimProjection{"covered"}{"to"}.getStr("").startsWith(
          trimFirstConv & ":") and
        not afterTrimProjection{"covered"}{"from"}.getStr("").contains("#omit-"),
        (if afterTrimProjection == nil: "projection missing"
         else: $afterTrimProjection{"covered"}))
  var sawTrimFirstReset = false
  for ev in drainEvents(afterTrimContextSub):
    if ev{"reason"}.getStr("") == "reset:compact": sawTrimFirstReset = true
  check("the trim-first compaction emits reset:compact", sawTrimFirstReset)
  # The committed checkpoint must also survive a restart: reload goes through
  # covered.to plus the retained canonical tail, never the notice.
  coreProc.stopHard()
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-compaction-trimfirst-reload.log")
  doAssert waitComponent(nc, "store") and waitComponent(nc, "llm") and
    waitComponent(nc, "compaction")
  let trimFirstReload = call(nc, "core", "session",
    %*{"sessionId": trimFirstConv, "content": "AFTER-TRIM-FIRST-RELOAD"},
    180_000)
  check("the trim-first checkpoint reloads after a runner restart",
        trimFirstReload{"ok"}.getBool(false) and
        trimFirstReload{"turnError"}.getStr("").len == 0, $trimFirstReload)

  # A refusal is never silent: a conversation with no permitted cut at all
  # answers the manual rung AND emits the same reason as a context event.
  let barrenConv = "conv-compaction-barren-" & $int(epochTime())
  let barrenSub = subscribeEvents(nc, "ev.session." & barrenConv & ".context")
  defer: discard natsSubscription_Unsubscribe(barrenSub)
  let barren = call(nc, "core", "session",
    %*{"sessionId": barrenConv, "compact": true}, 60_000)
  check("a conversation with no permitted cut declines the manual compact",
        barren{"ok"}.getBool(false) and
        not barren{"compacted"}.getBool(true) and
        barren{"reason"}.getStr("").contains("no permitted cut exists yet"),
        $barren)
  var sawDeclineEvent = false
  for ev in drainEvents(barrenSub):
    if ev{"reason"}.getStr("") == "compact:declined" and
        ev{"detail"}.getStr("").contains("no permitted cut"):
      sawDeclineEvent = true
  check("the declined manual compact emits the reason as a context event",
        sawDeclineEvent)

  report("COMPACTION TEST")

when isMainModule:
  main()
