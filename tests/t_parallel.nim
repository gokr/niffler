## parallel-safe tool fan-out tests (B1a).
##
## When an assistant message carries several tool calls marked
## x-harness.parallel, the session runner fans them out over the bus
## (distinct inbox reply subjects, round-robin collection) and reassembles
## the results in tool_calls order. Three scenarios via a test-only mock llm
## (tests/mock_parallel_llm.nim, selected by NIF_MOCK_SCENARIO):
##   wave        — read a.txt, read b.txt, grep needle, files *.txt:
##                 all four run through the wave path; results must land in
##                 c1..c4 order with correct contents.
##   interleave  — read a.txt, bash "echo serial-ok", read b.txt:
##                 the non-parallel bash call splits the read calls into two
##                 waves; the transcript must stay c1(read), c2(bash),
##                 c3(read) — serial calls keep working inside a batch.
##   slow        — sa_slow + sb_slow, two 1s-sleeping tools on two separate
##                 spawned components: proves cross-component concurrency
##                 (the turn finishes in ~1s, not ~2s).
##   replica     — sr_slow ×8 on one logical component supervised with four
##                 process replicas: proves same-component concurrency without
##                 adding threads to the Nim SDK (pid + overlap assertions).
##   retry       — NIF_MOCK_FAIL_FIRST=2: the mock llm fails its first two
##                 chat calls with a retryable 503; the runner's B3 auto-retry
##                 must recover the turn and publish ev.session.retry events.

import std/[json, os, osproc, strutils, times]
import natswrapper
import envelope
import helpers

proc compileMock(llmBin, repoRoot, scenario: string) =
  ## Build the test-only llm stand-in into the sandbox's var/bin (replacing
  ## the copied real llm binary): same component name, same hidden chat tool.
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & llmBin,
    repoRoot / "tests" / "mock_parallel_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("mock parallel llm failed to compile")
    quit(1)

proc compileSlow(bin, src: string) =
  ## Build one slow test component (sa_slow / sb_slow) into the sandbox.
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & getEnv("NIF_REPO_ROOT",
      getEnv("NIF_ROOT", getAppDir().parentDir())) / "sdk",
    "-o:" & bin, src],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("slow component failed to compile: " & src)
    quit(1)

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc waitReplicas(nc: NatsConnection, name: string, count: int,
                  secs = 25): bool =
  ## Wait until the catalog has observed every PID in a logical replica group.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "snapshot"}, 5_000)
    let components = snap{"components"}
    if components != nil and components.kind == JArray:
      for item in components:
        if item{"name"}.getStr("") == name and
            item{"pids"} != nil and item{"pids"}.len >= count:
          return true
    sleep(200)
  return false

proc bootWithExtra(nc: NatsConnection, coreProc: var Process,
                   sandbox: TestSandbox, url: string, scenario: string,
                   extra: openArray[(string, string)]) =
  ## boot() variant that passes extra env to the core (and thus its mock llm
  ## child). The mock's NIF_MOCK_* scenario vars reach the llm through it.
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = @[("NIF_AUTO_APPROVE", "1"), ("NIF_MOCK_SCENARIO", scenario)] & @extra,
    logFile = "/tmp/niffler-t-parallel-" & scenario & ".log")
  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check(scenario & ": core up", coreUp)
  check(scenario & ": store registered", waitComponent(nc, "store"))
  check(scenario & ": mock llm registered", waitComponent(nc, "llm"))

proc stopHard(p: var Process) =
  if p != nil and p.running():
    p.terminate()
    sleep(500)
    if p.running(): p.kill()
    sleep(100)
  if p != nil: p.close()
  p = nil

proc toolMessages(nc: NatsConnection, sessionId: string): seq[JsonNode] =
  ## Transcript tool messages in store order (store key order = message order).
  let listed = call(nc, "store", "list",
    %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 200}, 10_000)
  for item in listed{"items"}:
    if item{"value"}{"role"}.getStr("") == "tool":
      result.add(item{"value"})

proc parseTime(toolMsg: JsonNode, field: string): float =
  ## Pull a float field out of a tool result's JSON content text (the runner
  ## stores the component's result as `content: $value`).
  let content = toolMsg{"content"}.getStr("")
  let marker = "\"" & field & "\":"
  let idx = content.find(marker)
  if idx < 0: return 0.0
  let rest = content[idx + marker.len .. ^1]
  var endIdx = 0
  while endIdx < rest.len and rest[endIdx] in {'0'..'9', '.', '-', 'e', 'E', '+'}:
    inc endIdx
  if endIdx == 0: return 0.0
  try:
    return parseFloat(rest[0 ..< endIdx])
  except CatchableError:
    return 0.0

proc boot(nc: NatsConnection, coreProc: var Process,
          sandbox: TestSandbox, url: string, scenario: string) =
  ## Shared sandbox boot: nats + core (with the scenario env for the mock llm
  ## child) + wait for the components the scenario needs.
  coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = sandbox.root,
                            extra = [("NIF_AUTO_APPROVE", "1"),
                                     ("NIF_MOCK_SCENARIO", scenario)],
                            logFile = "/tmp/niffler-t-parallel-" & scenario & ".log")
  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check(scenario & ": core up", coreUp)
  check(scenario & ": store registered", waitComponent(nc, "store"))
  check(scenario & ": mock llm registered", waitComponent(nc, "llm"))

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "session", "store", "edit", "grep", "bash"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)

  # ---- scenario: wave (4 parallel-safe calls) -----------------------------
  block:
    let sandbox = newCoreSandbox("parallel-wave", ["store", "edit", "grep",
                                                   "llm"])
    let root = sandbox.root
    writeFile(root / "a.txt", "AAA line one\n")
    writeFile(root / "b.txt", "needle hit\n")
    compileMock(sandbox.sandboxBin("llm"), sandbox.repoRoot, "wave")

    let (server, url) = startNats()
    var nc = waitConnect(url)
    var coreProc: Process
    boot(nc, coreProc, sandbox, url, "wave")
    defer: stopHard(coreProc)
    defer: nc.close()
    defer: stopServer(server)
    defer: removeDir(root)

    check("wave: edit registered", waitComponent(nc, "edit"))
    check("wave: grep registered", waitComponent(nc, "grep"))

    let sessionId = "conv-parallel-wave-" & $int(epochTime())
    let turn = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "content": "go"}, 120_000)
    check("wave: turn ok", turn{"error"} == nil, $turn)
    check("wave: turn reply", turn{"reply"}.getStr("") == "parallel-done",
          $turn)

    let tools = toolMessages(nc, sessionId)
    check("wave: four tool results", tools.len == 4, $tools.len)
    if tools.len == 4:
      check("wave: c1 read a.txt", tools[0]{"tool_call_id"}.getStr("") == "c1" and
            tools[0]{"name"}.getStr("") == "read" and
            ($tools[0]).contains("AAA"), $tools[0])
      check("wave: c2 read b.txt", tools[1]{"tool_call_id"}.getStr("") == "c2" and
            tools[1]{"name"}.getStr("") == "read" and
            ($tools[1]).contains("needle hit"), $tools[1])
      check("wave: c3 grep needle", tools[2]{"tool_call_id"}.getStr("") == "c3" and
            tools[2]{"name"}.getStr("") == "grep" and
            ($tools[2]).contains("needle"), $tools[2])
      check("wave: c4 files *.txt", tools[3]{"tool_call_id"}.getStr("") == "c4" and
            tools[3]{"name"}.getStr("") == "files" and
            ($tools[3]).contains("a.txt"), $tools[3])

  # ---- scenario: interleave (serial bash between two read waves) ---------
  block:
    let sandbox = newCoreSandbox("parallel-interleave",
                                 ["store", "edit", "bash", "llm"])
    let root = sandbox.root
    writeFile(root / "a.txt", "AAA line one\n")
    writeFile(root / "b.txt", "needle hit\n")
    compileMock(sandbox.sandboxBin("llm"), sandbox.repoRoot, "interleave")

    let (server, url) = startNats()
    var nc = waitConnect(url)
    var coreProc: Process
    boot(nc, coreProc, sandbox, url, "interleave")
    defer: stopHard(coreProc)
    defer: nc.close()
    defer: stopServer(server)
    defer: removeDir(root)

    check("interleave: edit registered", waitComponent(nc, "edit"))
    check("interleave: bash registered", waitComponent(nc, "bash"))

    let sessionId = "conv-parallel-il-" & $int(epochTime())
    let turn = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "content": "go"}, 120_000)
    check("interleave: turn ok", turn{"error"} == nil, $turn)
    check("interleave: turn reply", turn{"reply"}.getStr("") == "parallel-done",
          $turn)

    let tools = toolMessages(nc, sessionId)
    check("interleave: three tool results", tools.len == 3, $tools.len)
    if tools.len == 3:
      check("interleave: c1 read first",
            tools[0]{"tool_call_id"}.getStr("") == "c1" and
            tools[0]{"name"}.getStr("") == "read" and
            ($tools[0]).contains("AAA"), $tools[0])
      check("interleave: c2 bash serial middle",
            tools[1]{"tool_call_id"}.getStr("") == "c2" and
            tools[1]{"name"}.getStr("") == "bash" and
            ($tools[1]).contains("serial-ok"), $tools[1])
      check("interleave: c3 read last",
            tools[2]{"tool_call_id"}.getStr("") == "c3" and
            tools[2]{"name"}.getStr("") == "read" and
            ($tools[2]).contains("needle hit"), $tools[2])

  # ---- scenario: slow (cross-component concurrency timing) ----------------
  block:
    let sandbox = newCoreSandbox("parallel-slow", ["store", "llm"])
    let root = sandbox.root
    compileMock(sandbox.sandboxBin("llm"), sandbox.repoRoot, "slow")
    # two separate slow components, each one parallel-safe 1s-sleeping tool
    const slowSrcA = """
      import std/[os]
      import niffler/sdk
      let comp = newComponent("sa", "0.1.0")
      comp.tool(%*{"parallel": true, "timeoutMs": 30000}):
        proc sa_slow(): JsonNode =
          ## Sleep and report
          sleep(1000)
          %*{"ok": true, "which": "sa"}
      comp.run()
      """.dedent()
    const slowSrcB = """
      import std/[os]
      import niffler/sdk
      let comp = newComponent("sb", "0.1.0")
      comp.tool(%*{"parallel": true, "timeoutMs": 30000}):
        proc sb_slow(): JsonNode =
          ## Sleep and report
          sleep(1000)
          %*{"ok": true, "which": "sb"}
      comp.run()
      """.dedent()
    writeFile(root / "sa.nim", slowSrcA)
    writeFile(root / "sb.nim", slowSrcB)
    compileSlow(sandbox.sandboxBin("sa"), root / "sa.nim")
    compileSlow(sandbox.sandboxBin("sb"), root / "sb.nim")

    let (server, url) = startNats()
    var nc = waitConnect(url)
    var coreProc: Process
    boot(nc, coreProc, sandbox, url, "slow")
    defer: stopHard(coreProc)
    defer: nc.close()
    defer: stopServer(server)
    defer: removeDir(root)

    let spA = call(nc, "core", "spawn",
                   %*{"name": "sa", "binary": sandbox.sandboxBin("sa")},
                   60_000)
    check("slow: spawn sa", spA{"ok"}.getBool(false), $spA)
    let spB = call(nc, "core", "spawn",
                   %*{"name": "sb", "binary": sandbox.sandboxBin("sb")},
                   60_000)
    check("slow: spawn sb", spB{"ok"}.getBool(false), $spB)
    check("slow: sa registered", waitComponent(nc, "sa"))
    check("slow: sb registered", waitComponent(nc, "sb"))

    let sessionId = "conv-parallel-slow-" & $int(epochTime())
    # Warm the runner: a model-only session call spawns the runner process,
    # seeds its catalog and resolves the system prompt, so the timed turn
    # below measures only the tool fan-out, not runner startup.
    let warm = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "model": "mock-model"},
                    60_000)
    check("slow: runner warm (model-only)", warm{"ok"}.getBool(false), $warm)
    let t0 = epochTime()
    let turn = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "content": "go"}, 120_000)
    let dt = epochTime() - t0
    check("slow: turn ok", turn{"error"} == nil, $turn)
    check("slow: turn reply", turn{"reply"}.getStr("") == "parallel-done",
          $turn)
    # Two 1s-sleeping calls on two processes: ~1s in parallel, ~2s if the
    # runner serialized them. 1.8s is comfortably between the two.
    check("slow: cross-component concurrency (turn < 1.8s)",
          dt < 1.8, "turn took " & $dt & "s")
    let tools = toolMessages(nc, sessionId)
    check("slow: two tool results", tools.len == 2, $tools.len)
    if tools.len == 2:
      check("slow: c1 sa_slow",
            tools[0]{"tool_call_id"}.getStr("") == "c1" and
            ($tools[0]).contains("sa"), $tools[0])
      check("slow: c2 sb_slow",
            tools[1]{"tool_call_id"}.getStr("") == "c2" and
            ($tools[1]).contains("sb"), $tools[1])

  # ---- scenario: replica (same logical component concurrency) ------------
  block:
    let sandbox = newCoreSandbox("parallel-replica", ["store", "llm"])
    let root = sandbox.root
    compileMock(sandbox.sandboxBin("llm"), sandbox.repoRoot, "replica")
    const replicaSrc = """
      import std/[json, os, times]
      import niffler/sdk
      let comp = newComponent("sr", "0.1.0")
      comp.tool(%*{"parallel": true, "timeoutMs": 30000}):
        proc sr_slow(label: string): JsonNode =
          ## Sleep, then report which process served this call and when it
          ## ran, so the test can prove two handlers overlapped across
          ## process replicas.
          let started = epochTime()
          sleep(1000)
          %*{"ok": true, "label": label, "pid": getCurrentProcessId(),
             "started": started, "finished": epochTime()}
      comp.run()
      """.dedent()
    writeFile(root / "sr.nim", replicaSrc)
    compileSlow(sandbox.sandboxBin("sr"), root / "sr.nim")

    let (server, url) = startNats()
    var nc = waitConnect(url)
    var coreProc: Process
    boot(nc, coreProc, sandbox, url, "replica")
    defer: stopHard(coreProc)
    defer: nc.close()
    defer: stopServer(server)
    defer: removeDir(root)

    let spawned = call(nc, "core", "spawn",
      %*{"name": "sr", "binary": sandbox.sandboxBin("sr"), "replicas": 2},
      60_000)
    check("replica: spawn two sr processes",
          spawned{"ok"}.getBool(false) and
          spawned{"replicas"}.getInt(0) == 2, $spawned)
    check("replica: both processes registered", waitReplicas(nc, "sr", 2))

    let status = call(nc, "core", "status", newJObject(), 10_000)
    var replicaStatus: JsonNode
    if status{"components"} != nil:
      for item in status{"components"}:
        if item{"name"}.getStr("") == "sr": replicaStatus = item
    check("replica: status reports one group with two live replicas",
          replicaStatus != nil and
          replicaStatus{"replicas"}.getInt(0) == 2 and
          replicaStatus{"runningReplicas"}.getInt(0) == 2,
          $replicaStatus)

    let sessionId = "conv-parallel-replica-" & $int(epochTime())
    let warm = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "model": "mock-model"},
                    60_000)
    check("replica: runner warm (model-only)", warm{"ok"}.getBool(false), $warm)
    let turn = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "content": "go"}, 120_000)
    check("replica: turn ok", turn{"error"} == nil, $turn)
    check("replica: turn reply",
          turn{"reply"}.getStr("") == "parallel-done", $turn)
    let tools = toolMessages(nc, sessionId)
    check("replica: eight ordered tool results", tools.len == 8, $tools.len)
    if tools.len == 8:
      for i, expected in ["1", "2", "3", "4", "5", "6", "7", "8"]:
        check("replica: c" & $i & " label " & expected,
              ($tools[i]).contains("call-" & expected), $tools[i])
      # Deterministic concurrency proof instead of wall-clock timing (CI load
      # and NATS queue-group randomness make turn duration flaky). Each
      # handler reports its pid and start/finish stamps: we require (a) more
      # than one process served the wave and (b) some pair of handlers from
      # different processes overlapped. A single serial process can do neither.
      var pids: seq[int]
      type Interval = tuple[start, finish: float]
      var intervals: seq[Interval]
      for msg in tools:
        let pid = parseTime(msg, "pid").int
        let start = parseTime(msg, "started")
        let finish = parseTime(msg, "finished")
        if pid > 0 and start > 0:
          if pid notin pids: pids.add(pid)
          intervals.add((start, finish))
      check("replica: more than one process served the wave", pids.len > 1,
            "pids seen: " & $pids)
      var overlappedAcrossProcesses = false
      for a in 0 ..< intervals.len:
        for b in a + 1 ..< intervals.len:
          if intervals[a].start < intervals[b].finish and
             intervals[b].start < intervals[a].finish:
            overlappedAcrossProcesses = true
      check("replica: same-component handlers overlapped across replicas",
            overlappedAcrossProcesses, $intervals)

    let killed = call(nc, "core", "kill", %*{"name": "sr"}, 60_000)
    check("replica: kill removes the whole supervised group",
          killed{"ok"}.getBool(false), $killed)
    let afterKill = call(nc, "core", "status", newJObject(), 10_000)
    var stillSupervised = false
    if afterKill{"components"} != nil:
      for item in afterKill{"components"}:
        if item{"name"}.getStr("") == "sr": stillSupervised = true
    check("replica: no process remains after group kill", not stillSupervised,
          $afterKill)

  # ---- scenario: retry (B3 auto-retry of transient LLM failures) ---------
  block:
    let sandbox = newCoreSandbox("parallel-retry", ["store", "llm"])
    let root = sandbox.root
    compileMock(sandbox.sandboxBin("llm"), sandbox.repoRoot, "wave")

    let (server, url) = startNats()
    var nc = waitConnect(url)
    var coreProc: Process
    # scenario "wave" gives the mock its scripted tool batch + "parallel-done"
    # final reply; NIF_MOCK_FAIL_FIRST makes the first two chat calls 503.
    bootWithExtra(nc, coreProc, sandbox, url, "wave",
                  [("NIF_MOCK_FAIL_FIRST", "2")])
    defer: stopHard(coreProc)
    defer: nc.close()
    defer: stopServer(server)
    defer: removeDir(root)

    # Count ev.session.retry events for our session.
    var retrySub: ptr natsSubscription
    check("retry: subscribe ev.session.retry",
          checkStatus(natsConnection_SubscribeSync(
            addr retrySub, nc.conn, "ev.session.retry".cstring)))
    defer: natsSubscription_Destroy(retrySub)

    let sessionId = "conv-parallel-retry-" & $int(epochTime())
    let turn = call(nc, "core", "session",
                    %*{"sessionId": sessionId, "content": "go"}, 120_000)
    check("retry: turn recovered after transient failures",
          turn{"error"} == nil, $turn)
    check("retry: turn reply", turn{"reply"}.getStr("") == "parallel-done",
          $turn)

    # Two 503s (attempt 0 and 1) must each announce a retry before success.
    var retryEvents: seq[JsonNode]
    let deadline = epochTime() + 5.0
    while epochTime() < deadline and retryEvents.len < 2:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, retrySub, 200)
      if st != NATS_OK: continue
      let env = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if env.payload{"sessionId"}.getStr("") == sessionId:
        retryEvents.add(env.payload)
    check("retry: two retry events announced", retryEvents.len == 2,
          $retryEvents.len)
    if retryEvents.len == 2:
      check("retry: first event attempt 1",
            retryEvents[0]{"attempt"}.getInt(0) == 1 and
            retryEvents[0]{"maxRetries"}.getInt(0) == 2 and
            retryEvents[0]{"delayMs"}.getInt(-1) >= 0, $retryEvents[0])
      check("retry: second event attempt 2",
            retryEvents[1]{"attempt"}.getInt(0) == 2, $retryEvents[1])
      check("retry: error message carried",
            retryEvents[0]{"error"}.getStr("").contains("503"),
            $retryEvents[0])

  report("PARALLEL")

main()
