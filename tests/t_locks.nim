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

proc main() =
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

  let locksProc = startComponent(repoRoot / "var" / "bin" / "locks", url,
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

  # ── acquire cost does not grow with the number of LIVE leases ──
  # This is the regression guard for the shape of the table. The first
  # implementation kept every lease in one store document and rewrote the whole
  # list per call (~50us per live lease: 54ms at 1000); a per-document version
  # still read the whole table over the bus (~49ms at 1000). The in-memory
  # index made acquire ~flat. A released/replaced table would still get these
  # checks right — the assertion below is the one that catches the cost.
  for i in 0 ..< 120:
    discard acquire("conv-load", "load" & $i, @[ws / "sub" / "c.txt"])
  let loaded = call(nc, "locks", "lock_status", %*{}, 20000)
  check("table holds the load leases", loaded{"count"}.getInt(0) >= 1, $loaded)
  var samples: seq[float] = @[]
  for i in 0 ..< 12:
    let t0 = getMonoTime()
    discard acquire("conv-load", "probe" & $i, @[ws / "sub" / "c.txt"])
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

  report("LOCKS TEST")

main()
