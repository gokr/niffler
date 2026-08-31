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

import std/[algorithm, json, os, posix, strutils, times]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
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

proc programDigest*(args: JsonNode): string =
  ## Identity of a program-shaped approval (any args carrying a string `code`):
  ## the digest covers the source plus every dimension the human approved —
  ## selected tools and the call budget — so a changed program or capability
  ## set is a different approval. Empty for ordinary (non-program) calls.
  if args == nil: return ""
  if args{"code"} == nil or args{"code"}.kind != JString: return ""
  var material = %*{"code": args{"code"}}
  let tools = args{"tools"}
  if tools != nil and tools.kind == JArray:
    var names: seq[string]
    for t in tools: names.add(t.getStr(""))
    names.sort()
    material["tools"] = %names
  if args{"maxCalls"} != nil and args{"maxCalls"}.kind != JNull:
    material["maxCalls"] = args{"maxCalls"}
  result = $secureHash(canonicalJson(material))

proc sourceArtifact*(digest, code: string): string =
  ## The full program source at a stable digest-keyed path (mode 0600), so
  ## the approver can read everything, not a prompt-truncated excerpt.
  let dir = getEnv("NIF_ROOT", ".") / "var" / "approval-sources"
  try:
    createDir(dir)
  except CatchableError: discard
  let path = dir / (digest & ".nim")
  if not fileExists(path):
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL,
                        Mode(0o600))
    if fd >= 0:
      var written = 0
      while written < code.len:
        let count = posix.write(fd, unsafeAddr code[written],
                                code.len - written)
        if count <= 0: break
        written += count
      discard posix.close(fd)
      if written < code.len:
        try: removeFile(path)
        except CatchableError: discard
  return path

proc approvalManifest*(args: JsonNode): JsonNode =
  ## Extra view data for program-shaped approvals (nil otherwise): digest,
  ## viewable full source, selected tools, and declared budgets.
  let digest = programDigest(args)
  if digest.len == 0: return nil
  let code = args{"code"}.getStr("")
  result = %*{"digest": digest}
  if code.len > 0:
    result["source"] = %sourceArtifact(digest, code)
  if args{"tools"} != nil: result["tools"] = args{"tools"}
  if args{"maxCalls"} != nil: result["maxCalls"] = args{"maxCalls"}
  if args{"timeoutMs"} != nil: result["timeoutMs"] = args{"timeoutMs"}

proc autoKey*(tool: string, args: JsonNode): string =
  ## Persisted auto-approval key: program-shaped calls are keyed by manifest
  ## digest, never by tool name alone (a blanket "always approve fabric"
  ## would approve arbitrary source).
  let digest = programDigest(args)
  if digest.len > 0: tool & ":" & digest else: tool

proc describeApproval(tool: string, args: JsonNode, manifest: JsonNode): string =
  ## What the human sees at a tty gate: the manifest for program approvals,
  ## the classic one-line summary otherwise.
  if manifest == nil: return describe(tool, args)
  result = "program " & manifest{"digest"}.getStr("")
  let tools = manifest{"tools"}
  if tools != nil and tools.kind == JArray and tools.len > 0:
    var names: seq[string]
    for t in tools: names.add(t.getStr(""))
    result.add("\n  selected tools: " & names.join(", "))
  if manifest{"maxCalls"} != nil:
    result.add("\n  maxCalls: " & $manifest{"maxCalls"}.getInt(0))
  if manifest{"timeoutMs"} != nil:
    result.add("\n  timeoutMs: " & $manifest{"timeoutMs"}.getInt(0))
  let source = manifest{"source"}.getStr("")
  if source.len > 0:
    result.add("\n  full source: " & source)
  let code = args{"code"}.getStr("")
  var head = code.split('\n')[0]
  if head.len > 120: head = head[0 ..< 120] & "…"
  result.add("\n  code begins: " & head)

proc askTty(tool: string, args: JsonNode): bool =
  echo ""
  echo "[approval] this tool call needs your ok:"
  echo "  " & describeApproval(tool, args, approvalManifest(args))
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
  let manifest = approvalManifest(args)
  if manifest != nil:
    payload["manifest"] = manifest
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
  # shown at all — not even a flash. Program-shaped calls are keyed by
  # manifest digest (autoKey), so a blanket tool-name record never covers
  # unreviewed source.
  if a.checkAuto != nil and a.session.len > 0:
    let key = autoKey(tool, args)
    if a.checkAuto(a.session, key):
      return true
  # Fall back to the tty prompt only when core is on a terminal AND no
  # interactive client is attached (classic terminal-harness usage). The
  # tty fallback never applies to session turns — runners always have
  # tty = false and route through askUi.
  if a.cat.clientCount() == 0 and a.tty:
    return askTty(tool, args)
  return askUi(a, tool, args)
