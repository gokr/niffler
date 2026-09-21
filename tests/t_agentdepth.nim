## P2.6 — NIF_AGENT_MAX_DEPTH (end-to-end) + P2.5 A schema guidance.
##
## Delegation depth was a hard-coded 1 (any session with a lineage record
## may not spawn). It is now `NIF_AGENT_MAX_DEPTH` (default 1), evaluated by
## a depth walk over sessionmeta.parent links, with the tool staying VISIBLE
## at the cap — each start rejects with an errored result naming the limit
## and the caller's depth, so the model learns why:
##
## - default cap 1 preserved: a child's spawn attempt is denied (t_agent
##   already asserts the refusal; the message now names the env var);
## - NIF_AGENT_MAX_DEPTH=2: a child may spawn a grandchild, which may not
##   spawn — the child's stage-0 "try to spawn" attempt exercises this
##   exactly (three generations from one scripted parent);
## - NIF_AGENT_MAX_DEPTH=0 forbids delegation entirely: even a root's
##   agent_run is denied (depth 0 >= cap 0);
## - the root itself is depth 0 and always allowed at cap >= 1 (implicit in
##   every other agent test);
## - P2.5 A: agent_spawn's schema carries the parallel-start guidance.

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

proc bootSandbox(tag, maxDepth: string) =
  ## One sandbox per cap value: core + ctxtest + agent, then the scenario.
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  let sandbox = newCoreSandbox(tag, ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root, " (NIF_AGENT_MAX_DEPTH=", maxDepth, ")"
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))
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

  var extra = @[("NIF_AUTO_APPROVE", "1"), ("NIF_RUNNER_IDLE_S", "2"),
                   ("NIF_AGENT_NOTICE_HOLD", "0")]
  if maxDepth.len > 0:
    extra.add(("NIF_AGENT_MAX_DEPTH", maxDepth))
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = extra,
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
  check("core up (" & tag & ")", coreUp)

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = root / "var" / "test-logs" / "ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered (" & tag & ")", waitComponent(nc, "ctxtest"))
  var agentExtra: seq[tuple[name, value: string]] = @[]
  if maxDepth.len > 0:
    agentExtra.add(("NIF_AGENT_MAX_DEPTH", maxDepth))
  # this suite asserts exact turn flows; the wake/hold contracts have their
  # own test (t_agentwake)
  agentExtra.add(("NIF_AGENT_WAKES", "0"))
  agentExtra.add(("NIF_AGENT_NOTICE_HOLD", "0"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 extra = agentExtra,
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered (" & tag & ")", waitComponent(nc, "agent"))

  proc msgs(session: string): seq[JsonNode] =
    let r = call(nc, "store", "list",
                 %*{"kind": "message", "idPrefix": session & ":",
                    "limit": 1000}, 10_000)
    if r{"items"} != nil:
      for it in r{"items"}: result.add(it{"value"})

  proc transcript(session: string): string =
    for m in msgs(session): result.add($m{"content"}.getStr("") & "\n")

  proc metaOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "sessionmeta", "id": child}, 10_000){"value"}

  proc turn(parent: string) =
    let r = call(nc, "core", "session",
                 %*{"sessionId": parent, "content": "go"}, 180_000)
    if r{"error"} != nil:
      fail("parent turn " & parent & " errored: " & $r)

  proc jstr(n: JsonNode): string =
    if n == nil: "<nil>" else: $n

  proc childIdOf(parent: string): string =
    ## The child session id from the parent's last agent tool result.
    for m in msgs(parent):
      if m{"role"}.getStr("") != "tool": continue
      let c = m{"content"}.getStr("")
      if c.startsWith("{"):
        try:
          let j = parseJson(c)
          let sid = j{"sessionId"}.getStr("")
          if sid.startsWith("agent-"): return sid
        except CatchableError: discard

  if maxDepth == "2":
    # Three generations from one scripted parent: the root spawns a child
    # (agent_run), the child's own stage-0 script attempts a spawn of its
    # own — allowed at depth 1 < 2 — and the grandchild's attempt is denied
    # at depth 2.
    turn("agt-parent")
    let child = childIdOf("agt-parent")
    check("cap 2: child spawned", child.startsWith("agent-"), child)
    check("cap 2: child lineage recorded",
          metaOf(child){"parent"}.getStr("") == "agt-parent", jstr(metaOf(child)))
    let ctext = transcript(child)
    check("cap 2: child's own spawn attempt was ALLOWED",
          not ctext.contains("NIF_AGENT_MAX_DEPTH"), ctext)
    check("cap 2: child completed after spawning",
          ctext.contains("subagent-done"), ctext)
    # the child's agent_run result names the grandchild
    var grandchild = ""
    for m in msgs(child):
      if m{"role"}.getStr("") != "tool": continue
      let c = m{"content"}.getStr("")
      if c.startsWith("{"):
        try:
          let j = parseJson(c)
          let sid = j{"sessionId"}.getStr("")
          if sid.startsWith("agent-"): grandchild = sid
        except CatchableError: discard
    check("cap 2: grandchild exists", grandchild.startsWith("agent-"),
          transcript(child))
    check("cap 2: grandchild lineage: child is the parent",
          metaOf(grandchild){"parent"}.getStr("") == child,
          jstr(metaOf(grandchild)))
    let gtext = transcript(grandchild)
    check("cap 2: grandchild's spawn DENIED at the cap",
          gtext.contains("subagent depth 2 exceeds NIF_AGENT_MAX_DEPTH=2"),
          gtext)
    check("cap 2: denied grandchild still ran its turn (tool visible)",
          gtext.contains("agent-ok") or gtext.contains("subagent-done"),
          gtext)
    check("cap 2: no great-grandchild (the denial held)",
          metaOf("agent-d2-great") == nil, "unexpected lineage record")

  if maxDepth == "0":
    # Cap 0 forbids delegation entirely: even a root's agent_run is denied.
    turn("agt-parent")
    let text = transcript("agt-parent")
    check("cap 0: root's agent_run denied",
          text.contains("subagent depth 0 exceeds NIF_AGENT_MAX_DEPTH=0"),
          text)
    check("cap 0: no child was minted",
          childIdOf("agt-parent") == "", "a child appeared anyway")

  if maxDepth.len == 0:
    # P2.5 A: the parallel-start guidance lives in agent_spawn's schema
    # (the honest description of today's capability: N spawns in one
    # message ARE parallel delegations, scheduled by the child runners).
    let r = call(nc, "core", "catalog",
                 %*{"op": "schemas", "tools": ["agent_spawn"]}, 10_000)
    var desc = ""
    if r{"tools"} != nil and r{"tools"}.len > 0:
      desc = r{"tools"}[0]{"schema"}{"description"}.getStr("")
    check("agent_spawn schema carries the parallel-start guidance",
          desc.contains("Start independent delegations together"), desc)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "agent"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  bootSandbox("agentdepth2", "2")
  bootSandbox("agentdepth0", "0")
  bootSandbox("agentdepthD", "")   # default: only the schema-text assertion
  report("agentdepth")

when isMainModule:
  main()
