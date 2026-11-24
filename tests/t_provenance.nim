## provenance — issue #101 end-to-end: a command dispatched inside a live turn
## is handed the turn's RESOLVED identity through the child-process
## environment.
##
## The unit-level contract (injection shape, absence of unresolved values,
## scope to session-dispatched calls, harness ownership) is pinned in
## tests/t_bash.nim. This file proves the half a unit test cannot: that the
## RUNNER actually fills those fields from its own resolution, so a command
## reporting `$NIF_MODEL` tells the truth about the model that drove it.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc compileMock(llmBin, repoRoot: string) =
  let p = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & llmBin, repoRoot / "tests" / "mock_parallel_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  if waitForExit(p, fixtureCompileTimeoutMs) != 0:
    fail("mock llm failed to compile")
    quit(1)

proc toolMessages(nc: NatsConnection, sessionId: string): seq[JsonNode] =
  let listed = call(nc, "store", "list",
    %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 200}, 10_000)
  for item in listed{"items"}:
    if item{"value"}{"role"}.getStr("") == "tool":
      result.add(item{"value"})

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let sandbox = newCoreSandbox("provenance",
    ["store", "bash", "builder", "llm", "systemprompt"])
  let keep = getEnv("NIF_KEEP_SANDBOX") == "1"
  defer:
    if not keep: removeDir(sandbox.root)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  compileMock(sandbox.sandboxBin("llm"), repoRoot)

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = @[("NIF_AUTO_APPROVE", "1"),
              ("NIF_MOCK_SCENARIO", "provenance")],
    logFile = sandbox.root / "var" / "provenance-core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(500)
      if coreProc.running(): coreProc.kill()
    if coreProc != nil: coreProc.close()

  var up = false
  for i in 0 ..< 150:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      up = true
      break
    sleep(200)
  check("core up", up)
  if not up:
    report("PROVENANCE")
    return

  let sessionId = "provenance-e2e-" & $int(epochTime())
  let turn = call(nc, "core", "session",
    %*{"sessionId": sessionId, "cwd": sandbox.root, "content": "go"}, 120_000)
  check("the turn completes", turn{"error"} == nil, $turn)

  let msgs = toolMessages(nc, sessionId)
  var bashMsg: JsonNode = nil
  for m in msgs:
    if m{"name"}.getStr("") == "bash": bashMsg = m
  check("the bash call produced a tool result", bashMsg != nil, $msgs.len)
  if bashMsg != nil:
    let cmdOut = bashMsg{"content"}.getStr("")
    # The session id is the one the turn actually ran under — a command can
    # now call back into the harness without a model-pasted id.
    check("a live turn exports NIF_SESSION_ID to its command",
          cmdOut.contains("SID=[" & sessionId & "]"), cmdOut)
    # The mock llm answers with model "mock-model", so the RESOLVED model is
    # exactly that — and the value must come from the runner's resolution,
    # not from this test's process environment.
    check("the command sees the model the turn actually used",
          cmdOut.contains("MODEL=[mock-model]"), cmdOut)
    check("the command's provider field is populated or absent, never bogus",
          not cmdOut.contains("PROVIDER=[DECOY]"), cmdOut)

  report("PROVENANCE")

main()
