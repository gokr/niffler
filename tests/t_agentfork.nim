## P1.4 fork tests (docs/research/SUBAGENTS-PLAN.md).
##
## `agent_run`/`agent_spawn {fork}` seed a FRESH child with the caller's
## COMPLETED turns, so the child has READ the conversation instead of being
## told about it:
##
## - adoption: messages exist before the header; the child's first request
##   replays the inherited history plus the new task (the needle is in the
##   child's transcript and its stub reply proves it saw the history);
## - the cut is balanced: a synthetic dangling turn (user + assistant with
##   tool_calls, no tool results) is excluded — the copied tail always ends
##   at a completed turn, never mid-tool-round;
## - lastK / maxChars budgets cut on turn boundaries; a budget that drops
##   everything fails closed and mints no child;
## - usage is absent from copied records; summary/error roles are skipped;
## - the child does NOT inherit the parent's toolset: a fork's `tools`
##   argument freezes the child's allowlist (a birth's controls come from
##   this call); conversation header records it;
## - provenance in sessionmeta and visible through session_info;
## - fork + session is refused (a fork is a birth, not a continuation);
## - the forked child is depth-1 like any child (lineage recorded).

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
  let sandbox = newCoreSandbox("agentfork", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
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
    ## ALL stored message records (value + id) of a conversation, in order.
    let r = call(nc, "store", "list",
                 %*{"kind": "message", "idPrefix": session & ":",
                    "limit": 1000}, 10_000)
    if r{"items"} != nil:
      for it in r{"items"}:
        result.add(it)

  proc toolJsons(parent: string): seq[JsonNode] =
    ## Parsed tool-call results in a parent transcript.
    for m in msgs(parent):
      if m{"value"}{"role"}.getStr("") != "tool": continue
      let content = m{"value"}{"content"}.getStr("")
      if content.startsWith("{"):
        try: result.add(parseJson(content))
        except CatchableError: discard

  proc lastTool(parent: string): JsonNode =
    let all = toolJsons(parent)
    if all.len > 0: result = all[^1]

  proc metaOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "sessionmeta", "id": child}, 10_000){"value"}

  proc headerOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "conversation", "id": child}, 10_000){"value"}

  proc turn(parent: string) =
    let r = call(nc, "core", "session",
                 %*{"sessionId": parent, "content": "go"}, 180_000)
    if r{"error"} != nil:
      fail("parent turn " & parent & " errored: " & $r)

  # =========================================================================
  # 1. Build parent history: two completed turns (stages 0 and 2)
  # =========================================================================
  turn("frk-main")
  turn("frk-main")
  let parentMsgs = msgs("frk-main")
  check("parent history has both turns",
        parentMsgs.len >= 4, $parentMsgs.len & " records")
  var sawOrigin = false
  var sawSecond = false
  for m in parentMsgs:
    # the needles ride in tool_calls arguments, not only content — search
    # the whole record
    if ($m{"value"}).contains("FRKORIGIN"): sawOrigin = true
    if ($m{"value"}).contains("FRKSECOND"): sawSecond = true
  check("both needles in the parent transcript", sawOrigin and sawSecond,
        "origin=" & $sawOrigin & " second=" & $sawSecond)

  # =========================================================================
  # 2. fork: true — full adoption (stage 4)
  # =========================================================================
  turn("frk-main")
  let full = lastTool("frk-main")
  let fchild = full{"sessionId"}.getStr("")
  check("fork returned a fresh child", fchild.startsWith("agent-"), $full)
  check("fork result carries provenance",
        full{"fork"}{"source"}.getStr("") == "frk-main" and
        full{"fork"}{"copied"}.getInt(0) > 0, $full)

  # adoption: the child's transcript = copied history + the new task, and
  # the header was created (not clobbered) around it
  let cmsgs = msgs(fchild)
  check("child transcript holds the inherited history",
        cmsgs.len > full{"fork"}{"copied"}.getInt(0),
        $cmsgs.len & " vs copied " & $full{"fork"}{"copied"}.getInt(0))
  var childSawOrigin = false
  var childSawSecond = false
  for m in cmsgs:
    if ($m{"value"}).contains("FRKORIGIN"): childSawOrigin = true
    if ($m{"value"}).contains("FRKSECOND"): childSawSecond = true
  check("child inherited the full history (both needles)",
        childSawOrigin and childSawSecond,
        "origin=" & $childSawOrigin & " second=" & $childSawSecond)
  check("child ids are dense from :000001",
        cmsgs.len > 0 and cmsgs[0]{"id"}.getStr("").endsWith(":000001"),
        cmsgs[0]{"id"}.getStr(""))
  check("header was created around the copied messages",
        headerOf(fchild){"createdAt"} != nil, "no header")
  check("the child SAW the inherited history (stub reply proves it)",
        full{"reply"}.getStr("").len > 0, $full)

  # usage is absent from copied records
  var usageLeaks = 0
  for m in cmsgs:
    if m{"value"}{"usage"} != nil: inc usageLeaks
  check("copied records carry no usage meters", usageLeaks == 0,
        $usageLeaks & " leaks")

  # provenance in sessionmeta and session_info
  let meta = metaOf(fchild)
  check("sessionmeta carries fork provenance",
        meta{"fork"}{"source"}.getStr("") == "frk-main" and
        meta{"fork"}{"uptoId"}.getStr("").contains("frk-main:") and
        meta{"fork"}{"copied"}.getInt(0) > 0, $meta)
  let sinfo = call(nc, "core", "session_info",
                   %*{"sessionId": fchild}, 10_000)
  check("session_info surfaces the fork",
        sinfo{"fork"}{"source"}.getStr("") == "frk-main" and
        sinfo{"parent"}.getStr("") == "frk-main", $sinfo)

  # =========================================================================
  # 3. the cut is balanced: a dangling turn is excluded (stage 6 uses lastK,
  #    but first plant the synthetic in-flight turn on a fresh parent)
  # =========================================================================
  # A real turn always ends balanced (the stub returns content), so plant an
  # IN-FLIGHT turn by hand AFTER a completed one: user message +
  # assistant-with-tool_calls and no tool results — exactly what a
  # mid-tool-round crash leaves at the tail.
  turn("frk-cut")             # stage 0: a completed turn of its own
  let dangling = @[
    %*{"role": "user", "content": "FRKDANGLING start something",
       "conversationId": "frk-cut", "createdAt": now().toTime().toUnixFloat()},
    %*{"role": "assistant", "content": "",
       "tool_calls": %*[{"id": "call_x", "type": "function",
                         "function": {"name": "bash",
                                      "arguments": "{\"command\":\"echo hi\"}"}}],
       "conversationId": "frk-cut", "createdAt": now().toTime().toUnixFloat()}
  ]
  var dn = msgs("frk-cut").len
  for d in dangling:
    inc dn
    discard call(nc, "store", "put",
      %*{"kind": "message",
         "id": "frk-cut:" & align($dn, 6, '0'), "value": d}, 10_000)
  turn("frk-cut")             # stage 2: the lastK fork under test
  let cut = lastTool("frk-cut")
  let kchild = cut{"sessionId"}.getStr("")
  check("lastK fork returned a child", kchild.startsWith("agent-"), $cut)
  check("lastK result carries provenance",
        cut{"fork"}{"copied"}.getInt(0) > 0, $cut)
  # the copied tail must end at the COMPLETED turn — the dangling user +
  # assistant-with-tool_calls that follow it must be excluded. Scope the
  # check to the COPIED prefix: the child's own turn (after its task
  # message, the last user record) legitimately contains tool_calls.
  let kmsgs = msgs(kchild)
  var lastUserIdx = -1
  for i, m in kmsgs:
    if m{"value"}{"role"}.getStr("") == "user": lastUserIdx = i
  check("the forked child has its own task message", lastUserIdx > 0,
        "last user idx " & $lastUserIdx)
  var copiedDangling = 0
  var pending = 0   # replay-balance walk over the COPIED prefix
  for i in 0 ..< lastUserIdx:
    let v = kmsgs[i]{"value"}
    if ($v{"content"}).contains("FRKDANGLING"): inc copiedDangling
    let role = v{"role"}.getStr("")
    if role == "assistant":
      let tc = v{"tool_calls"}
      if tc != nil and tc.kind == JArray:
        inc pending, tc.len
      elif pending > 0:
        inc copiedDangling   # closing assistant over unanswered calls
    elif role == "tool":
      if pending == 0: inc copiedDangling  # orphaned tool record
      else: dec pending
  check("the in-flight turn was excluded from the cut",
        copiedDangling == 0 and pending == 0,
        $copiedDangling & " dangling records, pending " & $pending)
  # the cut boundary: the LAST COPIED record is a closing assistant
  let lastCopied = kmsgs[lastUserIdx - 1]{"value"}
  check("the copied tail ends at a closing assistant",
        lastCopied{"role"}.getStr("") == "assistant" and
        (lastCopied{"tool_calls"} == nil or
         lastCopied{"tool_calls"}.len == 0),
        "last copied: " & $lastCopied)
  check("lastK(1) copied exactly one turn's worth",
        cut{"fork"}{"copied"}.getInt(0) < full{"fork"}{"copied"}.getInt(0),
        "lastK copied " & $cut{"fork"}{"copied"}.getInt(0) & " vs full " &
        $full{"fork"}{"copied"}.getInt(0))

  # A crash mid-HISTORY (dangling turn NOT at the tail) truncates the fork
  # at the corruption: the seed is contiguous-from-0, so with dangling
  # records at the HEAD of a fresh parent, nothing is forkable and the call
  # fails closed instead of copying an unbalanced prefix.
  var hn = 0
  for d in dangling:
    inc hn
    discard call(nc, "store", "put",
      %*{"kind": "message",
         "id": "frk-cut2:" & align($hn, 6, '0'), "value": d}, 10_000)
  turn("frk-cut2")            # stage 0: a plain completed turn
  turn("frk-cut2")            # stage 2: fork the corrupted history
  let headCut = lastTool("frk-cut2")
  check("a mid-history crash truncates the fork (fail closed)",
        headCut{"error"}.getStr("").contains("nothing to fork") and
        headCut{"sessionId"}.getStr("") == "", $headCut)

  # =========================================================================
  # 4. fail-closed budgets (frk-main stage 8 = maxChars, 10 = fork+session)
  # =========================================================================
  turn("frk-main")            # stage 6: lastK(1) — consumed, not asserted
  turn("frk-main")            # stage 8: maxChars: 10 → nothing fits
  let tiny = lastTool("frk-main")
  check("maxChars budget that drops everything fails closed",
        tiny{"error"}.getStr("").contains("nothing fits"), $tiny)
  turn("frk-main")            # stage 10: fork + session → refused
  let cont = lastTool("frk-main")
  check("fork + session refused (a fork is a birth)",
        cont{"error"}.getStr("").contains("fork only applies"), $cont)
  # the failed forks minted no children beyond the known ones
  let sinfo2 = call(nc, "core", "session_info",
                    %*{"sessionId": "frk-nonexistent-fork"}, 10_000)
  check("failed fork minted nothing",
        sinfo2{"error"} != nil, $sinfo2)

  # =========================================================================
  # 5. the fork does NOT inherit the parent's toolset (stage 12)
  # =========================================================================
  turn("frk-main")            # stage 12: fork + tools: ["bash"]
  let scoped = lastTool("frk-main")
  check("scoped fork carries provenance",
        scoped{"fork"}{"copied"}.getInt(0) > 0, $scoped)
  let tchild = scoped{"sessionId"}.getStr("")
  check("scoped fork returned a child", tchild.startsWith("agent-"), $scoped)
  let theader = headerOf(tchild)
  check("the fork's tools argument froze the child's allowlist",
        theader{"toolAllowlist"} != nil and
        theader{"toolAllowlist"}.len == 1 and
        theader{"toolAllowlist"}[0].getStr("") == "bash", $theader)
  # and a fork WITHOUT tools gets the full set (no inherited allowlist)
  turn("frk-second")          # stage 0: history
  turn("frk-second")          # stage 2: more history
  turn("frk-second")          # stage 4: fork: true, no tools argument
  let openfork = lastTool("frk-second")
  check("open fork carries provenance",
        openfork{"fork"}{"copied"}.getInt(0) > 0, $openfork)
  let ochild = openfork{"sessionId"}.getStr("")
  check("open fork returned a child", ochild.startsWith("agent-"), $openfork)
  let oheader = headerOf(ochild)
  check("a fork without tools inherits NO allowlist",
        oheader{"toolAllowlist"} == nil or
        oheader{"toolAllowlist"}.len == 0, $oheader)
  check("forked child is depth-1 lineage like any child",
        metaOf(ochild){"parent"}.getStr("") == "frk-second", $metaOf(ochild))

  report("agentfork")

when isMainModule:
  main()
