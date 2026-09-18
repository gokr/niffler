## Autonomous-wake tests (docs/WIRE.md "Settlement notices", "Autonomous wake").
##
## A background child that settles while its PARENT CONVERSATION is idle must
## not wait for the human to ask: the agent component wakes the parent, and
## the runner runs one bounded turn whose only purpose is folding the pending
## settlement notices in. This suite pins that contract:
##
## - an idle parent is woken with NO further client session call, and its
##   transcript gains a wake-marked user message + the structurally marked
##   notice + an assistant reply;
## - wakes are bounded: after NIF_AGENT_WAKES consecutive wake turns a real
##   user message is required, the declined notice stays pending, and the
##   runner re-checks the budget authoritatively (a direct wake call is
##   declined with reason "budget" even when the component's pre-check was
##   bypassed);
## - a wake with nothing pending runs no turn and persists nothing;
## - the next real user turn still pulls a notice a declined wake left behind.
##
## The agent component and core are both started with NIF_AGENT_WAKES=2 so
## the budget scenario stays short; the runner reads the same knob from core's
## environment (in production both see it through .env).

import std/[algorithm, json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc clip(s: string, n: int): string =
  if s.len <= n: s else: s[0 ..< n]

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
  let sandbox = newCoreSandbox("agentwake", ["store", "bash"])
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

  # Budget 2 on CORE so the session runners (spawned by core) see the same
  # knob the agent component uses; runner idle 2s exercises wake-after-retire.
  var coreProc = startComponent(coreBin, url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "2"),
                                         ("NIF_AGENT_WAKES", "2")],
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
                                 extra = [("NIF_AGENT_WAKES", "2")],
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- helpers -------------------------------------------------------------

  proc transcript(parent: string): seq[JsonNode] =
    ## Ordered stored messages of a conversation.
    for i in 1 .. 60:
      let m = call(nc, "store", "get",
                   %*{"kind": "message",
                      "id": parent & ":" & align($i, 6, '0')}, 10_000)
      if m{"error"} != nil: break
      result.add(m{"value"})

  proc wakeMessages(parent: string): seq[JsonNode] =
    for m in transcript(parent):
      if m{"role"}.getStr("") == "user" and m{"notice"} != nil and
          m{"notice"}{"kind"}.getStr("") == "wake":
        result.add(m)

  proc noticeMessages(parent: string): seq[JsonNode] =
    for m in transcript(parent):
      if m{"notice"} != nil and
          m{"notice"}{"kind"}.getStr("") == "subagent-settled":
        result.add(m)

  proc notices(parent: string): seq[JsonNode] =
    let r = call(nc, "store", "list",
                 %*{"kind": "agentnotice", "idPrefix": parent & ":"}, 10_000)
    if r{"items"} != nil:
      for item in r{"items"}: result.add(item{"value"})

  proc fetchJobId(parent: string): string =
    for m in transcript(parent):
      let content = m{"content"}.getStr("")
      let marker = content.find("\"jobId\":\"job-")
      if marker >= 0:
        let start = marker + "\"jobId\":\"".len
        var stop = start
        while stop < content.len and content[stop] != '"': inc stop
        return content[start ..< stop]
    return ""

  proc waitJob(jobId: string): JsonNode =
    call(nc, "agent", "agent_wait",
         %*{"jobId": jobId, "timeoutMs": 90_000}, 120_000)

  # --- 1. an idle parent is WOKEN: visibility without asking --------------
  # One client call spawns the child; from then on nobody calls the session
  # again. When the child settles, the parent must gain a wake turn on its
  # own: wake-marked user message, the notice, an assistant reply.
  let wakeParent = "ntc-wake1"
  discard call(nc, "core", "session",
               %*{"sessionId": wakeParent, "content": "go"}, 120_000)
  let wakeJob = fetchJobId(wakeParent)
  check("wake parent spawned a background child", wakeJob.startsWith("job-"),
        wakeJob)
  let wakeDone = waitJob(wakeJob)
  check("wake child settled done", wakeDone{"status"}.getStr("") == "done",
        $wakeDone)

  var woke = false
  for i in 0 ..< 200:
    if wakeMessages(wakeParent).len >= 1 and
        noticeMessages(wakeParent).len >= 1:
      woke = true
      break
    sleep(250)
  check("idle parent woke without another client turn", woke, block:
    var dump = ""
    for m in transcript(wakeParent):
      dump.add(m{"role"}.getStr("") & ": " & clip(m{"content"}.getStr(""), 60) & "\n")
    dump)

  let wakeMsgs = wakeMessages(wakeParent)
  let noticeMsgs = noticeMessages(wakeParent)
  check("exactly one wake turn ran", wakeMsgs.len == 1, $wakeMsgs.len)
  check("exactly one settlement notice folded", noticeMsgs.len == 1,
        $noticeMsgs.len)
  check("the wake message is structurally marked",
        wakeMsgs.len == 1 and
        wakeMsgs[0]{"notice"}{"kind"}.getStr("") == "wake", $wakeMsgs)
  let wokeNotice = notices(wakeParent)
  check("the settled notice was delivered", wokeNotice.len == 1 and
        wokeNotice[0]{"deliveredAt"} != nil, $wokeNotice)
  # The wake turn ran after the notice landed: the transcript's last
  # assistant message follows the notice and came from the stub's wake stage.
  var wakeReply = ""
  for m in transcript(wakeParent):
    if m{"role"}.getStr("") == "assistant" and
        m{"content"}.getStr("") == "notice-parent-done":
      wakeReply = "notice-parent-done"
  check("the woken turn produced an assistant reply", wakeReply.len > 0, block:
    var dump = ""
    for m in transcript(wakeParent):
      dump.add(m{"role"}.getStr("") & ": " & clip(m{"content"}.getStr(""), 40) & "\n")
    dump)

  # --- 2. the consecutive-wake budget bounds autonomous turns -------------
  # Three SLOW children settle one after another while the parent is idle:
  # the first two settlements wake, the third must be declined with the
  # notice left pending. Then a direct wake call (bypassing the component's
  # pre-check) must be declined authoritatively by the runner, and the next
  # real user turn still delivers the pending notice.
  let budgetParent = "ntc-budget"
  discard call(nc, "core", "session",
               %*{"sessionId": budgetParent, "content": "go"}, 120_000)

  var budgetWakes = 0
  for i in 0 ..< 320:
    budgetWakes = wakeMessages(budgetParent).len
    if budgetWakes >= 2 and notices(budgetParent).len >= 3:
      break
    sleep(250)
  check("two wakes fired", budgetWakes == 2, $budgetWakes)
  let budgetNotices = notices(budgetParent)
  check("three children settled", budgetNotices.len == 3, $budgetNotices.len)

  # Give any third wake attempt time to land, then prove the budget held.
  sleep(3000)
  check("the budget stopped the third wake",
        wakeMessages(budgetParent).len == 2,
        $wakeMessages(budgetParent).len)
  let delivered = block:
    var n = 0
    for v in notices(budgetParent):
      if v{"deliveredAt"} != nil: inc n
    n
  check("exactly two notices were delivered by wakes", delivered == 2,
        $delivered)

  # The runner re-checks the budget itself: a direct wake, with the
  # component's pre-check bypassed, is declined with the machine-readable
  # reason — and persists nothing.
  let direct = call(nc, "core", "session",
                    %*{"sessionId": budgetParent, "wake": true}, 60_000)
  check("runner declines a direct over-budget wake",
        direct{"wake"}.getStr("") == "declined" and
        direct{"reason"}.getStr("") == "budget", $direct)
  check("the declined direct wake ran no turn",
        wakeMessages(budgetParent).len == 2, $wakeMessages(budgetParent).len)

  # The real user turn resets the budget and pulls the pending notice.
  discard call(nc, "core", "session",
               %*{"sessionId": budgetParent, "content": "status?"}, 120_000)
  let afterReal = block:
    var n = 0
    for v in notices(budgetParent):
      if v{"deliveredAt"} != nil: inc n
    n
  check("the next real turn delivered the notice the wake left behind",
        afterReal == 3, $afterReal)
  check("the real turn is not wake-marked",
        wakeMessages(budgetParent).len == 2,
        $wakeMessages(budgetParent).len)

  # --- 3. a wake with nothing pending is skipped, not run -----------------
  let emptyParent = "ntc-nopending"
  let skipped = call(nc, "core", "session",
                     %*{"sessionId": emptyParent, "wake": true}, 60_000)
  check("a wake with nothing pending is skipped",
        skipped{"wake"}.getStr("") == "skipped" and
        skipped{"reason"}.getStr("") == "nothing pending", $skipped)
  let emptyTranscript = transcript(emptyParent)
  check("the skipped wake persisted no message",
        emptyTranscript.len == 0, $emptyTranscript.len)

  # --- 4. a busy parent cannot close over a settlement ---------------------
  # The stub injects a notice onto the parent's steer channel while it is
  # answering (its stage-0 response has no tool calls). The would-stop drain
  # must fold it and hold the turn open for one more round — the turn ends on
  # the stub's stage-1 reply, and the notice lands between the two assistant
  # messages. Deterministic: the notice is queued before the first response
  # returns, with no second process in the race.
  let holdParent = "ntc-hold"
  let held = call(nc, "core", "session",
                  %*{"sessionId": holdParent, "content": "go"}, 120_000)
  check("the held turn ran a second round",
        held{"reply"}.getStr("") == "notice-parent-done", $held)
  var holdSeq: seq[string] = @[]
  for m in transcript(holdParent):
    case m{"role"}.getStr("")
    of "user":
      if m{"notice"} != nil and
          m{"notice"}{"kind"}.getStr("") == "subagent-settled":
        holdSeq.add("notice")
      elif m{"notice"} == nil:
        holdSeq.add("user")
    of "assistant":
      holdSeq.add(m{"content"}.getStr(""))
    else: discard
  check("the notice folded between the two rounds",
        holdSeq == @["user", "hold-first", "notice", "notice-parent-done"],
        $holdSeq)

  report("AGENT WAKE")

main()
