## Transcript appends and header merges fail closed against a fault store.
import std/[json, os, strutils]
import natsnim
import helpers
import ../core/[conversation, dispatch, catalog]
import niffler/sandboxpolicy

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
  # Sandbox policy must distinguish an absent document (default off) from a
  # store outage, and child birth must not persist an off policy on failure.
  let parent = initialSandboxPolicy(root, true)
  check("sandbox parent policy persists",
    ct.saveSandboxPolicy("sb-parent", parent, -1).ok)
  let duplicate = ct.saveSandboxPolicy("sb-parent", initialSandboxPolicy(root), -1)
  check("create-only sandbox policy cannot overwrite an existing decision",
    not duplicate.ok and ct.loadSandboxPolicy("sb-parent", root).policy.enabled)
  let outside = root / ".."
  refused = false
  try: ct.inheritSandboxPolicyFor("sb-parent", "sb-child-outside", outside)
  except CatchableError: refused = true
  check("sandbox child cannot turn an unapproved workspace into a grant", refused)
  fault(%*{"get": true})
  refused = false
  try: discard ct.loadSandboxPolicy("sb-parent", root)
  except CatchableError: refused = true
  check("sandbox policy read outage refuses instead of defaulting off", refused)
  refused = false
  try: ct.inheritSandboxPolicyFor("sb-parent", "sb-child-read", root)
  except CatchableError: refused = true
  check("sandbox child inheritance refuses an unreadable parent", refused)
  fault(%*{"putKind": "sandboxpolicy"})
  refused = false
  try: ct.inheritSandboxPolicyFor("sb-parent", "sb-child-write", root)
  except CatchableError: refused = true
  check("sandbox child inheritance refuses a failed child write", refused)
  fault(%*{})
  check("failed inheritance leaves no off child policy",
    ct.storeGetItem("sandboxpolicy", "sb-child-write:policy").value == nil)

  block:
    let sandbox = newCoreSandbox("append-outage", ["store", "bash", "llm"])
    defer: removeDir(sandbox.root)
    copyFileWithPermissions(sandbox.repoRoot / "var/bin/fixture-fleet-fault-store",
      sandbox.sandboxBin("store-sqlite"))
    discard fixtureBin(sandbox, "llm", sandbox.repoRoot / "tests/mock_llm.nim",
                       "fixture-mock-llm")
    let (bus, busUrl) = startNats()
    defer: stopServer(bus)
    var client = waitConnect(busUrl)
    defer: client.close()
    let core = startComponent(sandbox.sandboxBin("niffler"), busUrl, sandbox.root,
      extra = [("NIF_MOCK_ROUNDS", "0"), ("NIF_AUTO_APPROVE", "1")],
      logFile = sandbox.root / "var/core.log")
    defer: stopProcess(core)
    doAssert waitCoreUp(client)
    writeFile(sandbox.root / "fault.json", $(%*{"messageRole": "assistant"}))
    let args = %*{"sessionId": "outage", "content": "first"}
    let failed = call(client, "core", "session", args, 30_000)
    check("the active turn reports persistence failure, not success",
          failed{"outcome"}.getStr() == "error" and
          failed{"turnError"}.getStr().contains("transcript persistence failed"), $failed)
    let after = call(client, "store", "list", %*{"kind": "message", "idPrefix": "outage:"})
    check("failure stops the transcript at the committed user message",
          after{"items"}.len == 1 and after{"items"}[0]{"id"}.getStr() == "outage:000001", $after)
    args["content"] = %"second"
    let resumed = call(client, "core", "session", args, 30_000)
    check("the same runner reloads and completes a subsequent turn",
          resumed{"outcome"}.getStr() == "success", $resumed)
    let kept = call(client, "store", "get", %*{"kind": "message", "id": "outage:000002"})
    check("resume uses the next contiguous canonical id",
          kept{"value", "content"}.getStr() == "second", $kept)

  report("TRANSCRIPT SAFETY")

main()
