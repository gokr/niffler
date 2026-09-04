## Supervisor — spawn, monitor, drain, kill. Erlang/OTP for agent harnesses:
## the unit of composition is the process, the OS is the disposer.
##
## Restart policy per child: never | on-failure (with backoff). Drain order:
## ev.sys.drain event → grace period → SIGTERM → SIGKILL.

import std/[algorithm, json, os, osproc, strutils, times]
import natswrapper
import ../sdk/envelope
import ../sdk/niffler/procutil
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
    name*: string          ## logical component name (shared by replicas)
    instance*: int         ## 1-based supervisor instance for logs/status
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

proc childLabel(c: Child): string =
  if c.instance <= 1: c.name else: c.name & "#" & $c.instance

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
  let logPath = logDir / (c.childLabel() & ".log")
  # Stop the pipe-web: without this sweep every child inherited the parent
  # ends of all earlier children's spawn pipes (see cloexecInheritedFds).
  cloexecInheritedFds()
  var cmd = "exec " & quoteShell(c.binary)
  for a in args:
    cmd.add(" " & quoteShell(a))
  cmd.add(" >> " & quoteShell(logPath) & " 2>&1")
  # stdin stays a fresh pipe (EOF on read) as before; the wrapper's own
  # stdout/stderr pipes carry nothing (redirected at exec) and are never read.
  c.process = startProcess("/bin/sh", workingDir = sup.root, args = ["-c", cmd],
                           options = {poUsePath})
  echo "supervisor: started " & c.childLabel() & " (" & c.binary & ")"
  c.restarts = 0

proc addChild*(sup: Supervisor, name, binary: string,
               policy: RestartPolicy = rpOnFailure): Child =
  var instance = 1
  for child in sup.children:
    if child.name == name:
      instance = max(instance, child.instance + 1)
  result = Child(name: name, instance: instance, binary: binary,
                 policy: policy, wanted: true)
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
    let pid = c.process.processID
    if c.policy == rpNever:
      c.process.close()
      c.process = nil
      cat.dropReplica(c.name, pid)
      # retire the entry entirely: ensureRunner probes sup.children to tell
      # "spawning" from "dead", and a stale entry would block re-ensure of
      # an intentionally retired (idle-exited) runner forever
      retired.add(i)
      continue
    if now < c.nextStart: continue
    let code = c.process.peekExitCode()
    let tail = logTail(sup.root / "var" / "logs" /
                       (c.childLabel() & ".log"), 3)
    c.process.close()
    cat.dropReplica(c.name, pid)
    c.restarts += 1
    let backoff = min(500.0 * float(1 shl min(c.restarts, 5)), 8000.0)
    c.nextStart = now + backoff / 1000.0
    echo "supervisor: " & c.childLabel() & " died (exit " & $code &
         ", restart #" & $c.restarts & ", backoff " & $backoff.int & "ms)"
    if tail.len > 0:
      echo "supervisor:   last output: " & tail
    startChild(sup, c)
  # delete the recorded indices descending so earlier indices stay valid
  for i in countdown(retired.len - 1, 0):
    sup.children.delete(retired[i])

proc removeChild*(sup: Supervisor, name: string): bool =
  ## Stop every replica of one logical component for good, then drop them
  ## from the managed set (no restart, no restore on boot). SIGTERM alone is
  ## the graceful path for a single component group — ev.sys.drain would shut
  ## down every component. Returns false when no matching child exists.
  var indices: seq[int]
  for i, c in sup.children:
    if c.name == name:
      indices.add(i)
  if indices.len == 0: return false
  # Signal the group together so N replicas cost one grace window, not N.
  for i in indices:
    let c = sup.children[i]
    c.wanted = false
    if c.process != nil and c.process.running():
      c.process.terminate()
  sleep(600)
  for i in indices:
    let c = sup.children[i]
    if c.process != nil and c.process.running():
      c.process.kill()
  sleep(50)
  for i in countdown(indices.len - 1, 0):
    let idx = indices[i]
    let c = sup.children[idx]
    if c.process != nil and not c.process.running():
      c.process.close()
      c.process = nil
    delete(sup.children, idx)
  echo "supervisor: removed " & name & " (" & $indices.len & " replica(s))"
  return true

proc drain*(sup: Supervisor) =
  ## Reverse registration order: drain event → grace → SIGTERM → SIGKILL.
  echo "supervisor: draining " & $sup.children.len & " children"
  for c in sup.children:
    c.wanted = false
  # One broadcast reaches every process, including every replica.
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
