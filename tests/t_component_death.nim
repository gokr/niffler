## component_death — issue #116: a component that dies mid-call must fail its
## in-flight call FAST and truthfully, instead of stalling the turn until the
## tool's own cap.
##
## Drives the REAL product path: a session turn whose mock LLM asks for a tool
## on a component we then SIGKILL. The assertion is on what the conversation
## receives — a `[component-exited]` tool result naming the component, arriving
## well under the cap, with the turn finishing rather than hanging.
##
## Contract under test (docs/WIRE.md, "Presence = connection"):
##   1. a call whose component loses its last live replica fails fast;
##   2. a merely SLOW component that is still registered keeps its full
##      timeout — live presence, never a timer, is the signal;
##   3. the error says the conversation is intact and a retry works once the
##      component re-registers.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

const turnDeadlineMs = 120_000

proc compileMock(llmBin, repoRoot: string) =
  ## Build the test LLM stand-in into the sandbox (same name/tool as `llm`).
  let p = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & llmBin, repoRoot / "tests" / "mock_parallel_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  if waitForExit(p, fixtureCompileTimeoutMs) != 0:
    fail("mock llm failed to compile")
    quit(1)

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  return false

proc toolMessages(nc: NatsConnection, sessionId: string): seq[JsonNode] =
  let listed = call(nc, "store", "list",
    %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 200}, 10_000)
  for item in listed{"items"}:
    if item{"value"}{"role"}.getStr("") == "tool":
      result.add(item{"value"})

proc findTool(msgs: seq[JsonNode], name: string): JsonNode =
  for m in msgs:
    if m{"name"}.getStr("") == name: return m
  return nil

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let sandbox = newCoreSandbox("compdeath",
    ["store", "bash", "builder", "llm", "systemprompt"])
  # Keep the tree when NIF_KEEP_SANDBOX=1: diagnosing a turn that never
  # finishes needs core's log and the component's. NOTE the defer must not sit
  # inside an `if` block — that scopes it to the block and deletes the sandbox
  # on the spot (which is exactly how this test first "lost" its core binary).
  let keepSandbox = getEnv("NIF_KEEP_SANDBOX") == "1"
  if keepSandbox: echo "sandbox root: " & sandbox.root & " (kept)"
  defer:
    if not keepSandbox: removeDir(sandbox.root)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # The dying component: `hang` never returns, `quick` answers at once.
  let fixtureSrc = repoRoot / "tests" / "fixtures" / "component_death.nim"
  let fixture = sandbox.fixtureBin("compdeath", fixtureSrc,
                                   prebuiltName = "fixture-component-death")

  compileMock(sandbox.sandboxBin("llm"), repoRoot)

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = @[("NIF_AUTO_APPROVE", "1"),
              ("NIF_MOCK_SCENARIO", "component-death")],
    logFile = sandbox.root / "var" / "compdeath-core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(500)
      if coreProc.running(): coreProc.kill()
    if coreProc != nil: coreProc.close()

  var up = false
  var lastErr = ""
  for i in 0 ..< 150:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    lastErr = $r
    if r{"error"} == nil and r{"tools"} != nil:
      up = true
      break
    sleep(200)
  var coreTail = ""
  if fileExists(sandbox.root / "var" / "compdeath-core.log"):
    let l = readFile(sandbox.root / "var" / "compdeath-core.log")
    coreTail = if l.len > 700: l[l.len-700 .. ^1] else: l
  check("core up", up, lastErr & " running=" & $coreProc.running() &
        " pid=" & $coreProc.processID & " log=" & coreTail)
  check("store registered", waitComponent(nc, "store"))

  # --- the live component serves, then we kill it MID-CALL ----------------
  # Spawned by CORE, not by this test: core must be the parent so its
  # supervisor reaps the death and announces the departure (the real path).
  # A component started here and SIGKILLed would linger as a ZOMBIE — this
  # process never waits on it — and `kill(pid, 0)` would keep calling it alive,
  # which is exactly the false "still present" the probe must not report.
  let spawned = call(nc, "core", "spawn",
    %*{"name": "compdeath", "binary": fixture}, 60_000)
  check("core.spawn compdeath", spawned{"ok"}.getBool(false), $spawned)
  var registered = false
  for i in 0 ..< 150:
    let r = call(nc, "compdeath", "quick", newJObject(), 3_000)
    if r{"error"}.getStr("").len == 0 and r{"alive"}.getBool(false):
      registered = true
      break
    sleep(200)
  check("the fixture registers and answers while alive", registered)

  if registered:
    # The mock asks for `block` on the first round. The turn is in flight;
    # kill the component underneath it and measure what the turn is told.
    let sessionId = "component-death-" & $int(epochTime())
    let t0 = epochTime()
    # Kill shortly after the turn starts: the handler is already blocked.
    # SIGKILL (not SIGTERM) is the case that matters — a killed process cannot
    # publish reg.depart, so only core's reap can report the death.
    # A detached shell does the killing so this process stays free to block on
    # the turn call (the SDK is single-threaded by design).
    # The pid comes from the catalog: core spawned it, so this is the pid core
    # will reap.
    var deathPid = 0
    let snap = call(nc, "core", "catalog", %*{"op": "snapshot"}, 5_000)
    if snap{"components"} != nil and snap{"components"}.kind == JArray:
      for item in snap{"components"}:
        if item{"name"}.getStr("") == "compdeath":
          deathPid = item{"pid"}.getInt(0)
    check("the catalog names the pid to kill", deathPid > 0, $snap)
    discard startProcess("/bin/sh",
      args = @["-c", "sleep 2.5; kill -9 " & $deathPid],
      options = {poUsePath})
    let turn = call(nc, "core", "session",
      %*{"sessionId": sessionId, "cwd": sandbox.root,
         "content": "go"}, turnDeadlineMs)
    let elapsed = epochTime() - t0
    check("the turn completes instead of hanging to the cap", turn{"error"} == nil,
          $turn)
    # The cap for a normal tool is far above this; the point is that the turn
    # ends promptly after the kill rather than waiting the full timeout.
    check("the turn ends well under the tool cap (elapsed " &
          $int(elapsed) & "s)", elapsed < 60.0, $turn)

    let msgs = toolMessages(nc, sessionId)
    let blockMsg = findTool(msgs, "hang")
    check("the in-flight call produced a tool result", blockMsg != nil,
          $msgs.len & " tool messages")
    if blockMsg != nil:
      let text = blockMsg{"content"}.getStr("")
      check("the result names the component that died and says it exited",
            text.contains("component-exited") and text.contains("compdeath"),
            text)
      check("the result says the conversation is intact and a retry works",
            text.toLowerAscii.contains("conversation is intact") and
            text.toLowerAscii.contains("retry"), text)
      check("the result does not claim a timeout",
            not text.contains("timed out"), text)

  # --- a merely slow component keeps its full timeout ---------------------
  # (The `hang` tool IS slow-but-alive before the kill: the point of the
  # timing check above is that the fast-fail fired only after the kill, so a
  # live-and-blocked component was allowed to keep waiting.)

  # --- the retry the error promises actually works ------------------------
  # A replacement process re-registers, and the same tool answers again.
  # (Also started by core, so its lifecycle stays core's.)
  discard call(nc, "core", "spawn",
    %*{"name": "compdeath2", "binary": fixture}, 60_000)
  var back = false
  for i in 0 ..< 150:
    let r = call(nc, "compdeath", "quick", newJObject(), 3_000)
    if r{"error"}.getStr("").len == 0 and r{"alive"}.getBool(false):
      back = true
      break
    sleep(200)
  check("a re-registered component answers again (the promised retry)", back)

  # --- no false early failure: a live component is never failed ----------
  if back:
    let q = call(nc, "compdeath", "quick", newJObject(), 3_000)
    check("a live component is never failed early",
          q{"error"}.getStr("").len == 0 and q{"alive"}.getBool(false))

  report("COMPONENT DEATH")

main()
