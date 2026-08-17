## mini Niffler component SDK (Nim)
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

import std/[json, os, strutils, tables]
import std/macros
import natswrapper
import ../envelope
import ../dotenv

export envelope
export json  # components write %*{"..."} and JsonNode without their own import

type
  ToolHandler* = proc(c: Component, args: JsonNode): JsonNode
  EventHandler* = proc(c: Component, subject: string, payload: JsonNode)

  Tool* = object
    name*: string
    schema*: JsonNode
    handler*: ToolHandler

  Component* = ref object
    name*: string
    version*: string
    tools*: seq[Tool]
    eventHandlers*: seq[tuple[pattern: string, handler: EventHandler]]
    nc*: NatsConnection
    subs*: seq[ptr natsSubscription]
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
  ## Extend the result with x-harness (approval, timeoutMs, hidden) as needed.
  result = %*{"type": "object", "properties": props}
  if required.len > 0: result["required"] = %required
  if description.len > 0: result["description"] = %description

proc on*(c: Component, pattern: string, handler: EventHandler): Component =
  c.eventHandlers.add((pattern: pattern, handler: handler))
  return c

proc matches(pattern, subject: string): bool =
  if pattern == subject: return true
  if pattern == ">": return true
  if pattern.endsWith(".>"):
    return subject.startsWith(pattern[0 .. ^3])
  return false

proc emit*(c: Component, subject: string, payload: JsonNode) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: payload)
  c.nc.publish(subject, env.encode())

proc request*(c: Component, componentName, toolName: string, args: JsonNode,
              timeoutMs: int = 5000): JsonNode =
  ## Call a tool on another component (request/reply over the bus).
  ## Returns the result value; raises on timeout or error envelope.
  let env = callEnvelope(toolName, args)
  let data = env.encode()
  var msg: ptr natsMsg
  let subject = "svc." & componentName & ".call"
  let st = natsConnection_Request(addr msg, c.nc.conn, subject.cstring,
                                  data.cstring, data.len.cint,
                                  timeoutMs.int64 * 1_000_000)
  if st == NATS_TIMEOUT:
    raise newException(IOError, "request " & subject & " timed out after " & $timeoutMs & "ms")
  if not checkStatus(st):
    raise newException(IOError, "request " & subject & ": " & getErrorString(st))
  let reply = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  if reply.kind == ekError:
    raise newException(IOError, reply.error{"message"}.getStr("component error"))
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

proc regPayload(c: Component): JsonNode =
  var toolsJson = newJArray()
  for t in c.tools:
    toolsJson.add(%*{"name": t.name, "schema": t.schema})
  result = %*{"name": c.name, "version": c.version,
              "pid": getCurrentProcessId(), "tools": toolsJson}

proc announce(c: Component, subject: string) =
  c.nc.publish(subject, $c.regPayload())

proc handleMsg(c: Component, msg: ptr natsMsg) =
  let subject = $natsMsg_GetSubject(msg)
  let data = $natsMsg_GetData(msg)
  let reply = $natsMsg_GetReply(msg)
  natsMsg_Destroy(msg)

  let env = decode(data)

  if env.kind == ekCall and reply.len > 0:
    # tool call: find handler, answer on the reply subject
    for t in c.tools:
      if t.name == env.tool:
        var resp: Envelope
        try:
          resp = resultEnvelope(env.id, t.handler(c, env.args))
        except CatchableError as e:
          resp = errorEnvelope(env.id, "boom", e.msg)
        c.nc.publish(reply, resp.encode())
        return
    c.nc.publish(reply, errorEnvelope(env.id, "no-tool",
      "component " & c.name & " has no tool '" & env.tool & "'").encode())
  else:
    # passive event
    for e in c.eventHandlers:
      if matches(e.pattern, subject):
        try:
          e.handler(c, subject, env.payload)
        except CatchableError:
          discard  # event handlers must not kill the component

proc drainHandler(c: Component, subject: string, payload: JsonNode) =
  gShutdown = true

proc run*(c: Component) =
  installSignals()
  # .env from cwd and the harness root (existing env always wins)
  loadDotEnv(".env", getEnv("NIF_ROOT", ".") / ".env")
  let url = getEnv("NATS_URL", "nats://127.0.0.1:4222")
  c.nc = connect(url)

  # queue-grouped call subject: N replicas, one gets each call
  var sub: ptr natsSubscription
  let callSubject = "svc." & c.name & ".call"
  let st = natsConnection_QueueSubscribeSync(addr sub, c.nc.conn,
                                             callSubject.cstring, c.name.cstring)
  if not checkStatus(st):
    raise newException(IOError, "subscribe " & callSubject & ": " & getErrorString(st))
  c.subs.add(sub)

  # passive event subscriptions (plus the SDK-managed drain subject)
  c.eventHandlers.add((pattern: "ev.sys.drain",
                       handler: EventHandler(drainHandler)))
  for e in c.eventHandlers:
    var s: ptr natsSubscription
    let es = natsConnection_SubscribeSync(addr s, c.nc.conn, e.pattern.cstring)
    if not checkStatus(es):
      raise newException(IOError, "subscribe " & e.pattern & ": " & getErrorString(es))
    c.subs.add(s)

  c.announce("reg.publish")
  echo c.name & " v" & c.version & " online on " & url &
       " (" & $c.tools.len & " tools)"

  # main loop: poll subscriptions, dispatch on the main thread
  while not gShutdown:
    var gotOne = false
    for s in c.subs:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, s, 50)
      if st == NATS_OK:
        gotOne = true
        c.handleMsg(msg)
    if not gotOne:
      sleep(10)

  # graceful: announce departure, finish, exit
  c.announce("reg.depart")
  sleep(200)
  for s in c.subs:
    natsSubscription_Destroy(s)
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
  for b in bindings:
    let name = ident(b.name)
    let extractCall =
      case $b.typ
      of "string":
        if b.hasDefault:
          newCall(ident("argStringD"), ident("args"), newLit(b.name), b.default)
        else:
          newCall(ident("argString"), ident("args"), newLit(b.name))
      of "int", "int8", "int16", "int32", "int64",
         "uint", "uint8", "uint16", "uint32", "uint64":
        if b.hasDefault:
          newCall(ident("argIntD"), ident("args"), newLit(b.name), b.default)
        else:
          newCall(ident("argInt"), ident("args"), newLit(b.name))
      of "float", "float32", "float64":
        if b.hasDefault:
          newCall(ident("argFloatD"), ident("args"), newLit(b.name), b.default)
        else:
          newCall(ident("argFloat"), ident("args"), newLit(b.name))
      of "bool":
        if b.hasDefault:
          newCall(ident("argBoolD"), ident("args"), newLit(b.name), b.default)
        else:
          newCall(ident("argBool"), ident("args"), newLit(b.name))
      of "JsonNode":
        newCall(ident("argJson"), ident("args"), newLit(b.name))
      else:
        if b.hasDefault:
          newCall(ident("argStrSeqD"), ident("args"), newLit(b.name), b.default)
        else:
          newCall(ident("argStrSeq"), ident("args"), newLit(b.name))
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
     newIdentDefs(ident("comp"), bindSym("Component")),
     newIdentDefs(ident("args"), bindSym("JsonNode"))],
    body,
    nnkProcDef)
  result = newStmtList(
    procDef,
    handler,
    nnkDiscardStmt.newTree(
      newCall(ident("registerTool"), c, newLit(procName),
              newLit($schema), handlerName)))
