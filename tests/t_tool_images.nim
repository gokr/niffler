## Tool-produced images end to end (docs/WIRE.md "Tool results").
##
## The transport for a UI drop already shipped (tests/t_attachments.nim); this
## is the OTHER half: a TOOL result may carry `images`, which is the only way a
## component can return something the model sees rather than reads. Drives a
## real core against a fixture component that returns images (valid, lying,
## too many, too large, mislabelled) and a recording OpenAI-compatible
## provider, then asserts what the provider actually received.
##
## Pins the properties that make the design safe:
##   * a valid result image reaches the provider as an image part, with the
##     tool's own caption as text;
##   * a refused image NEVER fails the turn — it is reported inside the tool
##     message, because the tool's text still answers the call;
##   * the pixels are stored as their own documents (never inline base64 in
##     the message a `list` page reads);
##   * the toolcall event carries descriptors, not megabytes;
##   * a plain result is untouched by the whole contract.

import std/[base64, json, os, osproc, strutils, times]
import natsnim
import helpers
import ../sdk/niffler/jsonx

proc stopHard(p: var Process) =
  ## Terminate-then-kill, then close: leaked test children hold ports.
  if p != nil and p.running():
    p.terminate()
    sleep(800)
    if p.running(): p.kill()
    sleep(300)
  if p != nil: p.close()
  p = nil

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  ## Poll the catalog's component view until `name` is registered (robust
  ## against fast registrations that precede a reg.publish subscription).
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("toolimages",
    ["store", "provider", "llm", "edit"])
  copyFileWithPermissions(repoRoot / "var" / "bin" / "session",
                          sandbox.sandboxBin("session"))
  # The fixture is a test component, not a shipped one: it registers only
  # because the test's core has no manifest entry for it (NIF_ROOT is the
  # sandbox) and this binary sits in the sandbox bin dir.
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

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

  # Start the fixture component directly. It is a plain bus peer: the
  # catalog accepts any reg.publish, so no manifest entry and no persisted
  # spawn record are needed (a record would make the supervisor start it a
  # second time).
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fixture-image-tool",
                          sandbox.sandboxBin("imagetool"))
  var toolProc = startComponent(sandbox.sandboxBin("imagetool"), url,
                                root = sandbox.root)
  defer: stopHard(toolProc)
  check("the image-returning fixture registers on the bus",
        waitComponent(nc, "imagetool"), "imagetool never registered")

  proc requestCount(): int =
    if not fileExists(reqFile): return 0
    for line in readFile(reqFile).splitLines():
      if line.strip().len > 0: inc result

  proc waitRequest(after: int, ms = 30_000): JsonNode =
    let deadline = epochTime() + ms.float / 1000.0
    while epochTime() < deadline:
      if requestCount() > after:
        var last: JsonNode = nil
        for line in readFile(reqFile).splitLines():
          let t = line.strip()
          if t.len == 0: continue
          try: last = parseJson(t)
          except CatchableError: discard
        return last
      sleep(50)
    nil

  proc toolImageParts(req: JsonNode): int =
    ## Image parts the provider received on any TOOL message.
    for m in req{"messages"}.listOf:
      if m{"role"}.getStr("") != "tool": continue
      for part in m{"content"}.listOf:
        if part{"type"}.getStr("") == "image_url": inc result

  proc lastToolText(req: JsonNode, tool: string): string =
    for m in req{"messages"}.listOf:
      if m{"role"}.getStr("") == "tool" and m{"name"}.getStr("") == tool:
        if m{"content"}.isStr: return m{"content"}.getStr("")
        var text = ""
        for part in m{"content"}.listOf:
          if part{"type"}.getStr("") == "text": text.add(part{"text"}.getStr(""))
        return text

  # --- a valid image reaches the provider -----------------------------------
  let before0 = requestCount()
  let ok = call(nc, "core", "session", %*{
    "sessionId": "img-ok", "content": "TOOLCALL:img_ok show me the screenshot"},
    120_000)
  check("a turn whose tool returns an image succeeds",
        ok{"ok"}.getBool(false), $ok)
  let req0 = waitRequest(before0)
  check("the turn reached the provider", req0 != nil, "")
  if req0 != nil:
    check("the tool result carried one image part to the provider",
          toolImageParts(req0) == 1, jdump(req0))
    var toolText = lastToolText(req0, "img_ok")
    check("the tool's own caption is the message text (the format, not JSON)",
          toolText.contains("[image: shot.png image/png"), toolText)
    var dataUrls = 0
    for m in req0{"messages"}.listOf:
      if m{"role"}.getStr("") != "tool": continue
      for part in m{"content"}.listOf:
        if part{"type"}.getStr("") == "image_url":
          let u = part{"image_url"}{"url"}.getStr("")
          if u.startsWith("data:image/png;base64,") and
              u.contains("iVBORw0KGgo"): inc dataUrls
    check("the image part is a PNG data URL with the original bytes",
          dataUrls == 1, $dataUrls)

  # --- what was STORED ------------------------------------------------------
  let stored = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "img-ok:"})
  var storedTool: JsonNode = nil
  for item in stored{"items"}:
    if item{"value"}{"role"}.getStr("") == "tool": storedTool = item{"value"}
  check("the tool message is stored", storedTool != nil, jdump(stored))
  if storedTool != nil:
    check("the stored tool message carries refs, not base64 pixels",
          not ($storedTool).contains("iVBORw0KGgo"), $storedTool)
    check("the ref names the attachment docs and keeps the provider's format",
          storedTool{"attachments"}[0]{"id"}.getStr("").len > 0 and
          storedTool{"attachments"}[0]{"mimeType"}.getStr("") == "image/png",
          $storedTool{"attachments"})
    check("the tool message keeps its caption text and an image count",
          storedTool{"text"}.getStr("") == "" and
          storedTool{"attachText"}.getStr("").contains("shot.png") and
          storedTool{"imageCount"}.getInt(0) == 1, $storedTool)
    let attId = storedTool{"attachments"}[0]{"id"}.getStr("")
    if attId.len > 0:
      check("the attachment id is derived from the tool message's own key",
            attId.startsWith("img-ok:"), attId)
      let meta = call(nc, "store", "get", %*{
        "kind": "attachment", "id": attId})
      check("the metadata doc is pixel-free and names the tool message",
            meta{"ok"}.getBool(false) and
            not (jdump(meta)).contains("iVBORw0KGgo") and
            meta{"value"}{"messageId"}.getStr("").startsWith("img-ok:"), jdump(meta))
      let pixels = call(nc, "store", "get", %*{
        "kind": "attachmentdata", "id": attId})
      check("the pixels live in their own document",
            pixels{"ok"}.getBool(false) and
            pixels{"value"}{"data"}.getStr("").startsWith("iVBORw0KGgo"),
            $pixels)

  # --- a lying component cannot poison the transcript ----------------------
  let before1 = requestCount()
  let bad = call(nc, "core", "session", %*{
    "sessionId": "img-bad", "content": "TOOLCALL:img_bad show me the picture"}, 120_000)
  check("a turn whose tool returns non-image bytes still succeeds",
        bad{"ok"}.getBool(false) and bad{"error"} == nil, jdump(bad))
  let req1 = waitRequest(before1)
  check("the refused-image turn reached the provider", req1 != nil, "")
  if req1 != nil:
    check("no image part was sent for the lying component",
          toolImageParts(req1) == 0, $(toolImageParts(req1)))
    let body = lastToolText(req1, "img_bad")
    check("the model is told why the pixels are missing, in the tool message",
          body.contains("here is the picture you asked for") and
          body.contains("not attached") and
          body.contains("not a recognized image"), body)
  let badMsgs = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "img-bad:"})
  var refusedMessages = 0
  for item in badMsgs{"items"}:
    if item{"value"}{"attachments"} != nil: inc refusedMessages
  check("a refused image stores no refs", refusedMessages == 0,
        $refusedMessages)

  # --- too many images ------------------------------------------------------
  let before2 = requestCount()
  let many = call(nc, "core", "session", %*{
    "sessionId": "img-many", "content": "TOOLCALL:img_many show me all the frames"}, 120_000)
  check("a turn with too many result images still succeeds",
        many{"ok"}.getBool(false) and many{"error"} == nil, jdump(many))
  let req2 = waitRequest(before2)
  if req2 != nil:
    check("not one of the six images was attached",
          toolImageParts(req2) == 0, $toolImageParts(req2))
    let body = lastToolText(req2, "img_many")
    check("the count refusal names the limit",
          body.contains("six frames") and body.contains("too many images") and
          body.contains("(limit 4)"), body)

  # --- too large ------------------------------------------------------------
  let before3 = requestCount()
  let huge = call(nc, "core", "session", %*{
    "sessionId": "img-huge", "content": "TOOLCALL:img_huge show me the big one"}, 120_000)
  check("a turn with an oversized result image still succeeds",
        huge{"ok"}.getBool(false) and huge{"error"} == nil, jdump(huge))
  let req3 = waitRequest(before3)
  if req3 != nil:
    check("the oversized image was dropped, not sent",
          toolImageParts(req3) == 0, $toolImageParts(req3))
    let body = lastToolText(req3, "img_huge")
    check("the size refusal names the inline limit",
          body.contains("a big one") and body.contains("inline limit"), body)

  # --- bytes beat the declared MIME ----------------------------------------
  let before4 = requestCount()
  let meta = call(nc, "core", "session", %*{
    "sessionId": "img-meta", "content": "TOOLCALL:img_meta show me the mislabelled one"},
    120_000)
  check("a mislabelled image still runs its turn", meta{"ok"}.getBool(false), jdump(meta))
  let req4 = waitRequest(before4)
  if req4 != nil:
    check("the image was attached under its REAL format, not the claim",
          toolImageParts(req4) == 1 and ($req4).contains("data:image/jpeg"),
          $(toolImageParts(req4)))

  # --- the ordinary result path is untouched -------------------------------
  let before5 = requestCount()
  let none = call(nc, "core", "session", %*{
    "sessionId": "img-none", "content": "TOOLCALL:img_none just the plain one"}, 120_000)
  check("a result with no images runs normally", none{"ok"}.getBool(false), $none)
  let req5 = waitRequest(before5)
  if req5 != nil:
    check("a plain result stays a plain string in the transcript",
          lastToolText(req5, "img_none") == "plain text result",
          lastToolText(req5, "img_none"))
    check("no image parts appear for a plain result",
          toolImageParts(req5) == 0, $toolImageParts(req5))

  # --- a resume rebuilds the projection ------------------------------------
  # The runner is killed; the next call resumes from the store and must
  # materialize the tool's image again from its refs.
  let before6 = requestCount()
  let resumed = call(nc, "core", "session", %*{
    "sessionId": "img-ok", "content": "TOOLCALL:img_ok and now?"}, 120_000)
  check("the resumed turn succeeds",
        resumed{"ok"}.getBool(false) and resumed{"error"} == nil, $resumed)
  let req6 = waitRequest(before6)
  check("the resumed turn reached the provider", req6 != nil, "")
  if req6 != nil:
    check("a resumed conversation still carries the tool image",
          toolImageParts(req6) == 1, $toolImageParts(req6))

  # --- `read` on an image path ---------------------------------------------
  # The producer users actually reach: a screenshot exists on disk, the model
  # reads its path. This is the dead end the whole slice removes (it used to
  # be refused as `[E_NOT_TEXT] ... looks binary`), and it needs no new tool
  # and no new argument — `read` is already in every conversation's direct
  # toolset.
  let png = base64.decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")
  let imgPath = sandbox.root / "shot.png"
  writeFile(imgPath, png)
  let read = call(nc, "edit", "read", %*{"path": imgPath}, 20_000)
  check("read on an image path succeeds instead of refusing it as binary",
        read{"error"} == nil and read{"images"} != nil, jdump(read))
  if read{"images"} != nil:
    check("read returns the pixels with the byte-sniffed format",
          read{"images"}[0]{"data"}.getStr("") == base64.encode(png) and
          read{"images"}[0]{"mimeType"}.getStr("") == "image/png",
          $read{"images"}[0]{"mimeType"})
    check("read reads the dimensions out of the header",
          read{"images"}[0]{"width"}.getInt(0) == 1 and
          read{"images"}[0]{"height"}.getInt(0) == 1, $read{"images"}[0])
    check("the caption names the file, format and size",
          read{"text"}.getStr("").contains("shot.png") and
          read{"text"}.getStr("").contains("image/png"), $read{"text"})

  # A `.png` that is really text must stay text: detection is by bytes.
  let liar = sandbox.root / "liar.png"
  writeFile(liar, "this is not an image at all\n")
  let liarRead = call(nc, "edit", "read", %*{"path": liar}, 20_000)
  # A single-file read answers with the bare body string (no wrapper object)
  # unless it carries images, so unwrap both shapes.
  proc bodyOf(r: JsonNode): string =
    if r.isStr: r.getStr() else: r{"text"}.getStr("")
  check("a text file named .png is still read as text",
        liarRead{"images"} == nil and
        bodyOf(liarRead).contains("not an image at all"),
        jdump(liarRead))

  # A genuinely binary non-image keeps its existing refusal and its hint.
  let blob = sandbox.root / "blob.bin"
  writeFile(blob, "\x00\x01\x02\x03binary junk")
  let blobRead = call(nc, "edit", "read", %*{"path": blob}, 20_000)
  check("a non-image binary is still refused with the binary message",
        blobRead{"error"}.getStr("").contains("looks binary"), jdump(blobRead))

  # An image too large to attach is reported, never silently resized.
  let bigPath = sandbox.root / "big.png"
  writeFile(bigPath, png & repeat('\0', 4_000_000))
  let bigRead = call(nc, "edit", "read", %*{"path": bigPath}, 30_000)
  check("an oversized read image is reported instead of attached",
        bigRead{"error"} == nil and bigRead{"images"} == nil and
        bigRead{"attached"}.getBool(true) == false and
        bigRead{"text"}.getStr("").contains("not attached"), jdump(bigRead))

  # --- a batch read forwards pixels too ------------------------------------
  # A batch is one result, so its images share core's per-result cap. The
  # component must NOT silently drop the ones that do not fit: a model that
  # asked for two screenshots and got one caption would have no way to tell.
  let b1 = sandbox.root / "b1.png"
  let b2 = sandbox.root / "b2.png"
  writeFile(b1, png)
  writeFile(b2, png)
  # Liveness probe first: if this fails, the batch failure below is about the
  # component, not about batches.
  let single = call(nc, "edit", "read", %*{"path": b1}, 15_000)
  check("the edit component still answers a single read",
        single{"error"} == nil, jdump(single))
  let batch = call(nc, "edit", "read", %*{
    "reads": [{"path": b1}, {"path": b2}]}, 60_000)
  # A batch reply mixing an image item with a text item must serialize: the
  # machine `content` field of an image item has no text source, and a nil
  # value there used to crash the component mid-encode (every later call then
  # answered "no responders").
  let txt = sandbox.root / "t.txt"
  writeFile(txt, "plain text beside an image\n")
  let mixed = call(nc, "edit", "read", %*{
    "reads": [{"path": b1}, {"path": txt}]}, 30_000)
  check("a batch mixing an image and a text item answers",
        mixed{"error"} == nil and mixed{"images"} != nil and
        mixed{"images"}.len == 1, jdump(mixed))
  check("the text item still carries its content in the batch",
        mixed{"items"}[1]{"content"}.getStr("").contains("plain text"),
        jdump(mixed{"items"}))
  check("an image item reports no capturable text source",
        mixed{"items"}[0]{"content"}.jkind == JNull, jdump(mixed{"items"}[0]))
  check("a batch read of two images attaches both",
        batch{"images"} != nil and batch{"images"}.len == 2, jdump(batch))
  check("both captions reach the batch text",
        batch{"text"}.getStr("").contains("b1.png") and
        batch{"text"}.getStr("").contains("b2.png"), $batch{"text"})

  # Over the per-result cap: attach what fits and SAY which did not.
  var manyImgs = newJArray()
  for i in 0 .. 5:
    let p = sandbox.root / ("m" & $i & ".png")
    writeFile(p, png)
    manyImgs.add(%*{"path": p})
  let manyRead = call(nc, "edit", "read", %*{"reads": manyImgs}, 30_000)
  check("a batch over the per-result image cap attaches only the cap",
        manyRead{"images"} != nil and manyRead{"images"}.len == 4,
        jdump(manyRead))
  check("the batch text names the files that were not attached",
        manyRead{"text"}.getStr("").contains("not attached") and
        manyRead{"text"}.getStr("").contains("m4.png"),
        $manyRead{"text"})

  # --- a text-only model gets elision, not a rejected request --------------
  # Without this, an image in history is sent to a model that rejects image
  # parts — and a provider rejects the WHOLE conversation, not just the turn,
  # so every later turn in that conversation would fail. Core learns the
  # capability from the same resolve that reports the window and elides every
  # image (the honest text marker) instead. The mock reports it only when
  # NIF_MOCK_VISION is set, which is also the check that an UNKNOWN capability
  # keeps images materialized rather than guessing.
  #
  # A fresh harness, because the capability is per-conversation and this
  # fixture's mock llm is the one that must answer it.
  block textOnlyModel:
    let sandbox2 = newCoreSandbox("toolimages-textonly",
      ["store", "provider", "llm", "edit"])
    copyFileWithPermissions(repoRoot / "var" / "bin" / "session",
                            sandbox2.sandboxBin("session"))
    # Replace the sandbox's llm with the deterministic mock (prebuilt by
    # `make test-server`): a second llm component beside the manifest's would
    # race for the same subject, and this test needs the mock's answer.
    discard fixtureBin(sandbox2, "llm", repoRoot / "tests" / "mock_llm.nim",
                       prebuiltName = "fixture-mock-llm")
    let (server2, url2) = startNats()
    defer: stopServer(server2)
    var nc2 = waitConnect(url2)
    defer: nc2.close()
    # The mock IS the provider here, so the evidence is its own request log —
    # and it ENFORCES text-only (any request carrying image parts is refused
    # the way a real text-only backend refuses it), which makes a passing turn
    # proof that no image part was sent.
    let mockLog2 = sandbox2.root / "var" / "textonly-requests.jsonl"
    var coreProc2 = startComponent(sandbox2.sandboxBin("niffler"), url2,
                                   root = sandbox2.root, extra = [
      ("NIF_AUTO_APPROVE", "1"),
      ("NIF_MOCK_VISION", "0"),
      ("NIF_MOCK_TEXT_ONLY", "1"),
      ("NIF_MOCK_LOG", mockLog2),
      # Script the tool call through the MOCK (the `TOOLCALL:` marker belongs
      # to the other fixture): one round calls img_ok, whose result carries an
      # image, so round 2's request is the one that would have sent it.
      ("NIF_MOCK_ROUNDS", "1"),
      ("NIF_MOCK_TOOLJSON", $(%*[{"name": "img_ok", "arguments": {}}]))])
    defer:
      if coreProc2.running():
        coreProc2.terminate()
        sleep(1500)
        if coreProc2.running(): coreProc2.kill()
        sleep(200)
      coreProc2.close()
      removeDir(sandbox2.root)
    check("the mock llm registers on the second bus",
          waitComponent(nc2, "llm"), "no llm on the second bus")
    # The image must actually be IN the conversation for this to prove
    # anything: the fixture tool returns one, so round 2's request is the one
    # that would have carried image parts to a text-only model.
    var toolProc2 = startComponent(
      repoRoot / "var" / "bin" / "fixture-image-tool", url2,
      root = sandbox2.root)
    defer: stopHard(toolProc2)
    check("the fixture registers on the second bus",
          waitComponent(nc2, "imagetool"), "imagetool never registered")
    let turn = call(nc2, "core", "session", %*{
      "sessionId": "text-only", "content": "look at the screenshot"},
      120_000)
    check("the turn on a text-only model succeeds", turn{"ok"}.getBool(false),
          jdump(turn))
    var entries: seq[JsonNode] = @[]
    if fileExists(mockLog2):
      for line in readFile(mockLog2).splitLines():
        if line.strip().len > 0:
          try: entries.add(parseJson(line))
          except CatchableError: discard
    var imageParts = 0
    var violations = 0
    for entry in entries:
      imageParts += entry{"imageParts"}.getInt(0)
      if entry{"note"}.getStr("") == "image-part-on-text-only-model":
        inc violations
    check("the mock provider saw the conversation's requests",
          entries.len >= 2, $entries.len & " request(s)")
    check("no request carried an image part to the text-only model",
          imageParts == 0 and violations == 0,
          "imageParts=" & $imageParts & " violations=" & $violations)
    var omitted = 0
    for entry in entries:
      omitted += entry{"omittedImages"}.getInt(0)
    check("the elision marker tells the model an image is there",
          omitted > 0, "omittedImages=" & $omitted)
    check("the text-only model still answered (images were elided, not sent)",
          turn{"ok"}.getBool(false) and
          turn{"error"}.getStr("").len == 0, jdump(turn))

  report("TOOL IMAGES TEST")

main()
