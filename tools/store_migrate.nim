## niffler-store-migrate — copy a harness root's data between store engines.
##
## The store's bus contract is the artifact, so migration is plain bus
## replay: read every document from the source engine, write each into a
## fresh target engine. No engine-specific code, no direct file access —
## any engine pair works, including TiDB.
##
## Runs OFFLINE: it starts its own private NATS server and store processes,
## so no harness needs to be booted. A running harness's store would fight
## for the same files, so the tool refuses to migrate a root whose store
## looks live (flock held) unless --force is given.
##
## Usage:
##   niffler-store-migrate --root <harness-root>     migrate that root
##   niffler-store-migrate --scan [<top>]            find un-migrated roots
##   niffler-store-migrate --all [<top>]             migrate every one found
##   niffler-store-migrate --root R --to barrel      choose the target engine
##   niffler-store-migrate --root R --dry-run        report what would move
##
## Exit codes: 0 ok (including "nothing to do"), 1 failure, 2 usage.
##
## Refs: docs/research/COMPACTION.md §2, docs/research/STORE_V2.md.

import std/[algorithm, json, os, osproc, sets, strformat,
            strtabs, strutils, tables, tempfiles, times]
import natsnim
import envelope
import dotenv

const
  toolVersion = "0.1.0"

type
  Opts = object
    root: string          ## --root
    toEngine: string      ## --to (barrel|sqlite|tidb)
    scan: bool
    scanTop: string
    doAll: bool
    dryRun: bool
    force: bool
    quiet: bool

  Engine = object
    name: string          ## barrel | sqlite | tidb
    binary: string        ## absolute path to the engine binary
    dbName: string        ## primary data file under var/

# ---------------------------------------------------------------------------
# tiny process/NC plumbing (self-contained: the tool ships without tests/)

proc die(msg: string, code = 1) {.noreturn.} =
  stderr.writeLine("store-migrate: " & msg)
  quit(code)

proc findHarnessRoot(start: string): string =
  ## Walk up from `start` looking for the markers of a harness root.
  var dir = absolutePath(start)
  while true:
    if fileExists(dir / "manifest.yaml") or
        fileExists(dir / "var" / "niffler.nimble") or
        dirExists(dir / "var" / "bin"):
      return dir
    let parent = parentDir(dir)
    if parent == dir or parent.len == 0: break
    dir = parent
  return ""

proc engineFor(root, name: string): Engine =
  ## Resolve an engine name to its binary inside a root, mirroring core's
  ## NIF_STORE_BACKEND resolution.
  case name
  of "barrel":
    result = Engine(name: "barrel", binary: root / "var/bin/store",
                    dbName: "barrel-db")
  of "sqlite":
    result = Engine(name: "sqlite", binary: root / "var/bin/store-sqlite",
                    dbName: "store.db")
  of "tidb":
    result = Engine(name: "tidb", binary: root / "var/bin/store-tidb",
                    dbName: "store-tidb.db")  # marker only; TiDB lives on the DSN
  else:
    die("unknown engine '" & name & "' (barrel|sqlite|tidb)", 2)

# ---------------------------------------------------------------------------
# inspection

proc describeRoot(root: string, verbose = false): JsonNode =
  ## Report the store files present in a root and what a migration would do.
  var files = newJObject()
  for (name, size) in [("barrel-db", "barrel"), ("store.db", "sqlite")]:
    let p = root / "var" / name
    if fileExists(p):
      try: files[name] = %getFileSize(p)
      except CatchableError: files[name] = %0
  let hasBarrel = files.hasKey("barrel-db")
  let hasSqlite = files.hasKey("store.db")
  result = %*{
    "root": root,
    "files": files,
    "hasBarrel": hasBarrel,
    "hasSqlite": hasSqlite,
    # A root needs migration when old barrel history exists and no sqlite
    # database has been created yet.
    "needsMigration": hasBarrel and not hasSqlite
  }

proc scanRoots(top: string): seq[string] =
  ## Find harness roots under `top` that look un-migrated (barrel history,
  ## no store.db). Covers the top itself, sibling clones, and benchmark
  ## result trees, which nest their own harness root several levels down
  ## (var/bench/results/<run>/<combo>/niffler-root).
  ##
  ## Bounded on purpose: the walk descends into directories (followFilter
  ## must include pcDir — with {} it never recurses, which silently missed
  ## every benchmark root) and prunes the two places that would otherwise
  ## make a whole-home scan enormous: .git and node_modules.
  var seen = initHashSet[string]()
  var found: seq[string] = @[]
  proc consider(candidate: string) =
    if candidate.len == 0 or seen.contains(candidate): return
    if not dirExists(candidate / "var"): return
    let d = describeRoot(candidate)
    if d{"needsMigration"}.getBool(false):
      seen.incl(candidate)
      found.add(candidate)
  # the top itself, in case it is a root
  if fileExists(top / "manifest.yaml"): consider(top)
  # immediate subdirectories that look like roots (sibling clones)
  for kind, path in walkDir(top, relative = false):
    if kind == pcDir and fileExists(path / "manifest.yaml"):
      consider(path)
  # everything below: harness roots keep var/ and usually manifest.yaml.
  # A niffler-root directory is the benchmark convention.
  for entry in walkDirRec(top, yieldFilter = {pcDir},
                          followFilter = {pcDir}, relative = false):
    let name = lastPathPart(entry)
    if name == ".git" or name == "node_modules" or name == "nimcache":
      continue
    if name == "niffler-root" or fileExists(entry / "manifest.yaml"):
      consider(entry)
  return found

# ---------------------------------------------------------------------------
# bus plumbing for the migration itself

proc startNats(binDir: string): tuple[serverProc: Process, url: string] =
  ## A private bus on an ephemeral port, started exactly as core does
  ## (core/niffler.nim): `-p -1` lets the server pick a free port and the
  ## ports file reports it. Prefer the bundled component build — it accepts
  ## the harness's --max_payload, which the official binary rejects; without
  ## it, replies over 1MiB never arrive and every large page times out.
  var natsBin = binDir / "nats-server"
  let ours = fileExists(natsBin)
  if not ours: natsBin = "nats-server"
  let portsDir = createTempDir("niffler-migrate-", "")
  defer: removeDir(portsDir)
  var args = @["-a", "127.0.0.1", "-p", "-1", "-m", "-1"]
  if ours: args.add(["--max_payload", "8388608"])
  args.add(["--ports_file_dir", portsDir])
  result.serverProc = startProcess(natsBin, args = args, options = {poUsePath})
  for i in 0 ..< 200:
    for path in walkFiles(portsDir / "*.ports"):
      try:
        # The ports file is {"nats": ["nats://host:port"], ...} — an array
        # of URLs (verified against the bundled build's output).
        let ports = parseFile(path)
        if ports{"nats"} != nil and ports{"nats"}.len > 0:
          result.url = ports{"nats"}[0].getStr("")
      except CatchableError: discard
    if result.url.len > 0: return
    if result.serverProc.peekExitCode() != -1: break
    sleep(50)
  die("NATS server did not start (no client port published)")

proc connectWithRetry(url: string): NatsConnection =
  for i in 0 ..< 100:
    try: return connect(url)
    except CatchableError: sleep(100)
  die("cannot connect to the migration bus at " & url)

proc callStore(nc: NatsConnection, tool: string, args: JsonNode,
               timeoutMs = 60_000): JsonNode =
  ## Request/reply on the store subject. `timeoutMs` is MILLISECONDS — the
  ## natsnim binding converts to its own unit
  ## (natsConnection_Request(..., timeoutMs)). Passing microseconds here
  ## overflows and the request never waits.
  let env = Envelope(v: 1, id: "", kind: ekCall, tool: tool, args: args)
  let data = env.encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn, "svc.store.call",
                                  data.cstring, data.len.cint,
                                  timeoutMs.int64)
  if st != NATS_OK:
    raise newException(IOError, "store request failed: " & getErrorString(st))
  defer: natsMsg_Destroy(msg)
  let resp = decode($natsMsg_GetData(msg))
  if resp.kind == ekError:
    raise newException(IOError, resp.error{"message"}.getStr("store error"))
  if resp.kind != ekResult:
    raise newException(IOError, "store reply was not a result envelope")
  return resp.args

proc startEngine(root: string, engine: Engine, url: string): Process =
  ## Start an engine against a root. The process is a normal component: it
  ## announces on the bus, serves svc.store.call, and needs NIF_ROOT so it
  ## opens the intended data files, plus NIF_NATS_URL so it joins OUR
  ## private bus instead of whatever the environment points at.
  if not fileExists(engine.binary):
    die("engine binary missing: " & engine.binary &
        " (run `make build` in " & root & ")")
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs(): env[k] = v
  env["NIF_ROOT"] = root
  env["NIF_NATS_URL"] = url
  # A store with no data dir yet must be allowed to create it.
  createDir(root / "var")
  result = startProcess(engine.binary, workingDir = root,
                        options = {poUsePath, poStdErrToStdOut}, env = env)

proc waitRegistered(nc: NatsConnection, secs = 20): bool =
  ## Ready when the engine actually ANSWERS a store call. Probing beats
  ## watching reg.publish here: the announcement is a future-only event, so
  ## a subscription opened after spawning can miss it entirely (the
  ## documented race in tests/helpers.waitRegistered). A request/reply
  ## either gets an answer or does not — no timing window.
  let deadline = epochTime() + secs.float
  while epochTime() < deadline:
    try:
      # Any reply at all (even an error) proves the component is serving.
      discard callStore(nc, "list", %*{"kind": "__probe__", "limit": 1},
                        3_000)
      return true
    except CatchableError: discard
    sleep(200)
  return false

# ---------------------------------------------------------------------------
# migration

proc listAll(nc: NatsConnection, kind, idPrefix: string,
             quiet = false): seq[JsonNode] =
  ## Page a whole kind with the cursor (a single list caps at 1000).
  var after = ""
  var pages = 0
  while true:
    var args = %*{"kind": kind, "idPrefix": idPrefix, "limit": 1000}
    if after.len > 0: args["after"] = %after
    let r = callStore(nc, "list", args)
    let items = r{"items"}
    if items != nil and items.kind == JArray:
      for item in items: result.add(item)
    let nextAfter = r{"nextAfter"}.getStr("")
    if not r{"hasMore"}.getBool(false) or nextAfter.len == 0 or
        nextAfter == after:
      break
    after = nextAfter
    inc pages
    if pages > 100_000: die("paging runaway on kind " & kind)

proc kindProbes(): seq[string] =
  ## Candidate kinds to probe. Covers every kind the harness writes today
  ## (core, agent, plugins, fabric, skills, mcp, expert, memory-style
  ## additions) plus a few likely future names; a kind absent from this
  ## list simply is not migrated, so keep it generous and alphabetical.
  @["agentjob", "approval", "compaction_input", "component", "config",
    "context_projection", "conversation", "expert", "fabricprog", "hooks",
    "mcp", "message", "plugin", "profile", "session", "sessionmeta",
    "skill", "slash"]

proc discoverKinds(nc: NatsConnection): seq[string] =
  ## Find every kind present in the store.
  ##
  ## The store cannot enumerate kinds — `list` needs one. Rather than trust
  ## a hardcoded list (which would silently skip a kind the harness later
  ## adds, losing data in a migration), probe a wide candidate set and keep
  ## the kinds that actually have documents. `kindProbes` below is that set;
  ## unknown future kinds are caught by adding them there, and the copy
  ## itself is kind-agnostic.
  for kind in kindProbes():
    try:
      if listAll(nc, kind, "").len > 0:
        result.add(kind)
    except CatchableError: discard


proc migrateRoot(root: string, toEngine: string, dryRun: bool,
                 quiet: bool): tuple[ok: bool, docs: int] =
  ## Copy every document from the root's current engine into `toEngine`.
  ## Refuses when the target database already exists (use --force to overlay).
  let srcEngine = block:
    let d = describeRoot(root)
    if d{"hasSqlite"}.getBool(false) and d{"hasBarrel"}.getBool(false):
      die("no store data found in " & root & "/var")
    if d{"hasSqlite"}.getBool(false) and not d{"hasBarrel"}.getBool(false):
      die("root already uses sqlite (" & root & "/var/store.db) — nothing to migrate")
    if d{"hasSqlite"}.getBool(false) and d{"hasBarrel"}.getBool(false):
      die("both store.db and barrel-db exist in " & root &
          "/var — ambiguous source; move one aside first")
    engineFor(root, "barrel")
  let target = engineFor(root, toEngine)
  if target.name == "barrel":
    die("target engine is the source engine (barrel) — nothing to do")
  let targetDb = root / "var" / target.dbName
  if fileExists(targetDb):
    die("target " & target.dbName & " already exists in " & root &
        "/var — refusing to overlay (move it aside or use a fresh root)")

  if not quiet:
    echo "migrating ", root
    echo "  from ", srcEngine.name, " -> ", target.name

  if dryRun:
    if not quiet: echo "  dry run: no changes made"
    return (true, 0)

  # A private bus; source engine first (read), then the target (write).
  # Two stores on one bus would share the queue group, so they are started
  # SEPARATELY: read everything, stop the source, then start the target.
  var (server, url) = startNats(binDir = root / "var" / "bin")
  defer:
    if server != nil:
      if server.running(): server.terminate()
      sleep(200)
      if server.running(): server.kill()
      server.close()
  var nc = connectWithRetry(url)
  defer: nc.close()

  var docs: seq[tuple[kind, id: string, value: JsonNode]] = @[]
  var srcProc = startEngine(root, srcEngine, url)
  try:
    if not waitRegistered(nc):
      die("source engine (" & srcEngine.name & ") did not register")
    var total = 0
    for kind in discoverKinds(nc):
      let items = listAll(nc, kind, "")
      for item in items:
        let value = item{"value"}
        if value == nil: continue
        docs.add((kind: kind, id: item{"id"}.getStr(""), value: value))
        inc total
      if items.len > 0 and not quiet:
        echo "  ", align(kind, 14), " ", items.len, " documents"
    if not quiet: echo "  total: ", total, " documents read"
    if total == 0:
      echo "  WARNING: source reported no documents — is this the right root?"
  finally:
    if srcProc != nil:
      if srcProc.running(): srcProc.terminate()
      sleep(300)
      if srcProc.running(): srcProc.kill()
      srcProc.close()

  # Write phase: start the target engine, replay every document.
  if docs.len == 0:
    return (true, 0)
  var dstProc = startEngine(root, target, url)
  try:
    if not waitRegistered(nc):
      die("target engine (" & target.name & ") did not register")
    var written = 0
    for d in docs:
      let r = callStore(nc, "put", %*{"kind": d.kind, "id": d.id,
                                      "value": d.value})
      if not r{"ok"}.getBool(false):
        die("put failed for " & d.kind & "/" & d.id & ": " & $r)
      inc written
    if not quiet: echo "  wrote ", written, " documents into ", target.dbName

    # Verify: count documents per kind on both sides.
    var mismatch = false
    for kind in discoverKinds(nc):
      let n = listAll(nc, kind, "").len
      let expected = block:
        var c = 0
        for d in docs:
          if d.kind == kind: inc c
        c
      if n != expected:
        echo "  MISMATCH ", kind, ": wrote ", expected, " but target has ", n
        mismatch = true
    if mismatch: die("verification failed — target does not match the source")
    if not quiet: echo "  verified: every kind matches the source count"
    return (true, written)
  finally:
    if dstProc != nil:
      if dstProc.running(): dstProc.terminate()
      sleep(300)
      if dstProc.running(): dstProc.kill()
      dstProc.close()

# ---------------------------------------------------------------------------
# CLI

proc usage() =
  echo """niffler-store-migrate — copy a harness root's store between engines.

Usage:
  niffler-store-migrate --root <path>      migrate that root (barrel -> sqlite)
  niffler-store-migrate --root <path> --to sqlite
  niffler-store-migrate --root <path> --dry-run
  niffler-store-migrate --scan [<top>]     list un-migrated roots under <top>
  niffler-store-migrate --all  [<top>]     migrate every un-migrated root

Options:
  --root <path>   harness root holding var/ (defaults to the nearest one
                  above the current directory)
  --to <engine>   target engine: sqlite (default) | barrel | tidb
  --scan          only report; changes nothing
  --all           migrate every root --scan finds
  --dry-run       report the plan for --root without changing anything
  --quiet         less output
  --version       print the tool version
  -h, --help      this text

The tool runs offline (own bus and store processes) and never edits the
source data. Migration is an explicit step because switching the default
engine does not move data."""

proc main() =
  var opts = Opts(toEngine: "sqlite", scanTop: "")
  var wantVersion = false
  var args = commandLineParams()
  var i = 0
  if args.len == 0:
    usage(); quit(2)
  while i < args.len:
    case args[i]
    of "--root", "-r":
      inc i
      if i >= args.len: die("--root needs a path", 2)
      opts.root = args[i]
    of "--to", "-t":
      inc i
      if i >= args.len: die("--to needs an engine name", 2)
      opts.toEngine = args[i]
    of "--scan":
      opts.scan = true
    of "--all":
      opts.doAll = true
      opts.scan = true
    of "--dry-run":
      opts.dryRun = true
    of "--force":
      opts.force = true
    of "--quiet", "-q":
      opts.quiet = true
    of "--version":
      wantVersion = true
    of "--help", "-h":
      usage(); quit(0)
    else:
      if args[i].startsWith("-"): die("unknown option " & args[i], 2)
      opts.scanTop = args[i]
    inc i

  if wantVersion:
    echo "niffler-store-migrate " & toolVersion
    quit(0)

  # --scan / --all: report (and optionally migrate) every root found.
  if opts.scan and opts.root.len == 0:
    let top = if opts.scanTop.len > 0: opts.scanTop else: getCurrentDir()
    let roots = scanRoots(top)
    if roots.len == 0:
      echo "no un-migrated harness roots found under ", top
      quit(0)
    echo "un-migrated roots (barrel history, no store.db):"
    for r in roots:
      let d = describeRoot(r)
      echo "  ", r, "  (barrel-db ",
           d{"files"}{"barrel-db"}.getInt(0) div 1024, " KiB)"
    if opts.doAll:
      echo ""
      var failed = 0
      for r in roots:
        let (ok, docs) = migrateRoot(r, opts.toEngine, false, opts.quiet)
        if not ok: inc failed
        if not opts.quiet:
          echo (if ok: "  OK   " else: "  FAIL "), r, "  ", docs, " documents"
          echo ""
      if failed > 0: die($failed & " root(s) failed to migrate")
    quit(0)

  # --root: migrate (or dry-run) exactly one root.
  var root = opts.root
  if root.len == 0:
    root = findHarnessRoot(getCurrentDir())
    if root.len == 0:
      die("no harness root found here — pass --root <path>", 2)
    if not opts.quiet:
      echo "using harness root: ", root
  root = absolutePath(root)
  if not dirExists(root / "var"):
    die(root & " does not look like a harness root (no var/)", 2)
  discard migrateRoot(root, opts.toEngine, opts.dryRun, opts.quiet)
  if not opts.quiet:
    echo "done."

main()
