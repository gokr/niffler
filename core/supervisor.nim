## Supervisor — spawn, monitor, drain, kill. Erlang/OTP for agent harnesses:
## the unit of composition is the process, the OS is the disposer.
##
## Restart policy per child: never | on-failure (with backoff). Drain order:
## ev.sys.drain event → grace period → SIGTERM → SIGKILL.

import std/[json, os, osproc, strtabs, times]
import natswrapper
import ../sdk/envelope
import catalog

type
  RestartPolicy* = enum
    rpNever = "never"
    rpOnFailure = "on-failure"

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

proc startChild*(sup: Supervisor, c: Child) =
  # env = nil inherits the parent environment (NATS_URL, PATH, API keys);
  # NIF_ROOT is set globally once so children know where the SDK lives.
  putEnv("NIF_ROOT", sup.root)
  c.process = startProcess(c.binary, workingDir = sup.root,
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
