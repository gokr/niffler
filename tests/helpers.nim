## Shared test helpers — no framework, just small building blocks.
##
## Each test spawns its own NATS server on a free port and boots what it
## needs (components directly, or full core headless). Tests that boot
## core against the real repo root require no other harness running
## (store single-writer rule, docs/MANUAL.md); tests that only talk to
## components use a temp NIF_ROOT where possible.

import std/[json, net, os, osproc, streams, strtabs, strutils, times]
import natswrapper
import envelope

var failures* = 0

proc fail*(msg: string) =
  echo "FAIL: ", msg
  inc failures

proc check*(name: string, cond: bool, detail: string = "") =
  if cond:
    echo "OK: ", name
  else:
    inc failures
    echo "FAIL: ", name, " — ", detail

proc report*(label: string) =
  if failures > 0:
    echo label, " FAILED: ", failures, " failure(s)"
    quit(1)
  echo label, " PASSED"

# --------------------------------------------------------------------------
# NATS

proc startNats*(): tuple[prc: Process, url: string] =
  ## Spawn nats-server on a free port; caller must terminate result.prc.
  var s = newSocket()
  s.bindAddr(Port(0))
  let port = int(s.getLocalAddr()[1])
  s.close()
  let url = "nats://127.0.0.1:" & $port
  result.prc = startProcess("nats-server", args = ["-p", $port],
                            options = {poUsePath})
  result.url = url

proc waitConnect*(url: string, tries = 40): NatsConnection =
  ## Connect with retry; quits the test on failure.
  for i in 0 ..< tries:
    try:
      return connect(url)
    except CatchableError:
      sleep(100)
  fail("cannot connect to " & url)
  quit(1)

proc waitRegistered*(nc: NatsConnection, comp: string, secs = 15): bool =
  ## Watch reg.publish until the named component registers.
  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, "reg.publish".cstring)
  if not checkStatus(st):
    fail("subscribe reg.publish: " & getErrorString(st))
    return false
  let deadline = epochTime() + secs.float
  result = false
  while epochTime() < deadline:
    var msg: ptr natsMsg
    let r = natsSubscription_NextMsg(addr msg, sub, 200)
    if r == NATS_OK:
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      if data.contains("\"" & comp & "\""):
        result = true
        break
  natsSubscription_Destroy(sub)

proc call*(nc: NatsConnection, comp, tool: string, args: JsonNode,
           timeoutMs = 10_000): JsonNode =
  ## Request/reply envelope call; returns the result args, or an
  ## {"error": ...} object on failure.
  let data = callEnvelope(tool, args).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn,
                                  ("svc." & comp & ".call").cstring,
                                  data.cstring, data.len.cint,
                                  timeoutMs.int64)
  if st == NATS_TIMEOUT:
    return %*{"error": "timeout"}
  if not checkStatus(st):
    return %*{"error": "nats " & $st}
  let r = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  if r.kind == ekError:
    return %*{"error": r.error{"message"}.getStr("component error")}
  return r.args

# --------------------------------------------------------------------------
# processes

proc startComponent*(bin: string, url: string, root = "",
                     extra: openArray[(string, string)] = []): Process =
  ## Start a component (or core) with the standard NIF_* env. The
  ## environment REPLACES the inherited one (osproc), so seed it from the
  ## current env first — components spawn subprocesses (bash, nim, go,
  ## git) that need PATH etc.
  let root2 = if root.len > 0: root else: getEnv("NIF_ROOT", getAppDir().parentDir())
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    env[k] = v
  env["NIF_ROOT"] = root2
  env["NIF_NATS_URL"] = url
  for (k, v) in extra:
    env[k] = v
  result = startProcess(bin, workingDir = root2, env = env,
                        options = {poUsePath})

proc runCli*(cliBin, url: string, args: openArray[string],
             timeoutMs = 60_000, root = ""): tuple[code: int, output: string] =
  ## Run var/bin/cli against a bus; returns exit code + combined output.
  let root2 = if root.len > 0: root else: getEnv("NIF_ROOT", getAppDir().parentDir())
  var env = newStringTable(modeCaseSensitive)
  env["NIF_ROOT"] = root2
  env["NIF_NATS_URL"] = url
  let p = startProcess(cliBin, args = @args, env = env,
                       options = {poUsePath, poStdErrToStdOut})
  result.code = p.waitForExit(timeoutMs)
  if result.code == -1:
    p.terminate()
    result.code = 124
  result.output = p.outputStream.readAll()
  p.close()

proc drain*(nc: NatsConnection) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: newJObject())
  nc.publish("ev.sys.drain", env.encode())

proc tempRoot*(tag: string): string =
  ## A scratch NIF_ROOT for tests that must not touch the real barrel.
  result = getTempDir() / ("niffler-test-" & tag & "-" & $getCurrentProcessId())
  createDir(result)
  createDir(result / "var")
