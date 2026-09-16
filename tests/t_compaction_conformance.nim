## Contract-v1 conformance runner for replaceable compaction components
## (docs/research/COMPACTION.md §8.7). It proves that ANY implementation
## registering the selected proposal tool meets the runner contract —
## without reading core/: propose → strict validation → checkpoint-v1
## render → optimistic commit → restart reload → second generation.
##
## Suite default — proves the shipped component still conforms:
##   make test-conformance
##
## Third-party component:
##   nim c --path:sdk -o:conformance tests/t_compaction_conformance.nim
##   ./conformance --bin:/path/to/your-component --tool:your_tool_name
##
## Needs a niffler checkout with `make build` done (sandbox binaries are
## copied from var/bin); point NIF_REPO_ROOT at it when running elsewhere.
## The deterministic mock LLM enforces a 16k provider window, so a finished
## turn also proves no request was sent over-window.
##
## Asserted here:
##   1. the candidate is validated and committed (generation 1, renderer
##      checkpoint-v1, provenance.tool = the selected tool, cut recorded)
##   2. canonical history stays immutable and append-only
##   3. the temporary compaction_input snapshot is cleaned up
##   4. a runner restart reloads the committed checkpoint (turn completes)
##   5. a second compaction advances the generation (absorbing the first)
##      and the advanced projection still reloads
## Exit 0 = conforming; 1 = a check failed (printed).

import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc stopHard(p: var Process) =
  if p != nil and p.running():
    p.terminate()
    sleep(800)
    if p.running(): p.kill()
    sleep(300)
  if p != nil: p.close()
  p = nil

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
                  bodyBytes: int): int =
  result = firstSeq
  for pair in 0 ..< pairs:
    putDoc(nc, "message", convId & ":" & align($result, 6, '0'),
      %*{"role": "user",
         "content": "conformance objective " & $pair & " " &
                    repeat("u", bodyBytes),
         "conversationId": convId, "createdAt": epochTime()})
    inc result
    putDoc(nc, "message", convId & ":" & align($result, 6, '0'),
      %*{"role": "assistant",
         "content": "conformance result " & $pair & " " &
                    repeat("a", bodyBytes),
         "conversationId": convId, "createdAt": epochTime()})
    inc result

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for i in 0 ..< secs * 5:
    try:
      let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
      if snap{"components"}{name} != nil: return true
    except CatchableError:
      discard
    sleep(200)

proc waitTool(nc: NatsConnection, tool: string, secs = 30): bool =
  ## The proposal tool is hidden, so the direct `list` projection and the
  ## on-demand schemas op never show it (no existence oracle). The full
  ## registration snapshot is what session runners seed their catalog from
  ## and it keeps hidden tools — poll that.
  for i in 0 ..< secs * 5:
    try:
      let r = call(nc, "core", "catalog", %*{"op": "snapshot"}, 5_000)
      if ($r).contains("\"" & tool & "\""): return true
    except CatchableError:
      discard
    sleep(200)

proc main() =
  var binDir = ""
  var toolName = "compaction_propose"
  for arg in commandLineParams():
    if arg.startsWith("--bin:"): binDir = arg["--bin:".len .. ^1]
    elif arg.startsWith("--tool:"): toolName = arg["--tool:".len .. ^1]
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))
  if binDir.len == 0:
    binDir = repoRoot / "var" / "bin" / "compaction"
  if not fileExists(binDir):
    fail("component binary not found: " & binDir)
    quit(1)
  for name in ["niffler", "session", "store", "bash", "cli"]:
    if not fileExists(repoRoot / "var" / "bin" / name):
      fail("missing " & name & " binary in " & repoRoot &
           " — run `make build` first")
      quit(1)

  let sandbox = newCoreSandbox("compaction-conformance",
    ["store", "bash", "llm"])
  let root = sandbox.root
  # NIF_CONF_KEEP=1 spares the sandbox for inspecting a failed run.
  let keepRoot = getEnv("NIF_CONF_KEEP", "0") == "1"
  defer:
    if not keepRoot: removeDir(root)
  # The deterministic mock llm replaces the copied real one in the sandbox.
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off", "--path:" & repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"), repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, 120_000) != 0:
    fail("mock llm failed to compile")
    quit(1)
  compiler.close()

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let extra = @[
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MOCK_CTX", "16000"),
    ("NIF_CTX_RESERVE", "7000"),
    ("NIF_COMPACTION_TOOL", toolName)]
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-conformance.log")
  defer: coreProc.stopHard()
  doAssert waitComponent(nc, "store"), "store did not register"
  doAssert waitComponent(nc, "llm"), "mock llm did not register"
  # The component under test is started exactly like any user component.
  var compProc = startComponent(binDir, url, root = root, extra = @[],
    logFile = root / "var" / "test-logs" / "component-under-test.log")
  defer: compProc.stopHard()
  doAssert waitTool(nc, toolName),
    "proposal tool \"" & toolName & "\" never registered"

  let convId = "conv-conformance-" & $int(epochTime())
  putDoc(nc, "conversation", convId,
    %*{"createdAt": epochTime(), "systemPrompt": "Small frozen system prompt"})
  discard seedMessages(nc, convId, 1, 8, 2200)
  # Sample canonical bodies before the turn; immutability is checked below.
  var seededSamples: seq[tuple[id: string, body: JsonNode]]
  let allSeeded = listDocs(nc, "message", convId & ":")
  for idx in [0, allSeeded.len div 2, allSeeded.len - 1]:
    let id = allSeeded[idx]{"id"}.getStr("")
    seededSamples.add((id, getDoc(nc, "message", id)))

  let turn = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "CONFORMANCE-TURN",
       "tools": ["bash"]}, 180_000)
  let projection = getDoc(nc, "context_projection", convId)
  check("pressured turn completes against the component under test",
        turn{"turnError"}.getStr("").len == 0 and
        turn{"reply"}.getStr("").len > 0, $turn)
  check("candidate committed as a generation-1 checkpoint-v1 projection",
        projection != nil and
        projection{"generation"}.getInt(0) == 1 and
        projection{"renderer"}.getStr("") == "checkpoint-v1" and
        projection{"provenance"}{"tool"}.getStr("") == toolName and
        projection{"covered"}{"from"}.getStr("").len > 0 and
        projection{"checkpoint"}{"objective"}.getStr("").len > 0,
        (if projection == nil: "missing projection" else: $projection))
  check("covered range is present and ordered",
        projection{"covered"}{"from"}.getStr("").len > 0 and
        projection{"covered"}{"to"}.getStr("").len > 0 and
        projection{"covered"}{"from"}.getStr("") <=
          projection{"covered"}{"to"}.getStr(""),
        (if projection == nil: "missing projection" else: $projection{"covered"}))
  var immutable = true
  for sample in seededSamples:
    let now = getDoc(nc, "message", sample.id)
    if now != sample.body: immutable = false
  check("canonical history stayed byte-identical under compaction",
        immutable)
  check("temporary compaction_input snapshot was cleaned up",
        listDocs(nc, "compaction_input", convId & ":").len == 0)

  # Restart the full test stack, including the externally launched component.
  # It is not in the sandbox manifest, so this test owns its restart.
  proc restartStack(tag: string) =
    coreProc.stopHard()
    compProc.stopHard()
    coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
      root = root, extra = extra,
      logFile = root / "var" / "test-logs" / tag)
    doAssert waitComponent(nc, "store"), "store did not register for " & tag
    doAssert waitComponent(nc, "llm"), "mock llm did not register for " & tag
    compProc = startComponent(binDir, url, root = root, extra = @[],
      logFile = root / "var" / "test-logs" / tag & "-component.log")
    doAssert waitTool(nc, toolName),
      "proposal tool never registered for " & tag

  restartStack("core-conformance-reload")
  let reloadTurn = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "CONFORMANCE-RELOAD-TURN"}, 180_000)
  check("runner restart reloads the committed checkpoint",
        reloadTurn{"turnError"}.getStr("").len == 0 and
        reloadTurn{"reply"}.getStr("").len > 0, $reloadTurn)

  # Fresh pressure beyond the checkpoint: a second compaction must advance
  # the durable generation (absorbing the first checkpoint) and reload.
  # The batch is seeded while no runner is live — canonical history is read
  # at runner start, so the next runner's ledger begins with it.
  restartStack("core-conformance-second")
  var canonicalHigh = 0
  for item in listDocs(nc, "message", convId & ":"):
    let id = item{"id"}.getStr("")
    let colon = id.rfind(':')
    if colon >= 0:
      try: canonicalHigh = max(canonicalHigh, parseInt(id[colon + 1 .. ^1]))
      except ValueError: discard
  discard seedMessages(nc, convId, canonicalHigh + 1, 7, 2200)
  let secondTurn = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "CONFORMANCE-SECOND-TURN"}, 180_000)
  let projection2 = getDoc(nc, "context_projection", convId)
  check("second compaction advances the durable generation",
        secondTurn{"turnError"}.getStr("").len == 0 and
        projection2 != nil and
        projection2{"generation"}.getInt(0) == 2,
        $secondTurn & " / " &
        (if projection2 == nil: "missing projection" else: $projection2))
  check("second projection still renders checkpoint-v1 with a real cut",
        projection2{"renderer"}.getStr("") == "checkpoint-v1" and
        projection2{"covered"}{"from"}.getStr("").len > 0,
        (if projection2 == nil: "missing projection" else: $projection2))

  restartStack("core-conformance-final-reload")
  let finalReload = call(nc, "core", "session", %*{
    "sessionId": convId, "content": "CONFORMANCE-FINAL-RELOAD"}, 180_000)
  check("advanced projection also reloads after restart",
    finalReload{"ok"}.getBool(false) and
    finalReload{"turnError"}.getStr("").len == 0 and
    finalReload{"reply"}.getStr("").len > 0, $finalReload)

  report("CONFORMANCE TEST")

when isMainModule:
  main()
