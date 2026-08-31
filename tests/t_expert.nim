## expert advisory peer tests (EXPERT.md).
##
## Boots a sandbox core (store + bash + git) with a test-only mock llm
## (tests/mock_llm.nim) and the expert component. One expert follows one
## working session; the scripted working turn calls bash, giving the expert a
## window to judge and deliver turn-bound advice mid-turn. Asserts the full
## loop: ev.session.turn start/done with a shared turnId, the advise
## request/reply accepted while the turn is live, the advisory folded into
## the conversation as a marked user message (and persisted), expert_status
## diagnostics, and stale-advise rejection after the turn ends.

import std/[json, os, osproc, strutils, times]
import natswrapper
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc adviseRequest(nc: NatsConnection, sessionId: string,
                   payload: JsonNode, timeoutMs = 10_000): JsonNode =
  ## Publish an advise request to the runner's turn-bound surface and return
  ## the {accepted, reason?} reply.
  let data = callEnvelope("advise", payload, "t-expert").encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn,
    ("svc.session." & sessionId & ".advise").cstring,
    data.cstring, data.len.cint, timeoutMs.int64)
  if st != NATS_OK:
    return %*{"error": "nats " & $st}
  let r = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  return r.args

proc drainTurnEvents(sub: ptr natsSubscription): seq[JsonNode] =
  ## Collect whatever ev.session.turn events are queued right now.
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 100)
    if st != NATS_OK: break
    let env = decode($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if env.kind == ekEvent and env.payload != nil:
      result.add(env.payload)

proc stopHard(p: var Process) =
  if p != nil and p.running():
    p.terminate()
    sleep(500)
    if p.running(): p.kill()
    sleep(100)
  if p != nil: p.close()
  p = nil

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "session", "store", "bash", "git", "expert"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("expert", ["store", "bash", "git", "llm",
                                          "expert"])
  let root = sandbox.root
  echo "sandbox root: ", root
  # Replace the copied real llm binary with the test-only mock (no provider,
  # no network): same component name, same hidden chat tool contract.
  let llmBin = sandbox.sandboxBin("llm")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & llmBin,
    repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("mock llm failed to compile")
    quit(1)
  # NOTE: sandbox intentionally kept on failure for post-mortem (cleaned by OS)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")],
                                logFile = "/tmp/opencode/core-expert.log")
  defer: stopHard(coreProc)

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  # The manifest autostarts every sandbox component; wait for the ones the
  # scenario actually depends on (llm + expert register their tools, git
  # provides the git_diff tool the mock's steer names).
  check("store registered", waitComponent(nc, "store"))
  check("mock llm registered", waitComponent(nc, "llm"))
  check("git registered", waitComponent(nc, "git"))
  check("expert registered", waitComponent(nc, "expert"))

  # Watch the turn lifecycle events for the session we are about to run.
  var turnSub: ptr natsSubscription
  let tst = natsConnection_SubscribeSync(addr turnSub, nc.conn,
                                         "ev.session.turn".cstring)
  check("subscribe ev.session.turn", checkStatus(tst))
  defer: natsSubscription_Destroy(turnSub)

  let sessionId = "conv-expert-" & $int(epochTime())

  # Arm the expert BEFORE the turn so it sees the turn-start event.
  let follow = call(nc, "expert", "expert_follow",
                    %*{"session_id": sessionId}, 15_000)
  check("expert_follow ok", follow{"ok"}.getBool(false), $follow)
  check("expert_follow captured knowledge",
        follow{"knowledgeVersion"}.getStr("").len > 0, $follow)

  # One working turn: mock round 1 returns a bash tool_call (the expert gets
  # its mid-turn window), the advisory is folded, round 2 ends the turn.
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sessionId, "content": "Show me the diff"},
                  120_000)
  check("turn ok", turn{"error"} == nil, $turn)
  check("turn reply is the scripted final",
        turn{"reply"}.getStr("") == "working-done", $turn)

  # Turn lifecycle: start + done sharing one non-empty turnId, start carries
  # the user request.
  let events = drainTurnEvents(turnSub)
  var startEv: JsonNode = nil
  var doneEv: JsonNode = nil
  for e in events:
    if e{"phase"}.getStr("") == "start" and startEv == nil: startEv = e
    if e{"phase"}.getStr("") == "done" and doneEv == nil: doneEv = e
  check("turn start event seen", startEv != nil, $events)
  check("turn done event seen", doneEv != nil, $events)
  if startEv != nil and doneEv != nil:
    let tid = startEv{"turnId"}.getStr("")
    check("turnId non-empty", tid.len > 0, $startEv)
    check("turn events share turnId",
          tid == doneEv{"turnId"}.getStr(""), $doneEv)
    check("turn start carries the user request",
          startEv{"content"}.getStr("") == "Show me the diff", $startEv)

  # The advisory was accepted mid-turn and folded into the conversation as a
  # marked user message (persisted via the store).
  let msgs = call(nc, "store", "list",
                  %*{"kind": "message", "idPrefix": sessionId & ":",
                     "limit": 200}, 10_000)
  check("advisory folded into transcript",
        ($msgs).contains("[Niffler advisor: expert]"), $msgs)

  # Diagnostics reflect one accepted steer.
  let status = call(nc, "expert", "expert_status", %*{}, 10_000)
  check("expert_status ok", status{"ok"}.getBool(false), $status)
  check("expert_status target", status{"target"}.getStr("") == sessionId,
        $status)
  check("expert saw a steer", status{"steers"}.getInt(0) >= 1, $status)
  check("expert steer accepted", status{"accepted"}.getInt(0) >= 1, $status)

  # Turn-bound guarantee: after the turn, a late advise is rejected, never
  # queued into the next turn.
  let late = adviseRequest(nc, sessionId, %*{
    "sessionId": sessionId, "turnId": "turn-bogus",
    "kind": "advisor", "source": "expert", "content": "late advice"})
  check("late advise rejected", late{"accepted"}.getBool(false) == false,
        $late)
  check("late advise reason",
        late{"reason"}.getStr("") in ["no-active-turn", "stale-turn"], $late)

  report("EXPERT")

main()
