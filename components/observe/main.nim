## observe component - bounded, queryable inspection of the Niffler bus.
##
## One raw `>` tap records recent wire messages without changing core or any
## observed component. Targeted listen/trace probes keep their own bounded
## buffers. Arbitrary publishing is event-only and approval-gated; arbitrary
## service requests are separately approval-gated by core.

import std/[algorithm, base64, httpclient, json, monotimes, os, re, sequtils,
            strutils, tables, times, unicode]
import niffler/sdk
import ../../sdk/dotenv

loadDotEnv(".env", rootDir() / ".env")

const
  DefaultRingMessages = 2000
  DefaultRingBytes = 16_777_216
  DefaultEntryBytes = 65_536
  DefaultProbeBytes = 2_097_152
  DefaultMaxProbes = 32
  MaxProbeEntries = 2000
  MaxPendingSeconds = 60.0
  MaxResponseBytes = 60_000
  ResponseItemBudget = MaxResponseBytes - 4096
  MaxSubjectBytes = 512
  MaxComponentBytes = 128
  MaxToolBytes = 256
  MaxLabelBytes = 256
  MaxRegexBytes = 1024
  MaxComponents = 1000
  DefaultCaptureBytes = 67_108_864
  MaxCaptureFiles = 256
  KnownEvents = ["reg.publish", "reg.depart", "ev.sys.drain",
    "ev.catalog.updated", "ev.llm.token", "ev.session.>",
    "ev.approval.request", "ev.approval.reply", "ev.approval.resolved",
    "svc.approval.>.request", "ev.log.>",
    "ev.models.updated", "llm.cancel.>"]

type
  ProbeKind = enum
    pkListen, pkTrace

  PendingTrace = object
    observedAt: MonoTime

  Probe = ref object
    id: string
    kind: ProbeKind
    label: string
    subject: string
    traceComp: string
    regex: Regex
    hasRegex: bool
    toolRegex: Regex
    hasToolRegex: bool
    cap: int
    bytes: int
    dropped: int
    entries: seq[JsonNode]
    pending: Table[string, PendingTrace]
    startedAt: float
    stopped: bool

  Captured = object
    at: float
    subject: string
    message: JsonNode
    bytes: int

let root = rootDir()
let ringCap = configInt("NIF_OBSERVE_RING", DefaultRingMessages, 1, 10_000)
let ringByteCap = configInt("NIF_OBSERVE_RING_BYTES", DefaultRingBytes, 65_536,
                            104_857_600)
let entryByteCap = configInt("NIF_OBSERVE_ENTRY_BYTES", DefaultEntryBytes, 1024,
                             1_048_576)
let probeByteCap = configInt("NIF_OBSERVE_PROBE_BYTES", DefaultProbeBytes,
                             65_536, 16_777_216)
let maxProbes = configInt("NIF_OBSERVE_MAX_PROBES", DefaultMaxProbes, 1, 256)
let captureByteCap = configInt("NIF_OBSERVE_CAPTURE_BYTES",
  DefaultCaptureBytes, 65_536, 1_073_741_824)
let configuredCaptureDir = getEnv("NIF_OBSERVE_CAPTURE_DIR")
let captureDir =
  if configuredCaptureDir.len == 0: root / "var" / "captures"
  elif configuredCaptureDir.isAbsolute(): configuredCaptureDir
  else: root / configuredCaptureDir

var ring: seq[Captured] = @[]
var ringBytes = 0
var probes = initOrderedTable[string, Probe]()
var components = initTable[string, bool]()
var droppedComponents = 0
var subjectCounts = initTable[string, int]()
var droppedSubjects = 0

proc validSubject(value: string, wildcards: bool): bool =
  if value.len == 0 or value.len > MaxSubjectBytes or
     value.anyIt(it.isSpaceAscii):
    return false
  let tokens = value.split('.')
  if tokens.len == 0:
    return false
  for i, token in tokens:
    if token.len == 0:
      return false
    if token == ">":
      if not wildcards or i != tokens.high:
        return false
    elif token == "*":
      if not wildcards:
        return false
    elif token.contains('*') or token.contains('>'):
      return false
  true

proc validComponent(value: string): bool =
  value.len <= MaxComponentBytes and validSubject(value, false) and
    not value.contains('.')

proc addResponseItem(items, item: JsonNode, responseBytes: var int): bool =
  let itemBytes = ($item).len
  if responseBytes + itemBytes > ResponseItemBudget:
    return false
  items.add(item)
  responseBytes += itemBytes
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

proc wireMessage(data: string): JsonNode =
  if data.len > entryByteCap:
    let previewLen = min(data.len, max(1, entryByteCap * 3 div 4))
    return %*{"truncated": true, "bytes": data.len,
              "previewBase64": base64.encode(data[0 ..< previewLen]),
              "previewBytes": previewLen, "encoding": "base64"}
  let invalidAt = validateUtf8(data)
  if invalidAt >= 0:
    return %*{"rawBase64": base64.encode(data), "encoding": "base64",
              "bytes": data.len,
              "decodeError": "invalid UTF-8 at byte " & $invalidAt}
  try:
    result = data.parseJson()
  except JsonParsingError as e:
    result = %*{"decodeError": e.msg}
    result["raw"] = %data

proc addRing(at: float, subject, data: string, message: JsonNode) =
  let messageBytes = ($message).len + subject.len
  ring.add(Captured(at: at, subject: subject, message: message,
                    bytes: messageBytes))
  ringBytes += messageBytes
  while ring.len > ringCap or ringBytes > ringByteCap:
    ringBytes -= ring[0].bytes
    ring.delete(0)
  if not subject.startsWith("_INBOX.") and subject.len <= MaxSubjectBytes:
    if subjectCounts.hasKey(subject):
      inc subjectCounts[subject]
    elif subjectCounts.len < 2000:
      subjectCounts[subject] = 1
    else:
      inc droppedSubjects
  elif not subject.startsWith("_INBOX."):
    inc droppedSubjects

proc removePending(pr: Probe, entry: JsonNode) =
  let envelope = entry{"envelope"}
  if envelope != nil and envelope{"direction"}.getStr("") == "request":
    let id = envelope{"id"}.getStr("")
    if id.len > 0:
      pr.pending.del(id)

proc appendProbe(pr: Probe, entry: JsonNode): bool =
  let entryBytes = ($entry).len
  if entryBytes > probeByteCap:
    inc pr.dropped
    return false
  pr.entries.add(entry)
  pr.bytes += entryBytes
  while pr.entries.len > pr.cap or pr.bytes > probeByteCap:
    pr.removePending(pr.entries[0])
    pr.bytes -= ($pr.entries[0]).len
    pr.entries.delete(0)
  true

proc prunePending(pr: Probe, now: MonoTime) =
  var expired: seq[string] = @[]
  for id, pending in pr.pending:
    if (now - pending.observedAt).inMilliseconds.float / 1000.0 >
       MaxPendingSeconds:
      expired.add(id)
  for id in expired:
    pr.pending.del(id)

proc traceSubjectMatches(component, subject: string): bool =
  let tokens = subject.split('.')
  (tokens.len == 3 and tokens[0] == "svc" and tokens[1] == component and
   tokens[2] == "call") or
  (tokens.len == 4 and tokens[0] == "svc" and tokens[1] == component and
   tokens[3] == "call")

proc captureFor(pr: Probe, at: float, observedAt: MonoTime, subject: string,
                message: JsonNode) =
  if pr.stopped:
    return
  case pr.kind
  of pkListen:
    if not matchesPattern(pr.subject, subject):
      return
    if pr.hasRegex and not contains($message, pr.regex):
      return
    discard pr.appendProbe(%*{"at": at, "subject": subject,
                              "envelope": message})
  of pkTrace:
    pr.prunePending(observedAt)
    if message == nil or message.kind != JObject:
      return
    let kind = message{"kind"}.getStr("")
    let id = message{"id"}.getStr("")
    if kind == "call" and traceSubjectMatches(pr.traceComp, subject):
      let tool = message{"tool"}.getStr("")
      if pr.hasToolRegex and not contains(tool, pr.toolRegex):
        return
      var envelope = %*{"direction": "request", "kind": "call", "id": id,
                        "component": pr.traceComp, "tool": tool}
      let args = message{"args"}
      if args != nil: envelope["args"] = args
      let entry = %*{"at": at, "subject": subject, "envelope": envelope}
      let retained = pr.appendProbe(entry)
      if retained and id.len > 0:
        pr.pending[id] = PendingTrace(observedAt: observedAt)
        if pr.pending.len > pr.cap:
          var oldestId = ""
          var oldestAge = -1'i64
          for pendingId, pending in pr.pending:
            let age = (observedAt - pending.observedAt).inNanoseconds
            if age >= oldestAge:
              oldestAge = age
              oldestId = pendingId
          if oldestId.len > 0: pr.pending.del(oldestId)
    elif kind in ["result", "error"] and subject.startsWith("_INBOX.") and
         id.len > 0 and pr.pending.hasKey(id):
      let pending = pr.pending[id]
      var envelope = %*{"direction": "reply", "kind": kind, "id": id,
                         "component": pr.traceComp,
                         "elapsedMs":
                           (observedAt - pending.observedAt).inNanoseconds.float /
                           1_000_000.0}
      if kind == "result":
        let args = message{"args"}
        if args != nil: envelope["result"] = args
      else:
        let error = message{"error"}
        if error != nil: envelope["error"] = error
      discard pr.appendProbe(%*{"at": at, "subject": subject,
                                "envelope": envelope})
      pr.pending.del(id)

proc onBus(c: Component, subject: string, data: string) =
  let observedAt = getMonoTime()
  let at = epochTime()
  let message = wireMessage(data)
  addRing(at, subject, data, message)
  for pr in probes.values:
    pr.captureFor(at, observedAt, subject, message)

  if subject in ["reg.publish", "reg.depart"] and message.kind == JObject:
    let name = message{"name"}.getStr("")
    if validComponent(name):
      if subject == "reg.publish":
        if components.hasKey(name) or components.len < MaxComponents:
          components[name] = true
        else:
          inc droppedComponents
      else:
        components.del(name)

let comp = newComponent("observe", "0.1.0")
discard comp.tap(">", onBus)

proc serviceSubject(name: string): string =
  if name.startsWith("session-") and name.len > 8:
    return "svc.session." & name[8 .. ^1] & ".call"
  "svc." & name & ".call"

comp.tool(%*{"onDemand": true}):
  proc observe_subjects(): JsonNode =
    ## Discover components, service subjects, known event patterns, and the
    ## most frequently observed concrete subjects. Use this before starting a
    ## listen or trace probe. Core's snapshot is authoritative, so crashed
    ## components disappear even when they could not publish reg.depart.
    try:
      let snapshot = comp.requestEnvelope("svc.core.call",
        callEnvelope("catalog", %*{"op": "components"}), 250)
      if snapshot.kind == ekResult:
        let live = snapshot.args{"components"}
        if live != nil and live.kind == JObject:
          components.clear()
          droppedComponents = 0
          for name, _ in live:
            if validComponent(name) and components.len < MaxComponents:
              components[name] = true
            elif validComponent(name):
              inc droppedComponents
    except CatchableError:
      discard

    var names = toSeq(components.keys)
    names.sort()
    var componentItems = newJArray()
    var services = newJArray()
    var known = newJArray()
    var responseBytes = 0
    for subject in KnownEvents:
      let item = %subject
      discard addResponseItem(known, item, responseBytes)
    var componentsTruncated = droppedComponents > 0
    for name in names:
      let componentItem = %name
      let serviceItem = %serviceSubject(name)
      let pairBytes = ($componentItem).len + ($serviceItem).len
      if responseBytes + pairBytes > ResponseItemBudget:
        componentsTruncated = true
        break
      componentItems.add(componentItem)
      services.add(serviceItem)
      responseBytes += pairBytes

    var counts: seq[(string, int)] = @[]
    for subject, count in subjectCounts:
      counts.add((subject, count))
    counts.sort(proc(a, b: (string, int)): int =
      result = cmp(b[1], a[1])
      if result == 0: result = cmp(a[0], b[0]))
    var observed = newJArray()
    var observedTruncated = counts.len > 100
    for i in 0 ..< min(counts.len, 100):
      let item = %*{"subject": counts[i][0], "count": counts[i][1]}
      if not addResponseItem(observed, item, responseBytes):
        observedTruncated = true
        break
    %*{"components": componentItems, "serviceSubjects": services,
       "knownEventSubjects": known, "observedSubjects": observed,
       "componentsTruncated": componentsTruncated,
       "droppedComponentNames": droppedComponents,
       "observedSubjectTotal": counts.len,
       "observedSubjectsTruncated": observedTruncated,
       "droppedSubjectNames": droppedSubjects,
       "responseBytes": responseBytes}
comp.tool(%*{"approval": "always", "onDemand": true}):
  proc observe_send(subject: string, payload: JsonNode = nil): JsonNode =
    ## Publish one event envelope. Use this only to exercise an event-driven
    ## behavior; it cannot call tools or spoof registrations. Core asks for
    ## human approval because events such as drain/cancel can change runtime
    ## behavior.
    ## - subject: concrete ev.* or llm.cancel.* subject (no wildcards)
    ## - payload: event payload
    if not validSubject(subject, false):
      raise newException(ValueError, "subject must be a concrete NATS subject")
    if not (subject.startsWith("ev.") or subject.startsWith("llm.cancel.")):
      raise newException(ValueError, "observe_send only publishes ev.* or llm.cancel.* events")
    comp.emit(subject, if payload == nil: newJObject() else: payload)
    okResult(%*{"subject": subject})

comp.tool(%*{"approval": "always", "timeoutMs": 35_000, "onDemand": true}):
  proc observe_request(subject: string, tool: string,
                       args: JsonNode = nil, timeoutMs: int = 5000): JsonNode =
    ## Send a request/reply call to a concrete service subject for diagnosis.
    ## This bypasses normal tool-name routing, so core always requires human
    ## approval and shows the target subject/tool before dispatch. The timeout
    ## is clamped to 100..30000 ms.
    ## - subject: concrete svc.*.call subject
    ## - tool: target tool name
    ## - args: call arguments
    ## - timeoutMs: wait time in milliseconds
    if not validSubject(subject, false) or not subject.startsWith("svc.") or
       not subject.endsWith(".call"):
      raise newException(ValueError, "subject must be a concrete svc.*.call subject")
    if tool.len == 0 or tool.len > MaxToolBytes:
      raise newException(ValueError, "tool must be 1.." & $MaxToolBytes & " bytes")
    if timeoutMs < 100 or timeoutMs > 30_000:
      raise newException(ValueError, "timeoutMs must be in 100..30000")
    let request = callEnvelope(tool, if args == nil: newJObject() else: args)
    let started = getMonoTime()
    let reply = comp.requestEnvelope(subject, request, timeoutMs)
    let elapsedMs = (getMonoTime() - started).inMilliseconds
    if reply.kind == ekError:
      let errorBytes = if reply.error == nil: 4 else: ($reply.error).len
      if errorBytes > ResponseItemBudget:
        return %*{"ok": false, "errorTruncated": true,
                  "errorBytes": errorBytes, "elapsedMs": elapsedMs}
      return %*{"ok": false, "error": reply.error, "elapsedMs": elapsedMs}
    let valueBytes = if reply.args == nil: 4 else: ($reply.args).len
    if valueBytes > ResponseItemBudget:
      return okResult(%*{"valueTruncated": true,
                         "valueBytes": valueBytes, "elapsedMs": elapsedMs})
    okResult(%*{"value": reply.args, "elapsedMs": elapsedMs})

proc newProbe(kind: ProbeKind, subject, label: string, cap: int): Probe =
  if probes.len >= maxProbes:
    raise newException(ValueError, "probe limit reached (" & $maxProbes &
      "); stop and remove an old probe")
  result = Probe(id: "pr-" & newId(), kind: kind, subject: subject,
                 label: label, cap: min(max(cap, 1), MaxProbeEntries),
                 pending: initTable[string, PendingTrace](),
                 startedAt: epochTime())

comp.tool(%*{"onDemand": true}):
  proc observe_listen(subject: string, regex: string = "", label: string = "",
                      cap: int = 500): JsonNode =
    ## Start a bounded recording probe for a NATS subject pattern. Optional
    ## regex matches the preserved wire JSON. Read with observe_events; stop
    ## and remove probes when done so their memory can be reclaimed.
    ## - subject: NATS subject or wildcard pattern, e.g. ev.log.* or svc.>
    ## - regex: optional regex over serialized wire JSON
    ## - label: human label shown by observe_probes
    ## - cap: retained entries (default 500, max 2000)
    if not validSubject(subject, true):
      raise newException(ValueError, "invalid or oversized NATS subject pattern")
    if label.len > MaxLabelBytes:
      raise newException(ValueError, "label must be at most " &
        $MaxLabelBytes & " bytes")
    if regex.len > MaxRegexBytes:
      raise newException(ValueError, "regex must be at most " &
        $MaxRegexBytes & " bytes")
    let pr = newProbe(pkListen, subject, label, cap)
    if regex.len > 0:
      try:
        pr.regex = re(regex)
        pr.hasRegex = true
      except RegexError:
        return errResult("invalid regex: " & regex)
    probes[pr.id] = pr
    %*{"probeId": pr.id, "subject": subject, "listening": true,
       "cap": pr.cap}
comp.tool(%*{"onDemand": true}):
  proc observe_trace(component: string, toolRegex: string = "",
                     cap: int = 500): JsonNode =
    ## Trace calls to svc.<component>.call and one scoped suffix
    ## (svc.<component>.<id>.call), correlating result/error inbox replies by
    ## envelope id with elapsedMs. Unanswered calls expire after 60 seconds.
    ## - component: component/service token, e.g. bash or session
    ## - toolRegex: optional tool-name regex
    ## - cap: retained request/reply entries (default 500, max 2000)
    if not validComponent(component):
      raise newException(ValueError, "component must be one subject token")
    if toolRegex.len > MaxRegexBytes:
      raise newException(ValueError, "toolRegex must be at most " &
        $MaxRegexBytes & " bytes")
    let pr = newProbe(pkTrace, "svc." & component & ".call", component, cap)
    pr.traceComp = component
    if toolRegex.len > 0:
      try:
        pr.toolRegex = re(toolRegex)
        pr.hasToolRegex = true
      except RegexError:
        return errResult("invalid toolRegex: " & toolRegex)
    probes[pr.id] = pr
    %*{"probeId": pr.id, "subject": pr.subject, "listening": true,
       "cap": pr.cap}
comp.tool(%*{"onDemand": true}):
  proc observe_probes(): JsonNode =
    ## List active and stopped probes with their bounds and pending trace
    ## counts. Remove stopped probes after exporting anything you need.
    var items = newJArray()
    var responseBytes = 0
    var truncated = false
    let now = getMonoTime()
    for id, pr in probes:
      pr.prunePending(now)
      let item = %*{"probeId": id, "kind": $pr.kind, "label": pr.label,
                    "subject": pr.subject, "startedAt": pr.startedAt,
                    "stopped": pr.stopped, "captured": pr.entries.len,
                    "pending": pr.pending.len, "cap": pr.cap,
                    "bytes": pr.bytes, "byteCap": probeByteCap,
                    "dropped": pr.dropped}
      if not addResponseItem(items, item, responseBytes):
        truncated = true
        break
    %*{"items": items, "count": items.len, "total": probes.len,
       "max": maxProbes, "truncated": truncated,
       "responseBytes": responseBytes}
comp.tool(%*{"onDemand": true}):
  proc observe_stop(probeId: string): JsonNode =
    ## Stop recording into a probe while keeping its entries queryable.
    ## - probeId: id returned by observe_listen or observe_trace
    if probeId.len > 128:
      return errResult("invalid probe id")
    let pr = probes.getOrDefault(probeId)
    if pr == nil:
      return errResult("no such probe")
    pr.stopped = true
    pr.pending.clear()
    %*{"stopped": true, "probeId": probeId, "captured": pr.entries.len}
comp.tool(%*{"onDemand": true}):
  proc observe_remove(probeId: string): JsonNode =
    ## Delete a probe and release its captured memory.
    ## - probeId: id returned by observe_listen or observe_trace
    if probeId.len > 128 or not probes.hasKey(probeId):
      return errResult("no such probe")
    let captured = probes[probeId].entries.len
    probes.del(probeId)
    %*{"removed": true, "probeId": probeId, "captured": captured}
comp.tool(%*{"onDemand": true}):
  proc observe_events(probeId: string = "", limit: int = 100,
                      since: float = 0.0, until: float = 0.0,
                      kind: string = "", component: string = "",
                      subject: string = "", regex: string = ""): JsonNode =
    ## Query a probe buffer or the global ring, newest first. Filters combine.
    ## Results are response-size bounded and report truncated when more matched.
    ## - probeId: probe id, or omit for the global ring
    ## - limit: max items (default 100, cap 500)
    ## - since: minimum capture epoch seconds
    ## - until: maximum capture epoch seconds
    ## - kind: call | result | event | error
    ## - component: svc/trace component filter
    ## - subject: exact concrete subject
    ## - regex: regex over serialized wire JSON
    if probeId.len > 128:
      return errResult("invalid probe id")
    if kind.len > 16 or (kind.len > 0 and
       kind notin ["call", "result", "event", "error"]):
      return errResult("invalid kind")
    if component.len > MaxComponentBytes:
      return errResult("component filter is too long")
    if subject.len > MaxSubjectBytes:
      return errResult("subject filter is too long")
    if regex.len > MaxRegexBytes:
      return errResult("regex is too long")
    if since > 0 and until > 0 and since > until:
      return errResult("since must be <= until")
    var rx: Regex
    var hasRegex = false
    if regex.len > 0:
      try:
        rx = re(regex)
        hasRegex = true
      except RegexError:
        return errResult("invalid regex: " & regex)
    let resultLimit = min(max(limit, 1), 500)
    var source: seq[Captured] = @[]
    var sourceName = "ring"
    if probeId.len > 0:
      let pr = probes.getOrDefault(probeId)
      if pr == nil:
        return errResult("no such probe")
      sourceName = "probe " & probeId
      for entry in pr.entries:
        source.add(Captured(at: entry{"at"}.getFloat(0.0),
          subject: entry{"subject"}.getStr(""), message: entry{"envelope"}))
    else:
      source = ring

    var items = newJArray()
    var responseBytes = 0
    var truncated = false
    if source.len > 0:
      for i in countdown(source.high, 0):
        let entry = source[i]
        if since > 0 and entry.at < since: continue
        if until > 0 and entry.at > until: continue
        if kind.len > 0 and entry.message{"kind"}.getStr("") != kind: continue
        if component.len > 0 and
           not (entry.subject.startsWith("svc." & component & ".") or
                entry.subject == "ev.log." & component or
                entry.message{"component"}.getStr("") == component):
          continue
        if subject.len > 0 and entry.subject != subject: continue
        if hasRegex and not contains($entry.message, rx): continue
        let item = %*{"at": entry.at, "subject": entry.subject,
                      "envelope": entry.message}
        let itemBytes = ($item).len
        if items.len >= resultLimit or responseBytes + itemBytes > MaxResponseBytes:
          truncated = true
          break
        items.add(item)
        responseBytes += itemBytes
    %*{"items": items, "count": items.len, "source": sourceName,
       "truncated": truncated, "responseBytes": responseBytes}
comp.tool(%*{"onDemand": true}):
  proc observe_logs(level: string = "", component: string = "",
                    regex: string = "", since: float = 0.0,
                    limit: int = 100): JsonNode =
    ## Search recent structured ev.log.* events in memory, newest first. For
    ## persisted history use logfile_search.
    ## - level: debug | info | warn | error
    ## - component: exact emitting component
    ## - regex: regex over message text
    ## - since: minimum sink capture epoch seconds
    ## - limit: max items (default 100, cap 500)
    if level.len > 16 or (level.len > 0 and
       level notin ["debug", "info", "warn", "error"]):
      return errResult("invalid level")
    if component.len > MaxComponentBytes:
      return errResult("component filter is too long")
    if regex.len > MaxRegexBytes:
      return errResult("regex is too long")
    var rx: Regex
    var hasRegex = false
    if regex.len > 0:
      try:
        rx = re(regex)
        hasRegex = true
      except RegexError:
        return errResult("invalid regex: " & regex)
    let resultLimit = min(max(limit, 1), 500)
    var items = newJArray()
    var responseBytes = 0
    var truncated = false
    if ring.len > 0:
      for i in countdown(ring.high, 0):
        let entry = ring[i]
        if not entry.subject.startsWith("ev.log."): continue
        if since > 0 and entry.at < since: continue
        if entry.message == nil or entry.message.kind != JObject or
           entry.message{"kind"}.getStr("") != "event":
          continue
        let payload = entry.message{"payload"}
        if payload == nil or payload.kind != JObject: continue
        let componentName = entry.subject[7 .. ^1]
        if component.len > 0 and componentName != component: continue
        let entryLevel = payload{"level"}.getStr("")
        if level.len > 0 and entryLevel != level: continue
        let message = payload{"msg"}.getStr("")
        if hasRegex and not contains(message, rx): continue
        var item = %*{"at": entry.at, "subject": entry.subject,
                      "component": componentName, "level": entryLevel,
                      "msg": message}
        let emittedAt = payload{"at"}.getFloat(0.0)
        if emittedAt > 0: item["emittedAt"] = %emittedAt
        let ctx = payload{"ctx"}
        if ctx != nil: item["ctx"] = ctx
        let itemBytes = ($item).len
        if items.len >= resultLimit or responseBytes + itemBytes > MaxResponseBytes:
          truncated = true
          break
        items.add(item)
        responseBytes += itemBytes
    %*{"items": items, "count": items.len, "truncated": truncated,
       "responseBytes": responseBytes}
proc prepareCapture(path: string, requiredBytes: int) =
  if requiredBytes > captureByteCap:
    raise newException(IOError, "probe exceeds capture byte quota")
  var files: seq[(string, int64, float)] = @[]
  var totalBytes = 0'i64
  if dirExists(captureDir):
    for kind, candidate in walkDir(captureDir):
      let name = candidate.extractFilename()
      if kind == pcFile and candidate != path and name.startsWith("pr-") and
         name.endsWith(".jsonl"):
        let size = getFileSize(candidate)
        files.add((candidate, size, getLastModificationTime(candidate).toUnixFloat()))
        totalBytes += size
  files.sort(proc(a, b: (string, int64, float)): int = cmp(a[2], b[2]))
  var index = 0
  while index < files.len and
        (files.len - index >= MaxCaptureFiles or
         totalBytes + requiredBytes.int64 > captureByteCap.int64):
    removeFile(files[index][0])
    totalBytes -= files[index][1]
    inc index
  if files.len - index >= MaxCaptureFiles or
     totalBytes + requiredBytes.int64 > captureByteCap.int64:
    raise newException(IOError, "capture directory quota is exhausted")

comp.tool(%*{"approval": "always", "onDemand": true}):
  proc observe_dump(probeId: string): JsonNode =
    ## Export a probe to NIF_OBSERVE_CAPTURE_DIR (default var/captures).
    ## The generated filename is confined to that directory; arbitrary paths
    ## are intentionally unsupported.
    ## - probeId: id returned by observe_listen or observe_trace
    if probeId.len > 128:
      return errResult("invalid probe id")
    let pr = probes.getOrDefault(probeId)
    if pr == nil:
      return errResult("no such probe")
    createDir(captureDir)
    try:
      setFilePermissions(captureDir, {fpUserRead, fpUserWrite, fpUserExec})
    except CatchableError:
      discard
    let path = captureDir / (probeId & ".jsonl")
    if symlinkExists(path):
      raise newException(IOError, "refusing symlink capture file " & path)
    var requiredBytes = 0
    for entry in pr.entries:
      requiredBytes += ($entry).len + 1
    prepareCapture(path, requiredBytes)
    var file = open(path, fmWrite)
    try:
      for entry in pr.entries:
        file.writeLine($entry)
      file.flushFile()
    finally:
      file.close()
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    except CatchableError:
      discard
    %*{"path": path, "lines": pr.entries.len, "bytes": requiredBytes,
       "captureByteCap": captureByteCap}

comp.tool(%*{"approval": "always", "onDemand": true}):
  proc observe_monitor(): JsonNode =
    ## Read nats-server HTTP monitoring counts and the most-subscribed subject
    ## patterns. Core writes var/nats-monitor-url only for a bus it spawned;
    ## otherwise configure NIF_OBSERVE_MONITOR_URL.
    var url = getEnv("NIF_OBSERVE_MONITOR_URL")
    if url.len == 0:
      let monitorFile = root / "var" / "nats-monitor-url"
      if fileExists(monitorFile):
        url = readFile(monitorFile).strip()
    if url.len == 0:
      return errResult("no NATS monitoring endpoint; set NIF_OBSERVE_MONITOR_URL or let core spawn the bus")
    try:
      proc fetch(path: string): JsonNode =
        var client = newHttpClient()
        client.timeout = 3000
        try:
          let response = client.get(url & path)
          if not response.status.startsWith("200"):
            raise newException(IOError, path & ": " & response.status)
          result = response.body.parseJson()
        finally:
          client.close()

      let subscriptions = fetch("/subsz?subs=1&limit=1024")
      let list = subscriptions{"subscriptions_list"}
      if list == nil or list.kind != JArray:
        return errResult("monitor " & url & ": /subsz omitted subscriptions_list")
      var counts = initCountTable[string]()
      for item in list:
        if item.kind != JObject: continue
        let subject = item{"subject"}.getStr("")
        if subject.len > 0: counts.inc(subject)
      var pairs: seq[(string, int)] = @[]
      for subject, subscribers in counts:
        pairs.add((subject, subscribers))
      pairs.sort(proc(a, b: (string, int)): int =
        result = cmp(b[1], a[1])
        if result == 0: result = cmp(a[0], b[0]))
      var mostSubscribed = newJArray()
      for i in 0 ..< min(pairs.len, 30):
        mostSubscribed.add(%*{"subject": pairs[i][0],
                              "subscribers": pairs[i][1]})
      let connections = fetch("/connz")
      let connectionCount = connections{"num_connections"}
      let subscriptionCount = subscriptions{"num_subscriptions"}
      if connectionCount == nil or subscriptionCount == nil:
        return errResult("monitor " & url & ": count fields missing")
      return %*{"connections": connectionCount.getInt(0),
                "subscriptions": subscriptionCount.getInt(0),
                "mostSubscribed": mostSubscribed,
                "subscriptionDetailsReturned": list.len,
                "subscriptionDetailsTruncated":
                  subscriptionCount.getInt(0) > list.len}
    except CatchableError as e:
      return errResult("monitor " & url & ": " & e.msg)
comp.run()
