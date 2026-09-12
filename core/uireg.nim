## UI registry — numbered interactive clients with renewable leases.
##
## Interactive frontends (TUIs, web UIs) announce a client-supplied UUID and
## receive a display number ("Niffler 1", "Niffler 2", …) plus a lease they
## must renew. The lease is the liveness signal: a UI that stops renewing
## (crash, SIGSTOP, closed terminal) loses its claims after the lease
## expires; a graceful release drops them immediately.
##
## The registry also brokers conversation ownership: one live UI holds a
## conversation at a time, so a second TUI resuming the same conversation is
## told who owns it instead of silently joining the stream. This is
## coordination against accidental interference between cooperating UIs —
## not authentication (NATS caller names are self-declared; docs/WIRE.md)
## and not a security boundary.
##
## Served by the system core as the hidden core tool "ui"
## (op: register|renew|release|claim|release_session|owner). Expired
## entries are swept lazily on every registry decision — claims expire
## exactly when someone next asks, so no timer thread is needed. Numbers
## are monotonic per harness lifetime: a departed UI's number is not reused.

import std/[json, strutils, tables, times]

const defaultLeaseSecs* = 20.0

type
  UiInfo* = object
    id*: string          ## client-supplied UUID (e.g. "tui-1f3a9c02b7d4")
    number*: int         ## display number (1-based, monotonic)
    leaseUntil*: float   ## epoch seconds; expired = gone at next sweep

  UiRegistry* = ref object
    uis*: Table[string, UiInfo]
    claims*: Table[string, string]  ## sessionId -> owning uiId
    nextNumber*: int
    leaseSecs*: float               ## lease lifetime (tests use tiny values)

proc newUiRegistry*(leaseSecs: float = defaultLeaseSecs): UiRegistry =
  UiRegistry(uis: initTable[string, UiInfo](),
             claims: initTable[string, string](),
             nextNumber: 0, leaseSecs: leaseSecs)

proc sweep(r: UiRegistry, now: float) =
  ## Drop expired UIs and the conversations they owned.
  var dead: seq[string]
  for id, ui in r.uis:
    if ui.leaseUntil <= now: dead.add(id)
  for id in dead:
    r.uis.del(id)
    var stale: seq[string]
    for sid, owner in r.claims:
      if owner == id: stale.add(sid)
    for sid in stale: r.claims.del(sid)

proc ownerInfo(r: UiRegistry, sessionId: string,
               now: float): tuple[owned: bool, uiId: string, number: int] =
  ## The live owner of a conversation, if any (expired owners don't count).
  if r.claims.hasKey(sessionId):
    let owner = r.claims[sessionId]
    if r.uis.hasKey(owner) and r.uis[owner].leaseUntil > now:
      return (true, owner, r.uis[owner].number)
  return (false, "", 0)

proc handleUi*(r: UiRegistry, args: JsonNode): JsonNode =
  ## One registry operation. Every op sweeps first, so expiry is observed
  ## exactly when it matters and no background timer is required.
  let op = args{"op"}.getStr("")
  let id = args{"ui"}.getStr("").strip()
  let now = epochTime()
  r.sweep(now)
  case op
  of "register":
    if id.len == 0:
      return %*{"error": "ui register needs ui (a client UUID)"}
    if r.uis.hasKey(id):
      # Reconnect while the lease is still warm: keep identity and number.
      r.uis[id].leaseUntil = now + r.leaseSecs
      return %*{"ok": true, "number": r.uis[id].number,
                "leaseSecs": int(r.leaseSecs)}
    inc r.nextNumber
    r.uis[id] = UiInfo(id: id, number: r.nextNumber,
                       leaseUntil: now + r.leaseSecs)
    return %*{"ok": true, "number": r.nextNumber,
              "leaseSecs": int(r.leaseSecs)}
  of "renew":
    if id.len == 0 or not r.uis.hasKey(id):
      # Lease lost (expired while the client was frozen, core restart, …):
      # the client must re-register and re-claim.
      return %*{"ok": false}
    r.uis[id].leaseUntil = now + r.leaseSecs
    return %*{"ok": true, "leaseSecs": int(r.leaseSecs)}
  of "release":
    if r.uis.hasKey(id):
      r.uis.del(id)
      var stale: seq[string]
      for sid, owner in r.claims:
        if owner == id: stale.add(sid)
      for sid in stale: r.claims.del(sid)
    return %*{"ok": true}
  of "claim":
    let sessionId = args{"session"}.getStr("").strip()
    if id.len == 0 or sessionId.len == 0:
      return %*{"error": "ui claim needs ui and session"}
    if not r.uis.hasKey(id):
      return %*{"error": "ui claim needs a live lease (register first)"}
    let (owned, owner, number) = r.ownerInfo(sessionId, now)
    if owned and owner != id:
      return %*{"ok": false, "owner": owner, "number": number}
    r.claims[sessionId] = id
    return %*{"ok": true}
  of "release_session":
    let sessionId = args{"session"}.getStr("").strip()
    if r.claims.hasKey(sessionId) and r.claims[sessionId] == id:
      r.claims.del(sessionId)
    return %*{"ok": true}
  of "owner":
    let sessionId = args{"session"}.getStr("").strip()
    let (owned, owner, number) = r.ownerInfo(sessionId, now)
    if owned:
      return %*{"owned": true, "owner": owner, "number": number}
    return %*{"owned": false}
  else:
    return %*{"error": "ui op must be register|renew|release|claim|" &
                       "release_session|owner"}
