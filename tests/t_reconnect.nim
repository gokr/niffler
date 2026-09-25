## t_reconnect — SDK survives a bus outage longer than the reconnect budget
## (issue #3).
##
## Contract under test: when the bus stays unreachable past the client's own
## reconnect budget, the component must NOT go alive-but-deaf. It re-resolves
## the bus URL (the restarted core may bind a NEW port — discovery file),
## redials, rebuilds every subscription (call + event + tap) and re-announces
## reg.publish, then answers tool calls again. No process restart involved.
##
## Setup: a private NATS + a fixture component (tests/fixtures/
## reconnect_probe.nim, NIF_RECONNECT_GRACE_S=4). Kill the bus, restart it on
## a different port, point the discovery file at it, and watch:
##   1. reg.publish arrives a SECOND time (re-announce proof),
##   2. a direct call to svc.reconnect-probe.call answers pong again.
## The test process talks to the fixture DIRECTLY on svc.<name>.call — core
## is deliberately absent so the component's recovery is isolated.

import std/[json, os, osproc, times]
import natsnim
import envelope
import helpers

type Probe = object
  sandbox: TestSandbox
  server1: Process
  server2: Process
  nc: NatsConnection
  comp: Process

proc buildProbe(sandbox: TestSandbox) =
  let compiler = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & sandbox.repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("reconnect-probe"),
    sandbox.repoRoot / "tests" / "fixtures" / "reconnect_probe.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compiler, 180_000) != 0:
    fail("reconnect probe failed to compile")
    quit(1)
  compiler.close()

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                  subject.cstring)):
    fail("subscribe " & subject)
  sub

proc pollEnv(sub: ptr natsSubscription, timeoutMs: int64): Envelope =
  var msg: ptr natsMsg
  if natsSubscription_NextMsg(addr msg, sub, timeoutMs) != NATS_OK:
    return Envelope()
  let data = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
  try: result = decode(data)
  except CatchableError: discard

proc callPing(nc: NatsConnection, timeoutMs: int): JsonNode =
  ## Direct call to the fixture's ping tool; returns the result args or nil.
  let data = callEnvelope("ping", %*{}, "t-reconnect").encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn, "svc.reconnect-probe.call".cstring,
                                  data.cstring, data.len.cint, timeoutMs.int64)
  if st != NATS_OK: return nil
  defer: natsMsg_Destroy(msg)
  let r = decode($natsMsg_GetData(msg))
  if r.kind != ekResult: return nil
  return r.args

proc waitRegPublish(sub: ptr natsSubscription, secs: float): bool =
  ## Wait for one reg.publish envelope within the budget.
  let deadline = epochTime() + secs
  while epochTime() < deadline:
    let env = pollEnv(sub, 250)
    if env.kind == ekEvent:
      return true
  false

var p: Probe
p.sandbox = newCoreSandbox("reconnect", [])   # no core: isolate the component
buildProbe(p.sandbox)

block sanity:
  let started = startNats()
  p.server1 = started.prc
  p.nc = waitConnect(started.url)
  p.comp = startComponent(p.sandbox.sandboxBin("reconnect-probe"),
                          started.url, root = p.sandbox.root,
                          extra = [("NIF_RECONNECT_GRACE_S", "4")],
                          logFile = p.sandbox.root / "var" / "test-logs" /
                                    "reconnect-probe.log")
  var regs = openSub(p.nc, "reg.publish")
  # First announcement + a working call before the outage.
  let first = waitRegPublish(regs, 15)
  let pong = callPing(p.nc, 5_000)
  check("pre-outage: fixture announced and answers ping",
        first and pong != nil and pong{"pong"}.getBool(false),
        $pong)
  natsSubscription_Destroy(regs)

block outage:
  # 1. Kill the bus. The fixture's internal reconnect keeps trying the dead
  #    URL; its health watch trips re-attach after the 4s grace.
  stopServer(p.server1)
  p.nc.close()
  sleep(7_000)

  # 2. Restart the bus on a NEW port and point the discovery file at it.
  let started2 = startNats()
  p.server2 = started2.prc
  writeFile(p.sandbox.root / "var" / "nats-url", started2.url & "\n")
  p.nc = waitConnect(started2.url)
  var regs = openSub(p.nc, "reg.publish")

  # 3. Re-announce: the fixture must find the new bus and re-register.
  let reannounced = waitRegPublish(regs, 40)

  # 4. Calls work again on the new connection.
  let pong = callPing(p.nc, 5_000)
  check("post-outage: fixture re-announced (reg.publish #2)", reannounced)
  check("post-outage: fixture answers ping again",
        pong != nil and pong{"pong"}.getBool(false), $pong)

  natsSubscription_Destroy(regs)

# teardown
stopProcess(p.comp)
p.nc.close()
if p.server2 != nil: stopServer(p.server2)
if p.server1 != nil: stopServer(p.server1)
if p.sandbox.root.len > 0: removeDir(p.sandbox.root)

report("reconnect")
