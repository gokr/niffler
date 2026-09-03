## Niffler component SDK (Nim)
##
## The core component surface lives here; companion modules keep concerns
## separable and core-importable:
##   sdk/envelope.nim     pure wire codec (imported by core directly)
##   sdk/subjects.nim     pure wire helpers: session subjects, bus discovery,
##                        root paths (imported by core directly)
##   sdk/procutil.nim     shell-out + output capping utilities (components)
## Ports in other languages (sdk/go, sdk/ts) mirror this surface 1:1 —
## the envelope (sdk/envelope.nim + docs/WIRE.md) is the artifact, SDKs follow.
##
## Surface:
##   let comp = newComponent("greet", "0.1.0")
##   comp.tool:
##     proc greet(name: string, count: int = 1): JsonNode =
##       ## Greet someone
##       ## - name: the name to greet
##       %*{"greeting": "Hello, " & name}
##   comp.tool(%*{"onDemand": true}):               # x-harness schema ext
##     proc discover(): JsonNode = newJArray()
##   comp.run()                     # register, serve calls, drain on signal
##   inside a handler: c.emit("ev.x", %*{}), c.request("llm-openai", "chat", ...)
##   result conventions: okResult(extra), errResult(msg, code, extra),
##   c.requestOk(...) raises on {"ok": false} replies; c.onDrain(h) cleanup;
##   shell-outs: runCmd/runArgv, output caps capBytes/capLines/tailBytes;
##   paths: rootDir()/rootVarDir(name).
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
import ../subjects
import procutil

export envelope
export subjects  # session subject builders (wire spec, docs/WIRE.md)
export procutil  # runCmd/runArgv/capBytes/capLines/tailBytes
export dotenv    # standalone clients (cli, console) import niffler/sdk only
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
    slashCommands*: seq[JsonNode]  ## declared slash command specs (docs/WIRE.md)
    eventHandlers*: seq[tuple[pattern: string, handler: EventHandler]]
    taps*: seq[tuple[pattern: string, handler: TapHandler]]
    drainHandlers: seq[DrainHandler]
    nc*: NatsConnection
    bindings: seq[SubscriptionBinding]
    shuttingDown*: bool

  DrainHandler* = proc(c: Component)
    ## Cleanup callback registered with onDrain; invoked (on the main
    ## thread, like every handler) when the component shuts down.

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

proc tool*(c: Component, name: string, schema: JsonNode,
           handler: ToolHandler, xharness: JsonNode = nil): Component =
  ## Low-level registration (the `comp.tool:` macro wraps this). xharness
  ## is the optional x-harness schema extension (docs/WIRE.md).
  var s = schema
  if xharness != nil:
    s = schema.copy()
    s["x-harness"] = xharness
  c.tools.add(Tool(name: name, schema: s, handler: handler))
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

proc slashCommand*(c: Component, name, description: string,
                   params: JsonNode = nil, tool = ""): Component =
  ## Declare a slash command interactive UIs expose to users (docs/WIRE.md).
  ## params is an array of {name, kind?, source?, description?, default?}
  ## (kind: string|bool|int|enum); tool defaults to name and must be a tool
  ## registered by this same component. Chainable like tool/on/tap.
  var cmd = %*{"name": name, "description": description}
  if tool.len > 0: cmd["tool"] = %tool
  if params != nil: cmd["params"] = params
  c.slashCommands.add(cmd)
  return c

proc tap*(c: Component, pattern: string, handler: TapHandler): Component =
  ## Raw wire tap (see TapHandler): receives full envelope bytes for every
  ## matching subject. Subscriptions join the same serialized pump loop.
  c.taps.add((pattern: pattern, handler: handler))
  return c

proc emit*(c: Component, subject: string, payload: JsonNode) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: payload)
  c.nc.publish(subject, env.encode())

# ---------------------------------------------------------------------------
# Result conventions — the {ok, error} shape of tool results.
#
# Tools that report success/failure inside the result JSON (rather than
# raising, which becomes a bus-level error envelope) use one canonical
# shape so the LLM and component callers never hand-roll it:
#   success → {"ok": true, ...extra}
#   failure → {"ok": false, "error": msg, "code": code?, ...extra}

proc mergeExtra(result: JsonNode, extra: JsonNode) =
  if extra != nil and extra.kind == JObject:
    for key, val in extra:
      result[key] = val

proc okResult*(extra: JsonNode = nil): JsonNode =
  ## Canonical success tool result: {"ok": true} merged with extra fields.
  result = %*{"ok": true}
  mergeExtra(result, extra)

proc errResult*(msg: string, code = "", extra: JsonNode = nil): JsonNode =
  ## Canonical failure tool result: {"ok": false, "error": msg}, plus the
  ## optional machine-readable code (e.g. "not-found", "rev-conflict")
  ## and extra fields.
  result = %*{"ok": false, "error": msg}
  if code.len > 0: result["code"] = %code
  mergeExtra(result, extra)

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

proc requestOk*(c: Component, componentName, toolName: string, args: JsonNode,
                timeoutMs: int = 5000): JsonNode =
  ## request() plus the {ok, error} result convention: raises when the
  ## reply carries ok:false (its "error" field becomes the message), so
  ## callers stop writing `if r{"ok"}.getBool()` chains. Replies without
  ## an "ok" field pass through unchanged.
  result = c.request(componentName, toolName, args, timeoutMs)
  if result.hasKey("ok") and not result{"ok"}.getBool(false):
    raise newException(IOError,
      result{"error"}.getStr("tool call failed"))

# --- config helpers ---------------------------------------------------------

proc configStr*(name: string, default = ""): string =
  ## Environment config with a default. Component configuration comes from
  ## the process env (docs/MANUAL.md); one helper per SDK keeps parsing
  ## uniform instead of every component hand-rolling getEnv + clamps.
  let v = getEnv(name)
  if v.len == 0: return default
  return v

proc configBool*(name: string, default = false): bool =
  ## Boolean env config: 1/true/yes/on (case-insensitive) read true,
  ## 0/false/no/off read false; anything else (including unset) reads as
  ## the default.
  case getEnv(name).toLowerAscii()
  of "1", "true", "yes", "on": return true
  of "0", "false", "no", "off": return false
  else: return default

proc configInt*(name: string, default, minimum, maximum: int): int =
  ## Integer env config. Unparsable or outside [minimum, maximum] raises
  ## ValueError — a misconfigured component should fail loudly at boot
  ## (the convention every component's local copy followed); unset reads
  ## as the default.
  let raw = getEnv(name, $default)
  try:
    result = raw.parseInt()
  except ValueError:
    raise newException(ValueError,
      name & " must be an integer, got '" & raw & "'")
  if result < minimum or result > maximum:
    raise newException(ValueError, name & " must be in " & $minimum & ".." &
      $maximum & ", got " & $result)

# --- store client -----------------------------------------------------------
#
# Typed access to the store component's document contract (put/get/list/del,
# docs/WIRE.md). One layer instead of per-component "store unreachable"
# boilerplate; error codes become first-class error types so call sites
# read as intent (fail closed vs best effort) rather than JSON poking.

type
  StoreConflictError* = object of CatchableError
    ## put with expectRev lost an optimistic-concurrency race.
  StoreNotFoundError* = object of CatchableError
    ## get target does not exist.
  StoreItem* = object
    id*: string
    rev*: int
    value*: JsonNode

proc storeErr(tool, kind, id: string, r: JsonNode) =
  ## Turn the store tool's {ok:false, code, ...} result into a typed error.
  ## An unreachable store arrives as an IOError from request() itself.
  let what = tool & " " & kind & ":" & id
  case r{"code"}.getStr("")
  of "rev-conflict":
    raise newException(StoreConflictError,
      what & ": revision conflict (current rev " &
      $r{"currentRev"}.getInt(-1) & ")")
  of "not-found":
    raise newException(StoreNotFoundError, what & ": not found")
  else:
    raise newException(IOError, what & ": " &
      r{"error"}.getStr("store call failed"))

proc storeCall(c: Component, tool, kind, id: string, args: JsonNode,
               timeoutMs: int): JsonNode =
  ## request() plus the store's ok-check with typed error mapping.
  result = c.request("store", tool, args, timeoutMs)
  if result.hasKey("ok") and not result{"ok"}.getBool(false):
    storeErr(tool, kind, id, result)

proc storePut*(c: Component, kind, id: string, value: JsonNode,
               expectRev = 0, timeoutMs = 5000): int =
  ## Upsert a document (kind/id) into the store, returning its new revision.
  ## expectRev > 0 → StoreConflictError when the current revision differs
  ## (optimistic concurrency); an unreachable store raises IOError.
  let r = storeCall(c, "put", kind, id, %*{"kind": kind, "id": id,
                    "value": value, "expectRev": expectRev}, timeoutMs)
  return r{"rev"}.getInt(-1)

proc storeGet*(c: Component, kind, id: string,
               timeoutMs = 5000): StoreItem =
  ## Fetch a document by kind and id; StoreNotFoundError when absent.
  let r = storeCall(c, "get", kind, id,
                    %*{"kind": kind, "id": id}, timeoutMs)
  result = StoreItem(id: id, rev: r{"rev"}.getInt(0), value: r{"value"})

proc storeList*(c: Component, kind: string, idPrefix = "", limit = 100,
                timeoutMs = 5000): seq[StoreItem] =
  ## List documents of a kind, ordered by id, optionally filtered by an id
  ## prefix. limit is capped by the store itself.
  let r = storeCall(c, "list", kind, idPrefix, %*{"kind": kind,
                    "idPrefix": idPrefix, "limit": limit}, timeoutMs)
  let items = r{"items"}
  if items != nil and items.kind == JArray:
    for item in items:
      result.add(StoreItem(id: item{"id"}.getStr(""),
                           rev: item{"rev"}.getInt(0),
                           value: item{"value"}))

proc storeDel*(c: Component, kind, id: string, timeoutMs = 5000) =
  ## Delete a document; idempotent (missing target is not an error).
  discard storeCall(c, "del", kind, id,
                    %*{"kind": kind, "id": id}, timeoutMs)

proc onDrain*(c: Component, handler: DrainHandler): Component =
  ## Register a cleanup callback (e.g. close a database) invoked when the
  ## component receives ev.sys.drain — its authorized orderly shutdown
  ## event. Chainable like tool/on/tap.
  c.drainHandlers.add(handler)
  return c

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

proc pumpTaps*(c: Component, maxMessages: int): int
  ## Drain queued tap subscriptions. Exported for components that block in
  ## a handler: a polling wait must keep its taps current, or replies that
  ## arrive during the block sit queued until it returns.

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
  if c.slashCommands.len > 0:
    result["slash"] = %c.slashCommands
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
      # bounded wait: a blocking NextMsg here would freeze a caller that
      # pumps taps from inside a handler (agent_wait) when the queue is
      # empty, and freeze requestEnvelope for tap-owning components
      let st = natsSubscription_NextMsg(addr msg, binding.sub, 25)
      if st != NATS_OK:
        break
      inc result
      c.handleMsg(binding, msg)
    if result >= maxMessages:
      break

proc drainHandler(c: Component, subject: string, payload: JsonNode) =
  for h in c.drainHandlers:
    try:
      h(c)
    except CatchableError as e:
      stderr.writeLine(c.name & ": drain handler failed: " & e.msg)
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
# An optional xharness argument carries the schema's x-harness
# extension (docs/WIRE.md) — no post-registration schema poking:
#
#   comp.tool(%*{"approval": "always", "timeoutMs": 60000}):
#     proc bash(command: string): JsonNode = ...
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

proc toolImpl(c, procDefArg, xharness: NimNode): NimNode =
  ## Shared body of the two `tool` macro overloads (block form and
  ## x-harness form). All nodes are untyped macro AST.
  var procDef = procDefArg
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
  var registerStmt: NimNode
  if xharness.kind == nnkNilLit:
    registerStmt = nnkDiscardStmt.newTree(
      newCall(ident("registerTool"), c, newLit(procName),
              newLit($schema), handlerName))
  else:
    # x-harness extension (docs/WIRE.md): evaluate the caller's JsonNode
    # expression at runtime and merge it into the schema before registering
    let schemaSym = genSym(nskLet, "toolSchema")
    registerStmt = newStmtList(
      newLetStmt(schemaSym, newCall(ident("parseJson"), newLit($schema))),
      newAssignment(
        nnkBracketExpr.newTree(schemaSym, newLit("x-harness")),
        xharness),
      nnkDiscardStmt.newTree(
        newCall(ident("registerTool"), c, newLit(procName),
                newCall(ident("$"), schemaSym), handlerName)))
  result = newStmtList(procDef, handler, registerStmt)

macro tool*(c: untyped, procDef: untyped): untyped =
  ## Register a tool from a proc definition (block form):
  ##   comp.tool:
  ##     proc greet(name: string): JsonNode = %*{"greeting": "Hi " & name}
  toolImpl(c, procDef, newNilLit())

macro tool*(c: untyped, xharness: untyped, procDef: untyped): untyped =
  ## Register a tool from a proc definition, with the schema's x-harness
  ## extension (docs/WIRE.md) given as a JsonNode expression:
  ##   comp.tool(%*{"approval": "always", "timeoutMs": 60000}):
  ##     proc bash(command: string): JsonNode = ...
  toolImpl(c, procDef, xharness)
