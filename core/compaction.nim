## Compaction contract — the replaceable summarization seam, runner side
## (docs/research/COMPACTION.md §4.4–4.6, §6.2).
##
## This module is the CONTRACT: configuration, permitted-cut computation,
## snapshot chunking, candidate validation, the runner-owned checkpoint
## render template, and the projection record builder. It is deliberately
## pure — JSON and values in, JSON and values out, no bus, no Persister —
## so the validator unit tests without a store. The runner glue (snapshot
## I/O, the propose dispatch, commit with expectRev, context replace) lives
## in core/conversation.nim, which owns the context representation.
##
## Ownership (§4.1): the runner owns budgets, admission, node identity,
## valid boundaries, validation and the projection; the component owns
## choosing among valid cuts, summarization and quality. It never writes
## conversation or projection records and never executes tools described
## in the supplied history.

import std/[json, os, strutils]
import checksums/sha2

const
  compactionSnapshotPageBytes* = 512_000
    ## Each snapshot content page stays far under the bus max_payload (§4.4);
    ## the meta record names the page count, and a missing/incomplete page
    ## fails the attempt.
  snapshotSweepSecs* = 600.0
    ## Grace for timed-out readers: settled snapshots are deleted at once; a
    ## crashed attempt's docs are swept when older than this.
  ckMaxFieldLen* = 4000
  ckMaxListLen* = 32
  ckMaxFiles* = 64
  ckMaxTotalBytes* = 65_536
  rendererId* = "checkpoint-v1"
    ## The runner-owned render template version (§6.1): any compaction
  ## component's checkpoint renders through the same frame, so a candidate
  ## stored by one implementation reloads under another.

type CompactionConfig* = object
  tool*: string            ## "" = summarization disabled; the guard still runs
  timeoutMs*: int
  maxLlmCalls*: int
  maxSummaryTokens*: int

proc compactionConfigFromEnv*(): CompactionConfig =
  ## Harness-level configuration (§4.1). Session overrides persisting in
  ## the conversation header land with the configuration matrix (step 6).
  result.tool = getEnv("NIF_COMPACTION_TOOL", "compaction_propose").strip()
  result.timeoutMs = 90_000
  result.maxLlmCalls = 4
  result.maxSummaryTokens = 2048
  try:
    if getEnv("NIF_COMPACTION_TIMEOUT_MS").len > 0:
      result.timeoutMs = parseInt(getEnv("NIF_COMPACTION_TIMEOUT_MS"))
    if getEnv("NIF_COMPACTION_MAX_LLM_CALLS").len > 0:
      result.maxLlmCalls = parseInt(getEnv("NIF_COMPACTION_MAX_LLM_CALLS"))
    if getEnv("NIF_COMPACTION_MAX_SUMMARY_TOKENS").len > 0:
      result.maxSummaryTokens = parseInt(
        getEnv("NIF_COMPACTION_MAX_SUMMARY_TOKENS"))
  except CatchableError:
    discard
  result.timeoutMs = clamp(result.timeoutMs, 5_000, 600_000)
  result.maxLlmCalls = clamp(result.maxLlmCalls, 1, 16)
  result.maxSummaryTokens = clamp(result.maxSummaryTokens, 128, 32_768)

# --- permitted cut positions (§4.3) -----------------------------------------

type CutBoundary* = object
  fromIndex*: int      ## first covered projection entry
  index*: int          ## first retained entry after the covered span
                       ## (the cut sits before it)
  id*: string          ## that entry's node id — the cutBefore ref
  source*: string      ## its node source ("canonical" today)

proc foldToolBalance(toolCallIds, answeredIds: openArray[string], i: int,
                     openCalls: var seq[string]) =
  if i < toolCallIds.len and toolCallIds[i].len > 0:
    for tc in toolCallIds[i].split('\x1f'):
      if tc.len > 0: openCalls.add(tc)
  if i < answeredIds.len and answeredIds[i].len > 0:
    let idx = openCalls.find(answeredIds[i])
    if idx >= 0: openCalls.delete(idx)

proc permittedCuts*(ids, sources, roles: openArray[string],
                    toolCallIds: openArray[string],
                    answeredIds: openArray[string]): seq[CutBoundary] =
  ## A cut is legal only where tool pairing is balanced (no unanswered tool
  ## call crosses it — the balance fold), the retained tail keeps the most
  ## recent actual user request visible (§4.3 rule 3), and at least one
  ## non-system entry is covered (cutBefore ≥ index 2). `ids`/`sources`/
  ## `roles` describe the projection entries in order (index 0 = the system
  ## node); `toolCallIds[i]` are the call ids declared by entry i and
  ## `answeredIds[i]` the result id it answers. There are no minimum
  ## user-turn counts: one enormous autonomous turn must be cuttable,
  ## which is the whole point.
  if ids.len != sources.len or ids.len != roles.len or ids.len < 3:
    return @[]
  var latestUser = -1
  for i in 0 ..< roles.len:
    if sources[i] == "canonical" and roles[i] == "user": latestUser = i
  if latestUser < 1: return @[]
  # Preferred old-prefix cuts: the newest actual user request and its whole
  # tail remain verbatim. A prior checkpoint at index 1 is naturally
  # absorbed on the next generation.
  if latestUser >= 2:
    var openCalls: seq[string]
    for i in 1 .. latestUser:
      foldToolBalance(toolCallIds, answeredIds, i - 1, openCalls)
      if openCalls.len == 0 and i >= 2:
        result.add(CutBoundary(fromIndex: 1, index: i,
          id: ids[i], source: sources[i]))
  # Autonomous-turn cuts: once the newest request is already the first
  # canonical entry, compact older COMPLETE tool groups after it while
  # retaining both that request and a non-empty recent tail. This is what
  # makes one 40-round turn cuttable without ever replacing the request.
  let middleFrom = latestUser + 1
  if middleFrom + 1 < ids.len:
    var openCalls: seq[string]
    for i in middleFrom + 1 ..< ids.len:
      foldToolBalance(toolCallIds, answeredIds, i - 1, openCalls)
      if openCalls.len == 0:
        result.add(CutBoundary(fromIndex: middleFrom, index: i,
          id: ids[i], source: sources[i]))

# --- snapshot chunking (§4.4) -----------------------------------------------

proc chunkSnapshotContent*(content: string): seq[string] =
  ## Split serialized snapshot JSON into exact byte chunks, each far under
  ## max_payload. Chunks concatenate byte-for-byte before parse; an
  ## individual huge message therefore cannot create an oversized page.
  if content.len == 0: return @[""]
  var offset = 0
  while offset < content.len:
    let stop = min(offset + compactionSnapshotPageBytes, content.len)
    result.add(content[offset ..< stop])
    offset = stop

proc contentDigest*(s: string): string =
  "sha256:" & $(block:
    var st = initSha_256()
    st.update(s)
    st.digest())

proc strictlyReduces*(coveredTokens, checkpointTokens: int): bool =
  ## Candidate acceptance is based on the runner's own measurement, never a
  ## component's claimed savings (§6.1).
  coveredTokens > 0 and checkpointTokens < coveredTokens

# --- checkpoint render template (runner-owned, §6.1) -------------------------

proc renderCheckpoint*(cp: JsonNode, generation: int,
                       coveredFrom, coveredTo: string): string =
  ## Frame a validated checkpoint into the message the provider sees. The
  ## template is runner-owned and versioned — a candidate stored by
  ## compactor A reloads identically under compactor B (§8 test 7). The
  ## frame carries its executable recall ref, like prune/spill notices.
  var convId = coveredFrom
  let sep = block:
    let colon = convId.find(':')
    let hash = convId.find('#')
    if colon >= 0 and hash >= 0: min(colon, hash)
    elif colon >= 0: colon
    else: hash
  if sep >= 0: convId = convId[0 ..< sep]
  let checkpointId = convId & "#ck" & $generation
  result = "<context_checkpoint generation=\"" & $generation & "\""
  if coveredFrom.len > 0:
    result &= " covered=\"" & coveredFrom & ".." & coveredTo & "\""
  result &= ">\n"
  result &= "Recall ref: {\"source\":\"checkpoint\",\"id\":\"" &
            checkpointId & "\"}\n"
  result &= "Objective: " & cp{"objective"}.getStr("") & "\n"
  let list = func (name: string): string =
    var outp = ""
    if cp{name} != nil and cp{name}.kind == JArray:
      for item in cp{name}:
        outp.add("- " & item.getStr("") & "\n")
    outp
  result &= "Constraints:\n" & list("constraints")
  result &= "Decisions:\n" & list("decisions")
  result &= "Completed work:\n" & list("completedWork")
  if cp{"currentBlocker"} != nil and cp{"currentBlocker"}.kind == JString and
      cp{"currentBlocker"}.getStr("").len > 0:
    result &= "Current blocker: " & cp{"currentBlocker"}.getStr("") & "\n"
  result &= "Next steps:\n" & list("nextSteps")
  if cp{"files"} != nil and cp{"files"}.kind == JArray and
      cp{"files"}.len > 0:
    result &= "Files touched:\n" & list("files")
  result &= "</context_checkpoint>"

# --- candidate validation (§4.5) ---------------------------------------------

type CandidateStatus* = enum
  csCandidate      ## a valid candidate — the caller commits it
  csDeclined       ## a first-class decline; `declineReason` is stable
  csInvalid        ## malformed/out-of-contract — bounded fallback path

const declineReasons = ["no-useful-cut", "input-budget-exceeded", "indivisible"]
const ckFields = ["objective", "constraints", "decisions", "completedWork",
                  "currentBlocker", "nextSteps"]

proc validateCandidate*(cand: JsonNode, attemptId: string,
                       baseGeneration: int, expectedDigest: string,
                       cuts: seq[CutBoundary], coveredFromIdx, coveredToIdx: int,
                       currentIds, currentSources, currentRoles: openArray[string]): tuple[status: CandidateStatus,
                       checkpoint: JsonNode, declineReason: string,
                       detail: string] =
  ## Validate one candidate against the contract. `cuts` is the runner's
  ## permitted set; `coveredFromIdx/coveredToIdx` is the range the claimed
  ## cutBefore implies; `currentIds/Sources/Roles` is the live projection
  ## (the covered nodes must still be present and un-replaced). The strict-
  ## reduction check (§6.1: the rendered checkpoint must cost less than the
  ## span it replaces) lives with the caller, which can price both sides.
  ## Raises nothing: every rejection comes back as csInvalid with a reason,
  ## feeding the same bounded fallback path as timeouts and declines (§6.3).
  result.checkpoint = JsonNode(nil)
  if cand == nil or cand.kind != JObject:
    result.status = csInvalid
    result.detail = "candidate is not an object"
    return
  if cand{"version"}.getInt(0) != 1:
    result.status = csInvalid; result.detail = "unsupported version"; return
  if cand{"attemptId"}.getStr("") != attemptId:
    result.status = csInvalid; result.detail = "attemptId mismatch"; return
  let status = cand{"status"}.getStr("")
  case status
  of "declined":
    let reason = cand{"reason"}.getStr("")
    if reason notin declineReasons:
      result.status = csInvalid
      result.detail = "decline reason \"" & reason & "\" is not a stable one"
      return
    result.status = csDeclined; result.declineReason = reason
    return
  of "candidate": discard
  else:
    result.status = csInvalid; result.detail = "unknown status \"" & status & "\""
    return
  # generation and digest: the candidate must have read THIS snapshot of
  # THIS generation — "the surface changed under you" made detectable.
  if cand{"baseGeneration"}.getInt(-1) != baseGeneration:
    result.status = csInvalid
    result.detail = "baseGeneration " &
      $cand{"baseGeneration"}.getInt(-1) & " != " & $baseGeneration
    return
  if cand{"snapshotDigest"}.getStr("") != expectedDigest:
    result.status = csInvalid; result.detail = "snapshotDigest mismatch"; return
  # cutBefore must be one of the runner's permitted boundaries
  let cb = cand{"cutBefore"}
  var cutIdx = -1
  if cb != nil and cb.kind == JObject:
    for c in cuts:
      if c.id == cb{"id"}.getStr("") and c.source == cb{"source"}.getStr(""):
        cutIdx = c.index
        break
  if cutIdx < 0:
    result.status = csInvalid
    result.detail = "cutBefore is not a permitted boundary"
    return
  # covered must be exactly the range the checkpoint absorbs. Reject bad
  # caller/state dimensions as data errors rather than indexing through a
  # corrupt ledger — this validator promises not to raise.
  if currentIds.len != currentSources.len or
      currentIds.len != currentRoles.len or
      coveredFromIdx < 0 or coveredToIdx < coveredFromIdx or
      coveredToIdx >= currentIds.len or cutIdx != coveredToIdx + 1:
    result.status = csInvalid
    result.detail = "covered range indexes do not match the live projection"
    return
  let covered = cand{"covered"}
  if covered == nil or covered.kind != JObject:
    result.status = csInvalid; result.detail = "covered range missing"; return
  let wantFrom = currentIds[coveredFromIdx]
  let wantTo = currentIds[coveredToIdx]
  if covered{"from"}{"id"}.getStr("") != wantFrom or
      covered{"from"}{"source"}.getStr("") != currentSources[coveredFromIdx] or
      covered{"to"}{"id"}.getStr("") != wantTo or
      covered{"to"}{"source"}.getStr("") != currentSources[coveredToIdx]:
    result.status = csInvalid
    result.detail = "covered range does not match the claimed cut"
    return
  # the checkpoint object: six required fields, bounded, no unknown fields
  let cp = cand{"checkpoint"}
  if cp == nil or cp.kind != JObject:
    result.status = csInvalid; result.detail = "checkpoint missing"; return
  for f in ckFields:
    if cp{f} == nil:
      result.status = csInvalid; result.detail = "checkpoint field \"" & f & "\" missing"
      return
  for key, val in cp:
    if key notin ckFields and key != "files":
      result.status = csInvalid
      result.detail = "unknown checkpoint field \"" & key & "\" (v1 rejects)"
      return
  if cp{"objective"}.kind != JString or
      cp{"objective"}.getStr("").len == 0 or
      cp{"objective"}.getStr("").len > ckMaxFieldLen:
    result.status = csInvalid; result.detail = "objective must be a non-empty bounded string"; return
  for f in ["constraints", "decisions", "completedWork", "nextSteps"]:
    if cp{f}.kind != JArray or cp{f}.len > ckMaxListLen:
      result.status = csInvalid
      result.detail = "checkpoint field \"" & f & "\" must be a bounded list"
      return
    for item in cp{f}:
      if item.kind != JString or item.getStr("").len > ckMaxFieldLen:
        result.status = csInvalid
        result.detail = "checkpoint field \"" & f & "\" has a non-string or oversized item"
        return
  if not (cp{"currentBlocker"}.kind == JNull or
          (cp{"currentBlocker"}.kind == JString and
           cp{"currentBlocker"}.getStr("").len <= ckMaxFieldLen)):
    result.status = csInvalid; result.detail = "currentBlocker must be null or a bounded string"
    return
  var files: seq[string]
  if cp{"files"} != nil and cp{"files"}.kind != JNull:
    if cp{"files"}.kind != JArray or cp{"files"}.len > ckMaxFiles:
      result.status = csInvalid; result.detail = "files must be a bounded list"
      return
    for item in cp{"files"}:
      if item.kind != JString or item.getStr("").len == 0 or
          item.getStr("").len > ckMaxFieldLen:
        result.status = csInvalid; result.detail = "files has an invalid entry"
        return
      files.add(item.getStr(""))
  if ($(cand{"checkpoint"})).len > ckMaxTotalBytes:
    result.status = csInvalid; result.detail = "checkpoint exceeds the encoded size bound"
    return
  # strict reduction (§6.1): the rendered checkpoint must cost less than
  # the span it replaces — the normalized checkpoint carries the files list
  var normalized = cp
  if files.len > 0:
    normalized = cp.copy()
    normalized["files"] = %files
  result.checkpoint = normalized
  result.status = csCandidate

# --- projection record builder (§6.2) ----------------------------------------

proc buildProjectionRecord*(generation, canonicalHigh: int, cp: JsonNode,
                            coveredFrom, coveredTo: string,
                            retained: seq[string],
                            prunes: JsonNode, measurements, provenance: JsonNode): JsonNode =
  ## One context_projection record per conversation; written with expectRev
  ## on the previous generation by the runner (§6.2 — commit order: validate
  ## → single acknowledged store put → replace in-memory context → emit).
  result = %*{
    "version": 1,
    "generation": generation,
    "canonicalHigh": canonicalHigh,
    "renderer": rendererId,
    "checkpoint": cp,
    "covered": {"from": coveredFrom, "to": coveredTo},
    "retained": retained,
    "prunes": prunes,
  }
  if measurements != nil: result["measurements"] = measurements
  if provenance != nil: result["provenance"] = provenance
