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
import natsnim
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
    approvalMode*: string
      ## The conversation's gate mode, set around a turn (like session/
      ## caller): "" or "ask" = gate every x-harness.approval tool, "auto" =
      ## this conversation auto-grants them. Chosen by the human through the
      ## session control op, never by the model.
    onIdle*: proc() {.closure.}
      ## Optional idle hook, called on every wait-loop iteration while a
      ## human verdict is pending. The harness wires it to its own pump set
      ## (core's svc.core.call surface, a runner's busy/cancel surfaces) so
      ## waiting for a human never stalls the rest of the system: without
      ## it, a session call arriving during an approval wait went unanswered
      ## (not even a "busy" refusal) and a stop/cancel control queued
      ## unread until the approval timed out.
    cancelled*: proc(): bool {.closure.}
      ## Optional cancel predicate (a session runner wires it to the steer
      ## stream's cancelRequested flag): when it turns true, the wait aborts
      ## as a denial so the turn can end as cancelled instead of waiting out
      ## the whole approval timeout.
    waiting*: bool
      ## Re-entrancy guard: the idle hook can service nested calls (a core
      ## pump answers svc.core.call, a runner pump answers nested/advise
      ## surfaces), and a nested approval question must not open a second
      ## blocking wait inside the first — the human can only answer one
      ## modal at a time anyway. Nested asks are denied immediately; the
      ## model retries the tool next round against a free gate.


const ackTimeoutSecs = 1.5  ## how long the driver has to ack a directed request
const continueTimeoutMs = 120_000
  ## how long a turn-limit question ("keep going?") waits for its human

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

proc askHuman*(a: Approval, payload: JsonNode, timeoutMs: int): bool =
  ## Put one question to a human over the approval transport and wait for the
  ## verdict. Routing, no hardcoded component names:
  ## 1. turn driven by a known caller → private subject of that caller
  ##    (svc.approval.<caller>.request), ack-gated;
  ## 2. no ack within ackTimeoutSecs → broadcast fallback, any client;
  ## 3. no caller (direct call) → broadcast immediately, any client;
  ## 4. no interactive client reachable → DENY.
  ## `payload` carries id/tool/args (plus optional manifest/purpose/
  ## dimension) and is completed in place with the caller when routing there:
  ## JsonNode is a ref, so a parameter (not a var parameter) is both mutable
  ## here and visible to the caller — and only a ref can be captured by the
  ## publish closures below (a `var JsonNode` cannot be, by memory-safety).
  let id = payload{"id"}.getStr("")
  let tool = payload{"tool"}.getStr("")
  if a.waiting:
    # A nested approval question (see Approval.waiting): deny immediately,
    # before publishing anything — the human can only answer one modal at a
    # time, and blocking inside the outer wait's idle hook would deadlock
    # the outer wait itself. The model retries the tool next round against
    # a free gate.
    echo "core: approval for " & tool & " nested inside a pending " &
         "approval — denying (retry the tool when the gate is free)"
    return false
  a.waiting = true
  defer: a.waiting = false
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
      echo "core: " & tool & " needs a human" &
           " but no interactive client is attached — denying"
      return false
    publishRequest("ev.approval.request",
      "core: approval requested for " & tool & " (" & id & ") — waiting for a UI")

  var acked = not directed
  let deadline = epochTime() + timeoutMs.float / 1000.0
  let ackDeadline = epochTime() + ackTimeoutSecs
  while epochTime() < deadline:
    if a.onIdle != nil: a.onIdle()
    if a.cancelled != nil and a.cancelled():
      echo "core: approval for " & tool & " cancelled by request — denying"
      publishResolved(false)
      return false
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
       $(timeoutMs div 1000) & "s — denying"
  publishResolved(false)
  return false

proc askUi*(a: Approval, tool: string, args: JsonNode): bool =
  ## The gate's interactive question (see askHuman for routing).
  var payload = %*{"id": newId(), "tool": tool, "args": args,
                   "sessionId": a.session}
  let manifest = approvalManifest(args)
  if manifest != nil:
    payload["manifest"] = manifest
  askHuman(a, payload, a.timeoutMs)

proc askContinue*(a: Approval, dimension, detail: string): bool =
  ## A turn hit a human-set budget (rounds/tokens/seconds, see /limit): ask
  ## whether it may keep going, over the same transport, on the same routing.
  ## Denied, unanswered or unreachable → false, and the turn ends as budget
  ## exhausted exactly as it would have without the question. Job-scoped
  ## budgets (subagent scoping) never reach here — see runTurn.
  if getEnv("NIF_AUTO_APPROVE") == "1" or getEnv("NIF_AUTO_CONTINUE") == "1":
    return true
  var payload = %*{"id": newId(), "tool": "turn-limit",
                   "purpose": "continue", "sessionId": a.session,
                   "args": %*{"dimension": dimension, "detail": detail}}
  askHuman(a, payload, continueTimeoutMs)

proc ask*(a: Approval, tool: string, args: JsonNode): bool =
  ## Returns true when the call may proceed.
  if getEnv("NIF_AUTO_APPROVE") == "1":
    return true
  # The conversation's own mode (/approvals auto): the human opted this
  # conversation out of the gate. Grant loudly — a silent grant is what the
  # gate exists to prevent.
  if a.approvalMode == "auto":
    echo "core: approval auto-granted for " & tool &
         " (this conversation is in approval mode: auto)"
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
