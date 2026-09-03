## Supervisor — spawn, monitor, drain, kill. Erlang/OTP for agent harnesses:
## the unit of composition is the process, the OS is the disposer.
##
## Restart policy per child: never | on-failure (with backoff). Drain order:
## ev.sys.drain event → grace period → SIGTERM → SIGKILL.

import std/[algorithm, json, os, osproc, strutils, times]
import natswrapper
import ../sdk/envelope
import catalog

type
  RestartPolicy* = enum
    rpNever = "never"
    rpOnFailure = "on-failure"

proc parsePolicy*(s: string): RestartPolicy =
  ## Manifest/store policy strings → enum. Unknown values fall back to
  ## on-failure (the safe default: a crashed component comes back).
  case s
  of "never": rpNever
  of "on-failure": rpOnFailure
  else:
    echo "supervisor: unknown restart policy '" & s & "' — using on-failure"
    rpOnFailure

type
  Child* = ref object
    name*: string
    binary*: string
    policy*: RestartPolicy
    wanted*: bool          ## false while draining: never restart
    process*: Process
    restarts*: int
    nextStart*: float      ## backoff: epochTime when restart is allowed

  Supervisor* = ref object
    root*: string
    nc*: NatsConnection
    children*: seq[Child]

proc newSupervisor*(root: string, nc: NatsConnection): Supervisor =
  Supervisor(root: root, nc: nc)

proc sweepLogs*(sup: Supervisor, maxAgeDays: float, maxTotalMb: float) =
  ## Retention for child logs (var/logs/<name>.log): delete files older
  ## than maxAgeDays, then evict oldest-first until the directory fits
  ## maxTotalMb. Diagnostic records, not an audit trail — unbounded growth
  ## served nobody. Called at boot and hourly from the service loop.
  let dir = sup.root / "var" / "logs"
  if not dirExists(dir): return
  type LogFile = tuple[path: string, modified: times.Time, size: int64]
  var files: seq[LogFile]
  var total = 0'i64
  let cutoff = getTime() - initDuration(days = maxAgeDays.int)
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    try:
      let modified = getLastModificationTime(path)
      if modified < cutoff:
        removeFile(path)
      else:
        total += getFileSize(path)
        files.add((path, modified, getFileSize(path)))
    except CatchableError:
      discard
  if total.float > maxTotalMb * 1_000_000.0:
    files.sort(proc (a, b: LogFile): int = cmp(a.modified, b.modified))
    for f in files:
      if total.float <= maxTotalMb * 1_000_000.0: break
      try:
        total -= f.size
        removeFile(f.path)
      except CatchableError:
        discard

proc logTail(path: string, maxLines: int): string =
  ## Last lines of a child's log file, for the death report. Missing or
  ## unreadable file → empty string (report degrades gracefully).
  if not fileExists(path): return ""
  try:
    let lines = readFile(path).strip().splitLines()
    let tail = lines[max(0, lines.len - maxLines) .. ^1]
    return tail.join(" | ").strip()
  except CatchableError:
    return ""

proc startChild*(sup: Supervisor, c: Child, args: seq[string] = @[]) =
  # env = nil inherits the parent environment (NIF_NATS_URL, PATH, API keys);
  # NIF_ROOT is set globally once so children know where the SDK lives.
  # Child output goes to var/logs/<name>.log: without a redirect, osproc
  # gives the child an undrained pipe — a chatty child blocks on write and
  # freezes silently mid-boot (this actually happened with session runners).
  putEnv("NIF_ROOT", sup.root)
  # stdout+stderr go to var/logs/<name>.log: a supervisor-owned pipe nobody
  # reads would swallow crash messages (and a bash grandchild could hold it
  # open forever). The death report in pump() shows the tail of this file.
  let logDir = sup.root / "var" / "logs"
  try:
    createDir(logDir)
  except CatchableError:
    discard
  let logPath = logDir / (c.name & ".log")
  var cmd = "exec " & quoteShell(c.binary)
  for a in args:
    cmd.add(" " & quoteShell(a))
  cmd.add(" >> " & quoteShell(logPath) & " 2>&1")
  # stdin stays a fresh pipe (EOF on read) as before; the wrapper's own
  # stdout/stderr pipes carry nothing (redirected at exec) and are never read.
  c.process = startProcess("/bin/sh", workingDir = sup.root, args = ["-c", cmd],
                           options = {poUsePath})
  echo "supervisor: started " & c.name & " (" & c.binary & ")"
  c.restarts = 0

proc addChild*(sup: Supervisor, name, binary: string,
               policy: RestartPolicy = rpOnFailure): Child =
  result = Child(name: name, binary: binary, policy: policy, wanted: true)
  sup.children.add(result)

proc pump*(sup: Supervisor, cat: Catalog) =
  ## Check children for unexpected death; restart per policy. Call from
  ## event gaps in the loop (registrations converge in the catalog).
  let now = epochTime()
  var retired: seq[int]
  for i in 0 ..< sup.children.len:
    # index access: `for c in sup.children` yields copies, and mutating a
    # copy's process field would leave a stale pointer in the managed set
    template c: untyped = sup.children[i]
    if not c.wanted or c.process == nil: continue
    if c.process.running(): continue
    # died — keep c.process until the backoff window passes: a child that
    # dies twice in a row (e.g. refused a lock) must still be restarted when
    # its backoff elapses, never silently dropped
    if c.policy == rpNever:
      c.process.close()
      c.process = nil
      cat.dropComponent(c.name)
      # retire the entry entirely: ensureRunner probes sup.children to tell
      # "spawning" from "dead", and a stale entry would block re-ensure of
      # an intentionally retired (idle-exited) runner forever
      retired.add(i)
      continue
    if now < c.nextStart: continue
    let code = c.process.peekExitCode()
    let tail = logTail(sup.root / "var" / "logs" / (c.name & ".log"), 3)
    c.process.close()
    cat.dropComponent(c.name)
    c.restarts += 1
    let backoff = min(500.0 * float(1 shl min(c.restarts, 5)), 8000.0)
    c.nextStart = now + backoff / 1000.0
    echo "supervisor: " & c.name & " died (exit " & $code & ", restart #" &
         $c.restarts & ", backoff " & $backoff.int & "ms)"
    if tail.len > 0:
      echo "supervisor:   last output: " & tail
    startChild(sup, c)
  # delete the recorded indices descending so earlier indices stay valid
  for i in countdown(retired.len - 1, 0):
    sup.children.delete(retired[i])

proc removeChild*(sup: Supervisor, name: string): bool =
  ## Stop one child for good, then drop it from the managed set (no restart,
  ## no restore on boot). SIGTERM alone is the graceful path for a single
  ## child — the SDKs treat SIGTERM like ev.sys.drain (depart + exit) —
  ## whereas ev.sys.drain is a broadcast and would shut down every component.
  ## Returns false if no such child exists.
  var idx = -1
  for i, c in sup.children:
    if c.name == name:
      idx = i
      break
  if idx < 0: return false
  let c = sup.children[idx]
  c.wanted = false
  if c.process != nil and c.process.running():
    c.process.terminate()   # SIGTERM: component departs gracefully
    sleep(600)
  if c.process != nil and c.process.running():
    c.process.kill()        # SIGKILL
    sleep(50)
  if c.process != nil and not c.process.running():
    c.process.close()
    c.process = nil
  delete(sup.children, idx)
  echo "supervisor: removed " & name
  return true

proc drain*(sup: Supervisor) =
  ## Reverse registration order: drain event → grace → SIGTERM → SIGKILL.
  echo "supervisor: draining " & $sup.children.len & " children"
  for c in sup.children:
    c.wanted = false
    let env = Envelope(v: 1, id: newId(), kind: ekEvent,
                       payload: newJObject())
    sup.nc.publish("ev.sys.drain", env.encode())
  sleep(600)  # grace: components finish current call, depart, exit
  for c in sup.children:
    if c.process == nil: continue
    if c.process.running():
      c.process.terminate()   # SIGTERM
      sleep(300)
    if c.process.running():
      c.process.kill()        # SIGKILL
      sleep(50)
    if not c.process.running():
      c.process.close()
      c.process = nil
  echo "supervisor: drained"
