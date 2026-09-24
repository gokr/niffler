## Image attachments end to end: a session call's `attachments` array is
## validated, stored beside the message, and materialized into the provider
## request as an OpenAI multimodal content array. Drives a real core (store +
## provider + llm + session runner) against a loopback OpenAI-compatible SSE
## fixture that records the request body, then asserts what the provider
## actually received — the only place this contract can be proven.
##
## Also pins the two properties that make the design safe:
##   * the STORED message carries refs, never base64 (a `list` page with
##     inline images outgrows the bus max_payload and resume truncates);
##   * a resumed conversation rebuilds the same projection (pixels survive a
##     runner restart);
##   * a refused attachment fails the call loudly and persists nothing.

import std/[base64, json, os, osproc, strutils, times]
import natsnim
import helpers
import ../sdk/niffler/jsonx

const
  # 1x1 PNG.
  pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
  # 1x1 JPEG.
  jpegB64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("attachments", ["store", "provider", "llm"])
  copyFileWithPermissions(repoRoot / "var" / "bin" / "session",
                          sandbox.sandboxBin("session"))
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # The OpenAI-compatible fixture: records every request body it receives,
  # so the test can assert the wire shape (not just the bus reply).
  let portFile = sandbox.root / "var" / "fixture.port"
  let reqFile = sandbox.root / "var" / "fixture.requests"
  let fixture = startProcess("python3", workingDir = repoRoot, args = @[
    repoRoot / "tests" / "fixtures" / "openai_stream_server.py",
    portFile, reqFile], options = {poUsePath, poParentStreams})
  defer: stopProcess(fixture)
  var port = ""
  for i in 0 ..< 200:
    if fileExists(portFile):
      port = readFile(portFile).strip()
      if port.len > 0: break
    sleep(20)
  check("OpenAI stream fixture starts", port.len > 0)
  if port.len == 0: quit(1)

  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = sandbox.root, extra = [
    ("NIF_AUTO_APPROVE", "1")
  ])
  defer:
    if coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running():
        coreProc.kill()
        sleep(200)
    coreProc.close()
    removeDir(sandbox.root)

  # Register the fixture as the active provider.
  var up = false
  for i in 0 ..< 100:
    let r = call(nc, "provider", "provider_add", %*{
      "nickname": "fixture", "apiKey": "sk-test-fixture",
      "baseUrl": "http://127.0.0.1:" & port & "/v1",
      "model": "fixture-model", "catalog": "openai"}, 3_000)
    if r{"ok"}.getBool(false) or r{"error"}.getStr("").contains("exists"):
      up = true
      break
    sleep(200)
  check("fixture provider registers", up)

  proc lastRequest(): JsonNode =
    if not fileExists(reqFile): return nil
    var last: JsonNode = nil
    for line in readFile(reqFile).splitLines():
      let t = line.strip()
      if t.len == 0: continue
      try: last = parseJson(t)
      except CatchableError: discard
    last

  proc requestCount(): int =
    if not fileExists(reqFile): return 0
    for line in readFile(reqFile).splitLines():
      if line.strip().len > 0: inc result

  proc waitRequest(after: int, ms = 30_000): JsonNode =
    ## Wait until at least `after + 1` request lines exist, then return the
    ## LAST one (the request the caller is waiting for).
    let deadline = epochTime() + ms.float / 1000.0
    while epochTime() < deadline:
      let n = requestCount()
      if n > after:
        var last: JsonNode = nil
        for line in readFile(reqFile).splitLines():
          let t = line.strip()
          if t.len == 0: continue
          try: last = parseJson(t)
          except CatchableError: discard
        return last
      sleep(50)
    nil

  # --- one image with a caption ---------------------------------------------
  let sent = call(nc, "core", "session", %*{
    "sessionId": "attach-basic",
    "content": "what is in this screenshot?",
    "attachments": [%*{"type": "image", "name": "shot.png",
                       "mimeType": "image/png", "data": pngB64,
                       "width": 1, "height": 1}]}, 120_000)
  check("a turn with one image succeeds",
        sent{"ok"}.getBool(false) and sent{"error"} == nil, $sent)

  let req = waitRequest(0)
  check("the provider received a request", req != nil, "")
  if req != nil:
    var userMsg: JsonNode = nil
    for m in req{"messages"}:
      if m{"role"}.getStr("") == "user": userMsg = m
    check("the user message reached the provider", userMsg != nil, $req)
    if userMsg != nil:
      let content = userMsg{"content"}
      check("the content is a multimodal array, not a string",
            content.kind == JArray, $content)
      var text = ""
      var images = 0
      for part in content.elems:
        case part{"type"}.getStr("")
        of "text": text &= part{"text"}.getStr("")
        of "image_url":
          inc images
          check("the image part is a data URL with the right MIME",
                part{"image_url"}{"url"}.getStr("").startsWith(
                  "data:image/png;base64,"), $part)
          check("the image bytes are intact",
                part{"image_url"}{"url"}.getStr("").endsWith(pngB64), $part)
        else: discard
      check("the caption text reached the provider",
            text.contains("what is in this screenshot"), text)
      check("exactly one image part was sent", images == 1, $images)

  # --- what was STORED ------------------------------------------------------
  let stored = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "attach-basic:"})
  var storedUser: JsonNode = nil
  for item in stored{"items"}:
    if item{"value"}{"role"}.getStr("") == "user": storedUser = item{"value"}
  check("the stored message exists", storedUser != nil, $stored)
  if storedUser != nil:
    check("the stored message carries refs, not base64 pixels",
          storedUser{"content"}.kind == JString and
          not ($storedUser).contains(pngB64), $storedUser)
    check("the stored refs name the attachment docs",
          storedUser{"attachments"}[0]{"id"}.getStr("").len > 0 and
          storedUser{"attachments"}[0]{"mimeType"}.getStr("") == "image/png",
          $storedUser{"attachments"})
    check("the stored message keeps the text and an attachment count",
          storedUser{"content"}.getStr("").contains("screenshot") and
          storedUser{"attachmentCount"}.getInt(0) == 1, $storedUser)
  let attachmentId = if storedUser != nil:
                       storedUser{"attachments"}[0]{"id"}.getStr("")
                     else: ""
  if attachmentId.len > 0:
    let doc = call(nc, "store", "get", %*{
      "kind": "attachment", "id": attachmentId})
    check("the pixels live in their own attachment document",
          doc{"ok"}.getBool(false) and
          doc{"value"}{"data"}.getStr("") == pngB64, $doc)
    check("the attachment doc records its message and dimensions",
          doc{"value"}{"messageId"}.getStr("").startsWith("attach-basic:") and
          doc{"value"}{"width"}.getInt(0) == 1, $doc)

  # --- a resume rebuilds the projection ------------------------------------
  # The runner is killed; the next session call resumes from the store and
  # must materialize the image again from its refs.
  # NOTE: count with requestCount() — splitLines() on a trailing-newline
  # file adds an empty last element, so it overcounts by one.
  let beforeResume = requestCount()
  let resumed = call(nc, "core", "session", %*{
    "sessionId": "attach-basic", "content": "and now?"}, 120_000)
  check("the resumed turn succeeds",
        resumed{"ok"}.getBool(false) and resumed{"error"} == nil, $resumed)
  let req2 = waitRequest(beforeResume)
  check("the resumed turn reached the provider", req2 != nil, "")
  if req2 != nil:
    var images = 0
    for m in req2{"messages"}:
      if m{"role"}.getStr("") != "user": continue
      for part in m{"content"}.listOf:
        if part{"type"}.getStr("") == "image_url": inc images
    check("the resumed projection still carries the image", images == 1,
          $images)

  # --- a caption-less drop -------------------------------------------------
  let beforeCaptionless = requestCount()
  let bare = call(nc, "core", "session", %*{
    "sessionId": "attach-bare",
    "attachments": [%*{"type": "image", "name": "j.jpg",
                       "mimeType": "image/jpeg", "data": jpegB64,
                       "width": 1, "height": 1}]}, 120_000)
  check("an image with no caption still runs a turn",
        bare{"ok"}.getBool(false) and bare{"error"} == nil, $bare)
  let req3 = waitRequest(beforeCaptionless)
  check("the caption-less turn reached the provider", req3 != nil, "")
  if req3 != nil:
    var userMsg: JsonNode = nil
    for m in req3{"messages"}:
      if m{"role"}.getStr("") == "user": userMsg = m
    check("the caption-less turn has a multimodal user message",
          userMsg != nil and userMsg{"content"}.kind == JArray, $req3)
    if userMsg != nil:
      check("the surrogate caption is present",
            ($userMsg{"content"}).contains("image attached"), $userMsg)
      check("the jpeg was sent as image/jpeg",
            ($req3).contains("data:image/jpeg;base64,"), "")

  # --- refusals persist nothing --------------------------------------------
  let messagesBefore = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "attach-bad:"}){"items"}.len
  let bad = call(nc, "core", "session", %*{
    "sessionId": "attach-bad", "content": "hi",
    "attachments": [%*{"type": "image", "name": "x.png",
                       "mimeType": "image/png", "data": "bm90IGFuIGltYWdl"}]},
    30_000)
  check("a non-image is refused loudly, naming the reason",
        bad{"error"}.getStr("").contains("attachment rejected") and
        bad{"error"}.getStr("").contains("not a recognized image"), $bad)
  let messagesAfter = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "attach-bad:"}){"items"}.len
  check("a refused attachment persists no message",
        messagesAfter == messagesBefore,
        $messagesBefore & " -> " & $messagesAfter)

  let oversize = call(nc, "core", "session", %*{
    "sessionId": "attach-bad", "content": "hi",
    "attachments": [%*{"type": "image", "name": "big.png",
                       "mimeType": "image/png",
                       "data": repeat('A', 5_000_000)}]}, 30_000)
  check("an oversized image is refused by the per-image cap",
        oversize{"error"}.getStr("").contains("inline limit"), $oversize)

  let tooMany = newJArray()
  for i in 0 .. 8:
    tooMany.add(%*{"type": "image", "name": "s" & $i & ".png",
                   "mimeType": "image/png", "data": pngB64,
                   "width": 1, "height": 1})
  let many = call(nc, "core", "session", %*{
    "sessionId": "attach-bad", "content": "hi", "attachments": tooMany},
    30_000)
  check("too many attachments are refused",
        many{"error"}.getStr("").contains("too many attachments"), $many)

  # --- conversation_delete sweeps the pixels -------------------------------
  discard call(nc, "core", "conversation_delete", %*{
    "sessionId": "attach-basic"}, 30_000)
  if attachmentId.len > 0:
    let gone = call(nc, "store", "get", %*{
      "kind": "attachment", "id": attachmentId})
    check("conversation_delete removes the attachment documents",
          not gone{"ok"}.getBool(true) or gone{"error"} != nil, $gone)
  let left = call(nc, "store", "list", %*{
    "kind": "attachment", "idPrefix": "attach-basic:"})
  check("no attachment document survives the conversation",
        left{"items"}.len == 0, $left)

  report("ATTACHMENTS TEST")

main()
