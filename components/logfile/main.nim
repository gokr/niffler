## logfile component - rotating JSONL sink for structured logs and bus capture.
##
## This is best-effort persistence, not an audit log: Core NATS can lose
## messages while the process is down. By default only ev.log.> is recorded,
## one file per valid component name. NIF_LOGFILE_SUBJECTS may select other
## subjects; non-log traffic is written to one bounded bus.jsonl file so
## dynamic inbox subjects cannot exhaust file descriptors or inodes.

import std/[algorithm, base64, json, os, re, sequtils, strutils, tables, times,
            unicode]
import niffler/sdk

loadDotEnv(".env", rootDir() / ".env")

const
  DefaultMaxBytes = 10_485_760
  DefaultKeep = 5
  DefaultMaxFiles = 64
  DefaultScanBytes = 16_777_216
  MaxConfiguredBytes = 104_857_600
  MaxSearchItems = 5000
  MaxResponseBytes = 60_000
  ResponseItemBudget = MaxResponseBytes - 4096
  MaxPathItems = 500
  MaxPatterns = 64
  MaxPatternBytes = 512
  MaxRegexBytes = 1024
  DefaultDirectoryEntries = 10_000
  LogLevels = ["debug", "info", "warn", "error"]

let root = rootDir()
let configuredDir = getEnv("NIF_LOGFILE_DIR")
let logDir =
  if configuredDir.len == 0: root / "var" / "logs"
  elif configuredDir.isAbsolute(): configuredDir
  else: root / configuredDir
let maxBytes = configInt("NIF_LOGFILE_MAX_BYTES", DefaultMaxBytes, 256,
                         MaxConfiguredBytes)
let keepN = configInt("NIF_LOGFILE_KEEP", DefaultKeep, 0, 100)
let maxComponentFiles = configInt("NIF_LOGFILE_MAX_FILES", DefaultMaxFiles, 1,
                                  1024)
let maxScanBytes = configInt("NIF_LOGFILE_SCAN_BYTES", DefaultScanBytes, 1024,
                              MaxConfiguredBytes)
let maxDirectoryEntries = configInt("NIF_LOGFILE_DIRECTORY_ENTRIES",
  DefaultDirectoryEntries, 100, 100_000)

var writeErrors = 0
var lastError = ""
var lastErrorAt = 0.0
var componentFiles = initTable[string, bool]()
var patterns: seq[string] = @[]

proc validComponentName(name: string): bool =
  if name.len == 0 or name.len > 64:
    return false
  for ch in name:
    if not (ch in {'a'..'z'} or ch in {'0'..'9'} or ch == '-'):
      return false
  true

proc validSubjectPattern(value: string): bool =
  if value.len == 0 or value.len > MaxPatternBytes or
     value.anyIt(it.isSpaceAscii):
    return false
  let tokens = value.split('.')
  for i, token in tokens:
    if token.len == 0:
      return false
    if token == ">" and i != tokens.high:
      return false
    if token != "*" and token != ">" and
       (token.contains('*') or token.contains('>')):
      return false
  true

proc matchesPattern(pattern, subject: string): bool =
  let patternTokens = pattern.split('.')
  let subjectTokens = subject.split('.')
  var i = 0
  while i < patternTokens.len:
    let token = patternTokens[i]
    if token == ">":
      return i < subjectTokens.len
    if i >= subjectTokens.len:
      return false
    if token != "*" and token != subjectTokens[i]:
      return false
    inc i
  i == subjectTokens.len

proc pathFor(subject: string): string =
  if subject.startsWith("ev.log."):
    let component = subject[7 .. ^1]
    if validComponentName(component):
      if componentFiles.hasKey(component) or
         componentFiles.len < maxComponentFiles:
        componentFiles[component] = true
        return logDir / (component & ".jsonl")
  logDir / "bus.jsonl"

proc removeIfExists(path: string) =
  if fileExists(path) or symlinkExists(path):
    removeFile(path)

proc rotate(path: string) =
  if not fileExists(path):
    return
  if keepN == 0:
    removeFile(path)
    return
  removeIfExists(path & "." & $keepN)
  for generation in countdown(keepN - 1, 1):
    let source = path & "." & $generation
    if fileExists(source):
      let target = path & "." & $(generation + 1)
      removeIfExists(target)
      moveFile(source, target)
  let first = path & ".1"
  removeIfExists(first)
  moveFile(path, first)

proc pruneRotations() =
  if not dirExists(logDir):
    return
  for kind, path in walkDir(logDir):
    if kind != pcFile:
      continue
    let marker = path.rfind(".jsonl.")
    if marker < 0:
      continue
    let suffix = path[marker + 7 .. ^1]
    try:
      if parseInt(suffix) > keepN:
        removeFile(path)
    except ValueError:
      discard

proc rawEntry(subject, data: string): JsonNode =
  result = %*{"receivedAt": epochTime(), "subject": subject}
  let invalidAt = validateUtf8(data)
  if invalidAt >= 0:
    result["rawBase64"] = %base64.encode(data)
    result["encoding"] = %"base64"
    result["bytes"] = %data.len
    result["decodeError"] = %("invalid UTF-8 at byte " & $invalidAt)
    return
  try:
    result["message"] = data.parseJson()
  except JsonParsingError as e:
    result["decodeError"] = %e.msg
    result["raw"] = %data

proc appendEntry(subject, data: string) =
  createDir(logDir)
  try:
    setFilePermissions(logDir, {fpUserRead, fpUserWrite, fpUserExec})
  except CatchableError:
    discard
  let path = pathFor(subject)
  if symlinkExists(path):
    raise newException(IOError, "refusing symlink log file " & path)
  let line = $rawEntry(subject, data)
  let recordBytes = line.len + 1
  if fileExists(path) and getFileSize(path) > 0 and
     getFileSize(path) + recordBytes > maxBytes:
    rotate(path)
  var file = open(path, fmAppend)
  try:
    file.writeLine(line)
    file.flushFile()
  finally:
    file.close()
  try:
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except CatchableError:
    discard

proc onAny(c: Component, subject: string, data: string) =
  try:
    appendEntry(subject, data)
  except CatchableError as e:
    inc writeErrors
    lastError = e.msg
    lastErrorAt = epochTime()
    stderr.writeLine("logfile: write failed: " & e.msg)

proc onConfigured(c: Component, subject: string, data: string) =
  for pattern in patterns:
    if matchesPattern(pattern, subject):
      onAny(c, subject, data)
      return

createDir(logDir)
pruneRotations()
for kind, path in walkDir(logDir):
  if kind != pcFile or not path.endsWith(".jsonl"):
    continue
  let name = path.extractFilename()[0 .. ^7]
  if name != "bus" and validComponentName(name) and
     componentFiles.len < maxComponentFiles:
    componentFiles[name] = true

let comp = newComponent("logfile", "0.1.0")
let configuredSubjects = getEnv("NIF_LOGFILE_SUBJECTS")
if configuredSubjects.len == 0:
  patterns.add("ev.log.>")
else:
  for value in configuredSubjects.split(','):
    let pattern = value.strip()
    if pattern.len == 0:
      continue
    if not validSubjectPattern(pattern):
      raise newException(ValueError,
        "NIF_LOGFILE_SUBJECTS contains an invalid or oversized subject")
    if pattern notin patterns:
      if patterns.len >= MaxPatterns:
        raise newException(ValueError, "NIF_LOGFILE_SUBJECTS exceeds " &
          $MaxPatterns & " unique patterns")
      patterns.add(pattern)
if patterns.len == 0:
  raise newException(ValueError, "NIF_LOGFILE_SUBJECTS contains no subjects")
if ">" in patterns:
  patterns = @[">"]
if patterns.len == 1:
  discard comp.tap(patterns[0], onAny)
else:
  discard comp.tap(">", onConfigured)

proc isLogFile(path: string): bool =
  if path.endsWith(".jsonl"):
    return true
  let marker = path.rfind(".jsonl.")
  if marker < 0 or marker + 7 >= path.len:
    return false
  for ch in path[marker + 7 .. ^1]:
    if ch notin Digits:
      return false
  true

proc logPayload(entry: JsonNode): JsonNode =
  if entry == nil or entry.kind != JObject:
    return nil
  let message = entry{"message"}
  if message == nil or message.kind != JObject or
     message{"kind"}.getStr("") != "event":
    return nil
  let payload = message{"payload"}
  if payload == nil or payload.kind != JObject:
    return nil
  payload

type SearchItem = tuple[at: float, order: int, node: JsonNode]

proc readTail(path: string, maxRead: int): tuple[data: string, bytes: int,
                                                    truncated: bool] =
  let size = getFileSize(path)
  if size <= 0 or maxRead <= 0:
    return
  result.truncated = size > maxRead.int64
  var bodyBudget = maxRead
  if result.truncated and bodyBudget > 1:
    dec bodyBudget # reserve one physical read for the boundary look-behind
  let wanted = min(size, bodyBudget.int64).int
  var file = open(path, fmRead)
  defer: file.close()
  var startsAtBoundary = true
  if result.truncated:
    let offset = size - wanted.int64
    if maxRead > 1:
      setFilePos(file, offset - 1)
      var previous: char
      let previousBytes = file.readBuffer(addr previous, 1)
      result.bytes += previousBytes
      startsAtBoundary = previousBytes == 1 and previous == '\n'
    else:
      startsAtBoundary = false
    setFilePos(file, offset)
  if wanted > 0:
    result.data = newString(wanted)
    let dataBytes = file.readBuffer(addr result.data[0], wanted)
    result.bytes += dataBytes
    result.data.setLen(dataBytes)
  if result.truncated and not startsAtBoundary:
    let newline = result.data.find('\n')
    if newline < 0:
      result.data.setLen(0)
    elif newline == result.data.high:
      result.data.setLen(0)
    else:
      result.data = result.data[newline + 1 .. ^1]

comp.tool(%*{"onDemand": true}):
  proc logfile_search(component: string = "", level: string = "",
                      regex: string = "", since: float = 0.0,
                      until: float = 0.0, limit: int = 100): JsonNode =
    ## Search persisted JSONL history. Structured ev.log.* records expose
    ## component/level/msg/ctx; raw bus records expose their original JSON
    ## message (or raw + decodeError). Results are newest first by sink
    ## receivedAt. The bounded scan reports truncated when it hits its byte
    ## or candidate limit.
    ## - component: only ev.log.<component> records
    ## - level: debug | info | warn | error
    ## - regex: match log text, or serialized raw bus records
    ## - since: minimum receivedAt epoch seconds
    ## - until: maximum receivedAt epoch seconds
    ## - limit: max returned items (default 100, cap 500)
    if component.len > 64:
      return %*{"error": "component filter is too long"}
    if level.len > 16 or (level.len > 0 and level notin LogLevels):
      return %*{"error": "invalid level (debug|info|warn|error)"}
    if regex.len > MaxRegexBytes:
      return %*{"error": "regex is too long"}
    if since > 0 and until > 0 and since > until:
      return %*{"error": "since must be <= until"}
    var rx: Regex
    var hasRegex = false
    if regex.len > 0:
      try:
        rx = re(regex)
        hasRegex = true
      except RegexError:
        return %*{"error": "invalid regex: " & regex}
    let resultLimit = min(max(limit, 1), 500)
    if not dirExists(logDir):
      return %*{"items": newJArray(), "count": 0, "dir": logDir,
                "scannedBytes": 0, "parseErrors": 0, "truncated": false}

    var files: seq[string] = @[]
    var directoryTruncated = false
    for kind, path in walkDir(logDir):
      if kind == pcFile and isLogFile(path):
        if files.len >= maxDirectoryEntries:
          directoryTruncated = true
          break
        files.add(path)
    files.sort(proc(a, b: string): int =
      cmp(getLastModificationTime(b).toUnixFloat(),
          getLastModificationTime(a).toUnixFloat()))

    var candidates: seq[SearchItem] = @[]
    var scannedBytes = 0
    var parseErrors = 0
    var readErrors = 0
    var order = 0
    var truncated = directoryTruncated
    var stopScanning = false
    for path in files:
      if stopScanning:
        break
      let remaining = maxScanBytes - scannedBytes
      if remaining <= 0:
        truncated = true
        break
      var tail: tuple[data: string, bytes: int, truncated: bool]
      try:
        tail = readTail(path, remaining)
      except CatchableError:
        inc readErrors
        continue
      scannedBytes += tail.bytes
      let lines = tail.data.splitLines()
      if lines.len == 0:
        if tail.truncated:
          truncated = true
          stopScanning = true
        continue
      for i in countdown(lines.high, 0):
        let line = lines[i]
        if line.len == 0:
          continue
        if candidates.len >= MaxSearchItems:
          truncated = true
          stopScanning = true
          break
        var entry: JsonNode
        try:
          entry = line.parseJson()
        except JsonParsingError:
          inc parseErrors
          continue
        let subject = entry{"subject"}.getStr("")
        let receivedAt = entry{"receivedAt"}.getFloat(0.0)
        if since > 0 and receivedAt < since: continue
        if until > 0 and receivedAt > until: continue
        let payload = logPayload(entry)
        let isLog = payload != nil and subject.startsWith("ev.log.")
        let componentName =
          if isLog: subject[7 .. ^1]
          else: ""
        if component.len > 0 and componentName != component: continue
        let entryLevel =
          if isLog: payload{"level"}.getStr("")
          else: ""
        if level.len > 0 and entryLevel != level: continue
        let message =
          if isLog: payload{"msg"}.getStr("")
          else: $entry
        if hasRegex and not contains(message, rx): continue

        var item = %*{"at": receivedAt, "receivedAt": receivedAt,
                      "subject": subject, "file": path.extractFilename()}
        if isLog:
          item["component"] = %componentName
          item["level"] = %entryLevel
          item["msg"] = %payload{"msg"}.getStr("")
          let emittedAt = payload{"at"}.getFloat(0.0)
          if emittedAt > 0: item["emittedAt"] = %emittedAt
          let ctx = payload{"ctx"}
          if ctx != nil: item["ctx"] = ctx
        else:
          let wireMessage = entry{"message"}
          if wireMessage != nil: item["message"] = wireMessage
          let raw = entry{"raw"}
          if raw != nil: item["raw"] = raw
          let rawBase64 = entry{"rawBase64"}
          if rawBase64 != nil:
            item["rawBase64"] = rawBase64
            item["encoding"] = %"base64"
            item["bytes"] = entry{"bytes"}
          let decodeError = entry{"decodeError"}
          if decodeError != nil: item["decodeError"] = decodeError
        candidates.add((at: receivedAt, order: order, node: item))
        inc order
      if tail.truncated:
        truncated = true
        stopScanning = true

    candidates.sort(proc(a, b: SearchItem): int =
      result = cmp(b.at, a.at)
      if result == 0: result = cmp(a.order, b.order))
    var items = newJArray()
    var responseBytes = 0
    for candidate in candidates:
      let itemBytes = ($candidate.node).len
      if items.len >= resultLimit or
         responseBytes + itemBytes > ResponseItemBudget:
        truncated = true
        break
      items.add(candidate.node)
      responseBytes += itemBytes
    %*{"items": items, "count": items.len, "dir": logDir,
       "scannedBytes": scannedBytes, "parseErrors": parseErrors,
       "readErrors": readErrors, "truncated": truncated,
       "directoryTruncated": directoryTruncated,
       "maxDirectoryEntries": maxDirectoryEntries,
       "responseBytes": responseBytes}

comp.tool(%*{"onDemand": true}):
  proc logfile_paths(): JsonNode =
    ## Report the configured directory, retained JSONL files, and sink health.
    ## A non-empty lastError means writes were lost; inspect stderr and fix the
    ## filesystem before relying on subsequent records.
    var found: seq[(string, int64, float)] = @[]
    var directoryTruncated = false
    if dirExists(logDir):
      for kind, path in walkDir(logDir):
        if kind == pcFile and isLogFile(path):
          if found.len >= maxDirectoryEntries:
            directoryTruncated = true
            break
          found.add((path.extractFilename(), getFileSize(path),
                     getLastModificationTime(path).toUnixFloat()))
    found.sort(proc(a, b: (string, int64, float)): int = cmp(a[0], b[0]))
    var files = newJArray()
    let metadata = %*{"dir": logDir, "files": newJArray(),
      "writeErrors": writeErrors, "lastError": lastError,
      "lastErrorAt": lastErrorAt, "maxBytes": maxBytes, "keep": keepN,
      "maxComponentFiles": maxComponentFiles,
      "componentFiles": componentFiles.len, "subjects": patterns,
      "totalFiles": found.len, "directoryTruncated": directoryTruncated,
      "maxDirectoryEntries": maxDirectoryEntries}
    var responseBytes = ($metadata).len
    var truncated = directoryTruncated
    for (name, size, mtime) in found:
      let item = %*{"name": name, "size": size, "mtime": mtime}
      let itemBytes = ($item).len + 1
      if files.len >= MaxPathItems or
         responseBytes + itemBytes > ResponseItemBudget:
        truncated = true
        break
      files.add(item)
      responseBytes += itemBytes
    %*{"dir": logDir, "files": files, "writeErrors": writeErrors,
       "lastError": lastError, "lastErrorAt": lastErrorAt,
       "maxBytes": maxBytes, "keep": keepN,
       "maxComponentFiles": maxComponentFiles,
       "componentFiles": componentFiles.len, "subjects": patterns,
       "totalFiles": found.len, "truncated": truncated,
       "directoryTruncated": directoryTruncated,
       "maxDirectoryEntries": maxDirectoryEntries,
       "responseBytes": responseBytes}

comp.run()
