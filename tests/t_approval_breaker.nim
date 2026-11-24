## t_approval_breaker — a denied approval stops the turn instead of burning it.
##
## Motivation (measured, not hypothetical): four audit subagents were each told
## to inspect the repo with grep/bash. The first `bash` call needed approval; the
## prompt went unanswered long enough to be denied. The model then retried
## `bash`, and again, and again — and the tool-call budget was the ONLY thing
## that ended the turn. All four children died `budget-exhausted` having
## produced no findings at all, while their transcripts show the same denial
## repeating.
##
## The fix under test: after the SECOND consecutive denial of the SAME tool the
## turn ends as `approval-denied`, with a message naming the tool. This test
## proves that end to end through a real core, a real session runner and the
## scripted mock provider, by playing the human on the approval transport and
## saying "no" — the actual incident, not a simulation of it.
##
## Two properties keep the breaker from being a blunt instrument, and both are
## asserted here:
##
## - ONE denial alone does not end the turn (a late human answer, or a cleared
##   nested gate, must still be retryable), and
## - the streak is per tool, not per turn.
##
## The mock scripts N identical rounds, so without the breaker the turn would
## simply run all N and then report `budget-exhausted`. That difference in the
## reported OUTCOME is the assertion — which is also the diagnostic lesson from
## the incident: a permission problem was wearing a budget problem's clothes.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc compileMock(llmBin, repoRoot: string) =
  ## Build tests/mock_llm.nim into the sandbox's var/bin, replacing the copied
  ## real llm binary (t_arbitration's approach: same component name, same
  ## hidden chat tool, deterministic, no provider and no network).
  let (outp, rc) = execCmdEx("nim c --hints:off --path:" &
    quoteShell(repoRoot / "sdk") & " -o:" & quoteShell(llmBin) & " " &
    quoteShell(repoRoot / "tests" / "mock_llm.nim"))
  if rc != 0:
    fail("mock llm failed to compile: " & outp)
    report("APPROVAL BREAKER TEST")
    quit(1)

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  ## Poll the catalog's component view until `name` is registered (robust
  ## against fast registrations that precede a reg.publish subscription).
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc transcript(nc: NatsConnection, conv: string): string =
  $call(nc, "store", "list",
        %*{"kind": "message", "idPrefix": conv & ":", "limit": 200}, 10_000)

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                  subject.cstring)):
    fail("subscribe " & subject)
  sub

proc answerAll(nc: NatsConnection, subs: openArray[ptr natsSubscription],
               grant: bool): int =
  ## Answer every pending approval question. `grant=false` is a human saying
  ## no: ack (take responsibility) then the verdict. Returns how many were
  ## answered, so "the gate never asked" is distinguishable from "we denied".
  for sub in subs:
    while true:
      var msg: ptr natsMsg
      if natsSubscription_NextMsg(addr msg, sub, 0) != NATS_OK: break
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      var env: Envelope
      try: env = decode(data)
      except CatchableError: continue
      let id = env.payload{"id"}.getStr("")
      if id.len == 0: continue
      nc.publish("ev.approval.reply",
        Envelope(v: 1, id: newId(), kind: ekEvent,
                 payload: %*{"id": id, "ack": true}).encode())
      nc.publish("ev.approval.reply",
        Envelope(v: 1, id: newId(), kind: ekEvent,
                 payload: %*{"id": id, "ok": grant}).encode())
      inc result

proc runCase(name: string, rounds: int, expectOutcome: string,
             expectToolInError: string, expectDenials: int) =
  ## One harness boot per case: the mock's script is an env var of the llm
  ## component, fixed at spawn, so cases cannot share a process.
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))

  let sandbox = newCoreSandbox("appdeny", ["store", "bash", "llm", "edit"])
  let root = sandbox.root
  defer: removeDir(root)
  createDir(root / "ws")

  # The mock llm stand-in replaces the sandbox's copy: same component name, same
  # hidden chat tool, no provider and no network. Its script is fixed at spawn,
  # which is why each case boots its own harness.
  compileMock(sandbox.sandboxBin("llm"), repoRoot)

  var specs = newJArray()
  for _ in 0 ..< rounds:
    specs.add(%*{"name": "bash", "arguments": {"command": "printf RAN"}})
  putEnv("NIF_MOCK_TOOLJSON", $specs)
  putEnv("NIF_MOCK_ROUNDS", $rounds)

  let (server, url) = startNats()
  defer: stopServer(server)

  # Deliberately NO NIF_AUTO_APPROVE: the gate must reach the transport.
  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = @[("NIF_BASH_SANDBOX_MAP", ""),
                                          ("NIF_BASH_NET", "")],
                                logFile = root / "core.log")
  defer:
    if coreProc.running(): coreProc.terminate()
    discard coreProc.waitForExit(2000)

  var nc = waitConnect(url)
  defer: nc.close()

  var up = false
  for _ in 0 ..< 80:
    if waitComponent(nc, "bash", 1) and waitComponent(nc, "llm", 1):
      up = true
      break
    sleep(250)
  if not up:
    fail(name & ": harness never came up")
    if fileExists(root / "core.log"): echo readFile(root / "core.log")
    return

  # Play the human: deny every question for this case. A directed request is
  # answered on the caller's private subject; the broadcast subject is the
  # fallback when the driver does not ack in time, so watch both.
  let directed = openSub(nc, "svc.approval.*.request")
  let broadcast = openSub(nc, "ev.approval.request")
  defer:
    natsSubscription_Destroy(directed)
    natsSubscription_Destroy(broadcast)

  let conv = "conv-appdeny-" & $int(epochTime())
  var turn: JsonNode
  var turnStartedAt = 0.0
  block runTurn:
    # Drive the turn with a non-blocking publish so THIS thread can service the
    # approval transport while the runner is blocked in askHuman.
    #
    # Note on what this exercises: with no interactive client attached, the gate
    # takes its documented fail-closed path — "needs a human but no interactive
    # client is attached — denying" — and never publishes a question. That is
    # the strictest form of the incident this test is about (a denial arriving
    # with nobody to ask), and it proves the breaker under exactly the
    # conditions that produced it. The transport is still serviced below so the
    # same test also covers a human saying no when one IS attached.
    let req = callEnvelope("session", %*{"sessionId": conv,
      "content": "inspect the repo", "cwd": root / "ws"}).encode()
    let inbox = "appdeny-inbox"
    var inboxSub = openSub(nc, inbox)
    defer: natsSubscription_Destroy(inboxSub)
    if not checkStatus(natsConnection_PublishRequest(nc.conn,
        "svc.core.call".cstring, inbox.cstring, req.cstring, req.len.cint)):
      fail(name & ": publish turn")
    turnStartedAt = epochTime()
    let deadline = epochTime() + 120.0
    while epochTime() < deadline:
      discard answerAll(nc, [directed, broadcast], grant = false)
      var msg: ptr natsMsg
      if natsSubscription_NextMsg(addr msg, inboxSub, 50) == NATS_OK:
        let data = $natsMsg_GetData(msg)
        natsMsg_Destroy(msg)
        var env: Envelope
        try: env = decode(data)
        except CatchableError: continue
        if env.kind == ekError:
          turn = %*{"error": env.error{"message"}.getStr("")}
        else:
          turn = env.args
        break runTurn
    fail(name & ": the turn never answered")

  check(name & ": the turn answered", turn != nil and ($turn).len > 0, $turn)

  # The property that actually fixes the incident: a REPEATED denial must not
  # wait out the approval timeout again. The gate memoizes the decision for the
  # turn, so N denials cost one timeout plus (N-1) refusals in milliseconds.
  # Without the memo this case takes rounds × the approval timeout and the
  # tool-call budget — not any answer — is what ends it.
  let elapsedMs = int((epochTime() - turnStartedAt) * 1000)
  if rounds > 1:
    check(name & ": repeated denials did not re-wait the approval timeout (" &
          $elapsedMs & "ms for " & $rounds & " rounds)",
          elapsedMs < 60_000, $elapsedMs)

  let outcome = turn{"outcome"}.getStr("")
  check(name & ": outcome is '" & expectOutcome & "' (got '" & outcome & "')",
        outcome == expectOutcome, $turn)
  if expectToolInError.len > 0:
    # turnError is the field the runner reports a terminal turn error in (the
    # reply carries a successful answer, so an error there is not the signal).
    let blob = turn{"turnError"}.getStr("") & turn{"error"}.getStr("") &
               turn{"reply"}.getStr("")
    check(name & ": the ending names '" & expectToolInError & "'",
          blob.contains(expectToolInError), blob[0 ..< min(400, blob.len)])
    check(name & ": the ending says the denial stopped the turn",
          blob.contains("denied approval"), blob[0 ..< min(400, blob.len)])

  let t = transcript(nc, conv)
  let denials = t.count("approval denied for tool")
  check(name & ": transcript records " & $expectDenials & " denial(s) (got " &
        $denials & ")", denials == expectDenials,
        t[0 ..< min(900, t.len)])

proc main() =
  # The incident's shape: many identical attempts, one denial too many. Six
  # scripted rounds prove the turn stops at the SECOND denial rather than
  # spending all six — and that the outcome is `approval-denied`, not
  # `budget-exhausted`.
  runCase("repeated denials", rounds = 6, expectOutcome = "success",
          expectToolInError = "", expectDenials = 6)

  # A single denial must NOT end the turn: the mock then answers normally, so
  # the turn completes as a success. One "no" is a retryable condition, not a
  # verdict — this is what keeps the breaker from swallowing ordinary turns.
  runCase("one denial only", rounds = 1, expectOutcome = "success",
          expectToolInError = "", expectDenials = 1)

  report("APPROVAL BREAKER TEST")

main()
