## Shared test helpers — no framework, just small building blocks.
##
## Each test owns a NATS-assigned loopback port and a unique writable
## NIF_ROOT. Full-core tests snapshot only the shipped binaries they need,
## so tests may overlap each other and a live development harness.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times]
import natswrapper
import envelope

type TestFailure* = object of CatchableError

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
    raise newException(TestFailure, label & " failed")
  echo label, " PASSED"

# --------------------------------------------------------------------------
# NATS

proc startNatsImpl(monitoring: bool): tuple[prc: Process, url, monitorUrl: string] =
  let portsDir = createTempDir("niffler-nats-", "")
  try:
    var args = @["-a", "127.0.0.1", "-p", "-1"]
    if monitoring:
      args.add(["-m", "-1"])
    args.add(["--ports_file_dir", portsDir])
    result.prc = startProcess("nats-server",
      args = args,
      options = {poUsePath, poStdErrToStdOut})
    for i in 0 ..< 100:
      for path in walkFiles(portsDir / "*.ports"):
        try:
          let ports = parseFile(path)
          if ports{"nats"} != nil and ports{"nats"}.len > 0:
            result.url = ports{"nats"}[0].getStr("")
          if ports{"monitoring"} != nil and ports{"monitoring"}.len > 0:
            result.monitorUrl = ports{"monitoring"}[0].getStr("")
        except CatchableError:
          discard
      if result.url.len > 0 and (not monitoring or result.monitorUrl.len > 0):
        break
      if result.prc.peekExitCode() != -1:
        break
      sleep(20)
    if result.url.len == 0 or (monitoring and result.monitorUrl.len == 0):
      if result.prc.running():
        result.prc.terminate()
      result.prc.close()
      raise newException(IOError, "nats-server did not publish a client port")
  finally:
    removeDir(portsDir)

proc startNats*(): tuple[prc: Process, url: string] =
  ## Let NATS allocate its own loopback port, avoiding bind-close-start races.
  let started = startNatsImpl(false)
  (started.prc, started.url)

proc startNatsMonitoring*(): tuple[prc: Process, url, monitorUrl: string] =
  ## Start an isolated bus with NATS-assigned client and monitoring ports.
  startNatsImpl(true)

proc stopServer*(server: Process, waitMs = 800) =
  ## Terminate a test bus, wait, escalate to SIGKILL, then reap.
  if server == nil:
    return
  if server.running():
    server.terminate()
    let deadline = epochTime() + waitMs.float / 1000.0
    while server.running() and epochTime() < deadline:
      sleep(50)
    if server.running():
      server.kill()
      sleep(50)
  server.close()

proc stopProcess*(process: Process, waitMs = 800) =
  ## Terminate a test component, wait, escalate to SIGKILL, then reap.
  if process == nil:
    return
  if process.running():
    process.terminate()
    let deadline = epochTime() + waitMs.float / 1000.0
    while process.running() and epochTime() < deadline:
      sleep(50)
    if process.running():
      process.kill()
      sleep(50)
  process.close()

proc waitConnect*(url: string, tries = 40): NatsConnection =
  ## Connect with retry; quits the test on failure.
  for i in 0 ..< tries:
    try:
      return connect(url)
    except CatchableError:
      sleep(100)
  raise newException(IOError, "cannot connect to " & url)

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
                     extra: openArray[(string, string)] = [],
                     args: openArray[string] = []): Process =
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
  env["NIF_NATS_SPAWN"] = "0"
  env["NIF_MODELS_OFFLINE"] = "1"
  env["NIF_MODELS_CACHE_DIR"] = root2 / "var" / "models"
  env["NIF_LOGFILE_DIR"] = root2 / "var" / "logs"
  env["NIF_OBSERVE_CAPTURE_DIR"] = root2 / "var" / "captures"
  env["XDG_CONFIG_HOME"] = root2 / "var" / "xdg-config"
  env["XDG_CACHE_HOME"] = root2 / "var" / "xdg-cache"
  for (k, v) in extra:
    env[k] = v
  result = startProcess(bin, workingDir = root2, args = @args, env = env,
                        options = {poUsePath})

proc runCli*(cliBin, url: string, args: openArray[string],
             timeoutMs = 60_000, root = ""): tuple[code: int, output: string] =
  ## Run var/bin/cli against a bus; returns exit code + combined output.
  let root2 = if root.len > 0: root else: getEnv("NIF_ROOT", getAppDir().parentDir())
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    env[k] = v
  env["NIF_ROOT"] = root2
  env["NIF_NATS_URL"] = url
  let p = startProcess(cliBin, args = @args, env = env,
                       options = {poUsePath, poStdErrToStdOut})
  # osproc's waitForExit(timeout) SIGKILLs the child itself and returns a
  # signal-derived code rather than -1 — poll peekExitCode and own the kill
  # (exit code 124 on timeout), like the builder's runCmd.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  result.code = -1
  while epochTime() < deadline:
    result.code = p.peekExitCode()
    if result.code != -1: break
    sleep(50)
  if result.code == -1:
    p.terminate()
    sleep(200)
    if p.running(): p.kill()
    result.code = 124
  result.output = p.outputStream.readAll()
  p.close()

proc drain*(nc: NatsConnection) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: newJObject())
  nc.publish("ev.sys.drain", env.encode())

proc tempRoot*(tag: string): string =
  ## A unique scratch NIF_ROOT safe across agents and stale PID reuse.
  result = createTempDir("niffler-test-" & tag & "-", "")
  createDir(result / "var")

type TestSandbox* = object
  ## An immutable binary snapshot plus a writable, test-local NIF_ROOT.
  repoRoot*: string
  root*: string

proc sandboxBin*(sandbox: TestSandbox, name: string): string =
  sandbox.root / "var" / "bin" / name

proc newCoreSandbox*(tag: string,
                     components: openArray[string]): TestSandbox =
  ## Create a minimal full-core root. Shipped binaries are copied rather than
  ## linked so a concurrent repository build cannot alter a running test.
  result.repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))
  result.root = tempRoot(tag)
  createDir(result.root / "var" / "bin")
  createDir(result.root / "var" / "build")
  createDir(result.root / "var" / "nimcache")
  createSymlink(result.repoRoot / "sdk", result.root / "sdk")
  writeFile(result.root / "config.nims",
    readFile(result.repoRoot / "config.nims") &
    "\n# Keep agent-built component caches inside this test sandbox.\n" &
    "switch(\"nimcache\", thisDir() / \"var\" / \"nimcache\")\n")
  copyFile(result.repoRoot / "niffler.nimble", result.root / "niffler.nimble")

  var manifest = "components:\n"
  for name in components:
    manifest.add("  - name: " & name & "\n")
    manifest.add("    binary: var/bin/" & name & "\n")
    manifest.add("    autostart: true\n")
    manifest.add("    required: true\n")
    manifest.add("    restart: on-failure\n\n")
    copyFileWithPermissions(result.repoRoot / "var" / "bin" / name,
                            result.sandboxBin(name))
  writeFile(result.root / "manifest.yaml", manifest)
  for name in ["niffler", "session", "cli"]:
    copyFileWithPermissions(result.repoRoot / "var" / "bin" / name,
                            result.sandboxBin(name))
