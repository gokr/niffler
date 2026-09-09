## Native guest API for Fabric. See components/fabric/docs/REFERENCE.md.
## No NATS connection or lease: the host mediates every proxied tool call.
## Native code is trusted, not sandboxed; direct OS effects are not mediated.

import std/[json, os, strutils, tables]
export json, strutils

type
  FabricCallError* = object of CatchableError
  FabricCall* = object
    tool*: string
    args*: JsonNode
  FabricOutcome* = object
    ok*: bool
    value*: JsonNode
    error*: string

const
  maxBatchCalls = 16
  maxStructuredBatchCalls = 1000
  maxBridgeBytes = 1_000_000 # same bound as host framing.nim
  maxBatchBytes = 8_000_000

var
  protocol: File
  initialized = false
  callCount = 0
  runtimeInputs: JsonNode

proc initBridge() =
  if initialized: return
  let fd = parseInt(getEnv("FABRIC_PROTOCOL_FD", "3"))
  if not open(protocol, FileHandle(fd), fmWrite):
    raise newException(IOError, "Fabric protocol descriptor is unavailable")
  runtimeInputs = parseJson(readFile(getEnv("FABRIC_INPUT_FILE")))
  initialized = true

proc emit(j: JsonNode) =
  initBridge()
  let data = $j
  if data.len > maxBridgeBytes:
    raise newException(FabricCallError, "Fabric frame exceeds byte budget")
  protocol.writeLine(data)
  protocol.flushFile()

proc nextResponse(): JsonNode =
  ## Bounded framing, including EOF in the middle of a frame.
  var line = ""
  while true:
    if stdin.endOfFile:
      raise newException(FabricCallError, "fabric parent closed the pipe")
    let ch = stdin.readChar()
    if ch == '\n': break
    if line.len >= maxBridgeBytes:
      raise newException(FabricCallError, "Fabric response exceeds byte budget")
    line.add(ch)
  result = parseJson(line)
  if result{"t"}.getStr("") != "resp":
    raise newException(FabricCallError, "expected Fabric response frame")

proc callTool*(tool: string, argsJson: string): string =
  ## Legacy serialized interface. Prefer call(tool, args).
  inc callCount
  let id = $callCount
  emit(%*{"t": "req", "id": id, "tool": tool, "argsJson": argsJson})
  let response = nextResponse()
  if response{"id"}.getStr("") != id:
    raise newException(FabricCallError, "unexpected Fabric response id")
  if not response{"ok"}.getBool(false):
    raise newException(FabricCallError,
      "tool '" & tool & "' failed: " & response{"error"}.getStr("call failed"))
  response{"result"}.getStr("")

proc call*(tool: string, args: JsonNode): JsonNode =
  ## Structured call. Tool failures raise; bash exit codes are normal results.
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "call args must be a JSON object")
  parseJson(callTool(tool, $args))

proc batch*(callsJson: string): string =
  ## Legacy: max 16 {tool,args} entries; successful result is serialized JSON.
  let calls = parseJson(callsJson)
  if calls.kind != JArray or calls.len > maxBatchCalls:
    raise newException(ValueError, "batch needs an array of at most 16 calls")
  # Validate all entries before any request can mutate the workspace.
  for item in calls:
    if item.kind != JObject or item{"tool"}.getStr("").len == 0 or
        item{"args"} == nil or item{"args"}.kind != JObject:
      raise newException(ValueError, "batch entries must be {tool, args: object}")
  var ids: seq[string]
  for item in calls:
    inc callCount
    let id = $callCount
    ids.add(id)
    emit(%*{"t": "req", "id": id, "tool": item{"tool"},
            "argsJson": $(item{"args"})})
  var answers = initTable[string, JsonNode]()
  while answers.len < ids.len:
    let frame = nextResponse()
    let id = frame{"id"}.getStr("")
    if id notin ids or answers.hasKey(id):
      raise newException(FabricCallError, "unexpected or duplicate response id")
    answers[id] = frame
  var outcomes = newJArray()
  for id in ids:
    let response = answers[id]
    if response{"ok"}.getBool(false):
      outcomes.add(%*{"ok": true, "result": response{"result"}.getStr("")})
    else:
      outcomes.add(%*{"ok": false, "error": response{"error"}.getStr("call failed")})
  $outcomes

proc toolCall*(tool: string, args: JsonNode): FabricCall =
  FabricCall(tool: tool, args: args)

proc batch*(calls: openArray[FabricCall]): seq[FabricOutcome] =
  ## Automatically chunk; preserve order and per-item failure. Not atomic.
  ## Reads may overlap; writes follow the host scheduler. Each item costs a call.
  if calls.len > maxStructuredBatchCalls:
    raise newException(ValueError, "batch exceeds 1000 calls")
  var inputBytes = 0
  for item in calls:
    if item.tool.len == 0 or item.args == nil or item.args.kind != JObject:
      raise newException(ValueError, "batch entries need a tool and object args")
    let frameBytes = ($(%*{"t": "req", "id": "1000000000",
      "tool": item.tool, "argsJson": $item.args})).len
    inputBytes += frameBytes
    if frameBytes > maxBridgeBytes or inputBytes > maxBatchBytes:
      raise newException(ValueError, "batch arguments exceed byte budget")
  var outputBytes = 0
  var start = 0
  while start < calls.len:
    var chunk = newJArray()
    let stop = min(start + maxBatchCalls, calls.len)
    for i in start ..< stop:
      chunk.add(%*{"tool": calls[i].tool, "args": calls[i].args})
    let response = batch($chunk)
    outputBytes += response.len
    if outputBytes > maxBatchBytes:
      raise newException(FabricCallError,
        "batch results exceed byte budget; earlier calls may have completed")
    for item in parseJson(response):
      if item{"ok"}.getBool(false):
        result.add(FabricOutcome(ok: true,
          value: parseJson(item{"result"}.getStr("null"))))
      else:
        result.add(FabricOutcome(ok: false, error: item{"error"}.getStr("call failed")))
    start = stop

proc finish*(valueJson: string) =
  ## Legacy terminal return. Native guest exits; code after finish cannot run.
  emit(%*{"t": "result", "ok": true, "value": valueJson})
  quit(0)

proc finish*(value: JsonNode) =
  ## Structured terminal return; only this value reaches conversation history.
  finish($value)

proc logg*(message: string) =
  emit(%*{"t": "log", "s": message})

proc log*(message: string) = logg(message)

proc inputs*(): JsonNode =
  initBridge()
  runtimeInputs

proc stringArg*(key: string): string = inputs(){key}.getStr("")

proc fabricMissingFinish*() =
  ## Called by the generated driver when guest top-level code returns normally.
  emit(%*{"t": "result", "ok": false, "phase": "execute",
          "diagnostics": "program finished without calling finish()"})

proc jesc*(s: string): string = $(%s)
proc jpair*(name: string, valueJson: string): string = jesc(name) & ":" & valueJson
proc jobj*(members: varargs[string]): string = "{" & members.join(",") & "}"
proc jarr*(items: varargs[string]): string = "[" & items.join(",") & "]"
proc jnum*(i: int): string = $i
proc jbool*(b: bool): string = (if b: "true" else: "false")
