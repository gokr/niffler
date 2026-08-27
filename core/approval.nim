## Approval interceptor — the human gate for x-harness.approval.
##
## Tools whose schema carries x-harness.approval: "always" (bash, builder,
## core.spawn/kill/remove) are held here until a human says yes:
## - terminal harness (tty): a y/N prompt on stdin with the call details
## - interactive clients: the request is routed to the component that drove
##   the current turn (svc.approval.<name>.request, derived from the call
##   envelope's self-declared caller — core never hardcodes component names).
##   The driver answers on ev.approval.reply: {id, ack: true} when it takes
##   responsibility (modal shown), then {id, ok} with the decision. When the
##   driver does not ack (crashed, or not interactive) the request is
##   rebroadcast on ev.approval.request {fallback: true} so any attached
##   interactive client can step in. Direct (non-session) calls broadcast
##   immediately; ev.approval.resolved {id, ok} tells every client the gate
##   outcome so stale modals can be dismissed.
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
    session*: string       ## active conversation for the current call (set
                           ## around a turn; "" = direct harness call)
    caller*: string        ## component name driving the current turn (set
                           ## around a turn; "" = unknown, direct call)
    checkAuto*: proc(session, tool: string): bool
      ## Persisted per-conversation auto-approve lookup (set by the harness
      ## after CoreTools exists; queries the store). When it returns true the
      ## gate grants without asking any client — no dialog flashes anywhere.


const ackTimeoutSecs = 1.5  ## how long the driver has to ack a directed request

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

proc askUi*(a: Approval, tool: string, args: JsonNode): bool =
  ## Interactive approval routing, no hardcoded component names:
  ## 1. turn driven by a known caller → private subject of that caller
  ##    (svc.approval.<caller>.request), ack-gated;
  ## 2. no ack within ackTimeoutSecs → broadcast fallback, any client;
  ## 3. no caller (direct call) → broadcast immediately, any client;
  ## 4. no interactive client reachable → DENY.
  let id = newId()
  var payload = %*{"id": id, "tool": tool, "args": args,
                   "sessionId": a.session}
  var directed = a.caller.len > 0
  if directed:
    payload["caller"] = %a.caller

  proc publishRequest(subject: string, announce: string) =
    let req = Envelope(v: 1, id: newId(), kind: ekEvent, payload: payload)
    a.nc.publish(subject, req.encode())
    echo announce

  proc publishResolved(ok: bool) =
    let env = Envelope(v: 1, id: newId(), kind: ekEvent,
                       payload: %*{"id": id, "ok": ok})
    a.nc.publish("ev.approval.resolved", env.encode())

  if directed:
    publishRequest("svc.approval." & a.caller & ".request",
      "core: approval requested for " & tool & " (" & id & ") from " & a.caller)
  else:
    if a.cat.clientCount() == 0:
      echo "core: approval required for " & tool &
           " but no interactive client is attached — denying"
      return false
    publishRequest("ev.approval.request",
      "core: approval requested for " & tool & " (" & id & ") — waiting for a UI")

  var acked = not directed
  let deadline = epochTime() + a.timeoutMs.float / 1000.0
  let ackDeadline = epochTime() + ackTimeoutSecs
  while epochTime() < deadline:
    if directed and not acked and epochTime() > ackDeadline:
      # The driver did not take the request (gone or not interactive):
      # offer it to every attached interactive client instead.
      if a.cat.clientCount() == 0:
        echo "core: approval for " & tool & " has no reachable client — denying"
        publishResolved(false)
        return false
      payload["fallback"] = %true
      publishRequest("ev.approval.request",
        "core: approval for " & tool & " (" & id & ") unanswered by " &
        a.caller & " — offered to all interactive clients")
      directed = false
      acked = true
      continue
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, a.replySub, 100)
    if st != NATS_OK:
      continue
    let data = $natsMsg_GetData(msg)
    natsMsg_Destroy(msg)
    var node: JsonNode
    try:
      node = data.parseJson()
    except CatchableError:
      continue
    let p = node{"payload"}
    if p{"id"}.getStr("") != id: continue
    if p{"ack"}.getBool(false):
      acked = true
      continue
    if p.hasKey("ok"):
      let ok = p{"ok"}.getBool(false)
      echo "core: approval " & (if ok: "GRANTED" else: "DENIED") & " for " & tool
      publishResolved(ok)
      return ok
  echo "core: approval for " & tool & " timed out after " &
       $(a.timeoutMs div 1000) & "s — denying"
  publishResolved(false)
  return false

proc ask*(a: Approval, tool: string, args: JsonNode): bool =
  ## Returns true when the call may proceed.
  if getEnv("NIF_AUTO_APPROVE") == "1":
    return true
  # Persisted per-conversation auto-approve (set by a client's "auto
  # approve" action): grant without asking any client, so no dialog is
  # shown at all — not even a flash.
  if a.checkAuto != nil and a.session.len > 0 and a.checkAuto(a.session, tool):
    return true
  # Fall back to the tty prompt only when core is on a terminal AND no
  # interactive client is attached (classic terminal-harness usage). The
  # tty fallback never applies to session turns — runners always have
  # tty = false and route through askUi.
  if a.cat.clientCount() == 0 and a.tty:
    return askTty(tool, args)
  return askUi(a, tool, args)
