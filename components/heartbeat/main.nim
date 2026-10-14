## heartbeat component — scheduled turns for conversations nobody is driving
## (docs/research/FLEET.md §7).
##
## A heartbeat is a durable record (store kind "heartbeat") naming a
## conversation, a prompt and an interval. On its due time this component asks
## the system to run one turn in that conversation, through the same `session`
## call any client uses. That is the whole mechanism: no new wire, no new lane
## in the runner beyond the marker below, and the resulting turn is an ordinary
## conversation turn with a durable transcript.
##
## Why a component and not core work: it is optional (a harness that wants no
## scheduled turns pays nothing), it is per-instance and local — which is what
## makes it the right trigger for a resident agent on one machine — and the
## agent can write, replace or remove it like any other component.
##
## Why not the wake lane: a wake is admitted only when notices are pending and
## is bounded by NIF_AGENT_WAKES, so it can neither carry a heartbeat (nothing
## is ever pending for one) nor should it (the wake budget exists to stop
## runaway autonomous turns). Heartbeats ride their own marker — the runner
## treats `notice.kind: "heartbeat"` as runtime machinery, exactly like a
## wake, but budgets it per record instead of per conversation.
##
## Admission, in order:
##   * the record must be due and enabled;
##   * its per-day turn budget must not be spent (checked here AND in the
##     runner, so a hand-edited record cannot punch through);
##   * the conversation must not be mid-turn — a heartbeat SKIPS rather than
##     queues, because a scheduled turn must never sit behind a human's turn;
##   * NIF_HEARTBEAT=0 disables the whole component's ticking.
##
## Nothing is persisted when a heartbeat is not admitted: the record keeps its
## `nextAt` and the tick tries again after its retry interval.

import std/[json, os, sets, strutils, times]
import niffler/sdk
import subjects   # sanitizeSessionId: the steer/turn lanes are per conversation

let comp = newComponent("heartbeat", "0.1.0")

const
  defaultTickMs = 30_000       ## how often the idle seam looks for due records
  retrySecs = 300.0            ## a skipped/failed heartbeat retries this soon
  minIntervalSecs = 10.0       ## refuse a record that would spin
  maxPromptBytes = 8_192

proc tickMs(): int =
  ## The idle-seam period. A heartbeat's own granularity is its interval, so
  ## this only decides how late one may start; tests set it small.
  try:
    let v = parseInt(getEnv("NIF_HEARTBEAT_TICK_MS", $defaultTickMs))
    if v >= 100: return v
  except ValueError: discard
  defaultTickMs

proc tickingEnabled(): bool =
  ## NIF_HEARTBEAT=0 turns the whole component dormant: records stay intact and
  ## a restart re-enables it, which is what makes this a pause and not a
  ## delete.
  getEnv("NIF_HEARTBEAT", "1") != "0"

proc maxPerDay(): int =
  try:
    let v = parseInt(getEnv("NIF_HEARTBEAT_MAX_PER_DAY", "4"))
    if v >= 0: return v
  except ValueError: discard
  4

proc intervalOf(doc: JsonNode): float =
  ## A record's interval in seconds; 0 when unusable.
  try:
    result = doc{"intervalSec"}.getFloat(0.0)
  except CatchableError:
    result = 0.0
  if result <= 0.0:
    # A little forgiveness for hand-written records: minutes are the natural
    # unit a human writes when they mean "every 15 minutes".
    try:
      result = doc{"intervalMin"}.getFloat(0.0) * 60.0
    except CatchableError:
      result = 0.0

proc due(doc: JsonNode, now: float): bool =
  if not doc{"enabled"}.getBool(true): return false
  if intervalOf(doc) < minIntervalSecs: return false
  let nextAt = doc{"nextAt"}.getFloat(0.0)
  # A record with no nextAt is due now: a newly written heartbeat runs once
  # immediately so its author sees it work, then settles into its interval.
  nextAt <= 0.0 or now >= nextAt

proc turnsSince(doc: JsonNode, now: float): int =
  ## How many turns this record has run in the last 24h, derived from the
  ## durable start times it keeps — no counter to lose across a restart.
  let starts = doc{"starts"}
  if starts == nil or starts.kind != JArray: return 0
  for s in starts:
    let at = s.getFloat(0.0)
    if at > 0.0 and now - at < 86_400.0: inc result

proc withStart(doc: var JsonNode, now: float) =
  ## Record the turn we are about to start, keeping only the last day's worth.
  var kept = newJArray()
  let starts = doc{"starts"}
  if starts != nil and starts.kind == JArray:
    for s in starts:
      let at = s.getFloat(0.0)
      if at > 0.0 and now - at < 86_400.0: kept.add(%at)
  kept.add(%now)
  doc["starts"] = kept
  doc["lastAt"] = %now

var liveTurns = initHashSet[string]()
  ## Sessions whose runner is mid-turn, maintained by the ev.session.*.turn tap.
  ## The same mechanism components/agent uses to decide its steer lane; a stale
  ## entry costs a deferred heartbeat (retried next tick), never a lost one.

proc conversationMidTurn(c: Component, session: string): bool =
  ## Best-effort live-turn hint from events, checked against runner residency.
  ## The runner's busy gate remains authoritative when events were missed.
  try:
    let snap = c.request("core", "catalog", %*{"op": "components"}, 5_000)
    let comps = snap{"components"}
    if comps == nil or comps.kind != JObject: return false
    let key = "session-" & sanitizeSessionId(session)
    if comps{key} == nil: return false
    # The catalog knows the runner exists; turn state comes from the event tap
    # below, which is cheaper and race-free compared with asking per record.
    return session in liveTurns
  except CatchableError:
    # Unreadable catalog: assume busy, so a scheduled turn is skipped rather
    # than published into a runner that may refuse it loudly.
    return true

proc fire(c: Component, id: string, doc: JsonNode): bool =
  ## Publish one heartbeat turn. Returns whether it was admitted here; the
  ## runner re-checks and may still decline, which is reported in its own
  ## result (a decline persists nothing, so the record is simply retried).
  let session = doc{"session"}.getStr("")
  let prompt = doc{"prompt"}.getStr("")
  if session.len == 0 or prompt.len == 0: return false
  if prompt.len > maxPromptBytes: return false
  var args = %*{"sessionId": session, "content": prompt,
                "notice": {"kind": "heartbeat", "id": id}}
  for field in ["provider", "model", "thinking", "cwd", "agent"]:
    let v = doc{field}.getStr("")
    if v.len > 0: args[field] = %v
  try:
    comp.publishCall("svc.core.call", callEnvelope("session", args, c.name))
    return true
  except CatchableError as e:
    stderr.writeLine("heartbeat: cannot publish " & id & ": " & e.msg)
    return false

proc tick(c: Component) =
  let now = epochTime()
  var records: seq[StoreItem]
  try:
    records = c.storeListAll("heartbeat", "", 1000, 10_000)
  except CatchableError:
    return  # store unreachable: nothing to do, try again next tick
  for item in records:
    var doc = item.value
    if doc == nil or doc.kind != JObject: continue
    let id = item.id
    if id.len == 0 or not due(doc, now): continue
    if turnsSince(doc, now) >= maxPerDay():
      # Budget spent: push the next attempt past the window instead of
      # re-deciding every tick, and say so in the record the human reads.
      doc["nextAt"] = %(now + intervalOf(doc))
      doc["lastResult"] = %"skipped: daily budget spent"
      try: discard c.storePut("heartbeat", id, doc, timeoutMs = 5_000)
      except CatchableError: discard
      continue
    let session = doc{"session"}.getStr("")
    if session.len == 0:
      doc["nextAt"] = %(now + retrySecs)
      doc["lastResult"] = %"error: record names no conversation"
      try: discard c.storePut("heartbeat", id, doc, timeoutMs = 5_000)
      except CatchableError: discard
      continue
    if conversationMidTurn(c, session):
      # Skip, never queue: the human's turn owns the conversation until it
      # ends, and a scheduled turn must not appear in their stream afterwards.
      doc["nextAt"] = %(now + retrySecs)
      doc["lastResult"] = %"skipped: conversation busy"
      try: discard c.storePut("heartbeat", id, doc, timeoutMs = 5_000)
      except CatchableError: discard
      continue
    # Reserve before publication. A crash after this write may lose a tick,
    # but cannot produce a retry storm or spend unaccounted inference.
    withStart(doc, now)
    doc["nextAt"] = %(now + intervalOf(doc))
    doc["lastResult"] = %"dispatch attempted (result not tracked)"
    try:
      discard c.storePut("heartbeat", id, doc, expectRev = item.rev, timeoutMs = 5_000)
    except CatchableError:
      continue
    discard fire(c, id, doc)

# --- tool surface ----------------------------------------------------------
# Admin tools for records, plus the read-only listing a UI or a resident agent
# uses to see what is scheduled.

let setSchema = toolSchema(%*{
  "id": {"type": "string", "description": "Record id (stable; reuse to edit)"},
  "session": {"type": "string", "description": "Conversation the heartbeat runs in"},
  "prompt": {"type": "string", "description": "What the turn should do, phrased as a user message"},
  "intervalSec": {"type": "number", "description": "Seconds between turns (minimum 10)"},
  "intervalMin": {"type": "number", "description": "Interval in minutes (alternative to intervalSec)"},
  "enabled": {"type": "boolean", "description": "false parks the record without deleting it"},
  "provider": {"type": "string"}, "model": {"type": "string"},
  "thinking": {"type": "string"}, "cwd": {"type": "string"},
  "agent": {"type": "string", "description": "Agent definition for the conversation when the heartbeat births it"}
}, required = @["id", "session", "prompt"],
   description = "Create or replace a heartbeat: a turn this conversation runs on a schedule, even when nobody is attached. Requires intervalSec or intervalMin. A turn that lands while the conversation is mid-turn is SKIPPED (never queued) and retried; per-day budget NIF_HEARTBEAT_MAX_PER_DAY. Turns run with the conversation's own approvals, so on an unattended machine the gate still denies anything the human never allowed.")
setSchema["x-harness"] = %*{"timeoutMs": 15_000, "onDemand": true, "approval": "always"}
discard comp.tool("heartbeat_set", setSchema,
  proc(c: Component, args: JsonNode): JsonNode =
    let id = args{"id"}.getStr("").strip()
    let session = args{"session"}.getStr("").strip()
    let prompt = args{"prompt"}.getStr("")
    if id.len == 0 or id.len > 64: return errResult("heartbeat_set needs id (1..64 chars)")
    for ch in id:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
        return errResult("heartbeat id must be letters, digits, - _ or .")
    if session.len == 0: return errResult("heartbeat_set needs session")
    if prompt.strip().len == 0: return errResult("heartbeat_set needs prompt")
    if prompt.len > maxPromptBytes: return errResult("prompt too long")
    var doc = newJObject()
    try:
      let existing = c.storeGet("heartbeat", id)
      if existing.value != nil and existing.value.kind == JObject:
        doc = existing.value
    except CatchableError:
      discard
    doc["id"] = %id
    doc["session"] = %session
    doc["prompt"] = %prompt
    if args.hasKey("intervalSec"): doc["intervalSec"] = args{"intervalSec"}
    if args.hasKey("intervalMin"): doc["intervalMin"] = args{"intervalMin"}
    if intervalOf(doc) < minIntervalSecs:
      return errResult("heartbeat_set needs intervalSec >= " & $int(minIntervalSecs) &
                       " or intervalMin")
    doc["enabled"] = %args{"enabled"}.getBool(true)
    for field in ["provider", "model", "thinking", "cwd", "agent"]:
      if args.hasKey(field): doc[field] = args{field}
    doc["updatedAt"] = %epochTime()
    if doc{"nextAt"}.getFloat(0.0) <= 0.0:
      # A new (or re-armed) record runs once soon, so its author sees it work
      # instead of waiting out a whole interval to learn it is wrong.
      doc["nextAt"] = %(epochTime() + min(intervalOf(doc), 60.0))
    try:
      discard c.storePut("heartbeat", id, doc, timeoutMs = 10_000)
    except CatchableError as e:
      return errResult("cannot store heartbeat: " & e.msg)
    return okResult(%*{"id": id, "session": session,
                       "intervalSec": intervalOf(doc),
                       "nextAt": doc{"nextAt"}.getFloat(0.0)})
  )

let rmSchema = toolSchema(%*{
  "id": {"type": "string", "description": "Record id to remove"}
}, required = @["id"], description = "Remove a heartbeat record. The conversation and its transcript are untouched; only the schedule goes away.")
rmSchema["x-harness"] = %*{"timeoutMs": 15_000, "onDemand": true, "approval": "always"}
discard comp.tool("heartbeat_remove", rmSchema,
  proc(c: Component, args: JsonNode): JsonNode =
    let id = args{"id"}.getStr("").strip()
    if id.len == 0: return errResult("heartbeat_remove needs id")
    try:
      c.storeDel("heartbeat", id, 10_000)
    except CatchableError as e:
      return errResult("cannot remove heartbeat: " & e.msg)
    okResult(%*{"id": id, "removed": true})
  )

let listSchema = toolSchema(%*{
  "session": {"type": "string", "description": "Only records for this conversation"}
}, required = @[],
   description = "List heartbeat records with their interval, next run and last outcome — what this instance will do on its own, and when. Read-only.")
listSchema["x-harness"] = %*{"timeoutMs": 15_000, "onDemand": true, "effect": "read"}
discard comp.tool("heartbeat_list", listSchema,
  proc(c: Component, args: JsonNode): JsonNode =
    let want = args{"session"}.getStr("")
    var items = newJArray()
    let now = epochTime()
    try:
      for item in c.storeListAll("heartbeat", "", 1000, 10_000):
        let doc = item.value
        if doc == nil: continue
        if want.len > 0 and doc{"session"}.getStr("") != want: continue
        var row = %*{"id": item.id, "session": doc{"session"},
                     "enabled": doc{"enabled"}.getBool(true),
                     "intervalSec": intervalOf(doc),
                     "nextAt": doc{"nextAt"}.getFloat(0.0),
                     "due": due(doc, now),
                     "turnsToday": turnsSince(doc, now),
                     "maxPerDay": maxPerDay()}
        if doc{"lastAt"} != nil: row["lastAt"] = doc{"lastAt"}
        if doc{"lastResult"} != nil: row["lastResult"] = doc{"lastResult"}
        for field in ["provider", "model", "thinking", "cwd", "agent"]:
          if doc{field} != nil: row[field] = doc{field}
        items.add(row)
    except CatchableError as e:
      return errResult("cannot read heartbeats: " & e.msg)
    okResult(%*{"heartbeats": items, "count": items.len, "ticking": tickingEnabled()})
  )

# --- the seam --------------------------------------------------------------

# The turn tap feeds liveTurns; the idle seam fires the schedule. Both are the
# SDK's own single-threaded pump, so no lock is needed and a tick can never
# overlap a handler.
discard comp.tap("ev.session.*.turn",
  proc(c: Component, subject: string, data: string) =
    ## Track which conversations hold a live turn, so a due heartbeat can skip
    ## rather than publish into a runner that would refuse it. Observe-only and
    ## best-effort: this tap must never affect a turn. Same mechanism
    ## components/agent uses to choose its steer lane.
    var env: Envelope
    try:
      env = decode(data)
    except CatchableError:
      return
    if env.kind != ekEvent or env.payload == nil: return
    let session = env.payload{"sessionId"}.getStr("")
    if session.len == 0: return
    case env.payload{"phase"}.getStr("")
    of "start": liveTurns.incl(session)
    of "done": liveTurns.excl(session)
    else: discard)

let tickInterval = tickMs()
discard comp.onIdle(tickInterval) do (c: Component):
  if not tickingEnabled(): return
  tick(c)

echo "heartbeat: ticking every " & $tickInterval & "ms (NIF_HEARTBEAT=0 pauses)"
comp.run()
