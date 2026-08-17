## Envelope codec — Niffler wire protocol (docs/WIRE.md)
##
## Pure std/json so the SDK stays trivially portable; this is runtime data
## by design (schemas-as-runtime-data), not a typed seam.

import std/[json, os, times]

type
  EnvelopeKind* = enum
    ekCall = "call"
    ekResult = "result"
    ekEvent = "event"
    ekError = "error"

  Envelope* = object
    v*: int
    id*: string
    kind*: EnvelopeKind
    tool*: string
    args*: JsonNode     ## call/result only
    payload*: JsonNode  ## event only
    error*: JsonNode    ## error only: {"code": "...", "message": "..."}

var idCounter = 0

proc newId*(): string =
  ## Cheap unique id (pid + ns timestamp + counter; plenty for a bus id)
  inc idCounter
  result = $(epochTime() * 1_000_000_000).int64 & "-" & $getCurrentProcessId() & "-" & $idCounter

proc parseKind(s: string): EnvelopeKind =
  case s
  of "call": ekCall
  of "result": ekResult
  of "event": ekEvent
  else: ekError

proc toJson*(e: Envelope): JsonNode =
  result = %*{"v": e.v, "id": e.id, "kind": $e.kind}
  if e.tool.len > 0: result["tool"] = %e.tool
  if e.args != nil: result["args"] = e.args
  if e.payload != nil: result["payload"] = e.payload
  if e.error != nil: result["error"] = e.error

proc fromJson*(node: JsonNode): Envelope =
  result.v = node{"v"}.getInt(1)
  result.id = node{"id"}.getStr("")
  result.kind = parseKind(node{"kind"}.getStr("event"))
  result.tool = node{"tool"}.getStr("")
  result.args = node{"args"}
  result.payload = node{"payload"}
  result.error = node{"error"}

proc encode*(e: Envelope): string = $e.toJson()

proc decode*(data: string): Envelope =
  try:
    return data.parseJson().fromJson()
  except CatchableError:
    # Never crash the component on garbage; report it as an error envelope
    return Envelope(v: 1, id: newId(), kind: ekError,
                    error: %*{"code": "bad-envelope",
                              "message": data[0 ..< min(200, data.len)]})

proc errorEnvelope*(id, code, message: string): Envelope =
  Envelope(v: 1, id: id, kind: ekError, error: %*{"code": code, "message": message})

proc resultEnvelope*(id: string, value: JsonNode): Envelope =
  Envelope(v: 1, id: id, kind: ekResult, args: value)

proc callEnvelope*(tool: string, args: JsonNode): Envelope =
  Envelope(v: 1, id: newId(), kind: ekCall, tool: tool, args: args)
