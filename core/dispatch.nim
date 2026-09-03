## Dispatch — route a tool call to its component over the bus.
##
## Core's own tools (spawn, catalog, discover) are handled locally; everything else
## goes to svc.<component>.call as a request/reply call envelope.
## The approval interceptor (x-harness.approval, see approval.nim) gates
## both paths: core tools here, component tools below.

import std/[algorithm, json, monotimes, os, osproc, strutils, tables, times]
import yaml/tojson
import natswrapper
import ../sdk/envelope
import approval
import catalog
import schema_validation
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
    steerStream*: SteerStream          ## steering queue (see SteerStream below)
    adviseStream*: AdviseStream        ## turn-bound advisory queue (runners only)
    activeTurn*: ActiveTurn            ## live turn identity (set by runTurn)
    nested*: NestedState               ## nested-call proxy (session runners only)
    prepareSession*: proc(sessionId: string): JsonNode {.closure.}
      ## Delegated child-runner preparation (set by the system harness after
      ## CoreTools exists): ensure a conversation header + session runner and
      ## return {subject}. Serves the "session_prepare" core tool so a
      ## component (agent) can drive a subagent mid-turn — core's session
      ## tool would stash the request while a turn runs (pumpCoreWhileBusy:
      ## "turns must never nest") and deadlock the caller.
  TokenStream* = ref object
    sub*: ptr natsSubscription
    session*: string                ## "" = not streaming a turn
    cb*: proc(sid, content, reasoning: string) {.closure.}

  # Steering channel: a sync subscription on svc.session.<id>.steer that
  # pumpSteer drains during dispatch's idle slot, appending each injected
  # user message to queue for runTurn to consume between LLM rounds (Pi-style
  # steering: you can type while the agent works and it is folded into the
  # running turn instead of starting a new one). A ref, like tokenStream, so
  # mutations survive CoreTools' by-value copies.
  SteerStream* = ref object
    sub*: ptr natsSubscription
    queue*: seq[string]      # injected user messages (drained by runTurn)
    cancelRequested*: bool   # a __cancel control message arrived (agent_stop)
    cancelAt*: float         # when it arrived (stale cancels self-expire)
  # Turn-bound advisory channel (svc.session.<id>.advise): the expert peer's
  # request/reply surface. pumpAdvise answers each request immediately —
  # accepted only while the named turn is still live — and queues accepted
  # payloads for runTurn to fold in as distinctly marked user messages.
  # A ref, like steerStream, so runTurn's state survives by-value copies.
  AdviseStream* = ref object
    sub*: ptr natsSubscription
    queue*: seq[JsonNode]    # accepted advisory payloads (drained by runTurn)
    lastContent*: string     # naive dedupe: reject an exact repeat
  # Identity of the turn currently running in this process, maintained by
  # runTurn so pumpAdvise can bind advice to it (stale-turn rejection).
  ActiveTurn* = ref object
    session*: string         ## active conversation ("" = no live turn)
    id*: string              ## turnId of the live turn
    advisories*: int         ## accepted advisor messages this turn
  # Nested-call proxy state (svc.session.<id>.tool): session-context tools
  # (fabric, agent) receive {session, lease} in args; the runner's pump
  # validates nested calls against the live lease before re-entering the one
  # dispatch gate. A ref, like tokenStream, so runTurn's set survives
  # CoreTools' by-value copies. Nil in the system core (turns run in runners).
  NestedState* = ref object
    sub*: ptr natsSubscription
    session*: string         ## active conversation ("" = no live turn)
    lease*: string           ## current lease; "" = no session-context call in flight
    deadline*: MonoTime      ## monotonic limit for the current lease
    hasDeadline*: bool
  PendingCalls* = ref object
    items*: seq[tuple[env: Envelope, reply: string]]

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000,
                       deadlineMs: int = 0): JsonNode

proc dispatchSubjectCall*(ct: CoreTools, subject: string, tool: string,
                         args: JsonNode, timeoutMs: int, caller = ""): JsonNode

# --- store helpers ----------------------------------------------------------
# Typed access to the store component for core, mirroring sdk.nim's
# storeclient. Core deliberately imports only the pure SDK modules
# (envelope/subjects — never the Component machinery), so this lives here
# and speaks the store's subject directly: no tool routing, which also
# makes it safe to call from inside dispatchToolCall's own path (the spawn
# depth guard). Semantics: not-found reads as nil/empty; refusals and an
# unreachable store raise.

proc storeGetItem*(ct: CoreTools, kind, id: string,
                   timeoutMs = 5000): tuple[value: JsonNode, rev: int] =
  ## Fetch a document from the store; (nil, 0) when not-found. An
  ## unreachable store (or any refusal other than not-found) raises.
  let r = dispatchSubjectCall(ct, "svc.store.call", "get",
                              %*{"kind": kind, "id": id}, timeoutMs)
  if r{"ok"}.getBool(false):
    return (r{"value"}, r{"rev"}.getInt(0))
  if r{"code"}.getStr("") != "not-found":
    raise newException(IOError, r{"error"}.getStr("store get failed"))

proc storePutRev*(ct: CoreTools, kind, id: string, value: JsonNode,
                  expectRev = 0, timeoutMs = 5000): int =
  ## Upsert a document into the store; returns the new revision. Refusals
  ## (rev-conflict) and outages raise — callers that tolerate a lost race
  ## catch CatchableError, same split as the SDK storeclient.
  let r = dispatchSubjectCall(ct, "svc.store.call", "put",
    %*{"kind": kind, "id": id, "value": value, "expectRev": expectRev},
    timeoutMs)
  if not r{"ok"}.getBool(false):
    raise newException(IOError, r{"error"}.getStr("store put failed"))
  return r{"rev"}.getInt(0)

proc storeListItems*(ct: CoreTools, kind: string, idPrefix = "",
                     limit = 100, timeoutMs = 5000): seq[JsonNode] =
  ## List documents of a kind in id order, returning the raw items
  ## ({id, rev, value}); empty when none. An unreachable store raises.
  let r = dispatchSubjectCall(ct, "svc.store.call", "list",
    %*{"kind": kind, "idPrefix": idPrefix, "limit": limit}, timeoutMs)
  if not r{"ok"}.getBool(false):
    raise newException(IOError, r{"error"}.getStr("store list failed"))
  let items = r{"items"}
  if items != nil and items.kind == JArray:
    for item in items:
      result.add(item)

proc storeDel*(ct: CoreTools, kind, id: string, timeoutMs = 5000) =
  ## Delete a document; idempotent.
  discard dispatchSubjectCall(ct, "svc.store.call", "del",
                              %*{"kind": kind, "id": id}, timeoutMs)

proc invokeTool(ct: CoreTools, args: JsonNode,
                defaultTimeoutMs: int): JsonNode =
  let target = args{"tool"}.getStr("")
  let arguments = args{"arguments"}
  if target.len == 0 or arguments == nil or arguments.kind != JObject:
    raise newException(ValueError,
      "invoke needs tool and an arguments object")
  var name = target
  if ct.cat.toolSchema(name) == nil and name.contains('.'):
    # tolerate "component.tool" spellings (the LLM writes them naturally);
    # the tool namespace is flat, bare names are canonical
    name = name.split('.')[^1]
  let schema = ct.cat.toolSchema(name)
  # deliberately name-free: the error must be identical for unknown and
  # hidden tools, or invoke becomes an existence oracle (tests/t_discover.nim)
  if name == "invoke" or schema == nil or schema.isHidden():
    raise newException(ValueError,
      "tool is not available through invoke — discover lists the exact names")
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
      discard ct.storePutRev("component", name,
        %*{"name": name, "binary": abs,
           "policy": "on-failure", "addedAt": epochTime()})
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
      ct.storeDel("component", name)
    except CatchableError as e:
      echo "core: warning — component record not deleted (store down?): " & e.msg
    return %*{"ok": true, "name": name, "persisted": false}
  of "session_prepare":
    ## Delegated child-runner preparation for components (agent): returns the
    ## runner's direct subject WITHOUT running a turn — the session tool would
    ## be stashed mid-turn (pumpCoreWhileBusy) and deadlock the caller.
    if ct.prepareSession == nil:
      return %*{"error": "session_prepare is not available in this context"}
    return ct.prepareSession(args{"sessionId"}.getStr(""))
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
    if args{"op"}.getStr("") == "schemas":
      return ct.cat.selectedSchemas(args{"tools"})
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
        # The interactive-client flag must survive snapshot reseeding: a child
        # session runner (subagent) routes its fallback approvals through
        # clientCount() — a dropped flag makes every approval there deny.
        if reg.client:
          entry["client"] = %true
        if reg.slash.len > 0:
          entry["slash"] = slashList(reg)
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
    return %*{"error":
      "catalog op must be 'list', 'components', 'snapshot' or 'schemas'"}
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
  of "session_info":
    ## Read-only conversation introspection for the LLM: the current session
    ## (its runner injects the session id when the arg is absent — see
    ## dispatchToolCall) or any other stored conversation. Header fields come
    ## from the conversation doc (kept fresh by the turn loop), message counts
    ## from the persisted transcript.
    let sessionId = args{"sessionId"}.getStr("").strip()
    if sessionId.len == 0:
      return %*{"error": "session_info needs sessionId (a session runner injects its own id for the current session)"}
    var info = %*{"sessionId": sessionId}
    try:
      let header = ct.storeGetItem("conversation", sessionId)
      if header.value == nil:
        return %*{"error": "no conversation '" & sessionId & "'"}
      for f in ["title", "createdAt", "model", "modelOverride", "provider",
                "thinkingEffort", "context", "contextUsed", "promptTokens"]:
        if header.value{f} != nil:
          info[f] = header.value{f}
      # subagent lineage (the agent component records kind sessionmeta)
      let meta = ct.storeGetItem("sessionmeta", sessionId)
      if meta.value != nil and meta.value{"parent"} != nil:
        info["parent"] = meta.value{"parent"}
      # role counts from the message log (zero-padded ids → store key order
      # = message order). The store caps a list at 1000 items; flag the cut.
      var byRole = newJObject()
      var total = 0
      for item in ct.storeListItems("message", sessionId & ":", 1000):
        inc total
        let role = item{"value"}{"role"}.getStr("")
        let key = if role.len > 0: role else: "unknown"
        byRole[key] = %(byRole{key}.getInt(0) + 1)
      info["messageCount"] = %total
      info["messagesByRole"] = byRole
      if total >= 1000:
        info["truncated"] = %true
    except CatchableError as e:
      info["warning"] = %("store unavailable: " & e.msg)
    return info
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

proc pumpSteer*(ct: CoreTools) =
  ## Drain svc.session.<id>.steer messages and enqueue each injected user
  ## message for runTurn to fold into the running turn. Steer is fire-and-forget
  ## from the client, so there is no reply; the queue is drained by runTurn at
  ## the top of every LLM round and again before it would emit "done" (giving a
  ## queued steer the chance to keep the agent working — the Pi pattern).
  ## A payload carrying __cancel: true is a CONTROL message (agent_stop's
  ## turn abort), not user content: it raises the cancel flag runTurn checks
  ## between rounds instead of being folded into the conversation.
  if ct.steerStream == nil or ct.steerStream.sub == nil: return
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, ct.steerStream.sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekEvent or env.payload == nil: continue
    if env.payload{"__cancel"}.getBool(false):
      ct.steerStream.cancelRequested = true
      ct.steerStream.cancelAt = epochTime()
      continue
    let content = env.payload{"content"}.getStr("")
    if content.len > 0:
      ct.steerStream.queue.add(content)

proc pumpAdvise*(ct: CoreTools) =
  ## Drain svc.session.<id>.advise — turn-bound advisory requests from the
  ## expert peer. Each request is answered immediately: accepted only while
  ## the named turn is still active (one advisory per turn, no exact repeat),
  ## otherwise rejected with a stable reason. Fire-and-forget steer is for
  ## user type-ahead; autonomous advice must not leak into a later turn, so
  ## this surface is request/reply and fail-closed. Also serviced while the
  ## runner's main loop is idle (session.nim), so a late advise gets a
  ## rejection reply instead of sitting queued for the next turn.
  if ct.adviseStream == nil or ct.adviseStream.sub == nil: return
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, ct.adviseStream.sub, 1)
    if st != NATS_OK: break  # timeout or error: nothing (more) to do now
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    if reply.len == 0: continue
    var env: Envelope
    try:
      env = decode(data)
    except CatchableError:
      let resp = errorEnvelope(newId(), "bad-envelope",
        "expected a call envelope on the advise subject")
      ct.nc.publish(reply, resp.encode())
      continue
    let p = env.args
    let sessionId = p{"sessionId"}.getStr("")
    let turnId = p{"turnId"}.getStr("")
    let content = p{"content"}.getStr("")
    var reason = ""
    var accepted = false
    if env.kind != ekCall or env.tool != "advise":
      reason = "bad-envelope"
    elif ct.activeTurn == nil or ct.activeTurn.session.len == 0:
      reason = "no-active-turn"
    elif sessionId.len == 0 or sessionId != ct.activeTurn.session:
      reason = "wrong-session"
    elif turnId.len == 0 or turnId != ct.activeTurn.id:
      reason = "stale-turn"
    elif content.len == 0:
      reason = "empty"
    elif content == ct.adviseStream.lastContent:
      reason = "duplicate"
    elif ct.activeTurn.advisories >= 1:
      reason = "advisory-limit"
    else:
      accepted = true
      ct.activeTurn.advisories += 1
      ct.adviseStream.lastContent = content
      ct.adviseStream.queue.add(p)
    try:
      let resp = resultEnvelope(env.id,
        %*{"accepted": accepted, "reason": reason})
      ct.nc.publish(reply, resp.encode())
    except CatchableError as e:
      stderr.writeLine("core: advise reply publish failed: " & e.msg)

proc handleNestedCall(ct: CoreTools, env: Envelope): Envelope =
  ## Admission + dispatch for one nested tool call from a session-context
  ## program (arrives on svc.session.<id>.tool, pumped from the idle slot).
  ## Every check here fails closed: no live turn, no matching lease, hidden
  ## or internal target, or a missing required argument — all denied before
  ## dispatchToolCall re-enters the single gate (approval, timeout).
  if env.kind != ekCall:
    return errorEnvelope(env.id, "no-call", "expected a call envelope")
  if env.args == nil or env.args.kind != JObject:
    return errorEnvelope(env.id, "bad-args", "tool arguments must be an object")
  # lease: the in-flight session-context tool owns the proxy; a request
  # without the live lease (stale, guessed, or no turn running) is denied.
  if ct.nested == nil or ct.nested.session.len == 0 or ct.nested.lease.len == 0:
    return errorEnvelope(env.id, "no-session",
      "nested calls are only valid while a session-context tool is running")
  let lease = env.args{"__session"}{"lease"}.getStr("")
  if lease.len == 0 or lease != ct.nested.lease:
    return errorEnvelope(env.id, "bad-lease", "stale or unknown nested-call lease")
  let tool = env.tool
  # internal and recursive surfaces are never reachable from a program:
  # chat/session are core wiring, invoke would bypass admission, and
  # fabric-in-fabric would recurse through the proxy.
  if tool in ["fabric", "agent", "chat", "session", "invoke", "session_prepare"]:
    return errorEnvelope(env.id, "denied",
      "tool '" & tool & "' is not reachable through nested calls")
  let comp = ct.cat.toolIndex.getOrDefault(tool)
  if comp.len == 0:
    return errorEnvelope(env.id, "no-tool",
      "no component provides tool '" & tool & "' — is it registered?")
  let schema = ct.cat.toolSchema(tool)
  if schema != nil and schema.isHidden():
    return errorEnvelope(env.id, "denied",
      "tool '" & tool & "' is hidden and not reachable through nested calls")
  let expected = env.args{"__session"}{"catalog"}
  if expected != nil:
    let reg = ct.cat.components[comp]
    if expected{"component"}.getStr("") != comp or
        expected{"version"}.getStr("") != reg.version or
        expected{"fingerprint"}.getStr("") != schemaFingerprint(schema):
      return errorEnvelope(env.id, "catalog-changed",
        "tool '" & tool & "' changed after the Fabric schema snapshot")
  # __session is private proxy context. Validate it above, then remove it from
  # the copy that reaches approval, session events, and the target component.
  let cleanArgs = env.args.copy()
  let requestedMs = cleanArgs{"__session"}{"remainingMs"}.getInt(0)
  cleanArgs.delete("__session")
  let invalid = validateToolArgs(schema, cleanArgs)
  if invalid.len > 0:
    return errorEnvelope(env.id, "bad-args", invalid)
  if not ct.nested.hasDeadline:
    return errorEnvelope(env.id, "expired", "nested-call deadline is unavailable")
  let outerMs = (ct.nested.deadline - getMonoTime()).inMilliseconds.int
  let remainingMs = if requestedMs > 0: min(outerMs, requestedMs)
                    else: outerMs
  if remainingMs <= 0:
    return errorEnvelope(env.id, "expired", "nested-call deadline expired")
  try:
    result = resultEnvelope(env.id,
      ct.dispatchToolCall(tool, cleanArgs, deadlineMs = remainingMs))
  except CatchableError as e:
    result = errorEnvelope(env.id, "boom", e.msg)

proc pumpNested*(ct: CoreTools) =
  ## Drain svc.session.<id>.tool — nested calls from a running session-context
  ## program — and answer each through the normal dispatch gate. Called from
  ## dispatchSubjectCall's idle slot, like pumpSteer: the runner is blocked
  ## waiting for the fabric/agent reply and keeps its service surfaces alive.
  if ct.nested == nil or ct.nested.sub == nil: return
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, ct.nested.sub, 1)
    if st != NATS_OK: break  # timeout or error: nothing (more) to do now
    let data = $natsMsg_GetData(msg)
    let hasReply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    if hasReply.len == 0: continue
    let env = decode(data)
    let resp = handleNestedCall(ct, env)
    ct.nc.publish(hasReply, resp.encode())

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
    pumpSteer(ct)
    pumpAdvise(ct)
    pumpNested(ct)
  raise newException(IOError,
    "tool '" & tool & "' (" & subject & ") timed out after " &
    $timeoutMs & "ms")

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000,
                       deadlineMs: int = 0): JsonNode =
  if tool == "invoke":
    return invokeTool(ct, args, defaultTimeoutMs)

  # session_info with no sessionId means "my own conversation": while a turn
  # is live (ct.nested.session is set only inside runTurn) the runner injects
  # its own session id before the call reaches the system, so the model's
  # introspection always answers about the conversation it is running in.
  # Direct (non-session) callers have no live nested session and get the
  # tool's clear "needs sessionId" error instead.
  if tool == "session_info" and ct.nested != nil and
      ct.nested.session.len > 0 and args{"sessionId"}.getStr("").len == 0:
    args["sessionId"] = %ct.nested.session

  # Core tools: executed locally by the system harness; in a session runner
  # they are forwarded over the bus (svc.core.call) — one implementation.
  if tool in ["spawn", "catalog", "kill", "remove", "status", "discover",
              "session_info"] and
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
  let callArgs = if args == nil: newJObject() else: args.copy()
  let hasDeadline = deadlineMs > 0
  let deadline = if hasDeadline:
                   getMonoTime() + initDuration(milliseconds = deadlineMs)
                 else: MonoTime()
  if hasDeadline and getMonoTime() >= deadline:
    raise newException(IOError, "tool '" & tool & "' deadline expired")
  # approval gate: x-harness.approval == "always" needs a human (or NIF_AUTO_APPROVE)
  if schema != nil and schema{"x-harness"}{"approval"}.getStr("") == "always":
    if ct.approval == nil or not ct.approval.ask(tool, callArgs):
      raise newException(ValueError, "approval denied for tool '" & tool & "'")
    if hasDeadline and getMonoTime() >= deadline:
      raise newException(IOError,
        "tool '" & tool & "' deadline expired while awaiting approval")

  # per-tool timeout from its schema (x-harness.timeoutMs)
  var timeoutMs = defaultTimeoutMs
  if schema != nil:
    timeoutMs = schema{"x-harness"}{"timeoutMs"}.getInt(timeoutMs)
  if hasDeadline:
    timeoutMs = min(timeoutMs,
      (deadline - getMonoTime()).inMilliseconds.int)
    if timeoutMs <= 0:
      raise newException(IOError, "tool '" & tool & "' deadline expired")

  # Session-context tools (fabric, agent): inject the calling session plus a
  # lease for the nested-call proxy. Nested session-context calls temporarily
  # replace the current lease and restore it on return, so an outer Fabric
  # program remains valid after a nested agent_run.
  if schema != nil and schema{"x-harness"}{"sessionContext"}.getBool(false):
    if ct.nested == nil or ct.nested.session.len == 0:
      raise newException(ValueError,
        "tool '" & tool & "' needs a live session (no conversation turn is running)")
    let previousLease = ct.nested.lease
    let previousDeadline = ct.nested.deadline
    let previousHasDeadline = ct.nested.hasDeadline
    ct.nested.lease = newId()
    ct.nested.deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    ct.nested.hasDeadline = true
    defer:
      ct.nested.lease = previousLease
      ct.nested.deadline = previousDeadline
      ct.nested.hasDeadline = previousHasDeadline
    # caller is private proxy context: the interactive component driving this
    # turn. Session-context components (agent) forward it to child runners so
    # approvals raised inside a subagent route to the original human's client.
    let turnCaller = if ct.approval != nil: ct.approval.caller else: ""
    callArgs["__session"] = %*{"session": ct.nested.session,
                                "lease": ct.nested.lease,
                                "remainingMs": timeoutMs,
                                "caller": turnCaller}
    # Depth guard at dispatch time (x-harness.noSpawn): a subagent — a session
    # with a parent record in the store — may not call spawn-class tools. The
    # check MUST live here, not in the component's handler: the handler blocks
    # its component's pump for the child's whole turn, so a request from that
    # child would queue behind it and circular-wait forever.
    if schema{"x-harness"}{"noSpawn"}.getBool(false):
      var hasParent = false
      try:
        hasParent = ct.storeGetItem("sessionmeta", ct.nested.session, 5_000)
          .value{"parent"}.getStr("").len > 0
      except CatchableError:
        # fail closed: a missing sessionmeta record arrives as a result
        # (not-found), so an exception here means the lineage store is
        # unreachable — spawning cannot be verified, so it is denied
        hasParent = true
      if hasParent:
        raise newException(ValueError,
          "subagents cannot spawn subagents (depth limit)")
    return dispatchSubjectCall(ct, "svc." & comp & ".call", tool,
                               callArgs, timeoutMs)

  dispatchSubjectCall(ct, "svc." & comp & ".call", tool, callArgs, timeoutMs)
