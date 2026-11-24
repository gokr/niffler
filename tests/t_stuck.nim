## stuck — issue #135: a turn that keeps making the same call with the same
## result must end `stuck`, not burn the round budget and then blame it.
##
## Two halves, because the second is where a naive detector does damage:
##   1. "stuck"   — one call, identical result every round: the turn ends
##                  `stuck`, well below the 1000-round cap, naming the call,
##                  after exactly one steer.
##   2. "stuck-progress" — the SAME call whose result CHANGES each round (a
##                  counter file): a legitimate poll. The turn must not end
##                  `stuck`; it runs to its own stop. This is the check that
##                  makes the feature safe — tool+args alone would kill it.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc toolMessages(nc: NatsConnection, sessionId: string): seq[JsonNode] =
  let listed = call(nc, "store", "list",
    %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 400}, 10_000)
  for item in listed{"items"}:
    if item{"value"}{"role"}.getStr("") == "tool":
      result.add(item{"value"})

proc bootCore(sandbox: TestSandbox, url, scenario: string): Process =
  result = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = @[("NIF_AUTO_APPROVE", "1"),
              ("NIF_MOCK_SCENARIO", scenario),
              # A small threshold keeps the test quick; the default is 4.
              ("NIF_STUCK_REPEATS", "3")],
    logFile = sandbox.root / "var" / ("stuck-" & scenario & "-core.log"))

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let sandbox = newCoreSandbox("stuck",
    ["store", "bash", "builder", "llm", "systemprompt"])
  let keep = getEnv("NIF_KEEP_SANDBOX") == "1"
  defer:
    if not keep: removeDir(sandbox.root)

  # The mock llm replaces the real one (same component name and chat tool).
  let llmBin = sandbox.sandboxBin("llm")
  let p = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & llmBin, repoRoot / "tests" / "mock_parallel_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  check("the mock llm compiles",
        waitForExit(p, fixtureCompileTimeoutMs) == 0)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # --- 1. a repeating call with a repeating result ends `stuck` -----------
  block looping:
    var coreProc = bootCore(sandbox, url, "stuck")
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
      report("STUCK")
      return

    let sessionId = "stuck-loop-" & $int(epochTime())
    let started = epochTime()
    let turn = call(nc, "core", "session",
      %*{"sessionId": sessionId, "cwd": sandbox.root, "content": "go"},
      120_000)
    let elapsed = epochTime() - started
    let err = turn{"turnError"}.getStr("")
    check("the looping turn ends, it does not hang", turn{"error"} == nil, $turn)
    check("the turn ends `stuck`, not budget-exhausted",
          turn{"outcome"}.getStr("") == "stuck" and
          not err.contains("round budget"), $turn)
    check("the terminal error names the repeated call and says no progress",
          err.contains("no progress") and err.contains("bash") and
          err.contains("identical"), err)
    check("it ends far below the 1000-round cap (" & $int(elapsed) & "s)",
          elapsed < 90.0, $turn)

    # One steer, then death — not a silent kill and not an endless steer loop.
    # The line is emitted by the SESSION RUNNER (a separate process), not core,
    # so read the runner's own log rather than the core's.
    var log = ""
    for f in walkFiles(sandbox.root / "var" / "logs" / "session-*.log"):
      log.add(readFile(f))
    let steers = log.count("steered the turn away")
    check("exactly one steer was spent before ending (got " & $steers & ")",
          steers == 1, log[^600 .. ^1])

    # The repeated call really ran that many times (so the detector fired on
    # evidence, not on an empty ring).
    let msgs = toolMessages(nc, sessionId)
    check("the repeated call was dispatched more than once",
          msgs.len >= 3, $msgs.len)

  # --- 2. the SAME call with a CHANGING result is progress, not a loop ----
  block polling:
    let sandbox2 = newCoreSandbox("stuck-progress",
      ["store", "bash", "builder", "llm", "systemprompt"])
    defer:
      if not keep: removeDir(sandbox2.root)
    let llmBin2 = sandbox2.sandboxBin("llm")
    let p2 = startProcess("nim", args = [
      "c", "--hints:off", "--warnings:off",
      "--path:" & repoRoot / "sdk",
      "-o:" & llmBin2, repoRoot / "tests" / "mock_parallel_llm.nim"],
      options = {poUsePath, poStdErrToStdOut})
    p2.close()
    discard waitForExit(p2, fixtureCompileTimeoutMs)

    var coreProc = bootCore(sandbox2, url, "stuck-progress")
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
    check("core up for the polling case", up)

    let sessionId = "stuck-progress-" & $int(epochTime())
    let turn = call(nc, "core", "session",
      %*{"sessionId": sessionId, "cwd": sandbox2.root, "content": "go"},
      120_000)
    check("a poll whose result changes does NOT end `stuck`",
          turn{"outcome"}.getStr("") != "stuck", $turn)

  report("STUCK")

main()
