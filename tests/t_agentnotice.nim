## Settlement-notice tests (docs/research/SUBAGENTS-PLAN.md P0.1).
##
## A background child that settles must reach its PARENT CONVERSATION, not
## just the UI. Boots a sandbox core (store + bash, no LLM) with the
## test-only stub component (components/ctxtest) and the agent component,
## then drives real background jobs and asserts the notice contract:
##
## - the notice record is durable before any delivery is attempted;
## - a notice to an IDLE parent is pulled by the parent's next turn, exactly
##   once, and lands as a structurally marked user message (not a bare
##   "Steer: ..." string);
## - agent_notices drains (and peek does not consume);
## - a replyless (stopped) job produces a notice with no fabricated summary;
## - the notice is a POINTER: replyBytes is the untruncated length and
##   agent_status returns the byte-identical full reply;
## - an oversized reply is summarised head/tail, not mid-truncated.

import std/[algorithm, json, os, osproc, strutils, times]
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
  let sandbox = newCoreSandbox("agentnotice", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  let coreBin = sandbox.sandboxBin("niffler")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))

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

  proc parentTranscript(parent: string): string =
    ## Concatenated content of a conversation's stored messages.
    for i in 1 .. 40:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      result.add($m{"value"}{"content"}.getStr("") & "\n")

  proc noticeMessages(parent: string): seq[JsonNode] =
    ## The structurally marked notice records in a parent transcript.
    for i in 1 .. 40:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      let v = m{"value"}
      if v{"notice"} != nil:
        result.add(v)

  proc fetchJobId(parent: string): string =
    for i in 1 .. 12:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      let content = m{"value"}{"content"}.getStr("")
      let marker = content.find("\"jobId\":\"job-")
      if marker >= 0:
        let start = marker + "\"jobId\":\"".len
        var stop = start
        while stop < content.len and content[stop] != '"': inc stop
        return content[start ..< stop]
    return ""

  proc waitJob(jobId: string): JsonNode =
    call(nc, "agent", "agent_wait",
         %*{"jobId": jobId, "timeoutMs": 60_000}, 90_000)

  # --- 1. a settled background job writes a durable notice ----------------
  # Drive the parent turn that spawns, then wait for the child, then check
  # the notice exists even though nobody has drained it (it is pull-lane:
  # the parent's turn already ended before the child settled).
  let idleParent = "ntc-idle"
  discard call(nc, "core", "session",
               %*{"sessionId": idleParent, "content": "go"}, 120_000)
  let idleJob = fetchJobId(idleParent)
  check("spawn returned a jobId", idleJob.startsWith("job-"), idleJob)
  let idleDone = waitJob(idleJob)
  check("child settled done",
        idleDone{"status"}.getStr("") == "done", $idleDone)
  let idleChild = idleDone{"sessionId"}.getStr("")

  var record: JsonNode
  for i in 0 ..< 30:
    record = call(nc, "store", "list",
                  %*{"kind": "agentnotice", "idPrefix": idleParent & ":"},
                  10_000)
    if record{"items"} != nil and record{"items"}.len > 0: break
    sleep(100)
  let items = record{"items"}
  check("settled job wrote a durable notice", items != nil and items.len > 0,
        $record)
  let noticeId = if items != nil and items.len > 0: items[0]{"id"}.getStr("")
                 else: ""
  let notice = if items != nil and items.len > 0: items[0]{"value"}
               else: newJObject()
  check("notice names the parent, job and child",
        notice{"parent"}.getStr("") == idleParent and
        notice{"jobId"}.getStr("") == idleJob and
        notice{"child"}.getStr("") == idleChild, $notice)
  check("notice is pending (no delivery yet)",
        notice{"deliveredAt"} == nil, $notice)

  # --- 2. the notice is a POINTER: replyBytes is the whole reply ----------
  # The summary is bounded; replyBytes must count the untruncated reply, and
  # agent_status (named by fullReplyIn) must return it byte-identical.
  let fullReply = idleDone{"reply"}.getStr("")
  check("notice names the recourse to the full reply",
        notice{"fullReplyIn"}.getStr("") == "agent_status", $notice)
  check("notice replyBytes is the untruncated length",
        notice{"replyBytes"}.getInt(0) == fullReply.len, $notice)
  let viaStatus = call(nc, "agent", "agent_status", %*{"jobId": idleJob}, 10_000)
  check("agent_status returns the full reply the notice points at",
        viaStatus{"reply"}.getStr("") == fullReply and fullReply.len > 0,
        $viaStatus)

  # --- 3. peek does not consume; drain marks delivered once ---------------
  let peeked = call(nc, "agent", "agent_notices",
                    %*{"session": idleParent, "peek": true}, 10_000)
  check("peek returns the pending notice without consuming",
        peeked{"count"}.getInt(0) == 1, $peeked)
  let afterPeek = call(nc, "store", "get",
                       %*{"kind": "agentnotice", "id": noticeId}, 10_000)
  check("peek left the notice undelivered",
        afterPeek{"value"}{"deliveredAt"} == nil, $afterPeek)
  let drained = call(nc, "agent", "agent_notices",
                     %*{"session": idleParent}, 10_000)
  check("drain returns the notice", drained{"count"}.getInt(0) == 1, $drained)
  check("drain marks it delivered via pull",
        drained{"notices"}[0]{"deliveredVia"}.getStr("") == "pull", $drained)
  let second = call(nc, "agent", "agent_notices",
                    %*{"session": idleParent}, 10_000)
  check("a second drain returns nothing", second{"count"}.getInt(0) == 0,
        $second)

  # --- 4. the parent's turn pulls a pending notice, exactly once ----------
  # A notice pending while the parent is idle must be folded into its NEXT
  # turn, as a structurally marked message — never as a bare steer string.
  let pullParent = "ntc-pull"
  discard call(nc, "core", "session",
               %*{"sessionId": pullParent, "content": "go"}, 120_000)
  let pullJob = fetchJobId(pullParent)
  let pullDone = waitJob(pullJob)
  check("pull child settled",
        pullDone{"status"}.getStr("") == "done", $pullDone)
  # The spawning turn is over, so the notice is pending. Run another turn.
  discard call(nc, "core", "session",
               %*{"sessionId": pullParent, "content": "second turn"}, 120_000)
  let pulled = noticeMessages(pullParent)
  check("the parent's next turn folded exactly one notice",
        pulled.len == 1, "found " & $pulled.len & " notices")
  if pulled.len == 1:
    check("the folded notice is structurally marked",
          pulled[0]{"notice"}{"kind"}.getStr("") == "subagent-settled" and
          pulled[0]{"notice"}{"jobId"}.getStr("") == pullJob, $pulled[0])
    check("the folded notice is not a bare steer string",
          not pulled[0]{"content"}.getStr("").startsWith("Steer: "),
          $pulled[0])
  let pulledRecord = call(nc, "store", "list",
                          %*{"kind": "agentnotice",
                             "idPrefix": pullParent & ":"}, 10_000)
  check("the pulled notice is marked delivered via the turn drain",
        pulledRecord{"items"}[0]{"value"}{"deliveredVia"}.getStr("") == "pull",
        $pulledRecord)

  # --- 5. a replyless (failed) job produces a notice with NO summary ------
  # A failed job has an error and no reply. The notice must report the status
  # and the recourse but must never fabricate a summary.
  let failParent = "ntc-fail"
  discard call(nc, "core", "session",
               %*{"sessionId": failParent, "content": "go"}, 120_000)
  let failJob = fetchJobId(failParent)
  check("fail-test spawn returned a jobId", failJob.startsWith("job-"),
        failJob)
  let failDone = waitJob(failJob)
  check("failed child is terminal",
        failDone{"status"}.getStr("") == "failed", $failDone)
  var failNotice: JsonNode
  for i in 0 ..< 30:
    let r = call(nc, "store", "list",
                 %*{"kind": "agentnotice", "idPrefix": failParent & ":"},
                 10_000)
    if r{"items"} != nil and r{"items"}.len > 0:
      failNotice = r{"items"}[0]{"value"}
      break
    sleep(100)
  check("a failed job still produces a notice",
        failNotice != nil and failNotice{"status"}.getStr("") == "failed",
        $failNotice)
  check("the replyless notice fabricates no summary",
        failNotice{"summary"} == nil and
        failNotice{"replyBytes"}.getInt(-1) == 0, $failNotice)
  check("failed notice carries the terminal error",
        failNotice{"error"}.getStr("").len > 0, $failNotice)

  # --- 6. a stopped job KEEPS a reply it already produced -----------------
  # Documented behavior: stopping is not erasure — the terminal record reads
  # "stopped" and the reply, if one was produced before the stop landed, is
  # kept. The notice must reflect that truthfully: a summary present iff the
  # job record has a reply, never invented and never hidden.
  let stopParent = "ntc-stop"
  discard call(nc, "core", "session",
               %*{"sessionId": stopParent, "content": "go"}, 120_000)
  let stopJob = fetchJobId(stopParent)
  check("stop-test spawn returned a jobId", stopJob.startsWith("job-"),
        stopJob)
  discard call(nc, "agent", "agent_stop", %*{"jobId": stopJob}, 10_000)
  let stopDone = waitJob(stopJob)
  check("stopped job is terminal",
        stopDone{"status"}.getStr("") == "stopped", $stopDone)
  var stopNotice: JsonNode
  for i in 0 ..< 30:
    let r = call(nc, "store", "list",
                 %*{"kind": "agentnotice", "idPrefix": stopParent & ":"},
                 10_000)
    if r{"items"} != nil and r{"items"}.len > 0:
      stopNotice = r{"items"}[0]{"value"}
      break
    sleep(100)
  check("a stopped job still produces a notice",
        stopNotice != nil and stopNotice{"status"}.getStr("") == "stopped",
        $stopNotice)
  let stopReply = stopDone{"reply"}.getStr("")
  check("the stopped notice's summary matches the reply the job kept",
        (stopReply.len == 0 and stopNotice{"summary"} == nil) or
        (stopReply.len > 0 and
         stopNotice{"summary"}.getStr("") == stopReply), $stopNotice)
  check("the stopped notice's replyBytes matches the kept reply",
        stopNotice{"replyBytes"}.getInt(-1) == stopReply.len, $stopNotice)

  # --- 7. agent_list: the derived roster --------------------------------
  # The roster is DERIVED (sessionmeta.parent joined with job records), so it
  # works for any conversation that ever spawned — nothing extra is stored.
  #
  # Two session turns: the first spawns three children and lists them while
  # two are still working (so status must be running), the second lists again
  # after everything has settled (so status must fall to idle/ready).
  let listParent = "lst-multi"
  discard call(nc, "core", "session",
               %*{"sessionId": listParent, "content": "go"}, 180_000)

  proc rosterCalls(parent: string): seq[JsonNode] =
    ## Every stored tool result that looks like an agent_list answer.
    for i in 1 .. 30:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      let content = m{"value"}{"content"}.getStr("")
      if content.contains("\"children\""):
        try: result.add(parseJson(content))
        except CatchableError: discard

  let busy = rosterCalls(listParent)
  check("agent_list answered from inside the turn", busy.len >= 2,
        "found " & $busy.len)
  if busy.len >= 1:
    let kids = busy[0]{"children"}
    check("the roster lists the parent's three children",
          kids != nil and kids.len == 3,
          if kids != nil: $kids else: "nil")
    if kids != nil and kids.len == 3:
      var wellFormed = true
      var depths: seq[int]
      for c in kids:
        depths.add(c{"depth"}.getInt(0))
        if not c{"sessionId"}.getStr("").startsWith("agent-") or
           not c{"jobId"}.getStr("").startsWith("job-"):
          wellFormed = false
      check("every row carries a durable child id and its jobId",
            wellFormed, $kids)
      check("direct children are depth 1", depths == @[1, 1, 1], $depths)
      # While the spawning turn is still running, at least one child is
      # mid-turn. Assert the vocabulary is from the closed set — never a
      # job-record status leaking through ("done"/"failed").
      let allowed = ["running", "idle", "ready"]
      var allAllowed = true
      for c in kids:
        if c{"status"}.getStr("") notin allowed: allAllowed = false
      check("status vocabulary is residency-based, not job-record status",
            allAllowed, $kids)
  if busy.len >= 2:
    check("the descendants scope reports itself and the same depth-1 set",
          busy[1]{"scope"}.getStr("") == "descendants" and
          busy[1]{"children"}.len == 3, $busy[1]{"scope"})

  # Wait for every rostered job to settle before the settled-state turn.
  # "By now" was a load-dependent race: under parallel-suite load the quick
  # children can still be mid-flight when the next turn starts, and the
  # check's intent is the settled vocabulary, not timing luck.
  if busy.len >= 1 and busy[0]{"children"} != nil:
    for c in busy[0]{"children"}:
      let jid = c{"jobId"}.getStr("")
      if jid.startsWith("job-"):
        discard waitJob(jid)

  # Second turn: the children have settled and their runners retired
  # (NIF_RUNNER_IDLE_S=2), so nobody may still read "running".
  discard call(nc, "core", "session",
               %*{"sessionId": listParent, "content": "settled?"}, 120_000)
  let settled = rosterCalls(listParent)
  if settled.len >= 3:
    let kids = settled[2]{"children"}
    var stillRunning = 0
    for c in kids:
      if c{"status"}.getStr("") == "running": inc stillRunning
    check("after the children settle, none still reads running",
          stillRunning == 0, $kids)
    check("a settled child's lastStatus records how its activation ended",
          kids.len == 3 and kids[0]{"lastStatus"}.getStr("") in
            ["done", "failed", "stopped"], $kids)

  let externalRoster = call(nc, "agent", "agent_list",
    %*{"sessionId": listParent, "scope": "descendants"}, 10_000)
  check("read-only UI roster accepts an explicit parent session",
        externalRoster{"children"} != nil and
        externalRoster{"children"}.len == 3, $externalRoster)
  if externalRoster{"children"} != nil and externalRoster{"children"}.len > 0:
    check("external roster carries activation timing for badges",
          externalRoster{"children"}[0]{"startedAt"}.getFloat(0) > 0,
          $externalRoster{"children"}[0])

  # future change to the tool cannot silently empty it.
  var metaChildren = 0
  let metas = call(nc, "store", "list",
                   %*{"kind": "sessionmeta", "limit": 1000}, 10_000)
  for item in metas{"items"}:
    if item{"value"}{"parent"}.getStr("") == listParent: inc metaChildren
  check("three children are durably recorded under the roster parent",
        metaChildren == 3, $metaChildren)

  # A parent that never spawned has no children — and does not error.
  discard call(nc, "core", "session",
               %*{"sessionId": "plain-parent", "content": "plain"}, 120_000)
  var noneChildren = 0
  for item in metas{"items"}:
    if item{"value"}{"parent"}.getStr("") == "plain-parent": inc noneChildren
  check("a parent that never spawned has no children", noneChildren == 0,
        $noneChildren)

  report("agentnotice")

main()
