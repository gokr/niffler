## locks — write arbitration for concurrent writers (docs/research/WRITE-ARBITRATION.md).
##
## Why this exists: several conversations can share one workspace, parallel
## dispatch is shipped, and core/workspace.nim declares a working *set* (the
## primary plus its git worktrees and same-origin sibling checkouts). Nothing
## owned a file, so two session runners could edit one path and the only
## artifact of the collision was whichever write landed last — silently.
##
## This component is the owner. It holds a table of path-stripe **leases** and
## answers two questions over the bus: `lock_acquire` (may this call write
## these paths?) and `lock_release`. Core's dispatch gate does the asking via
## the data-only `x-harness.writes` declaration (core knows no component
## names); a path-bound writer names its file arguments, an opaque writer
## (`bash`, `builder`, …) claims its whole root.
##
## Design rules this file holds to:
## - **Leases, not locks.** Every claim carries a TTL, so a killed runner
##   cannot wedge a workspace forever; expired leases are swept on every call.
## - **Stripes are hierarchies.** A claim takes the ancestor stripes of each
##   path plus one exclusive stripe per path, and always in canonical
##   (sorted, ancestor-first) order — two sessions claiming overlapping sets
##   can therefore never deadlock by ordering.
## - **Disjoint stays parallel.** The point of striping is that two
##   conversations editing different files of one repository both proceed.
## - **A denial names the holder.** "E_WRITE_BUSY: <path> is being modified by
##   conversation <id> (edit, 4s ago)" is the difference between a debuggable
##   outcome and a mystery.
## - **Absence is not refusal.** The component being absent means no
##   arbitration (a warning, like repomap absent); the component being present
##   but unreachable is a refusal (core decides that half — see dispatch).
##
## State: the authoritative lease table is **in memory** (one process serves a
## harness; its pump serializes handlers), persisted one document per lease so a
## restarted component rebuilds the table it handed out. Persisting per-lease
## rather than as one blob is deliberate — see the cost table in the design doc.
## Do not set `replicas` on this component: two instances would each hold a
## partial view and arbitration would silently weaken.

import std/[algorithm, json, os, strutils, times]
import niffler/sdk

# ---------------------------------------------------------------------------
# lease table

type
  Lease* = object
    leaseId*: string
    sessionId*: string
    tool*: string
    callId*: string
    ## Canonical stripe list this lease holds: ancestor prefixes first, then
    ## the exclusive path stripes. Overlap is decided by comparing stripes.
    stripes*: seq[string]
    root*: string
    acquiredAt*: float
    ttlMs*: int

const storeKind = "lock-lease"

var comp = newComponent("locks", "0.1.0")

var gLeases: seq[Lease]
  ## The live lease table (see loadTable). Loaded once at boot, then kept in
  ## memory with write-through persistence.
var gLoaded = false

proc defaultTtlMs(): int =
  ## A lease outlives a slow tool call (tool timeouts reach 300s) but not a
  ## dead runner's forgotten claim. Overridable for tests and long benches.
  try: result = parseInt(getEnv("NIF_LOCK_TTL_MS", "600000"))
  except CatchableError: result = 600000

proc leaseFromJson(v: JsonNode): Lease =
  result.leaseId = v{"leaseId"}.getStr("")
  result.sessionId = v{"sessionId"}.getStr("")
  result.tool = v{"tool"}.getStr("")
  result.callId = v{"callId"}.getStr("")
  result.root = v{"root"}.getStr("")
  result.acquiredAt = v{"acquiredAt"}.getFloat(0.0)
  result.ttlMs = v{"ttlMs"}.getInt(defaultTtlMs())
  if v{"stripes"} != nil and v{"stripes"}.kind == JArray:
    for s in v{"stripes"}: result.stripes.add(s.getStr(""))

proc toJson(l: Lease): JsonNode =
  var arr = newJArray()
  for s in l.stripes: arr.add(%s)
  %*{"leaseId": l.leaseId, "sessionId": l.sessionId, "tool": l.tool,
     "callId": l.callId, "root": l.root, "stripes": arr,
     "acquiredAt": l.acquiredAt, "ttlMs": l.ttlMs}

proc live(l: Lease, now: float): bool =
  l.acquiredAt + l.ttlMs.float / 1000.0 > now

# ---------------------------------------------------------------------------
# stripe algebra

proc normalize(p: string): string =
  ## One spelling per path — absolute, symlinks resolved where possible, no
  ## trailing separator — so the same file typed two ways yields one stripe.
  if p.len == 0: return ""
  var q = p
  try: q = expandFilename(absolutePath(q))
  except CatchableError:
    try: q = absolutePath(q)
    except CatchableError: discard
  while q.len > 1 and q[^1] == '/': q.setLen(q.len - 1)
  q

proc underAnyRoot(target: string, roots: openArray[string]): bool =
  ## Workspace fence: a claim only ever covers paths inside the conversation's
  ## declared working set (core/workspace.nim). Outside that, the locks
  ## component has no authority to grant or deny.
  let t = normalize(target)
  if t.len == 0: return false
  for r0 in roots:
    let r = normalize(r0)
    if r.len == 0: continue
    if t == r or t.startsWith(r & "/"): return true
  false

proc stripesFor(paths: openArray[string]): seq[string] =
  ## The exclusive stripes a claim holds: one per requested path. Ancestor
  ## directories are deliberately NOT stripes — they are shared by construction,
  ## so treating them as claims would make two files in one directory conflict
  ## (the whole repository would serialize). Containment is decided at compare
  ## time instead (see overlaps): an opaque writer claims the root as a path,
  ## and that root is a prefix of every file beneath it.
  var s: seq[string]
  for p in paths:
    let n = normalize(p)
    if n.len > 0 and n notin s: s.add(n)
  s.sort()
  s

proc overlaps(a, b: openArray[string]): bool =
  ## Two claims conflict when one exclusive stripe is the other, or one is an
  ## ancestor of the other across a separator boundary. So `/repo` (an opaque
  ## writer's root claim) conflicts with `/repo/src/x.go`, while `/repo/a.go`
  ## and `/repo/b.go` do not conflict — disjoint paths stay parallel.
  for x in a:
    for y in b:
      if x == y: return true
      if x.len < y.len and y.startsWith(x & "/"): return true
      if y.len < x.len and x.startsWith(y & "/"): return true
  false

# ---------------------------------------------------------------------------
# table load / save

proc sweep(leases: seq[Lease], now: float): seq[Lease] =
  for l in leases:
    if live(l, now): result.add(l)

proc loadIndex(c: Component) =
  ## One-time boot load: rebuild the in-memory table from the durable documents
  ## a previous incarnation of this component wrote.
  if gLoaded: return
  # Build a candidate off to the side: a failed page must never publish a
  # partial/empty table or latch the loaded flag. Retry on the next request.
  var recovered: seq[Lease]
  for item in c.storeListAll(storeKind, "", 1000, 10_000):
    if item.value == nil: continue
    if item.id == "table":
      raise newException(IOError,
        "legacy aggregate lock table requires operator migration; refusing writes")
    recovered.add(leaseFromJson(item.value))
  gLeases = recovered
  gLoaded = true

proc loadTable(c: Component): seq[Lease] =
  ## The lease table. In memory, loaded once from the store at boot and
  ## write-through on every change: an acquire must not pay for reading every
  ## other lease (measured: listing 1000 docs was ~49ms, of which the compare
  ## itself is microseconds). The store stays the durable record — a restarted
  ## component rebuilds its index from it — while the runtime authority is this
  ## table, which is safe because exactly one `locks` instance serves a harness
  ## (its pump serializes handlers). **Do not set `replicas` on this component**:
  ## two instances would each hold a partial view and arbitration would silently
  ## weaken. The store documents are the durable record, one per lease.
  loadIndex(c)
  result = gLeases

proc persistLease(c: Component, l: Lease): bool =
  ## Write one lease document (the durable half of an acquire).
  try:
    let rev = c.storePut(storeKind, l.leaseId, toJson(l), timeoutMs = 5_000)
    result = rev >= 0
  except CatchableError:
    result = false

proc forgetLease(c: Component, leaseId: string): bool =
  ## Remove one lease from the index and the store. The store's `del` is
  ## idempotent, so existence is decided by the index — the `released` count is
  ## a diagnostic the contract test reads, and "removes nothing" must stay
  ## distinguishable from "removed one".
  var found = false
  var kept: seq[Lease]
  for l in gLeases:
    if l.leaseId == leaseId: found = true
    else: kept.add(l)
  if not found: return false
  # Persist deletion before removing the runtime claim. On failure retain it:
  # otherwise a restart would resurrect a lease we had reported as released.
  let response = c.request("store", "del",
    %*{"kind": storeKind, "id": leaseId}, 5_000)
  if not response{"ok"}.getBool(false):
    raise newException(IOError, "lock deletion refused by store")
  gLeases = kept
  result = true

proc dropLease(c: Component, leaseId: string): bool =
  ## Kept for the sweep's call shape; forgetLease is the implementation.
  forgetLease(c, leaseId)

proc sweepStale(c: Component, now: float) =
  ## Drop leases whose TTL has passed, from the index and the store. Runs on the
  ## idle tick, so a dead runner's claim is cleaned up without charging every
  ## acquire for it.
  var stale: seq[string]
  for l in gLeases:
    if not live(l, now): stale.add(l.leaseId)
  for id in stale:
    discard forgetLease(c, id)

proc leaseIdFor(sessionId, callId: string): string =
  ## The lease key. Derived, not the bare call id, so the same call re-claiming
  ## replaces its own lease rather than refusing itself.
  if callId.len > 0:
    sessionId & ":" & callId
  else:
    sessionId & ":" & $epochTime()

proc holderOf(leases: seq[Lease], stripes: seq[string],
              sessionId, callId: string): Lease =
  ## The first live lease that conflicts with the request and is not the
  ## caller's own in-flight call. The exclusion key is the derived lease key
  ## (sessionId:callId), not the bare call id, so a re-dispatch of the same
  ## call replaces its own lease instead of refusing itself.
  let own = leaseIdFor(sessionId, callId)
  for l in leases:
    if l.leaseId == own: continue
    if overlaps(l.stripes, stripes): return l

proc denial(paths: openArray[string], h: Lease, now: float): string =
  ## Name the holder. "<path> is being modified by conversation <id>
  ## (edit, 4s ago)" is the difference between a debuggable outcome and a
  ## mystery — the model can wait, narrow, or ask the human.
  let who = if h.sessionId.len > 0: "conversation " & h.sessionId else: "another writer"
  let tool = if h.tool.len > 0: h.tool else: "a tool"
  let age = max(0, int(now - h.acquiredAt))
  "[E_WRITE_BUSY] " & paths[0] & " is being modified by " & who & " (" &
    tool & ", " & $age & "s ago) — retry shortly, or work on a different file"

# ---------------------------------------------------------------------------
# tools

proc hLockAcquire(c: Component, args: JsonNode): JsonNode =
  ## Take (or extend) a write lease for one dispatched call. Denies, naming the
  ## holder, when another live lease overlaps.
  loadIndex(c)
  let now = epochTime()
  let sessionId = args{"sessionId"}.getStr("")
  let tool = args{"tool"}.getStr("")
  let callId = args{"callId"}.getStr("")
  var roots: seq[string]
  if args{"roots"} != nil and args{"roots"}.kind == JArray:
    for r in args{"roots"}: roots.add(r.getStr(""))
  let root = args{"root"}.getStr("")
  if roots.len == 0 and root.len > 0: roots.add(root)
  if roots.len == 0:
    return %*{"ok": false, "error":
      "lock_acquire needs root or roots — a lease only covers the conversation's working set"}

  var paths: seq[string]
  if args{"paths"} != nil and args{"paths"}.kind == JArray:
    for p in args{"paths"}:
      let s = p.getStr("")
      if s.len == 0: continue
      if not underAnyRoot(s, roots):
        # Outside the declared working set: not ours to grant or deny.
        return %*{"ok": false, "error":
          "[E_WRITE_OUTSIDE] " & s & " is outside this conversation's workspace"}
      paths.add(s)
  if paths.len == 0:
    return %*{"ok": false, "error": "lock_acquire needs at least one path"}

  let stripes = stripesFor(paths)
  let leaseId = leaseIdFor(sessionId, callId)
  # A conversation is one serial writer — its runner serves one turn at a time,
  # and writers never share a parallel wave — so a live claim of its OWN over
  # these paths can only be a leftover when it starts a new call: an abandoned
  # wait (the human stopped the tool while it ran, and the dispatch never
  # observed a terminal reply), a runner that died between dispatch and
  # release, or a release that failed on a store hiccup. Left in place it
  # wedges the conversation's own retry for the whole lease lifetime (transport
  # timeout + 60s, minimum 10 minutes) and keeps every other conversation out
  # for a write that is not happening any more.
  #
  # Only claims that OVERLAP this request go: a disjoint claim is not a
  # leftover but a different write, and it stays guarded. Another session's
  # claims are never touched — they still deny below.
  var superseded: seq[string]
  for l in sweep(gLeases, now):
    if l.leaseId != leaseId and l.sessionId == sessionId and
        overlaps(l.stripes, stripes):
      superseded.add(l.leaseId)
  for id in superseded:
    try:
      discard forgetLease(c, id)
    except CatchableError:
      # Store outage: leave it in the table so the conflict check below denies
      # rather than dropping a claim we could not durably delete.
      discard

  # Live leases only: an expired claim is not a holder (the document itself is
  # removed by the idle sweep). The compare is in-memory — the whole table is
  # walked, but on strings, not over the bus.
  let holder = holderOf(sweep(gLeases, now), stripes, sessionId, callId)
  if holder.leaseId.len > 0:
    return %*{"ok": false, "busy": true,
              "holder": holder.sessionId, "holderTool": holder.tool,
              "error": denial(paths, holder, now)}

  let ttl = if args{"ttlMs"}.getInt(0) > 0: args{"ttlMs"}.getInt(defaultTtlMs())
            else: defaultTtlMs()
  let lease = Lease(leaseId: leaseId, sessionId: sessionId, tool: tool,
                    callId: callId, stripes: stripes, root: normalize(root),
                    acquiredAt: now, ttlMs: ttl)
  # Persist FIRST: if the store refuses we have not recorded a lease the caller
  # cannot release later. Then publish to the index in place (same id on a
  # re-dispatch, so a call never accumulates duplicates).
  if not persistLease(c, lease):
    return %*{"ok": false, "error":
      "lock store unreachable — refusing the write rather than guarding nothing"}
  var replaced = false
  for i in 0 ..< gLeases.len:
    if gLeases[i].leaseId == leaseId:
      gLeases[i] = lease
      replaced = true
      break
  if not replaced: gLeases.add(lease)
  %*{"ok": true, "leaseId": leaseId, "stripes": stripes, "ttlMs": ttl}

discard comp.tool("lock_acquire", toolSchema(%*{
  "root": {"type": "string",
           "description": "Conversation workspace root the claim must stay inside (absolute)"},
  "roots": {"type": "array", "items": {"type": "string"},
            "description": "The conversation's whole working set; a claim inside any of these is accepted"},
  "paths": {"type": "array", "items": {"type": "string"},
            "description": "Absolute file paths this call will write"},
  "sessionId": {"type": "string",
                "description": "Conversation id taking the lease"},
  "tool": {"type": "string", "description": "Tool name (for the denial message)"},
  "callId": {"type": "string",
             "description": "The dispatch call id; the lease is keyed by it, and a retry of the same call never refuses itself"},
  "ttlMs": {"type": "integer",
            "description": "Lease lifetime; a dead runner's claim expires (default from NIF_LOCK_TTL_MS)"}
}, @["root", "paths", "sessionId", "tool"],
  "Take a write lease over the given file paths for one dispatched call, so a second conversation cannot mutate them concurrently. Denies with the holder named when another live lease overlaps. Internal to core's dispatch gate — the model never calls this."), hLockAcquire,
  %*{"hidden": true, "effect": "write", "timeoutMs": 10000})

proc hLockRelease(c: Component, args: JsonNode): JsonNode =
  ## Release the lease a call holds. Idempotent: releasing an unknown or already
  ## expired lease is a success (the caller is done either way), so a retry of a
  ## release never fails a turn. Deletes exactly one document — the cost does
  ## not grow with the number of other live leases.
  let sessionId = args{"sessionId"}.getStr("")
  let callId = args{"callId"}.getStr("")
  let leaseId = args{"leaseId"}.getStr("")
  let key = if leaseId.len > 0: leaseId else: leaseIdFor(sessionId, callId)
  loadIndex(c)
  let removed = if dropLease(c, key): 1 else: 0
  %*{"ok": true, "released": removed}

proc hLockStatus(c: Component, args: JsonNode): JsonNode =
  ## Live leases. An expired claim is filtered out here (a dead runner must not
  ## read as a holder); the document itself is removed by the idle sweep, so
  ## this stays a read.
  let now = epochTime()
  let only = args{"sessionId"}.getStr("")
  var arr = newJArray()
  var n = 0
  for l in sweep(loadTable(c), now):
    if only.len > 0 and l.sessionId != only: continue
    arr.add(%*{"leaseId": l.leaseId, "sessionId": l.sessionId,
               "tool": l.tool, "paths": l.stripes,
               "ageSeconds": int(now - l.acquiredAt),
               "ttlMs": l.ttlMs})
    inc n
  %*{"ok": true, "leases": arr, "count": n}

discard comp.tool("lock_release", toolSchema(%*{
  "leaseId": {"type": "string",
              "description": "The lease to release (preferred)"},
  "sessionId": {"type": "string",
                "description": "Conversation id (used to derive the lease key when leaseId is omitted)"},
  "callId": {"type": "string",
             "description": "The dispatch call id that keyed the lease"}
}, @[],
  "Release a write lease taken by lock_acquire. Idempotent — releasing an unknown or already expired lease succeeds, so a retry never fails a turn. Internal to core's dispatch gate."), hLockRelease,
  %*{"hidden": true, "effect": "write", "timeoutMs": 10000})

discard comp.tool("lock_status", toolSchema(%*{
  "sessionId": {"type": "string",
                "description": "Optional: only leases held by this conversation"}
}, @[],
  "List live write leases: paths, holder, tool, age. Read-only; for diagnosing a refusal or an orphaned claim."), hLockStatus,
  %*{"onDemand": true, "effect": "read", "timeoutMs": 10000})

# Stale-lease sweep on the idle tick: a runner that dies mid-call leaves its
# lease behind, and nothing else would ever remove the document. Doing this
# here, rather than inside lock_acquire, keeps the acquire path free of the
# table scan — the measured reason the per-lease table exists at all.
discard comp.onIdle(30_000) do (c: Component):
  try:
    loadIndex(c)
    sweepStale(c, epochTime())
  except CatchableError:
    discard # No caller to answer; retain claims and retry on the next tick.

comp.run()