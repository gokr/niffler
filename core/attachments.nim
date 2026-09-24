## Image attachments — from a UI drop to the provider wire.
##
## A UI (the TUI's drag-and-drop) sends a session call's `attachments` array:
## [{type:"image", name, mimeType, data(base64), width, height}]. This module
## owns the whole contract between that call and the provider request:
##
##   * validation (MIME allowlist, per-image and per-turn size caps, base64
##     and magic-byte checks) — core never trusts a client's claim;
##   * the stored form: a message keeps its text and small attachment REFS,
##     never the base64. Inline base64 broke resume once already: `list`
##     replies are capped by the bus max_payload (8MiB), so a page holding
##     two or three screenshots never arrives and the conversation looks
##     clobbered. The pixels live in their own store documents (kind
##     "attachment", id "<messageKey>:a<i>"); conversation.nim owns that
##     I/O and the projection materialization, exactly as compaction.nim
##     owns the contract and the runner owns its store traffic.
##   * the projection shape: the in-memory context carries the OpenAI
##     multimodal content array (text parts + image_url data URLs) because
##     that is what the provider request needs. Which images stay
##     materialized is greedy-newest within the projection budget and a pure
##     function of the refs, so every resume rebuilds exactly the same
##     projection with no ledger to keep.
##
## Budgets: the TUI's caps mirror these (tui/attach.go). The per-turn cap is
## below the projection budget, so a turn's own images are always materialized
## — a turn can never be elided out from under the user. The projection budget
## keeps the `chat` call, a `/export` reply and a compaction snapshot all far
## below the 8MiB bus max_payload.

import std/[base64, json, os, strutils]

import ../sdk/niffler/jsonx

const
  attachMaxCount* = 8
    ## One turn's attachments.
  attachMaxImageB64* = 4_000_000
    ## Per-image base64 cap — the TUI resizes to fit this before sending
    ## (tui/attach.go mirrors it).
  attachMaxTurnB64* = 4_500_000
    ## Per-turn base64 cap across every attachment (mirrored by the TUI).
  attachDefaultBudget* = 5_000_000
    ## Projection budget: how many base64 characters of images stay
    ## materialized in the context. Must stay above attachMaxTurnB64 so the
    ## turn being sent is never partially elided.
  attachMaxDecodedBytes* = 4_000_000
    ## Decoded-byte sanity cap (a base64 blob that decodes to absurd size).
  attachMimes* = ["image/png", "image/jpeg", "image/gif", "image/webp",
                  "image/bmp"]
  attachMarkerPrefix* = "[image omitted to keep the request within the "
    ## Elided images become a text part with this prefix; the rest names the
    ## image and says the original is still stored.

proc projectionBudget*(): int =
  ## Harness default with a test/ops override. Exported so a deployment can
  ## trade context for more concurrent images without a rebuild.
  let raw = getEnv("NIF_ATTACH_BUDGET", "").strip()
  if raw.len > 0:
    try:
      let v = parseInt(raw)
      if v > 0: return v
    except ValueError:
      discard
  attachDefaultBudget

# --- validation --------------------------------------------------------------

proc sniffImageMime(data: openArray[byte]): string =
  ## Magic-byte check: a client's declared MIME is a hint, the bytes decide.
  ## Returns "" when nothing recognizable matches.
  if data.len >= 8 and data[0] == 0x89 and data[1] == 0x50 and
      data[2] == 0x4E and data[3] == 0x47:
    return "image/png"
  if data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF:
    return "image/jpeg"
  if data.len >= 6 and data[0] == 0x47 and data[1] == 0x49 and data[2] == 0x46:
    return "image/gif"
  if data.len >= 12 and data[0] == 0x52 and data[1] == 0x49 and
      data[2] == 0x46 and data[3] == 0x46 and
      data[8] == 0x57 and data[9] == 0x45 and data[10] == 0x42 and
      data[11] == 0x50:
    return "image/webp"
  if data.len >= 2 and data[0] == 0x42 and data[1] == 0x4D:
    return "image/bmp"
  ""

proc validateAttachments*(raw: JsonNode):
    tuple[ok: bool, error: string, refs: seq[JsonNode], payloads: seq[string]] =
  ## Validate one session call's `attachments`. On success `refs` are the
  ## small descriptors the stored message keeps and `payloads` the base64
  ## strings, index-aligned. Every failure is a precise reason: a UI must be
  ## able to tell the user which image was refused and why.
  result = (ok: true, error: "", refs: @[], payloads: @[])
  if raw.isNil: return
  if raw.jkind != JArray:
    return (ok: false, error: "attachments must be an array", refs: @[],
            payloads: @[])
  if raw.len > attachMaxCount:
    return (ok: false,
            error: "too many attachments: " & $raw.len & " (limit " &
                   $attachMaxCount & ")",
            refs: @[], payloads: @[])
  var total = 0
  for i, item in raw.elems:
    if item.jkind != JObject:
      return (ok: false, error: "attachment " & $i & " is not an object",
              refs: @[], payloads: @[])
    if item{"type"}.getStr("image") != "image":
      return (ok: false,
              error: "attachment " & $i & ": only type \"image\" is supported",
              refs: @[], payloads: @[])
    let mime = item{"mimeType"}.getStr("").strip().toLowerAscii()
    if mime notin attachMimes:
      return (ok: false,
              error: "attachment " & $i & ": unsupported MIME type \"" &
                     mime & "\" (have: " & attachMimes.join(", ") & ")",
              refs: @[], payloads: @[])
    let data = item{"data"}.getStr("")
    if data.len == 0:
      return (ok: false, error: "attachment " & $i & ": missing data",
              refs: @[], payloads: @[])
    if data.len > attachMaxImageB64:
      return (ok: false,
              error: "attachment " & $i & " (\"" &
                     item{"name"}.getStr("") & "\"): image exceeds the " &
                     $(attachMaxImageB64 div 1_000_000) & "MB inline limit",
              refs: @[], payloads: @[])
    var decoded: string
    try:
      decoded = decode(data)
    except CatchableError:
      return (ok: false,
              error: "attachment " & $i & ": data is not valid base64",
              refs: @[], payloads: @[])
    if decoded.len == 0:
      return (ok: false, error: "attachment " & $i & ": empty image",
              refs: @[], payloads: @[])
    if decoded.len > attachMaxDecodedBytes:
      return (ok: false,
              error: "attachment " & $i & ": decoded image exceeds " &
                     $(attachMaxDecodedBytes div 1_000_000) & "MB",
              refs: @[], payloads: @[])
    let sniffed = sniffImageMime(decoded.toOpenArrayByte(0, decoded.len - 1))
    if sniffed.len == 0:
      return (ok: false,
              error: "attachment " & $i & " (\"" &
                     item{"name"}.getStr("") &
                     "\"): bytes are not a recognized image",
              refs: @[], payloads: @[])
    total += data.len
    if total > attachMaxTurnB64:
      return (ok: false,
              error: "attachments exceed the " &
                     $(attachMaxTurnB64 div 1_000_000) &
                     "MB per-message limit",
              refs: @[], payloads: @[])
    let width = item{"width"}.getInt(0)
    let height = item{"height"}.getInt(0)
    result.refs.add(%*{
      "id": "",                       # filled by the caller (message key)
      "name": item{"name"}.getStr("").strip(),
      "mimeType": sniffed,
      "bytes": decoded.len,
      "b64": data.len,
      "width": max(0, width),
      "height": max(0, height),
    })
    result.payloads.add(data)

# --- token accounting --------------------------------------------------------

proc attachedImageTokens*(width, height: int): int =
  ## Rough per-image token cost for admission/trim. Anthropic's published
  ## approximation is (w*h)/750; clamped to a floor so tiny images still
  ## cost something and a ceiling so one huge image cannot dominate the
  ## estimate. Only a proxy — the provider's own usage re-calibrates every
  ## response (core's calibration offset).
  if width <= 0 or height <= 0:
    return 1100
  clamp((width * height) div 750, 85, 4000)

proc contentTokens*(message: JsonNode): int =
  ## Token proxy for one message's content, string or multimodal array.
  ## Image parts are matched to the message's refs by order (materialization
  ## writes text parts first, then images in ref order).
  let content = message{"content"}
  if content.isStr:
    return content.getStr("").len div 4
  if content.jkind != JArray: return 0
  let refs = message{"attachments"}
  var imageIndex = 0
  for part in content.elems:
    case part{"type"}.getStr("")
    of "text":
      result += part{"text"}.getStr("").len div 4
    of "image_url":
      var w = 0
      var h = 0
      if refs.jkind == JArray and imageIndex < refs.len:
        w = refs.elems[imageIndex]{"width"}.getInt(0)
        h = refs.elems[imageIndex]{"height"}.getInt(0)
      result += attachedImageTokens(w, h)
      inc imageIndex
    else:
      discard

proc buildContent*(text: string, refs: seq[JsonNode], payloads: seq[string],
                   retain: bool): JsonNode =
  ## The provider content array for one user message: the text part first,
  ## then one part per attachment — image_url when retained, an honest text
  ## marker when elided. `payloads` may be empty when retain is false or
  ## when a payload could not be fetched (that ref degrades to a marker too).
  result = newJArray()
  if text.len > 0:
    result.add(%*{"type": "text", "text": text})
  for i, att in refs:
    let payload = if retain and i < payloads.len: payloads[i] else: ""
    if payload.len > 0:
      result.add(%*{"type": "image_url",
                    "image_url": %*{"url": "data:" &
                      att{"mimeType"}.getStr("image/png") & ";base64," &
                      payload}})
    else:
      let name = att{"name"}.getStr("")
      let shown = if name.len > 0: name else: "attachment"
      result.add(%*{"type": "text", "text": attachMarkerPrefix &
        "window: " & shown & ", " &
        $(att{"bytes"}.getInt(0)) & " bytes — attached earlier in this " &
        "conversation; the original is still stored with this message]"})
  if result.len == 0:
    # A turn is never contentless once it has attachments; this only guards
    # a fully-elided ref list, which cannot occur (one message's images are
    # elided as a unit, and the newest always fits).
    result.add(%*{"type": "text", "text": "[image attachment]"})

proc contentHasImages*(content: JsonNode): bool =
  for part in content.listOf:
    if part{"type"}.getStr("") == "image_url": return true

proc hasAttachments*(message: JsonNode): bool =
  let refs = message{"attachments"}
  refs.jkind == JArray and refs.len > 0

proc snapshotForm*(message: JsonNode): JsonNode =
  ## The stable, elision-independent form of a message: text content and the
  ## attachment refs, never the materialized data URLs. Compaction's
  ## manifest digests and snapshot rows use this, so dropping a new image —
  ## which can elide an older one from the projection — does not invalidate
  ## an in-flight compaction with a spurious "snapshot became stale". A pure
  ## function of what is stored, so it reproduces after a restart.
  if not hasAttachments(message): return message
  result = message.copy()
  result["content"] = %message{"attachText"}.getStr("")
  result.delete("attachText")

proc retainedMessages*(messages: seq[JsonNode], budget: int): seq[bool] =
  ## Which messages' images stay materialized: walk newest to oldest and
  ## keep a message whole while the budget lasts. Whole-message granularity
  ## means one message's images are never half-shown; the per-turn cap is
  ## below the budget, so the newest message always fits.
  result = newSeq[bool](messages.len)
  var used = 0
  for i in countdown(messages.high, 0):
    if not hasAttachments(messages[i]): continue
    var cost = 0
    for att in messages[i]{"attachments"}.elems:
      cost += att{"b64"}.getInt(0)
    if used + cost <= budget:
      result[i] = true
      used += cost

