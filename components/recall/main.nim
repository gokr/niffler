## context_recall — hidden tool resolving the replaced-content reference
## space (docs/research/COMPACTION.md §5.3).
##
## Content leaves the model's context in two ways — execution-time spills
## and compaction-time prunes/checkpoints — and both must stay retrievable.
## Every prune/spill notice names a ref; this tool resolves it:
##
##   {"source": "canonical",  "id": "conv-…:000090"}  → store message body
##   {"source": "spill",      "id": "conv-…:000090"}  → full original capture
##   {"source": "checkpoint", "id": "conv-…#ck3"}     → projection checkpoint
##
## Failure is never worse than the status quo: an unresolvable ref returns a
## clear error naming what is unavailable — and the runner only ever prunes
## content whose original it first durably kept (canonical body or spill
## document), so a broken spill doc can never cost the last copy.

import std/[json, os, strutils]
import niffler/sdk

const
  recallMaxBytes = 262_144     ## hard byte ceiling per recalled document
  recallDefaultLines = 2000    ## mirrors read's default line cap
  matchDefaultLines = 50

proc paged(s: string, offset, limit: int): tuple[text: string, totalLines: int,
                                                 truncated: bool] =
  ## Line paging with a hard byte ceiling (capBytes keeps head+tail and says
  ## exactly what was cut — the model can narrow with mode:match instead of
  ## re-paging blindly).
  var lines = s.split('\n')
  if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  result.totalLines = lines.len
  let start = max(offset - 1, 0)
  if start >= lines.len:
    result.text = ""
    return
  let stop = min(start + max(limit, 1), lines.len)
  result.text = lines[start ..< stop].join("\n")
  result.truncated = stop < lines.len or result.text.len > recallMaxBytes
  if result.text.len > recallMaxBytes:
    result.text = capBytes(result.text, recallMaxBytes,
      "page with offset/limit or narrow with mode:match")

proc matchLines(s, query: string, limit: int): string =
  ## Cheap grep over the recalled document: the lines containing query,
  ## capped, so "which of the 400 error lines was the timeout one" costs
  ## one call instead of paging the whole capture through context.
  var count = 0
  for line in s.split('\n'):
    if line.contains(query):
      result.add(line & "\n")
      inc count
      if count >= limit:
        result.add("[context_recall: match list capped at " & $limit &
                   " lines — narrow the query]\n")
        break

proc convOf(id: string): string =
  ## "conv-…:000090" / "conv-…#ck3" → the conversation id part.
  for i, c in id:
    if c == ':' or c == '#': return id[0 ..< i]
  id

proc resolveRef(c: Component, refNode: JsonNode, mode, query: string,
                offset, limit: int): JsonNode =
  ## Resolve one reference to text (+ provenance). Errors raise ValueError —
  ## the caller converts to a per-ref error entry so an array of refs
  ## degrades independently.
  let source = refNode{"source"}.getStr("")
  let id = refNode{"id"}.getStr("")
  if id.len == 0:
    raise newException(ValueError, "ref is missing its id")
  case source
  of "canonical":
    # The stored message body — never edited after the fact, so this is the
    # un-pruned original whenever canonical is the full copy.
    let item = c.storeGet("message", id)
    if item.value == nil or item.value.kind == JNull:
      raise newException(ValueError,
        "canonical message " & id & " not found — it may predate this store")
    let text = item.value{"content"}.getStr("")
    if mode == "match":
      if query.len == 0:
        raise newException(ValueError, "mode:match needs query")
      result = %*{"ref": refNode, "text": matchLines(text, query, limit),
                  "bytes": text.len, "matches": true}
    else:
      let pg = paged(text, offset, limit)
      result = %*{"ref": refNode, "text": pg.text, "bytes": text.len,
                  "totalLines": pg.totalLines}
      if pg.truncated: result["truncated"] = %true
  of "spill":
    # The full original capture (execution-time spill, promoted to the store
    # by the runner at append time) — byte-identical to what the tool
    # produced, bounded by the same paging discipline as read.
    let item = c.storeGet("spill", id)
    if item.value == nil or item.value.kind == JNull:
      raise newException(ValueError,
        "spill document " & id & " not found — it may have been swept or " &
        "this result predates spill promotion; the canonical transcript " &
        "still holds what entered context")
    let text = item.value{"text"}.getStr("")
    if text.len == 0:
      # A malformed/empty document must never masquerade as a successful
      # recall of nothing — the runner's prune gate treats this the same as
      # a missing document and keeps the original un-pruned.
      raise newException(ValueError,
        "spill document " & id & " is empty or malformed (no text field)")
    if mode == "match":
      if query.len == 0:
        raise newException(ValueError, "mode:match needs query")
      result = %*{"ref": refNode, "text": matchLines(text, query, limit),
                  "bytes": text.len, "matches": true}
    else:
      let pg = paged(text, offset, limit)
      result = %*{"ref": refNode, "text": pg.text, "bytes": text.len,
                  "totalLines": pg.totalLines}
      if pg.truncated: result["truncated"] = %true
  of "checkpoint":
    # The projection record's checkpoint (§6.2) — the model can re-read what
    # a compaction summarized, including the files list. Populated from
    # step 4 on; until then the store has no projection record, and the
    # error says exactly that.
    let conv = convOf(id)
    var item: StoreItem
    try:
      item = c.storeGet("context_projection", conv)
    except StoreNotFoundError:
      raise newException(ValueError,
        "no projection record for " & conv & " — nothing has been compacted yet")
    if item.value == nil or item.value.kind == JNull:
      raise newException(ValueError,
        "no projection record for " & conv & " — nothing has been compacted yet")
    let gen = block:
      let hash = id.rfind('#')
      if hash >= 0:
        try: parseInt(id[hash + 1 .. ^1].replace("ck", ""))
        except CatchableError: -1
      else: -1
    if gen >= 0 and item.value{"generation"}.getInt(0) < gen:
      raise newException(ValueError,
        "checkpoint " & id & " is superseded (current generation " &
        $item.value{"generation"}.getInt(0) & ")")
    result = %*{"ref": refNode, "checkpoint": item.value{"checkpoint"},
                "generation": item.value{"generation"}.getInt(0)}
  else:
    raise newException(ValueError,
      "unknown ref source \"" & source & "\" — expected canonical, spill or checkpoint")

proc main() =
  let comp = newComponent("recall", "0.1.0")

  let schema = toolSchema(%*{
    "ref": {"description": "One reference ({source, id}) or an array of them — every notice in the conversation names its ref verbatim",
            "oneOf": [{"type": "object"}, {"type": "array", "items": {"type": "object"}}]},
    "mode": {"type": "string", "enum": ["full", "match"],
             "description": "full (default) returns the paged document; match greps it"},
    "query": {"type": "string",
              "description": "mode:match — return only the lines containing this"},
    "offset": {"type": "integer", "minimum": 1,
               "description": "full mode: start line (default 1)"},
    "limit": {"type": "integer", "minimum": 1,
              "description": "full mode: max lines (default 2000, read's cap); match mode: max matching lines (default 50)"}
  }, description = "Retrieve original content that was replaced in this conversation's context (pruned tool results, spilled command output, compaction checkpoints). Every notice naming replaced content carries its ref verbatim — pass it back here unchanged. Use it when exact wording or the full body of a large result matters; mode:match greps a large document for specific lines without paging it all into context.")
  schema["x-harness"] = %*{"hidden": true, "timeoutMs": 15_000}

  discard comp.tool("context_recall", schema,
    proc(c: Component, args: JsonNode): JsonNode =
      let mode = args{"mode"}.getStr("full")
      if mode notin ["full", "match"]:
        return errResult("mode must be \"full\" or \"match\"", "bad-request")
      let query = args{"query"}.getStr("")
      let offset = args{"offset"}.getInt(1)
      let limit = args{"limit"}.getInt(if mode == "match": matchDefaultLines
                                       else: recallDefaultLines)
      let refArg = args{"ref"}
      if refArg == nil:
        return errResult("context_recall needs ref", "bad-request")

      if refArg.kind == JArray:
        # An array of refs degrades independently: one broken reference must
        # not hide the others' content.
        var refs = newJArray()
        for r in refArg:
          try:
            refs.add(resolveRef(c, r, mode, query, offset, limit))
          except CatchableError as e:
            refs.add(%*{"ref": r, "error": e.msg})
        return okResult(%*{"refs": refs})

      try:
        let r = resolveRef(c, refArg, mode, query, offset, limit)
        return okResult(r)
      except StoreNotFoundError as e:
        return errResult("context_recall: " & e.msg, "unresolvable")
      except CatchableError as e:
        return errResult("context_recall: " & e.msg, "unresolvable"))

  comp.run()

when isMainModule:
  main()
