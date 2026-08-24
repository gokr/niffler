## logfile tests - isolated persistence, rotation, search, raw capture, config.

import std/[base64, json, os, osproc, streams, strutils, times]
import natswrapper
import envelope
import helpers

proc stopProcess(process: Process) =
  if process == nil:
    return
  if process.running():
    process.terminate()
    sleep(500)
    if process.running(): process.kill()
  process.close()

proc waitUntil(predicate: proc(): bool, timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if predicate(): return true
    sleep(50)
  predicate()

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let logfileBin = root / "var" / "bin" / "logfile"
  if not fileExists(logfileBin):
    fail("missing logfile binary - run `make build` first")
    report("LOGFILE TEST")

  let tmp = tempRoot("logfile")
  defer: removeDir(tmp)

  # Compile a tiny SDK client once. This tests the public log() API and its
  # JsonNode default argument without booting core/store or touching repo state.
  let emitterSource = tmp / "logc.nim"
  let emitterBin = tmp / "logc"
  writeFile(emitterSource, """
import niffler/sdk
let comp = newComponent("logc", "0.1.0")
comp.tool:
  proc logc_emit(level: string, msg: string, ctx: JsonNode = nil): JsonNode =
    ## Emit one structured SDK log line.
    comp.log(level, msg, ctx)
    %*{"ok": true}
comp.run()
""".strip() & "\n")
  let compiler = startProcess("nim", args = @["c", "--hints:off",
    "--nimcache:" & (tmp / "var" / "nimcache" / "logc"),
    "--path:" & (root / "sdk"), "-o:" & emitterBin, emitterSource],
    workingDir = root, options = {poUsePath, poStdErrToStdOut})
  let compileCode = compiler.waitForExit(120_000)
  let compileOutput = compiler.outputStream.readAll()
  compiler.close()
  check("test log emitter compiles", compileCode == 0, compileOutput)
  if compileCode != 0: report("LOGFILE TEST")

  let (server, url) = startNats()
  var nc = waitConnect(url)
  defer:
    nc.close()
    if server.running(): server.terminate()
    server.close()

  let logDir = tmp / "logs"
  var logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", logDir),
             ("NIF_LOGFILE_MAX_BYTES", "450"),
             ("NIF_LOGFILE_KEEP", "2"),
             ("NIF_LOGFILE_SUBJECTS", "ev.log.>")])
  var emitter = startComponent(emitterBin, url, root = tmp,
    extra = [("NIF_LOG_LEVEL", "info")])
  defer:
    stopProcess(emitter)
    stopProcess(logfile)

  let logfileUp = waitUntil(proc(): bool =
    let response = call(nc, "logfile", "logfile_paths", newJObject(), 500)
    response{"dir"}.getStr("") == logDir)
  check("logfile registers with isolated directory", logfileUp)
  let emitterUp = waitUntil(proc(): bool =
    let response = call(nc, "logc", "logc_emit",
      %*{"level": "debug", "msg": "suppressed"}, 500)
    response{"ok"}.getBool(false))
  check("SDK log emitter registers", emitterUp)
  if not logfileUp or not emitterUp: report("LOGFILE TEST")

  let first = call(nc, "logc", "logc_emit",
    %*{"level": "info", "msg": "first", "ctx": %*{"probe": "logfile"}})
  let longMessage = "x".repeat(600)
  let second = call(nc, "logc", "logc_emit",
    %*{"level": "warn", "msg": longMessage, "ctx": %*{"probe": "logfile"}})
  let third = call(nc, "logc", "logc_emit",
    %*{"level": "error", "msg": "newest", "ctx": %*{"probe": "logfile"}})
  check("SDK emits info/warn/error logs",
        first{"ok"}.getBool(false) and second{"ok"}.getBool(false) and
        third{"ok"}.getBool(false), $first & " " & $second & " " & $third)

  var search = newJObject()
  let allWritten = waitUntil(proc(): bool =
    search = call(nc, "logfile", "logfile_search",
                  %*{"component": "logc", "limit": 20}, 2000)
    search{"count"}.getInt(0) == 3)
  check("logfile_search finds all published (not suppressed) levels", allWritten,
        $search)
  if not allWritten: report("LOGFILE TEST")

  let items = search{"items"}
  check("search returns newest first",
        items.kind == JArray and items.len == 3 and
        items[0]{"msg"}.getStr("") == "newest", $search)
  var sawFirst = false
  var sawLong = false
  for item in items:
    if item{"msg"}.getStr("") == "first":
      sawFirst = item{"ctx"}{"probe"}.getStr("") == "logfile"
    if item{"msg"}.getStr("") == longMessage: sawLong = true
  check("search preserves message and context", sawFirst and sawLong, $search)

  let newestOnly = call(nc, "logfile", "logfile_search",
                        %*{"component": "logc", "limit": 1})
  check("search limit keeps the newest record",
        newestOnly{"count"}.getInt(0) == 1 and
        newestOnly{"items"}[0]{"msg"}.getStr("") == "newest", $newestOnly)
  let newestAt = newestOnly{"items"}[0]{"receivedAt"}.getFloat(0.0)
  let window = call(nc, "logfile", "logfile_search",
                    %*{"component": "logc", "since": newestAt})
  check("search applies receivedAt windows",
        window{"count"}.getInt(0) >= 1 and
        window{"items"}[0]{"msg"}.getStr("") == "newest", $window)
  let regexResult = call(nc, "logfile", "logfile_search", %*{"regex": "^first$"})
  check("search applies regex", regexResult{"count"}.getInt(0) == 1, $regexResult)
  let invalidRegex = call(nc, "logfile", "logfile_search", %*{"regex": "["})
  check("search rejects invalid regex", invalidRegex{"error"} != nil, $invalidRegex)

  let active = logDir / "logc.jsonl"
  check("rotation keeps an active file", fileExists(active), active)
  check("rotation creates first generation", fileExists(active & ".1"), active & ".1")
  check("rotation respects retention", fileExists(active & ".2") and
        not fileExists(active & ".3"))
  let paths = call(nc, "logfile", "logfile_paths", newJObject())
  check("logfile_paths reports a healthy sink",
        paths{"writeErrors"}.getInt(-1) == 0 and paths{"files"}.kind == JArray,
        $paths)

  stopProcess(emitter)
  emitter = nil
  stopProcess(logfile)
  logfile = nil

  # Whole-bus mode uses one bus.jsonl and preserves bare JSON, unknown fields,
  # and malformed text instead of round-tripping through Envelope.
  let busDir = tmp / "bus-logs"
  logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", busDir),
             ("NIF_LOGFILE_SUBJECTS", ">"),
             ("NIF_LOGFILE_MAX_BYTES", "100000"),
             ("NIF_LOGFILE_KEEP", "1")])
  check("whole-bus logfile starts", waitUntil(proc(): bool =
    call(nc, "logfile", "logfile_paths", newJObject(), 500){"dir"}.getStr("") == busDir))
  nc.publish("reg.publish", $(%*{"name": "raw-test", "future": 7, "tools": []}))
  nc.publish("ev.raw.test",
    "{\"v\":1,\"id\":\"raw-id\",\"kind\":\"event\",\"payload\":{},\"future\":\"kept\"}")
  nc.publish("raw.invalid", "not-json")
  let nulData = "a\0b"
  discard natsConnection_Publish(nc.conn, "raw.nul".cstring,
                                 nulData.cstring, nulData.len.cint)
  var invalidUtf8 = "{\"x\":\""
  invalidUtf8.add(char(0xff))
  invalidUtf8.add("\"}")
  discard natsConnection_Publish(nc.conn, "raw.binary".cstring,
                                 invalidUtf8.cstring, invalidUtf8.len.cint)
  let largeLog = Envelope(v: 1, id: "large-log", kind: ekEvent,
    payload: %*{"component": "big", "level": "info",
                "msg": "b".repeat(70_000), "at": epochTime()})
  nc.publish("ev.log.big", largeLog.encode())
  let busFile = busDir / "bus.jsonl"
  check("whole-bus capture writes bus.jsonl", waitUntil(proc(): bool =
    fileExists(busFile) and readFile(busFile).contains("not-json") and
      readFile(busFile).contains("raw.nul") and
      readFile(busFile).contains("raw.binary") and
      fileExists(busDir / "big.jsonl")))
  var sawRegistration = false
  var sawFuture = false
  var sawMalformed = false
  var sawNul = false
  var sawBinary = false
  if fileExists(busFile):
    for line in lines(busFile):
      if line.len == 0: continue
      let entry = line.parseJson()
      if entry{"subject"}.getStr("") == "reg.publish" and
         entry{"message"}{"future"}.getInt(0) == 7:
        sawRegistration = true
      if entry{"subject"}.getStr("") == "ev.raw.test" and
         entry{"message"}{"future"}.getStr("") == "kept":
        sawFuture = true
      if entry{"subject"}.getStr("") == "raw.invalid" and
         entry{"raw"}.getStr("") == "not-json" and entry{"decodeError"} != nil:
        sawMalformed = true
      if entry{"subject"}.getStr("") == "raw.nul" and
         entry{"raw"}.getStr("") == "a\0b":
        sawNul = true
      if entry{"subject"}.getStr("") == "raw.binary" and
         entry{"encoding"}.getStr("") == "base64" and
         base64.decode(entry{"rawBase64"}.getStr("")) == invalidUtf8:
        sawBinary = true
  check("whole-bus capture preserves registration JSON", sawRegistration)
  check("whole-bus capture preserves unknown envelope fields", sawFuture)
  check("whole-bus capture preserves malformed wire text", sawMalformed)
  check("whole-bus capture preserves bytes after embedded NULs", sawNul)
  check("whole-bus capture base64-encodes invalid UTF-8", sawBinary)
  check("whole-bus capture does not create per-subject files",
        not fileExists(busDir / "raw_invalid.jsonl"))
  let boundedResponse = call(nc, "logfile", "logfile_search",
    %*{"component": "big", "limit": 500}, 3000)
  let afterBoundedResponse = call(nc, "logfile", "logfile_paths", newJObject())
  check("oversized search items truncate without terminating logfile",
        boundedResponse{"truncated"}.getBool(false) and
        boundedResponse{"responseBytes"}.getInt(-1) <= 60_000 and
        afterBoundedResponse{"dir"}.getStr("") == busDir,
        $boundedResponse & " / " & $afterBoundedResponse)
  stopProcess(logfile)
  logfile = nil

  # keep=0 explicitly discards the previous active generation on rotation.
  let zeroDir = tmp / "zero-retention"
  logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", zeroDir),
             ("NIF_LOGFILE_SUBJECTS", "ev.log.>"),
             ("NIF_LOGFILE_MAX_BYTES", "256"),
             ("NIF_LOGFILE_KEEP", "0")])
  check("zero-retention logfile starts", waitUntil(proc(): bool =
    call(nc, "logfile", "logfile_paths", newJObject(), 500){"dir"}.getStr("") == zeroDir))
  let firstOversized = Envelope(v: 1, id: "zero-first", kind: ekEvent,
    payload: %*{"component": "zero", "level": "info",
                 "msg": "z".repeat(400), "at": epochTime()})
  let secondOversized = Envelope(v: 1, id: "zero-second", kind: ekEvent,
    payload: %*{"component": "zero", "level": "info",
                "msg": "z".repeat(400), "at": epochTime()})
  nc.publish("ev.log.zero", firstOversized.encode())
  let zeroFile = zeroDir / "zero.jsonl"
  let firstStored = waitUntil(proc(): bool =
    fileExists(zeroFile) and readFile(zeroFile).contains("zero-first"))
  nc.publish("ev.log.zero", secondOversized.encode())
  let secondStored = waitUntil(proc(): bool =
    fileExists(zeroFile) and readFile(zeroFile).contains("zero-second") and
      not readFile(zeroFile).contains("zero-first"))
  check("zero retention keeps only the new active output",
        firstStored and secondStored)
  check("zero retention creates no rotated file", not fileExists(zeroFile & ".1"))
  stopProcess(logfile)
  logfile = nil

  # Search reads only the configured tail budget, and path listings are bounded
  # even when the directory was populated externally.
  let boundedDir = tmp / "bounded"
  createDir(boundedDir)
  for i in 0 ..< 550:
    writeFile(boundedDir / ("f-" & $i & ".jsonl"), "")
  writeFile(boundedDir / "huge.jsonl", "x".repeat(2_000_000))
  logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", boundedDir),
             ("NIF_LOGFILE_SCAN_BYTES", "1024")])
  check("bounded logfile starts", waitUntil(proc(): bool =
    call(nc, "logfile", "logfile_paths", newJObject(), 1000){"dir"}.getStr("") == boundedDir))
  let boundedPaths = call(nc, "logfile", "logfile_paths", newJObject(), 3000)
  check("logfile_paths bounds large directory responses",
        boundedPaths{"totalFiles"}.getInt(0) == 551 and
        boundedPaths{"files"}.len <= 500 and
        boundedPaths{"truncated"}.getBool(false), $boundedPaths)
  let boundedScan = call(nc, "logfile", "logfile_search", newJObject(), 3000)
  check("logfile_search bounds actual disk reads",
        boundedScan{"scannedBytes"}.getInt(0) <= 1024 and
        boundedScan{"truncated"}.getBool(false), $boundedScan)
  stopProcess(logfile)
  logfile = nil

  # If the scan window begins exactly at a JSONL boundary, the complete first
  # record in that window must not be discarded as a partial line.
  let boundaryDir = tmp / "boundary"
  createDir(boundaryDir)
  let oldLine = $(%*{"receivedAt": 1.0, "subject": "ev.log.boundary",
    "message": %*{"v": 1, "id": "old", "kind": "event",
      "payload": %*{"level": "info", "msg": "old"}}})
  let boundaryMessage = "tail-boundary-marker-" & "t".repeat(1500)
  let boundaryLine = $(%*{"receivedAt": 2.0,
    "subject": "ev.log.boundary",
    "message": %*{"v": 1, "id": "boundary", "kind": "event",
      "payload": %*{"level": "info", "msg": boundaryMessage}}})
  writeFile(boundaryDir / "boundary.jsonl",
            oldLine & "\n" & boundaryLine & "\n")
  logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", boundaryDir),
             ("NIF_LOGFILE_SCAN_BYTES", $(boundaryLine.len + 1))])
  check("boundary logfile starts", waitUntil(proc(): bool =
    call(nc, "logfile", "logfile_paths", newJObject(), 1000){"dir"}.getStr("") == boundaryDir))
  let boundarySearch = call(nc, "logfile", "logfile_search",
    %*{"component": "boundary", "regex": "tail-boundary-marker"}, 3000)
  check("tail scans retain records that start exactly at the byte boundary",
        boundarySearch{"count"}.getInt(0) == 1 and
        boundarySearch{"items"}[0]{"msg"}.getStr("") == boundaryMessage,
        $boundarySearch)
  stopProcess(logfile)
  logfile = nil

  let cappedDir = tmp / "directory-cap"
  createDir(cappedDir)
  let cappedLine = $(%*{"receivedAt": 3.0, "subject": "ev.log.capped",
    "message": %*{"v": 1, "id": "capped", "kind": "event",
      "payload": %*{"level": "info", "msg": "capped-entry"}}}) & "\n"
  for i in 0 ..< 550:
    writeFile(cappedDir / ("c-" & $i & ".jsonl"), cappedLine)
  logfile = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", cappedDir),
             ("NIF_LOGFILE_DIRECTORY_ENTRIES", "500")])
  check("directory-capped logfile starts", waitUntil(proc(): bool =
    call(nc, "logfile", "logfile_paths", newJObject(), 1000){"dir"}.getStr("") == cappedDir))
  let cappedPaths = call(nc, "logfile", "logfile_paths", newJObject(), 3000)
  let cappedSearch = call(nc, "logfile", "logfile_search",
                          %*{"component": "capped"}, 3000)
  check("directory caps report truncation while searching the bounded subset",
        cappedPaths{"directoryTruncated"}.getBool(false) and
        cappedPaths{"totalFiles"}.getInt(0) == 500 and
        cappedSearch{"directoryTruncated"}.getBool(false) and
        cappedSearch{"count"}.getInt(0) > 0,
        $cappedPaths & " / " & $cappedSearch)
  stopProcess(logfile)
  logfile = nil

  # Invalid configuration must fail loudly instead of silently using defaults.
  let invalid = startComponent(logfileBin, url, root = tmp,
    extra = [("NIF_LOGFILE_DIR", tmp / "invalid"),
             ("NIF_LOGFILE_MAX_BYTES", "0")])
  let invalidCode = invalid.waitForExit(3000)
  if invalidCode == -1: invalid.terminate()
  invalid.close()
  check("invalid logfile configuration exits non-zero",
        invalidCode != -1 and invalidCode != 0, $invalidCode)

  report("LOGFILE TEST")

main()
