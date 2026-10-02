## store component tests — bus contract: document store semantics.
##
## Uses a temp NIF_ROOT so the real var/store.db is never touched.
## Covers put/get/list/del, rev-based optimistic concurrency, prefix
## listing, tombstones, and persistence across a store restart.

import std/[json, os, osproc, strutils]
import natsnim
import envelope
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  # Engine under test: NIF_STORE_BIN (an explicit binary) → NIF_STORE_BACKEND
  # → the shipped default engine, SQLite. `make test-store` and
  # `make test-store-tidb` run this exact contract against those two
  # (docs/research/STORE_V2.md); relative paths resolve against root.
  let bin = resolveStoreBin(root)
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

  # --- search: the server-side session filter (issue #77, docs/WIRE.md) ---
  # Contract pinned here runs against EVERY engine (t_store picks the binary
  # up from NIF_STORE_BIN): matching, no-match, ordering/cursors, special
  # characters, and a result set past the 1000-item cap.
  discard call(nc, "store", "put", %*{"kind": "conversation", "id": "conv-s1",
                                      "value": %*{"title": "Can you check the PRs"}})
  discard call(nc, "store", "put", %*{"kind": "conversation", "id": "conv-s2",
                                      "value": %*{"title": "spike solution for JEV"}})
  discard call(nc, "store", "put", %*{"kind": "conversation", "id": "conv-s3",
                                      "value": %*{"title": "unrelated chat"}})
  discard call(nc, "store", "put",
               %*{"kind": "message", "id": "conv-s1:000001",
                  "value": %*{"role": "user",
                              "content": "where did we discuss the retry policy?"}})

  # match by title token: prefix + case-insensitive ("spike" → "spike solution")
  let sTitle = call(nc, "store", "search",
                    %*{"kind": "conversation", "query": "spike"})
  check("search matches a title token prefix",
        sTitle{"ok"}.getBool(false) and sTitle{"items"}.len == 1 and
        sTitle{"items"}[0]{"id"}.getStr("") == "conv-s2", $sTitle)
  # match by id (hyphen splits into tokens: "conv" AND "s1")
  let sId = call(nc, "store", "search",
                 %*{"kind": "conversation", "query": "conv-s1"})
  check("search matches a conversation id",
        sId{"ok"}.getBool(false) and sId{"items"}.len == 1 and
        sId{"items"}[0]{"id"}.getStr("") == "conv-s1", $sId)
  # AND across query words
  let sAnd = call(nc, "store", "search",
                  %*{"kind": "conversation", "query": "check prs"})
  check("search ANDs the query words",
        sAnd{"ok"}.getBool(false) and sAnd{"items"}.len == 1 and
        sAnd{"items"}[0]{"id"}.getStr("") == "conv-s1", $sAnd)
  # message content is searchable, and kinds never bleed into each other
  let sMsg = call(nc, "store", "search",
                  %*{"kind": "message", "query": "retry policy"})
  check("search finds message content",
        sMsg{"ok"}.getBool(false) and sMsg{"items"}.len == 1 and
        sMsg{"items"}[0]{"id"}.getStr("") == "conv-s1:000001", $sMsg)
  let sKind = call(nc, "store", "search",
                   %*{"kind": "component", "query": "spike"})
  check("search never crosses kinds",
        sKind{"ok"}.getBool(false) and sKind{"items"}.len == 0, $sKind)
  # no match: ok with an empty page, never an error
  let sNone = call(nc, "store", "search",
                   %*{"kind": "conversation", "query": "nothingmatchesthis"})
  check("search no-match is ok + empty",
        sNone{"ok"}.getBool(false) and sNone{"items"}.len == 0 and
        not sNone{"hasMore"}.getBool(true), $sNone)
  # special characters: everything non-alphanumeric is a separator, so
  # "OR" can never act as an operator and quotes/%/_ cannot smuggle one in
  let sOr = call(nc, "store", "search",
                 %*{"kind": "conversation", "query": "conv OR nothingmatchesthis"})
  check("search treats OR as a plain word",
        sOr{"ok"}.getBool(false) and sOr{"items"}.len == 0, $sOr)
  let sPunct = call(nc, "store", "search",
                    %*{"kind": "conversation", "query": "%;\"'"})
  check("search rejects a punctuation-only query",
        not sPunct{"ok"}.getBool(true) and
        sPunct{"code"}.getStr("") == "bad-request", $sPunct)

  # --- issue #51: idPrefix scoping, ranked mode, snippets ------------------
  discard call(nc, "store", "put",
               %*{"kind": "message", "id": "conv-s2:000001",
                  "value": %*{"role": "user",
                              "content": "a second retry policy note"}})
  let sPrefix = call(nc, "store", "search",
                     %*{"kind": "message", "query": "retry",
                        "idPrefix": "conv-s1:"})
  check("search idPrefix narrows to one conversation",
        sPrefix{"ok"}.getBool(false) and sPrefix{"items"}.len == 1 and
        sPrefix{"items"}[0]{"id"}.getStr("") == "conv-s1:000001", $sPrefix)
  let sNoPrefix = call(nc, "store", "search",
                       %*{"kind": "message", "query": "retry"})
  check("search without idPrefix crosses conversations",
        sNoPrefix{"ok"}.getBool(false) and sNoPrefix{"items"}.len == 2,
        $sNoPrefix)

  let sRanked = call(nc, "store", "search",
                     %*{"kind": "message", "query": "retry", "rank": true,
                        "snippet": true})
  var sRankedOk = sRanked{"ok"}.getBool(false) and
    sRanked{"ranked"}.kind == JBool and sRanked{"items"}.len == 2
  for it in sRanked{"items"}:
    if it{"snippet"}.getStr("").len == 0: sRankedOk = false
  check("search rank+snippet answers with a ranked flag and span-marked hits",
        sRankedOk, $sRanked)

  # ranked paging by offset: pages cover the match set without gaps or
  # overlaps, and the reply names nextOffset when more remain
  discard call(nc, "store", "put",
               %*{"kind": "message", "id": "conv-s3:000001",
                  "value": %*{"role": "user",
                              "content": "yet another retry policy thought"}})
  var rPage: seq[string] = @[]
  var rOffset = 0
  var rHasMore = true
  while rHasMore and rPage.len < 10:
    let pg = call(nc, "store", "search",
                  %*{"kind": "message", "query": "retry", "rank": true,
                     "limit": 1, "offset": rOffset})
    check("ranked page ok", pg{"ok"}.getBool(false), $pg)
    for it in pg{"items"}:
      rPage.add(it{"id"}.getStr(""))
    rHasMore = pg{"hasMore"}.getBool(false)
    if rHasMore:
      let nxt = pg{"nextOffset"}.getInt(-1)
      check("ranked page carries nextOffset", nxt > rOffset, $pg)
      rOffset = nxt
  check("ranked offset paging covers the match set exactly once",
        rPage.len == 3 and rPage == @["conv-s1:000001", "conv-s2:000001",
                                     "conv-s3:000001"] or
        (rPage.len == 3 and
         ("conv-s1:000001" in rPage) and ("conv-s2:000001" in rPage) and
         ("conv-s3:000001" in rPage)), $rPage)

  # pagination: 25 conversations, every 5th not matching → 20 results, paged
  # in ascending id order with no gaps and no repeats (list's cursor rule)
  for i in 0 ..< 25:
    let sid = "srchp-" & align($i, 3, '0')
    let title = if i mod 5 == 0: "other title" else: "match " & sid
    discard call(nc, "store", "put",
                 %*{"kind": "conversation", "id": sid, "value": %*{"title": title}})
  var paged: seq[string] = @[]
  var after = ""
  for page in 0 ..< 10:
    var args = %*{"kind": "conversation", "query": "match", "limit": 7}
    if after.len > 0: args["after"] = %after
    let pg = call(nc, "store", "search", args)
    check("search page ok", pg{"ok"}.getBool(false), $pg)
    for it in pg{"items"}:
      paged.add(it{"id"}.getStr(""))
    if not pg{"hasMore"}.getBool(false): break
    let nxt = pg{"nextAfter"}.getStr("")
    check("search page carries nextAfter", nxt.len > 0, $pg)
    after = nxt
  check("search pages to the full result set", paged.len == 20, $paged)
  var ascending = true
  for i in 1 ..< paged.len:
    if paged[i - 1] >= paged[i]: ascending = false
  check("search results are in ascending id order", ascending, $paged)

  # large result set: 1050 matching docs cross the 1000-item cap, so the
  # first page is capped and hasMore + the cursor must carry the rest —
  # never a silent truncation
  for i in 0 ..< 1050:
    discard call(nc, "store", "put",
                 %*{"kind": "conversation",
                    "id": "srchlrg-" & align($i, 4, '0'),
                    "value": %*{"title": "haystack needle" & $i}})
  let big1 = call(nc, "store", "search",
                  %*{"kind": "conversation", "query": "haystack", "limit": 5000})
  check("search caps a page at 1000",
        big1{"ok"}.getBool(false) and big1{"items"}.len == 1000 and
        big1{"hasMore"}.getBool(false) and
        big1{"nextAfter"}.getStr("").len > 0, $big1{"items"}.len)
  let big2 = call(nc, "store", "search",
                  %*{"kind": "conversation", "query": "haystack",
                     "limit": 5000, "after": big1{"nextAfter"}.getStr("")})
  check("search pages past the cap without loss",
        big2{"ok"}.getBool(false) and big2{"items"}.len == 50 and
        not big2{"hasMore"}.getBool(true), $big2{"items"}.len)

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
  # the search path survives the restart too (index rebuilt from `docs` or
  # carried over, depending on the engine — same contract either way)
  let sAfter = call(nc, "store", "search",
                    %*{"kind": "conversation", "query": "spike"})
  check("search works after a store restart",
        sAfter{"ok"}.getBool(false) and sAfter{"items"}.len == 1 and
        sAfter{"items"}[0]{"id"}.getStr("") == "conv-s2", $sAfter)

  drain(nc)
  sleep(500)
  report("STORE TEST")

main()
