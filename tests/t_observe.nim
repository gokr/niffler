## observe tests - raw tap fidelity, bounded probes, tracing, safety, monitoring.

import std/[base64, json, os, osproc, streams, strtabs, strutils, times]
import natswrapper
import envelope
import helpers

proc stopProcess(process: Process, waitMs = 500) =
  if process == nil:
    return
  if process.running():
    process.terminate()
    let deadline = epochTime() + waitMs.float / 1000.0
    while process.running() and epochTime() < deadline:
      sleep(50)
    if process.running(): process.kill()
    sleep(50)
  process.close()

proc waitUntil(predicate: proc(): bool, timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if predicate(): return true
    sleep(50)
  predicate()

proc startObserveNats(): tuple[prc: Process, url, monitorUrl: string] =
  startNatsMonitoring()

proc compileTarget(root, tmp: string): string =
  let source = tmp / "probe_target.nim"
  result = tmp / "probe-target"
  writeFile(source, """
import std/[os, strutils]
import niffler/sdk
let comp = newComponent("probe-target", "0.1.0")
comp.tool:
  proc probe_echo(value: string): JsonNode =
    ## Return one value for observation tests.
    %*{"value": value}
comp.tool:
  proc probe_log(msg: string): JsonNode =
    ## Emit one structured log event.
    comp.log("info", msg, %*{"probe": "observe"})
    %*{"ok": true}
comp.tool:
  proc probe_large(): JsonNode =
    ## Return a deliberately oversized result for SDK reply hardening.
    %*{"value": "x".repeat(1_100_000)}
comp.tool:
  proc probe_delay(delayMs: int): JsonNode =
    ## Return after a controlled delay for monotonic trace tests.
    sleep(delayMs)
    %*{"delayMs": delayMs}
comp.run()
""".strip() & "\n")
  let compiler = startProcess("nim", args = @["c", "--hints:off",
    "--nimcache:" & (tmp / "var" / "nimcache" / "probe-target"),
    "--path:" & (root / "sdk"), "-o:" & result, source],
    workingDir = root, options = {poUsePath, poStdErrToStdOut})
  let code = compiler.waitForExit(120_000)
  let output = compiler.outputStream.readAll()
  compiler.close()
  check("observation target compiles", code == 0, output)
  if code != 0: report("OBSERVE TEST")

proc schemaFor(registration: JsonNode, tool: string): JsonNode =
  let tools = registration{"tools"}
  if tools == nil or tools.kind != JArray:
    return nil
  for item in tools:
    if item{"name"}.getStr("") == tool:
      return item{"schema"}

proc testCoreSpawnedMonitor(root, observeBin, parentTmp: string) =
  # A minimal isolated root exercises core's cold-start path: client and HTTP
  # monitoring ports must differ, and discovery is published only once live.
  let testRoot = parentTmp / "core-monitor"
  createDir(testRoot / "var" / "bin")
  copyFileWithPermissions(root / "var" / "bin" / "niffler",
                          testRoot / "var" / "bin" / "niffler")
  copyFileWithPermissions(observeBin, testRoot / "var" / "bin" / "observe")
  writeFile(testRoot / "manifest.yaml", """
components:
  - name: observe
    binary: var/bin/observe
    required: true
    restart: on-failure
""".strip() & "\n")

  var environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key notin ["NIF_NATS_URL", "NIF_OBSERVE_MONITOR_URL"]:
      environment[key] = value
  environment["NIF_ROOT"] = testRoot
  environment["NIF_AUTO_APPROVE"] = "1"
  environment["NIF_NATS_SPAWN"] = "1"
  let core = startProcess(testRoot / "var" / "bin" / "niffler",
                          workingDir = testRoot, env = environment,
                          options = {poUsePath, poStdErrToStdOut})
  defer: stopProcess(core, 5000)
  let natsFile = testRoot / "var" / "nats-url"
  let monitorFile = testRoot / "var" / "nats-monitor-url"
  let discovered = waitUntil(proc(): bool =
    fileExists(natsFile) and fileExists(monitorFile), 12_000)
  check("core publishes client and monitor discovery after cold start", discovered)
  if not discovered: return
  let natsUrl = readFile(natsFile).strip()
  let monitorUrl = readFile(monitorFile).strip()
  check("core picks distinct client and monitoring ports",
        natsUrl.split(':')[^1] != monitorUrl.split(':')[^1],
        natsUrl & " / " & monitorUrl)
  var nc = waitConnect(natsUrl)
  defer: nc.close()
  var monitor = newJObject()
  let monitorReady = waitUntil(proc(): bool =
    monitor = call(nc, "observe", "observe_monitor", newJObject(), 1000)
    monitor{"connections"}.getInt(0) >= 1, 10_000)
  check("observe reads core-spawned monitor endpoint", monitorReady, $monitor)
  var coreReady = false
  let serviceReady = waitUntil(proc(): bool =
    let response = call(nc, "core", "catalog", %*{"op": "list"}, 500)
    coreReady = response{"tools"} != nil
    coreReady, 10_000)
  check("nested core service is ready before teardown", serviceReady)
  if coreReady:
    let removed = call(nc, "core", "remove", %*{"name": "observe"}, 10_000)
    check("nested core removes observe before teardown",
          removed{"ok"}.getBool(false), $removed)

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let observeBin = root / "var" / "bin" / "observe"
  if not fileExists(observeBin):
    fail("missing observe binary - run `make build` first")
    report("OBSERVE TEST")

  let tmp = tempRoot("observe")
  defer: removeDir(tmp)
  let targetBin = compileTarget(root, tmp)

  let (server, url, monitorUrl) = startObserveNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var regSub: ptr natsSubscription
  let regStatus = natsConnection_SubscribeSync(addr regSub, nc.conn,
                                                "reg.publish".cstring)
  check("registration subscription created", checkStatus(regStatus))
  discard natsConnection_FlushTimeout(nc.conn, 1000)

  let captures = tmp / "captures"
  var observe = startComponent(observeBin, url, root = tmp,
    extra = [("NIF_OBSERVE_CAPTURE_DIR", captures),
              ("NIF_OBSERVE_CAPTURE_BYTES", "65536"),
              ("NIF_OBSERVE_MONITOR_URL", monitorUrl),
              ("NIF_OBSERVE_RING", "128"),
              ("NIF_OBSERVE_RING_BYTES", "1048576"),
              ("NIF_OBSERVE_ENTRY_BYTES", "1048576"),
              ("NIF_OBSERVE_PROBE_BYTES", "65536"),
              ("NIF_OBSERVE_MAX_PROBES", "16")])
  var target = startComponent(targetBin, url, root = tmp)
  defer:
    stopProcess(target)
    stopProcess(observe)

  var observeRegistration: JsonNode
  let registrationSeen = waitUntil(proc(): bool =
    var message: ptr natsMsg
    let status = natsSubscription_NextMsg(addr message, regSub, 50)
    if status != NATS_OK: return false
    let node = ($natsMsg_GetData(message)).parseJson()
    natsMsg_Destroy(message)
    if node{"name"}.getStr("") == "observe":
      observeRegistration = node
      return true
    false, 5000)
  natsSubscription_Destroy(regSub)
  check("observe registers", registrationSeen)
  let targetUp = waitUntil(proc(): bool =
    let response = call(nc, "probe-target", "probe_echo",
                        %*{"value": "ready"}, 500)
    response{"value"}.getStr("") == "ready")
  check("probe target registers", targetUp)
  if not registrationSeen or not targetUp: report("OBSERVE TEST")

  let nonCallId = "non-call-envelope"
  let nonCallData = Envelope(v: 1, id: nonCallId, kind: ekEvent,
                             payload: %*{}).encode()
  var nonCallMsg: ptr natsMsg
  let nonCallStatus = natsConnection_Request(addr nonCallMsg, nc.conn,
    "svc.probe-target.call", nonCallData.cstring, nonCallData.len.cint, 1000)
  var nonCallReply: Envelope
  if checkStatus(nonCallStatus):
    nonCallReply = envelope.decode($natsMsg_GetData(nonCallMsg))
    natsMsg_Destroy(nonCallMsg)
  check("Nim SDK rejects non-call requests immediately",
        checkStatus(nonCallStatus) and nonCallReply.id == nonCallId and
        nonCallReply.kind == ekError and
        nonCallReply.error{"code"}.getStr("") == "bad-envelope",
        if checkStatus(nonCallStatus): nonCallReply.encode()
        else: getErrorString(nonCallStatus))

  let sendSchema = schemaFor(observeRegistration, "observe_send")
  let requestSchema = schemaFor(observeRegistration, "observe_request")
  let dumpSchema = schemaFor(observeRegistration, "observe_dump")
  check("observe_send is approval-gated",
        sendSchema{"x-harness"}{"approval"}.getStr("") == "always", $sendSchema)
  check("observe_request is approval-gated and bounded",
        requestSchema{"x-harness"}{"approval"}.getStr("") == "always" and
         requestSchema{"x-harness"}{"timeoutMs"}.getInt(0) == 35_000,
         $requestSchema)
  check("observe_dump is approval-gated and exposes no arbitrary path",
        dumpSchema{"x-harness"}{"approval"}.getStr("") == "always" and
        dumpSchema{"properties"}{"path"} == nil, $dumpSchema)

  let oversizedReply = call(nc, "probe-target", "probe_large", newJObject(), 500)
  let targetSurvived = call(nc, "probe-target", "probe_echo",
                            %*{"value": "still-running"}, 1000)
  check("oversized SDK replies do not terminate a component",
        oversizedReply{"error"} != nil and
        targetSurvived{"value"}.getStr("") == "still-running",
        $oversizedReply & " / " & $targetSurvived)

  # Live registrations and service-subject discovery work without a core
  # snapshot, including the scoped session-runner mapping.
  nc.publish("reg.publish", $(%*{"name": "session-demo", "tools": []}))
  var subjects = newJObject()
  let subjectsReady = waitUntil(proc(): bool =
    subjects = call(nc, "observe", "observe_subjects", newJObject(), 1000)
    let services = subjects{"serviceSubjects"}
    if services == nil or services.kind != JArray: return false
    for item in services:
      if item.getStr("") == "svc.session.demo.call": return true
    false)
  check("observe_subjects maps session runner subjects", subjectsReady, $subjects)

  let oversizedLabel = call(nc, "observe", "observe_listen",
    %*{"subject": "ev.test", "label": "l".repeat(50_000)}, 1000)
  let afterOversizedLabel = call(nc, "observe", "observe_probes", newJObject())
  check("oversized probe metadata is rejected without terminating observe",
        oversizedLabel{"error"} != nil and afterOversizedLabel{"items"} != nil,
        $oversizedLabel & " / " & $afterOversizedLabel)

  # A probe on observe's own service call catches one copy, not one from the
  # call subscription plus another from the broad tap.
  let ownProbe = call(nc, "observe", "observe_listen",
    %*{"subject": "svc.observe.call", "regex": "unique-own-marker", "cap": 10})
  let ownId = ownProbe{"probeId"}.getStr("")
  let sent = call(nc, "observe", "observe_send",
    %*{"subject": "ev.test.sent", "payload": %*{"marker": "unique-own-marker"}})
  check("observe_send publishes an event", sent{"ok"}.getBool(false), $sent)
  var ownEvents = newJObject()
  let exactOnce = waitUntil(proc(): bool =
    ownEvents = call(nc, "observe", "observe_events", %*{"probeId": ownId})
    ownEvents{"count"}.getInt(0) >= 1)
  check("raw tap observes its own call exactly once",
        exactOnce and ownEvents{"count"}.getInt(0) == 1, $ownEvents)
  let invalidSend = call(nc, "observe", "observe_send",
                         %*{"subject": "svc.probe-target.call", "payload": %*{}})
  check("observe_send rejects service subjects", invalidSend{"error"} != nil,
        $invalidSend)

  # Token-aware NATS wildcard matching and the cap=1 eviction boundary.
  let wildcardProbe = call(nc, "observe", "observe_listen",
    %*{"subject": "ev.test.*", "cap": 1})
  let wildcardId = wildcardProbe{"probeId"}.getStr("")
  nc.publish("ev.test.one", Envelope(v: 1, id: "one", kind: ekEvent,
                                     payload: %*{"n": 1}).encode())
  nc.publish("ev.test.one.extra", Envelope(v: 1, id: "extra", kind: ekEvent,
                                           payload: %*{"n": 99}).encode())
  nc.publish("ev.test.two", Envelope(v: 1, id: "two", kind: ekEvent,
                                     payload: %*{"n": 2}).encode())
  var wildcardEvents = newJObject()
  let wildcardReady = waitUntil(proc(): bool =
    wildcardEvents = call(nc, "observe", "observe_events",
                          %*{"probeId": wildcardId})
    wildcardEvents{"count"}.getInt(0) == 1 and
    wildcardEvents{"items"}[0]{"subject"}.getStr("") == "ev.test.two")
  check("wildcard is token-aware and cap=1 retains newest", wildcardReady,
        $wildcardEvents)

  let registrationProbe = call(nc, "observe", "observe_listen",
    %*{"subject": "reg.>", "regex": "reg-probe"})
  let registrationId = registrationProbe{"probeId"}.getStr("")
  nc.publish("reg.publish", $(%*{"name": "reg-probe", "future": true, "tools": []}))
  var registrationEvents = newJObject()
  let registrationCaptured = waitUntil(proc(): bool =
    registrationEvents = call(nc, "observe", "observe_events",
                              %*{"probeId": registrationId})
    registrationEvents{"count"}.getInt(0) == 1)
  check("listen probes capture bare registrations", registrationCaptured,
        $registrationEvents)

  # Trace one request/reply pair and require exact cardinality.
  let trace = call(nc, "observe", "observe_trace",
                   %*{"component": "probe-target", "toolRegex": "^probe_echo$"})
  let traceId = trace{"probeId"}.getStr("")
  let echo = call(nc, "probe-target", "probe_echo", %*{"value": "trace-me"})
  check("target echo works", echo{"value"}.getStr("") == "trace-me", $echo)
  var traceEvents = newJObject()
  let traceReady = waitUntil(proc(): bool =
    traceEvents = call(nc, "observe", "observe_events", %*{"probeId": traceId})
    traceEvents{"count"}.getInt(0) == 2)
  var requestId = ""
  var replyId = ""
  if traceReady:
    for item in traceEvents{"items"}:
      let envelope = item{"envelope"}
      if envelope{"direction"}.getStr("") == "request":
        requestId = envelope{"id"}.getStr("")
      if envelope{"direction"}.getStr("") == "reply":
        replyId = envelope{"id"}.getStr("")
  check("trace records exactly one correlated request and reply",
        traceReady and requestId.len > 0 and requestId == replyId, $traceEvents)
  let traceStopped = call(nc, "observe", "observe_stop", %*{"probeId": traceId})
  check("trace can be frozen before later diagnostics",
        traceStopped{"stopped"}.getBool(false), $traceStopped)

  let diagnosticTrace = call(nc, "observe", "observe_trace",
    %*{"component": "probe-target", "toolRegex": "^probe_delay$"})
  let diagnosticTraceId = diagnosticTrace{"probeId"}.getStr("")
  let requested = call(nc, "observe", "observe_request",
    %*{"subject": "svc.probe-target.call", "tool": "probe_delay",
       "args": %*{"delayMs": 250}, "timeoutMs": 1000}, 3000)
  check("observe_request validates and returns a target result",
        requested{"ok"}.getBool(false) and
         requested{"value"}{"delayMs"}.getInt(0) == 250, $requested)
  var diagnosticEvents = newJObject()
  var tracedElapsedMs = -1.0
  let diagnosticTraceReady = waitUntil(proc(): bool =
    diagnosticEvents = call(nc, "observe", "observe_events",
      %*{"probeId": diagnosticTraceId})
    if diagnosticEvents{"count"}.getInt(0) != 2: return false
    for item in diagnosticEvents{"items"}:
      let envelope = item{"envelope"}
      if envelope{"direction"}.getStr("") == "reply":
        tracedElapsedMs = envelope{"elapsedMs"}.getFloat(-1.0)
    tracedElapsedMs >= 0)
  check("observe_request keeps taps moving and trace latency is monotonic",
        diagnosticTraceReady and tracedElapsedMs >= 200 and tracedElapsedMs < 1500,
        $diagnosticEvents)

  let oversizedTrace = call(nc, "observe", "observe_trace",
                             %*{"component": "probe-target"})
  let oversizedTraceId = oversizedTrace{"probeId"}.getStr("")
  let largeValue = "v".repeat(70_000)
  let largeRequested = call(nc, "observe", "observe_request",
    %*{"subject": "svc.probe-target.call", "tool": "probe_echo",
       "args": %*{"value": largeValue}, "timeoutMs": 1000}, 3000)
  var oversizedProbeState = newJObject()
  let oversizedAccounted = waitUntil(proc(): bool =
    let state = call(nc, "observe", "observe_probes", newJObject())
    for item in state{"items"}:
      if item{"probeId"}.getStr("") == oversizedTraceId:
        oversizedProbeState = item
        return item{"dropped"}.getInt(0) > 0
    false)
  check("oversized target results are response-bounded",
        largeRequested{"ok"}.getBool(false) and
        largeRequested{"valueTruncated"}.getBool(false) and
        largeRequested{"valueBytes"}.getInt(0) > 60_000, $largeRequested)
  check("oversized trace entries stay outside pending and byte accounting",
        oversizedAccounted and oversizedProbeState{"pending"}.getInt(-1) == 0 and
        oversizedProbeState{"bytes"}.getInt(-1) <= 65_536,
        $oversizedProbeState)

  # A live subscriber that never replies proves timeout units are milliseconds,
  # not nanoseconds accidentally passed as milliseconds.
  var silentSub: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr silentSub, nc.conn,
                                        "svc.silent.call".cstring)
  discard natsConnection_FlushTimeout(nc.conn, 1000)
  let timeoutStarted = epochTime()
  let timedOut = call(nc, "observe", "observe_request",
    %*{"subject": "svc.silent.call", "tool": "silent",
       "args": %*{}, "timeoutMs": 150}, 2000)
  let timeoutElapsed = epochTime() - timeoutStarted
  natsSubscription_Destroy(silentSub)
  check("observe_request times out in milliseconds",
        timedOut{"error"} != nil and timeoutElapsed < 1.5,
        $timedOut & " elapsed=" & $timeoutElapsed)

  let logged = call(nc, "probe-target", "probe_log", %*{"msg": "observe-log"})
  check("target emits SDK log", logged{"ok"}.getBool(false), $logged)
  var logs = newJObject()
  let logReady = waitUntil(proc(): bool =
    logs = call(nc, "observe", "observe_logs",
                %*{"component": "probe-target", "level": "info"})
    logs{"count"}.getInt(0) >= 1)
  check("observe_logs finds structured SDK logs", logReady and
        logs{"items"}[0]{"msg"}.getStr("") == "observe-log" and
        logs{"items"}[0]{"ctx"}{"probe"}.getStr("") == "observe", $logs)

  nc.publish("raw.bad", "not-json")
  let nulData = "a\0b"
  discard natsConnection_Publish(nc.conn, "raw.nul".cstring,
                                 nulData.cstring, nulData.len.cint)
  var invalidUtf8 = "{\"x\":\""
  invalidUtf8.add(char(0xff))
  invalidUtf8.add("\"}")
  discard natsConnection_Publish(nc.conn, "raw.binary".cstring,
                                 invalidUtf8.cstring, invalidUtf8.len.cint)
  var malformed = newJObject()
  let malformedReady = waitUntil(proc(): bool =
    malformed = call(nc, "observe", "observe_events", %*{"subject": "raw.bad"})
    malformed{"count"}.getInt(0) == 1)
  check("global ring preserves malformed wire text", malformedReady and
        malformed{"items"}[0]{"envelope"}{"raw"}.getStr("") == "not-json" and
         malformed{"items"}[0]{"envelope"}{"decodeError"} != nil, $malformed)
  var embeddedNul = newJObject()
  let nulReady = waitUntil(proc(): bool =
    embeddedNul = call(nc, "observe", "observe_events", %*{"subject": "raw.nul"})
    embeddedNul{"count"}.getInt(0) == 1)
  check("raw taps preserve bytes after embedded NULs", nulReady and
        embeddedNul{"items"}[0]{"envelope"}{"raw"}.getStr("") == "a\0b",
        $embeddedNul)
  var binaryRaw = newJObject()
  let binaryReady = waitUntil(proc(): bool =
    binaryRaw = call(nc, "observe", "observe_events",
                     %*{"subject": "raw.binary"})
    binaryRaw{"count"}.getInt(0) == 1)
  let encodedBinary =
    if binaryReady: binaryRaw{"items"}[0]{"envelope"}{"rawBase64"}.getStr("")
    else: ""
  check("raw taps base64-encode invalid UTF-8", binaryReady and
        encodedBinary.len > 0 and base64.decode(encodedBinary) == invalidUtf8,
        $binaryRaw)

  createDir(captures)
  let oldCapture = captures / "pr-old.jsonl"
  writeFile(oldCapture, "x".repeat(65_500))
  let dump = call(nc, "observe", "observe_dump", %*{"probeId": traceId})
  let dumpPath = dump{"path"}.getStr("")
  check("observe_dump is confined to configured capture directory",
        dumpPath.parentDir() == captures and fileExists(dumpPath) and
        dump{"lines"}.getInt(0) == 2, $dump)
  check("observe_dump prunes old captures to its byte quota",
        not fileExists(oldCapture), $dump)
  let probes = call(nc, "observe", "observe_probes", newJObject())
  check("observe_probes exposes bounded probe metadata",
        probes{"count"}.getInt(0) >= 4 and probes{"max"}.getInt(0) == 16, $probes)
  let removed = call(nc, "observe", "observe_remove", %*{"probeId": traceId})
  check("stopped probes can be removed", removed{"removed"}.getBool(false),
        $removed)

  let monitor = call(nc, "observe", "observe_monitor", newJObject())
  check("observe_monitor reads external NATS monitoring",
        monitor{"connections"}.getInt(0) >= 1 and
        monitor{"subscriptions"}.getInt(0) >= 1 and
        monitor{"mostSubscribed"} != nil and
        monitor{"mostSubscribed"}.kind == JArray, $monitor)

  stopProcess(target)
  target = nil
  stopProcess(observe)
  observe = nil

  testCoreSpawnedMonitor(root, observeBin, tmp)

  # Invalid bounds fail at startup instead of creating a broken empty ring.
  let (invalidServer, invalidUrl) = startNats()
  defer: stopServer(invalidServer)
  let invalid = startComponent(observeBin, invalidUrl, root = tmp,
    extra = [("NIF_OBSERVE_RING", "0")])
  let invalidCode = invalid.waitForExit(3000)
  if invalidCode == -1: invalid.terminate()
  invalid.close()
  check("invalid observe configuration exits non-zero",
        invalidCode != -1 and invalidCode != 0, $invalidCode)

  report("OBSERVE TEST")

main()
