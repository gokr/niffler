## Transcript appends and header merges fail closed against a fault store.
import std/[json, os, strutils]
import natsnim
import helpers
import ../core/[conversation, dispatch, catalog]

proc main() =
  let root = getCurrentDir() / "var" / ("transcript-safety-" & $getCurrentProcessId())
  createDir(root)
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let sp = startComponent(getCurrentDir() / "var/bin/fixture-fleet-fault-store", url, root)
  defer: stopProcess(sp)
  doAssert waitRegistered(nc, "store")
  let ct = CoreTools(nc: nc, cat: newCatalog(nc), root: root)
  let control = root / "fault.json"
  proc fault(v: JsonNode) = writeFile(control, $v)

  discard ct.storePutRev("message", "c:001001", %*{"role": "user", "content": "original"})
  var p = newPersister(ct)
  p.convId = "c"
  p.seqNo = 1000
  var refused = false
  try: discard p.persistMsg(%*{"role": "user", "content": "overwrite"})
  except IOError: refused = true
  check("stale continuation refuses the append", refused)
  let original = ct.storeGetItem("message", "c:001001")
  check("collision preserves original content and revision",
    original.rev == 1 and original.value{"content"}.getStr() == "original")
  var pt, used, size: int
  let loaded = loadStoredMessagesEx(ct, "c", pt, used, size)
  check("resume uses the highest stored id, not message count", loaded.lastSeqNo == 1001)
  p.seqNo = loaded.lastSeqNo
  check("a correctly resumed append succeeds",
    p.persistMsg(%*{"role": "user", "content": "new"}) == "c:001002")

  for mode in ["malformed", "missing-cursor", "stuck-cursor", "backward-cursor"]:
    fault(%*{"list": mode})
    refused = false
    try: discard ct.storeListAll("message", "c:", after = "c:000001")
    except IOError: refused = true
    check("incomplete list refuses: " & mode, refused)
  fault(%*{})

  discard ct.storePutRev("conversation", "c",
    %*{"createdAt": 123.0, "title": "original title", "cacheRead": 50})
  fault(%*{"headerRace": true})
  ct.updateConversationHeader("c", %*{"promptTokens": 100})
  let merged = ct.storeGetItem("conversation", "c")
  check("header retry keeps concurrent title and existing creation time",
    merged.value{"title"}.getStr() == "concurrent title" and
    merged.value{"createdAt"}.getFloat() == 123.0 and
    merged.value{"promptTokens"}.getInt() == 100 and
    merged.value{"cacheRead"}.getInt() == 50)
  fault(%*{"get": true})
  ct.updateConversationHeader("c", %*{"promptTokens": 999})
  ensureConversationHeader(ct, "c")
  fault(%*{})
  let intact = ct.storeGetItem("conversation", "c")
  check("failed header read never writes an empty replacement",
    intact.rev == merged.rev and $intact.value == $merged.value)
  ensureConversationHeader(ct, "new")
  let born = ct.storeGetItem("conversation", "new")
  ensureConversationHeader(ct, "new")
  check("header creation is idempotent",
    ct.storeGetItem("conversation", "new").rev == born.rev)
  report("TRANSCRIPT SAFETY")

main()
