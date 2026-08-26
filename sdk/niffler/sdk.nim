## Niffler component SDK (Nim)
##
## ~250 lines. Ports in other languages (sdk/go) mirror this file 1:1 — the
## envelope (sdk/envelope.nim + docs/WIRE.md) is the artifact, SDKs follow.
##
## Surface:
##   let comp = newComponent("greet", "0.1.0")
##   comp.tool:
##     proc greet(name: string, count: int = 1): JsonNode =
##       ## Greet someone
##       ## - name: the name to greet
##       %*{"greeting": "Hello, " & name}
##   comp.run()                     # register, serve calls, drain on signal
##   inside a handler: c.emit("ev.x", %*{}), c.request("llm-openai", "chat", ...)
##
## Implementation notes:
## - No cdecl callbacks, no threads: subscriptions are polled with
##   natsSubscription_NextMsg, so handlers always run on the main thread,
##   serialized, with normal GC. Porting this to another language is
##   mechanical (Go port uses nats.go callbacks + a mutex instead).
## - Teardown = exit; the OS is the disposer. On SIGTERM/SIGINT/ev.sys.drain
##   we announce reg.depart, finish the current message, then quit.

import std/[json, monotimes, os, osproc, strutils, strtabs, tables, times]
import std/macros
import natswrapper
import ../envelope
import ../dotenv

export envelope
export json  # components write %*{"..."} and JsonNode without their own import

type
  ToolHandler* = proc(c: Component, args: JsonNode): JsonNode
  EventHandler* = proc(c: Component, subject: string, payload: JsonNode)
  TapHandler* = proc(c: Component, subject: string, data: string)
    ## Raw wire tap: receives the full envelope bytes for every matching
    ## subject (all kinds: call/result/event/error), for bus observation.

  Tool* = object
    name*: string
    schema*: JsonNode
    handler*: ToolHandler

  SubscriptionKind = enum
    skCall, skEvent, skTap

  SubscriptionBinding = object
    sub: ptr natsSubscription
    kind: SubscriptionKind
    eventHandler: EventHandler
    tapHandler: TapHandler

  Component* = ref object
    name*: string
    version*: string
    client*: bool  ## interactive frontend (reg.publish carries "client": true)
    tools*: seq[Tool]
    eventHandlers*: seq[tuple[pattern: string, handler: EventHandler]]
    taps*: seq[tuple[pattern: string, handler: TapHandler]]
    nc*: NatsConnection
    bindings: seq[SubscriptionBinding]
    shuttingDown*: bool

var libOpened = false

proc ensureLib() =
  if not libOpened:
    let st = nats_Open(-1)
    if not checkStatus(st):
      raise newException(IOError, "nats_Open: " & getErrorString(st))
    libOpened = true

proc newComponent*(name, version: string): Component =
  ensureLib()
  result = Component(name: name, version: version)

proc tool*(c: Component, name: string, schema: JsonNode, handler: ToolHandler): Component =
  c.tools.add(Tool(name: name, schema: schema, handler: handler))
  return c

proc registerTool*(c: Component, name: string, schemaJson: string,
                   handler: ToolHandler): Component =
  ## Internal: called by the tool macro. Not for direct use.
  result = c.tool(name, schemaJson.parseJson(), handler)

proc toolSchema*(props: JsonNode, required: seq[string] = @[],
                 description = ""): JsonNode =
  ## Convenience: OpenAI tool-calling schema from a properties object.
  ## Extend with x-harness (approval, timeoutMs, hidden, onDemand) as needed.
  result = %*{"type": "object", "properties": props}
  if required.len > 0: result["required"] = %required
  if description.len > 0: result["description"] = %description

proc on*(c: Component, pattern: string, handler: EventHandler): Component =
  c.eventHandlers.add((pattern: pattern, handler: handler))
  return c

proc tap*(c: Component, pattern: string, handler: TapHandler): Component =
  ## Raw wire tap (see TapHandler): receives full envelope bytes for every
  ## matching subject. Subscriptions join the same serialized pump loop.
  c.taps.add((pattern: pattern, handler: handler))
  return c

proc emit*(c: Component, subject: string, payload: JsonNode) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: payload)
  c.nc.publish(subject, env.encode())

proc messageData(msg: ptr natsMsg): string =
  let data = natsMsg_GetData(msg)
  let length = natsMsg_GetDataLength(msg).int
  if data != nil and length > 0:
    result = newString(length)
    copyMem(addr result[0], data, length)

proc request*(c: Component, componentName, toolName: string, args: JsonNode,
              timeoutMs: int = 5000): JsonNode =
  ## Call a tool on another component (request/reply over the bus).
  ## Returns the result value; raises on timeout or error envelope.
  let env = callEnvelope(toolName, args, c.name)
  let data = env.encode()
  var msg: ptr natsMsg
  let subject = "svc." & componentName & ".call"
  let st = natsConnection_Request(addr msg, c.nc.conn, subject.cstring,
                                  data.cstring, data.len.cint,
                                  timeoutMs.int64)
  if st == NATS_TIMEOUT:
    raise newException(IOError, "request " & subject & " timed out after " & $timeoutMs & "ms")
  if not checkStatus(st):
    raise newException(IOError, "request " & subject & ": " & getErrorString(st))
  defer: natsMsg_Destroy(msg)
  let reply = decode(messageData(msg))
  if reply.id != env.id:
    raise newException(IOError, "request " & subject & ": reply id mismatch")
  if reply.kind == ekError:
    raise newException(IOError, reply.error{"message"}.getStr("component error"))
  if reply.kind != ekResult:
    raise newException(IOError, "request " & subject & ": expected result envelope")
  return reply.args

when defined(posix):
  import std/posix

var gShutdown = false

proc onSignal(sig: cint) {.noconv.} =
  gShutdown = true

proc installSignals() =
  when defined(posix):
    discard signal(SIGTERM, onSignal)
    discard signal(SIGINT, onSignal)

proc publishEnvelope*(c: Component, subject: string, env: Envelope) =
  ## Publish any pre-built envelope to any subject (fire-and-forget).
  c.nc.publish(subject, env.encode())

proc pumpTaps(c: Component, maxMessages: int): int

proc requestEnvelope*(c: Component, subject: string, env: Envelope,
                      timeoutMs: int = 5000): Envelope =
  ## Request/reply with a pre-built envelope on an arbitrary subject;
  ## returns the full reply envelope (result or error). Uses an explicit inbox
  ## poll so timeout behavior is identical to the SDK's serialized pump loop.
  let data = env.encode()
  let inbox = "_INBOX.niffler." & newId()
  var subscription: ptr natsSubscription
  let subscribeStatus = natsConnection_SubscribeSync(addr subscription,
    c.nc.conn, inbox.cstring)
  if not checkStatus(subscribeStatus):
    raise newException(IOError,
      "subscribe request inbox: " & getErrorString(subscribeStatus))
  defer: natsSubscription_Destroy(subscription)

  let publishStatus = natsConnection_PublishRequest(c.nc.conn, subject.cstring,
    inbox.cstring, data.cstring, data.len.cint)
  if not checkStatus(publishStatus):
    raise newException(IOError,
      "request " & subject & ": " & getErrorString(publishStatus))
  let flushStatus = natsConnection_FlushTimeout(c.nc.conn,
    min(timeoutMs, 1000).int64)
  if not checkStatus(flushStatus):
    raise newException(IOError,
      "request " & subject & " flush: " & getErrorString(flushStatus))

  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs.int64)
  var msg: ptr natsMsg
  while true:
    # A handler may issue this request while the component's normal pump is
    # paused. Keep raw observation taps current without nesting calls/events.
    discard c.pumpTaps(100)
    let st = natsSubscription_NextMsg(addr msg, subscription, 0)
    if st == NATS_OK:
      break
    if st != NATS_TIMEOUT:
      raise newException(IOError,
        "request " & subject & ": " & getErrorString(st))
    if getMonoTime() >= deadline:
      raise newException(IOError,
        "request " & subject & " timed out after " & $timeoutMs & "ms")
    sleep(1)
  discard c.pumpTaps(100)
  defer: natsMsg_Destroy(msg)
  result = decode(messageData(msg))
  if result.id != env.id:
    raise newException(IOError, "request " & subject & ": reply id mismatch")
  if result.kind notin {ekResult, ekError}:
    raise newException(IOError, "request " & subject & ": expected result or error envelope")

const LogLevels = ["debug", "info", "warn", "error"]

proc logLevelIndex(level: string): int =
  result = -1
  for i, candidate in LogLevels:
    if level == candidate:
      return i

proc log*(c: Component, level, msg: string, ctx: JsonNode = nil) =
  ## Standard structured logging: publishes ev.log.<component> with
  ## {component, level, msg, ctx, at}. NIF_LOG_LEVEL (default "info")
  ## suppresses lower levels before publishing.
  let lIdx = logLevelIndex(level)
  if lIdx < 0:
    raise newException(ValueError,
      "invalid log level '" & level & "' (debug|info|warn|error)")
  let threshold = getEnv("NIF_LOG_LEVEL", "info")
  var tIdx = logLevelIndex(threshold)
  if tIdx < 0:
    tIdx = logLevelIndex("info")
  if lIdx < tIdx: return
  var payload = %*{"component": c.name, "level": level,
                   "msg": msg, "at": epochTime()}
  if ctx != nil:
    payload["ctx"] = ctx
  c.emit("ev.log." & c.name, payload)

proc regPayload(c: Component): JsonNode =
  var toolsJson = newJArray()
  for t in c.tools:
    toolsJson.add(%*{"name": t.name, "schema": t.schema})
  result = %*{"name": c.name, "version": c.version,
              "pid": getCurrentProcessId(), "tools": toolsJson}
  if c.client:
    result["client"] = %true

proc announce(c: Component, subject: string) =
  c.nc.publish(subject, $c.regPayload())

# ---------------------------------------------------------------------------
# Harness discovery + ensure — for interactive clients (UIs, terminal
# frontends) that should "just work": attach to the running harness, or
# start one. A core spawned this way runs UI-owned (NIF_AUTOSTART=1): it
# exits when the last interactive client (interactive() marker) departs.

proc interactive*(c: Component): Component =
  ## Mark this component as an interactive frontend: registrations carry
  ## "client": true and an autostarted core stays alive while at least one
  ## interactive client is registered (and exits when the last one departs).
  c.client = true
  return c

proc resolveNatsUrl*(root = ""): string =
  ## Bus address: NIF_NATS_URL env → <root>/var/nats-url discovery file →
  ## the well-known local default.
  result = getEnv("NIF_NATS_URL")
  if result.len > 0: return
  let r = if root.len > 0: root else: getEnv("NIF_ROOT", ".")
  let disc = r / "var" / "nats-url"
  if fileExists(disc):
    let u = readFile(disc).strip()
    if u.len > 0: return u
  return "nats://127.0.0.1:4222"

proc coreAnswers*(url: string, timeoutMs = 500): bool =
  ## Is a live core answering svc.core.call on this bus?
  ensureLib()
  try:
    var nc = natswrapper.connect(url)
    defer: nc.close()
    let data = callEnvelope("catalog", %*{"op": "list"}).encode()
    var msg: ptr natsMsg
    let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call".cstring,
                                    data.cstring, data.len.cint, timeoutMs.int64)
    if st != NATS_OK: return false
    defer: natsMsg_Destroy(msg)
    return decode(messageData(msg)).kind == ekResult
  except CatchableError:
    return false

var lastSpawnedCore: Process  # daemon child; reaped on the next ensure

proc reapSpawnedCore() =
  if lastSpawnedCore != nil and lastSpawnedCore.peekExitCode() != -1:
    discard lastSpawnedCore.waitForExit(100)
    lastSpawnedCore.close()
  lastSpawnedCore = nil

proc candidateUrls(r: string): seq[string] =
  ## Discovery file first (core's actual bus), then the well-known port.
  let disc = r / "var" / "nats-url"
  if fileExists(disc):
    let u = readFile(disc).strip()
    if u.len > 0:
      result.add(u)
  result.add("nats://127.0.0.1:4222")

proc ensureHarness*(root = ""): string =
  ## Attach to the running harness, or start one for this root. Probe order:
  ## NIF_NATS_URL (explicit always wins — nothing is spawned), core's
  ## discovery file, the well-known port. If no core answers anywhere, spawn
  ## <root>/var/bin/niffler detached with NIF_AUTOSTART=1; that core exits
  ## when the last interactive client departs. Returns the bus URL (also
  ## exported as NIF_NATS_URL so run()/Connect picks it up).
  let explicit = getEnv("NIF_NATS_URL")
  if explicit.len > 0:
    return explicit
  let r = if root.len > 0: root else: getEnv("NIF_ROOT")
  if r.len == 0:
    raise newException(ValueError,
      "ensureHarness: no harness root (pass it or set NIF_ROOT)")
  reapSpawnedCore()
  # Probe for ~10s (NIF_ENSURE_ATTACH=0 skips attach entirely — tests):
  # covers an already-running core, a stale discovery file, and a sibling UI
  # that is spawning core right now.
  if getEnv("NIF_ENSURE_ATTACH", "1") != "0":
    let probeUntil = epochTime() + 10.0
    while true:
      for url in candidateUrls(r):
        if coreAnswers(url):
          os.putEnv("NIF_NATS_URL", url)
          return url
      if epochTime() >= probeUntil:
        break
      sleep(200)
  let coreBin = r / "var" / "bin" / "niffler"
  if not fileExists(coreBin):
    raise newException(IOError, "no harness running and core binary missing: " &
      coreBin & " — run `make build`")
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    env[k] = v
  env["NIF_ROOT"] = r
  env["NIF_AUTOSTART"] = "1"
  lastSpawnedCore = startProcess(coreBin, workingDir = r, env = env,
                                 options = {poUsePath, poDaemon})
  # Trust only OUR core now: another harness may be live on the well-known
  # port — attaching to it would orphan the child we just spawned.
  let spawnUntil = epochTime() + 20.0
  while epochTime() < spawnUntil:
    let code = lastSpawnedCore.peekExitCode()
    if code != -1:
      raise newException(IOError,
        "spawned core exited immediately (code " & $code & ")")
    let disc = r / "var" / "nats-url"
    if fileExists(disc):
      let u = readFile(disc).strip()
      if u.len > 0 and coreAnswers(u):
        os.putEnv("NIF_NATS_URL", u)
        return u
    sleep(200)
  raise newException(IOError,
    "spawned core did not answer within 20s — check " & r)

proc handleMsg(c: Component, binding: SubscriptionBinding,
               msg: ptr natsMsg) =
  let subject = $natsMsg_GetSubject(msg)
  let data = messageData(msg)
  let reply = $natsMsg_GetReply(msg)
  natsMsg_Destroy(msg)

  case binding.kind
  of skTap:
    try:
      binding.tapHandler(c, subject, data)
    except CatchableError as e:
      stderr.writeLine(c.name & ": tap handler failed: " & e.msg)
  of skEvent:
    try:
      let env = decode(data)
      binding.eventHandler(c, subject, env.payload)
    except CatchableError as e:
      stderr.writeLine(c.name & ": event handler failed: " & e.msg)
  of skCall:
    var env: Envelope
    try:
      env = decode(data)
    except CatchableError as e:
      stderr.writeLine(c.name & ": invalid call envelope: " & e.msg)
      return
    if reply.len == 0:
      return
    if env.kind != ekCall:
      try:
        c.nc.publish(reply, errorEnvelope(env.id, "bad-envelope",
          "expected call envelope").encode())
      except CatchableError as e:
        stderr.writeLine(c.name & ": reply publish failed: " & e.msg)
      return
    # tool call: find handler, answer on the reply subject
    for t in c.tools:
      if t.name == env.tool:
        var resp: Envelope
        try:
          resp = resultEnvelope(env.id, t.handler(c, env.args))
        except CatchableError as e:
          resp = errorEnvelope(env.id, "boom", e.msg)
        try:
          c.nc.publish(reply, resp.encode())
        except CatchableError as e:
          stderr.writeLine(c.name & ": reply publish failed: " & e.msg)
        return
    try:
      c.nc.publish(reply, errorEnvelope(env.id, "no-tool",
        "component " & c.name & " has no tool '" & env.tool & "'").encode())
    except CatchableError as e:
      stderr.writeLine(c.name & ": reply publish failed: " & e.msg)

proc pumpTaps(c: Component, maxMessages: int): int =
  for binding in c.bindings:
    if binding.kind != skTap:
      continue
    while result < maxMessages:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, binding.sub, 0)
      if st != NATS_OK:
        break
      inc result
      c.handleMsg(binding, msg)
    if result >= maxMessages:
      break

proc drainHandler(c: Component, subject: string, payload: JsonNode) =
  gShutdown = true

proc run*(c: Component) =
  installSignals()
  # .env from cwd and the harness root (existing env always wins)
  loadDotEnv(".env", getEnv("NIF_ROOT", ".") / ".env")
  let url = getEnv("NIF_NATS_URL", "nats://127.0.0.1:4222")
  c.nc = connect(url)

  # queue-grouped call subject: N replicas, one gets each call
  var sub: ptr natsSubscription
  let callSubject = "svc." & c.name & ".call"
  let st = natsConnection_QueueSubscribeSync(addr sub, c.nc.conn,
                                             callSubject.cstring, c.name.cstring)
  if not checkStatus(st):
    raise newException(IOError, "subscribe " & callSubject & ": " & getErrorString(st))
  c.bindings.add(SubscriptionBinding(sub: sub, kind: skCall))

  # passive event subscriptions (plus the SDK-managed drain subject)
  c.eventHandlers.add((pattern: "ev.sys.drain",
                       handler: EventHandler(drainHandler)))
  for e in c.eventHandlers:
    var s: ptr natsSubscription
    let es = natsConnection_SubscribeSync(addr s, c.nc.conn, e.pattern.cstring)
    if not checkStatus(es):
      raise newException(IOError, "subscribe " & e.pattern & ": " & getErrorString(es))
    c.bindings.add(SubscriptionBinding(sub: s, kind: skEvent,
                                      eventHandler: e.handler))

  # raw wire taps
  for t in c.taps:
    var s: ptr natsSubscription
    let ts = natsConnection_SubscribeSync(addr s, c.nc.conn, t.pattern.cstring)
    if not checkStatus(ts):
      raise newException(IOError, "subscribe " & t.pattern & ": " & getErrorString(ts))
    c.bindings.add(SubscriptionBinding(sub: s, kind: skTap,
                                      tapHandler: t.handler))

  c.announce("reg.publish")
  echo c.name & " v" & c.version & " online on " & url &
       " (" & $c.tools.len & " tools)"

  # main loop: drain subscriptions, dispatch on the main thread.
  # Drain instead of one-message-per-pass: a fully-idle sibling sub would
  # otherwise cost the pass a whole 50ms timeout, and a ">" tap (which sees
  # every message on the bus) backs up for seconds (t_observe). Bounded per
  # pass so a hammered call subject can't starve the rest.
  while not gShutdown:
    var gotOne = false
    for binding in c.bindings:
      var drained = 0
      while drained < 100:
        var msg: ptr natsMsg
        let st = natsSubscription_NextMsg(addr msg, binding.sub, 1)
        if st != NATS_OK: break
        inc drained
        gotOne = true
        c.handleMsg(binding, msg)
    if not gotOne:
      sleep(5)

  # graceful: announce departure, finish, exit
  c.announce("reg.depart")
  sleep(200)
  for binding in c.bindings:
    natsSubscription_Destroy(binding.sub)
  c.nc.close()
  quit(0)

# ---------------------------------------------------------------------------
# Typed tool definitions (nimcp-inspired: schema + handler from a proc)
#
#   comp.tool:
#     proc greet(name: string, count: int = 1): JsonNode =
#       ## Greet someone
#       ## - name: the name to greet
#       %*{"greeting": "Hello, " & name}
#
# Doc comments: first line = tool description, "- param: text" = parameter
# descriptions. Params without defaults are required. Supported types:
# string, int, float, bool, JsonNode, seq[string]. Return type JsonNode
# (other types are wrapped with %). Handlers run through the same
# error-envelope path as manual ones.

proc nimTypeToSchema(t: NimNode): JsonNode =
  # handles both nnkIdent (raw) and nnkSym (semchecked) type nodes
  case t.kind
  of nnkIdent, nnkSym:
    case $t
    of "int", "int8", "int16", "int32", "int64",
       "uint", "uint8", "uint16", "uint32", "uint64":
      %*{"type": "integer"}
    of "float", "float32", "float64":
      %*{"type": "number"}
    of "string":
      %*{"type": "string"}
    of "bool":
      %*{"type": "boolean"}
    of "JsonNode":
      %*{"type": "object"}
    else:
      %*{"type": "string"}
  of nnkBracketExpr:
    if $t[0] == "seq":
      %*{"type": "array", "items": nimTypeToSchema(t[1])}
    else:
      %*{"type": "string"}
  else:
    %*{"type": "string"}

proc procBody(procDef: NimNode): NimNode =
  ## The body is the nnkStmtList child (semchecked ProcDefs carry extra
  ## hidden children, so position-based access is unreliable)
  for i in 0 ..< procDef.len:
    if procDef[i].kind == nnkStmtList: return procDef[i]
  return procDef[^1]

proc extractToolDocs(procDef: NimNode): tuple[description: string,
                                              paramDocs: Table[string, string]] =
  ## Doc comments become the tool schema: all prose lines of the first
  ## comment block join into the description (so authors can write a full
  ## paragraph, not just one line), "- param: text" lines become
  ## per-parameter descriptions.
  let body = procBody(procDef)
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      var desc: seq[string] = @[]
      for line in stmt.strVal.splitLines():
        let clean = line.strip()
        if clean.startsWith("- "):
          let parts = clean[2 .. ^1].split(":", 1)
          if parts.len == 2:
            result.paramDocs[parts[0].strip()] = parts[1].strip()
        elif clean.len > 0:
          desc.add(clean)
      result.description = desc.join(" ")
      break

# arg helpers: required vs defaulted, with clear errors for the LLM
proc argString*(args: JsonNode, name: string): string =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  v.getStr()

proc argStringD*(args: JsonNode, name, default: string): string =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  v.getStr()

proc argInt*(args: JsonNode, name: string): int =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  v.getInt()

proc argIntD*(args: JsonNode, name: string, default: int): int =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  v.getInt()

proc argFloat*(args: JsonNode, name: string): float =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  v.getFloat()

proc argFloatD*(args: JsonNode, name: string, default: float): float =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  v.getFloat()

proc argBool*(args: JsonNode, name: string): bool =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  v.getBool()

proc argBoolD*(args: JsonNode, name: string, default: bool): bool =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  v.getBool()

proc argStrSeq*(args: JsonNode, name: string): seq[string] =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  result = @[]
  for item in v:
    result.add(item.getStr())

proc argStrSeqD*(args: JsonNode, name: string, default: seq[string]): seq[string] =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  result = @[]
  for item in v:
    result.add(item.getStr())

proc argJson*(args: JsonNode, name: string): JsonNode =
  let v = args{name}
  if v == nil or v.kind == JNull:
    raise newException(ValueError, "missing required argument '" & name & "'")
  v

proc argJsonD*(args: JsonNode, name: string, default: JsonNode): JsonNode =
  let v = args{name}
  if v == nil or v.kind == JNull: return default
  v

macro tool*(c: untyped, procDef: untyped): untyped =
  var procDef = procDef
  if procDef.kind == nnkStmtList:
    # `comp.tool:` block form — the proc def sits inside the statement list
    for stmt in procDef:
      if stmt.kind == nnkProcDef:
        procDef = stmt
        break
  procDef.expectKind(nnkProcDef)
  let procName = $procDef[0]
  let formalParams = procDef[3]

  # --- schema from the signature + doc comments ---
  var properties = newJObject()
  var required = newJArray()
  var bindings = newSeq[tuple[name: string, typ: NimNode, hasDefault: bool, default: NimNode]]()

  for i in 1 ..< formalParams.len:
    let idDefs = formalParams[i]
    if idDefs.kind != nnkIdentDefs: continue
    let pname = $idDefs[0]
    let hasDefault = idDefs.len >= 3 and idDefs[2].kind != nnkEmpty
    bindings.add((name: pname, typ: idDefs[1], hasDefault: hasDefault,
                  default: (if hasDefault: idDefs[2] else: nil)))
    properties[pname] = nimTypeToSchema(idDefs[1])
    if not hasDefault:
      required.add(%pname)

  let (description, paramDocs) = extractToolDocs(procDef)
  for b in bindings:
    if paramDocs.hasKey(b.name):
      properties[b.name]["description"] = %paramDocs[b.name]

  let schema = newJObject()
  schema["type"] = %"object"
  schema["properties"] = properties
  if required.len > 0:
    schema["required"] = required
  if description.len > 0:
    schema["description"] = %description

  # --- handler body: decode args, call the proc ---
  var argExprs = newSeq[NimNode]()
  var body = newStmtList()
  let handlerComp = genSym(nskParam, "component")
  let handlerArgs = genSym(nskParam, "toolArgs")
  for b in bindings:
    let name = ident(b.name)
    let extractCall =
      case $b.typ
      of "string":
        if b.hasDefault:
          newCall(ident("argStringD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argString"), handlerArgs, newLit(b.name))
      of "int", "int8", "int16", "int32", "int64",
         "uint", "uint8", "uint16", "uint32", "uint64":
        if b.hasDefault:
          newCall(ident("argIntD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argInt"), handlerArgs, newLit(b.name))
      of "float", "float32", "float64":
        if b.hasDefault:
          newCall(ident("argFloatD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argFloat"), handlerArgs, newLit(b.name))
      of "bool":
        if b.hasDefault:
          newCall(ident("argBoolD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argBool"), handlerArgs, newLit(b.name))
      of "JsonNode":
        if b.hasDefault:
          newCall(ident("argJsonD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argJson"), handlerArgs, newLit(b.name))
      else:
        if b.hasDefault:
          newCall(ident("argStrSeqD"), handlerArgs, newLit(b.name), b.default)
        else:
          newCall(ident("argStrSeq"), handlerArgs, newLit(b.name))
    body.add(newLetStmt(name, extractCall))
    argExprs.add(name)

  let retType = formalParams[0]
  let call = newCall(ident(procName), argExprs)
  let retExpr =
    if retType.kind == nnkIdent and $retType == "JsonNode": call
    else: newCall(ident("%"), call)
  body.add(newStmtList(newAssignment(ident("result"), retExpr)))

  # --- register: handler as a top-level proc (nimcp pattern: emit the
  # original procDef, then the wrapper, then the register call) ---
  let handlerName = genSym(nskProc, "handler")
  let handler = newProc(
    handlerName,
    [bindSym("JsonNode"),
     newIdentDefs(handlerComp, bindSym("Component")),
     newIdentDefs(handlerArgs, bindSym("JsonNode"))],
    body,
    nnkProcDef)
  result = newStmtList(
    procDef,
    handler,
    nnkDiscardStmt.newTree(
      newCall(ident("registerTool"), c, newLit(procName),
              newLit($schema), handlerName)))
