## Subagent workspace + grant inheritance.
##
## The regression this exists for, observed live: a conversation pinned to
## ~/git/harding spawned a subagent, and the child was born in
## /home/gokr/git/nifflerprod — the harness root — because `agent_run` had no
## `cwd` argument and core's `resolveWorkspace(root, "")` answers the harness
## root. Its `bash` then took an OPAQUE write claim (`x-harness.writes:
## {"root": true}`) over that whole repository, so every other conversation
## working there was refused with [E_WRITE_BUSY]. All 13 subagents in that
## store had the same path, while 26 parent conversations lived elsewhere.
##
## The rule asserted here (docs/research/SANDBOX-CONVERSATION-POLICY.md states
## it twice, but nothing in production ever called inheritSandboxPolicy):
##
## - a fresh child inherits the parent's PINNED workspace, not the harness root;
## - an explicit `cwd` beats inheritance, so a parent may place a child in a
##   worktree;
## - a child inherits the parent's `grantedroot` document (a snapshot at
##   creation), so a human's `/roots add` reaches headless children instead of
##   stopping at the conversation boundary.
##
## The stub LLM (components/ctxtest) scripts the agent_run call for the fixed
## session ids "agt-inherit" and "agt-inherit-cwd".

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
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
  let sandbox = newCoreSandbox("agentinherit", ["store", "bash"])
  let root = sandbox.root
  defer: removeDir(root)
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))

  # Three DIFFERENT trees, so "inherited the parent", "explicit cwd" and "fell
  # back to the harness root" cannot be confused with one another.
  let parentWs = root / "ws-parent"
  let explicitWs = root / "ws-explicit"
  let grantedWs = root / "ws-granted"
  createDir(parentWs)
  createDir(explicitWs)
  createDir(grantedWs)
  putEnv("CTXTEST_EXPLICIT_CWD", explicitWs)
  let ctxBin = fixtureBin(sandbox, "ctxtest",
                          repoRoot / "components" / "ctxtest" / "main.nim")

  let (server, url, monUrl) = startNatsMonitoring()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "2"),
                                         ("NIF_AGENT_NOTICE_HOLD", "0")],
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
  if not coreUp:
    report("AGENT INHERIT TEST")
    quit(1)

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = root / "var" / "test-logs" / "ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 extra = [("NIF_AGENT_WAKES", "0"),
                                          ("NIF_AGENT_NOTICE_HOLD", "0")],
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- helpers -------------------------------------------------------------

  proc msgs(session: string): seq[JsonNode] =
    let r = call(nc, "store", "list",
                 %*{"kind": "message", "idPrefix": session & ":",
                    "limit": 1000}, 10_000)
    if r{"items"} != nil:
      for it in r{"items"}: result.add(it)

  proc lastTool(session: string): JsonNode =
    for m in msgs(session):
      if m{"value"}{"role"}.getStr("") != "tool": continue
      let content = m{"value"}{"content"}.getStr("")
      if content.startsWith("{"):
        try: result = parseJson(content)
        except CatchableError: discard

  proc headerOf(session: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "conversation", "id": session}, 10_000){"value"}

  proc turn(session: string, args: JsonNode): JsonNode =
    call(nc, "core", "session", args, 180_000)

  # =========================================================================
  # 1. A child inherits the parent's workspace, NOT the harness root
  # =========================================================================
  # The parent is born directly in parentWs — the ordinary client shape (a
  # client sends its launch directory as cwd on the first call).
  let pTurn = turn("agt-inherit",
                   %*{"sessionId": "agt-inherit", "cwd": parentWs,
                      "content": "go"})
  check("the parent turn completed", pTurn{"error"} == nil, $pTurn)
  check("the parent is pinned to its own tree (fixture precondition)",
        headerOf("agt-inherit"){"cwd"}.getStr("") == parentWs,
        $headerOf("agt-inherit"){"cwd"})

  let spawned = lastTool("agt-inherit")
  let child = spawned{"sessionId"}.getStr("")
  check("the parent spawned a child", child.startsWith("agent-"), $spawned)
  if child.len > 0:
    let childCwd = headerOf(child){"cwd"}.getStr("")
    check("the child's workspace is the PARENT's, not the harness root",
          childCwd == parentWs,
          "child cwd = " & childCwd & " (harness root = " & root & ")")
    check("the child did not land in the harness root", childCwd != root,
          childCwd)

  # =========================================================================
  # 2. An explicit cwd beats inheritance
  # =========================================================================
  let eTurn = turn("agt-inherit-cwd",
                   %*{"sessionId": "agt-inherit-cwd", "cwd": parentWs,
                      "content": "go"})
  check("the explicit-cwd parent turn completed", eTurn{"error"} == nil, $eTurn)
  let eSpawned = lastTool("agt-inherit-cwd")
  let eChild = eSpawned{"sessionId"}.getStr("")
  check("the explicit-cwd parent spawned a child", eChild.startsWith("agent-"),
        $eSpawned)
  if eChild.len > 0:
    let eCwd = headerOf(eChild){"cwd"}.getStr("")
    check("an explicit cwd places the child there, not in the parent's tree",
          eCwd == explicitWs, "child cwd = " & eCwd & " want " & explicitWs)

  # =========================================================================
  # 3. Grant inheritance: the parent's grantedroot snapshot reaches the child
  # =========================================================================
  # Grant FIRST, then birth: inheritance is a snapshot at creation, so the
  # child must be created after the grant exists. Both are the same session
  # call shape a client uses (cwd pins, roots adds, content spawns).
  let grant = call(nc, "core", "session",
                   %*{"sessionId": "agt-inherit-grant", "cwd": parentWs,
                      "roots": {"add": [grantedWs]}}, 20_000)
  check("the parent accepted a grant", grant{"error"} == nil, $grant)
  let gTurn = turn("agt-inherit-grant",
                   %*{"sessionId": "agt-inherit-grant", "content": "go"})
  check("the granting parent ran a turn", gTurn{"error"} == nil, $gTurn)
  let gSpawned = lastTool("agt-inherit-grant")
  let gChild = gSpawned{"sessionId"}.getStr("")
  check("the granting parent spawned a second child",
        gChild.startsWith("agent-") and gChild != child, $gSpawned)
  if gChild.len > 0:
    let doc = call(nc, "store", "get",
                   %*{"kind": "grantedroot", "id": gChild & ":roots"}, 10_000)
    check("the child has a grantedroot document of its own",
          doc{"value"} != nil, $doc)
    check("the inherited grant names the granted tree",
          ($doc{"value"}).contains(grantedWs), $doc{"value"})

  report("AGENT INHERIT TEST")

main()
