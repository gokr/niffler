## t_session_usage — per-turn authoritative usage and outcome (issue #123).
##
## Contract under test (docs/WIRE.md "Turn usage"):
## - a session turn's final result carries `turnId`, `outcome` and a `usage`
##   object accounting for THIS activation only — the successful provider
##   responses of this turn, summed. A resumed turn starts empty: a driver is
##   never charged again for an earlier execution of the same conversation.
## - the terminal `turn` phase:done frame carries the SAME object, so a client
##   disconnected from the request reply reconciles by turnId; the legacy
##   `done` frame keeps its reply/error-only shape so a naive client cannot
##   double count two frames.
## - cancellation and budget endings keep the usage of the rounds that did
##   complete, and a counter the provider never reported is ABSENT, never a
##   fabricated zero.
## - descendants are excluded explicitly (`descendantsExcluded`).
##
## Runs against a sandbox core plus the test-only mock LLM
## (tests/mock_llm.nim: NIF_MOCK_ROUNDS scripted rounds, NIF_MOCK_USAGE_DETAILS
## deterministic cache/reasoning breakdowns, NIF_MOCK_TOOLCMD the scripted
## tool).

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

type
  Frame = tuple[kind: string, payload: JsonNode]
  Probe = object
    sandbox: TestSandbox
    server: Process
    nc: NatsConnection
    core: Process

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  ## Membership comes from core's authoritative catalog snapshot; a raw
  ## reg.publish announcement is fire-once and can be missed.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc startProbe(tag: string, extra: seq[(string, string)]): Probe =
  ## Sandbox core (store + bash + llm) with the mock LLM in the llm slot.
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  result.sandbox = newCoreSandbox(tag, ["store", "bash", "llm"])
  discard fixtureBin(result.sandbox, "llm", repoRoot / "tests" / "mock_llm.nim",
                     prebuiltName = "fixture-mock-llm")
  let (server, url) = startNats()
  result.server = server
  result.nc = waitConnect(url)
  # The gate must be live (the soft-limit case relies on a question nobody
  # answers resolving to a denial), whatever the ambient environment says.
  var env = @[("NIF_AUTO_APPROVE", "0"), ("NIF_AUTO_CONTINUE", "0")]
  for kv in extra: env.add(kv)
  result.core = startComponent(result.sandbox.sandboxBin("niffler"),
                               url, root = result.sandbox.root,
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

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                  subject.cstring)):
    fail("subscribe " & subject)
  sub

proc pollEnv(sub: ptr natsSubscription,
             timeoutMs: int64): tuple[found: bool, env: Envelope] =
  var msg: ptr natsMsg
  if natsSubscription_NextMsg(addr msg, sub, timeoutMs) != NATS_OK:
    return (false, Envelope())
  let data = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
  try:
    return (true, decode(data))
  except CatchableError:
    return (false, Envelope())

proc callerOf(env: Envelope): JsonNode =
  if env.kind == ekError:
    return %*{"error": env.error{"message"}.getStr("component error")}
  env.args

proc driveTurn(p: Probe, sid: string, args: JsonNode, frames: var seq[Frame],
               cancelAfterToolcalls = -1,
               timeoutMs = 120_000, steerContent = ""): JsonNode =
  ## Run one session call while watching the conversation's frames. With
  ## cancelAfterToolcalls >= 0 the __cancel control is published to the steer
  ## channel once that many toolcall-start frames have been seen (the scripted
  ## bash call is what keeps the turn alive long enough to interrupt).
  let nc = p.nc
  let inbox = "_INBOX.usage." & newId()
  let replies = openSub(nc, inbox)
  let turns = openSub(nc, "ev.session." & sid & ".turn")
  let toolcalls = openSub(nc, "ev.session." & sid & ".toolcall")
  let dones = openSub(nc, "ev.session." & sid & ".done")
  let sentSteers = openSub(nc, "ev.session." & sid & ".steer_sent")
  defer:
    natsSubscription_Destroy(replies)
    natsSubscription_Destroy(turns)
    natsSubscription_Destroy(toolcalls)
    natsSubscription_Destroy(dones)
    natsSubscription_Destroy(sentSteers)
  let data = callEnvelope("session", args, "probe").encode()
  if not checkStatus(natsConnection_PublishRequest(nc.conn, "svc.core.call".cstring,
                                                   inbox.cstring, data.cstring,
                                                   data.len.cint)):
    fail("publish session call")
  var startedToolcalls = 0
  var cancelled = false
  var steered = false
  var reply: JsonNode = nil
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while reply == nil and epochTime() < deadline:
    var polled = pollEnv(turns, 0)
    while polled.found:
      frames.add(("turn", polled.env.payload))
      polled = pollEnv(turns, 0)
    polled = pollEnv(toolcalls, 0)
    while polled.found:
      frames.add(("toolcall", polled.env.payload))
      if polled.env.payload{"phase"}.getStr("") == "start" and
          steerContent.len > 0 and not steered:
        steered = true
        nc.publish("svc.session." & sid & ".steer",
          Envelope(v: 1, id: newId(), kind: ekEvent,
                   payload: %*{"content": steerContent}).encode())
      if polled.env.payload{"phase"}.getStr("") == "start" and
          cancelAfterToolcalls >= 0 and not cancelled:
        inc startedToolcalls
        if startedToolcalls >= cancelAfterToolcalls:
          cancelled = true
          nc.publish("svc.session." & sid & ".steer",
            Envelope(v: 1, id: newId(), kind: ekEvent,
                     payload: %*{"__cancel": true}).encode())
      polled = pollEnv(toolcalls, 0)
    polled = pollEnv(dones, 0)
    while polled.found:
      frames.add(("done", polled.env.payload))
      polled = pollEnv(dones, 0)
    polled = pollEnv(sentSteers, 0)
    while polled.found:
      frames.add(("steer_sent", polled.env.payload))
      polled = pollEnv(sentSteers, 0)
    let r = pollEnv(replies, 20)
    if r.found: reply = callerOf(r.env)
  if reply == nil:
    return %*{"error": "timeout driving session call"}
  # Drain any frame that landed after the reply was published (the terminal
  # `turn` frame goes out before the runner answers, but be generous).
  for sub in [turns, toolcalls, dones, sentSteers]:
    var polled = pollEnv(sub, 0)
    while polled.found:
      let kind = if sub == turns: "turn"
                 elif sub == toolcalls: "toolcall"
                 elif sub == sentSteers: "steer_sent" else: "done"
      frames.add((kind, polled.env.payload))
      polled = pollEnv(sub, 0)
  reply

proc terminalFrames(frames: seq[Frame]): seq[JsonNode] =
  ## The authoritative terminal frames of the turn(s) that ran.
  for f in frames:
    if f.kind == "turn" and f.payload{"phase"}.getStr("") == "done":
      result.add(f.payload)

proc num(node: JsonNode, key: string, default = -1): int =
  if node == nil or node{"usage"} == nil: return default
  node["usage"]{key}.getInt(default)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for name in ["niffler", "session", "store-sqlite", "bash"]:
    if not fileExists(repoRoot / "var" / "bin" / name):
      fail("missing " & name & " binary — run `make build` first")
      quit(1)

  # -------------------------------------------------------------------------
  # 1. a multi-round turn: counters sum over the turn's successful responses,
  #    the terminal frame agrees with the result, and the legacy done frame
  #    carries no accounting at all.
  # 2. the next turn on the same conversation reports only ITS usage.
  # 3. a per-job token budget ends the turn with the partial usage it spent.
  # 4. a soft round limit the human never answers ends it as limit-exhausted.
  block accounting:
    var p = startProbe("usage", @[("NIF_MOCK_ROUNDS", "2"),
                                  ("NIF_MOCK_USAGE_DETAILS", "1"),
                                  ("NIF_MOCK_TOOLCMD", "true")])
    defer: p.stopProbe()
    let nc = p.nc
    let sid = "usage-" & $int(epochTime())

    var frames: seq[Frame] = @[]
    let turn1 = p.driveTurn(sid, %*{"sessionId": sid, "content": "count me"}, frames)
    check("turn 1 completes", turn1{"error"} == nil and
          turn1{"turnError"}.getStr("") == "", $turn1)
    # Late clean diagnostics must be stored/displayed while idle without a
    # model activation or message record. This is a real runner/bus probe.
    let diagnostics = openSub(nc, "ev.session." & sid & ".diagnostics")
    nc.publish("svc.session." & sid & ".diag",
      Envelope(v: 1, id: newId(), kind: ekEvent,
        payload: %*{"path": "clean.go", "text": "clean.go: no diagnostics — clean.",
                    "clean": true}).encode())
    let cleanFrame = pollEnv(diagnostics, 5000)
    natsSubscription_Destroy(diagnostics)
    check("idle clean check emits UI event", cleanFrame.found and
          cleanFrame.env.payload{"clean"}.getBool(false))
    let verdicts = call(nc, "store", "list",
      %*{"kind": "diagnostic", "idPrefix": sid & ":"})
    check("idle clean check persists separately", verdicts{"items"}.len == 1)
    let transcript = call(nc, "store", "list",
      %*{"kind": "message", "idPrefix": sid & ":"})
    var leaked = false
    for item in transcript{"items"}:
      if item{"value"}{"content"}.getStr("").contains("no diagnostics — clean"):
        leaked = true
    check("idle clean check never enters model history", not leaked)
    check("turn 1 outcome is success",
          turn1{"outcome"}.getStr("") == "success", $turn1)
    check("turn 1 has a turnId", turn1{"turnId"}.getStr("").len > 0, $turn1)
    check("turn 1 usage is reported",
          turn1{"usage"}{"usageReported"}.getBool(false) and
          turn1{"usage"}{"descendantsExcluded"}.getBool(false),
          $turn1{"usage"})
    # NIF_MOCK_ROUNDS=2: two scripted bash rounds plus the final answer, each
    # a successful provider response reporting usage.
    check("turn 1 counted every provider response",
          num(turn1, "providerResponses") == 3 and
          num(turn1, "responsesWithUsage") == 3 and
          num(turn1, "toolCalls") == 2, $turn1{"usage"})
    # Deterministic breakdowns: 100 cache-write and 7 reasoning tokens per
    # response, 10 completion tokens on the final answer only.
    check("turn 1 sums the provider breakdowns across rounds",
          num(turn1, "cacheWriteTokens") == 300 and
          num(turn1, "reasoningTokens") == 21 and
          num(turn1, "completionTokens") == 10, $turn1{"usage"})
    check("turn 1 reports cache reads honestly",
          num(turn1, "cacheReadTokens") > 0 and
          num(turn1, "cacheReadTokens") * 2 <= num(turn1, "promptTokens") + 3,
          $turn1{"usage"})
    check("turn 1 totals agree with its parts",
          num(turn1, "totalTokens") ==
            num(turn1, "promptTokens") + num(turn1, "completionTokens"),
          $turn1{"usage"})
    check("turn 1 names the provider/model that answered",
          turn1{"usage"}{"provider"}.getStr("").len > 0 and
          turn1{"usage"}{"model"}.getStr("").len > 0, $turn1{"usage"})

    let terminals = terminalFrames(frames)
    check("exactly one terminal frame per turn", terminals.len == 1,
          $terminals.len)
    if terminals.len == 1:
      check("the terminal frame carries the same turnId/outcome/usage",
            terminals[0]{"turnId"}.getStr("") == turn1{"turnId"}.getStr("") and
            terminals[0]{"outcome"}.getStr("") == "success" and
            terminals[0]{"usage"} == turn1{"usage"}, $terminals[0])
    var doneFrames = 0
    for f in frames:
      if f.kind == "done":
        inc doneFrames
        check("the legacy done frame carries no accounting (no double count)",
              f.payload{"usage"} == nil and f.payload{"outcome"} == nil,
              $f.payload)
    check("the turn emitted one done frame", doneFrames == 1, $doneFrames)

    # ---- 2. resume: only this turn's usage ------------------------------
    var frames2: seq[Frame] = @[]
    let turn2 = p.driveTurn(sid, %*{"sessionId": sid, "content": "again"}, frames2)
    check("resumed turn completes and succeeds",
          turn2{"error"} == nil and turn2{"outcome"}.getStr("") == "success",
          $turn2)
    check("a resumed turn reports only its own activation",
          num(turn2, "providerResponses") == 3 and
          num(turn2, "toolCalls") == 2 and
          num(turn2, "cacheWriteTokens") == 300 and
          num(turn2, "reasoningTokens") == 21, $turn2{"usage"})
    check("a resumed turn has its own turnId",
          turn2{"turnId"}.getStr("") != turn1{"turnId"}.getStr(""), $turn2)
    check("the resumed turn's terminal frame agrees",
          terminalFrames(frames2).len == 1 and
          terminalFrames(frames2)[0]{"usage"} == turn2{"usage"},
          $terminalFrames(frames2))

    # ---- 3. a hard per-job budget keeps the partial usage ---------------
    let budgetSid = "usage-budget-" & $int(epochTime())
    var frames3: seq[Frame] = @[]
    let budget = p.driveTurn(budgetSid,
      %*{"sessionId": budgetSid, "content": "budget", "maxTokens": 1}, frames3)
    check("budget turn ends budget-exhausted",
          budget{"outcome"}.getStr("") == "budget-exhausted" and
          budget{"turnError"}.getStr("").contains("token budget exhausted"),
          $budget)
    check("budget turn keeps the usage of the round it spent",
          num(budget, "providerResponses") == 1 and
          num(budget, "toolCalls") == 1 and
          num(budget, "responsesWithUsage") == 1 and
          num(budget, "cacheWriteTokens") == 100, $budget{"usage"})

    # ---- 4. a human soft limit nobody answers ---------------------------
    let limitSid = "usage-limit-" & $int(epochTime())
    let setLimit = call(nc, "core", "session",
      %*{"sessionId": limitSid, "limits": %*{"rounds": 1}}, 60_000)
    check("soft round limit accepted", setLimit{"error"} == nil, $setLimit)
    var frames4: seq[Frame] = @[]
    let limited = p.driveTurn(limitSid,
      %*{"sessionId": limitSid, "content": "limit me"}, frames4)
    check("a declined soft limit ends limit-exhausted",
          limited{"outcome"}.getStr("") == "limit-exhausted" and
          limited{"turnError"}.getStr("").contains("turn limit reached"),
          $limited)
    check("the limit turn reports the rounds it ran",
          num(limited, "providerResponses") == 1 and
          num(limited, "toolCalls") == 1, $limited{"usage"})

  # -------------------------------------------------------------------------
  # 5. cancellation after some usage: the round that completed is still
  #    accounted for, and the turn is NOT labelled success.
  block cancelled:
    var p = startProbe("usage-cancel", @[("NIF_MOCK_ROUNDS", "2"),
                                         ("NIF_MOCK_USAGE_DETAILS", "1"),
                                         ("NIF_MOCK_TOOLCMD", "sleep 4")])
    defer: p.stopProbe()
    let sid = "usage-cancel-" & $int(epochTime())
    var frames: seq[Frame] = @[]
    let cut = p.driveTurn(sid, %*{"sessionId": sid, "content": "cancel me"},
                          frames, cancelAfterToolcalls = 1)
    check("cancelled turn reports cancellation",
          cut{"outcome"}.getStr("") == "cancelled" and
          cut{"turnError"}.getStr("").contains("cancelled"), $cut)
    check("cancelled turn keeps the usage of the round that completed",
          num(cut, "providerResponses") == 1 and
          num(cut, "toolCalls") == 1 and
          num(cut, "cacheWriteTokens") == 100 and
          num(cut, "reasoningTokens") == 7 and
          cut{"usage"}{"usageReported"}.getBool(false), $cut{"usage"})
    check("the cancelled terminal frame agrees",
          terminalFrames(frames).len == 1 and
          terminalFrames(frames)[0]{"outcome"}.getStr("") == "cancelled" and
          terminalFrames(frames)[0]{"usage"} == cut{"usage"},
          $terminalFrames(frames))

  # -------------------------------------------------------------------------
  # 6. a provider that reports no usage at all: the counters are ABSENT
  #    (never invented zeros) and the turn says so.
  block unreported:
    var p = startProbe("usage-unreported", @[("NIF_MOCK_TOOLCMD", "sleep 4")])
    defer: p.stopProbe()
    let sid = "usage-none-" & $int(epochTime())
    var frames: seq[Frame] = @[]
    let cut = p.driveTurn(sid, %*{"sessionId": sid, "content": "no usage"},
                          frames, cancelAfterToolcalls = 1)
    check("unreported turn still reports its outcome",
          cut{"outcome"}.getStr("") == "cancelled" and
          cut{"usage"}{"providerResponses"}.getInt(-1) == 1, $cut)
    check("unreported usage is absent, not zero",
          not cut{"usage"}{"usageReported"}.getBool(true) and
          cut{"usage"}{"promptTokens"} == nil and
          cut{"usage"}{"completionTokens"} == nil and
          cut{"usage"}{"totalTokens"} == nil and
          cut{"usage"}{"cacheReadTokens"} == nil and
          cut{"usage"}{"reasoningTokens"} == nil,
          $cut{"usage"})

  block steerDispatch:
    var p = startProbe("steer-dispatch", @[("NIF_MOCK_ROUNDS", "1"),
                                         ("NIF_MOCK_TOOLCMD", "sleep 0.2")])
    defer: p.stopProbe()
    let sid = "steer-dispatch-" & $int(epochTime())
    var frames: seq[Frame]
    let reply = p.driveTurn(sid, %*{"sessionId": sid, "content": "work"}, frames,
                            steerContent = "check the edge case")
    var sent = 0
    for frame in frames:
      if frame.kind == "steer_sent" and
          frame.payload{"contents"} == %*["check the edge case"]:
        inc sent
    check("folded steer acknowledged once at next model dispatch",
          reply{"error"} == nil and sent == 1, $frames.len & " frames, sent=" & $sent)
  report("SESSION-USAGE")

main()
