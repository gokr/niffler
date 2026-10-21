## locks component tests — bus contract for write arbitration
## (docs/research/WRITE-ARBITRATION.md).
##
## The lease table is a store document, so this test runs the real thing: a
## minimal core sandbox with a store plus the locks binary. What it proves, in
## the order the proposal's phase-1 table names them:
## - two sessions, one file: the second claim is refused AND names the first;
## - two sessions, different files of one repo: both succeed (disjoint stays
##   parallel — the whole point of striping, and the failure mode of a naive
##   global lock);
## - an opaque writer (the root stripe) excludes a path-bound one;
## - a lease expires by TTL, so a dead runner cannot wedge the workspace;
## - a claim outside the conversation's workspace is refused outright;
## - release is idempotent (a retry never fails a turn);
## - re-claiming the same call id replaces rather than accumulates.

import std/[algorithm, json, monotimes, os, osproc, strutils, times]
import natsnim
import helpers
import ../core/dispatch

proc checkPure() =
  ## The claim computation for a declared value that may be a glob — verified
  ## directly because it is a pure function and the end-to-end case below can
  ## only show one shape of it. The rule: claim the last directory separator
  ## BEFORE the first wildcard, so every file the pattern can match is
  ## necessarily underneath the claim. Over-claiming is the safe direction.
  check("glob: recursive pattern claims the workspace",
        globClaim("/ws/**/*.go") == "/ws", globClaim("/ws/**/*.go"))
  check("glob: anchored pattern claims its directory",
        globClaim("/ws/src/*.go") == "/ws/src", globClaim("/ws/src/*.go"))
  check("glob: wildcard before a separator cuts higher",
        globClaim("/ws/a*b/c.go") == "/ws", globClaim("/ws/a*b/c.go"))
  check("glob: '?' is a wildcard too",
        globClaim("/ws/a?b.go") == "/ws", globClaim("/ws/a?b.go"))
  check("no wildcard: the path is claimed verbatim",
        globClaim("/ws/plain.go") == "/ws/plain.go", globClaim("/ws/plain.go"))
  check("wildcard with no directory prefix falls back to the workspace",
        globClaim("*.go") == "", globClaim("*.go"))

  # writePathsFor is the gate's whole view of a declaration: a path-bound tool
  # claims its named fields, an opaque one the root, and a missing declaration
  # nothing at all (opaque by default).
  let editSchema = %*{"x-harness": {"writes": {"paths": ["path"]}}}
  check("declared path is claimed",
        writePathsFor(editSchema, %*{"path": "/ws/a.go"}, "/ws") == @["/ws/a.go"],
        $writePathsFor(editSchema, %*{"path": "/ws/a.go"}, "/ws"))
  let globSchema = %*{"x-harness": {"writes": {"paths": ["glob", "paths"]}}}
  check("a glob argument claims its base directory",
        writePathsFor(globSchema, %*{"glob": "/ws/**/*.go"}, "/ws") == @["/ws"],
        $writePathsFor(globSchema, %*{"glob": "/ws/**/*.go"}, "/ws"))
  check("a concrete paths array is claimed file by file",
        writePathsFor(globSchema, %*{"paths": ["/ws/a.go", "/ws/b.go"]}, "/ws") ==
          @["/ws/a.go", "/ws/b.go"],
        $writePathsFor(globSchema, %*{"paths": ["/ws/a.go", "/ws/b.go"]}, "/ws"))
  check("an opaque declaration claims the workspace",
        writePathsFor(%*{"x-harness": {"writes": {"root": true}}}, %*{}, "/ws") ==
          @["/ws"], "")
  check("an undeclared tool is treated as opaque",
        writePathsFor(%*{}, %*{}, "/ws") == @["/ws"], "")
  check("read tools take no claim",
        writePathsFor(%*{"x-harness": {"effect": "read"}}, %*{}, "/ws").len == 0)
  check("orchestrators defer claims to nested dispatch",
        writePathsFor(%*{"x-harness": {"sessionContext": true,
          "writes": {"root": true}}}, %*{}, "/ws").len == 0)
  check("internal model machinery takes no claim",
        writePathsFor(%*{"x-harness": {"hidden": true, "runner": true}},
          %*{}, "/ws").len == 0)

  # Harness-state claims (x-harness.writes.harness): a tool that mutates
  # $NIF_ROOT/var rather than the conversation workspace. The opaque default
  # would claim the workspace it never touches — for a client launched in a
  # project directory (NIF_ROOT != workspace) that guarded nothing at all
  # while serializing unrelated conversations, which is the bug this shape
  # exists to close.
  let harnessSchema = %*{"x-harness": {"writes": {"harness": ["var/plugins"]}}}
  check("a harness claim resolves under $NIF_ROOT/var",
        writePathsFor(harnessSchema, %*{}, "/ws", "/root") == @["/root/var/plugins"],
        $writePathsFor(harnessSchema, %*{}, "/ws", "/root"))
  check("harness claims may name several directories",
        writePathsFor(%*{"x-harness": {"writes":
          {"harness": ["var/plugins", "var/bin"]}}}, %*{}, "/ws", "/root") ==
          @["/root/var/plugins", "/root/var/bin"],
        $writePathsFor(%*{"x-harness": {"writes":
          {"harness": ["var/plugins", "var/bin"]}}}, %*{}, "/ws", "/root"))
  # The control plane is never claimable: SANDBOX-PLAN §6 records that the
  # agent edits the harness's own source tree, so a lease over core/ would be
  # theater. Escapes are refused loudly and yield NO claim rather than the
  # workspace fallback (which would read as protection while guarding the
  # wrong tree).
  check("the harness control plane is not claimable",
        writePathsFor(%*{"x-harness": {"writes": {"harness": ["components"]}}},
          %*{}, "/ws", "/root").len == 0)
  check("an escaping harness claim is refused",
        writePathsFor(%*{"x-harness": {"writes":
          {"harness": ["../etc"]}}}, %*{}, "/ws", "/root").len == 0)
  check("an absolute harness claim is refused",
        writePathsFor(%*{"x-harness": {"writes":
          {"harness": ["/etc/passwd"]}}}, %*{}, "/ws", "/root").len == 0)
  check("an unknown harness root claims nothing",
        writePathsFor(harnessSchema, %*{}, "/ws", "").len == 0)
  # var/ itself is allowed: it is the whole runtime-state directory.
  check("a claim on var/ itself is allowed",
        writePathsFor(%*{"x-harness": {"writes": {"harness": ["var"]}}},
          %*{}, "/ws", "/root") == @["/root/var"],
        $writePathsFor(%*{"x-harness": {"writes": {"harness": ["var"]}}},
          %*{}, "/ws", "/root"))
  # `{"none": true}`: the call mutates no filesystem path. The key says what
  # the GATE does (claim nothing), not where the tool's writes land — the store
  # serializes its own writers, so a filesystem lease would be both redundant
  # and misdirected (it would name the conversation workspace).
  check("a none-declared writer claims no path",
        writePathsFor(%*{"x-harness": {"writes": {"none": true}}},
          %*{}, "/ws").len == 0)
  check("none is not the read-effect shortcut",
        writePathsFor(%*{"x-harness": {"effect": "write",
          "writes": {"none": true}}}, %*{}, "/ws").len == 0)

proc main() =
  checkPure()

  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))

  # A workspace with two files and a subdirectory, so "same file", "different
  # files" and "the whole tree" are all real paths on disk.
  let ws = tempRoot("locks-ws")
  defer: removeDir(ws)
  createDir(ws / "sub")
  writeFile(ws / "a.txt", "a\n")
  writeFile(ws / "b.txt", "b\n")
  writeFile(ws / "sub" / "c.txt", "c\n")

  # A short TTL so the expiry case is a one-second wait, not ten minutes. Set
  # in the environment before the sandbox starts: components inherit it.
  putEnv("NIF_LOCK_TTL_MS", "1500")

  let sandbox = newCoreSandbox("locks", ["store"])
  let root = sandbox.root
  defer: removeDir(root)

  let (server, url) = startNats()
  defer: stopServer(server)

  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                logFile = root / "core.log")
  defer:
    if coreProc.running(): coreProc.terminate()
    discard coreProc.waitForExit(2000)

  var locksProc = startComponent(repoRoot / "var" / "bin" / "locks", url,
                                 root = root, logFile = root / "locks.log")
  defer:
    if locksProc.running(): locksProc.terminate()
    discard locksProc.waitForExit(2000)

  var nc = waitConnect(url)
  defer: nc.close()

  check("locks registers", waitRegistered(nc, "locks"))

  # The store must answer before a claim can be persisted.
  var storeUp = false
  for _ in 0 ..< 50:
    let r = call(nc, "store", "list", %*{"kind": "lock-lease", "limit": 1}, 3000)
    if r{"ok"}.getBool(false):
      storeUp = true
      break
    sleep(200)
  if not storeUp:
    fail("harness never came up"); report("LOCKS TEST")
    quit(1)

  proc acquire(session, callId: string, paths: seq[string],
               tool = "edit"): JsonNode =
    call(nc, "locks", "lock_acquire",
         %*{"root": ws, "roots": [ws], "paths": paths,
            "sessionId": session, "tool": tool, "callId": callId})

  # ── disjoint claims proceed (striping must not serialize a whole repo) ──
  let a1 = acquire("conv-a", "call-1", @[ws / "a.txt"])
  check("first claim ok", a1{"ok"}.getBool(false), $a1)
  let b1 = acquire("conv-b", "call-2", @[ws / "b.txt"])
  check("different file, different session, both ok",
        b1{"ok"}.getBool(false), $b1)

  # ── the same file from another session is refused, and names the holder ──
  let a2 = acquire("conv-b", "call-3", @[ws / "a.txt"])
  check("same file refused", not a2{"ok"}.getBool(true), $a2)
  check("refusal is E_WRITE_BUSY", a2{"error"}.getStr("").contains("E_WRITE_BUSY"), $a2)
  check("refusal names the holder session",
        a2{"error"}.getStr("").contains("conv-a"), $a2)
  check("refusal names the holder's tool",
        a2{"error"}.getStr("").contains("edit"), $a2)
  check("refusal carries structured holder",
        a2{"holder"}.getStr("") == "conv-a", $a2)

  # ── the same call id re-claims in place (a re-dispatch, not a self-block) ──
  let a1again = acquire("conv-a", "call-1", @[ws / "a.txt"])
  check("same call re-claim ok", a1again{"ok"}.getBool(false), $a1again)

  # ── an opaque (root) writer excludes a path-bound one ──
  # Two conversations hold leases under the root at this point (conv-a's a.txt
  # and conv-b's b.txt), so the claim is refused — but WHICH conflicting holder
  # gets named is not part of the contract (the store returns leases in id
  # order, so it is deterministic, just not worth pinning here). The contract is
  # that the named holder is real and is one of the conflicting ones.
  let opq = acquire("conv-c", "call-4", @[ws], tool = "bash")
  check("opaque claim on held paths is refused",
        not opq{"ok"}.getBool(true), $opq)
  check("opaque refusal names a real holder",
        opq{"holder"}.getStr("") in ["conv-a", "conv-b"], $opq)

  # ── a claim outside the workspace is refused, not silently widened ──
  let outside = acquire("conv-d", "call-5", @["/etc/passwd"])
  check("outside-workspace claim refused",
        not outside{"ok"}.getBool(true), $outside)
  check("outside refusal is E_WRITE_OUTSIDE",
        outside{"error"}.getStr("").contains("E_WRITE_OUTSIDE"), $outside)

  # ── release is idempotent and frees the path ──
  let rel = call(nc, "locks", "lock_release", %*{"leaseId": "conv-a:call-1"})
  check("release ok", rel{"ok"}.getBool(false), $rel)
  check("release reports one removal", rel{"released"}.getInt(0) == 1, $rel)
  let relAgain = call(nc, "locks", "lock_release", %*{"leaseId": "conv-a:call-1"})
  check("second release still ok (idempotent)",
        relAgain{"ok"}.getBool(false), $relAgain)
  check("second release removes nothing",
        relAgain{"released"}.getInt(-1) == 0, $relAgain)
  let a3 = acquire("conv-b", "call-6", @[ws / "a.txt"])
  check("freed path is claimable", a3{"ok"}.getBool(false), $a3)

  # ── status lists live leases (expired ones swept) ──
  let st = call(nc, "locks", "lock_status", %*{})
  check("lock_status ok", st{"ok"}.getBool(false), $st)
  check("lock_status shows live leases", st{"count"}.getInt(0) >= 1, $st)

  # ── distinct load claims must succeed (not repeated denials on one file) ──
  # This is the regression guard for the shape of the table. The first
  # implementation kept every lease in one store document and rewrote the whole
  # list per call (~50us per live lease: 54ms at 1000); a per-document version
  # still read the whole table over the bus (~49ms at 1000). The in-memory
  # index made acquire ~flat. A released/replaced table would still get these
  # checks right — the assertion below is the one that catches the cost.
  for i in 0 ..< 120:
    let loadedClaim = call(nc, "locks", "lock_acquire", %*{
      "root": ws, "roots": [ws], "paths": [ws / ("load-" & $i)],
      "sessionId": "conv-load", "tool": "edit", "callId": "load" & $i,
      "ttlMs": 60000})
    check("distinct load claim " & $i, loadedClaim{"ok"}.getBool(false), $loadedClaim)
  let loaded = call(nc, "locks", "lock_status", %*{}, 20000)
  check("table holds all 120 load leases", loaded{"count"}.getInt(0) >= 120, $loaded)
  var samples: seq[float] = @[]
  for i in 0 ..< 12:
    let t0 = getMonoTime()
    let probe = acquire("conv-load", "probe" & $i, @[ws / ("probe-" & $i)])
    check("probe acquires, not denies", probe{"ok"}.getBool(false), $probe)
    discard call(nc, "locks", "lock_release",
                 %*{"leaseId": "conv-load:probe" & $i})
    samples.add((getMonoTime() - t0).inMicroseconds.float / 1000.0)
  samples.sort()
  let medMs = samples[samples.len div 2]
  # Generous: the point is to catch a return to O(live leases), not to police
  # absolute latency. 1000 leases previously cost ~54ms/acquire; a table of 120
  # cost tens of ms too. Anything under ~15ms here means the scan is in memory.
  check("acquire stays cheap with a large live table (med " &
        formatFloat(medMs, ffDecimal, 1) & "ms)", medMs < 15.0,
        "median acquire " & formatFloat(medMs, ffDecimal, 1) & "ms")
  # Release the load leases: they hold sub/c.txt, which the expiry case below
  # also needs, and leaving them live would make that case test the wrong thing.
  for i in 0 ..< 120:
    discard call(nc, "locks", "lock_release",
                 %*{"leaseId": "conv-load:load" & $i}, 10000)

  # ── a dead runner's lease expires: the workspace is not wedged forever ──
  let d1 = acquire("conv-e", "call-7", @[ws / "sub" / "c.txt"])
  check("subtree claim ok", d1{"ok"}.getBool(false), $d1)
  let blocked = acquire("conv-f", "call-8", @[ws / "sub" / "c.txt"])
  check("subtree claim blocks a second writer",
        not blocked{"ok"}.getBool(true), $blocked)
  sleep(1800)  # past NIF_LOCK_TTL_MS
  let afterTtl = acquire("conv-f", "call-9", @[ws / "sub" / "c.txt"])
  check("expired lease no longer blocks", afterTtl{"ok"}.getBool(false), $afterTtl)

  # ── a glob claim is a real directory claim, not the pattern text ──
  # Leftovers from the cases above hold paths in this tree; clear them so the
  # glob section measures only what it means to.
  for id in ["conv-f:call-9", "conv-b:call-6", "conv-c:call-4",
             "conv-anch:call-12"]:
    discard call(nc, "locks", "lock_release", %*{"leaseId": id}, 10000)
  # This is the bug the fix addresses: a glob declared as a path used to arrive
  # as its literal pattern ("/ws/**/*.go"), which prefix-matches no real file,
  # so a glob-based replace_across guarded nothing. The gate now claims the base
  # directory, so a claim out of the same tree conflicts — here simulated by
  # claiming what the gate would: the base directory of a recursive pattern.
  let globStripe = globClaim(ws / "**/*.txt")
  check("a recursive glob claims the workspace directory",
        globStripe == ws, globStripe)
  let globHold = acquire("conv-glob", "call-10", @[globStripe], tool = "replace_across")
  check("glob-base claim ok", globHold{"ok"}.getBool(false), $globHold)
  let underGlob = acquire("conv-rival", "call-11", @[ws / "deep" / "d.txt"])
  check("a file under a glob claim is refused",
        not underGlob{"ok"}.getBool(true), $underGlob)
  check("it names the glob holder", underGlob{"holder"}.getStr("") == "conv-glob",
        $underGlob)
  discard call(nc, "locks", "lock_release", %*{"leaseId": "conv-glob:call-10"})

  # An anchored glob must NOT block a sibling directory outside it.
  createDir(ws / "other")
  let anchored = acquire("conv-anch", "call-12", @[globClaim(ws / "sub" / "*.txt")])
  check("anchored glob claims only its directory",
        anchored{"ok"}.getBool(false), $anchored)
  let sibling = acquire("conv-sib", "call-13", @[ws / "other" / "s.txt"])
  check("a sibling directory is not blocked by an anchored glob",
        sibling{"ok"}.getBool(false), $sibling)

  # A restart must reconstruct durable claims before its first release/acquire.
  let durable = call(nc, "locks", "lock_acquire", %*{
    "root": ws, "roots": [ws], "paths": [ws / "restart-file"],
    "sessionId": "conv-durable", "tool": "edit", "callId": "restart",
    "ttlMs": 60000})
  check("durable claim accepted", durable{"ok"}.getBool(false), $durable)
  locksProc.terminate()
  discard locksProc.waitForExit(2000)
  locksProc.close()
  locksProc = startComponent(repoRoot / "var" / "bin" / "locks", url,
                            root = root, logFile = root / "locks-restart.log")
  var recovered: JsonNode
  for attempt in 0 ..< 30:
    recovered = call(nc, "locks", "lock_status", %*{}, 1000)
    if recovered{"ok"}.getBool(false): break
    sleep(100)
  let restartConflict = acquire("conv-restart-rival", "restart-rival",
                                @[ws / "restart-file"])
  check("restart preserves conflicting holder",
    restartConflict{"holder"}.getStr("") == "conv-durable", $restartConflict)
  let releaseRecovered = call(nc, "locks", "lock_release",
    %*{"leaseId": "conv-durable:restart"})
  check("recovered claim releases", releaseRecovered{"released"}.getInt(0) == 1,
        $releaseRecovered)

  # ── a tool that reads must not take a write claim ──
  # The class of bug this pins, observed live: a read-only tool that declares
  # no `x-harness` at all inherits the WRITE default and claims the whole
  # conversation workspace. Core's own `discover` was then refused by another
  # conversation's `bash` ("[E_WRITE_BUSY] ... discover"), and grep/files —
  # which declare a `workspace` but no effect — claimed every tree they merely
  # searched, serializing unrelated conversations on a read.
  #
  # Checked here against THIS sandbox's catalog (store + locks), which is the
  # point: the rule is a property of every registered tool, so the check names
  # no tool and cannot rot when one is renamed. The specific regressions live
  # in the components' own tests (t_core for discover, t_grep for grep/files),
  # where those tools are actually registered.
  let snap = call(nc, "core", "catalog", %*{"op": "snapshot"}, 10_000)
  var inspected = 0
  var claimants: seq[string]
  for comp in snap{"components"}:
    for t in comp{"tools"}:
      inc inspected
      let tool = comp{"name"}.getStr("") & "." & t{"name"}.getStr("")
      let policy = t{"schema"}{"x-harness"}
      if policy == nil: continue
      # The two ways a tool states "I take no write claim": the read effect
      # (scheduling *and* ownership) and the explicit none.
      if policy{"effect"}.getStr("") == "read" or
         policy{"writes"}{"none"}.getBool(false):
        let claim = writePathsFor(t{"schema"}, %*{}, ws)
        if claim.len > 0:
          claimants.add(tool & " -> " & $claim)
  check("catalog snapshot carries tools to inspect", inspected >= 8, $inspected)
  # Since lock_status declares effect:read, a regression here would show up as
  # the locks component's own read tool holding the workspace.
  check("no read/none tool computes a write claim", claimants.len == 0,
        claimants.join("; "))

  # ── the substrate is never a claimant ──
  # The reported symptom this pins: a conversation's own `bash` (an opaque root
  # claim, held for the length of a long command) refused that same
  # conversation's `store.list` — "[E_WRITE_BUSY] <ws> is being modified by
  # conversation <itself>". The store writes documents, never a filesystem
  # path, and it serializes its own writers, so a workspace lease it takes is
  # both redundant and misdirected: it serializes unrelated conversations and
  # blocks its own conversation's reads behind any in-flight writer.
  var storeTools = 0
  var storeClaims: seq[string]
  for comp in snap{"components"}:
    if comp{"name"}.getStr("") != "store": continue
    for t in comp{"tools"}:
      inc storeTools
      let claim = writePathsFor(t{"schema"}, %*{}, ws)
      if claim.len > 0:
        storeClaims.add("store." & t{"name"}.getStr("") & " -> " & $claim)
  check("the store registers its tools", storeTools >= 5, $storeTools)
  check("no store tool claims a workspace path", storeClaims.len == 0,
        storeClaims.join("; "))
  # And the consequence: a root claim held by one call must not make a store
  # read compute a conflicting one.
  # an earlier case (an anchored glob) legitimately holds part of the tree;
  # release every lease this test still owns before claiming the root.
  for l in call(nc, "locks", "lock_status", %*{}){"leases"}:
    discard call(nc, "locks", "lock_release",
                 %*{"leaseId": l{"leaseId"}.getStr("")})
  let rootHold = acquire("conv-self", "bash-call", @[ws], tool = "bash")
  check("an opaque writer holds the tree", rootHold{"ok"}.getBool(false), $rootHold)
  var conflicts: seq[string]
  for comp in snap{"components"}:
    if comp{"name"}.getStr("") != "store": continue
    for t in comp{"tools"}:
      if writePathsFor(t{"schema"}, %*{}, ws).len > 0:
        conflicts.add(t{"name"}.getStr(""))
  check("no store tool conflicts with its own conversation's root claim",
        conflicts.len == 0, conflicts.join(", "))
  discard call(nc, "locks", "lock_release", %*{"leaseId": "conv-self:bash-call"})

  report("LOCKS TEST")

main()
