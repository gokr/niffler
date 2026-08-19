## Conversation loop — the only "product logic" in core.
##
## The loop runs here (not in clients) so approvals, persistence and catalog
## freshness stay in one place. Two drivers:
## - stdin (interactive mode): runConversation
## - svc.core.call "session" tool (service mode): runTurn per request,
##   emitting ev.session.* events for UIs to render live
##
## Conversations and messages persist via the store component (document
## store over the bus); persistence failures degrade gracefully.

import std/[json, os, strutils, tables, times]
when defined(posix):
  import std/posix
import natswrapper
import ../sdk/envelope
import catalog
import dispatch
import supervisor

const systemPromptFmt = """
You are Niffler, a minimal self-extending agent harness.
Use your tools to get things done — read each tool's description before
calling it, and call the catalog tool to list everything available. Prefer
an existing tool (bash usually suffices) over building a new one.
You can add capabilities at runtime:
1. write a component source file — Nim: `import niffler/sdk` and use the
   typed tool pattern:

   let comp = newComponent("greet", "0.1.0")
   comp.tool:
     proc greet(name: string): JsonNode =
       ## Greet someone
       ## - name: the name to greet
       %*{"greeting": "Hello, " & name}
   comp.run()

   Go: package main importing `niffler.dev/sdk`, same surface (Tool/On/Emit/Run)
2. call builder.build {lang, name, source} to compile it (builder.info
   explains the pattern)
3. call core.spawn {name, binary} to start it
4. the new tool appears in your toolset on the next request
To stop a tool again: core.kill {name} (temporary; restored on boot) or
core.remove {name} (forgotten permanently).
Conversations and messages persist automatically via the store.

Your home is $# — the git repo Niffler runs from. Shipped component
sources: components/ (manifest.yaml lists the boot set), SDK: sdk/ +
sdk/go (builder.info has exact paths), design docs: docs/, build front
door: Makefile (make build / make test / make help). var/ is disposable
runtime state (binaries, barrel-db, agent builds) — gitignored; the repo
is the snapshot and `--recover` rebuilds it.

Be concise.
"""

proc systemPrompt(root: string): string =
  result = systemPromptFmt % [root]

proc formatToolsForLlm(tools: JsonNode): JsonNode =
  result = newJArray()
  for t in tools:
    # the catalog already normalized schemas at registration
    let schema = t{"schema"}
    result.add(%*{
      "type": "function",
      "function": {
        "name": t{"name"},
        "description": schema{"description"}.getStr(t{"name"}.getStr()),
        "parameters": schema
      }
    })

type
  Persister* = object
    ct: CoreTools
    convId*: string
    seqNo*: int
    failing: bool

  Session* = object
    messages*: seq[JsonNode]
    persister*: Persister

proc newPersister*(ct: CoreTools): Persister =
  ## Create a conversation header in the store and a persister for it.
  result = Persister(ct: ct, convId: "conv-" & newId())
  try:
    discard ct.dispatchToolCall("put", %*{
      "kind": "conversation", "id": result.convId,
      "value": %*{"createdAt": epochTime(),
                  "model": getEnv("NIF_OPENAI_MODEL", ""), "title": ""}})
  except CatchableError:
    discard

proc persistMsg*(p: var Persister, value: JsonNode) =
  ## Persist one message; warn once on failure and once on recovery.
  ## Ids are zero-padded so store key order == message order.
  inc p.seqNo
  value["conversationId"] = %p.convId
  try:
    discard p.ct.dispatchToolCall("put", %*{
      "kind": "message",
      "id": p.convId & ":" & align($p.seqNo, 6, '0'),
      "value": value})
    if p.failing:
      p.failing = false
      echo "core: store reachable again — persistence resumed"
  except CatchableError as e:
    if not p.failing:
      p.failing = true
      echo "core: WARNING persistence down (messages not saved): " & e.msg

proc loadStoredMessages*(ct: CoreTools, convId: string): seq[JsonNode] =
  ## Rebuild a conversation's message list from the store (resume).
  result = @[]
  try:
    let resp = ct.dispatchToolCall("list", %*{
      "kind": "message", "idPrefix": convId & ":"})
    for item in resp{"items"}:
      let v = item{"value"}
      var msg = newJObject()
      msg["role"] = v{"role"}
      msg["content"] = v{"content"}
      for field in ["tool_call_id", "name", "tool_calls"]:
        if v{field} != nil:
          msg[field] = v{field}
      result.add(msg)
  except CatchableError:
    discard

proc runTurn*(ct: CoreTools, p: var Persister, messages: var seq[JsonNode],
              onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil): string =
  ## One user turn: chat → dispatch tool calls → append results.
  ## Returns the final assistant text. onEvent receives
  ## ("assistant", {sessionId, content}), ("toolcall", {sessionId, tool, args,
  ## result|error}), ("done", {sessionId, reply}) as they happen.
  let sessionId = p.convId
  var rounds = 0
  while rounds < 20:
    rounds += 1
    # rebuild the tool list from the live catalog (self-extension!)
    let llmArgs = %*{"messages": messages,
                     "tools": ct.cat.allTools().formatToolsForLlm()}
    var resp: JsonNode
    try:
      resp = ct.dispatchToolCall("chat", llmArgs, 300000)
    except CatchableError as e:
      let msg = "llm error: " & e.msg
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "error": msg})
      return msg
    ct.cat.pump()
    ct.sup.pump(ct.cat)

    let content = resp{"content"}.getStr("")
    # Model + token usage surfaced by the llm component (informational).
    let usedModel = resp{"model"}.getStr("")
    let ctxSize = resp{"context"}.getInt(0)
    let usage = resp{"usage"}
    var usageObj = newJObject()
    if usage != nil:
      for k in ["prompt_tokens", "completion_tokens", "total_tokens"]:
        if usage{k} != nil:
          usageObj[k] = usage{k}
    if content.len > 0:
      let assistantMsg = %*{"role": "assistant", "content": content}
      if usedModel.len > 0: assistantMsg["model"] = %usedModel
      if ctxSize > 0: assistantMsg["context"] = %ctxSize
      if usageObj.len > 0: assistantMsg["usage"] = usageObj
      messages.add(assistantMsg)
      p.persistMsg(assistantMsg)
      if onEvent != nil:
        var ev = %*{"sessionId": sessionId, "content": content}
        if usedModel.len > 0: ev["model"] = %usedModel
        if ctxSize > 0: ev["context"] = %ctxSize
        if usageObj.len > 0: ev["usage"] = usageObj
        onEvent("assistant", ev)

    let toolCalls = resp{"tool_calls"}
    if toolCalls == nil or toolCalls.kind != JArray or toolCalls.len == 0:
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "reply": content})
      return content

    let tcMsg = %*{"role": "assistant", "content": nil, "tool_calls": toolCalls}
    messages.add(tcMsg)
    p.persistMsg(tcMsg)
    for tc in toolCalls:
      let id = tc{"id"}.getStr("")
      let name = tc{"function"}{"name"}.getStr("")
      var args = newJObject()
      try:
        args = parseJson(tc{"function"}{"arguments"}.getStr("{}"))
      except CatchableError:
        discard
      try:
        let toolResult = ct.dispatchToolCall(name, args)
        ct.cat.pump()
        ct.sup.pump(ct.cat)
        let toolMsg = %*{"role": "tool", "tool_call_id": id,
                         "name": name, "content": $toolResult}
        messages.add(toolMsg)
        p.persistMsg(toolMsg)
        if onEvent != nil:
          onEvent("toolcall", %*{"sessionId": sessionId, "tool": name,
                                 "args": args, "result": toolResult})
      except CatchableError as e:
        let toolMsg = %*{"role": "tool", "tool_call_id": id,
                         "name": name, "content": "ERROR: " & e.msg}
        messages.add(toolMsg)
        p.persistMsg(toolMsg)
        if onEvent != nil:
          onEvent("toolcall", %*{"sessionId": sessionId, "tool": name,
                                 "args": args, "error": e.msg})

proc runConversation*(ct: CoreTools, pump: proc() = nil) =
  ## Interactive stdin loop (headless demo mode). While waiting for input,
  ## the loop keeps serving svc.core.call (via `pump`) so UIs stay responsive.
  var messages = @[%*{"role": "system", "content": systemPrompt(ct.sup.root)}]
  var p = newPersister(ct)
  echo ""
  echo "Niffler — ready. Type a message (exit to quit)."
  while true:
    stdout.write("> ")
    stdout.flushFile()
    var line = ""
    when defined(posix):
      # poll stdin with a short timeout; pump the bus while we wait
      while true:
        if pump != nil: pump()
        var fds = [Tpollfd(fd: 0, events: POLLIN, revents: 0)]
        let r = poll(addr fds[0], 1, 25)
        if r > 0 and (fds[0].revents and POLLIN) != 0:
          break
        if r < 0:
          return
      line = stdin.readLine()
    else:
      line = stdin.readLine()
    if line.len == 0 or line in ["exit", "quit"]: break
    if pump != nil: pump()
    let userMsg = %*{"role": "user", "content": line}
    messages.add(userMsg)
    p.persistMsg(userMsg)
    proc onEvent(kind: string, data: JsonNode) {.closure.} =
      case kind
      of "assistant":
        echo ""
        echo data{"content"}.getStr("")
      of "toolcall":
        echo ""
        echo "  ↳ " & data{"tool"}.getStr("") & " " & $data{"args"}
      else:
        discard
    discard runTurn(ct, p, messages, onEvent)

# ---------------------------------------------------------------------------
# Session service — core as a component for UIs (svc.core.call, tool "session")
# ---------------------------------------------------------------------------

proc handleSessionCall*(ct: CoreTools, args: JsonNode,
                        sessions: var Table[string, Session]): JsonNode =
  ## session {sessionId, content}: run one turn, emitting ev.session.* events.
  ## Session state is rebuilt from the store on first use (resume).
  let sessionId = args{"sessionId"}.getStr("")
  let content = args{"content"}.getStr("")
  if sessionId.len == 0 or content.len == 0:
    return %*{"error": "session needs sessionId and content"}

  var entry: Session
  if sessions.hasKey(sessionId):
    entry = sessions[sessionId]
  else:
    entry.messages = @[%*{"role": "system", "content": systemPrompt(ct.sup.root)}]
    let stored = loadStoredMessages(ct, sessionId)
    if stored.len == 0:
      # brand new session: create the conversation header
      try:
        discard ct.dispatchToolCall("put", %*{
          "kind": "conversation", "id": sessionId,
          "value": %*{"createdAt": epochTime(),
                      "model": getEnv("NIF_OPENAI_MODEL", ""), "title": ""}})
      except CatchableError:
        discard
    for m in stored:
      entry.messages.add(m)
    entry.persister = Persister(ct: ct, convId: sessionId, seqNo: stored.len)

  let userMsg = %*{"role": "user", "content": content}
  entry.messages.add(userMsg)
  entry.persister.persistMsg(userMsg)

  proc onEvent(kind: string, data: JsonNode) {.closure.} =
    let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: data)
    ct.nc.publish("ev.session." & kind, env.encode())

  let reply = runTurn(ct, entry.persister, entry.messages, onEvent)
  sessions[sessionId] = entry
  return %*{"ok": true, "sessionId": sessionId, "reply": reply}

proc pumpCoreCalls*(ct: CoreTools, sub: ptr natsSubscription,
                    sessions: var Table[string, Session]) =
  ## Serve pending svc.core.call messages (session/spawn/catalog).
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekCall or reply.len == 0: continue
    var resp: Envelope
    try:
      case env.tool
      of "session":
        let r = handleSessionCall(ct, env.args, sessions)
        if r{"error"} != nil:
          raise newException(ValueError, r{"error"}.getStr("session error"))
        resp = resultEnvelope(env.id, r)
      of "spawn", "catalog", "kill", "remove":
        let r = ct.handleCoreTool(env.tool, env.args)
        if r{"error"} != nil:
          raise newException(ValueError, r{"error"}.getStr("core tool error"))
        resp = resultEnvelope(env.id, r)
      else:
        resp = errorEnvelope(env.id, "no-tool",
          "core has no tool '" & env.tool & "'")
    except CatchableError as e:
      resp = errorEnvelope(env.id, "boom", e.msg)
    ct.nc.publish(reply, resp.encode())
