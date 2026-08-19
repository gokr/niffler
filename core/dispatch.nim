## Dispatch — route a tool call to its component over the bus.
##
## Core's own tools (spawn, catalog) are handled locally; everything else
## goes to svc.<component>.call as a request/reply call envelope.
## The approval interceptor (x-harness.approval, see approval.nim) gates
## both paths: core tools here, component tools below.

import std/[json, os, strutils, tables, times]
import natswrapper
import ../sdk/envelope
import approval
import catalog
import supervisor

type
  CoreTools* = object
    nc*: NatsConnection
    cat*: Catalog
    sup*: Supervisor
    approval*: Approval

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000): JsonNode

proc handleCoreTool*(ct: CoreTools, tool: string, args: JsonNode): JsonNode =
  # the self-extension tools change the harness itself — human gate first
  if tool in ["spawn", "kill", "remove"] and ct.approval != nil:
    if not ct.approval.ask(tool, args):
      return %*{"error": "approval denied for " & tool}
  case tool
  of "spawn":
    ## Register and start a built component binary; it announces itself on
    ## connect and the LLM sees its tools on the next request. Persisted
    ## via the store component so it survives restarts (persistence of shape).
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
    if args{"op"}.getStr("") == "list":
      return %*{"tools": ct.cat.allTools()}
    return %*{"error": "catalog op must be 'list'"}
  else:
    return %*{"error": "core has no tool '" & tool & "'"}

proc dispatchToolCall*(ct: CoreTools, tool: string, args: JsonNode,
                       defaultTimeoutMs: int = 120000): JsonNode =
  if tool in ["spawn", "catalog", "kill", "remove"]:
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

  let env = callEnvelope(tool, args)
  let data = env.encode()
  let subject = "svc." & comp & ".call"
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, ct.nc.conn, subject.cstring,
                                  data.cstring, data.len.cint,
                                  timeoutMs.int64 * 1_000_000)
  if st == NATS_TIMEOUT:
    raise newException(IOError,
      "tool '" & tool & "' timed out after " & $timeoutMs & "ms")
  if not checkStatus(st):
    raise newException(IOError, "dispatch " & tool & ": " & getErrorString(st))
  let resp = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  if resp.kind == ekError:
    raise newException(ValueError,
      resp.error{"message"}.getStr("component error"))
  return resp.args
