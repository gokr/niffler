## Niffler core — entry point.
##
## Boot sequence (docs/REBOOT.md): spawn NATS (if no NIF_NATS_URL) → open catalog →
## resolve manifest + boot profile to binaries → spawn children → converge on
## the required set → serve svc.core.call (tty stdin becomes the admin shell,
## core/tty.nim).
## Core speaks exactly one protocol.

import std/[json, os, osproc, sequtils, streams, strutils, tables, tempfiles,
            terminal, times]
import yaml/tojson
import natswrapper
when defined(posix):
  import std/posix
import ../sdk/dotenv
import approval
import catalog
import conversation
import dispatch
import supervisor
import tty

const minimalComponents = ["store", "bash", "llm"]

var gStop = false

type CoreOptions = object
  recovering: bool
  minimal: bool
  help: bool

proc onSig(sig: cint) {.noconv.} =
  gStop = true

var natsLib = false

proc openNatsLib() =
  if not natsLib:
    let st = nats_Open(-1)
    if not checkStatus(st):
      raise newException(IOError, "nats_Open: " & getErrorString(st))
    natsLib = true

proc spawnNats(): tuple[process: Process, url, monitorUrl: string] =
  ## NATS owns port allocation, so concurrent harnesses cannot win the same
  ## bind-close-start race: try the canonical 4222 first (local clients
  ## default there), and fall back to any free port when it is taken — a
  ## failed bind makes nats-server exit, which retries with -1. The ports
  ## file is needed only during startup.
  let portsDir = createTempDir("niffler-nats-", "")
  try:
    for port in ["4222", "-1"]:
      result.process = startProcess("nats-server",
        args = ["-a", "127.0.0.1", "-p", port, "-m", "-1",
                "--ports_file_dir", portsDir],
        options = {poUsePath})
      var bound = false
      for i in 0 ..< 200:
        for path in walkFiles(portsDir / "*.ports"):
          try:
            let ports = parseFile(path)
            if ports{"nats"} != nil and ports{"nats"}.len > 0:
              result.url = ports{"nats"}[0].getStr("")
            if ports{"monitoring"} != nil and ports{"monitoring"}.len > 0:
              result.monitorUrl = ports{"monitoring"}[0].getStr("")
          except CatchableError:
            discard
        if result.url.len > 0 and result.monitorUrl.len > 0:
          bound = true
          break
        if result.process.peekExitCode() != -1:
          break
        sleep(20)
      if bound:
        return
      if result.process.running():
        result.process.terminate()
        sleep(200)
        if result.process.running():
          result.process.kill()
      result.process.close()
      result.process = nil
      result.url = ""
      result.monitorUrl = ""
    raise newException(IOError, "spawned nats-server did not publish its ports")
  finally:
    removeDir(portsDir)

proc connectWithRetry(url: string, tries = 40): NatsConnection =
  var lastErr = ""
  for i in 0 ..< tries:
    try:
      return connect(url)
    except CatchableError as e:
      lastErr = e.msg
      sleep(250)
  raise newException(IOError, "cannot connect to " & url & ": " & lastErr)

proc loadManifest(root: string): JsonNode =
  ## manifest.yaml bootstraps fresh systems; the DB catalog becomes
  ## authoritative later (docs/REBOOT.md).
  let path = root / "manifest.yaml"
  if not fileExists(path):
    raise newException(IOError, "manifest not found: " & path)
  let nodes = loadToJson(readFile(path))
  if nodes.len == 0:
    raise newException(IOError, "manifest is empty: " & path)
  result = nodes[0]

proc tail(s: string, n: int): string =
  ## Last n bytes of s, snapped forward to a UTF-8 boundary so a multi-byte
  ## character (CJK in compiler output, etc.) is never split into invalid
  ## UTF-8 — a broken rune here would poison the JSON envelope downstream.
  if s.len <= n: return s
  var start = s.len - n
  while start > 0 and (s[start].uint8 and 0xC0) == 0x80:
    inc start  # skip a continuation byte: start at the rune's first byte
  return "…" & s[start .. ^1]

proc rebuildShipped(root: string): bool =
  ## Recover mode: rebuild the shipped binaries from source. The git repo
  ## is the snapshot — var/ is disposable build output (docs/MANUAL.md).
  ## Tries the Makefile front door first, then nimble directly.
  for (tool, args) in [("make", @["build"]), ("nimble", @["all"])]:
    try:
      let p = startProcess(tool, args = args, workingDir = root,
                           options = {poUsePath, poStdErrToStdOut})
      let code = p.waitForExit(600_000)
      let output = p.outputStream.readAll()
      p.close()
      if code == 0:
        echo "core: recover — rebuilt with `" & tool & " " & args.join(" ") & "`"
        return true
      echo "core: recover — `" & tool & " " & args.join(" ") &
           "` failed (exit " & $code & "):"
      echo tail(output, 1200)
    except CatchableError as e:
      echo "core: recover — cannot run " & tool & ": " & e.msg
  return false

proc stopSpawnedBus(serverProc: var Process) =
  ## Terminate the bus this core spawned, escalating to SIGKILL, then reap.
  if serverProc == nil:
    return
  if serverProc.running():
    serverProc.terminate()
    let deadline = epochTime() + 2.0
    while serverProc.running() and epochTime() < deadline:
      sleep(50)
    if serverProc.running():
      serverProc.kill()
      sleep(50)
  serverProc.close()
  serverProc = nil

proc usage(): string =
  ## Command-line help for the system harness.
  """Usage: niffler [--minimal] [--recover]

  --minimal  start only store, bash and llm; do not restore spawned components
  --recover  rebuild shipped binaries and wipe spawned-component records
  -h, --help show this help
"""

proc parseOptions(args: seq[string]): CoreOptions =
  ## Parse independent startup modes; --minimal and --recover may be combined.
  for arg in args:
    case arg
    of "--minimal": result.minimal = true
    of "--recover": result.recovering = true
    of "-h", "--help": result.help = true
    else: raise newException(ValueError, "unknown option: " & arg)

proc main() =
  var options: CoreOptions
  try:
    options = parseOptions(commandLineParams())
  except ValueError as e:
    stderr.writeLine("niffler: " & e.msg)
    stderr.writeLine("Try 'niffler --help'.")
    quit(2)
  if options.help:
    stdout.write(usage())
    return

  let recovering = options.recovering
  let minimalMode = options.minimal
  if recovering:
    echo "core: RECOVER mode — rebuild shipped binaries, wipe spawned-component records"
  if minimalMode:
    echo "core: MINIMAL mode — starting store, bash and llm only"
  let root = getEnv("NIF_ROOT", getAppDir().parentDir().parentDir())
  # .env from cwd and the harness root (existing env always wins)
  loadDotEnv(".env", root / ".env")
  openNatsLib()

  # Signal handlers go up before the bus spawn so a SIGTERM during startup
  # can never leave the spawned nats-server orphaned.
  when defined(posix):
    discard signal(SIGTERM, onSig)
    discard signal(SIGINT, onSig)

  # --- 1. NATS: env/.env → try the default port → spawn if needed ---------
  var natsUrl = getEnv("NIF_NATS_URL")
  var serverProc: Process = nil
  defer:
    stopSpawnedBus(serverProc)
    removeFile(root / "var" / "nats-pid")
  var monitorUrl = ""
  if natsUrl.len == 0:
    # default: prefer a bus already running on 4222; only spawn when absent
    let defaultUrl = "nats://127.0.0.1:4222"
    var spawnBus = getEnv("NIF_NATS_SPAWN") == "1"
    if not spawnBus:
      try:
        var probe = connect(defaultUrl)
        probe.close()
        natsUrl = defaultUrl
        echo "core: using bus at " & natsUrl
      except CatchableError:
        spawnBus = true
    if spawnBus:
      let spawned = spawnNats()
      serverProc = spawned.process
      natsUrl = spawned.url
      monitorUrl = spawned.monitorUrl
      echo "core: spawned nats-server at " & natsUrl &
           " (monitoring " & monitorUrl & ")"
  os.putEnv("NIF_NATS_URL", natsUrl)  # children inherit the bus address
  var nc: NatsConnection
  try:
    nc = connectWithRetry(natsUrl)
  except CatchableError:
    stopSpawnedBus(serverProc)
    raise
  echo "core: connected to " & natsUrl
  # Publish discovery only after the bus is reachable; failed starts must not
  # leave a plausible but stale monitor endpoint behind. The spawned-bus PID
  # lets an operator (or a later cleanup) stop exactly this server if core
  # dies without running its own teardown.
  try:
    createDir(root / "var")
    writeFile(root / "var" / "nats-url", natsUrl & "\n")
    let monitorPath = root / "var" / "nats-monitor-url"
    if monitorUrl.len > 0:
      writeFile(monitorPath, monitorUrl & "\n")
    else:
      removeFile(monitorPath)
    if serverProc != nil:
      writeFile(root / "var" / "nats-pid", $serverProc.processID & "\n")
    else:
      removeFile(root / "var" / "nats-pid")
  except CatchableError:
    discard

  # recover: the repo is the snapshot — rebuild var/bin from source first
  if recovering:
    discard rebuildShipped(root)

  # --- 2. catalog + supervisor ------------------------------------------
  var cat = newCatalog(nc)
  var sup = newSupervisor(root, nc)

  # --- 3. manifest → children --------------------------------------------
  let manifest = loadManifest(root)
  var required: seq[string] = @[]
  for c in manifest{"components"}:
    let name = c{"name"}.getStr("")
    if minimalMode and name notin minimalComponents:
      continue
    let binary = root / c{"binary"}.getStr("")
    if not fileExists(binary):
      echo "core: WARNING missing binary for " & name & " — run `nimble build` (" & binary & ")"
      continue
    discard sup.addChild(name, binary, parsePolicy(c{"restart"}.getStr("on-failure")))
    if minimalMode or c{"required"}.getBool(false):
      required.add(name)
  for c in sup.children:
    sup.startChild(c)

  # --- 4. converge: wait for the required set to register -----------------
  echo "core: waiting for " & required.join(", ") & " ..."
  let deadline = epochTime() + 30
  while epochTime() < deadline:
    if gStop: break
    cat.pump()
    sup.pump(cat)
    var allIn = true
    for name in required:
      if not cat.components.hasKey(name): allIn = false
    if allIn: break
    sleep(100)
  let missing = required.filterIt(not cat.components.hasKey(it))
  if missing.len > 0:
    echo "core: WARNING not all required components registered: " & missing.join(", ")

  # --- 4b. restore spawned components from the store ---------------------
  # Persistence of shape: components added via core.spawn come back on boot.
  # Recover mode wipes those records first — back to the selected boot profile.
  var approval = newApproval(nc, cat, isatty(stdin))
  var ct = CoreTools(nc: nc, cat: cat, sup: sup, approval: approval,
                     root: root, runner: false,
                     pending: PendingCalls(items: @[]),
                     tokenStream: new(TokenStream),
                     steerStream: new(SteerStream))
  # Slash registry checkpoint (docs/WIRE.md): every catalog change persists
  # the merged table to the store BEFORE ev.catalog.updated goes out, so a UI
  # reading store-first after the event never sees a stale table. Best effort:
  # when the store is down the live catalog remains authoritative.
  cat.onChange = proc (cat: Catalog) =
    try:
      if not cat.components.hasKey("store"): return
      discard ct.dispatchToolCall("put", %*{
        "kind": "slash", "id": "slash", "value": cat.slashTable()})
    except CatchableError as e:
      echo "core: WARNING slash checkpoint failed (store down?): " & e.msg
  # Components that registered during convergence announced before the hook
  # existed; checkpoint the current table once now.
  if cat.sortedSlashCommands().len > 0:
    cat.onChange(cat)
  # Delegated child-runner preparation: the closure captures the master
  # CoreTools by reference, so ensureRunner's supervisor mutations (spawn a
  # session runner) land on the live state. Serves the "session_prepare"
  # core tool (see dispatch.nim handleCoreTool).
  ct.prepareSession = proc(sessionId: string): JsonNode =
    %*{"subject": ensureRunner(ct, sessionId)}
  # Persisted per-conversation auto-approve: the gate consults the store so
  # a decision made in any client (TUI, web UI) is honored everywhere and no
  # dialog is shown at all for auto-approved tools.
  approval.checkAuto = proc(session, tool: string): bool =
    try:
      let resp = ct.dispatchToolCall("get", %*{"kind": "approval",
        "id": session & ":" & tool})
      return resp{"ok"}.getBool(false)
    except CatchableError:
      return false
  if cat.components.hasKey("store"):
    if recovering:
      echo "core: recover — wiping stored component records (spawned components will not be restored)"
      try:
        let resp = ct.dispatchToolCall("list", %*{"kind": "component"})
        for item in resp{"items"}:
          let id = item{"id"}.getStr("")
          if id.len > 0:
            discard ct.dispatchToolCall("del", %*{"kind": "component", "id": id})
      except CatchableError as e:
        echo "core: WARNING recover wipe failed: " & e.msg
    if minimalMode:
      echo "core: minimal mode — persisted spawned components stay stopped"
    else:
      try:
        let resp = ct.dispatchToolCall("list", %*{"kind": "component"})
        for item in resp{"items"}:
          let name = item{"id"}.getStr("")
          let binary = item{"value"}{"binary"}.getStr("")
          if name.len == 0 or binary.len == 0: continue
          var alreadyManifest = false
          for c in sup.children:
            if c.name == name: alreadyManifest = true
          if alreadyManifest: continue  # shipped manifest definition wins
          if fileExists(binary):
            echo "core: restoring " & name & " from store (" & binary & ")"
            discard sup.addChild(name, binary,
              parsePolicy(item{"value"}{"policy"}.getStr("on-failure")))
            sup.startChild(sup.children[^1])
          else:
            echo "core: WARNING stored component " & name &
                 " has missing binary: " & binary
      except CatchableError as e:
        echo "core: WARNING cannot restore components from store: " & e.msg

  # --- 5. service surface ----------------------------------------------------
  # tty stdin: the admin shell (status commands — core/tty.nim). Otherwise:
  # serve svc.core.call for UIs (session ensure+forward to runners, spawn/catalog).
  # NIF_AUTOSTART=1 (set by an SDK's ensureHarness when a UI had to spawn us):
  # this core is UI-owned service — it exits when the last interactive client
  # (reg.publish client:true) departs, or if none ever arrives. A manually
  # started core (no marker) never self-terminates on client churn.
  let autostart = getEnv("NIF_AUTOSTART") == "1"
  let idleAfter = parseFloat(getEnv("NIF_AUTOSTART_IDLE_S", "10"))
  let bootGrace = parseFloat(getEnv("NIF_AUTOSTART_BOOT_S", "60"))
  var coreSub: ptr natsSubscription
  let cs = natsConnection_QueueSubscribeSync(addr coreSub, nc.conn,
                                             "svc.core.call".cstring,
                                             "core".cstring)
  if not checkStatus(cs):
    raise newException(IOError, "subscribe svc.core.call: " & getErrorString(cs))
  ct.coreSub = coreSub
  echo "core: serving svc.core.call (session ensures+forwards to runners, spawn/catalog)"

  if isatty(stdin) and not autostart:
    try:
      runAdminShell(ct,
        proc() = (pumpCoreCalls(ct, coreSub); cat.pump(); sup.pump(cat)),
        proc(): bool = gStop)
    except EOFError:
      discard
    except CatchableError as e:
      echo "core: " & e.msg
  else:
    echo "core: service mode (no tty) — serving svc.core.call"
    if autostart:
      echo "core: autostarted by a UI — exits when the last interactive client departs"
    var sawClients = false
    var lastClientLeft = 0.0
    let bootedAt = epochTime()
    while not gStop:
      pumpCoreCalls(ct, coreSub)
      cat.pump()
      sup.pump(cat)
      if autostart:
        let clients = cat.clientCount()
        if clients > 0:
          sawClients = true
          lastClientLeft = 0.0
        elif sawClients:
          # debounce: a restarting UI re-registers within the idle window
          if lastClientLeft == 0.0:
            lastClientLeft = epochTime()
          elif epochTime() - lastClientLeft >= idleAfter:
            echo "core: last interactive client departed — autostarted harness shutting down"
            break
        elif epochTime() - bootedAt >= bootGrace:
          echo "core: no interactive client arrived within boot grace — shutting down"
          break
      sleep(20)

  # --- 6. teardown ----------------------------------------------------------
  echo ""
  echo "core: shutting down"
  sup.drain()
  cat.nc.close()
  stopSpawnedBus(serverProc)
  echo "core: bye"

when isMainModule:
  main()
