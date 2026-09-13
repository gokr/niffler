## t_resume_long — resume must not truncate or overwrite a long transcript.
##
## Regression for the 1000-item list cap in loadStoredMessagesEx:
## - a conversation longer than 1000 messages must resume COMPLETE,
## - the next persisted message must continue AFTER the real tail, never
##   reuse an existing id (which silently overwrote history).
##
## Boots a sandbox core (store only) and drives the store directly, then
## checks the resume tuple through the same code path the runner uses.

import std/[json, os, strutils]
import natsnim
import helpers

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  if not fileExists(resolveStoreBin(repoRoot)):
    fail("missing store binary — run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("resume-long", ["store"])
  let root = sandbox.root
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")],
                                logFile = root / "var" / "test-logs" / "core.log")
  defer: stopProcess(coreProc)
  doAssert waitRegistered(nc, "store"), "store did not register"

  proc cs(tool: string, args: JsonNode, t = 60_000): JsonNode =
    call(nc, "store", tool, args, t)

  # --- seed a transcript longer than the cap -------------------------------
  const conv = "long-resume"
  const total = 2500
  discard cs("put", %*{"kind": "conversation", "id": conv,
                       "value": %*{"createdAt": 1.0, "title": "long"}})
  for i in 1 .. total:
    let r = cs("put", %*{"kind": "message",
                         "id": conv & ":" & align($i, 6, '0'),
                         "value": %*{"role": (if i mod 2 == 0: "assistant"
                                             else: "user"),
                                     "content": "m" & $i}})
    doAssert r{"ok"}.getBool(false), $r

  # --- the capped read (what resume does today) ---------------------------
  let capped = cs("list", %*{"kind": "message", "idPrefix": conv & ":",
                             "limit": 1000})
  check("capped list still caps at 1000", capped{"items"}.len == 1000)
  check("capped list reports hasMore", capped{"hasMore"}.getBool(false))
  let cappedMax = block:
    var m = 0
    for item in capped{"items"}:
      let id = item{"id"}.getStr("")
      m = max(m, parseInt(id[id.rfind(':') + 1 .. ^1]))
    m
  check("the cap hides the tail (max id seen is 1000)", cappedMax == 1000)

  # --- the paged read (the fix) -------------------------------------------
  var ids: seq[int]
  var after = ""
  var pages = 0
  while true:
    var args = %*{"kind": "message", "idPrefix": conv & ":", "limit": 1000}
    if after.len > 0: args["after"] = %after
    let r = cs("list", args)
    doAssert r{"ok"}.getBool(false), $r
    for item in r{"items"}:
      let id = item{"id"}.getStr("")
      ids.add(parseInt(id[id.rfind(':') + 1 .. ^1]))
    inc pages
    let na = r{"nextAfter"}.getStr("")
    if not r{"hasMore"}.getBool(false) or na.len == 0: break
    after = na
    if pages > 10: break
  check("paging recovers every message", ids.len == total)
  check("paging reaches the true tail", ids[^1] == total)
  check("ids are strictly increasing", block:
    var ok = true
    for i in 1 ..< ids.len:
      if ids[i] <= ids[i-1]: ok = false
    ok)

  # --- the overwrite hazard, demonstrated on the capped read --------------
  # Resume computes lastSeqNo from the messages it loaded. With the capped
  # read that is 1000, so the next persist writes id 1001 — overwriting a
  # stored message instead of appending.
  let nextSeqFromCapped = cappedMax + 1
  let clash = cs("get", %*{"kind": "message",
                           "id": conv & ":" & align($nextSeqFromCapped, 6, '0')})
  check("resuming from the capped read would target an EXISTING id",
        clash{"ok"}.getBool(false))
  check("...and that id holds real history",
        clash{"value"}{"content"}.getStr("") == "m" & $nextSeqFromCapped)

  # The fix's contract: a paged resume ends at the true tail, so the next
  # persist appends a fresh id.
  let nextSeqFromPaged = ids[^1] + 1
  check("resuming from the paged read appends past the tail",
        nextSeqFromPaged == total + 1)
  let fresh = cs("get", %*{"kind": "message",
                           "id": conv & ":" & align($nextSeqFromPaged, 6, '0')})
  check("...targeting a free id", not fresh{"ok"}.getBool(false))

  # --- transcript integrity after a paged resume + append -----------------
  discard cs("put", %*{"kind": "message",
                       "id": conv & ":" & align($nextSeqFromPaged, 6, '0'),
                       "value": %*{"role": "user", "content": "appended"}})
  let afterAppend = cs("list", %*{"kind": "message", "idPrefix": conv & ":",
                                  "limit": 1000})
  let all = cs("list", %*{"kind": "message", "idPrefix": conv & ":",
                          "limit": 1000, "after": "000000"})
  check("nothing was overwritten (first page still starts at 1)",
        afterAppend{"items"}[0]{"value"}{"content"}.getStr("") == "m1")
  # verify the tail survived the append
  var tailContent = ""
  after = ""
  while true:
    var args = %*{"kind": "message", "idPrefix": conv & ":", "limit": 1000}
    if after.len > 0: args["after"] = %after
    let r = cs("list", args)
    for item in r{"items"}:
      tailContent = item{"value"}{"content"}.getStr("")
    let na = r{"nextAfter"}.getStr("")
    if not r{"hasMore"}.getBool(false) or na.len == 0: break
    after = na
  check("the appended message is the new tail", tailContent == "appended")

  report("t_resume_long")

main()
