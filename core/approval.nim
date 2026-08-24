## Approval interceptor — the human gate for x-harness.approval.
##
## Tools whose schema carries x-harness.approval: "always" (bash, builder,
## core.spawn/kill/remove) are held here until a human says yes:
## - terminal harness (tty): a y/N prompt on stdin with the call details
## - service mode (UIs): core publishes ev.approval.request {id, tool, args};
##   a UI shows a dialog and answers on ev.approval.reply {id, ok}
## If no human is reachable the call is DENIED — never silently approved.
## NIF_AUTO_APPROVE=1 bypasses the gate entirely (headless automation,
## explicit opt-in; see docs/MANUAL.md).

import std/[json, os, strutils, tables, times]
import natswrapper
import ../sdk/envelope
import catalog

type
  Approval* = ref object
    nc*: NatsConnection
    cat*: Catalog
    tty*: bool             ## terminal prompt instead of UI dialog
    replySub*: ptr natsSubscription  ## ev.approval.reply (id-matched)
    timeoutMs*: int        ## how long to wait for a UI answer
    session*: string       ## active conversation/context for the current call (set
                           ## around a turn; "" = direct harness call, not a session)


proc newApproval*(nc: NatsConnection, cat: Catalog, tty: bool,
                  timeoutMs = 300000): Approval =
  result = Approval(nc: nc, cat: cat, tty: tty, timeoutMs: timeoutMs)
  let st = natsConnection_SubscribeSync(addr result.replySub, nc.conn,
                                        "ev.approval.reply".cstring)
  if not checkStatus(st):
    raise newException(IOError,
      "subscribe ev.approval.reply: " & getErrorString(st))

proc describe(tool: string, args: JsonNode): string =
  ## One-line summary of what the human is approving.
  var a = $args
  if a.len > 400: a = a[0 .. 399] & "…"
  return tool & " " & a

proc askTty(tool: string, args: JsonNode): bool =
  echo ""
  echo "[approval] this tool call needs your ok:"
  echo "  " & describe(tool, args)
  stdout.write("Approve? [y/N] ")
  stdout.flushFile()
  try:
    result = stdin.readLine().strip().toLowerAscii() in ["y", "yes"]
  except EOFError:
    result = false   # stdin closed — deny

proc askUi(a: Approval, tool: string, args: JsonNode): bool =
  if not a.cat.components.hasKey("ui"):
    echo "core: approval required for " & tool &
         " but no UI is attached — denying"
    return false
  let id = newId()
  let req = Envelope(v: 1, id: newId(), kind: ekEvent,
                     payload: %*{"id": id, "tool": tool, "args": args,
                                 "sessionId": a.session})
  a.nc.publish("ev.approval.request", req.encode())
  echo "core: approval requested for " & tool & " (" & id & ") — waiting for the UI"
  let deadline = epochTime() + a.timeoutMs.float / 1000.0
  while epochTime() < deadline:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, a.replySub, 200)
    if st == NATS_OK:
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      var node: JsonNode
      try:
        node = data.parseJson()
      except CatchableError:
        continue
      let payload = node{"payload"}
      if payload{"id"}.getStr("") != id: continue
      let ok = payload{"ok"}.getBool(false)
      echo "core: approval " & (if ok: "GRANTED" else: "DENIED") & " for " & tool
      return ok
  echo "core: approval for " & tool & " timed out after " &
       $(a.timeoutMs div 1000) & "s — denying"
  return false

proc ask*(a: Approval, tool: string, args: JsonNode): bool =
  ## Returns true when the call may proceed.
  if getEnv("NIF_AUTO_APPROVE") == "1":
    return true
  # Route to the UI whenever an interactive client (web UI) is driving the
  # session, even if core's own stdin happens to be a tty (core spawned from
  # a terminal while the user interacts through the UI). Fall back to the
  # tty prompt only when core is on a terminal AND no UI is attached
  # (classic terminal-harness usage).
  if a.cat.clientCount() == 0 and a.tty:
    return askTty(tool, args)
  return askUi(a, tool, args)
