## heartbeat component tests — scheduled turns (docs/research/FLEET.md §7).
##
## Boots a sandbox core (store + the ctxtest stub LLM, so a turn runs without a
## provider) plus the heartbeat component, and asserts the contract:
##
## - a due record fires a turn in its conversation, and the transcript shows
##   the machinery marker naming the record (never mistakable for the human);
## - a record with NO interval, or an interval below the floor, never fires;
## - disabled/paused records never fire (NIF_HEARTBEAT=0 is a pause, not a
##   delete: the record survives and resumes);
## - a heartbeat due while the conversation is MID-TURN is skipped and retried,
##   not queued — the human's turn must not be followed by a scheduled one;
## - the per-day budget is enforced from the DURABLE transcript, so a fresh
##   runner (retired and respawned) still refuses the over-budget tick;
## - a hand-rolled marker without a record id is refused outright, so nothing
##   can run an unbudgeted autonomous turn.

import std/[json, os, osproc, streams, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc messages(nc: NatsConnection, sessionId: string): JsonNode =
  ## The conversation's stored transcript, oldest first.
  call(nc, "store", "list",
       %*{"kind": "message", "idPrefix": sessionId & ":", "limit": 1000},
       10_000){"items"}

proc heartbeatTurns(nc: NatsConnection, sessionId: string): int =
  ## How many stored user messages carry the heartbeat marker: the turn log the
  ## runner's budget is derived from.
  let items = messages(nc, sessionId)
  if items == nil: return 0
  for item in items:
    let notice = item{"value"}{"notice"}
    if notice != nil and notice{"kind"}.getStr("") == "heartbeat":
      inc result

proc putRecord(nc: NatsConnection, id, session, prompt: string,
               intervalSec: float, enabled = true): JsonNode =
  call(nc, "heartbeat", "heartbeat_set",
       %*{"id": id, "session": session, "prompt": prompt,
          "intervalSec": intervalSec, "enabled": enabled}, 15_000)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "heartbeat", "ctxtest"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)

  # ctxtest is the stub LLM: a conversation runs a turn with no provider.
  let sandbox = newCoreSandbox("heartbeat", ["store"])
  let root = sandbox.root
  let ctxBin = fixtureBin(sandbox, "ctxtest",
                          repoRoot / "components" / "ctxtest" / "main.nim")
  let hbBin = sandbox.sandboxBin("heartbeat")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "heartbeat", hbBin)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # A 1s tick and a 10s interval floor: the tests drive real time, so the tick
  # must be fast and the intervals must be measurable.
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
    extra = [("NIF_AUTO_APPROVE", "1"), ("NIF_HEARTBEAT_TICK_MS", "1000"),
             ("NIF_HEARTBEAT_MAX_PER_DAY", "2")],
    logFile = root / "var" / "test-logs" / "core-hb.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(1200)
      if coreProc.running(): coreProc.kill()
    if coreProc != nil: coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  var ctxProc = startComponent(ctxBin, url, root = root,
    logFile = root / "var" / "test-logs" / "ctxtest-hb.log")
  defer: stopProcess(ctxProc)
  check("stub llm registered", waitComponent(nc, "ctxtest"))

  var hbProc = startComponent(hbBin, url, root = root,
    extra = [("NIF_HEARTBEAT_TICK_MS", "1000"), ("NIF_HEARTBEAT_MAX_PER_DAY", "2")],
    logFile = root / "var" / "test-logs" / "heartbeat.log")
  defer: stopProcess(hbProc)
  check("heartbeat registered", waitComponent(nc, "heartbeat"))

  # --- a due record fires, and the transcript marks it as machinery ---------
  let session = "hb-live"
  let created = putRecord(nc, "tick", session, "scheduled check-in", 10.0)
  check("a record is stored", created{"ok"}.getBool(false), $created)
  check("its first run is soon, not an interval away",
        created{"nextAt"}.getFloat(0.0) - epochTime() <= 61.0, $created)

  var fired = false
  for i in 0 ..< 40:
    sleep(1000)
    if heartbeatTurns(nc, session) > 0:
      fired = true
      break
  check("a due heartbeat ran a turn", fired,
        "no heartbeat-marked message after 40s")

  let marked = messages(nc, session)
  var found = false
  for item in marked:
    let notice = item{"value"}{"notice"}
    if notice != nil and notice{"kind"}.getStr("") == "heartbeat":
      found = notice{"id"}.getStr("") == "tick"
  check("the stored turn names its record", found, $marked)
  let header = call(nc, "store", "get",
                    %*{"kind": "conversation", "id": session}, 10_000){"value"}
  check("a scheduled turn does not title the conversation",
        header{"title"}.getStr("") == "", $header)

  # --- budget, enforced from the durable transcript -------------------------
  # NIF_HEARTBEAT_MAX_PER_DAY=2 above, and one turn has run: one more is
  # admitted, then the runner refuses even if the component asks again.
  var second = false
  for i in 0 ..< 40:
    sleep(1000)
    if heartbeatTurns(nc, session) >= 2:
      second = true
      break
  check("a second heartbeat within budget runs", second,
        "second turn never appeared (budget too small or component not ticking)")

  # The heartbeat component ticks on its own schedule, so the turn that just
  # landed may still be winding down when this direct call arrives — and a
  # runner mid-turn answers `busy`, not `budget`. That is correct behaviour and
  # a different refusal, so wait it out rather than sampling once: retry until
  # the answer is no longer the mid-turn one, then assert the budget verdict.
  # (This was the intermittent red in the full gate: ~1 run in 3, because it is
  # a race between the component's tick and this test's own call.)
  var overBudget: JsonNode = nil
  for i in 0 ..< 30:
    overBudget = call(nc, "core", "session", %*{"sessionId": session,
      "content": "scheduled check-in", "notice": {"kind": "heartbeat", "id": "tick"}})
    if not overBudget{"error"}.getStr("").contains("mid-turn"): break
    sleep(500)
  check("runner independently refuses an over-budget tick",
    overBudget{"heartbeat"}.getStr("") == "declined" and
    overBudget{"reason"}.getStr("") == "budget", $overBudget)
  # Same hazard for the two calls that follow.
  var missingRecord: JsonNode = nil
  for i in 0 ..< 30:
    missingRecord = call(nc, "core", "session", %*{"sessionId": "hb-no-record",
      "content": "x", "notice": {"kind": "heartbeat", "id": "absent"}})
    if not missingRecord{"error"}.getStr("").contains("mid-turn"): break
    sleep(500)
  check("a marker naming no record is refused",
    missingRecord{"heartbeat"}.getStr("") == "declined", $missingRecord)
  check("an interval below the floor is refused",
    putRecord(nc, "too-fast", "hb-fast", "x", 1.0){"error"} != nil)

  var third = false
  for i in 0 ..< 30:
    sleep(1000)
    if heartbeatTurns(nc, session) >= 3:
      third = true
      break
  check("the per-day budget stops further turns", not third,
        "a third turn ran despite NIF_HEARTBEAT_MAX_PER_DAY=2")

  # The runner refuses on its own authority, not only the component's: a
  # hand-published marker with no record id cannot start a turn (it would be an
  # unbudgeted autonomous turn). Driven through the cli so the call travels the
  # ordinary client path.
  let rogue = runCli(sandbox.sandboxBin("cli"), url,
                     @["call", "session",
                       """{"sessionId":"hb-rogue","content":"x","notice":{"kind":"heartbeat"}}"""],
                     timeoutMs = 60_000, root = root)
  check("a marker without a record id is refused",
        rogue.output.contains("notice.id"), rogue.output)
  check("and no turn ran for it", heartbeatTurns(nc, "hb-rogue") == 0,
        "the refused marker still produced a turn")

  # --- mid-turn: SKIP, never queue ------------------------------------------
  # The stub's hb-busy handler keeps the conversation mid-turn for ~8s while the
  # heartbeat component keeps ticking. A due record must NOT queue behind the
  # human's turn: the human would finish one turn and find a scheduled one had
  # been appended. The skip is written into the record, which is what the
  # human reads to see why nothing ran.
  let busySession = "hb-busy"
  # First, give it a conversation that exists: birth it with a control call.
  discard call(nc, "core", "session", %*{"sessionId": busySession}, 30_000)
  # Keep it disabled until the human owns the turn, even if process startup
  # takes longer than the record's initial 10s delay under load.
  discard putRecord(nc, "busy", busySession, "scheduled busy check", 10.0,
                    enabled = false)
  var turnSub: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr turnSub, nc.conn,
    "ev.session.hb-busy.turn") == NATS_OK
  defer: natsSubscription_Destroy(turnSub)
  discard natsConnection_Flush(nc.conn)
  # Drive the human's turn on a background process so this test can watch the
  # heartbeat's decision while the runner is busy.
  let busyCli = startComponent(sandbox.sandboxBin("cli"), url, root = root,
    args = ["call", "session",
            """{"sessionId":"hb-busy","content":"SLOW_CHILD go"}"""])
  defer: stopProcess(busyCli)
  var startMsg: ptr natsMsg
  doAssert natsSubscription_NextMsg(addr startMsg, turnSub, 10_000) == NATS_OK
  let startEvent = decode($natsMsg_GetData(startMsg))
  natsMsg_Destroy(startMsg)
  check("the observed start belongs to the human's turn",
        startEvent.payload{"phase"}.getStr("") == "start" and
        startEvent.payload{"content"}.getStr("") == "SLOW_CHILD go",
        $startEvent.payload)
  # Arm only AFTER observing the human's turn start; sleep alone is not a
  # synchronization barrier and allowed the tick to race ahead of the CLI.
  var busyRecord = call(nc, "store", "get",
    %*{"kind": "heartbeat", "id": "busy"}){"value"}
  busyRecord["enabled"] = %true
  busyRecord["nextAt"] = %0.0
  discard call(nc, "store", "put", %*{"kind": "heartbeat",
    "id": "busy", "value": busyRecord})
  sleep(2500)
  let during = call(nc, "heartbeat", "heartbeat_list",
                    %*{"session": busySession}, 10_000)
  var row: JsonNode = nil
  if during{"heartbeats"} != nil:
    for item in during{"heartbeats"}:
      if item{"id"}.getStr("") == "busy": row = item
  check("a heartbeat skipped a busy conversation",
        row != nil and row{"lastResult"}.getStr("").contains("busy"), $during)
  check("the skipped heartbeat ran no turn",
        heartbeatTurns(nc, busySession) == 0,
        "a heartbeat was appended to a conversation mid-turn")
  if busyCli.running():
    discard busyCli.waitForExit(60_000)
  let busyOut = busyCli.outputStream.readAll()
  check("the human's delayed fixture turn completed on its own",
        busyOut.contains("human-turn-done"),
        busyOut & " (expected current ctxtest hb-busy fixture; rebuild ctxtest)")
  # Inspect after completion too: checking only mid-turn would not catch a
  # heartbeat silently queued behind the human instead of being skipped.
  sleep(1500)
  check("no scheduled turn was queued behind the human",
        heartbeatTurns(nc, busySession) == 0,
        "a heartbeat appeared after the human's turn completed")

  # --- paused: NIF_HEARTBEAT=0 is a pause, not a delete ---------------------
  stopProcess(hbProc)
  hbProc = startComponent(hbBin, url, root = root,
    extra = [("NIF_HEARTBEAT_TICK_MS", "500"), ("NIF_HEARTBEAT", "0")],
    logFile = root / "var" / "test-logs" / "heartbeat-paused.log")
  check("paused heartbeat still registers", waitComponent(nc, "heartbeat"))
  let parked = putRecord(nc, "parked", "hb-paused", "should not run", 10.0)
  check("a record can be written while paused", parked{"ok"}.getBool(false),
        $parked)
  sleep(4000)
  check("no turn runs while paused", heartbeatTurns(nc, "hb-paused") == 0,
        "a paused heartbeat still fired")
  let listed = call(nc, "heartbeat", "heartbeat_list",
                    %*{"session": "hb-paused"}, 10_000)
  check("the record survives the pause and reports it",
        listed{"count"}.getInt(0) == 1 and listed{"ticking"}.getBool(true) == false,
        $listed)

  # --- disabled record never fires -----------------------------------------
  let off = putRecord(nc, "off", "hb-off", "disabled", 10.0, enabled = false)
  check("a disabled record is stored", off{"ok"}.getBool(false), $off)
  sleep(3000)
  check("a disabled heartbeat never runs", heartbeatTurns(nc, "hb-off") == 0,
        "a disabled record fired")

  report("heartbeat")

main()
