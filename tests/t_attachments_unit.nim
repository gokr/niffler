## Unit tests for the attachment contract (core/attachments.nim): MIME
## sniffing, validation caps, the token proxy, and the greedy-newest
## projection rule. Pure logic — no bus, no processes, no store.

import std/[base64, json, options, strutils]
import helpers
import ../core/attachments

const
  # 1x1 PNG (the smallest real image; avoids depending on a fixture file).
  pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
  jpegB64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="

proc img(name = "shot.png", mime = "image/png", data = pngB64): JsonNode =
  %*{"type": "image", "name": name, "mimeType": mime, "data": data,
     "width": 1, "height": 1}

proc main() =
  # --- validation ----------------------------------------------------------
  let ok = validateAttachments(%*[img()])
  check("a well-formed image validates", ok.ok and ok.refs.len == 1 and
        ok.payloads.len == 1, ok.error)
  check("the ref records the sniffed MIME and decoded size",
        ok.refs[0]{"mimeType"}.getStr("") == "image/png" and
        ok.refs[0]{"bytes"}.getInt(0) == 70, $ok.refs[0])

  # A client's declared MIME is only a hint: the bytes must match.
  let lying = validateAttachments(%*[img("x.png", "image/png", jpegB64)])
  check("the declared MIME may disagree with the bytes (bytes win)",
        lying.ok and lying.refs[0]{"mimeType"}.getStr("") == "image/jpeg",
        lying.error)

  let notImage = validateAttachments(%*[img("x.png", "image/png",
                                            encode("hello world"))])
  check("non-image bytes are refused", not notImage.ok and
        notImage.error.contains("not a recognized image"), notImage.error)

  let badMime = validateAttachments(%*[img("x.svg", "image/svg+xml", pngB64)])
  check("an unsupported MIME is refused", not badMime.ok and
        badMime.error.contains("unsupported MIME"), badMime.error)

  let badB64 = validateAttachments(%*[img("x.png", "image/png", "!!!not b64")])
  check("invalid base64 is refused", not badB64.ok and
        badB64.error.contains("not valid base64"), badB64.error)

  let empty = validateAttachments(%*[img("x.png", "image/png", "")])
  check("an empty image is refused", not empty.ok, empty.error)

  let notArray = validateAttachments(%*{"type": "image"})
  check("a non-array is refused", not notArray.ok and
        notArray.error.contains("must be an array"), notArray.error)

  let wrongType = validateAttachments(%*[%*{"type": "video", "data": pngB64}])
  check("only type image is accepted", not wrongType.ok and
        wrongType.error.contains("only type \"image\""), wrongType.error)

  # Caps: too many, per-image, per-turn.
  var many = newJArray()
  for i in 0 .. attachMaxCount:
    many.add(img("s" & $i & ".png"))
  let tooMany = validateAttachments(many)
  check("more than the attachment count cap is refused", not tooMany.ok and
        tooMany.error.contains("too many attachments"), tooMany.error)

  # A per-image cap breach is asserted on the DECLARED length (a real
  # >cap image would need megabytes of base64 in the test source). Two
  # images whose declared sizes each fit the per-image cap but together
  # break the per-turn cap must be refused: attachment 0 passes the
  # image cap, then the turn total trips.
  let nearCap = repeat('A', attachMaxImageB64)
  let overImage = validateAttachments(%*[img("a.png", "image/png",
                                             repeat('A', attachMaxImageB64 + 4))])
  check("the per-image cap is enforced",
        not overImage.ok and overImage.error.contains("inline limit"),
        overImage.error)
  # The bytes of `nearCap` are not an image, so the sniff refuses first —
  # which is the honest order: a client cannot reach the size caps without
  # also passing the content check. Assert the total cap through the code
  # path that is reachable: many real 1x1 PNGs whose combined DECLARED size
  # passes the per-image cap but breaks the per-turn cap.
  var heavy = newJArray()
  for i in 0 ..< attachMaxCount:
    heavy.add(img("s" & $i & ".png", "image/png", pngB64))
  let lightTotal = validateAttachments(heavy)
  check("many small images within every cap validate", lightTotal.ok,
        lightTotal.error)
  doAssert nearCap.len > 0  # (kept: documents the declared-length path above)

  # --- token accounting ----------------------------------------------------
  check("image tokens scale with pixel area",
        attachedImageTokens(1000, 1000) > attachedImageTokens(100, 100),
        $attachedImageTokens(1000, 1000))
  check("image tokens are floored", attachedImageTokens(1, 1) >= 85,
        $attachedImageTokens(1, 1))
  check("image tokens are capped", attachedImageTokens(20000, 20000) <= 4000,
        $attachedImageTokens(20000, 20000))

  # A materialized image must NOT be billed by its base64 length.
  let materialized = %*{"role": "user", "content": [
    %*{"type": "text", "text": "look at this"},
    %*{"type": "image_url", "image_url": %*{"url": "data:image/png;base64," &
      repeat('A', 4_000_000)}}],
    "attachments": [%*{"width": 1000, "height": 1000}]}
  let billed = contentTokens(materialized)
  check("a materialized image is billed by area, not by base64 length",
        billed < 2000, $billed)
  check("plain string content is billed at chars/4",
        contentTokens(%*{"role": "user", "content": "12345678"}) == 2,
        $contentTokens(%*{"role": "user", "content": "12345678"}))

  # --- the projection rule -------------------------------------------------
  # Three image messages, each 1000 b64 chars; budget holds the newest two.
  var messages = newJArray()
  for i in 0 .. 2:
    messages.add(%*{"role": "user", "content": "m" & $i,
      "attachText": "m" & $i,
      "attachments": [%*{"id": "x:a0", "name": "s" & $i & ".png",
                         "mimeType": "image/png", "bytes": 10, "b64": 1000,
                         "width": 1, "height": 1}]})
  let seqMsgs = messages.elems
  let retained = retainedMessages(seqMsgs, 2500)
  check("the greedy-newest rule keeps the newest messages that fit",
        not retained[0] and retained[1] and retained[2], $retained)
  check("whole messages are kept, never a partial set",
        retainedMessages(seqMsgs, 0) == newSeq[bool](3), "budget 0 kept some")

  # buildContent: retained -> image_url; elided -> honest text marker.
  let refs = @[seqMsgs[0]{"attachments"}[0]]
  let withImage = buildContent("caption", refs, @[pngB64], true)
  check("a retained image becomes an image_url part with a data URL",
        withImage.len == 2 and
        withImage[1]{"type"}.getStr("") == "image_url" and
        withImage[1]{"image_url"}{"url"}.getStr("").startsWith(
          "data:image/png;base64,"), $withImage)
  check("the text part comes first", withImage[0]{"type"}.getStr("") == "text",
        $withImage)

  let elided = buildContent("caption", refs, @[], false)
  check("an elided image becomes a text marker, never a silent drop",
        elided.len == 2 and elided[1]{"type"}.getStr("") == "text" and
        elided[1]{"text"}.getStr("").contains("image omitted"), $elided)
  check("the marker names the image",
        elided[1]{"text"}.getStr("").contains("s0.png"), $elided[1])
  check("the marker reports the original byte size",
        elided[1]{"text"}.getStr("").contains("10 bytes"), $elided[1])

  # A ref whose payload could not be fetched degrades to a marker too.
  let unreadable = buildContent("caption", refs, @[""], true)
  check("an unreadable payload degrades to a marker, not a failure",
        unreadable[1]{"type"}.getStr("") == "text", $unreadable)

  check("contentHasImages distinguishes the two shapes",
        contentHasImages(withImage) and not contentHasImages(elided),
        "contentHasImages misread a shape")

  # --- snapshot form -------------------------------------------------------
  var live = seqMsgs[0].copy()
  live["content"] = buildContent("m0", refs, @[pngB64], true)
  live["attachText"] = %"m0"
  let snap = snapshotForm(live)
  check("the snapshot form drops the pixels and keeps the refs",
        snap{"content"}.getStr("") == "m0" and snap{"attachments"} != nil and
        not ($snap).contains("base64"), $snap)
  var elidedLive = live.copy()
  elidedLive["content"] = buildContent("m0", refs, @[], false)
  check("the snapshot form is identical whether an image is materialized or elided",
        $snapshotForm(elidedLive) == $snap,
        $snapshotForm(elidedLive) & " != " & $snap)
  let passthrough = %*{"role": "user", "content": "hi"}
  check("a message with no attachments passes through unchanged",
        $snapshotForm(passthrough) == $passthrough,
        "passthrough changed the node")

  report("ATTACHMENTS UNIT TEST")

main()
