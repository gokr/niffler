## mini Niffler core — entry point.
##
## Boot sequence (docs/REBOOT.md): spawn NATS (if no NATS_URL) → open catalog →
## resolve manifest to binaries → spawn children → converge on the required
## set → conversation loop. Core speaks exactly one protocol.

import std/[json, net, os, osproc, sequtils, strutils, tables, terminal, times]
import yaml/tojson
import natswrapper
when defined(posix):
  import std/posix
import ../sdk/dotenv
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

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir().parentDir())
  # .env from cwd and the harness root (existing env always wins)
  loadDotEnv(".env", root / ".env")
  openNatsLib()

  # --- 1. NATS: env/.env → try the default port → spawn if needed ---------
  var natsUrl = getEnv("NATS_URL")
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
  os.putEnv("NATS_URL", natsUrl)  # children inherit the bus address
  # discovery file for UIs: the bridge reads var/nats-url when NATS_URL unset
  try:
    createDir(root / "var")
    writeFile(root / "var" / "nats-url", natsUrl & "\n")
  except CatchableError:
    discard
  let nc = connectWithRetry(natsUrl)
  echo "core: connected to " & natsUrl

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
    discard sup.addChild(name, binary)
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
  var ct = CoreTools(nc: nc, cat: cat, sup: sup)
  if cat.components.hasKey("store"):
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
          discard sup.addChild(name, binary)
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
  echo "core: serving svc.core.call (session/spawn/catalog)"
  var sessions = initTable[string, Session]()

  when defined(posix):
    discard signal(SIGTERM, onSig)
    discard signal(SIGINT, onSig)

  if isatty(stdin):
    try:
      runConversation(ct, proc() = pumpCoreCalls(ct, coreSub, sessions))
    except EOFError:
      discard
    except CatchableError as e:
      echo "core: " & e.msg
  else:
    echo "core: service mode (no tty) — serving svc.core.call"
    while not gStop:
      pumpCoreCalls(ct, coreSub, sessions)
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
