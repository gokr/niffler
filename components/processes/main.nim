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
## the reaping (docs/OCTOFRIEND-STEAL.md, "Steal 5 follow-up").
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

import std/[json, monotimes, os, posix, re, strutils, tables, times]
import std/syncio
import niffler/sdk

const
  MAX_LIVE = 32                    # concurrent running processes
  KEEP_FINISHED = 50               # finished entries kept in the registry
  POLL_CHUNK = 64 * 1024           # max new bytes returned per stream/poll
  TAIL_BYTES = 64 * 1024           # raw tail readable via tail=true
  SPOOL_CAP = 32 * 1024 * 1024     # truncate a spool beyond this
  SPOOL_KEEP = 2 * 1024 * 1024     # bytes kept when truncating
  WAIT_SLICE_MS = 100              # wait granularity
  MAX_WAIT_MS = 25_000             # wait cap (inside the 30s tool timeout)

proc spoolCap(): int =
  let v = getEnv("NIF_PROCESSES_SPOOL_CAP", "")
  if v.len > 0:
    try: return parseInt(v)
    except ValueError: discard
  return SPOOL_CAP

proc pollChunk(): int =
  ## Max new bytes one poll returns per stream (NIF_PROCESSES_POLL_CHUNK
  ## override, kept below the spool cap so a burst is always split).
  let v = getEnv("NIF_PROCESSES_POLL_CHUNK", "")
  if v.len > 0:
    try: return clamp(parseInt(v), 1024, 1_048_576)
    except ValueError: discard
  return POLL_CHUNK

type Status = enum
  stRunning, stExited, stKilled

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
  swept: bool                      # terminal statuses left the sweep file

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
                     "starttime": procStarttime(e.pid)})
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
        # else: pid reused or already gone — leave it alone
    except CatchableError as e:
      stderr.writeLine("processes: sweep read failed: " & e.msg)
  let dir = rootVarDir("processes")
  if dirExists(dir):
    for kind, p in walkDir(dir):
      if kind == pcFile and (p.endsWith(".out") or p.endsWith(".err")):
        try: removeFile(p)
        except CatchableError: discard
  if killed > 0:
    stderr.writeLine("processes: boot sweep killed " & $killed &
                     " orphaned process group(s)")
  atomicWrite(path, (%*{"nextId": gNextId, "entries": newJArray()}).pretty())

# ---------------------------------------------------------------------------
# child lifecycle

proc refreshStatus(e: Entry) =
  ## Reap via WNOHANG; caches the terminal status.
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

proc statusText(e: Entry): string =
  case e.status
  of stRunning: "running"
  of stExited: "exited(code " & $e.exitCode & ")"
  of stKilled: "killed(signal " & $e.exitCode & ")"

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
  let size = spoolSize(path)
  if size > spoolCap() and truncateSpool(path, cursor):
    result.truncated = true
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
  var compiled: Regex
  try: compiled = re(pattern, {reStudy})
  except CatchableError as e:
    fail("E_BAD_SHAPE", "invalid filter regex: " & e.msg)
  var matched: seq[string]
  var total = 0
  for line in chunk.splitLines():
    total += 1
    if find(line, compiled) >= 0: matched.add(line)
  let body = if matched.len > 0: matched.join("\n") & "\n" else: ""
  (body, total, matched.len)

# ---------------------------------------------------------------------------
# tools

proc entryOr404(id: string): Entry =
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
                outPath: outPath, errPath: errPath, startedAt: epochTime())
  gProcs[id] = e
  saveRegistry()
  return okResult(%*{"id": id, "label": label, "pid": int(pid),
    "text": "Started background process " & id & " (" & label & ") — " &
            "poll incremental output with process_poll {id}, stop with " &
            "process_kill {id}."})

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
  if truncated:
    text.add("\n[spool truncated to its tail — the cap was reached]")
  okResult(%*{"id": e.id, "label": e.label, "status": statusText(e),
              "exit_code": (if e.status != stRunning: e.exitCode else: 0),
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

proc hList(c: Component, args: JsonNode): JsonNode =
  var lines: seq[string]
  var items = newJArray()
  for e in gProcs.values:
    refreshStatus(e)
    markTerminal(e)
    lines.add(e.id & "  " & statusText(e) & "  " & e.label & "  — " & e.command)
    items.add(%*{"id": e.id, "label": e.label, "command": e.command,
                 "status": statusText(e),
                 "exit_code": (if e.status != stRunning: e.exitCode else: 0)})
  let text = if lines.len == 0:
               "No background processes this component lifetime."
             else: lines.join("\n")
  okResult(%*{"processes": items, "text": text,
              "note": "registry is per component lifetime; processes die with the harness"})

# ---------------------------------------------------------------------------
# component

let comp = newComponent("processes", "0.1.0")

discard comp.onDrain do (c: Component):
  for e in gProcs.values:
    killEntry(e)
  gProcs.clear()

bootSweep()

discard comp.tool("process_start", toolSchema(%*{
  "command": {"type": "string",
              "description": "The command line to run in the background (bash -c)"},
  "label": {"type": "string",
            "description": "Short human-readable name, e.g. \"dev-server\" or \"test-watcher\" (default: first command word)"},
  "workdir": {"type": "string", "description": "Working directory (default: workspace)"}
}, @["command"],
  "Start a long-running command (dev server, file watcher, database) as a detached background process and return its id immediately. Poll incremental output with process_poll (drain semantics: each poll returns only what was appended since the last one; waitMs blocks until there is new output or the process exits), stop it with process_kill. Use for servers and watchers you need to interact with across turns — not for commands that finish quickly (plain bash). stdin is /dev/null. Processes die with the harness. Starting a process writes harness state — approval-gated."),
  hStart,
  %*{"approval": "always", "timeoutMs": 20000, "onDemand": true,
     "workspace": %*{"cwdField": "workdir"}})

discard comp.tool("process_poll", toolSchema(%*{
  "id": {"type": "string", "description": "Process id from process_start"},
  "waitMs": {"type": "integer", "minimum": 0,
             "description": "Block until new output or process exit, up to this many ms (0 = return immediately)"},
  "filter": {"type": "string",
             "description": "Regex: return only matching lines from the new output (the drain cursor still advances past all of it; use tail to re-read raw recent output)"},
  "tail": {"type": "string",
           "description": "Any non-empty value: re-read the last ~64KB of raw output instead of draining"}
}, @["id"],
  "Read incremental output from a background process: each poll returns only what was appended since the previous poll, so repeated polls never repeat content. status reports running / exited(code) / killed(signal). Use filter (regex) to pull specific patterns (FAIL, error) out of chatty output, and tail to re-read the recent raw output unfiltered. Read-only."),
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
