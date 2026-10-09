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
## State is a store document, not a process global: core may supervise several
## replicas and a restarted lock table must keep the leases it handed out. The
## store's rev-based put is the single-writer arbitration; a lost race simply
## re-reads and re-evaluates.

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
const storeId = "table"

var comp = newComponent("locks", "0.1.0")

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

proc loadTable(c: Component): seq[Lease] =
  try:
    let item = c.storeGet(storeKind, storeId, 5_000)
    if item.value == nil: return @[]
    let v = item.value{"leases"}
    if v == nil or v.kind != JArray: return @[]
    for e in v: result.add(leaseFromJson(e))
  except StoreNotFoundError:
    discard
  except CatchableError:
    discard

proc sweep(leases: seq[Lease], now: float): seq[Lease] =
  for l in leases:
    if live(l, now): result.add(l)

proc saveTable(c: Component, leases: seq[Lease]): bool =
  var arr = newJArray()
  for l in leases: arr.add(toJson(l))
  let doc = %*{"v": 1, "leases": arr, "updatedAt": epochTime()}
  try:
    let rev = c.storePut(storeKind, storeId, doc, timeoutMs = 5_000)
    result = rev >= 0
  except CatchableError:
    result = false

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
  var leases = sweep(loadTable(c), now)
  let holder = holderOf(leases, stripes, sessionId, callId)
  if holder.leaseId.len > 0:
    return %*{"ok": false, "busy": true,
              "holder": holder.sessionId, "holderTool": holder.tool,
              "error": denial(paths, holder, now)}

  # Drop any prior lease for this exact call (a re-dispatch of the same call
  # id must not accumulate duplicates), then record ours.
  let leaseId = leaseIdFor(sessionId, callId)
  var kept: seq[Lease]
  for l in leases:
    if l.leaseId != leaseId: kept.add(l)
  let ttl = if args{"ttlMs"}.getInt(0) > 0: args{"ttlMs"}.getInt(defaultTtlMs())
            else: defaultTtlMs()
  kept.add(Lease(leaseId: leaseId, sessionId: sessionId, tool: tool,
                 callId: callId, stripes: stripes, root: normalize(root),
                 acquiredAt: now, ttlMs: ttl))
  if not saveTable(c, kept):
    return %*{"ok": false, "error":
      "lock store unreachable — refusing the write rather than guarding nothing"}
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
  %*{"effect": "write", "timeoutMs": 10000})

proc hLockRelease(c: Component, args: JsonNode): JsonNode =
  ## Release the lease a call holds. Idempotent: releasing an unknown or already
  ## expired lease is a success (the caller is done either way), so a retry of a
  ## release never fails a turn.
  let sessionId = args{"sessionId"}.getStr("")
  let callId = args{"callId"}.getStr("")
  let leaseId = args{"leaseId"}.getStr("")
  let now = epochTime()
  let key = if leaseId.len > 0: leaseId else: leaseIdFor(sessionId, callId)
  var kept: seq[Lease]
  var removed = 0
  for l in sweep(loadTable(c), now):
    if l.leaseId == key:
      inc removed
    else:
      kept.add(l)
  if removed > 0:
    discard saveTable(c, kept)
  %*{"ok": true, "released": removed}

proc hLockStatus(c: Component, args: JsonNode): JsonNode =
  ## Live leases after a sweep. Sweeping on read is deliberate: an operator
  ## asking "who holds this?" should not see a dead runner's expired claim.
  let now = epochTime()
  let only = args{"sessionId"}.getStr("")
  let leases = sweep(loadTable(c), now)
  var arr = newJArray()
  var n = 0
  for l in leases:
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
  %*{"effect": "write", "timeoutMs": 10000})

discard comp.tool("lock_status", toolSchema(%*{
  "sessionId": {"type": "string",
                "description": "Optional: only leases held by this conversation"}
}, @[],
  "List live write leases (expired ones are swept first): paths, holder, tool, age. Read-only; for diagnosing a refusal or an orphaned claim."), hLockStatus,
  %*{"effect": "read", "timeoutMs": 10000})

comp.run()