## t_controls — conversation controls: /approvals, /limit and the keep-going
## question (docs/WIRE.md "Conversation controls").
##
## Contract under test:
## - `session {approvals}` sets this conversation's gate mode: ""/"ask" gates
##   every x-harness.approval tool, "auto" grants them without asking anyone;
## - `session {limits}` sets the human's SOFT turn limits (rounds/tokens/
##   seconds): reaching one asks the human "keep going?" over the approval
##   transport instead of ending the turn, and a yes extends that limit by one
##   step. Job-scoped budgets (maxRounds/maxCalls/maxTokens) stay hard and
##   never ask — a subagent cannot negotiate its own budget;
## - both controls persist in the conversation header, are echoed by the status
##   readback and the turn result, and are validated (bad values are refused);
## - a session call that arrives while a turn is running is refused with
##   "busy" instead of being left unanswered until the client's deadline (the
##   /export hang: a 10s client deadline against a turn-length wait).
##
## Everything runs against a sandbox core plus the test-only mock LLM
## (tests/mock_llm.nim, NIF_MOCK_ROUNDS scripted bash rounds), with this test
## process acting as the human on svc.approval.<caller>.request.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

# ---------------------------------------------------------------------------
# fixture: sandbox core + mock LLM

type
  Probe = object
    sandbox: TestSandbox
    server: Process
    nc: NatsConnection
    core: Process

proc buildMockLlm(sandbox: TestSandbox) =
  ## Replace the sandbox's llm binary with the deterministic test mock
  ## (t_expert/t_ctxcompact pattern): no provider, no network.
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & sandbox.repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"),
    sandbox.repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, 180_000) != 0:
    fail("mock llm failed to compile")
    quit(1)
  compiler.close()

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  ## Wait for a component to appear in core's authoritative catalog snapshot.
  ## Not `reg.publish`: that announcement is fire-once per connect, so a
  ## fast-booting child (the mock LLM) can beat this process's subscription
  ## and then never be seen again.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc startProbe(tag: string, extra: seq[(string, string)] = @[]): Probe =
  result.sandbox = newCoreSandbox(tag, ["store", "bash", "llm"])
  buildMockLlm(result.sandbox)
  let started = startNats()
  result.server = started.prc
  result.nc = waitConnect(started.url)
  # NIF_AUTO_APPROVE=0 / NIF_AUTO_CONTINUE=0: the gate must be live, whatever
  # the ambient environment says (the suite may run under automation).
  var env = @[("NIF_AUTO_APPROVE", "0"), ("NIF_AUTO_CONTINUE", "0")]
  for kv in extra: env.add(kv)
  result.core = startComponent(result.sandbox.sandboxBin("niffler"),
                               started.url, root = result.sandbox.root,
                               extra = env,
                               logFile = result.sandbox.root / "var" /
                                         "test-logs" / "core-" & tag & ".log")
  doAssert waitComponent(result.nc, "store"), tag & ": store did not register"
  doAssert waitComponent(result.nc, "llm"), tag & ": llm did not register"

proc stopProbe(p: var Probe) =
  if p.core != nil: stopProcess(p.core)
  p.nc.close()
  if p.server != nil: stopServer(p.server)
  if p.sandbox.root.len > 0: removeDir(p.sandbox.root)

# ---------------------------------------------------------------------------
# the approval transport, from this process's side

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                  subject.cstring)):
    fail("subscribe " & subject)
  sub

proc pollEnv(sub: ptr natsSubscription,
             timeoutMs: int64): tuple[found: bool, env: Envelope] =
  ## Poll one message; found is false when nothing arrived within the timeout.
  var msg: ptr natsMsg
  if natsSubscription_NextMsg(addr msg, sub, timeoutMs) != NATS_OK:
    return (false, Envelope())
  let data = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
  try:
    return (true, decode(data))
  except CatchableError:
    return (false, Envelope())

proc serviceQuestions(nc: NatsConnection, subs: openArray[ptr natsSubscription],
                      answer: string, seen: var seq[JsonNode]): int =
  ## Answer every pending question on the approval transport: ack first (take
  ## responsibility), then the verdict. `answer` is "yes" (keep going / grant),
  ## "no" (stop / deny) or "silent" (answer nothing at all — the fail-closed
  ## path: the gate finds no human and denies).
  for sub in subs:
    var polled = pollEnv(sub, 0)
    while polled.found:
      let payload = polled.env.payload
      seen.add(payload)
      let id = payload{"id"}.getStr("")
      if answer != "silent":
        nc.publish("ev.approval.reply",
          Envelope(v: 1, id: newId(), kind: ekEvent,
                   payload: %*{"id": id, "ack": true}).encode())
        nc.publish("ev.approval.reply",
          Envelope(v: 1, id: newId(), kind: ekEvent,
                   payload: %*{"id": id, "ok": answer == "yes"}).encode())
      inc result
      polled = pollEnv(sub, 0)

proc publishCall(nc: NatsConnection, subject, reply: string, env: Envelope) =
  let data = env.encode()
  if not checkStatus(natsConnection_PublishRequest(nc.conn, subject.cstring,
                                                   reply.cstring, data.cstring,
                                                   data.len.cint)):
    fail("publish to " & subject)

proc callerOf(env: Envelope): JsonNode =
  ## Normalize a call reply: the payload either way (error or result).
  if env.kind == ekError:
    return %*{"error": env.error{"message"}.getStr("component error"),
              "code": env.error{"code"}.getStr("")}
  env.args

proc driveTurn(p: Probe, args: JsonNode, caller = "probe",
               answer = "yes", seen: var seq[JsonNode],
               timeoutMs = 120_000): JsonNode =
  ## Send one session call and stay on the approval transport while it runs,
  ## so a turn that asks a question gets an answer. Returns the reply payload
  ## (an {"error": ...} object on failure or timeout).
  let nc = p.nc
  let inbox = "_INBOX.controls." & newId()
  let replies = openSub(nc, inbox)
  let directed = openSub(nc, "svc.approval." & caller & ".request")
  let broadcast = openSub(nc, "ev.approval.request")
  defer:
    natsSubscription_Destroy(replies)
    natsSubscription_Destroy(directed)
    natsSubscription_Destroy(broadcast)
  publishCall(nc, "svc.core.call", inbox,
              callEnvelope("session", args, caller))
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    discard serviceQuestions(nc, [directed, broadcast], answer, seen)
    let polled = pollEnv(replies, 20)
    if polled.found: return callerOf(polled.env)
  return %*{"error": "timeout driving session call"}

proc toolText(nc: NatsConnection, sessionId: string): string =
  ## Concatenated tool-role message bodies of one conversation.
  let msgs = call(nc, "store", "list",
                  %*{"kind": "message", "idPrefix": sessionId & ":",
                     "limit": 200}, 15_000)
  result = ""
  if msgs{"items"} == nil: return
  for item in msgs{"items"}:
    let v = item{"value"}
    if v{"role"}.getStr("") == "tool":
      result.add(v{"content"}.getStr("") & "\n")

proc errorRecords(nc: NatsConnection, sessionId: string): seq[JsonNode] =
  ## The audit records a turn end writes (role "error").
  let msgs = call(nc, "store", "list",
                  %*{"kind": "message", "idPrefix": sessionId & ":",
                     "limit": 200}, 15_000)
  result = @[]
  if msgs{"items"} == nil: return
  for item in msgs{"items"}:
    let v = item{"value"}
    if v{"role"}.getStr("") == "error":
      result.add(v)

proc limitQuestions(seen: openArray[JsonNode]): seq[JsonNode] =
  ## Only the turn-limit questions (bash approvals share the transport).
  result = @[]
  for q in seen:
    if q{"tool"}.getStr("") == "turn-limit": result.add(q)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(resolveStoreBin(repoRoot)):
    fail("missing store binary — run `make build` first")
    quit(1)

  # -------------------------------------------------------------------------
  # 1. the controls themselves: set, read back, validate, persist, clear
  block controls:
    var p = startProbe("controls")
    defer: p.stopProbe()
    let nc = p.nc
    let sid = "controls-" & $int(epochTime())

    let setMode = call(nc, "core", "session",
                       %*{"sessionId": sid, "approvals": "auto"}, 60_000)
    check("approvals auto is accepted", setMode{"error"} == nil and
          setMode{"approvals"}.getStr("") == "auto", $setMode)

    # A bare sessionId is the read-only status readback.
    let st = call(nc, "core", "session", %*{"sessionId": sid}, 60_000)
    check("status readback echoes the gate mode",
          st{"approvals"}.getStr("") == "auto" and
          st{"limits"}{"rounds"}.getInt(-1) == 0, $st)

    let setLimits = call(nc, "core", "session",
      %*{"sessionId": sid, "limits": %*{"rounds": 2, "tokens": 5000}}, 60_000)
    check("limits are accepted and echoed",
          setLimits{"limits"}{"rounds"}.getInt(0) == 2 and
          setLimits{"limits"}{"tokens"}.getInt(0) == 5000 and
          setLimits{"limits"}{"seconds"}.getInt(-1) == 0, $setLimits)

    let header = call(nc, "store", "get",
                      %*{"kind": "conversation", "id": sid}, 15_000)
    check("controls persist in the conversation header",
          header{"value"}{"approvals"}.getStr("") == "auto" and
          header{"value"}{"limits"}{"rounds"}.getInt(0) == 2, $header)

    let badMode = call(nc, "core", "session",
                       %*{"sessionId": sid, "approvals": "sometimes"}, 60_000)
    check("an unknown gate mode is refused",
          badMode{"error"}.getStr("").contains("ask or auto"), $badMode)
    let badRound = call(nc, "core", "session",
      %*{"sessionId": sid, "limits": %*{"rounds": 0}}, 60_000)
    check("zero is not a limit",
          badRound{"error"}.getStr("").contains("between 1 and 200"),
          $badRound)
    let badKey = call(nc, "core", "session",
      %*{"sessionId": sid, "limits": %*{"nope": 3}}, 60_000)
    check("an unknown limit name is refused",
          badKey{"error"}.getStr("").contains("unknown limit"), $badKey)
    let badSeconds = call(nc, "core", "session",
      %*{"sessionId": sid, "limits": %*{"seconds": 999_999}}, 60_000)
    check("a limit beyond its ceiling is refused",
          badSeconds{"error"}.getStr("").contains("between 1 and 86400"),
          $badSeconds)

    let cleared = call(nc, "core", "session",
      %*{"sessionId": sid, "limits": %*{}, "approvals": ""}, 60_000)
    check("empty values clear both controls",
          cleared{"approvals"}.getStr("") == "" and
          cleared{"limits"}{"rounds"}.getInt(-1) == 0 and
          cleared{"limits"}{"tokens"}.getInt(-1) == 0, $cleared)

  # -------------------------------------------------------------------------
  # 2. approvals auto really grants; ask without a human really denies
  block gate:
    var p = startProbe("gate", @[("NIF_MOCK_ROUNDS", "1"),
                                 ("NIF_MOCK_TOOLCMD", "echo controls-ok")])
    defer: p.stopProbe()
    let nc = p.nc

    let autoSid = "gate-auto-" & $int(epochTime())
    let autoSet = call(nc, "core", "session",
                       %*{"sessionId": autoSid, "approvals": "auto"}, 60_000)
    check("gate: mode set", autoSet{"approvals"}.getStr("") == "auto", $autoSet)
    var autoSeen: seq[JsonNode] = @[]
    let autoTurn = driveTurn(p, %*{"sessionId": autoSid,
                                   "content": "run the gated tool"},
                             answer = "silent", seen = autoSeen)
    check("gate: turn completes in auto mode",
          autoTurn{"error"} == nil and autoTurn{"turnError"}.getStr("") == "",
          $autoTurn)
    check("gate: the gated tool ran and nobody was asked",
          autoSeen.len == 0 and toolText(nc, autoSid).contains("controls-ok"),
          "questions=" & $autoSeen.len & " text=" & toolText(nc, autoSid))

    let askSid = "gate-ask-" & $int(epochTime())
    var askSeen: seq[JsonNode] = @[]
    let askTurn = driveTurn(p, %*{"sessionId": askSid,
                                  "content": "run the gated tool"},
                            answer = "silent", seen = askSeen)
    check("gate: the turn still completes when the call is denied",
          askTurn{"error"} == nil, $askTurn)
    check("gate: the call was asked about and denied without a human",
          askSeen.len == 1 and toolText(nc, askSid).contains("approval denied"),
          "questions=" & $askSeen.len & " text=" & toolText(nc, askSid))

  # -------------------------------------------------------------------------
  # 3. a soft round limit asks; yes continues the turn, no ends it
  # 4. a job-scoped round budget stays hard and never asks
  block limits:
    var p = startProbe("limits", @[("NIF_MOCK_ROUNDS", "3"),
                                   ("NIF_MOCK_TOOLCMD", "true")])
    defer: p.stopProbe()
    let nc = p.nc

    let yesSid = "limit-yes-" & $int(epochTime())
    discard call(nc, "core", "session",
                 %*{"sessionId": yesSid, "limits": %*{"rounds": 1}}, 60_000)
    var yesSeen: seq[JsonNode] = @[]
    let yesTurn = driveTurn(p, %*{"sessionId": yesSid, "content": "keep working"},
                            answer = "yes", seen = yesSeen)
    let yesQuestions = limitQuestions(yesSeen)
    check("soft limit: the turn asked before giving up",
          yesQuestions.len >= 1, $yesSeen)
    check("soft limit: the question names the dimension, the detail and the session",
          yesQuestions.len > 0 and
          yesQuestions[0]{"purpose"}.getStr("") == "continue" and
          yesQuestions[0]{"args"}{"dimension"}.getStr("") == "rounds" and
          yesQuestions[0]{"args"}{"detail"}.getStr("").contains("limit 1") and
          yesQuestions[0]{"sessionId"}.getStr("") == yesSid, $yesQuestions)
    check("soft limit: a yes lets the turn finish",
          yesTurn{"error"} == nil and yesTurn{"turnError"}.getStr("") == "" and
          yesTurn{"reply"}.getStr("").contains("done"), $yesTurn)

    let noSid = "limit-no-" & $int(epochTime())
    discard call(nc, "core", "session",
                 %*{"sessionId": noSid, "limits": %*{"rounds": 1}}, 60_000)
    var noSeen: seq[JsonNode] = @[]
    let noTurn = driveTurn(p, %*{"sessionId": noSid, "content": "keep working"},
                           answer = "no", seen = noSeen)
    check("soft limit: a no ends the turn, named as a limit not a failure",
          noTurn{"turnError"}.getStr("").contains("turn limit reached"),
          $noTurn)
    var sawLimitRecord = false
    for rec in errorRecords(nc, noSid):
      if rec{"error"}.getStr("") == "limit-rounds": sawLimitRecord = true
    check("soft limit: the transcript records a distinct limit error kind",
          sawLimitRecord, $errorRecords(nc, noSid))
    let after = call(nc, "core", "session", %*{"sessionId": noSid}, 60_000)
    check("soft limit: the conversation and its limits survive the turn end",
          after{"limits"}{"rounds"}.getInt(0) == 1, $after)

    # job-scoped budget: hard, silent, never asks
    let jobSid = "limit-job-" & $int(epochTime())
    var jobSeen: seq[JsonNode] = @[]
    let jobTurn = driveTurn(p, %*{"sessionId": jobSid,
                                  "content": "keep working", "maxRounds": 1},
                            answer = "yes", seen = jobSeen)
    check("job budget: still ends the turn hard",
          jobTurn{"turnError"}.getStr("").contains("round budget exhausted"),
          $jobTurn)
    check("job budget: a subagent cannot negotiate its budget",
          limitQuestions(jobSeen).len == 0, $jobSeen)

  # -------------------------------------------------------------------------
  # 5. the seconds limit is checked while a tool call is in flight
  block seconds:
    var p = startProbe("seconds", @[("NIF_MOCK_ROUNDS", "2"),
                                    ("NIF_MOCK_TOOLCMD", "sleep 2")])
    defer: p.stopProbe()
    let nc = p.nc
    let sid = "limit-seconds-" & $int(epochTime())
    discard call(nc, "core", "session",
                 %*{"sessionId": sid, "limits": %*{"seconds": 1}}, 60_000)
    var seen: seq[JsonNode] = @[]
    let turn = driveTurn(p, %*{"sessionId": sid, "content": "work for a while"},
                         answer = "yes", seen = seen)
    let questions = limitQuestions(seen)
    check("seconds limit: the turn asked about the clock",
          questions.len >= 1 and
          questions[0]{"args"}{"dimension"}.getStr("") == "seconds",
          $questions)
    check("seconds limit: a yes lets the turn finish",
          turn{"error"} == nil and turn{"turnError"}.getStr("") == "", $turn)

  # -------------------------------------------------------------------------
  # 6. a session call that arrives mid-turn is refused with "busy"
  # (the /export hang: the client's deadline expired against a turn-length
  # wait; the runner now answers instead of staying silent)
  block midTurnBusy:
    var p = startProbe("busy", @[("NIF_MOCK_ROUNDS", "2"),
                                 ("NIF_MOCK_TOOLCMD", "sleep 20")])
    defer: p.stopProbe()
    let nc = p.nc
    let sid = "busy-" & $int(epochTime())
    var seen: seq[JsonNode] = @[]

    let inbox = "_INBOX.busy." & newId()
    let replies = openSub(nc, inbox)
    let directed = openSub(nc, "svc.approval.probe.request")
    let turns = openSub(nc, "ev.session.turn")
    let calls = openSub(nc, "ev.session.toolcall")
    defer:
      natsSubscription_Destroy(replies)
      natsSubscription_Destroy(directed)
      natsSubscription_Destroy(turns)
      natsSubscription_Destroy(calls)
    publishCall(nc, "svc.core.call", inbox,
                callEnvelope("session", %*{"sessionId": sid, "content": "work"},
                             "probe"))

    # Wait for the turn to start (the runner is now inside runTurn).
    var started = false
    let startDeadline = epochTime() + 60.0
    while not started and epochTime() < startDeadline:
      discard serviceQuestions(nc, [directed], "yes", seen)
      let polled = pollEnv(turns, 50)
      if polled.found and polled.env.payload{"phase"}.getStr("") == "start":
        started = true
    check("mid-turn: the turn started", started)

    # Wait until the turn is provably inside a tool DISPATCH: that is the
    # window whose idle slots pump the runner's call subject (an approval
    # wait has its own loop and answers nothing). The scripted bash call
    # sleeps, so the window is wide.
    var dispatching = false
    let dispatchDeadline = epochTime() + 30.0
    while not dispatching and epochTime() < dispatchDeadline:
      discard serviceQuestions(nc, [directed], "yes", seen)
      let polled = pollEnv(calls, 50)
      if polled.found and polled.env.payload{"phase"}.getStr("") == "start" and
          polled.env.payload{"tool"}.getStr("") == "bash":
        dispatching = true
    check("mid-turn: a tool dispatch is in flight", dispatching)

    # A read-only session call is now answered at once with busy — no hang.
    let busyInbox = "_INBOX.busy2." & newId()
    let busyReplies = openSub(nc, busyInbox)
    defer: natsSubscription_Destroy(busyReplies)
    let askedAt = epochTime()
    publishCall(nc, "svc.core.call", busyInbox,
                callEnvelope("session", %*{"sessionId": sid}))
    var refusal: string = ""
    var observed: string = "no reply"
    # A window well inside one scripted bash call (sleep 20): the turn cannot
    # end before this, so a late answer cannot masquerade as a fast one.
    let busyDeadline = epochTime() + 5.0
    while refusal.len == 0 and epochTime() < busyDeadline:
      let polled = pollEnv(busyReplies, 50)
      if polled.found:
        observed = $callerOf(polled.env)
        refusal = callerOf(polled.env){"error"}.getStr("")
        # A status-shaped answer means the call was served normally instead:
        # a timing failure, not a pass — and its shape is what we want to see.
        if refusal.len == 0:
          refusal = "(served as a normal status call: " & observed[0 ..< 80] & ")"
    let elapsed = epochTime() - askedAt
    check("mid-turn: the call is answered at once, not left hanging",
          refusal.len > 0 and elapsed < 10.0,
          "in " & $elapsed & "s: " & refusal & " | " & observed)
    check("mid-turn: the refusal names the reason",
          refusal.contains("mid-turn — retry"), refusal)

    # A client that addresses the RUNNER directly (svc.session.<id>.call, the
    # docs' "clients keep a single stable address" notwithstanding) gets the
    # same refusal from the runner's own idle-slot pump.
    let directInbox = "_INBOX.busy3." & newId()
    let directReplies = openSub(nc, directInbox)
    defer: natsSubscription_Destroy(directReplies)
    let directAt = epochTime()
    publishCall(nc, "svc.session." & sid & ".call", directInbox,
                callEnvelope("session", %*{"sessionId": sid}))
    var directRefusal: string = ""
    var directObserved: string = "no reply"
    let directDeadline = epochTime() + 5.0
    while directRefusal.len == 0 and epochTime() < directDeadline:
      let polled = pollEnv(directReplies, 50)
      if polled.found:
        directObserved = $callerOf(polled.env)
        directRefusal = callerOf(polled.env){"error"}.getStr("")
        if directRefusal.len == 0:
          directRefusal = "(served normally: " & directObserved[0 ..< 80] & ")"
    check("mid-turn: a direct runner call is refused just as fast",
          directRefusal.contains("mid-turn — retry") and
          epochTime() - directAt < 5.0,
          directRefusal & " | " & directObserved)

    # The turn itself is unaffected: it finishes normally.
    var turnReply: JsonNode = nil
    let doneDeadline = epochTime() + 60.0
    while turnReply == nil and epochTime() < doneDeadline:
      discard serviceQuestions(nc, [directed], "yes", seen)
      let polled = pollEnv(replies, 50)
      if polled.found: turnReply = callerOf(polled.env)
    check("mid-turn: the running turn still finishes",
          turnReply != nil and turnReply{"turnError"}.getStr("") == "",
          $turnReply)

  report("CONTROLS")

main()
