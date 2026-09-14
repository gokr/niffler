## t_compaction — replaceable compaction seam integration (§4–§8).
##
## Uses the enforcing deterministic mock LLM and real SQLite store/core/
## session runner/default compactor. It proves candidate commit, temporary
## snapshot cleanup, canonical immutability, projection reload after a runner
## crash, and a second compaction that absorbs the first checkpoint.

import std/[json, os, osproc, strutils, times]
import natsnim
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
  # Replace llm in the immutable binary snapshot with the deterministic mock.
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off", "--path:" & repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"), repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, 120_000) != 0:
    fail("mock llm failed to compile")
    quit(1)
  compiler.close()

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
       "modelOverride": "", "title": "compaction fixture"})
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

  echo "COMPACTION TEST PASSED"

when isMainModule:
  main()
