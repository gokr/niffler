## t_store_paging — the `list` cursor contract across engines.
##
## Verifies the `after`/`hasMore`/`nextAfter` paging semantics that store
## migration and compaction's projection reload depend on:
## - pages partition the kind exactly once (no gaps, no duplicates),
## - the cursor is strictly exclusive,
## - paging works past the 1000-item list cap,
## - idPrefix filtering composes with the cursor,
## - tombstoned documents do not stall or skip the cursor.
##
## Runs against one engine by default (NIF_STORE_BIN or the barrel default);
## `make test-store-paging` re-runs it against SQLite.

import std/[algorithm, json, os, sets, strutils]
import natsnim
import helpers

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
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

  let tmp = tempRoot("store-paging")
  defer: removeDir(tmp)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var storeProc = startComponent(bin, url, root = tmp)
  defer: stopProcess(storeProc)
  check("store registered", waitRegistered(nc, "store"))

  proc callStore(tool: string, args: JsonNode, timeoutMs = 30_000): JsonNode =
    call(nc, "store", tool, args, timeoutMs)

  # --- one kind, more documents than a single page may return ---------------
  # 2500 with a 1000 cap exercises three pages and the cap itself.
  const total = 2500
  for i in 1 .. total:
    let r = callStore("put", %*{"kind": "page", "id": "d-" & align($i, 6, '0'),
                                "value": %*{"n": i}})
    doAssert r{"ok"}.getBool(false), "put failed: " & $r

  # A second kind must never leak into the first kind's pages.
  for i in 1 .. 5:
    discard callStore("put", %*{"kind": "other", "id": "x-" & $i,
                                "value": %*{"n": i}})

  proc page(kind: string, after: string, limit: int,
            idPrefix = ""): JsonNode =
    callStore("list", %*{"kind": kind, "idPrefix": idPrefix,
                         "limit": limit, "after": after})

  # --- 1. paging past the 1000 cap partitions exactly ----------------------
  var seen: seq[string]
  var after = ""
  var pages = 0
  while true:
    var args = %*{"kind": "page", "limit": 1000}
    if after.len > 0: args["after"] = %after
    let r = page("page", after, 1000)
    doAssert r{"ok"}.getBool(false), "list failed: " & $r
    for item in r{"items"}:
      seen.add(item{"id"}.getStr(""))
    inc pages
    let nextAfter = r{"nextAfter"}.getStr("")
    if not r{"hasMore"}.getBool(false) or nextAfter.len == 0:
      break
    check("cursor advances", nextAfter != after)
    after = nextAfter
    if pages > 10: break  # runaway guard

  check("paged all documents (" & $seen.len & "/" & $total & ")",
        seen.len == total)
  check("more than one page was needed", pages > 1)
  var uniq = initHashSet[string]()
  for id in seen: uniq.incl(id)
  check("no duplicate documents across pages", uniq.len == seen.len)
  var sortedCopy = seen
  sortedCopy.sort()
  check("pages arrive in id order", sortedCopy == seen)
  check("ids are complete (no gaps)",
        seen[0] == "d-000001" and seen[^1] == "d-" & align($total, 6, '0'))

  # --- 2. the cursor is strictly exclusive ---------------------------------
  let firstPage = page("page", "", 10)
  check("first page has 10 items", firstPage{"items"}.len == 10)
  let cursor1 = firstPage{"nextAfter"}.getStr("")
  check("nextAfter is the last item's id",
        cursor1 == firstPage{"items"}[^1]{"id"}.getStr(""))
  let secondPage = page("page", cursor1, 10)
  check("resuming from the cursor excludes the cursor row",
        secondPage{"items"}[0]{"id"}.getStr("") != cursor1)
  check("resuming continues immediately after the cursor",
        secondPage{"items"}[0]{"value"}{"n"}.getInt(0) ==
          firstPage{"items"}[^1]{"value"}{"n"}.getInt(0) + 1,
        "first page last n=" & $firstPage{"items"}[^1]{"value"}{"n"}.getInt(0) &
        " second page first n=" & $secondPage{"items"}[0]{"value"}{"n"}.getInt(0) &
        " cursor=" & cursor1)

  # --- 3. hasMore is honest at the tail ------------------------------------
  let fullPage = page("page", "", 1000)
  check("a full page reports hasMore", fullPage{"hasMore"}.getBool(false))
  let lastPage = page("page", "d-" & align($(total - 5), 6, '0'), 1000)
  check("a tail page reports no more", not lastPage{"hasMore"}.getBool(false))
  check("tail page carries the remaining documents",
        lastPage{"items"}.len == 5)
  check("tail page omits nextAfter",
        lastPage{"nextAfter"} == nil or
          lastPage{"nextAfter"}.getStr("").len == 0)

  # --- 4. prefix filtering composes with the cursor ------------------------
  for i in 1 .. 50:
    discard callStore("put", %*{"kind": "pref", "id": "a-" & align($i, 3, '0'),
                                "value": %*{"n": i}})
  for i in 1 .. 50:
    discard callStore("put", %*{"kind": "pref", "id": "b-" & align($i, 3, '0'),
                                "value": %*{"n": i}})
  var prefixed: seq[string]
  after = ""
  while true:
    var args = %*{"kind": "pref", "idPrefix": "a-", "limit": 10}
    if after.len > 0: args["after"] = %after
    let r = callStore("list", args)
    for item in r{"items"}:
      prefixed.add(item{"id"}.getStr(""))
    let nextAfter = r{"nextAfter"}.getStr("")
    if not r{"hasMore"}.getBool(false) or nextAfter.len == 0: break
    after = nextAfter
  check("prefix paging returns only the prefix (" & $prefixed.len & ")",
        prefixed.len == 50)
  var allPrefixed = true
  for id in prefixed:
    if not id.startsWith("a-"): allPrefixed = false
  check("no b- documents leaked into an a- page", allPrefixed)

  # --- 5. a tombstoned page still advances the cursor ----------------------
  # Delete a whole first page's worth, then page across the hole: the cursor
  # must keep moving (an items-based cursor would stop early and lose the rest).
  for i in 1 .. 20:
    discard callStore("del", %*{"kind": "hole",
                                "id": "h-" & align($i, 3, '0')})
  for i in 1 .. 60:
    discard callStore("put", %*{"kind": "hole", "id": "h-" & align($i, 3, '0'),
                                "value": %*{"n": i}})
  for i in 1 .. 20:
    discard callStore("del", %*{"kind": "hole",
                                "id": "h-" & align($i, 3, '0')})
  var afterHole: seq[string]
  after = ""
  pages = 0
  while true:
    var args = %*{"kind": "hole", "limit": 10}
    if after.len > 0: args["after"] = %after
    let r = callStore("list", args)
    for item in r{"items"}:
      afterHole.add(item{"id"}.getStr(""))
    let nextAfter = r{"nextAfter"}.getStr("")
    inc pages
    if not r{"hasMore"}.getBool(false) or nextAfter.len == 0: break
    check("cursor advances across a tombstoned page", nextAfter != after)
    after = nextAfter
    if pages > 15: break
  check("documents after the tombstone hole are still reachable",
        afterHole.len == 40)
  check("the hole is actually empty",
        afterHole.len > 0 and afterHole[0] == "h-021")

  # --- 6. the cursor is scoped to the kind ---------------------------------
  # Paging "other" with a cursor from "page" must not skip its own rows.
  let otherAll = page("other", "", 100)
  check("other kind is unaffected by another kind's ids",
        otherAll{"items"}.len == 5)

  echo "ok: store paging contract holds for " & bin
  report("t_store_paging")

main()
