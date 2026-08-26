## Dispatch — route a tool call to its component over the bus.
##
## Core's own tools (spawn, catalog, discover) are handled locally; everything else
## goes to svc.<component>.call as a request/reply call envelope.
## The approval interceptor (x-harness.approval, see approval.nim) gates
## both paths: core tools here, component tools below.

import std/[algorithm, json, os, osproc, strutils, tables, times]
import yaml/tojson
import natswrapper
import ../sdk/envelope
import approval
import catalog
import supervisor

type
  CoreTools* = object
    nc*: NatsConnection
    cat*: Catalog
    sup*: Supervisor                      ## nil in session runners (no children)
    root*: string                         ## harness root (var/, components/, sdk/)
    approval*: Approval
    coreSub*: ptr natsSubscription        ## svc.core.call (set by niffler.nim; nil in runners)
    pending*: PendingCalls                ## session calls stashed during a turn
    runner*: bool                         ## true in a session runner: core tools go over the bus
    # Streaming turn channel: while a session turn is running, runTurn installs
    # a subscription on ev.llm.token and dispatchToolCall pumps it during its
    # blocking wait so live deltas reach the UI without a second thread.
    # A ref so mutations survive CoreTools' by-value copies (constructed once
    # in niffler.nim or session.nim, shared everywhere).
    tokenStream*: TokenStream

  TokenStream* = ref object
    sub*: ptr natsSubscription
    session*: string                ## "" = not streaming a turn
    cb*: proc(sid, content, reasoning: string) {.closure.}

  PendingCalls* = ref object
    items*: seq[tuple[env: Envelope, reply: string]]

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000): JsonNode

proc invokeTool(ct: CoreTools, args: JsonNode,
                defaultTimeoutMs: int): JsonNode =
  let target = args{"tool"}.getStr("")
  let arguments = args{"arguments"}
  if target.len == 0 or arguments == nil or arguments.kind != JObject:
    raise newException(ValueError,
      "invoke needs tool and an arguments object")
  let schema = ct.cat.toolSchema(target)
  if target == "invoke" or schema == nil or schema.isHidden():
    raise newException(ValueError,
      "tool is not available through invoke")
  return ct.dispatchToolCall(target, arguments, defaultTimeoutMs)

proc handleCoreTool*(ct: CoreTools, tool: string, args: JsonNode): JsonNode =
  # the self-extension tools change the harness itself — human gate first
  if tool in ["spawn", "kill", "remove"] and ct.approval != nil:
    if not ct.approval.ask(tool, args):
      return %*{"error": "approval denied for " & tool}
  case tool
  of "spawn":
    ## Register and start a built component binary; it announces itself on
    ## connect and becomes available through discover/invoke. Persisted via
    ## the store component so it survives restarts (persistence of shape).
    let name = args{"name"}.getStr("")
    let binary = args{"binary"}.getStr("")
    if name.len == 0 or binary.len == 0:
      return %*{"error": "spawn needs name and binary"}
    let abs = if binary.startsWith("/"): binary else: ct.sup.root / binary
    if not fileExists(abs):
      return %*{"error": "binary not found: " & abs}
    discard ct.sup.addChild(name, abs)
    ct.sup.startChild(ct.sup.children[^1])
    try:
      discard ct.dispatchToolCall("put", %*{
        "kind": "component", "id": name,
        "value": %*{"name": name, "binary": abs,
                    "policy": "on-failure", "addedAt": epochTime()}})
    except CatchableError as e:
      echo "core: warning — component not persisted (store down?): " & e.msg
    return %*{"ok": true, "name": name}
  of "kill":
    ## Stop a running component: drain, then terminate. It stays persisted
    ## in the store and is restored on the next boot.
    let name = args{"name"}.getStr("")
    if name.len == 0:
      return %*{"error": "kill needs name"}
    if not ct.sup.removeChild(name):
      return %*{"error": "no such component: " & name}
    ct.cat.dropComponent(name)
    return %*{"ok": true, "name": name, "persisted": true}
  of "remove":
    ## Stop a component AND delete its persisted record, so it does not
    ## come back on the next boot.
    let name = args{"name"}.getStr("")
    if name.len == 0:
      return %*{"error": "remove needs name"}
    discard ct.sup.removeChild(name)
    ct.cat.dropComponent(name)
    try:
      discard ct.dispatchToolCall("del", %*{"kind": "component", "id": name})
    except CatchableError as e:
      echo "core: warning — component record not deleted (store down?): " & e.msg
    return %*{"ok": true, "name": name, "persisted": false}
  of "catalog":
    # A late-joining client seeds from this snapshot. Drain registrations that
    # arrived before its request so the snapshot cannot lag the live bus.
    ct.cat.pump()
    if args{"op"}.getStr("") == "list":
      return %*{"tools": ct.cat.promptTools()}
    if args{"op"}.getStr("") == "components":
      ## component→tools view for bus clients that missed the registrations
      ## (cli seeds its catalog from this)
      var comps = newJObject()
      for name in ct.cat.sortedComponentNames():
        let reg = ct.cat.components[name]
        var tools = newJArray()
        for t in reg.tools:
          tools.add(%t.name)
        comps[name] = tools
      return %*{"components": comps}
    if args{"op"}.getStr("") == "snapshot":
      ## Full registration view ({name, version, pid, tools with schemas}) —
      ## session runners (and any late-joining client) seed their catalog
      ## from this, then follow reg.> live from there. Plus per-component
      ## details for UIs: lang/src from the manifest, binary path + file
      ## size/mtime from disk, registeredAt for uptime.
      var langTable = newTable[string, JsonNode]()
      var binaryTable = newTable[string, string]()
      for c in ct.sup.children:
        binaryTable[c.name] = c.binary
      try:
        let mpath = ct.root / "manifest.yaml"
        if fileExists(mpath):
          let nodes = loadToJson(readFile(mpath))
          if nodes.len > 0:
            for c in nodes[0]{"components"}:
              let cn = c{"name"}.getStr("")
              if cn.len > 0: langTable[cn] = c
      except CatchableError:
        discard
      var comps = newJArray()
      for name in ct.cat.sortedComponentNames():
        let reg = ct.cat.components[name]
        if name == "core": continue  # seeded locally by every newCatalog
        var tools = newJArray()
        for t in reg.tools:
          tools.add(%*{"name": t.name, "schema": t.schema})
        var entry = %*{"name": name, "version": reg.version, "pid": reg.pid,
                       "tools": tools, "registeredAt": reg.registeredAt}
        let m = langTable.getOrDefault(name)
        if m != nil:
          if m{"build"}{"lang"}.getStr("").len > 0:
            entry["lang"] = %m{"build"}{"lang"}.getStr("")
          if m{"build"}{"src"}.getStr("").len > 0:
            entry["src"] = %m{"build"}{"src"}.getStr("")
        let binary = binaryTable.getOrDefault(name)
        if binary.len > 0:
          entry["binary"] = %binary
          try:
            entry["size"] = %getFileSize(binary)
            entry["mtime"] = %getLastModificationTime(binary).toUnixFloat()
          except CatchableError:
            discard
        comps.add(entry)
      return %*{"components": comps}
    return %*{"error": "catalog op must be 'list', 'components' or 'snapshot'"}
  of "discover":
    ct.cat.pump()
    return ct.cat.discover(args)
  of "status":
    ## Live components: supervised process state plus every current catalog
    ## registration (core and external clients included), cross-referenced
    ## with tool schemas and manifest build metadata.
    if ct.sup == nil:
      return %*{"error": "no supervisor here (session runner?)"}
    let now = epochTime()
    # manifest build metadata: name -> {lang, src} from manifest.yaml
    var langTable = newTable[string, JsonNode]()
    try:
      let mpath = ct.root / "manifest.yaml"
      if fileExists(mpath):
        let nodes = loadToJson(readFile(mpath))
        if nodes.len > 0:
          for c in nodes[0]{"components"}:
            let cn = c{"name"}.getStr("")
            if cn.len > 0: langTable[cn] = c
    except CatchableError:
      discard
    var childTable = initTable[string, Child]()
    var names: seq[string] = @[]
    for child in ct.sup.children:
      childTable[child.name] = child
      names.add(child.name)
    for name in ct.cat.components.keys:
      if name notin names:
        names.add(name)
    names.sort()

    var comps = newJArray()
    for name in names:
      let child = childTable.getOrDefault(name)
      let reg = ct.cat.components.getOrDefault(name)
      let supervised = child != nil
      let running = if name == "core": true
                    elif supervised: child.process != nil and child.process.running()
                    else: reg.pid > 0
      var tools = newJArray()
      for t in reg.tools:
        tools.add(%*{"name": t.name, "schema": t.schema})
      var entry = %*{
        "name": name,
        "version": reg.version,
        "running": running,
        "wanted": if supervised: child.wanted else: true,
        "policy": if supervised: $child.policy
                  elif name == "core": "core" else: "external",
        "restarts": if supervised: child.restarts else: 0,
        "pid": reg.pid,
        "registeredAt": reg.registeredAt,
        "tools": tools}
      var binary = ""
      if supervised:
        binary = child.binary
        entry["binary"] = %binary
      let m = langTable.getOrDefault(name)
      if m != nil:
        entry["lang"] = %m{"build"}{"lang"}.getStr("")
        entry["src"] = %m{"build"}{"src"}.getStr("")
      if binary.len > 0:
        try:
          entry["size"] = %getFileSize(binary)
          entry["mtime"] = %getLastModificationTime(binary).toUnixFloat()
        except CatchableError:
          discard
      comps.add(entry)
    return %*{"components": comps, "at": now}
  else:
    return %*{"error": "core has no tool '" & tool & "'"}

proc pumpCoreWhileBusy*(ct: CoreTools) =
  ## Serve core's own svc.core.call surface while a turn dispatch is
  ## blocked waiting for a component reply. Without this, a component
  ## calling back into core (plugin_install → core.spawn) would deadlock
  ## against the in-flight turn: core waits for the install, the install
  ## waits for core. Concurrent session requests are stashed — turns must
  ## never nest — and drained by pumpCoreCalls once the turn ends.
  if ct.coreSub == nil: return
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, ct.coreSub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekCall or reply.len == 0: continue
    if env.tool == "session":
      ct.pending.items.add((env: env, reply: reply))
      continue
    var resp: Envelope
    try:
      let r = if env.tool == "invoke":
                ct.dispatchToolCall(env.tool, env.args)
              else:
                ct.handleCoreTool(env.tool, env.args)
      if r{"error"} != nil:
        raise newException(ValueError, r{"error"}.getStr("core tool error"))
      resp = resultEnvelope(env.id, r)
    except CatchableError as e:
      resp = errorEnvelope(env.id, "boom", e.msg)
    ct.nc.publish(reply, resp.encode())

proc pumpTokenStream*(ct: CoreTools) =
  ## Drain ev.llm.token frames matching the active streaming turn and forward
  ## each parsed delta to the turn's callback. Called from the dispatch idle
  ## slot so a blocking turn call keeps the live token stream flowing.
  if ct.tokenStream == nil or ct.tokenStream.sub == nil: return
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, ct.tokenStream.sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekEvent or env.payload == nil: continue
    let p = env.payload
    if p{"sessionId"}.getStr("") != ct.tokenStream.session: continue
    if ct.tokenStream.cb != nil:
      ct.tokenStream.cb(p{"sessionId"}.getStr(""),
                        p{"content"}.getStr(""),
                        p{"reasoning"}.getStr(""))
proc dispatchSubjectCall*(ct: CoreTools, subject: string, tool: string,
                          args: JsonNode, timeoutMs: int, caller = ""): JsonNode =
  ## Request/reply to an explicit subject (svc.<comp>.call or a scoped
  ## session subject). While waiting for the reply, keep the service surface
  # alive: core's own tools (so a component calling back into core mid-turn
  # cannot deadlock), the catalog, the supervisor, the live token stream.
  let env = callEnvelope(tool, args, caller)
  let data = env.encode()
  let inbox = "_INBOX." & newId()
  var sub: ptr natsSubscription
  var st = natsConnection_SubscribeSync(addr sub, ct.nc.conn, inbox.cstring)
  if not checkStatus(st):
    raise newException(IOError, "subscribe inbox: " & getErrorString(st))
  defer: natsSubscription_Destroy(sub)
  st = natsConnection_PublishRequest(ct.nc.conn, subject.cstring,
                                     inbox.cstring, data.cstring,
                                     data.len.cint)
  if not checkStatus(st):
    raise newException(IOError, "publish request: " & getErrorString(st))
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    var msg: ptr natsMsg
    let ns = natsSubscription_NextMsg(addr msg, sub, 100)
    if ns == NATS_OK:
      let resp = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if resp.kind == ekError:
        raise newException(ValueError,
          resp.error{"message"}.getStr("component error"))
      return resp.args
    # idle slot: keep core responsive to its own tools, the catalog, and the
    # live LLM token stream (so streaming thinking reaches the UI while we wait)
    pumpCoreWhileBusy(ct)
    ct.cat.pump()
    if ct.sup != nil:
      ct.sup.pump(ct.cat)
    pumpTokenStream(ct)
  raise newException(IOError,
    "tool '" & tool & "' (" & subject & ") timed out after " &
    $timeoutMs & "ms")

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000): JsonNode =
  if tool == "invoke":
    return invokeTool(ct, args, defaultTimeoutMs)

  # Core tools: executed locally by the system harness; in a session runner
  # they are forwarded over the bus (svc.core.call) — one implementation.
  if tool in ["spawn", "catalog", "kill", "remove", "status", "discover"] and
      not ct.runner:
    let r = ct.handleCoreTool(tool, args)
    if r{"error"} != nil:
      raise newException(ValueError, r{"error"}.getStr("core tool error"))
    return r

  let comp = ct.cat.toolIndex.getOrDefault(tool)
  if comp.len == 0:
    raise newException(ValueError,
      "no component provides tool '" & tool & "' — is it registered?")

  let schema = ct.cat.toolSchema(tool)
  # approval gate: x-harness.approval == "always" needs a human (or NIF_AUTO_APPROVE)
  if schema != nil and schema{"x-harness"}{"approval"}.getStr("") == "always":
    if ct.approval == nil or not ct.approval.ask(tool, args):
      raise newException(ValueError, "approval denied for tool '" & tool & "'")

  # per-tool timeout from its schema (x-harness.timeoutMs)
  var timeoutMs = defaultTimeoutMs
  if schema != nil:
    timeoutMs = schema{"x-harness"}{"timeoutMs"}.getInt(timeoutMs)

  dispatchSubjectCall(ct, "svc." & comp & ".call", tool, args, timeoutMs)
