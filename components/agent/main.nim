## agent component — subagent sessions (docs/research/FABRIC.md).
##
## A subagent is a Niffler session like any other: its own runner process,
## resumed from the store, full toolset. This component is the thin surface
## the LLM drives:
##
## - agent_run: synchronous — prepare a child runner (session_prepare —
##   never core's session tool, which stashes mid-turn), record lineage,
##   run the child turn, return its final reply.
## - agent_spawn: background — same preparation, then the child turn is
##   published fire-and-forget with a reply inbox this component taps; the
##   handler returns {jobId, sessionId} immediately. The tap records the
##   terminal job state in the store (kind agentjob) and emits
##   ev.agent.done — so late status lookups and waits never miss it.
## - agent_status: non-blocking durable lookup.
## - agent_wait: poll the durable record until terminal (for workflows
##   that need the result; blocks this component's pump, like agent_run).
## - agent_stop: cancel a running job for real — publish llm.cancel.<child>
##   (aborts an in-flight streaming LLM request) and the runner's
##   svc.session.<child>.cancel channel (ends the turn between rounds).
##   The terminal record says "stopped" (the reply, if any, is kept).
## - agent_steer: fire-and-forget injection into a live child turn
##   (meaningful only for spawned jobs — agent_run blocks the caller).
##
## Restart recovery: non-terminal job records are reconciled lazily — on
## boot and on every status/wait — against the live catalog and the child
## transcript: a completed turn whose completion tap was missed synthesizes
## the terminal record from the transcript; a turn whose runner died is
## recorded as interrupted.
##
## Depth rule: a session spawned as a child (sessionmeta.parent set) cannot
## spawn children itself. Lineage persistence and reads fail closed. Child
## LLM failures are reported as failures; approvals inside a child route to
## the original interactive caller. Idle child runners retire themselves
## (NIF_RUNNER_IDLE_S) and re-ensure on demand.

import std/[json, monotimes, os, sequtils, sets, strutils, tables, times]
import natsnim
import niffler/sdk

let comp = newComponent("agent", "0.1.0")

const taskPreamble =
  "You are a subagent. Work autonomously on the task below using the " &
  "available tools. When done, report a concise final result — it is the " &
  "only thing the caller sees.\n" &
  "You are a delegated subagent: your approvals are answered by the human " &
  "driving the parent conversation, and your tool allowlist and budgets " &
  "were fixed when this child was started — they cannot be widened from " &
  "inside it. If a request is denied or a budget is exhausted, report the " &
  "limitation in your final reply instead of retrying the denied " &
  "operation.\n\nTask:\n"

proc sanitizeSessionId(s: string): string =
  ## Mirror of the runner's subject sanitization (core/conversation.nim):
  ## session ids become NATS subject tokens, keep alnum/-/_.
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '-')

# --- settlement notices -----------------------------------------------------­
# A background child that settles has to reach its PARENT CONVERSATION, not
# just the UI: ev.agent.done is an observe-only event, so without a notice the
# parent must burn a turn polling agent_status. Design:
# docs/research/SUBAGENTS-PLAN.md P0.1.
#
# A notice is a durable record first and a delivery second — the record is
# written before any delivery is attempted, so a parent that is down, retired
# or mid-turn still gets it. Delivery is two-lane by PARENT state:
#   * parent runner mid-turn -> the steer channel (immediate, folded in)
#   * otherwise              -> pending, drained by the parent's next turn
#
# The notice is a POINTER, not the reply. The full reply is already durable in
# the agentjob record (agent_status returns it), so the notice carries a
# bounded summary plus an explicitly named recourse — a model that does not
# know to make the second call will not make one.
const noticeSummaryBytes = 400
  ## Bounded head of the reply carried in the notice. The full text is one
  ## agent_status call away, so this is a pointer's excerpt, not the payload.

const noticeFullReplyIn = "agent_status"
  ## Named recourse. Present so the model learns there is more AND how to get
  ## it, from the notice alone.

var liveTurns = initHashSet[string]()
  ## Sessions whose runner has a turn in flight, maintained by the
  ## ev.session.turn tap below. This is the ONLY state that lets the steer
  ## lane deliver immediately; everything else is queued for the pull lane.
  ## Conservative by design: a stale entry (missed "done") means we publish
  ## into a runner that may not be draining — the notice then ALSO stays
  ## pending, and the parent's next turn delivers it. A stale ABSENCE only
  ## ever costs a deferred delivery, never a lost one.

proc replySummary(reply: string; replyBytes: int): string =
  ## Head/tail split for a reply over the cap (the tool-spill convention:
  ## bash/mcp/fetch all return "content over cap + how to read it"). A mid-
  ## truncation would hide the shape of a long structured reply.
  if reply.len <= noticeSummaryBytes:
    return reply
  let head = noticeSummaryBytes div 2
  let tail = noticeSummaryBytes - head
  let omitted = reply.len - noticeSummaryBytes
  result = reply[0 ..< head] & "\n...[" & $omitted & " bytes omitted]...\n" &
           reply[^tail .. ^1]

proc parentMidTurn(parent: string): bool =
  ## True when the parent's runner is holding a turn, so the steer lane can
  ## fold the notice in immediately. Fed by the ev.session.turn tap (core
  ## emits phase start/done for every turn), not by a catalog probe — the
  ## catalog has no turn state.
  parent in liveTurns

proc nextNoticeSeq(parent: string): int =
  ## Next zero-padded-free sequence for a parent's notices. Derived from the
  ## stored records (no counter to lose): store key order is id order, so the
  ## highest existing suffix + 1 is the next value.
  result = 0
  try:
    for item in comp.storeList("agentnotice", parent & ":", 1000, 10_000):
      let id = item.id
      let dot = id.rfind(':')
      if dot >= 0:
        try: result = max(result, parseInt(id[dot + 1 .. ^1]))
        except ValueError: discard
  except CatchableError:
    discard
  inc result

proc deliverNotice(notice: var JsonNode, immediate: bool) =
  ## Publish (steer lane) or leave pending (pull lane). Either way the record
  ## is already written; a failed publish degrades to the pull lane, which is
  ## why the publish is best-effort and never raises.
  if not immediate: return
  let parent = notice{"parent"}.getStr("")
  if parent.len == 0: return
  try:
    # Build the payload field by field: %* is a literal constructor, it does
    # not interpolate JsonNode values from scope. Only non-nil fields are
    # copied, so a replyless notice carries no empty `summary` key.
    var payload = newJObject()
    payload["kind"] = %"subagent-settled"
    payload["parent"] = %parent
    for f in ["jobId", "child", "status", "summary", "replyBytes",
              "fullReplyIn"]:
      if notice{f} != nil:
        payload[f] = notice{f}
    comp.emit("svc.session." & sanitizeSessionId(parent) & ".steer",
              %*{"notice": payload})
    notice["deliveredAt"] = %epochTime()
    notice["deliveredVia"] = %"wake"
  except CatchableError:
    discard  # stays pending; the next turn's drain delivers it

proc emitNotice(c: Component, jobId, parent, child, status,
                reply: string) =
  ## The single writer of a settlement notice.
  ##
  ## Best-effort by construction: a notice is a convenience for the parent,
  ## and a store failure must never turn a completed job into a failed call.
  ## The `agentjob` record remains the authority on the job's outcome.
  if parent.len == 0 or child.len == 0: return
  var notice = %*{
    "v": 1,
    "parent": parent,
    "jobId": jobId,
    "child": child,
    "status": status,
    "replyBytes": reply.len,
    "fullReplyIn": noticeFullReplyIn,
    "createdAt": epochTime()}
  if reply.len > 0:
    notice["summary"] = %replySummary(reply, reply.len)
  try:
    let seqNo = nextNoticeSeq(parent)
    let id = parent & ":" & align($seqNo, 6, '0')
    discard c.storePut("agentnotice", id, notice, timeoutMs = 10_000)
    deliverNotice(notice, parentMidTurn(parent))
    if notice{"deliveredAt"} != nil:
      discard c.storePut("agentnotice", id, notice, timeoutMs = 10_000)
  except CatchableError as e:
    stderr.writeLine(c.name & ": notice for " & jobId & " failed: " & e.msg)
  c.emit("ev.agent.notice", %*{"jobId": jobId, "parent": parent,
                                "child": child, "status": status})

proc publishCancel(c: Component, child: string) =
  ## Two-channel turn cancellation: the llm side-channel aborts an in-flight
  ## streaming request; a __cancel control message on the proven steer
  ## channel ends the turn between rounds (the runner's pumpSteer raises the
  ## flag runTurn checks before the next LLM round — riding the steer
  ## subscription rather than a dedicated one keeps the connection's pump
  ## surface unchanged).
  c.emit("llm.cancel." & sanitizeSessionId(child), %*{"sessionId": child})
  c.emit("svc.session." & sanitizeSessionId(child) & ".steer",
         %*{"__cancel": true})

# --- cancellation side-channel ----------------------------------------------
# The session runner publishes cancel.agent {sessionId, tool, ts} when the
# turn that issued an in-flight agent_run is stopped (core/dispatch.nim,
# docs/WIRE.md "Cancellation"): the caller stops waiting for the reply and
# asks the callee to abandon the work. agent_run blocks this component's
# pump for the child's whole turn, so the handler polls the subscription
# itself (the same pattern as bash). A fresh cancel for the parent session
# cancels the child turn (publishCancel) instead of leaving it running out
# its budget for a caller that is gone — this is what stops nested
# agent_run children when the fabric program that launched them is
# cancelled mid-run. Cancels for other sessions are stashed so a request
# that was queued behind this run is skipped, not started.
const cancelFreshSeconds = 30.0
var cancelSub: ptr natsSubscription
var cancelledSessions: seq[tuple[sessionId: string, at: float]]

proc drainCancels(mySession: string): bool =
  ## Poll the cancel.agent subscription (non-blocking). Returns true when a
  ## fresh cancel targets mySession — the caller cancels its child turn.
  if cancelSub == nil:
    let st = natsConnection_SubscribeSync(addr cancelSub, comp.nc.conn,
                                          "cancel.agent")
    if not checkStatus(st): return false
  var cancelled = false
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, cancelSub, 0)
    if not checkStatus(st): break  # NATS_TIMEOUT = drained
    var payload = newJObject()
    try:
      let env = decode($natsMsg_GetData(msg))
      if env.kind == ekEvent and env.payload != nil: payload = env.payload
    except CatchableError:
      discard
    natsMsg_Destroy(msg)
    let sid = payload{"sessionId"}.getStr("")
    let ts = payload{"ts"}.getFloat(0.0)
    if sid.len == 0 or epochTime() - ts > cancelFreshSeconds: continue
    if mySession.len > 0 and sid == mySession: cancelled = true
    else: cancelledSessions.add((sessionId: sid, at: ts))
  cancelledSessions.keepItIf(epochTime() - it.at <= cancelFreshSeconds)
  cancelled

proc wasCancelled(sessionId: string): bool =
  ## True when a fresh cancel for sessionId arrived while its agent_run was
  ## still queued behind another in-flight agent_run — the child must not
  ## be started for a turn that has stopped waiting. The matched entry is
  ## consumed: a later, genuinely new turn of the same session must not be
  ## skipped by the stale notice.
  cancelledSessions.keepItIf(epochTime() - it.at <= cancelFreshSeconds)
  for i in 0 ..< cancelledSessions.len:
    if cancelledSessions[i].sessionId == sessionId:
      cancelledSessions.delete(i)
      return true
  false

proc requestChildTurn(c: Component, subject: string, env: Envelope,
                      timeoutMs: int, parentSession, child: string): Envelope =
  ## Publish the child session call and poll for the reply while keeping the
  ## cancel.agent side-channel current: when the PARENT session's turn is
  ## stopped mid-run (agent_stop on the job, or the session/fabric turn this
  ## agent_run is part of), cancel the child once, then wait for its abort
  ## reply so the caller's record stays honest.
  let data = env.encode()
  let inbox = "_INBOX.agent." & newId()
  var subscription: ptr natsSubscription
  let subscribeStatus = natsConnection_SubscribeSync(addr subscription,
    c.nc.conn, inbox.cstring)
  if not checkStatus(subscribeStatus):
    raise newException(IOError,
      "subscribe child inbox: " & getErrorString(subscribeStatus))
  defer: natsSubscription_Destroy(subscription)
  let publishStatus = natsConnection_PublishRequest(c.nc.conn, subject.cstring,
    inbox.cstring, data.cstring, data.len.cint)
  if not checkStatus(publishStatus):
    raise newException(IOError,
      "publish child session call: " & getErrorString(publishStatus))
  let flushStatus = natsConnection_FlushTimeout(c.nc.conn,
    min(timeoutMs, 1000).int64)
  if not checkStatus(flushStatus):
    discard  # polling still converges; flush is only a liveness hint
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs.int64)
  var msg: ptr natsMsg
  var cancelArmed = false
  while true:
    # A handler may issue this request while the component's normal pump is
    # paused. Keep raw observation taps current without nesting calls/events.
    discard c.pumpTaps(100)
    # Re-entrant call serving (P2.6): while this synchronous agent_run waits
    # for its child, a DEEPER synchronous agent_run from that child (allowed
    # when NIF_AGENT_MAX_DEPTH > 1) arrives at this component and must be
    # served — otherwise it sits queued behind this very handler and the
    # stack circular-waits until timeout. Re-entrancy depth is bounded by
    # the same cap: each level blocks in its own requestChildTurn below.
    discard c.pumpCallsReentrant(4)
    let st = natsSubscription_NextMsg(addr msg, subscription, 25)
    if st == NATS_OK:
      break
    if st != NATS_TIMEOUT:
      raise newException(IOError,
        "child session call: " & getErrorString(st))
    if not cancelArmed and drainCancels(parentSession):
      cancelArmed = true
      publishCancel(c, child)
    if getMonoTime() >= deadline:
      raise newException(IOError,
        "subagent timed out after " & $timeoutMs & "ms")
  defer: natsMsg_Destroy(msg)
  result = decode($natsMsg_GetData(msg))
  if result.id != env.id:
    raise newException(IOError, "child session call: reply id mismatch")
  if result.kind notin {ekResult, ekError}:
    raise newException(IOError,
      "child session call: expected result or error envelope")

proc hasParent(sessionId: string): bool =
  ## True when the session was itself spawned as a subagent child. Raises
  ## when the lineage store is unreachable — callers must fail closed.
  ## A session with no lineage record (not-found) is a root session.
  try:
    return comp.storeGet("sessionmeta", sessionId, 10_000)
      .value{"parent"}.getStr("").len > 0
  except StoreNotFoundError:
    return false

# --- fork --------------------------------------------------------------------
# A fork is a BIRTH that inherits the CALLER's transcript: the child's message
# log is seeded with the parent's completed turns before its first request, so
# the model has READ the conversation instead of being told about it. Design:
# docs/research/SUBAGENTS-PLAN.md P1.4 (DSH-STEAL §3, with the toolset-snapshot
# correction).

proc parseForkSpec(toolArgs: JsonNode): tuple[ok: bool, error: string,
    mode: string, lastK: int, maxChars: int] =
  ## `fork: true | {"lastK": n} | {"maxChars": n}` — absent/nil means no fork.
  let f = toolArgs{"fork"}
  if f == nil or f.kind == JNull:
    return (true, "", "", 0, 0)
  if f.kind == JBool:
    if f.getBool(false):
      return (true, "", "all", 0, 0)
    return (true, "", "", 0, 0)   # fork: false = no fork
  if f.kind == JObject:
    let k = f{"lastK"}
    let c = f{"maxChars"}
    if k != nil and c != nil:
      return (false, "fork takes lastK OR maxChars, not both", "", 0, 0)
    if k != nil:
      let n = k.getInt(0)
      if n < 1:
        return (false, "fork.lastK must be >= 1", "", 0, 0)
      return (true, "", "lastK", n, 0)
    if c != nil:
      let n = c.getInt(0)
      if n < 1:
        return (false, "fork.maxChars must be >= 1", "", 0, 0)
      return (true, "", "maxChars", 0, n)
    return (false, "fork object takes lastK or maxChars", "", 0, 0)
  return (false, "fork must be true, {lastK: n} or {maxChars: n}", "", 0, 0)

type TurnBlock = tuple[start, stop: int]
  ## A half-open [start, stop) range of transcript indices forming one
  ## COMPLETED turn: it opens at a user message and closes at an assistant
  ## message with no tool_calls. A trailing assistant-with-tool_calls (or a
  ## dangling user message) never closes — the in-flight turn is excluded,
  ## so the child never resumes with a dangling tool_call_id.

proc balancedPrefixLen(msgs: seq[StoreItem]): int =
  ## The length of the longest TRANSCRIPT PREFIX that replays as a valid
  ## provider message list: every assistant tool_calls is answered by its
  ## tool records before anything else, and no tool record is orphaned.
  ## The seed is contiguous-from-0 (DSH-STEAL §3), so the FIRST invalid
  ## record ends the forkable range — a crash left a dangling turn in the
  ## middle, everything after it is unreachable without copying the
  ## dangling tool_calls. summary/error records are not replayed
  ## (loadStoredMessagesEx skips error; summaries are derivations) and are
  ## neutral to validity.
  result = 0
  var pending = 0   # unanswered tool_calls in the open provider prefix
  for i, item in msgs:
    let role = item.value{"role"}.getStr("")
    case role
    of "assistant":
      let tc = item.value{"tool_calls"}
      if tc != nil and tc.kind == JArray and tc.len > 0:
        inc pending, tc.len
      elif pending > 0:
        return i          # a closing assistant over unanswered tool_calls
    of "tool":
      if pending == 0:
        return i          # orphaned tool record — prefix ends before it
      dec pending
    of "user":
      if pending > 0:
        return i          # unanswered tool_calls before the next turn
    else:
      discard             # summary/error: not replayed, validity-neutral
    result = i + 1
  # a prefix that ends with unanswered tool_calls is itself unbalanced —
  # the dangling assistant must not be copied
  if pending > 0:
    var last = result
    for i in countdown(msgs.len - 1, 0):
      if msgs[i].value{"role"}.getStr("") == "assistant":
        last = i
        break
    return last

proc forkBlocks(msgs: seq[StoreItem]): seq[TurnBlock] =
  ## Completed-turn blocks within the BALANCED prefix (a steer folds extra
  ## user messages into the open block; the block closes only on an
  ## assistant message with no tool_calls).
  let limit = balancedPrefixLen(msgs)
  var cur = -1
  for i in 0 ..< limit:
    let role = msgs[i].value{"role"}.getStr("")
    case role
    of "user":
      if cur < 0: cur = i
    of "assistant":
      let tc = msgs[i].value{"tool_calls"}
      if (tc == nil or tc.kind != JArray or tc.len == 0) and cur >= 0:
        result.add((cur, i + 1))
        cur = -1
    else:
      discard  # tool/summary/error records belong to the open block

proc forkHistory(parent, child: string; mode: string, lastK,
                 maxChars: int): tuple[ok: bool, error: string,
                                       copied: int, uptoId: string] =
  ## Copy the caller's completed turns into the child's message log, under
  ## dense child-side ids, so its first request replays the inherited
  ## history plus the new task. OWNERSHIP EXCEPTION, deliberate and
  ## documented: `agent` writes `message` records here, which core otherwise
  ## owns. Safe because it is a one-time COPY written before the child's
  ## runner exists — no concurrent writer for that session id, no
  ## lost-update window — and the child's seqNo continues AFTER the copied
  ## ids (loadStoredMessagesEx derives it from the highest stored id).
  var msgs: seq[StoreItem]
  try:
    msgs = comp.storeListAll("message", parent & ":")
  except CatchableError as e:
    return (false, "cannot read this conversation's history (store " &
                   "unreachable): " & e.msg, 0, "")
  let blocks = forkBlocks(msgs)
  if blocks.len == 0:
    return (false, "nothing to fork: this conversation has no completed " &
                   "turn yet", 0, "")
  # Select blocks per the budget. The cut ALWAYS lands on block boundaries —
  # never mid-tool-round — and a selection that drops everything fails
  # closed rather than minting an empty child.
  var keep: seq[TurnBlock]
  case mode
  of "all": keep = blocks
  of "lastK":
    keep = blocks[^min(lastK, blocks.len) .. ^1]
  of "maxChars":
    var total = 0
    var i = blocks.len - 1
    while i >= 0:
      var blockChars = 0
      for j in blocks[i].start ..< blocks[i].stop:
        blockChars += ($msgs[j].value{"content"}).len
      if total + blockChars > maxChars: break
      total += blockChars
      dec i
    # blocks[i+1 .. ^1] fit; if even the last block did not, nothing fits
    if i + 1 > blocks.len - 1:
      return (false, "fork.maxChars " & $maxChars & " is smaller than the " &
                     "last completed turn — nothing fits", 0, "")
    keep = blocks[i + 1 .. ^1]
  else:
    return (false, "unknown fork mode", 0, "")
  # Write the selected records under the child id. Per-message `usage` is
  # dropped (the child's token accounting is its own; copying the parent's
  # meters would lie twice), `summary`/`error` roles are skipped (a summary
  # is a derivation of records also being copied; error records are the
  # parent's turn audit), and conversationId is rewritten. Everything else —
  # role, content, tool_calls/tool_call_id/name, createdAt — is preserved so
  # the replay is byte-faithful where it matters.
  var seqNo = 0
  var upto = ""
  for b in keep:
    for j in b.start ..< b.stop:
      let src = msgs[j].value
      let role = src{"role"}.getStr("")
      if role in ["summary", "error"]: continue
      inc seqNo
      var rec = src.copy()
      # json.delete raises KeyError ("key not in object") on an absent key —
      # user/tool messages carry no usage at all
      if rec.hasKey("usage"):
        rec.delete("usage")
      rec["conversationId"] = %child
      try:
        discard comp.storePut("message", child & ":" & align($seqNo, 6, '0'),
                              rec, timeoutMs = 10_000)
      except CatchableError as e:
        return (false, "cannot seed the child's history (store " &
                       "unreachable): " & e.msg, 0, "")
      upto = msgs[j].id
  if seqNo == 0:
    return (false, "nothing to fork: the selection excluded every record",
            0, "")
  return (true, "", seqNo, upto)

proc agentMaxDepth(): int =
  ## The component-side mirror of core's NIF_AGENT_MAX_DEPTH (default 1).
  ## In production the supervisor propagates core's environment to every
  ## component, so both enforcement points read the same cap; the test
  ## harness sets it on both explicitly. An unreadable value falls back.
  try:
    let v = parseInt(getEnv("NIF_AGENT_MAX_DEPTH", "1").strip())
    return if v < 0: 1 else: v
  except CatchableError:
    return 1

proc lineageDepth(session: string; cap: int): int =
  ## Component-side mirror of core's depth walk (components cannot import
  ## core/dispatch): count sessionmeta.parent links from `session` up to a
  ## root, bounded by the cap. Fail closed on a store error — lineage that
  ## cannot be verified denies the spawn.
  var cur = session
  var depth = 0
  while depth <= cap:
    var meta: JsonNode
    try:
      meta = comp.storeGet("sessionmeta", cur, 10_000).value
    except StoreNotFoundError:
      # not-found reads as "no lineage record" — a root at this depth
      return depth
    except CatchableError:
      # the store is unreachable (any other refusal): lineage cannot be
      # verified, so fail closed
      return cap + 1
    let parent = if meta != nil: meta{"parent"}.getStr("") else: ""
    if parent.len == 0:
      return depth
    inc depth
    cur = parent
  return depth

proc prepareChild(parentSession, task, model: string;
                  forkMode = "", forkK = 0, forkChars = 0): tuple[
    ok: bool, error: string, subject: string, child: string,
    forkCopied: int, forkUpto: string] =
  ## Depth-guarded child-runner preparation + fail-closed lineage.
  ## Defense in depth: core's dispatch gate already enforces the cap for
  ## turn-dispatched calls; this second check guards this component's own
  ## trust boundary with the same configurable rule.
  let cap = agentMaxDepth()
  let depth = lineageDepth(parentSession, cap)
  if depth >= cap:
    return (false, "subagent depth " & $depth & " exceeds NIF_AGENT_MAX_DEPTH=" &
                   $cap & " (subagents cannot spawn subagents)", "",
            "", 0, "")
  let child = "agent-" & newId()
  # The fork copy happens BEFORE the runner exists: the child's runner (and
  # its conversation header) are created around the seeded history —
  # ensureConversationHeader is idempotent, so messages-before-header is the
  # supported order.
  var forkCopied = 0
  var forkUpto = ""
  if forkMode.len > 0:
    let (ok, err, copied, upto) = forkHistory(parentSession, child,
                                              forkMode, forkK, forkChars)
    if not ok:
      return (false, err, "", "", 0, "")
    forkCopied = copied
    forkUpto = upto
  # prepare the runner directly (core's session tool would stash mid-turn)
  var prep: JsonNode
  try:
    prep = comp.request("core", "session_prepare",
                        %*{"sessionId": child}, 60_000)
  except CatchableError as e:
    return (false, "session_prepare failed: " & e.msg, "", "", 0, "")
  let subject = prep{"subject"}.getStr("")
  if subject.len == 0:
    return (false, "session_prepare returned no subject", "", "", 0, "")
  # lineage before the turn, fail closed: an unrecorded child would pass
  # its own depth guard and could spawn grandchildren
  var meta = %*{"parent": parentSession}
  if forkCopied > 0:
    meta["fork"] = %*{"source": parentSession, "uptoId": forkUpto,
                      "copied": forkCopied}
  try:
    discard comp.storePut("sessionmeta", child, meta, timeoutMs = 10_000)
  except CatchableError as e:
    return (false, "cannot record subagent lineage (store unreachable): " &
                    e.msg, "", "", 0, "")
  result = (true, "", subject, child, forkCopied, forkUpto)

# Model inheritance (main's ac14d02): an explicit child override wins;
# otherwise the child inherits the parent's persisted effective model.
# Applies at BIRTH only — a continuation's model is frozen at its first
# turn and the caller's model argument is ignored by design (P1.3), so the
# continuation path never consults this.
const agentTiers = ["weak", "medium", "strong"]

proc tierRank(name: string): int =
  let normalized = name.strip().toLowerAscii()
  for i, tier in agentTiers:
    if normalized == tier: return i
  -1

proc tierModel(rank: int): string =
  case rank
  of 0: getEnv("NIF_AGENT_MODEL_WEAK", "").strip()
  of 1: getEnv("NIF_AGENT_MODEL_MEDIUM", "").strip()
  of 2: getEnv("NIF_AGENT_MODEL_STRONG", "").strip()
  else: ""

proc defaultAgentTier(): int =
  let configured = getEnv("NIF_AGENT_DEFAULT_TIER", "strong")
  let rank = tierRank(configured)
  if rank >= 0: rank else: 2

proc tierNameForModel(model: string): string =
  let normalized = model.strip()
  for i in 0 ..< agentTiers.len:
    if tierModel(i) == normalized: return agentTiers[i]
  ""

proc parentTier(model: string): int =
  ## Unknown parent models use the configured ceiling. This keeps existing
  ## deployments compatible while allowing installations with a known model
  ## ladder to clamp children strictly.
  let normalized = model.strip()
  for i in 0 ..< agentTiers.len:
    if tierModel(i) == normalized: return i
  defaultAgentTier()

proc childModel(c: Component, parentSession, requested, requestedTier: string): tuple[
    ok: bool, model, error: string] =
  ## Resolve a fresh child's model. An explicit exact model remains supported;
  ## `modelTier` selects from the configured weak/medium/strong ladder and is
  ## clamped to the parent's effective tier. Both controls together are
  ## rejected so a caller cannot mistake a silently ignored tier for policy.
  ## Continuations never call this: their model is frozen at birth.
  if requested.len > 0 and requestedTier.len > 0:
    return (false, "", "model and modelTier are mutually exclusive")
  if requested.len > 0:
    return (true, requested, "")
  try:
    let info = c.request("core", "session_info",
                         %*{"sessionId": parentSession}, 10_000)
    if info{"error"} != nil:
      # The parent conversation could not be read (e.g. a direct bus caller
      # with no conversation of its own). Degrade, don't fail: inheritance
      # is a default, not a requirement — the requested model (possibly
      # empty, meaning the provider's default) stands alone.
      return (true, requested, "")
    let override = info{"modelOverride"}.getStr("").strip()
    let inherited = if override.len > 0: override
                    else: info{"model"}.getStr("").strip()
    if requestedTier.len > 0:
      let requestedRank = tierRank(requestedTier)
      if requestedRank < 0:
        return (false, "", "modelTier must be weak, medium, or strong")
      let effectiveRank = min(requestedRank, parentTier(inherited))
      let selected = tierModel(effectiveRank)
      if selected.len == 0:
        return (false, "", "model tier '" & agentTiers[effectiveRank] &
          "' is not configured (set NIF_AGENT_MODEL_" &
          agentTiers[effectiveRank].toUpperAscii() & ")")
      return (true, selected, "")
    return (true, inherited, "")
  except CatchableError as e:
    # Same degradation as above, and note that core RAISES on an error
    # result (an unknown session reaches here as an exception, not an
    # {"error": ...} envelope). Inheritance is a default: degrade quietly.
    stderr.writeLine("agent: parent model inheritance unavailable (" &
                     e.msg & ") — using the requested model as-is")
    return (true, requested, "")

# --- continuation ------------------------------------------------------------
# A continuation is a NEW TURN in an EXISTING child conversation, not a new
# child: the conversation already persists, its runner re-ensures on demand,
# and every per-session control is frozen in its header. So the only things
# this needs are the authorization check and the runner subject. Design:
# docs/research/SUBAGENTS-PLAN.md P1.3.

proc childMeta(child: string): tuple[found: bool, value: JsonNode] =
  ## The stored lineage/meta record for a session, if any.
  try:
    let v = comp.storeGet("sessionmeta", child, 10_000).value
    if v == nil: return (false, newJObject())
    return (true, v)
  except StoreNotFoundError:
    return (false, newJObject())

proc continuable(child, caller: string): tuple[
    ok: bool, error: string, subject: string, activation: int] =
  ## Resolve a continuation target: validate FAIL-CLOSED, then re-ensure its
  ## runner. Authorization is the durable lineage relation (the child's
  ## sessionmeta.parent must be the caller) — the same relation the depth
  ## guard uses, so there is one notion of "whose child is this".
  ##
  ## Every rejection is explicit: an unknown session, a root conversation, a
  ## foreign child, a closed child and an unreachable store all refuse rather
  ## than silently minting a fresh child (which would look like success while
  ## doing something else entirely).
  ##
  ## On success this also advances the child's activation counter
  ## (sessionmeta.activations, 1-based) — the durable ledger of how many
  ## turns the child has had. Only the lineage parent may continue a child
  ## and one parent's calls serialize through this component's pump, so the
  ## read-modify-write cannot race.
  if child == caller:
    return (false, "cannot continue yourself", "", 0)
  var found = false
  var meta = newJObject()
  try:
    (found, meta) = childMeta(child)
  except CatchableError as e:
    return (false, "cannot verify continuation rights (store unreachable): " &
                   e.msg, "", 0)
  if not found:
    return (false, "unknown subagent session '" & child &
                   "' — no lineage record (it is not a child of this " &
                   "conversation, or it was deleted)", "", 0)
  if meta{"closed"}.getBool(false):
    return (false, "subagent session '" & child &
                   "' was closed (close: true); start a fresh one instead",
            "", 0)
  let owner = meta{"parent"}.getStr("")
  if owner.len == 0:
    return (false, "'" & child & "' is a root conversation, not a subagent " &
                   "of this one", "", 0)
  if owner != caller:
    return (false, "subagent '" & child & "' belongs to another conversation " &
                   "('" & owner & "'); only its parent may continue it", "", 0)
  # The child exists and we may continue it. Its runner may be resident or
  # retired — session_prepare is the idempotent re-ensure, so a retired child
  # costs a process start, not a redesign.
  var prep: JsonNode
  try:
    prep = comp.request("core", "session_prepare",
                        %*{"sessionId": child}, 60_000)
  except CatchableError as e:
    return (false, "session_prepare failed for continuation: " & e.msg,
            "", 0)
  let subject = prep{"subject"}.getStr("")
  if subject.len == 0:
    return (false, "session_prepare returned no subject", "", 0)
  # Advance the activation ledger. firstActivationAt is set once and never
  # moves; activations counts every turn the child has accepted, including
  # its first (so a child continued once reports activations = 2).
  let activation = meta{"activations"}.getInt(1) + 1
  meta["activations"] = %activation
  if meta{"firstActivationAt"} == nil:
    meta["firstActivationAt"] = %epochTime()
  try:
    discard comp.storePut("sessionmeta", child, meta, timeoutMs = 10_000)
  except CatchableError as e:
    return (false, "cannot record the continuation (store unreachable): " &
                   e.msg, "", 0)
  return (true, "", subject, activation)

proc busyChild(child: string): bool =
  ## True when the child's runner is holding a turn right now. Answered from
  ## the ev.session.turn tap (the catalog has no turn state). Used to refuse
  ## `agent_run {session}` with a clear `busy` instead of queueing a caller
  ## that promised it wanted the result now.
  child in liveTurns

proc effectiveControls(child: string): JsonNode =
  ## The child conversation's actual frozen controls, read back from its
  ## conversation header. A continuation ignores the caller's
  ## model/thinking/tools/budget arguments (they were frozen at the child's
  ## FIRST turn), so reporting the effective set is how the caller learns
  ## what it is really talking to instead of assuming its arguments took
  ## effect. Read from the store directly: session_info does not carry the
  ## per-session budget fields, and this keeps the read-only path free of a
  ## core change.
  result = newJObject()
  try:
    let header = comp.storeGet("conversation", child, 10_000).value
    if header == nil: return
    for f in ["model", "modelOverride", "thinkingEffort"]:
      if header{f} != nil and header{f}.getStr("").len > 0:
        result[f] = header{f}
    let tier = tierNameForModel(header{"model"}.getStr(""))
    if tier.len > 0:
      result["modelTier"] = %tier
    for f in ["maxRounds", "maxCalls", "maxTokens"]:
      if header{f} != nil and header{f}.getInt(0) > 0:
        result[f] = header{f}
    let allow = header{"toolAllowlist"}
    if allow != nil and allow.kind == JArray and allow.len > 0:
      result["tools"] = allow
  except CatchableError:
    discard

proc childSessArgs(child, task, model, thinking: string,
                   toolArgs: JsonNode = nil; fresh = true): JsonNode =
  ## The child session call.
  ##
  ## `fresh` is a BIRTH: task preamble, optional model/thinking, optional
  ## tool allowlist and budgets (all frozen into the child's header by core
  ## on this first call), and the conversation's pluggable constitution
  ## (systemprompt component, best effort — the runner's own fallback covers
  ## a missing component).
  ##
  ## `fresh = false` is a CONTINUATION: the child's constitution, model,
  ## thinking, allowlist and budgets were frozen at its FIRST turn and are
  ## read from its own header by core. Sending them again would be at best
  ## ignored and at worst a future divergence between what the caller thinks
  ## it set and what the child actually runs with — so a continuation sends
  ## the content and nothing else. The task preamble is also dropped: the
  ## child already knows it is a subagent (it was told on turn one).
  if fresh:
    result = %*{"sessionId": child, "content": taskPreamble & task}
    try:
      let sp = comp.request("systemprompt", "systemprompt",
        %*{"cwd": getEnv("NIF_ROOT", getCurrentDir()), "sessionId": child},
        5_000)
      let prompt = sp{"systemPrompt"}.getStr("")
      if prompt.len > 0:
        result["systemPrompt"] = %prompt
    except CatchableError:
      discard
    if model.len > 0:
      result["model"] = %model
    if thinking.len > 0:
      result["thinking"] = %thinking
    if toolArgs != nil:
      # never embed a possibly-nil JsonNode in %* (SIGSEGVs at toUgly)
      if toolArgs{"tools"} != nil and toolArgs{"tools"}.kind == JArray:
        result["tools"] = toolArgs{"tools"}
      let mr = toolArgs{"maxRounds"}.getInt(0)
      if mr >= 1 and mr <= 50:
        result["maxRounds"] = %mr
      # per-job budgets (frozen per-session controls enforced by core): total
      # tool dispatches and cumulative tokens for the child's whole turn
      let mc = toolArgs{"maxCalls"}.getInt(0)
      if mc >= 1 and mc <= 500:
        result["maxCalls"] = %mc
      let mt = toolArgs{"maxTokens"}.getInt(0)
      if mt >= 1:
        result["maxTokens"] = %mt
    return
  # Continuation: content only. No systemPrompt, no model/thinking/tools,
  # no budgets — every one of those is already frozen for this conversation.
  result = %*{"sessionId": child, "content": task}

proc originalCaller(toolArgs: JsonNode): string =
  ## Approvals inside the child route to the original interactive caller
  ## (injected as private context by the dispatch gate), not to this
  ## component — which may be blocked in a handler and could not answer.
  toolArgs{"__session"}{"caller"}.getStr("agent")

var stopArmed = initHashSet[string]()
  ## Jobs whose stop cancellation was already (re-)published. A stop request
  ## is re-armed exactly once per component incarnation — the first time a
  ## resolveStale sees the job stopping with its runner alive (the original
  ## publish may have been lost while this component was down). Re-arming on
  ## every status/wait poll would flood the child's cancel channel.

# --- restart recovery --------------------------------------------------------
# Non-terminal job records must not lie: after this component restarts (or a
# harness restart killed a child runner), status/wait resolve the record
# against the live catalog and the child transcript.

proc runnerAlive(sessionId: string): bool =
  ## Presence of the child's session runner in the live catalog. Any failure
  ## reads as absent: resolution prefers an honest terminal record over a
  ## job stuck "running" forever.
  try:
    let snap = comp.request("core", "catalog", %*{"op": "components"}, 10_000)
    let comps = snap{"components"}
    if comps == nil: return false
    return comps{"session-" & sanitizeSessionId(sessionId)} != nil
  except CatchableError:
    return false

proc lastTranscript(sessionId: string): tuple[role, content: string] =
  ## Last persisted message of the child conversation (best effort: any
  ## store failure returns empty, which reads as "no evidence").
  ## storeListAll pages the transcript: with a single capped list this saw
  ## only the first 1000 messages, so "the last message" could be a stale
  ## one from the middle of a long child conversation — and job settlement
  ## decisions were made from it.
  try:
    var last: JsonNode = nil
    for item in comp.storeListAll("message", sessionId & ":", 1000, 10_000):
      if item.id.startsWith(sessionId & ":"):
        last = item.value
    if last != nil:
      return (last{"role"}.getStr(""), last{"content"}.getStr(""))
  except CatchableError:
    discard
  return ("", "")

proc resolveStale(jobId: string, value: JsonNode): JsonNode =
  ## Reconcile one non-terminal job record. Rules:
  ## - runner alive: the turn may still complete (the tap will catch it);
  ##   only re-publish a lost stop request for "stopping" jobs. No change.
  ## - runner gone + transcript ends with an assistant reply: the turn
  ##   completed while this component was down (completion tap missed) —
  ##   synthesize the terminal record from the transcript.
  ## - runner gone without a final reply: the turn died with the runner —
  ##   record it as interrupted (stopping jobs read "stopped", not failed).
  ## Returns the updated value, or nil when the record was left alone.
  let status = value{"status"}.getStr("running")
  if status != "running" and status != "stopping": return nil
  let child = value{"sessionId"}.getStr("")
  if child.len == 0: return nil
  if runnerAlive(child):
    if status == "running" and jobId notin stopArmed and
        value{"budgetMs"}.getInt(0) > 0 and
        (epochTime() - value{"startedAt"}.getFloat(0)) * 1000.0 >
            value{"budgetMs"}.getFloat(0):
      # Time budget exhausted (enforced lazily on observation): cancel the
      # turn with agent_stop semantics; the completion tap — or a later
      # poll after the child dies — terminalizes the record as "stopped".
      stopArmed.incl(jobId)
      value["status"] = %"stopping"
      try:
        discard comp.storePut("agentjob", jobId, value, timeoutMs = 10_000)
      except CatchableError:
        return nil
      publishCancel(comp, child)
      return value
    if status == "stopping" and jobId notin stopArmed:
      # the original stop may have been lost while this component was down;
      # re-arm exactly once per incarnation (never per poll)
      stopArmed.incl(jobId)
      publishCancel(comp, child)
    return nil
  var updated = value
  let (role, content) = lastTranscript(child)
  if role == "assistant":
    updated["status"] = %(if status == "stopping": "stopped" else: "done")
    updated["reply"] = %content
  else:
    updated["status"] = %(if status == "stopping": "stopped" else: "failed")
    updated["error"] = %"interrupted — child runner gone before completion"
  updated["endedAt"] = %epochTime()
  try:
    discard comp.storePut("agentjob", jobId, updated, timeoutMs = 10_000)
  except CatchableError:
    return nil  # cannot persist — leave the record alone rather than lie
  emitNotice(comp, jobId, updated{"parent"}.getStr(""),
             updated{"sessionId"}.getStr(""), updated{"status"}.getStr(""),
             updated{"reply"}.getStr(""))
  comp.emit("ev.agent.done", %*{"jobId": jobId,
                                "sessionId": updated{"sessionId"},
                                "status": updated{"status"}})
  return updated

proc reconcileAll() =
  ## Boot-time pass over every non-terminal job (best effort).
  try:
    for item in comp.storeList("agentjob", "", 1000, 10_000):
      let jobId = item.id
      if jobId.len == 0: continue
      discard resolveStale(jobId, item.value)
  except CatchableError:
    discard

# low-level registration: the handler needs the raw __session injection
let runSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "The task, phrased for the mode. Fresh child (no session): it starts with a fresh context — include everything it needs (paths, goals, constraints), not a continuation of this conversation. Forked child (fork set): it sees the completed turns of this conversation but not the turn in flight — state only what is new. Continuation (session set): it already has its own history — send only the next task."},
  "model": {"type": "string",
            "description": "Optional exact model override for the subagent; mutually exclusive with modelTier"},
  "modelTier": {"type": "string", "enum": ["weak", "medium", "strong"],
                "description": "Optional model tier for a FRESH child. Resolves through NIF_AGENT_MODEL_* and is clamped to the parent's tier; mutually exclusive with model"},
  "thinking": {"type": "string",
               "description": "Optional reasoning effort for the subagent (e.g. low/high; passed to the child's turns)"},
  "tools": {"type": "array",
            "description": "Optional tool allowlist for the subagent (frozen for the child conversation; it may dispatch only these tools)"},
  "maxRounds": {"type": "integer",
                "description": "Optional tool-round budget per child turn (1-50, default 50)"},
  "maxCalls": {"type": "integer",
               "description": "Optional total tool-dispatch budget for the child's turn (1-500); the turn ends as budget-exhausted once it is spent"},
  "maxTokens": {"type": "integer",
                "description": "Optional cumulative token budget for the child's turn (provider-reported tokens across LLM rounds); the turn ends as budget-exhausted once it is spent"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting for the subagent after this many ms (default 600000)"},
  "session": {"type": "string",
              "description": "Continue an EXISTING child instead of starting a fresh one: pass the sessionId that a previous agent_run/agent_spawn returned. The child keeps its conversation, so send only the new task — and model/modelTier/thinking/tools/maxRounds/maxCalls/maxTokens are IGNORED (they were frozen at the child's first turn; the result reports the effective values). Fails if the session is not a child of this conversation, is closed, or if its runner is mid-turn (use agent_spawn for that)."},
  "close": {"type": "boolean",
            "description": "Mark this child finished after THIS turn completes, so it can no longer be continued (nothing is deleted). Works on a fresh run (one-shot child) or a continuation (last turn)."},
  "fork": {"type": ["boolean", "object"],
           "description": "FRESH RUNS ONLY: seed the child with this conversation's COMPLETED turns, so it has READ the discussion instead of being told about it. true copies every completed turn; {lastK: n} copies only the last n; {maxChars: n} copies the newest turns that fit. The cut never lands mid-tool-round, and usage meters are NOT copied (the child is born cold — its first request replays the history uncached; warm from the second turn). The child receives the RAW transcript — it may be larger than this conversation's current live context (compaction checkpoints are not copied); the child's own compaction shrinks it on its own schedule. Use this when the child must exercise judgment over the discussion; for bulk mechanical transfer with no judgment, use fabric instead. Fails closed if nothing fits."}
}, required = @["task"],
   description = "Run a task in a subagent session and return only its final reply. Without `session` it starts a FRESH child with its own context (include everything it needs — it does not see this conversation). With `session` it gives an EXISTING child another turn, keeping everything it already knows (send only the new task). Use for subtasks needing exploratory judgment per step — search, debugging, reading code — whose intermediate work must not enter this conversation. For mechanical, well-understood sequences (fan-out, big data, known shape) prefer the fabric tool; for background work use agent_spawn. The subagent cannot spawn further subagents.")
runSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 900_000,
                            "sessionContext": true, "noSpawn": true,
                            "onDemand": true}
discard comp.tool("agent_run", runSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_run needs a live session context")
    let task = toolArgs{"task"}.getStr("")
    if task.len == 0:
      return errResult("agent_run needs task")
    let target = toolArgs{"session"}.getStr("")
    let isFresh = target.len == 0
    let (forkOk, forkErr, forkMode, forkK, forkChars) = parseForkSpec(toolArgs)
    if not forkOk:
      return errResult(forkErr)
    if not isFresh and forkMode.len > 0:
      # A fork is a birth, not a continuation: the child to continue already
      # has its history, and re-seeding it would duplicate it.
      return errResult("fork only applies to a fresh child — drop it when " &
                       "continuing an existing session",
                       extra = %*{"sessionId": target})
    # Model inheritance on the fresh path only: a continuation's model was
    # frozen at its first turn (the result's effectiveControls reports it).
    var resolvedModel = (ok: true, model: "", error: "")
    if isFresh:
      let requestedModel = toolArgs{"model"}.getStr("").strip()
      let requestedTier = toolArgs{"modelTier"}.getStr("").strip()
      let cm = childModel(c, parentSession, requestedModel, requestedTier)
      if not cm.ok:
        return errResult(cm.error)
      resolvedModel = cm
    # Resolve the target FIRST (authorization fail-closed), THEN apply the
    # busy check: a mid-turn refusal is only meaningful for a target we may
    # actually continue — and the caller itself is always "mid-turn" while
    # its own agent_run executes (its runner holds the turn), so a
    # busy-before-auth check would misreport root/self continuations as
    # busy instead of naming the real reason.
    var ok = false
    var failure = ""
    var subject = ""
    var child = ""
    var activation = 0
    var forkCopied = 0
    var forkUpto = ""
    if isFresh:
      let prep = prepareChild(parentSession, task, resolvedModel.model,
                              forkMode, forkK, forkChars)
      (ok, failure, subject, child, forkCopied, forkUpto) = prep
    else:
      let cont = continuable(target, parentSession)
      child = target
      (ok, failure, subject, activation) = cont
    if not ok:
      return errResult(failure, extra = %*{"sessionId": child})
    if not isFresh and busyChild(child):
      # The child is mid-turn. `agent_run` promises a result NOW, so refusing
      # is honest: the alternative is a request that silently queues behind
      # the running turn and may time out. agent_spawn queues by design.
      return errResult("subagent '" & child & "' is mid-turn — use " &
                       "agent_spawn to queue another turn, or agent_wait/" &
                       "agent_status for its current one",
                       code = "busy", extra = %*{"sessionId": child})
    if wasCancelled(parentSession):
      # A stop for this session landed while its agent_run was queued behind
      # another in-flight agent_run: the launching turn is gone, so the
      # child must never be started (bash's queued-request semantics).
      return errResult("cancelled by request")
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(600_000)
    let env = callEnvelope("session",
      childSessArgs(child, task, resolvedModel.model,
                    toolArgs{"thinking"}.getStr(""), toolArgs,
                    fresh = isFresh),
      originalCaller(toolArgs))
    let resp = requestChildTurn(c, subject, env, timeoutMs,
                                parentSession, child)
    if resp.kind == ekError:
      return errResult(resp.error{"message"}.getStr("subagent failed"),
                       extra = %*{"sessionId": child})
    # a child whose LLM failed reports failure, not a text reply
    let turnError = resp.args{"turnError"}.getStr("")
    if turnError.len > 0:
      return errResult(turnError, extra = %*{"sessionId": child})
    let reportedModel = if isFresh and resolvedModel.model.len > 0:
                          resolvedModel.model
                        else:
                          resp.args{"modelOverride"}.getStr("")
    var answer = %*{"sessionId": child,
                    "reply": resp.args{"reply"}.getStr(""),
                    "model": reportedModel}
    let effectiveModel = if isFresh: resolvedModel.model
                         else: answer["model"].getStr("")
    let effectiveTier = tierNameForModel(effectiveModel)
    if effectiveTier.len > 0:
      answer["modelTier"] = %effectiveTier
    if forkCopied > 0:
      answer["fork"] = %*{"source": parentSession, "uptoId": forkUpto,
                          "copied": forkCopied}
    if not isFresh:
      # Report what the child is ACTUALLY running with, since the caller's
      # model/thinking/tools/budget arguments were ignored by design.
      answer["continued"] = %true
      answer["activation"] = %activation
      answer["effective"] = effectiveControls(child)
    if toolArgs{"close"}.getBool(false):
      # Retire the child after THIS turn — a one-shot fresh child or the
      # last turn of a continued one. The record and transcript survive;
      # only further continuation refuses.
      try:
        let (found, meta) = childMeta(child)
        if found:
          meta["closed"] = %true
          discard c.storePut("sessionmeta", child, meta, timeoutMs = 10_000)
          answer["closed"] = %true
      except CatchableError as e:
        answer["closeError"] = %("cannot mark the child closed: " & e.msg)
    return okResult(answer))

let spawnSchema = toolSchema(%*{
  "task": {"type": "string",
           "description": "The task, phrased for the mode (same contract as agent_run). Fresh child: include everything it needs — it does not see this conversation. Forked child: it sees this conversation's completed turns — state only what is new. Continuation (session set): send only the next task."},
  "model": {"type": "string",
            "description": "Optional exact model override for the subagent; mutually exclusive with modelTier"},
  "modelTier": {"type": "string", "enum": ["weak", "medium", "strong"],
                "description": "Optional model tier for a FRESH child. Resolves through NIF_AGENT_MODEL_* and is clamped to the parent's tier; mutually exclusive with model"},
  "thinking": {"type": "string",
               "description": "Optional reasoning effort for the subagent (e.g. low/high; passed to the child's turns)"},
  "tools": {"type": "array",
            "description": "Optional tool allowlist for the subagent (frozen for the child conversation; it may dispatch only these tools)"},
  "maxRounds": {"type": "integer",
                "description": "Optional tool-round budget per child turn (1-50, default 50)"},
  "maxCalls": {"type": "integer",
               "description": "Optional total tool-dispatch budget for the child's turn (1-500); the turn ends as budget-exhausted once it is spent"},
  "maxTokens": {"type": "integer",
                "description": "Optional cumulative token budget for the child's turn (provider-reported tokens across LLM rounds); the turn ends as budget-exhausted once it is spent"},
  "timeoutMs": {"type": "integer",
                "description": "Optional job budget in ms: once exceeded, the job is cancelled (agent_stop semantics) the next time it is observed via agent_status/agent_wait"},
  "session": {"type": "string",
              "description": "Give an EXISTING child another turn in the background instead of starting a fresh one: pass the sessionId from a previous agent_run/agent_spawn. The child keeps its conversation, so send only the new task — model/modelTier/thinking/tools/maxRounds/maxCalls/maxTokens are IGNORED (frozen at its first turn). Unlike agent_run this QUEUES if the child is mid-turn: a background job only promises the work happens. Fails if the session is not a child of this conversation or is closed."},
  "close": {"type": "boolean",
            "description": "Mark this child finished AFTER the queued/background turn settles, so it can no longer be continued (nothing is deleted). Applies via the job's completion, so it composes with session (queue the turn, then retire the child)."},
  "fork": {"type": ["boolean", "object"],
           "description": "FRESH JOBS ONLY: seed the child with this conversation's COMPLETED turns (true = all; {lastK: n}; {maxChars: n}). The child has READ the discussion; it is born cold (uncached first request). The cut never lands mid-tool-round; fails closed if nothing fits."}
}, required = @["task"],
   description = "Start a subagent task in the BACKGROUND and return {jobId, sessionId} immediately; you are told when it settles (settlement notice), so there is no need to poll. agent_status checks it without blocking, agent_wait blocks, agent_steer injects into the live turn, agent_stop cancels it. Without `session` it starts a FRESH child (give it everything: it does not see this conversation); with `session` it queues another turn for an EXISTING child that already has the context. Start independent delegations together in one message and keep working while they run. Use agent_run instead when your next action depends on the result. The subagent cannot spawn further subagents.")
spawnSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 60_000,
                              "sessionContext": true, "noSpawn": true,
                              "onDemand": true}
discard comp.tool("agent_spawn", spawnSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_spawn needs a live session context")
    let task = toolArgs{"task"}.getStr("")
    if task.len == 0:
      return errResult("agent_spawn needs task")
    let target = toolArgs{"session"}.getStr("")
    let isFresh = target.len == 0
    let (forkOk, forkErr, forkMode, forkK, forkChars) = parseForkSpec(toolArgs)
    if not forkOk:
      return errResult(forkErr)
    if not isFresh and forkMode.len > 0:
      # A fork is a birth, not a continuation: the child to continue already
      # has its history, and re-seeding it would duplicate it.
      return errResult("fork only applies to a fresh child — drop it when " &
                       "continuing an existing session",
                       extra = %*{"sessionId": target})
    # Model inheritance on the fresh path only (see agent_run).
    var resolvedModel = (ok: true, model: "", error: "")
    if isFresh:
      let requestedModel = toolArgs{"model"}.getStr("").strip()
      let requestedTier = toolArgs{"modelTier"}.getStr("").strip()
      let cm = childModel(c, parentSession, requestedModel, requestedTier)
      if not cm.ok:
        return errResult(cm.error)
      resolvedModel = cm
    # No busy check here, by design: a background job promises the work
    # HAPPENS, not that it starts now. A turn queued behind the child's
    # current one is what a queue is for (the child's runner serializes
    # turns, so it runs next).
    var ok = false
    var failure = ""
    var subject = ""
    var child = ""
    var activation = 0
    var forkCopied = 0
    var forkUpto = ""
    if isFresh:
      let prep = prepareChild(parentSession, task, resolvedModel.model,
                              forkMode, forkK, forkChars)
      (ok, failure, subject, child, forkCopied, forkUpto) = prep
    else:
      let cont = continuable(target, parentSession)
      child = target
      (ok, failure, subject, activation) = cont
    if not ok:
      return errResult(failure, extra = %*{"sessionId": child})
    let jobId = "job-" & newId()
    # durable record BEFORE the fire-and-forget publish, so a completion
    # that races the spawn cannot arrive at an unknown job
    var record = %*{"sessionId": child, "parent": parentSession,
                    "status": "running",
                    "task": task[0 ..< min(task.len, 200)],
                    "startedAt": epochTime()}
    if not isFresh:
      record["continued"] = %true
      record["activation"] = %activation
    if toolArgs{"close"}.getBool(false):
      # applied by the completion tap AFTER the turn settles — the parent
      # cannot close a child before the work it queued has run
      record["close"] = %true
    let budgetMs = toolArgs{"timeoutMs"}.getInt(0)
    if budgetMs > 0:
      record["budgetMs"] = %budgetMs
    try:
      discard comp.storePut("agentjob", jobId, record, timeoutMs = 10_000)
    except CatchableError as e:
      return errResult("cannot record job (store unreachable): " & e.msg,
                       extra = %*{"sessionId": child})
    let env = callEnvelope("session",
      childSessArgs(child, task, resolvedModel.model,
                    toolArgs{"thinking"}.getStr(""), toolArgs,
                    fresh = isFresh),
      originalCaller(toolArgs))
    let data = env.encode()
    let inbox = "_INBOX.agentjob." & jobId
    let st = natsConnection_PublishRequest(c.nc.conn, subject.cstring,
      inbox.cstring, data.cstring, data.len.cint)
    if not checkStatus(st):
      discard c.storePut("agentjob", jobId,
        %*{"sessionId": child, "parent": parentSession,
           "status": "failed",
           "error": "publish failed: " & getErrorString(st)},
        timeoutMs = 10_000)
      return errResult("could not start the job: " & getErrorString(st),
                       extra = %*{"jobId": jobId, "sessionId": child})
    comp.emit("ev.agent.started", %*{"jobId": jobId, "sessionId": child,
                                     "parent": parentSession})
    var started = %*{"jobId": jobId, "sessionId": child,
                     "steer": "svc.session." &
                              sanitizeSessionId(child) & ".steer"}
    if toolArgs{"close"}.getBool(false):
      started["close"] = %true
    if forkCopied > 0:
      started["fork"] = %*{"source": parentSession, "uptoId": forkUpto,
                           "copied": forkCopied}
    return okResult(started))

let statusSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Non-blocking lookup of a background subagent job: returns its durable status (running/done/failed/stopped/stopping), session id, and — when terminal — the final reply or error. Does not wait; use agent_wait for that.")
statusSchema["x-harness"] = %*{"onDemand": true}
discard comp.tool("agent_status", statusSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_status needs jobId")
    try:
      var value = c.storeGet("agentjob", jobId, 10_000).value
      # lazy restart recovery: a non-terminal record is reconciled against
      # the live catalog and the child transcript before it is reported
      let resolved = resolveStale(jobId, value)
      if resolved != nil: value = resolved
      return okResult(value)
    except StoreNotFoundError:
      return errResult("unknown job '" & jobId & "'", code = "not-found")
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

let waitSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting after this many ms (default 600000)"}
}, required = @["jobId"],
   description = "Block until a background subagent job reaches a terminal state (done/failed/stopped) and return its durable result — including for jobs that finished long ago (late waits read the store). Terminal states carry the child's final reply, or the failure reason for failed jobs.")
waitSchema["x-harness"] = %*{"timeoutMs": 900_000, "onDemand": true}
discard comp.tool("agent_wait", waitSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_wait needs jobId")
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(600_000)
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while true:
      # the completion tap shares this serialized pump: without pumping it
      # here, a reply arriving during the wait would sit queued forever
      discard c.pumpTaps(100)
      var value: JsonNode
      try:
        value = c.storeGet("agentjob", jobId, 10_000).value
      except StoreNotFoundError:
        return errResult("unknown job '" & jobId & "'", code = "not-found")
      except CatchableError as e:
        return errResult("cannot read job (store unreachable): " & e.msg)
      # lazy restart recovery: same reconciliation as agent_status, so a
      # wait on a stale record resolves it instead of blocking forever
      let resolved = resolveStale(jobId, value)
      if resolved != nil: value = resolved
      let status = value{"status"}.getStr("running")
      # "stopping" is NOT terminal: keep waiting until the completion tap
      # (or lazy recovery) lands done/failed/stopped
      if status != "running" and status != "stopping":
        return okResult(value)
      if epochTime() >= deadline:
        return errResult("job '" & jobId & "' still " & status & " after " &
          $timeoutMs & "ms — poll agent_status instead of waiting again",
          code = "timeout", extra = %*{"jobId": jobId, "status": status})
      sleep(250))

let stopSchema = toolSchema(%*{
  "jobId": {"type": "string", "description": "Job id returned by agent_spawn"}
}, required = @["jobId"],
   description = "Cancel a running background subagent job: aborts its in-flight LLM request and ends the child turn (between tool rounds, promptly after the current tool returns). The job's terminal record says \"stopped\" — the reply, if any, is kept. Re-calling is harmless; stopping an already-terminal job just returns the record.")
stopSchema["x-harness"] = %*{"onDemand": true}
discard comp.tool("agent_stop", stopSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let jobId = toolArgs{"jobId"}.getStr("")
    if jobId.len == 0:
      return errResult("agent_stop needs jobId")
    try:
      let value = c.storeGet("agentjob", jobId, 10_000).value
      let status = value{"status"}.getStr("running")
      if status != "running" and status != "stopping":
        return okResult(value)
      if status != "stopping":
        value["status"] = %"stopping"
        discard c.storePut("agentjob", jobId, value, timeoutMs = 10_000)
      let child = value{"sessionId"}.getStr("")
      if child.len > 0:
        publishCancel(c, child)
      return okResult(%*{"status": "stopping", "sessionId": child})
    except StoreNotFoundError:
      return errResult("unknown job '" & jobId & "'", code = "not-found")
    except CatchableError as e:
      return errResult("cannot read job (store unreachable): " & e.msg))

let steerSchema = toolSchema(%*{
  "session_id": {"type": "string",
                 "description": "The child session id returned by agent_spawn/agent_run"},
  "message": {"type": "string",
              "description": "The steering message for the running turn"}
}, required = @["session_id", "message"],
   description = "Send a message to one of your subagents. Mid-turn, it is injected into the running turn (folded in between LLM rounds). Between turns, it is QUEUED durably and delivered at the child's next continuation (agent_run/agent_spawn with session) — the reply says which: published=true means injected now, queued=true, deliveredVia=next-turn} means it is waiting for the child's next turn. Only the child's parent conversation may steer it.")
steerSchema["x-harness"] = %*{"onDemand": true, "sessionId": true}
discard comp.tool("agent_steer", steerSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let sessionId = toolArgs{"session_id"}.getStr("")
    let message = toolArgs{"message"}.getStr("")
    if sessionId.len == 0 or message.len == 0:
      return errResult("agent_steer needs session_id and message")
    let caller = toolArgs{"__session"}{"session"}.getStr("")
    if caller.len == 0:
      return errResult("agent_steer needs a live session context")
    # Authorization is the durable lineage relation, the same one that gates
    # continuation: only the child's parent conversation may steer it. This
    # also fail-closes on a nonexistent session — an error, never a pretend
    # publish.
    var meta: JsonNode
    try:
      meta = c.storeGet("sessionmeta", sessionId, 10_000).value
    except StoreNotFoundError:
      return errResult("unknown subagent session '" & sessionId &
                       "' — no lineage record", code = "not-found")
    except CatchableError as e:
      return errResult("cannot verify steering rights (store unreachable): " & e.msg)
    if meta == nil or meta{"parent"}.getStr("") != caller:
      return errResult("subagent '" & sessionId & "' is not yours — only its " &
                       "parent conversation may steer it")
    # Mid-turn: the child's runner is draining the steer channel between LLM
    # rounds, so a publish is delivered NOW. Anything else (idle between
    # turns, retired runner) would swallow a bare publish — the runner's
    # steer subscription dies with it — so queue durably instead and let the
    # child's next turn-top drain fold it in (same pull lane as settlement
    # notices, P0.1; same kind, direction parent-mail).
    if sessionId in liveTurns:
      comp.emit("svc.session." & sanitizeSessionId(sessionId) & ".steer",
                %*{"content": message})
      return okResult(%*{"published": true, "sessionId": sessionId})
    var record = %*{"v": 1, "direction": "parent-mail",
                    "from": caller, "child": sessionId,
                    "text": message, "createdAt": epochTime()}
    var seq = 0
    try:
      for item in c.storeList("agentnotice", sessionId & ":", 1000, 10_000):
        let id = item.id
        let dot = id.rfind(':')
        if dot >= 0:
          try: seq = max(seq, parseInt(id[dot + 1 .. ^1]))
          except ValueError: discard
      inc seq
      discard c.storePut("agentnotice",
                         sessionId & ":" & align($seq, 6, '0'), record,
                         timeoutMs = 10_000)
    except CatchableError as e:
      return errResult("cannot queue the steering (store unreachable): " & e.msg)
    return okResult(%*{"queued": true, "sessionId": sessionId,
                       "deliveredVia": "next-turn",
                       "guidance": "the child is between turns; this was " &
                         "queued for its next continuation (agent_run or " &
                         "agent_spawn with session)"}))

let askSchema = toolSchema(%*{
  "session": {"type": "string",
              "description": "The child session id to ask (a previous agent_run/agent_spawn result)"},
  "question": {"type": "string",
               "description": "The question for the child"},
  "timeoutMs": {"type": "integer",
                "description": "Give up waiting for the child's answer after this many ms (default 300000)"}
}, required = @["session", "question"],
   description = "Ask one of your subagents a question and get its answer. On an idle child this is a continuation that returns the reply directly. On a MID-TURN child the question is queued as mail and delivered when its current turn ends — the result says queued=true with deliveredVia=next-turn, and the answer comes back with the child's next continuation result (or as part of its final report). Same authorization as agent_run: only the child's parent conversation may ask.")
askSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 900_000,
                            "sessionContext": true, "noSpawn": true,
                            "onDemand": true}
discard comp.tool("agent_ask", askSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let parentSession = toolArgs{"__session"}{"session"}.getStr("")
    if parentSession.len == 0:
      return errResult("agent_ask needs a live session context")
    let target = toolArgs{"session"}.getStr("")
    let question = toolArgs{"question"}.getStr("")
    if target.len == 0 or question.len == 0:
      return errResult("agent_ask needs session and question")
    # Authorization fail-closed, identical to agent_run's continuation path:
    # the durable lineage relation, and a closed child refuses.
    let cont = continuable(target, parentSession)
    if not cont.ok:
      return errResult(cont.error, extra = %*{"sessionId": target})
    if wasCancelled(parentSession):
      return errResult("cancelled by request")
    # A mid-turn child cannot start a new turn (turns never nest) — queue
    # the question as mail for its next turn instead of pretending to ask.
    if busyChild(target):
      var record = %*{"v": 1, "direction": "parent-mail",
                      "from": parentSession, "child": target,
                      "text": question, "createdAt": epochTime()}
      var seq = 0
      try:
        for item in c.storeList("agentnotice", target & ":", 1000, 10_000):
          let id = item.id
          let dot = id.rfind(':')
          if dot >= 0:
            try: seq = max(seq, parseInt(id[dot + 1 .. ^1]))
            except ValueError: discard
        inc seq
        discard c.storePut("agentnotice",
                           target & ":" & align($seq, 6, '0'), record,
                           timeoutMs = 10_000)
      except CatchableError as e:
        return errResult("cannot queue the question (store unreachable): " & e.msg)
      return okResult(%*{"queued": true, "sessionId": target,
                         "deliveredVia": "next-turn",
                         "guidance": "the child is mid-turn; the question " &
                           "was queued for its next turn — its answer " &
                           "arrives with that turn's result"})
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(300_000)
    let env = callEnvelope("session",
      childSessArgs(target, question, "", "", nil, fresh = false),
      originalCaller(toolArgs))
    let resp = requestChildTurn(c, cont.subject, env, timeoutMs,
                                parentSession, target)
    if resp.kind == ekError:
      return errResult(resp.error{"message"}.getStr("subagent failed"),
                       extra = %*{"sessionId": target})
    let turnError = resp.args{"turnError"}.getStr("")
    if turnError.len > 0:
      return errResult(turnError, extra = %*{"sessionId": target})
    return okResult(%*{"sessionId": target,
                       "answer": resp.args{"reply"}.getStr(""),
                       "activation": %cont.activation,
                       "asked": %true}))

let noticesSchema = toolSchema(%*{
  "session": {"type": "string",
               "description": "Conversation to drain (defaults to the calling one)"},
  "peek": {"type": "boolean",
            "description": "Report pending notices without marking them delivered"}
}, description = "Drain the pending settlement notices for a conversation: one entry per background child that finished, was stopped, or failed. Each entry carries jobId, the child session id, a bounded summary of the child's final reply, how many bytes the full reply has, and where to get the rest (agent_status {jobId}). Notices are delivered automatically while your turn is running; this drains the ones that arrived while you were idle. Draining marks them delivered — pass peek to look without consuming.")
noticesSchema["x-harness"] = %*{"onDemand": true, "sessionId": true}
discard comp.tool("agent_notices", noticesSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    var target = toolArgs{"session"}.getStr("")
    if target.len == 0:
      target = toolArgs{"__session"}{"session"}.getStr("")
    if target.len == 0:
      return errResult("agent_notices needs a session (no live session context)")
    let peek = toolArgs{"peek"}.getBool(false)
    var pending = newJArray()
    try:
      for item in c.storeList("agentnotice", target & ":", 1000, 10_000):
        let value = item.value
        if value{"deliveredAt"} != nil: continue
        pending.add(value)
        if peek: continue
        var delivered = value
        delivered["deliveredAt"] = %epochTime()
        delivered["deliveredVia"] = %"pull"
        try:
          discard c.storePut("agentnotice", item.id, delivered,
                             timeoutMs = 10_000)
        except CatchableError:
          # cannot mark it: report it anyway rather than hiding it, and let
          # the next drain try again (at-least-once, never silently lost)
          discard
      return okResult(%*{"session": target, "notices": pending,
                         "count": pending.len, "peek": peek})
    except CatchableError as e:
      return errResult("cannot read notices (store unreachable): " & e.msg))

# --- the roster -------------------------------------------------------------
# agent_list derives the caller's children from the DURABLE relation
# (sessionmeta.parent) joined with their job records — nothing new is stored,
# so continuation and fork add no roster state. Design:
# docs/research/SUBAGENTS-PLAN.md P0.2.

proc liveRunnerSet(c: Component): HashSet[string] =
  ## The sanitized ids of every live session runner, in ONE catalog read.
  ## Returned empty on any failure: every child then reads as not-resident,
  ## which is honest (a missing runner cannot be steered) and never blocks
  ## the listing.
  try:
    let snap = c.request("core", "catalog", %*{"op": "components"}, 10_000)
    let comps = snap{"components"}
    if comps == nil or comps.kind != JObject: return
    for name in comps.keys:
      if name.startsWith("session-"):
        result.incl(name["session-".len .. ^1])
  except CatchableError:
    discard

let listSchema = toolSchema(%*{
  "scope": {"type": "string",
            "description": "children (default) lists direct children only; descendants walks the whole tree below you",
            "enum": ["children", "descendants"]}
}, description = "List your subagent children by durable session id, with what each is doing. Entries carry the child session id, its status, the jobId of its last activation, and the task it was given. Status is running (working right now), idle (resident between turns), or ready (exists in storage only — resumable, NOT finished and not a result waiting to be collected). Use it to remember which children you started and to decide how to reach one: agent_steer for a running turn, agent_wait/agent_status for a job's result, agent_spawn/agent_run with session to give it more work. You are told when a child settles (see the settlement notices), so this is for orientation, not for polling.")
listSchema["x-harness"] = %*{"onDemand": true, "sessionId": true}
discard comp.tool("agent_list", listSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let caller = toolArgs{"__session"}{"session"}.getStr("")
    if caller.len == 0:
      return errResult("agent_list needs a live session context")
    let wantDescendants = toolArgs{"scope"}.getStr("children") == "descendants"
    var metas: seq[JsonNode]
    var readError = ""
    try:
      for item in c.storeListAll("sessionmeta", "", 1000, 10_000):
        metas.add(%*{"id": item.id, "value": item.value})
    except CatchableError as e:
      readError = e.msg
    if readError.len > 0:
      return errResult("cannot list children (store unreachable): " &
                       readError)
    # childrenByParent: parent session id -> its children's session ids.
    var childrenByParent = initTable[string, seq[string]]()
    for m in metas:
      let parent = m{"value"}{"parent"}.getStr("")
      if parent.len == 0: continue
      childrenByParent.mgetOrPut(parent, @[]).add(m{"id"}.getStr(""))
    # Walk from the caller. `descendants` recurses; `children` is depth 1.
    # Depth is bounded by construction (a cycle would need a self-parent
    # record, which the lineage write cannot produce), but walk with a seen
    # set anyway so a hand-edited store cannot hang the component.
    var rows = newJArray()
    var seen = initHashSet[string]()
    var frontier = @[caller]
    var depth = 0
    while frontier.len > 0:
      inc depth
      var next: seq[string]
      for parent in frontier:
        for child in childrenByParent.getOrDefault(parent, @[]):
          if child in seen: continue
          seen.incl(child)
          rows.add(%*{"sessionId": child, "parent": parent, "depth": depth})
          if wantDescendants: next.add(child)
      frontier = next
    # Join the live-runner view ONCE for the whole listing.
    let live = liveRunnerSet(c)
    # Join each child's most recent activation. The jobId is the agentjob
    # record's ID, not a field inside its value — carry both.
    var lastJob = initTable[string, tuple[id: string, value: JsonNode]]()
    try:
      for item in c.storeList("agentjob", "", 1000, 10_000):
        let child = item.value{"sessionId"}.getStr("")
        if child.len == 0: continue
        let at = item.value{"startedAt"}.getFloat(0)
        if not lastJob.hasKey(child) or
            lastJob[child].value{"startedAt"}.getFloat(0) <= at:
          lastJob[child] = (id: item.id, value: item.value)
    except CatchableError:
      discard  # status falls back to ready; the roster still lists
    var listing = newJArray()
    for row in rows:
      let child = row{"sessionId"}.getStr("")
      var entry = %*{"sessionId": child, "parent": row{"parent"},
                     "depth": row{"depth"}}
      # Status is derived from residency + the last activation's outcome.
      # `ready` means STORAGE ONLY (resumable), never terminal — the wording
      # matters, because a parent choosing between verbs must not read it as
      # "this child is finished".
      if lastJob.hasKey(child):
        let (jobId, job) = lastJob[child]
        entry["jobId"] = %jobId
        if job{"status"} != nil: entry["lastStatus"] = job{"status"}
        if job{"task"} != nil: entry["task"] = job{"task"}
      if child in liveTurns:
        entry["status"] = %"running"
      elif sanitizeSessionId(child) in live:
        entry["status"] = %"idle"
      else:
        entry["status"] = %"ready"
      listing.add(entry)
    let scopeName = if wantDescendants: "descendants" else: "children"
    return okResult(%*{"scope": scopeName, "children": listing,
                       "count": listing.len}))

# Terminal job recording: the runner replies on the job's reply inbox; this
# tap is the single writer of the terminal state, so status lookups and
# waits see the same durable record no matter when they run.
discard comp.tap("_INBOX.agentjob.>",
  proc(c: Component, subject: string, data: string) =
    let parts = subject.split('.')
    if parts.len < 3: return
    let jobId = parts[2]
    let r = decode(data)
    if r.kind notin {ekResult, ekError}: return
    var status = "done"
    let turnError = if r.kind == ekError:
                      r.error{"message"}.getStr("child session failed")
                    else: r.args{"turnError"}.getStr("")
    if turnError.len > 0: status = "failed"
    var value = %*{"sessionId": r.args{"sessionId"}.getStr(""),
                   "status": status,
                   "endedAt": epochTime()}
    if turnError.len > 0:
      value["error"] = %turnError
    else:
      value["reply"] = %r.args{"reply"}.getStr("")
    var prior: JsonNode = nil
    try:
      # preserve spawn-time fields and honor a stop request: any terminal
      # state while a stop was requested reads "stopped" — the turn may end
      # via llm.cancel (an error) or between rounds (clean), and the reply,
      # if one was produced, is kept either way
      try:
        prior = c.storeGet("agentjob", jobId, 10_000).value
      except CatchableError:
        prior = nil
      if prior != nil:
        # never embed a possibly-nil JsonNode in value (SIGSEGVs at toUgly)
        if prior{"sessionId"} != nil:
          value["sessionId"] = prior{"sessionId"}
        value["parent"] = prior{"parent"}
        value["task"] = prior{"task"}
        value["startedAt"] = prior{"startedAt"}
        # never embed a possibly-nil JsonNode in %* (SIGSEGVs at toUgly)
        if prior{"budgetMs"} != nil:
          value["budgetMs"] = prior{"budgetMs"}
        # continuation lineage and a queued close survive terminalization:
        # the record is rebuilt here, so anything the spawn wrote that the
        # status surface must keep has to be carried over explicitly
        if prior{"continued"} != nil:
          value["continued"] = prior{"continued"}
        if prior{"activation"} != nil:
          value["activation"] = prior{"activation"}
        if prior{"status"}.getStr("") == "stopping":
          value["status"] = %"stopped"
      discard c.storePut("agentjob", jobId, value, timeoutMs = 10_000)
    except CatchableError:
      discard  # the durable record stays "running"; status reports it
    # A close queued on the job (agent_spawn {close: true}) is applied HERE,
    # after the child's turn has fully settled: the parent cannot mark the
    # child closed before the work it queued has run. Best effort — a lost
    # race (a continuation slipped in between turn end and this write) just
    # means the child stays continuable; nothing is corrupted.
    if prior != nil and prior{"close"}.getBool(false):
      let child = value{"sessionId"}.getStr("")
      if child.len > 0:
        try:
          var meta = c.storeGet("sessionmeta", child, 10_000).value
          if meta != nil:
            meta["closed"] = %true
            discard c.storePut("sessionmeta", child, meta, timeoutMs = 10_000)
        except CatchableError:
          discard
    # The notice is written outside the storePut's try: a notice failure or
    # a store hiccup while recording the job must not suppress the event,
    # and emitNotice is itself best-effort (it never raises). The parent is
    # only known once `prior` was read, so a job whose record vanished
    # before its completion tap produces an event but no notice.
    if value{"parent"}.getStr("").len > 0:
      emitNotice(c, jobId, value{"parent"}.getStr(""),
                 value{"sessionId"}.getStr(""),
                 value{"status"}.getStr(""), value{"reply"}.getStr(""))
    c.emit("ev.agent.done", %*{"jobId": jobId,
                                "sessionId": value{"sessionId"},
                                "status": value{"status"}}))

discard comp.tap("ev.session.turn",
  proc(c: Component, subject: string, data: string) =
    ## Track which sessions hold a live turn, so a settlement notice can pick
    ## the steer lane when the parent is mid-turn. Observe-only and
    ## best-effort: this tap must never affect a turn.
    var env: Envelope
    try:
      env = decode(data)
    except CatchableError:
      return
    if env.kind != ekEvent or env.payload == nil: return
    let sessionId = env.payload{"sessionId"}.getStr("")
    if sessionId.len == 0: return
    case env.payload{"phase"}.getStr("")
    of "start": liveTurns.incl(sessionId)
    of "done": liveTurns.excl(sessionId)
    else: discard)

reconcileAll()
comp.run()
