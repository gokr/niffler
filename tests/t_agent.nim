## agent component tests (fabric Phase 1, docs/research/FABRIC.md).
##
## Boots a sandbox core (store + bash, no LLM) with the test-only stub
## component (components/ctxtest) and the agent component. Drives parent
## turns whose stub LLM calls agent_run; child sessions (their own runners,
## stub-scripted) attempt a nested agent_run (denied by the depth guard),
## run bash, or force an LLM failure. Asserts the full loop: delegated
## child-runner prep, lineage metadata, synchronous reply, depth guard,
## child LLM failure surfaced as a failure, and idle runner retirement.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered (robust
  ## against fast registrations that precede a reg.publish subscription).
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
  let sandbox = newCoreSandbox("agent", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  let coreBin = sandbox.sandboxBin("niffler")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))
  # NOTE: sandbox intentionally kept on failure for post-mortem (cleaned by OS)

  # compile the test-only stub component into the sandbox
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
                                logFile = "/tmp/opencode/core.log")
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
                               logFile = "/tmp/opencode/ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = "/tmp/opencode/agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- one parent turn: stub LLM calls agent_run ----------------------------
  let parentId = "agt-parent"
  let turn = call(nc, "core", "session",
                  %*{"sessionId": parentId, "content": "go"}, 120_000)
  check("parent turn completed",
        turn{"reply"}.getStr("") == "agent-turn-done", $turn)

  # agent_run result in the parent transcript: child session id + reply
  var agentResult = JsonNode(nil)
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": parentId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    if content.contains("\"reply\""):
      try: agentResult = parseJson(content)
      except CatchableError: discard
  check("agent_run returned a child session",
        agentResult != nil and
        agentResult{"sessionId"}.getStr("").startsWith("agent-") and
        agentResult{"reply"}.getStr("") == "subagent-done",
        if agentResult != nil: $agentResult else: "no agent_run result")
  let childId = (if agentResult != nil: agentResult{"sessionId"}.getStr("")
                 else: "")

  # --- child transcript: depth guard denied, bash ran -----------------------
  var childTranscript = ""
  for i in 1 .. 8:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": childId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    childTranscript.add($m{"value"}{"content"}.getStr(""))
  check("depth guard denied nested agent_run",
        childTranscript.contains("subagents cannot spawn subagents"),
        childTranscript)
  check("child ran bash", childTranscript.contains("agent-ok"),
        childTranscript)

  # --- lineage: the child session carries its parent in the store ----------
  let meta = call(nc, "store", "get",
                  %*{"kind": "sessionmeta", "id": childId}, 10_000)
  check("child sessionmeta records parent",
        meta{"value"}{"parent"}.getStr("") == parentId, $meta)

  # --- child LLM failure is a failure, not a successful text reply ----------
  # The stub chat raises for a task carrying the marker; agent_run must
  # surface the runner's turnError instead of an ok reply.
  let failParent = "agt-llmfail"
  let failTurn = call(nc, "core", "session",
                      %*{"sessionId": failParent, "content": "go"}, 120_000)
  check("failing parent turn completed",
        failTurn{"reply"}.getStr("") == "agent-turn-done", $failTurn)
  var failResult = JsonNode(nil)
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": failParent & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    let content = m{"value"}{"content"}.getStr("")
    if content.contains("llm error") or content.contains("\"error\""):
      try: failResult = parseJson(content)
      except CatchableError: discard
  check("child LLM failure reported as a failure",
        failResult != nil and failResult{"error"}.getStr("").len > 0 and
        failResult{"error"}.getStr("").contains("llm error"),
        if failResult != nil: $failResult else: "no agent_run failure result")
  check("child failure carries the session id",
        failResult != nil and
        failResult{"sessionId"}.getStr("").startsWith("agent-"),
        if failResult != nil: $failResult else: "no agent_run failure result")

  # --- idle retirement: quiet runners self-exit (NIF_RUNNER_IDLE_S=2) -------
  # The parent runner still exists right after the turn; after the idle
  # window it is gone. A probe returns {"error": "timeout"} (no responder);
  # the runner is re-ensured on the next real session call.
  sleep(4000)
  let retired = call(nc, "session." & childId, "session",
                     %*{"sessionId": childId, "model": ""}, 2_000)
  check("idle child runner retired",
        retired{"error"}.getStr("") != "", $retired)
  let reensured = call(nc, "core", "session",
                       %*{"sessionId": childId, "model": ""}, 30_000)
  check("retired runner re-ensured on demand",
        reensured{"error"} == nil, $reensured)

  report("agent")

main()
