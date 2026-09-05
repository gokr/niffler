## bench-stores — run the same synthetic workload through the store bus
## contract against both engines (barrel + sqlite) and print a comparison.
##
## The store's contract is the artifact, so the bench is a plain bus client:
## identical envelope calls (put/get/list/del), identical client, identical
## bus, only the engine binary differs. docs/research/STORE_V2.md M5.
##
## Build & run (uses tests/helpers.nim for identical bus plumbing):
##   nim c --hints:off --path:sdk --path:tests -o:var/bin/bench-stores \
##     tools/bench_stores.nim
##   ./var/bin/bench-stores                        # both engines
##   ENGINE=var/bin/store ./var/bin/bench-stores   # one engine
##
## Note: numbers are END-TO-END (request/reply over NATS included — the
## contract latency callers actually see), not raw engine throughput.

import std/[json, os, osproc, sequtils, strformat, strutils, tempfiles, times]
import natswrapper
import envelope
import helpers

const
  seqDocs = 1500        # point docs, ~300 B each
  bigDocs = 200         # ~4 KB each
  updates = 1500        # CAS updates (expectRev)
  gets = 1500           # point reads
  fullLists = 10        # full-kind lists (seqDocs items each)
  prefixLists = 300     # prefix-scoped lists

proc payload(n: int, size: int): JsonNode =
  %*{"n": n, "title": &"bench document number {n}",
     "payload": repeat("x", size)}

proc fileSize(path: string): int64 =
  try: getFileSize(path)
  except CatchableError: 0

proc dbBytes(root: string): JsonNode =
  ## Live bytes on disk per data file (barrel file vs sqlite db/-wal/-shm).
  result = newJArray()
  for name in ["barrel-db", "store.db", "store.db-wal", "store.db-shm"]:
    let p = root / "var" / name
    if fileExists(p):
      result.add(%*{"file": name, "bytes": fileSize(p)})

proc benchEngine(bin: string): JsonNode =
  ## Runs the workload against one engine binary; returns phase timings.
  let tmp = tempRoot("bench-store")
  defer: removeDir(tmp)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var procH = startComponent(bin, url, root = tmp)
  defer:
    if procH.running(): procH.terminate()
    sleep(150)
    procH.close()
  doAssert waitRegistered(nc, "store"), "store did not register: " & bin

  proc callStore(tool: string, args: JsonNode, timeoutMs = 30_000): JsonNode =
    call(nc, "store", tool, args, timeoutMs)

  var phases: seq[tuple[name: string, ms: float, ops: int]] = @[]
  proc timed(name: string, ops: int, body: proc()) =
    let t0 = epochTime()
    body()
    let ms = (epochTime() - t0) * 1000
    phases.add((name, ms, ops))

  var lastRev = 0
  # --- writes -----------------------------------------------------------
  timed("put seq (" & $seqDocs & " x ~300 B)", seqDocs, proc() =
    for i in 1 .. seqDocs:
      let r = callStore("put", %*{"kind": "bench", "id": "doc-" & $i,
                                  "value": payload(i, 240)})
      lastRev = r{"rev"}.getInt(0))
  timed("put big (" & $bigDocs & " x ~4 KB)", bigDocs, proc() =
    for i in 1 .. bigDocs:
      discard callStore("put", %*{"kind": "big", "id": "doc-" & $i,
                                  "value": payload(i, 3900)}))
  timed("update CAS (" & $updates & ")", updates, proc() =
    for i in 1 .. updates:
      let r = callStore("put", %*{"kind": "bench", "id": "doc-" & $i,
                                  "value": payload(i, 240), "expectRev": lastRev})
      lastRev = r{"rev"}.getInt(0))

  let bytesAfterWrites = dbBytes(tmp)

  # --- reads ------------------------------------------------------------
  timed("get point (" & $gets & ")", gets, proc() =
    for i in 1 .. gets:
      discard callStore("get", %*{"kind": "bench", "id": "doc-" & $i}))
  let missing = 600
  timed("get missing (" & $missing & ")", missing, proc() =
    for i in 1 .. missing:
      discard callStore("get", %*{"kind": "bench", "id": "nope-" & $i}))
  var listed = 0
  timed("list full (" & $fullLists & " x " & $seqDocs & ")", fullLists, proc() =
    for i in 1 .. fullLists:
      let r = callStore("list", %*{"kind": "bench"}, 60_000)
      listed = r{"items"}.len)
  timed("list prefix (" & $prefixLists & ")", prefixLists, proc() =
    for i in 1 .. prefixLists:
      discard callStore("list", %*{"kind": "bench", "idPrefix": "doc-1"}))

  # --- deletes + restart cost ------------------------------------------
  timed("del (" & $seqDocs & ")", seqDocs, proc() =
    for i in 1 .. seqDocs:
      discard callStore("del", %*{"kind": "bench", "id": "doc-" & $i}))

  # boot: stop, then time until the replacement answers the bus
  drain(nc)
  sleep(300)
  if procH.running(): procH.terminate()
  sleep(300)
  procH.close()
  let t0 = epochTime()
  procH = startComponent(bin, url, root = tmp)
  doAssert waitRegistered(nc, "store"), "store did not restart: " & bin
  let bootMs = (epochTime() - t0) * 1000
  let g = callStore("get", %*{"kind": "big", "id": "doc-1"})
  doAssert g{"ok"}.getBool(false), "data lost across restart"

  result = %*{
    "binary": bin,
    "phases": phases.mapIt(%*{"name": it.name, "ms": it.ms, "ops": it.ops}),
    "bootMs": bootMs,
    "bytesAfterWrites": bytesAfterWrites,
    "bytesAfterRestart": dbBytes(tmp),
    "listItemsCheck": listed,
  }

proc row(name: string, ms: float, ops: int) =
  let n = alignLeft(name, 32)
  if ops > 0:
    echo "  ", n, align(ms.formatFloat(ffDecimal, 1), 9), " ms ",
      align((ops.float / ms * 1000).formatFloat(ffDecimal, 0), 8), " ops/s"
  else:
    echo "  ", n, align(ms.formatFloat(ffDecimal, 1), 9), " ms"

proc formatSize(n: int): string =
  if n >= 1_000_000: (n.float / 1_000_000).formatFloat(ffDecimal, 1) & " MB"
  elif n >= 1_000: (n.float / 1_000).formatFloat(ffDecimal, 1) & " KB"
  else: $n & " B"

proc show(label: string, r: JsonNode) =
  echo "\n== ", label, " (", r{"binary"}.getStr("?"), ")"
  for p in r{"phases"}.items:
    row(p{"name"}.getStr(), p{"ms"}.getFloat(), p{"ops"}.getInt(0))
  row("boot (registered)", r{"bootMs"}.getFloat(), 0)
  for phase in ["bytesAfterWrites", "bytesAfterRestart"]:
    let parts = r{phase}
    var total = 0
    var desc = ""
    for f in parts.items:
      total += f{"bytes"}.getInt()
      if desc.len > 0: desc.add(" + ")
      desc.add(f{"file"}.getStr() & "=" & formatSize(f{"bytes"}.getInt()))
    echo "  ", alignLeft(phase, 32), align(formatSize(total), 9), "  (", desc, ")"

proc main() =
  let binDir = getAppDir()  # var/bin
  let bins = if os.getEnv("ENGINE").len > 0: @[os.getEnv("ENGINE")]
             else: @[binDir / "store", binDir / "store-sqlite"]
  var results: seq[tuple[label: string, r: JsonNode]] = @[]
  for bin in bins:
    if not fileExists(bin):
      echo "skip (missing): ", bin
      continue
    let label = if bin.endsWith("store-sqlite"): "sqlite"
                else: "barrel"
    results.add((label, benchEngine(bin)))
  for (label, r) in results:
    show(label, r)
  if results.len == 2:
    echo "\n== ratio (barrel / sqlite, >1 means sqlite faster)"
    let (a, b) = (results[0].r, results[1].r)
    for i in 0 ..< a{"phases"}.len:
      let msA = a{"phases"}[i]{"ms"}.getFloat()
      let msB = b{"phases"}[i]{"ms"}.getFloat()
      let name = a{"phases"}[i]{"name"}.getStr()
      if msB > 0:
        echo "  ", alignLeft(name, 32),
          align((msA / msB).formatFloat(ffDecimal, 2), 9), "x"
    let bootA = a{"bootMs"}.getFloat()
    let bootB = max(b{"bootMs"}.getFloat(), 0.001)
    echo "  ", alignLeft("boot (registered)", 32),
      align((bootA / bootB).formatFloat(ffDecimal, 2), 9), "x"

main()
