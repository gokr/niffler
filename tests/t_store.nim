## store component tests — bus contract: document store semantics.
##
## Uses a temp NIF_ROOT so the real var/barrel-db is never touched.
## Covers put/get/list/del, rev-based optimistic concurrency, prefix
## listing, tombstones, and persistence across a store restart.

import std/[json, os, osproc, strutils]
import natswrapper
import envelope
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  # Engine under test: NIF_STORE_BIN overrides the default barrel binary
  # (make test-store-sqlite runs this exact contract against the SQLite
  # engine; docs/research/STORE_V2.md). Relative paths resolve against root.
  let bin = block:
    let override = getEnv("NIF_STORE_BIN", "")
    if override.len == 0:
      root / "var" / "bin" / "store"
    elif override.isAbsolute():
      override
    else:
      root / override
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let tmp = tempRoot("store")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var storeProc = startComponent(bin, url, root = tmp)
  defer:
    if storeProc.running():
      storeProc.terminate()
      sleep(200)
    storeProc.close()

  check("store registers", waitRegistered(nc, "store"))
  if failures > 0:
    echo "store never came up — aborting"
    report("STORE TEST")

  var secondStore = startComponent(bin, url, root = tmp)
  let secondCode = secondStore.waitForExit(3000)
  if secondCode == -1:
    secondStore.terminate()
    sleep(200)
  secondStore.close()
  check("store rejects a second writer", secondCode != -1 and secondCode != 0)

  # put/get round trip
  let p1 = call(nc, "store", "put",
                %*{"kind": "test", "id": "doc1", "value": %*{"hello": "world"}})
  check("store put ok", p1{"ok"}.getBool(false) and p1{"rev"}.getInt(-1) == 1, $p1)
  let g1 = call(nc, "store", "get", %*{"kind": "test", "id": "doc1"})
  check("store get returns value", g1{"value"}{"hello"}.getStr("") == "world", $g1)

  # rev bumps on update; optimistic concurrency enforced
  let p2 = call(nc, "store", "put",
                %*{"kind": "test", "id": "doc1", "value": %*{"hello": "v2"},
                   "expectRev": 1})
  check("store put expectRev ok", p2{"ok"}.getBool(false) and p2{"rev"}.getInt(-1) == 2, $p2)
  let conflict = call(nc, "store", "put",
                      %*{"kind": "test", "id": "doc1", "value": %*{"hello": "v3"},
                         "expectRev": 1})
  check("store rev conflict", not conflict{"ok"}.getBool(false) and
        conflict{"code"}.getStr("") == "rev-conflict", $conflict)

  # list: ordered, prefix-filtered, limit
  discard call(nc, "store", "put", %*{"kind": "test", "id": "doc2",
                                      "value": %*{"n": 2}})
  discard call(nc, "store", "put", %*{"kind": "other", "id": "doc3",
                                      "value": %*{"n": 3}})
  let all = call(nc, "store", "list", %*{"kind": "test"})
  check("store list finds 2 docs", all{"items"}.len == 2, $all)
  let pref = call(nc, "store", "list", %*{"kind": "test", "idPrefix": "doc1"})
  check("store list prefix", pref{"items"}.len == 1 and
        pref{"items"}[0]{"id"}.getStr("") == "doc1", $pref)
  let lim = call(nc, "store", "list", %*{"kind": "test", "limit": 1})
  check("store list limit", lim{"items"}.len == 1, $lim)

  # del → tombstone: get returns not-found, list excludes it
  let d1 = call(nc, "store", "del", %*{"kind": "test", "id": "doc1"})
  check("store del ok", d1{"ok"}.getBool(false), $d1)
  let gone = call(nc, "store", "get", %*{"kind": "test", "id": "doc1"})
  check("store del tombstone", not gone{"ok"}.getBool(false) and
        gone{"code"}.getStr("") == "not-found", $gone)
  let afterDel = call(nc, "store", "list", %*{"kind": "test"})
  check("store list excludes tombstoned", afterDel{"items"}.len == 1, $afterDel)

  # unknown doc
  let nf = call(nc, "store", "get", %*{"kind": "nope", "id": "x"})
  check("store missing doc not-found", not nf{"ok"}.getBool(false) and
        nf{"code"}.getStr("") == "not-found", $nf)

  # persistence across restart (single-writer: restart sequentially)
  drain(nc)
  sleep(500)
  storeProc.close()
  storeProc = startComponent(bin, url, root = tmp)
  check("store restarts", waitRegistered(nc, "store"))
  let g2 = call(nc, "store", "get", %*{"kind": "test", "id": "doc2"})
  check("store persists across restart", g2{"ok"}.getBool(false), $g2)

  drain(nc)
  sleep(500)
  report("STORE TEST")

main()
