## Supervisor — spawn, monitor, drain, kill. Erlang/OTP for agent harnesses:
## the unit of composition is the process, the OS is the disposer.
##
## Restart policy per child: never | on-failure (with backoff). Drain order:
## ev.sys.drain event → grace period → SIGTERM → SIGKILL.

import std/[json, os, osproc, times]
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

proc startChild*(sup: Supervisor, c: Child, args: seq[string] = @[]) =
  # env = nil inherits the parent environment (NIF_NATS_URL, PATH, API keys);
  # NIF_ROOT is set globally once so children know where the SDK lives.
  # Child output goes to var/logs/<name>.log: without a redirect, osproc
  # gives the child an undrained pipe — a chatty child blocks on write and
  # freezes silently mid-boot (this actually happened with session runners).
  putEnv("NIF_ROOT", sup.root)
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
  c.process = startProcess("/bin/sh", workingDir = sup.root,
                           args = ["-c", cmd], options = {poUsePath})
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
  for c in sup.children:
    if not c.wanted or c.process == nil: continue
    if c.process.running(): continue
    # died
    c.process.close()
    c.process = nil
    cat.dropComponent(c.name)
    if c.policy == rpNever: continue
    if now < c.nextStart: continue
    c.restarts += 1
    let backoff = min(500.0 * float(1 shl min(c.restarts, 5)), 8000.0)
    c.nextStart = now + backoff / 1000.0
    echo "supervisor: " & c.name & " died (restart #" & $c.restarts &
         ", backoff " & $backoff.int & "ms)"
    startChild(sup, c)

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
