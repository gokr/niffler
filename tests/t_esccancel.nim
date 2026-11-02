## The reported "ESC twice" sequence, end to end on one conversation.
##
## Focused and fast so the mid-turn cancellation timing can be tuned without
## paying for the whole t_controls suite.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc buildMockLlm(sandbox: TestSandbox) =
  ## Deterministic test LLM (tests/mock_llm.nim): no provider, no network.
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & sandbox.repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"),
    sandbox.repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, fixtureCompileTimeoutMs) != 0:
    fail("mock llm failed to compile")
    quit(1)
  compiler.close()

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc publishCall(nc: NatsConnection, subject, reply: string, env: Envelope) =
  let data = env.encode()
  if not checkStatus(natsConnection_PublishRequest(nc.conn, subject.cstring,
                                                   reply.cstring, data.cstring,
                                                   data.len.cint)):
    fail("publish to " & subject)

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  doAssert checkStatus(natsConnection_SubscribeSync(addr result, nc.conn,
                                                    subject.cstring))

proc pollEnv(sub: ptr natsSubscription, ms: int): tuple[found: bool, env: Envelope] =
  var msg: ptr natsMsg
  let st = natsSubscription_NextMsg(addr msg, sub, ms.cint)
  if st == NATS_TIMEOUT: return (false, Envelope())
  if not checkStatus(st): return (false, Envelope())
  result.env = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  result.found = true

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  let sandbox = newCoreSandbox("esccancel", ["store", "bash", "llm"])
  buildMockLlm(sandbox)
  let root = sandbox.root
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var core = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                            extra = [("NIF_AUTO_APPROVE", "1"),
                                     ("NIF_MOCK_ROUNDS", "3"),
                                     ("NIF_MOCK_TOOLCMD", "sleep 4")],
                            logFile = root / "var" / "test-logs" / "core.log")
  defer:
    if core.running(): core.terminate()
    discard core.waitForExit(3000)
  doAssert waitComponent(nc, "store"), "store"
  doAssert waitComponent(nc, "llm"), "llm"

  let sid = "esc-" & $int(epochTime())
  proc startTurn(content: string): ptr natsSubscription =
    let inbox = "_INBOX.esc." & newId()
    result = openSub(nc, inbox)
    publishCall(nc, "svc.core.call", inbox,
                callEnvelope("session", %*{"sessionId": sid,
                                           "content": content}, "probe"))
  proc awaitReply(sub: ptr natsSubscription, secs: float): JsonNode =
    let deadline = epochTime() + secs
    while epochTime() < deadline:
      let polled = pollEnv(sub, 50)
      if polled.found: return polled.env.args
    nil

  # Watch for the turn actually STARTING: a cancel published before runTurn
  # begins is (correctly) discarded as stale, so publishing on a blind sleep
  # tested the wrong thing.
  # ev.session.<id>.toolcall: proof the turn is genuinely working (there is
  # no "turnstart" event), so a cancel published after it is LIVE and must
  # count — not a stale leftover the turn boundary discards.
  let turnSub = openSub(nc, "ev.session." & sid & ".toolcall")
  defer: natsSubscription_Destroy(turnSub)

  let sub1 = startTurn("work")
  defer: natsSubscription_Destroy(sub1)
  var started = false
  let startDeadline = epochTime() + 30.0
  while not started and epochTime() < startDeadline:
    started = pollEnv(turnSub, 50).found
  check("the turn started (so the cancels below are live, not stale)", started)

  for i in 1 .. 2:
    nc.publish("svc.session." & sid & ".steer",
      Envelope(v: 1, id: "esc-" & $i, kind: ekEvent,
               payload: %*{"__cancel": true}).encode())
    sleep(150)
  let first = awaitReply(sub1, 60.0)
  echo "turn1 turnError=", first{"turnError"}.getStr(""), " outcome=",
       first{"outcome"}.getStr(""), " durMs=", first{"usage"}{"durationMs"}.getInt(0)
  check("esc twice: the first turn ends cancelled",
        first != nil and first{"turnError"}.getStr("").contains("cancelled"),
        $first)

  # The human now types "continue": it must RUN, produce exactly one user
  # message, and add no second cancellation.
  let sub2 = startTurn("continue")
  defer: natsSubscription_Destroy(sub2)
  let second = awaitReply(sub2, 90.0)
  check("the following 'continue' RUNS to completion",
        second != nil and second{"turnError"}.getStr("") == "", $second)
  check("and it produced a real answer",
        second != nil and second{"reply"}.getStr("").len > 0, $second)

  let msgs = call(nc, "store", "list",
                  %*{"kind": "message", "idPrefix": sid & ":", "limit": 200},
                  10_000)
  var continues = 0
  var cancelledErrors = 0
  for m in msgs{"items"}:
    let v = m{"value"}
    if v{"role"}.getStr("") == "user" and v{"content"}.getStr("") == "continue":
      inc continues
    if v{"role"}.getStr("") == "error" and
        v{"content"}.getStr("").contains("cancelled"):
      inc cancelledErrors
  check("exactly one 'continue' user message (no duplicate)",
        continues == 1, "found " & $continues)
  # The cancellation is reported in the turn RESULT (turnError, asserted
  # above), not written as an error row — a cancel is a normal outcome, not a
  # failure to persist. So the transcript must carry NO cancellation text at
  # all: one would mean a stray cancel leaked into history.
  check("no cancellation leaked into the transcript as an error row",
        cancelledErrors == 0, "found " & $cancelledErrors)

  report("ESC CANCEL TEST")

main()
