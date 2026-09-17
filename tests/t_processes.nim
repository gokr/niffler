## processes component tests — the long-running-command contract against a
## deterministic line-emitter fixture (tests/fixtures/line_emitter.py):
## registration; start returns an id while the child keeps running; drain
## semantics (each poll returns only what was appended since the last one —
## no duplicates, nothing re-injected); waitMs blocks until output/exit;
## filter projects matching lines while the cursor still advances past all
## of them; tail re-reads raw recent output without touching the cursor;
## stderr separation and exit codes; process_kill terminates the group;
## process_list; bash run_in_background forwarding (bash produces, processes
## owns); spool truncation under a small cap (NIF_PROCESSES_SPOOL_CAP);
## and the boot sweep: a SIGKILLed component leaves its children running
## (process-group leaders) and the next life kills the orphans via
## registry.json (pid + /proc starttime).

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc pidAlive(pid: int): bool =
  dirExists("/proc/" & $pid)

# --- the notice lane, from the test's side ----------------------------------
# The processes component publishes exit notices on the same subject the agent
# uses for settlement notices, so the test subscribes to it directly (shim
# calls, like the rest of this file).
proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                 subject.cstring)):
    fail("subscribe " & subject)
  sub

proc pollEnvelope(sub: ptr natsSubscription,
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

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "processes"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let bashBin = root / "var" / "bin" / "bash"
  if not fileExists(bashBin):
    fail(bashBin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("processes")
  defer: removeDir(tmp)
  let fixture = root / "tests" / "fixtures" / "line_emitter.py"

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # spool cap low enough that the truncation test can trigger it naturally
  # (seq 1 5000 ≈ 24KB > 20KB cap, keep 10KB tail)
  # spool cap 20KB (>10KB keep tail) and a 4KB poll chunk: the burst test
  # below needs both the truncation path and a chunk cap the burst exceeds
  let procProc = startComponent(bin, url, root = tmp,
                                extra = [("NIF_PROCESSES_SPOOL_CAP", "20000"),
                                         ("NIF_PROCESSES_POLL_CHUNK", "4096")])
  defer:
    if procProc.running():
      procProc.terminate()
      sleep(200)
    procProc.close()
  check("processes registers", waitRegistered(nc, "processes"), "reg.publish")

  proc pcall(tool: string, args: JsonNode, timeoutMs = 35000): JsonNode =
    call(nc, "processes", tool, args, timeoutMs)

  proc emitter(args: string): JsonNode =
    pcall("process_start", %*{"command": "python3 -u " & quoteShell(fixture) & " " & args})

  # --- start + drain: incremental, no duplicates --------------------------
  let s1 = emitter("6 120 tick")
  check("start returns an id and ok", s1{"ok"}.getBool(false) and
        s1{"id"}.getStr("").len > 0, $s1)
  check("start has a label (derived from the command)",
        s1{"label"}.getStr("").len > 0, $s1)
  let id1 = s1{"id"}.getStr("")

  sleep(400)                          # ~3 lines have been emitted
  let d1 = pcall("process_poll", %*{"id": id1})
  check("first poll sees early lines", d1{"ok"}.getBool(false) and
        d1{"text"}.getStr("").contains("tick line 0"), $d1)
  let early = d1{"lines"}.getInt(-1)
  check("first poll counted lines", early > 0, $d1)

  sleep(700)                          # remaining lines emitted
  let d2 = pcall("process_poll", %*{"id": id1})
  check("second poll returns only newer lines (drain semantics)",
        d2{"text"}.getStr("").contains("tick line 5") and
        not d2{"text"}.getStr("").contains("tick line 0"), $d2)
  check("drain is incremental: lines counted only once",
        d2{"lines"}.getInt(-1) < 6, $d2)
  let d3 = pcall("process_poll", %*{"id": id1, "waitMs": 2000})
  check("exhausted poll has no new output",
        d3{"text"}.getStr("").contains("(no new output)"), $d3)
  check("exit status reported with code",
        d3{"status"}.getStr("") == "exited(code 0)", $d3)

  # --- filter: projection; cursor advances past everything ---------------
  let s2 = emitter("8 100 w")
  let id2 = s2{"id"}.getStr("")
  sleep(500)
  let f1 = pcall("process_poll", %*{"id": id2, "filter": "line [2-4]"})
  check("filter keeps only matching lines",
        f1{"text"}.getStr("").contains("w line 3") and
        not f1{"text"}.getStr("").contains("w line 0"), $f1)
  check("filter reports matched count", f1{"matched"}.getInt(-1) >= 1, $f1)
  # the non-matching lines were drained: they never come back
  sleep(600)
  let f2 = pcall("process_poll", %*{"id": id2})
  check("non-matching lines are gone (cursor advanced past all)",
        not f2{"text"}.getStr("").contains("w line 1"), $f2)

  # --- tail: raw bounded re-read, cursor untouched ------------------------
  let t1 = pcall("process_poll", %*{"id": id2, "tail": "1"})
  check("tail re-reads raw output after everything was drained",
        t1{"text"}.getStr("").contains("w line 0"), $t1)
  let t2 = pcall("process_poll", %*{"id": id2})
  check("tail left the cursor alone (no re-injection after tail)",
        t2{"text"}.getStr("").contains("(no new output)"), $t2)

  # --- waitMs: block until output, then until exit ------------------------
  let s3 = emitter("3 400 slow")
  let id3 = s3{"id"}.getStr("")
  var guard = 0
  let w1 = pcall("process_poll", %*{"id": id3, "waitMs": 2000})
  check("waitMs returns on first output, status still running",
        w1{"text"}.getStr("").contains("slow line 0") and
        not w1{"text"}.getStr("").contains("slow line 2") and
        w1{"status"}.getStr("") == "running", $w1)
  var w2 = pcall("process_poll", %*{"id": id3, "waitMs": 3000})
  var w2all = w2{"text"}.getStr("")
  guard = 0
  while w2{"status"}.getStr("") == "running" and guard < 6:
    w2 = pcall("process_poll", %*{"id": id3, "waitMs": 3000})
    w2all.add(w2{"text"}.getStr(""))
    inc guard
  check("next waitMs poll returns the rest and the final status",
        w2all.contains("slow line 2") and
        w2{"status"}.getStr("") == "exited(code 0)", $w2all)

  # --- stderr separation + exit codes + kill ------------------------------
  let s4 = emitter("4 80 boom 1")     # fails after line 1
  let id4 = s4{"id"}.getStr("")
  var e1 = pcall("process_poll", %*{"id": id4, "waitMs": 1000})
  var e1all = e1{"text"}.getStr("")
  guard = 0
  while e1{"status"}.getStr("") == "running" and guard < 6:
    e1 = pcall("process_poll", %*{"id": id4, "waitMs": 1000})
    e1all.add(e1{"text"}.getStr(""))
    inc guard
  check("stderr lands in the stderr stream",
        e1all.contains("stderr") and e1all.contains("FATAL boom"), $e1all)
  check("exit code reported", e1{"status"}.getStr("") == "exited(code 7)" and
        e1{"exit_code"}.getInt(-1) == 7, $e1all)

  let s5 = pcall("process_start",
                 %*{"command": "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; echo loop $i; done",
                    "label": "sleeper"})
  let id5 = s5{"id"}.getStr("")
  let r1 = pcall("process_poll", %*{"id": id5})
  check("long-running child reports running", r1{"status"}.getStr("") == "running", $r1)
  let k1 = pcall("process_kill", %*{"id": id5})
  check("kill stops the process",
        k1{"status"}.getStr("") != "running", $k1)
  let k2 = pcall("process_poll", %*{"id": id5})
  check("poll after kill shows the terminal status and stops the loop",
        k2{"status"}.getStr("") != "running" and
        not k2{"text"}.getStr("").contains("loop 10"), $k2)
  check("killing an unknown id is a clean 404",
        pcall("process_kill", %*{"id": "p999"}).hasKey("error"))

  # --- list ---------------------------------------------------------------
  let l1 = pcall("process_list", %*{})
  check("list shows finished entries with statuses",
        l1{"ok"}.getBool(false) and
        l1{"processes"}.len >= 4, $l1)

  # --- bash run_in_background forwarding ----------------------------------
  let bashProc = startComponent(bashBin, url, root = tmp)
  defer:
    if bashProc.running():
      bashProc.terminate()
      sleep(200)
    bashProc.close()
  check("bash registers", waitRegistered(nc, "bash"), "reg.publish")

  proc bcall(args: JsonNode, timeoutMs = 45000): JsonNode =
    call(nc, "bash", "bash", args, timeoutMs)

  let b1 = bcall(%*{"command": "python3 -u " & quoteShell(fixture) & " 4 100 via-bash",
                    "run_in_background": true})
  check("bash flag returns an id instead of blocking",
        b1{"ok"}.getBool(false) and b1{"id"}.getStr("").len > 0 and
        not b1.hasKey("exit_code"), $b1)
  check("bash flag teaches the follow-up verbs",
        b1{"text"}.getStr("").contains("process_poll") and
        b1{"text"}.getStr("").contains("process_kill"), $b1)
  sleep(500)
  let b2 = pcall("process_poll", %*{"id": b1{"id"}.getStr("")})
  check("forwarded process is pollable through processes",
        b2{"text"}.getStr("").contains("via-bash line"), $b2)
  # cwd forwarding: bash passes its resolved cwd as workdir
  let b3 = bcall(%*{"command": "pwd", "run_in_background": true,
                    "cwd": tmp})
  let b4 = pcall("process_poll", %*{"id": b3{"id"}.getStr(""), "waitMs": 2000})
  check("bash cwd forwarded as the child workdir",
        b4{"text"}.getStr("").contains(tmp.lastPathPart) or
        b4{"text"}.getStr("").contains(tmp), $b4)

  # --- poll chunk cap: a burst larger than the chunk cap is split ---------
  # Regression: the cut used rfind's start-only form, which searches to the
  # chunk's end — one poll could return the whole burst, not the cap.
  let s8 = pcall("process_start", %*{
    "command": "seq 1 5000",
    "label": "burst"})
  let id8 = s8{"id"}.getStr("")
  var burstPolls = 0
  var burstBytes = 0
  var maxPollBytes = 0
  var burstDone = false
  while burstPolls < 60 and not burstDone:
    let p = pcall("process_poll", %*{"id": id8, "waitMs": 300})
    inc burstPolls
    let got = p{"new_bytes"}.getInt(0)
    burstBytes += got
    maxPollBytes = max(maxPollBytes, got)
    if p{"status"}.getStr("") != "running" and got == 0:
      burstDone = true
  check("large burst needs several polls (poll chunk cap holds)",
        burstPolls >= 2 and burstBytes >= 10_000, $burstBytes)
  check("no single poll exceeded the poll chunk cap",
        maxPollBytes <= 4096, $maxPollBytes)

  # --- spool truncation under the cap --------------------------------------
  let s6 = pcall("process_start", %*{"command": "seq 1 5000"})
  let id6 = s6{"id"}.getStr("")
  # drain fully: with the small poll chunk one call no longer returns the
  # whole (truncated) tail
  var tr1text = ""
  var tr1 = pcall("process_poll", %*{"id": id6, "waitMs": 5000})
  tr1text.add(tr1{"text"}.getStr(""))
  var trGuard = 0
  while (tr1{"status"}.getStr("") == "running" or
         tr1{"new_bytes"}.getInt(0) > 0) and trGuard < 20:
    tr1 = pcall("process_poll", %*{"id": id6, "waitMs": 2000})
    tr1text.add(tr1{"text"}.getStr(""))
    inc trGuard
  check("spool over the cap is truncated to its tail",
        tr1text.contains("5000") and tr1text.contains("truncated"),
        tr1text)
  check("truncated head did not leak into the result",
        not tr1text.contains("\n1\n"), tr1text)

  # --- boot sweep: SIGKILLed component leaves orphans; next life kills them
  let s7 = pcall("process_start",
                 %*{"command": "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; done"})
  let id7 = s7{"id"}.getStr("")
  let regFile = tmp / "var" / "processes" / "registry.json"
  let regDoc = parseJson(readFile(regFile))
  var orphanPid = 0
  for e in regDoc{"entries"}:
    if e{"id"}.getStr("") == id7: orphanPid = e{"pid"}.getInt(0)
  check("sweep file records the running child", orphanPid > 0 and
        pidAlive(orphanPid), "pid=" & $orphanPid & " reg=" & $regDoc)

  # crash the component (SIGKILL: children survive — they are group leaders)
  procProc.kill()
  procProc.close()
  sleep(300)
  check("orphan outlives the SIGKILLed component", pidAlive(orphanPid))

  # next life: boot sweep must kill the orphan (pid-reuse guarded by
  # /proc starttime recorded in the sweep file)
  let procProc2 = startComponent(bin, url, root = tmp)
  defer:
    if procProc2.running():
      procProc2.terminate()
      sleep(200)
    procProc2.close()
  check("processes registers again", waitRegistered(nc, "processes"), "reg.publish 2")
  sleep(500)                          # sweep ran at boot
  check("boot sweep killed the orphan", not pidAlive(orphanPid))
  check("sweep file was reset",
        parseJson(readFile(regFile)){"entries"}.len == 0)
  # unknown ids from the previous life are a clean 404
  check("stale ids from the previous life are not pollable",
        pcall("process_poll", %*{"id": id7}).hasKey("error"))

  # -------------------------------------------------------------------------
  # exit notices: a finished background process tells its conversation
  # -------------------------------------------------------------------------
  # Rides the lane the agent's settlement notices use
  # (svc.session.<id>.steer with a {"notice": …} payload). The point is that
  # it arrives WITHOUT anyone polling: before onIdle, a child's exit was only
  # noticed when a tool call happened to reap it, so finished background work
  # sat unseen.
  block exitNotice:
    let steerSub = openSub(nc, "svc.session.bgnotice.steer")
    defer: natsSubscription_Destroy(steerSub)
    let started = pcall("process_start",
      %*{"command": "echo notice-me", "label": "notice-fixture",
         "session": "bgnotice"}, 20_000)
    let ownedId = started{"id"}.getStr("")
    check("notice: start accepted the owning session",
          started{"error"} == nil and ownedId.len > 0, $started)

    var notice: JsonNode = nil
    let noticeDeadline = epochTime() + 20.0
    while notice == nil and epochTime() < noticeDeadline:
      let polled = pollEnvelope(steerSub, 200)
      if polled.found and polled.env.payload != nil and
          polled.env.payload{"notice"} != nil:
        notice = polled.env.payload{"notice"}

    check("notice: the exit was announced with no poll of our own",
          notice != nil, "nothing on " & "svc.session.bgnotice.steer in 20s")
    if notice != nil:
      check("notice: names the process and its terminal status",
            notice{"kind"}.getStr("") == "process-exited" and
            notice{"processId"}.getStr("") == ownedId and
            notice{"status"}.getStr("") == "exited(code 0)", $notice)
      check("notice: carries the timing and how much output exists",
            notice{"startedAt"}.getFloat(0) > 0 and
            notice{"endedAt"}.getFloat(0) >= notice{"startedAt"}.getFloat(0) and
            notice{"outputBytes"}.getInt(0) > 0, $notice)
      check("notice: it is a pointer (label, not the output itself)",
            notice{"label"}.getStr("") == "notice-fixture" and
            notice{"text"} == nil, $notice)

    # exactly once: further reaps, polls and listings must not repeat it
    var strays = 0
    let quietWindow = epochTime() + 2.5
    while epochTime() < quietWindow:
      if pollEnvelope(steerSub, 100).found: inc strays
    discard pcall("process_poll", %*{"id": ownedId})
    discard pcall("process_list", %*{})
    if pollEnvelope(steerSub, 500).found: inc strays
    check("notice: sent exactly once", strays == 0, $strays & " extra")

    # the UI's age display needs the start time on the listing
    let listing = pcall("process_list", %*{})
    var sawStartedAt = false
    if listing{"processes"} != nil:
      for p in listing{"processes"}:
        if p{"id"}.getStr("") == ownedId:
          sawStartedAt = p{"started_at"}.getFloat(0) > 0
    check("process_list exposes started_at (for the status-row age)",
          sawStartedAt, $listing)

    # a process started without an owner says nothing to anyone
    discard pcall("process_start", %*{"command": "echo quiet"})
    sleep(1500)
    var unowned = 0
    let unownedUntil = epochTime() + 2.0
    while epochTime() < unownedUntil:
      if pollEnvelope(steerSub, 100).found: inc unowned
    check("notice: no owner session means no notice", unowned == 0, $unowned)

  report("t_processes")

when isMainModule:
  main()
