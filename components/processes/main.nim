## processes component — long-running commands with an owner: start once,
## poll incremental output, kill explicitly.
##
## bash is synchronous by design; servers, watchers and test loops need a
## different contract. process_start spawns the command detached (own
## process group, stdin from /dev/null, stdout/stderr appended to spool
## files under var/processes/), returns an id immediately, and the component
## owns the child for its whole life: process_poll drains output appended
## since the last poll (incremental — never re-injects old bytes), optionally
## waits for new output, filters it, or re-reads the bounded raw tail;
## process_kill terminates the whole group; process_list shows everything.
##
## The bash tool's run_in_background flag is a thin producer: it forwards
## here and returns the id — this component owns the child, the registry and
## the reaping (docs/research/OCTOFRIEND-STEAL.md, "Steal 5 follow-up").
##
## Spool files are the drain buffer: the child writes append-mode to files
## (never a pipe it could deadlock on), the component reads from per-stream
## cursors — no reader thread, no shared memory, the OS absorbs bursts. A
## spool over the cap is truncated to its tail on the next poll with the
## cursor adjusted (O_APPEND writes always land at EOF, so truncation cannot
## create holes). Crash-safe: children are process-group leaders, so a
## SIGKILLed component leaves them running — registry.json (pid + /proc
## starttime to defeat pid reuse) drives a boot sweep that kills orphans
## from a previous life before serving.

import std/[json, monotimes, os, posix, strutils, tables, times]
import std/syncio
import regex
import niffler/sdk
import niffler/configowner
import subjects   # sanitizeSessionId: the notice lane is per conversation

const
  MAX_LIVE = 32                    # concurrent running processes
  KEEP_FINISHED = 50               # finished entries kept in the registry
  POLL_CHUNK = 64 * 1024           # max new bytes returned per stream/poll
  TAIL_BYTES = 64 * 1024           # raw tail readable via tail=true
  SPOOL_CAP = 32 * 1024 * 1024     # truncate a spool beyond this
  SPOOL_KEEP = 2 * 1024 * 1024     # bytes kept when truncating
  WAIT_SLICE_MS = 100              # wait granularity
  MAX_WAIT_MS = 25_000             # wait cap (inside the 30s tool timeout)

## Configuration (docs/research/CONFIG-CONTRACT.md). Both limits are read on
## every call rather than captured at boot, so a stored change takes effect
## without restarting the component — which is what the declaration promises.
let ownerStore* = OwnerStore(kind: "processes-settings", id: "main")
let settings* = newOwnerSnapshot(ownerStore)

proc spoolCap(): int =
  ## A stored value wins, then the environment (the migration path), then the
  ## default. A non-positive value falls back: a zeroed spool cap would empty
  ## every spool on its next poll.
  let stored = settings.num("spoolCap", "", 0)
  if stored > 0: return stored
  let v = getEnv("NIF_PROCESSES_SPOOL_CAP", "")
  if v.len > 0:
    try: return parseInt(v)
    except ValueError: discard
  return SPOOL_CAP

proc pollChunk(): int =
  ## Max new bytes one poll returns per stream, kept below the spool cap so a
  ## burst is always split. Stored value → NIF_PROCESSES_POLL_CHUNK → default,
  ## clamped to the range the schema also publishes.
  let stored = settings.num("pollChunk", "", 0)
  if stored > 0: return clamp(stored, 1024, 1_048_576)
  let v = getEnv("NIF_PROCESSES_POLL_CHUNK", "")
  if v.len > 0:
    try: return clamp(parseInt(v), 1024, 1_048_576)
    except ValueError: discard
  return POLL_CHUNK

type Status = enum
  stRunning, stExited, stKilled, stInterrupted

type Entry = ref object
  id: string
  pid: Pid
  label: string
  command: string
  outPath, errPath: string
  outCursor, errCursor: int        # drain offsets into the spool files
  status: Status
  exitCode: int                    # exit code, or signal number when killed
  startedAt: float
  session: string                  # owning conversation for the exit notice
                                   # ("" = a direct call: nobody to tell)
  notified: bool                   # the exit notice is sent exactly once
  swept: bool                      # terminal statuses left the sweep file
  emptyPollHinted: bool            # one local hint per process; no cursor effect

var gProcs = initOrderedTable[string, Entry]()
var gNextId = 1

proc fail(code, msg: string) {.noreturn.} =
  raise newException(ValueError, "[" & code & "] " & msg)

# ---------------------------------------------------------------------------
# registry persistence — only what the boot sweep needs (pid + starttime)

proc atomicWrite(path, content: string) =
  createDir(path.parentDir())
  let tmp = path.parentDir / (".tmp-" & newId())
  var f = open(tmp, fmWrite)
  f.write(content)
  f.close()
  moveFile(tmp, path)

proc procStarttime(pid: Pid): string =
  ## /proc/<pid>/stat field 22, robust against pid reuse.
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    let rest = stat[stat.rfind(')') + 2 ..^ 1]   # fields from state (3) on
    let f = rest.split(' ')
    if f.len > 19: return f[19]
  except CatchableError:
    discard
  return ""

proc registryPath(): string = rootVarDir("processes") / "registry.json"

proc saveRegistry() =
  ## The sweep file holds only RUNNING entries; terminal ones drop out.
  var entries = newJArray()
  for e in gProcs.values:
    if e.status == stRunning:
      entries.add(%*{"id": e.id, "pid": int(e.pid),
                     "starttime": procStarttime(e.pid), "session": e.session,
                     "label": e.label, "startedAt": e.startedAt})
  atomicWrite(registryPath(), (%*{"nextId": gNextId, "entries": entries}).pretty())

proc bootSweep() =
  ## Kill orphans from a previous component life (children are process-group
  ## leaders — a SIGKILLed component leaves them running), drop stale spool
  ## files, and adopt the id counter.
  let path = registryPath()
  var killed = 0
  if fileExists(path):
    try:
      let doc = parseJson(readFile(path))
      gNextId = doc{"nextId"}.getInt(1)
      for e in doc{"entries"}:
        let pid = Pid(e{"pid"}.getInt(0))
        if pid <= 0: continue
        let want = e{"starttime"}.getStr("")
        if want.len > 0 and procStarttime(pid) == want:
          discard posix.kill(-pid, SIGKILL)   # group kill: the whole tree
          inc killed
        # A missing/reused PID is never signalled. Its previous owner's
        # outcome is unknown, not a fabricated successful exit.
        let session = e{"session"}.getStr("")
        let id = e{"id"}.getStr("")
        if session.len > 0 and id.len > 1 and id[0] == 'p' and
            id[1 .. ^1].allCharsInSet({'0'..'9'}):
          let noticePath = rootVarDir("processes") / "notices" / (id & ".json")
          if not fileExists(noticePath):
            atomicWrite(noticePath, $(%*{"session": session, "delivered": false,
              "notice": {"kind": "process-exited", "processId": id,
                "label": e{"label"}.getStr(""), "status": "interrupted(component restart)",
                "exitCode": -1, "startedAt": e{"startedAt"}.getFloat(),
                "endedAt": epochTime(), "outputBytes": 0}}))
    except CatchableError as e:
      # Do not erase recovery ownership after a failed outbox write.
      raise newException(IOError, "processes: sweep failed: " & e.msg)
  let dir = rootVarDir("processes")
  if dirExists(dir):
    for kind, p in walkDir(dir):
      if kind == pcFile and (p.endsWith(".out") or p.endsWith(".err")):
        # Completion outbox pointers must retain their output across restart.
        let id = p.extractFilename().changeFileExt("")
        if fileExists(dir / "notices" / (id & ".json")): continue
        try: removeFile(p)
        except CatchableError: discard
  if killed > 0:
    stderr.writeLine("processes: boot sweep killed " & $killed &
                     " orphaned process group(s)")
  atomicWrite(path, (%*{"nextId": gNextId, "entries": newJArray()}).pretty())

# ---------------------------------------------------------------------------
# child lifecycle

proc publishExitNotice(e: Entry)
  ## Defined with the component (it publishes); called from the reaper.

proc refreshStatus(e: Entry) =
  ## Reap via WNOHANG; caches the terminal status. A transition to terminal
  ## also tells the owning conversation (publishExitNotice) — this is the only
  ## place a child's death is observed, so it is the only correct place to
  ## speak up.
  if e.status != stRunning: return
  var status: cint
  let r = posix.waitpid(e.pid, status, WNOHANG)
  if r == e.pid:
    if posix.WIFEXITED(status):
      e.status = stExited
      e.exitCode = posix.WEXITSTATUS(status)
    elif posix.WIFSIGNALED(status):
      e.status = stKilled
      e.exitCode = posix.WTERMSIG(status)
  elif r < 0:
    e.status = stExited          # reaped elsewhere / unknown: treat as gone
  if e.status != stRunning:
    publishExitNotice(e)

proc statusText(e: Entry): string =
  case e.status
  of stRunning: "running"
  of stExited: "exited(code " & $e.exitCode & ")"
  of stKilled: "killed(signal " & $e.exitCode & ")"
  of stInterrupted: "interrupted(component restart)"

proc markTerminal(e: Entry) =
  if e.status != stRunning and not e.swept:
    e.swept = true
    saveRegistry()                 # terminal entries leave the sweep file

proc killEntry(e: Entry) =
  ## Graceful group terminate, then escalate. refreshStatus reaps.
  if e.status == stRunning:
    killGroup(e.pid, SIGTERM)
    sleep(300)
    refreshStatus(e)
    if e.status == stRunning:
      killGroup(e.pid, SIGKILL)
      sleep(100)
      refreshStatus(e)
  markTerminal(e)

proc spoolSize(path: string): int =
  try: int(getFileSize(path))
  except CatchableError: 0

proc truncateSpool(path: string, cursor: var int): bool =
  ## Cap a spool file: keep the tail, shift the cursor. Returns true when
  ## truncated. The child's fd is O_APPEND, so writes always land at EOF —
  ## truncation cannot create holes.
  let size = spoolSize(path)
  let cap = spoolCap()
  if size <= cap: return false
  let keep = min(SPOOL_KEEP, cap div 2)   # keep must stay below the cap
  try:
    var f = open(path, fmRead)
    f.setFilePos(max(0, size - keep))
    let tail = f.readAll()
    f.close()
    writeFile(path, tail)
    cursor = max(0, cursor - (size - keep))
    return true
  except CatchableError:
    return false

proc readNew(path: string, cursor: var int): tuple[content: string, truncated: bool] =
  ## New complete lines since the cursor (a trailing partial line waits for
  ## its newline — line-oriented output is the contract; tail=true reads
  ## raw). Bounded per poll; anything beyond stays pending for the next one.
  ## Caps the spool at read time: the child may have written between the
  ## poll's entry and here, so the cap check must see the final size.
  var size = spoolSize(path)
  if size > spoolCap() and truncateSpool(path, cursor):
    result.truncated = true
    # The old size referred to the pre-truncation file. Reading against it
    # can allocate the whole old spool and report bytes that no longer exist.
    size = spoolSize(path)
  if size <= cursor: return
  var f = open(path, fmRead)
  var chunk: string
  try:
    f.setFilePos(cursor)
    chunk = newString(size - cursor)
    let n = readBuffer(f, addr chunk[0], chunk.len)
    chunk.setLen(n)
    f.close()
    let lastNl = chunk.rfind('\n')
    if lastNl < 0: return          # no complete line yet (keeps truncated)
    let chunkCap = pollChunk()
    var take = min(lastNl + 1, chunkCap)
    if take < lastNl + 1:
      # one huge burst: cut at the last newline inside the first chunkCap
      # bytes (the bound is rfind's `last`, not its `start`)
      take = chunk.rfind('\n', 0, chunkCap - 1) + 1
      if take <= 0: take = chunkCap     # pathological single line: raw cut
    cursor += take
    return (chunk[0 ..< take], result.truncated)
  except CatchableError:
    return ("", result.truncated)      # spool vanished: nothing to drain

proc applyFilter(chunk, pattern: string): tuple[matched: string, total, hits: int] =
  ## Projection over the drained chunk: the caller advances the cursor past
  ## everything; here we only select matching lines.
  var compiled: Regex2
  try: compiled = re2(pattern)
  except CatchableError as e:
    fail("E_BAD_SHAPE", "invalid filter regex: " & e.msg)
  var matched: seq[string]
  var total = 0
  for line in chunk.splitLines():
    total += 1
    if contains(line, compiled): matched.add(line)
  let body = if matched.len > 0: matched.join("\n") & "\n" else: ""
  (body, total, matched.len)

# ---------------------------------------------------------------------------
# tools

proc entryOr404(id: string): Entry =
  if not gProcs.hasKey(id) and id.len > 1 and id[0] == 'p' and
      id[1 .. ^1].allCharsInSet({'0'..'9'}):
    let noticePath = rootVarDir("processes") / "notices" / (id & ".json")
    if fileExists(noticePath):
      let record = parseJson(readFile(noticePath))
      let notice = record["notice"]
      gProcs[id] = Entry(id: id, label: notice{"label"}.getStr(""),
        session: record{"session"}.getStr(""),
        status: (if notice{"status"}.getStr("").startsWith("interrupted"): stInterrupted
                 elif notice{"status"}.getStr("").startsWith("killed"): stKilled else: stExited),
        exitCode: notice{"exitCode"}.getInt(),
        startedAt: notice{"startedAt"}.getFloat(), notified: true, swept: true,
        outPath: rootVarDir("processes") / (id & ".out"),
        errPath: rootVarDir("processes") / (id & ".err"))
  if not gProcs.hasKey(id):
    fail("E_NOT_FOUND", "unknown process id '" & id &
         "' — process_list shows the registry")
  result = gProcs[id]

proc hStart(c: Component, args: JsonNode): JsonNode =
  let command = args{"command"}.getStr("")
  if command.len == 0:
    fail("E_BAD_SHAPE", "process_start requires a non-empty \"command\" string")
  var live = 0
  for e in gProcs.values:
    refreshStatus(e)
    if e.status == stRunning: inc live
  if live >= MAX_LIVE:
    fail("E_LIMIT", "too many live background processes (" & $live &
         ") — kill some with process_kill first")
  var label = args{"label"}.getStr("")
  if label.len == 0:
    label = command.split(Whitespace)[0 ..< 1].join(" ")
  if label.len > 80: label = label[0 ..< 80]
  let workdir = args{"workdir"}.getStr("")
  if workdir.len > 0 and not dirExists(workdir):
    fail("E_BAD_SHAPE", "workdir does not exist: " & workdir)

  let id = "p" & $gNextId
  inc gNextId
  let outPath = rootVarDir("processes") / (id & ".out")
  let errPath = rootVarDir("processes") / (id & ".err")
  for p in [outPath, errPath]:
    try: removeFile(p)
    except CatchableError: discard
  # append-mode spools: the child never blocks on a full pipe, and the file
  # is the drain buffer. stdin from /dev/null: headless.
  let close = if command.contains("<<"): "\n" else: " "
  let wrapped = "( " & command & close & ") >> " & quoteShell(outPath) &
                " 2>> " & quoteShell(errPath) & " < /dev/null"
  cloexecInheritedFds()
  let argv = allocCStringArray(["bash", "-c", wrapped])
  defer: deallocCStringArray(argv)
  let pid = posix.fork()
  if pid == 0:
    # child: process-group leader before exec (no kill race), then exec.
    discard posix.setpgid(0, 0)
    if workdir.len > 0:
      let wd = cstring(workdir)
      if posix.chdir(wd) != 0:
        posix.exitnow(126)
    discard posix.execvp("bash", argv)
    posix.exitnow(127)
  if pid < 0:
    fail("E_LIMIT", "fork failed — cannot start background processes")
  let e = Entry(id: id, pid: pid, label: label, command: command,
                outPath: outPath, errPath: errPath, startedAt: epochTime(),
                session: args{"__session"}{"session"}.getStr(
                  args{"session"}.getStr("")))
  gProcs[id] = e
  saveRegistry()
  return okResult(%*{"id": id, "label": label, "pid": int(pid),
    "text": "Started background process " & id & " (" & label & "). " &
            "Discover controls with discover {tools:[\"process_poll\",\"process_kill\"]}. " &
            (if e.session.len > 0:
              "Completion is pushed to this session automatically (bounded wake if idle) — do not poll to wait for it. "
             else:
              "No owning session: automatic completion notification is unavailable. ") &
            "Call process_poll {id:\"" & id & "\"} only when you need its output; each poll " &
            "drains new complete lines, filter keeps matching lines (all new output is still " &
            "drained), and tail:\"1\" re-reads raw recent output without advancing the cursor. " &
            "Stop with process_kill {id:\"" & id & "\"}."})

proc hPoll(c: Component, args: JsonNode): JsonNode =
  let id = args{"id"}.getStr("")
  if id.len == 0:
    fail("E_BAD_SHAPE", "process_poll requires \"id\"")
  let e = entryOr404(id)
  let waitMs = clamp(args{"waitMs"}.getInt(0), 0, MAX_WAIT_MS)
  let filter = args{"filter"}.getStr("")
  let wantTail = args{"tail"}.getStr("").len > 0

  if wantTail:
    refreshStatus(e)
    proc rawTail(path: string): string =
      let size = spoolSize(path)
      if size == 0: return ""
      var f = open(path, fmRead)
      try:
        f.setFilePos(max(0, size - TAIL_BYTES))
        result = f.readAll()
      except CatchableError:
        result = ""
      finally:
        try: f.close()
        except CatchableError: discard
    let outT = rawTail(e.outPath)
    let errT = rawTail(e.errPath)
    var text = "[" & e.id & " (" & e.label & ") — " & statusText(e) & "]\n" &
               (if outT.len > 0: "stdout (tail):\n" & outT else: "") &
               (if errT.len > 0: (if outT.len > 0: "\n" else: "") &
                 "stderr (tail):\n" & errT else: "")
    return okResult(%*{"id": e.id, "label": e.label,
                       "status": statusText(e), "text": text})

  # drain: wait for new content, exit, or the wait cap
  let deadline = getMonoTime() + initDuration(milliseconds = waitMs)
  while true:
    refreshStatus(e)
    if spoolSize(e.outPath) > e.outCursor or
       spoolSize(e.errPath) > e.errCursor or
       e.status != stRunning: break
    if getMonoTime() >= deadline: break
    sleep(WAIT_SLICE_MS)
  refreshStatus(e)
  markTerminal(e)

  let rOut = readNew(e.outPath, e.outCursor)
  let rErr = readNew(e.errPath, e.errCursor)
  let newOut = rOut.content
  let newErr = rErr.content
  let truncated = rOut.truncated or rErr.truncated
  let newBytes = newOut.len + newErr.len

  var body = ""
  var matched = 0
  var totalLines = 0
  if filter.len > 0:
    let (m1, t1, h1) = applyFilter(newOut, filter)
    let (m2, t2, h2) = applyFilter(newErr, filter)
    matched = h1 + h2
    totalLines = t1 + t2
    if m1.len > 0: body.add("stdout (filtered):\n" & m1)
    if m2.len > 0:
      if body.len > 0: body.add("\n")
      body.add("stderr (filtered):\n" & m2)
    if body.len == 0:
      body = "(no lines matched the filter in " & $totalLines & " new lines)"
  else:
    totalLines = countLines(newOut) + countLines(newErr)
    if newOut.len > 0: body.add("stdout:\n" & newOut)
    if newErr.len > 0:
      if body.len > 0: body.add("\n")
      body.add("stderr:\n" & newErr)
    if body.len == 0: body = "(no new output)"
  var text = "[" & e.id & " (" & e.label & ") — " & statusText(e) & "]\n" & body
  if newBytes == 0 and e.status == stRunning and waitMs == 0 and
      not e.emptyPollHinted:
    e.emptyPollHinted = true
    text.add("\n[Still running: use process_poll {id:\"" & e.id &
             "\",waitMs:25000} to wait rather than polling tightly.]")
  if truncated:
    text.add("\n[spool truncated to its tail — the cap was reached]")
  okResult(%*{"id": e.id, "label": e.label, "status": statusText(e),
              "exit_code": (if e.status != stRunning: e.exitCode else: 0),
              "started_at": e.startedAt,
              "new_bytes": newBytes, "lines": totalLines,
              "matched": (if filter.len > 0: matched else: 0),
              "text": text})

proc hKill(c: Component, args: JsonNode): JsonNode =
  let id = args{"id"}.getStr("")
  if id.len == 0:
    fail("E_BAD_SHAPE", "process_kill requires \"id\"")
  let e = entryOr404(id)
  killEntry(e)
  okResult(%*{"id": id, "label": e.label, "status": statusText(e),
              "text": e.id & " (" & e.label & "): " & statusText(e)})

proc evictFinished() =
  ## KEEP_FINISHED: finished entries live only for process_list — drop the
  ## oldest beyond the cap so the registry cannot grow for the component's
  ## whole lifetime. Registry persistence is unaffected: only RUNNING
  ## entries are saved, so eviction is purely an in-memory list edit.
  while gProcs.len > MAX_LIVE + KEEP_FINISHED:
    var evicted = false
    for id, e in gProcs:
      if e.status != stRunning:
        gProcs.del(id)
        evicted = true
        break
    if not evicted:
      # nothing finished to evict (gProcs should be <= MAX_LIVE then)
      break

proc hList(c: Component, args: JsonNode): JsonNode =
  var lines: seq[string]
  var items = newJArray()
  for e in gProcs.values:
    refreshStatus(e)
    markTerminal(e)
    lines.add(e.id & "  " & statusText(e) & "  " & e.label & "  — " & e.command)
    items.add(%*{"id": e.id, "label": e.label, "command": e.command,
                 "status": statusText(e),
                 "exit_code": (if e.status != stRunning: e.exitCode else: 0),
                 "started_at": e.startedAt})
  evictFinished()
  let text = if lines.len == 0:
               "No background processes this component lifetime."
             else: lines.join("\n")
  okResult(%*{"processes": items, "text": text,
              "note": "registry is per component lifetime; processes die with the harness"})

# ---------------------------------------------------------------------------
# component

let comp = newComponent("processes", "0.1.0")

proc processNotices(args: JsonNode): JsonNode =
  ## Durable completion outbox, serialized with reaping. Peek never acknowledges.
  let session = args{"session"}.getStr("")
  var notices = newJArray()
  let dir = rootVarDir("processes") / "notices"
  if session.len > 0 and dirExists(dir):
    for path in walkFiles(dir / "*.json"):
      let record = parseJson(readFile(path))
      if record{"session"}.getStr("") != session or
          record{"delivered"}.getBool(false): continue
      notices.add(record["notice"])
      if args{"ack"}.getStr("") == record{"notice"}{"processId"}.getStr(""):
        record["delivered"] = %true
        record["deliveredAt"] = %epochTime()
        atomicWrite(path, $record)
  %*{"count": notices.len, "notices": notices}

proc publishExitNotice(e: Entry) =
  ## Tell the owning conversation that a background process finished.
  ##
  ## Rides the lane the agent's settlement notices use —
  ## svc.session.<id>.steer with a {"notice": …} payload — so the runner folds
  ## it in as an appended user message and emits ev.session.<id>.notice. Without it
  ## the model only learns by polling process_poll: nothing reaped a child
  ## except a tool call, so an exit stayed invisible until someone asked.
  ##
  ## Pointer, not payload: the notice names the process, its status, how much
  ## output exists and the recourse; the output stays in the spool for
  ## process_poll. Persist before notifying; the inbox survives component and
  ## runner restarts. No owning session means no autonomous notification.
  if e.session.len == 0 or e.notified: return
  var payload = newJObject()
  payload["kind"] = %"process-exited"
  payload["processId"] = %e.id
  payload["label"] = %e.label
  payload["status"] = %statusText(e)
  payload["exitCode"] = %e.exitCode
  payload["startedAt"] = %e.startedAt
  payload["endedAt"] = %epochTime()
  payload["outputBytes"] = %(spoolSize(e.outPath) + spoolSize(e.errPath))
  try:
    # Record first; failed writes are retried by the idle seam.
    atomicWrite(rootVarDir("processes") / "notices" / (e.id & ".json"),
      $(%*{"session": e.session, "notice": payload, "delivered": false}))
    e.notified = true
    comp.emit("svc.session." & sanitizeSessionId(e.session) & ".steer",
              %*{"notice": payload})
    comp.publishCall("svc.core.call", callEnvelope("session",
      %*{"sessionId": e.session, "wake": true}, "processes"))
  except CatchableError as err:
    stderr.writeLine(comp.name & ": exit notice for " & e.id &
                     " failed: " & err.msg)

var lastNoticeWake = 0.0

proc retryNoticeWakes(c: Component) =
  ## Recover a missed publish or a runner/core outage. Wake admission owns the
  ## turn budget; acknowledged records never wake again. One call per session.
  if epochTime() - lastNoticeWake < 10.0: return
  lastNoticeWake = epochTime()
  var sessions = initTable[string, bool]()
  let dir = rootVarDir("processes") / "notices"
  if dirExists(dir):
    for path in walkFiles(dir / "*.json"):
      try:
        let record = parseJson(readFile(path))
        let session = record{"session"}.getStr("")
        # Retention starts at acknowledgement, never at completion: pending
        # notices and their output remain recoverable regardless of age.
        let deliveredAt = record{"deliveredAt"}.getFloat(0)
        if record{"delivered"}.getBool(false) and deliveredAt > 0 and
            epochTime() - deliveredAt > 7 * 86400:
          let id = path.extractFilename().changeFileExt("")
          if id.len > 1 and id[0] == 'p' and id[1 .. ^1].allCharsInSet({'0'..'9'}):
            if not gProcs.hasKey(id) or gProcs[id].status != stRunning:
              removeFile(rootVarDir("processes") / (id & ".out"))
              removeFile(rootVarDir("processes") / (id & ".err"))
              if gProcs.hasKey(id): gProcs.del(id)
              removeFile(path)
          continue
        if session.len > 0 and not record{"delivered"}.getBool(false):
          sessions[session] = true
      except CatchableError as err:
        stderr.writeLine("processes: unreadable notice " & path & ": " & err.msg)
  for session in sessions.keys:
    c.publishCall("svc.core.call", callEnvelope("session",
      %*{"sessionId": session, "wake": true}, c.name))

# Reap on a tick: an exit must be noticed by the component, not by the next
# caller. This is what makes the notice possible at all (the SDK's onIdle seam)
# — and it also stops process_list from reporting a finished child as running
# until someone happens to poll.
# ---------------------------------------------------------------------------
# configuration: spool and poll limits, served by our own record

let declaration* = %*{
  "domain": "processes.limits", "version": 1, "owner": "processes",
  "ownerTool": "processes_config", "title": "Background process limits",
  "description": "How much output a background process may accumulate before its spool is truncated to a tail, and how much one poll returns.",
  "kind": ownerStore.kind, "id": ownerStore.id,
  # "immediate": both readers consult this record on every call.
  "application": "immediate",
  "schema": {
    "type": "object",
    "properties": {
      "spoolCap": {"type": "integer", "minimum": 65536, "maximum": 1073741824,
                   "default": SPOOL_CAP, "x-config": {
        "title": "Spool size before truncation (bytes)",
        "description": "A process's output spool is truncated to its tail (min(2 MiB, half this)) on the next poll once it grows past this."}},
      "pollChunk": {"type": "integer", "minimum": 1024, "maximum": 1048576,
                    "default": POLL_CHUNK, "x-config": {
        "title": "Bytes returned per poll",
        "description": "Kept below the spool cap so a burst is always split across polls."}}},
    "additionalProperties": false}}

discard comp.tool("processes_config", ownerToolSchema("processes.limits",
    "Owner-side settings protocol for the processes.limits domain. Called by " &
    "the config component; never call it directly."),
  proc(c: Component, args: JsonNode): JsonNode = c.ownerOp(ownerStore, args))

# Values follow config's change event (no store read in the idle seam, which
# runs on the pump thread and would starve the process output lane).
comp.watchConfig(settings, "processes.limits")

# ONE idle handler for the whole component: the SDK keeps a single one and a
# second registration REPLACES the first. Declaring the settings domain from its
# own onIdle() silently disabled this reaper — background exits then went
# unannounced until someone polled, which is the bug this seam exists to avoid.
# So the declaration rides here, and any future periodic work must join it.
var declared = false
discard comp.onIdle(500) do (c: Component):
  for e in gProcs.values:
    if e.status == stRunning:
      refreshStatus(e)             # publishes the notice on transition
      markTerminal(e)
    elif not e.notified:
      publishExitNotice(e)
  retryNoticeWakes(c)
  evictFinished()                  # the registry cap holds without callers
  if not declared:
    declared = c.declareConfig(declaration) or declared

discard comp.onDrain do (c: Component):
  for e in gProcs.values:
    killEntry(e)
  gProcs.clear()

bootSweep()

discard comp.tool("process_notices", toolSchema(%*{
  "session": {"type": "string"}, "peek": {"type": "boolean"},
  "ack": {"type": "string"}
}, @["session"], "Runner completion inbox: read pending process notices or explicitly acknowledge a persisted processId."),
  proc(c: Component, args: JsonNode): JsonNode = processNotices(args),
  %*{"hidden": true, "runner": true, "effect": "read"})

discard comp.tool("process_start", toolSchema(%*{
  "command": {"type": "string",
              "description": "The command line to run in the background (bash -c)"},
  "label": {"type": "string",
            "description": "Short human-readable name, e.g. \"dev-server\" or \"test-watcher\" (default: first command word)"},
  "workdir": {"type": "string", "description": "Working directory (default: workspace)"}
}, @["command"],
  "Start a long-running command (dev server, file watcher, database) as a detached background process and return its id immediately. Poll incremental output with process_poll (drain semantics: each poll returns only what was appended since the last one; waitMs blocks until there is new output or the process exits), stop it with process_kill. Completion automatically notifies the owning session and wakes it within the shared wake budget; do not poll just to wait for completion. Use for servers and watchers you need to interact with across turns — not for commands that finish quickly (plain bash). stdin is /dev/null. Processes die with the harness. Starting a process writes harness state — approval-gated."),
  hStart,
  %*{"approval": "always", "timeoutMs": 20000, "onDemand": true,
     "sessionId": true, "workspace": %*{"cwdField": "workdir"}})

discard comp.tool("process_poll", toolSchema(%*{
  "id": {"type": "string", "description": "Process id from process_start"},
  "waitMs": {"type": "integer", "minimum": 0, "maximum": 25000,
             "description": "Optional wait for output or exit (default 0, max 25000 ms)"},
  "filter": {"type": "string",
             "description": "Regex: return only matching lines from the new output (the drain cursor still advances past all of it; use tail to re-read raw recent output)"},
  "tail": {"type": "string",
           "description": "Any non-empty value: re-read the last ~64KB of raw output instead of draining"}
}, @["id"],
  "Read incremental output from a background process: each poll returns only what was appended since the previous poll, so repeated polls never repeat content. status reports running / exited(code) / killed(signal). Use filter (regex) to pull specific patterns (FAIL, error) out of chatty output, and tail to re-read the recent raw output unfiltered. Completion is pushed to the owning session automatically; use polling only when you need output or progress, not to discover completion. Read-only."),
  hPoll,
  %*{"timeoutMs": 30000, "onDemand": true, "effect": "read"})

discard comp.tool("process_kill", toolSchema(%*{
  "id": {"type": "string", "description": "Process id from process_start"}
}, @["id"],
  "Stop a background process: terminates its whole process group (SIGTERM, escalating to SIGKILL). Use when a server or watcher is no longer needed — processes are never killed automatically while the harness runs. Killing writes harness state — approval-gated."),
  hKill,
  %*{"approval": "always", "timeoutMs": 15000, "onDemand": true})

discard comp.tool("process_list", toolSchema(%*{}, @[],
  "List this harness's background processes: ids, labels, commands, and status (running / exited(code) / killed). Read-only."),
  hList,
  %*{"timeoutMs": 10000, "onDemand": true, "effect": "read"})

comp.run()
