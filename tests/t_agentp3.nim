## P3.7/P3.8/P3.9/P3.10 tests — mode-sensitive wording, the delegation-scope
## statement, agent_steer durability, and agent_ask.
##
## Driven by DIRECT agent-tool calls with a hand-injected __session (the
## same injection core's dispatch gate performs during a turn) — no stub-
## scripted parents needed; the CHILD scripts come from ctxtest's agent-*
## markers (CNT_SLOW_BASH for a mid-turn window, CNT_FOLLOWUP for replies).
##
## - P3.7: the task description carries the three mode sentences (fresh /
##   fork / continuation) in both tools' schemas;
## - P3.8: a child's first user message carries the delegation-scope
##   statement (approvals answered by the parent's human; fixed allowlist;
##   report limitations instead of retrying), and a continuation adds no
##   second copy;
## - P3.9: steer to a mid-turn child publishes (folded into the running
##   turn); steer to an idle child queues durably and the mail drains into
##   the next continuation; steer to a nonexistent session fails closed;
## - P3.10: ask an idle child → answer returned; ask a mid-turn child →
##   queued, delivered with the next turn; ask a closed child → refused;
##   ask a nonexistent session → refused.

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
  let sandbox = newCoreSandbox("agentp3", ["store", "bash"])
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
                                         ("NIF_RUNNER_IDLE_S", "2")],
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

  proc agent(tool: string, args: JsonNode, timeout = 180_000): JsonNode =
    ## Direct agent-tool call as the session "p3-parent" (the same __session
    ## injection core's dispatch gate performs during a turn).
    var full = args.copy()
    full["__session"] = %*{"session": "p3-parent"}
    call(nc, "agent", tool, full, timeout)

  proc msgs(session: string): seq[JsonNode] =
    let r = call(nc, "store", "list",
                 %*{"kind": "message", "idPrefix": session & ":",
                    "limit": 1000}, 10_000)
    if r{"items"} != nil:
      for it in r{"items"}: result.add(it{"value"})

  proc transcript(session: string): string =
    for m in msgs(session): result.add($m{"content"}.getStr("") & "\n")

  proc jobRecord(jobId: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "agentjob", "id": jobId}, 10_000){"value"}

  proc waitJobDone(jobId: string): JsonNode =
    for i in 0 ..< 120:
      result = jobRecord(jobId)
      if result != nil and
          result{"status"}.getStr("") notin ["running", "stopping"]:
        return
      sleep(250)
    result = jobRecord(jobId)

  proc waitTurnStarted(child: string): bool =
    ## The child's user message is persisted at turn start — before the
    ## stub sleeps in its tool round.
    for i in 0 ..< 60:
      if msgs(child).len > 0: return true
      sleep(250)
    return false

  proc metaOf(child: string): JsonNode =
    call(nc, "store", "get",
         %*{"kind": "sessionmeta", "id": child}, 10_000){"value"}

  # =========================================================================
  # P3.7 — three mode sentences in the task descriptions
  # =========================================================================
  let r = call(nc, "core", "catalog",
               %*{"op": "schemas", "tools": ["agent_run", "agent_spawn"]},
               10_000)
  var runTask = ""
  var spawnTask = ""
  if r{"tools"} != nil:
    for t in r{"tools"}:
      let desc = t{"schema"}{"properties"}{"task"}{"description"}.getStr("")
      if t{"name"}.getStr("") == "agent_run": runTask = desc
      if t{"name"}.getStr("") == "agent_spawn": spawnTask = desc
  check("P3.7: fresh-mode sentence present (agent_run)",
        runTask.contains("fresh context — include everything it needs"),
        runTask)
  check("P3.7: fork-mode sentence present (agent_run)",
        runTask.contains("completed turns of this conversation but not the " &
                         "turn in flight"), runTask)
  check("P3.7: continuation-mode sentence present (agent_run)",
        runTask.contains("already has its own history — send only the next " &
                         "task"), runTask)
  check("P3.7: all three mode sentences present (agent_spawn)",
        spawnTask.contains("does not see this conversation") and
        spawnTask.contains("completed turns") and
        spawnTask.contains("send only the next task"), spawnTask)

  # =========================================================================
  # P3.9a + P3.10b — steer/park while the child is MID-TURN
  # =========================================================================
  let spawnRes = agent("agent_spawn",
                       %*{"task": "CNT_SLOW_BASH run the slow thing"})
  let slowJob = spawnRes{"jobId"}.getStr("")
  let slowChild = spawnRes{"sessionId"}.getStr("")
  check("slow child spawned", slowChild.startsWith("agent-") and
        slowJob.startsWith("job-"), $spawnRes)
  check("slow child's turn began", waitTurnStarted(slowChild))
  sleep(600)                    # margin for the ev.session.*.turn tap

  let steerLive = agent("agent_steer",
                        %*{"session_id": slowChild,
                           "message": "STEER1 hurry up"}, 30_000)
  check("P3.9a: steer to a mid-turn child publishes",
        steerLive{"published"}.getBool(false), $steerLive)

  let askMid = agent("agent_ask",
                     %*{"session": slowChild,
                        "question": "ASK1 what is happening?"}, 30_000)
  check("P3.10b: ask a mid-turn child queues as mail",
        askMid{"queued"}.getBool(false) and
        askMid{"deliveredVia"}.getStr("") == "next-turn", $askMid)

  # the live steer folds into the RUNNING turn (drainSteer at the round top)
  var steerFolded = false
  for i in 0 ..< 40:
    if transcript(slowChild).contains("STEER1"):
      steerFolded = true
      break
    sleep(250)
  check("P3.9a: the live steer folded into the running turn", steerFolded,
        transcript(slowChild))

  # =========================================================================
  # P3.9b + P3.10b delivered — the queued mail drains into the next turn
  # =========================================================================
  discard waitJobDone(slowJob)
  let contRes = agent("agent_run",
                      %*{"session": slowChild,
                         "task": "CNT_FOLLOWUP wrap up"}, 180_000)
  check("continuation of the slow child works",
        contRes{"reply"}.getStr("").contains("cnt-saw-followup"), $contRes)
  let ctext = transcript(slowChild)
  check("P3.9b: the queued steer mail drained into the next turn",
        ctext.contains("STEER1") and
        ctext.contains("mail from the parent conversation"), ctext)
  check("P3.10b: the queued question drained into the next turn",
        ctext.contains("ASK1"), ctext)
  # the delivered records are marked
  var undelivered = 0
  let nres = agent("agent_notices", %*{"session": slowChild, "peek": true},
                   30_000)
  if nres{"notices"} != nil:
    for n in nres{"notices"}:
      if n{"direction"}.getStr("") == "parent-mail": inc undelivered
  check("P3.9b: no parent-mail left undelivered", undelivered == 0,
        $nres)

  # =========================================================================
  # P3.8 — the delegation-scope statement in the child's first turn only
  # =========================================================================
  var userMsgs: seq[string] = @[]
  for m in msgs(slowChild):
    if m{"role"}.getStr("") == "user":
      userMsgs.add(m{"content"}.getStr(""))
  check("P3.8: the first turn carries the delegation-scope statement",
        userMsgs.len > 0 and
        userMsgs[0].contains("delegated subagent") and
        userMsgs[0].contains("report the limitation in your final reply"),
        if userMsgs.len > 0: userMsgs[0] else: "no user messages")
  var statementCopies = 0
  for u in userMsgs:
    if u.contains("delegated subagent"): inc statementCopies
  check("P3.8: the statement appears exactly once (no continuation repeat)",
        statementCopies == 1, $statementCopies & " copies in " &
        $userMsgs.len & " user messages")

  # =========================================================================
  # P3.10a — agent_ask on an IDLE child returns the reply
  # =========================================================================
  let askIdle = agent("agent_ask",
                      %*{"session": slowChild,
                         "question": "CNT_FOLLOWUP what did you report?"},
                      180_000)
  check("P3.10a: ask an idle child returns the answer",
        askIdle{"answer"}.getStr("").contains("cnt-saw-followup") and
        askIdle{"queued"}.getBool(false) == false, $askIdle)

  # =========================================================================
  # P3.9c / P3.10c — fail-closed: nonexistent and closed targets
  # =========================================================================
  let steerNone = agent("agent_steer",
                        %*{"session_id": "agent-does-not-exist",
                           "message": "x"}, 30_000)
  check("P3.9c: steer to a nonexistent session fails closed",
        steerNone{"error"}.getStr("").contains("unknown subagent session") and
        steerNone{"published"}.getBool(false) == false, $steerNone)

  # close the slow child, then ask it again — refused. Let the last turn's
  # tap settle first: closing is a continuation, and a continuation that
  # lands mid-turn is refused (that is the P1.3 contract, not a bug here).
  sleep(1200)
  let closeRes = agent("agent_run",
                       %*{"session": slowChild, "task": "CNT_IGNORED bye",
                          "close": true}, 180_000)
  check("close succeeded", closeRes{"closed"}.getBool(false), $closeRes)
  let askClosed = agent("agent_ask",
                        %*{"session": slowChild,
                           "question": "CNT_FOLLOWUP again?"}, 30_000)
  check("P3.10c: ask a closed child is refused",
        askClosed{"error"}.getStr("").contains("was closed"), $askClosed)

  # =========================================================================
  # P3.9d — only the child's parent may steer it
  # =========================================================================
  var foreign = %*{"session_id": slowChild, "message": "hi"}
  foreign["__session"] = %*{"session": "some-other-conversation"}
  let steerForeign = call(nc, "agent", "agent_steer", foreign, 30_000)
  check("P3.9d: a non-parent cannot steer",
        steerForeign{"error"}.getStr("").contains("not yours"), $steerForeign)

  report("agentp3")

when isMainModule:
  main()
