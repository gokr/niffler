## Niffler core — entry point.
##
## Boot sequence (docs/REBOOT.md): spawn NATS (if no NIF_NATS_URL) → open catalog →
## resolve manifest to binaries → spawn children → converge on the required
## set → conversation loop. Core speaks exactly one protocol.

import std/[json, net, os, osproc, sequtils, streams, strutils, tables, terminal, times]
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

var gStop = false

proc onSig(sig: cint) {.noconv.} =
  gStop = true

var natsLib = false

proc openNatsLib() =
  if not natsLib:
    let st = nats_Open(-1)
    if not checkStatus(st):
      raise newException(IOError, "nats_Open: " & getErrorString(st))
    natsLib = true

proc pickNatsPort(): int =
  ## Prefer the well-known port (the UI's default); fall back to any free port.
  var s = newSocket()
  try:
    s.bindAddr(Port(4222))
    s.close()
    return 4222
  except CatchableError:
    discard
  var s2 = newSocket()
  s2.bindAddr(Port(0))
  result = int(s2.getLocalAddr()[1])
  s2.close()

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
  if s.len <= n: return s
  return "…" & s[^n .. ^1]

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

proc main() =
  let recovering = paramCount() >= 1 and paramStr(1) == "--recover"
  if recovering:
    echo "core: RECOVER mode — rebuild shipped binaries, wipe spawned-component records"
  let root = getEnv("NIF_ROOT", getAppDir().parentDir().parentDir())
  # .env from cwd and the harness root (existing env always wins)
  loadDotEnv(".env", root / ".env")
  openNatsLib()

  # --- 1. NATS: env/.env → try the default port → spawn if needed ---------
  var natsUrl = getEnv("NIF_NATS_URL")
  var serverProc: Process = nil
  if natsUrl.len == 0:
    # default: prefer a bus already running on 4222; only spawn when absent
    let defaultUrl = "nats://127.0.0.1:4222"
    try:
      var probe = connect(defaultUrl)
      probe.close()
      natsUrl = defaultUrl
      echo "core: using bus at " & natsUrl
    except CatchableError:
      let port = pickNatsPort()
      natsUrl = "nats://127.0.0.1:" & $port
      echo "core: spawning nats-server on port " & $port
      serverProc = startProcess("nats-server", args = ["-p", $port],
                                options = {poUsePath})
  os.putEnv("NIF_NATS_URL", natsUrl)  # children inherit the bus address
  # discovery file for UIs: the bridge reads var/nats-url when NIF_NATS_URL unset
  try:
    createDir(root / "var")
    writeFile(root / "var" / "nats-url", natsUrl & "\n")
  except CatchableError:
    discard
  let nc = connectWithRetry(natsUrl)
  echo "core: connected to " & natsUrl

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
    let binary = root / c{"binary"}.getStr("")
    if not fileExists(binary):
      echo "core: WARNING missing binary for " & name & " — run `nimble build` (" & binary & ")"
      continue
    discard sup.addChild(name, binary, parsePolicy(c{"restart"}.getStr("on-failure")))
    if c{"required"}.getBool(false):
      required.add(name)
  for c in sup.children:
    sup.startChild(c)

  # --- 4. converge: wait for the required set to register -----------------
  echo "core: waiting for " & required.join(", ") & " ..."
  let deadline = epochTime() + 30
  while epochTime() < deadline:
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
  # Recover mode wipes those records first — back to the manifest set.
  var approval = newApproval(nc, cat, isatty(stdin))
  var ct = CoreTools(nc: nc, cat: cat, sup: sup, approval: approval,
                     root: root, runner: false,
                     pending: PendingCalls(items: @[]),
                     tokenStream: new(TokenStream))
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

  # --- 5. conversation loop -------------------------------------------------
  # interactive (tty): stdin loop. service mode: serve svc.core.call for UIs.
  var coreSub: ptr natsSubscription
  let cs = natsConnection_QueueSubscribeSync(addr coreSub, nc.conn,
                                             "svc.core.call".cstring,
                                             "core".cstring)
  if not checkStatus(cs):
    raise newException(IOError, "subscribe svc.core.call: " & getErrorString(cs))
  ct.coreSub = coreSub
  echo "core: serving svc.core.call (session ensures+forwards to runners, spawn/catalog)"

  when defined(posix):
    discard signal(SIGTERM, onSig)
    discard signal(SIGINT, onSig)

  if isatty(stdin):
    try:
      runConversation(ct, proc() = pumpCoreCalls(ct, coreSub))
    except EOFError:
      discard
    except CatchableError as e:
      echo "core: " & e.msg
  else:
    echo "core: service mode (no tty) — serving svc.core.call"
    while not gStop:
      pumpCoreCalls(ct, coreSub)
      cat.pump()
      sup.pump(cat)
      sleep(20)

  # --- 6. teardown ----------------------------------------------------------
  echo ""
  echo "core: shutting down"
  sup.drain()
  cat.nc.close()
  if serverProc != nil:
    serverProc.terminate()
    serverProc.close()
  echo "core: bye"

when isMainModule:
  main()
