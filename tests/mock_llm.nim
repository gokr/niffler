## mock_llm — test-only `llm` stand-in (tests/t_expert.nim, docs/research/EXPERT.md).
##
## Answers chat deterministically over the bus, no provider, no network:
## - a call whose last message carries the "expert-observation" marker is an
##   expert judgment. The steer is keyed by the observed user request:
##   requests containing "diff" get a git_diff steer (the sandbox runs the
##   real git component, so the session-visible validation passes for an
##   unrestricted session); requests containing "build" get a bash steer
##   naming only the tool already in the activity frame — the expert's
##   tool-change gate must suppress it;
## - the first round of each working session returns a scripted bash
##   tool_call, which keeps the turn in its tool loop long enough for the
##   expert to judge and deliver turn-bound advice mid-turn;
## - every later working round returns the final reply "working-done".
##
## The mock replaces var/bin/llm inside the test sandbox only.

import std/[json, os, strutils, tables]
import niffler/sdk

# Env-gated test modes (all default off — unset env reproduces the historic
# mock exactly, so t_expert and friends are untouched):
# - NIF_MOCK_CTX: provider context window in tokens. Requests over it are
#   REJECTED with the adapter's stable context-overflow text (the same
#   normalization components/llm applies) — the enforcing fake provider of
#   the §8 long-turn fixture. Reported back as usage.context so admission
#   learns the window the way a real provider teaches it.
# - NIF_MOCK_HIDE_CTX: omit the window from responses too — capacity stays
#   unknown, so the first oversized request reaches the provider and the
#   §6.5 overflow-recovery path is exercised end to end.
# - NIF_MOCK_ROUNDS: scripted tool-call rounds before the final answer
#   (drives many tool rounds through one user turn).
# - NIF_MOCK_TOOLCMD: the bash command the scripted rounds call.
# - NIF_MOCK_LOG: JSONL request log (one line per chat request) so tests
#   assert sizes/rejections against the mock's own view.
# - NIF_MOCK_PT_BIAS: tokens the provider adds to its own chars/4 count
#   when REPORTING usage and ENFORCING the window — models a tokenizer that
#   packs denser than the core's chars/4 proxy (DeepSeek-class: ~4-5%). The
#   core must learn this offset from reported usage (calibration) and fire
#   the pressure ladder before the provider ever refuses.
# - NIF_MOCK_ENFORCE_CTX: the rejection threshold the chat handler enforces,
#   independent of the window llm_resolve reports — models the real-world
#   gap where a host's effective input limit sits below its catalog window
#   (thinking/output reserves count against it).
# - NIF_MOCK_RAW_OVERFLOW: 1 rejects with the RAW provider phrasing (no
#   context-overflow prefix, no window suffix) — the classifier must catch
#   the provider's own words ("Context limit exceeded").
let mockCtx = block:
  let v = getEnv("NIF_MOCK_CTX", "0")
  try: parseInt(v)
  except CatchableError: 0
let mockPtBias = block:
  let v = getEnv("NIF_MOCK_PT_BIAS", "0")
  try: parseInt(v)
  except CatchableError: 0
let mockEnforceCtx = block:
  let v = getEnv("NIF_MOCK_ENFORCE_CTX", "0")
  try: parseInt(v)
  except CatchableError: 0
let mockRawOverflow = getEnv("NIF_MOCK_RAW_OVERFLOW", "").len > 0
let mockHideCtx = getEnv("NIF_MOCK_HIDE_CTX", "").len > 0
let mockRounds = block:
  let v = getEnv("NIF_MOCK_ROUNDS", "0")
  try: parseInt(v)
  except CatchableError: 0
let mockToolCmd = getEnv("NIF_MOCK_TOOLCMD",
  "head -c 30000 /dev/zero | tr '\\0' 'x'")
let mockLog = getEnv("NIF_MOCK_LOG", "")
let mockHistoryMarker = getEnv("NIF_MOCK_HISTORY_MARKER", "")
let mockCompactionSleepMs = block:
  try: parseInt(getEnv("NIF_MOCK_COMPACTION_SLEEP_MS", "0"))
  except CatchableError: 0
var currentSessionId = ""
var currentCancelId = ""
var currentEmitTokens = true
var currentPurpose = ""

proc estimateTokens(messages: JsonNode, tools: JsonNode): int =
  ## Same chars/4 proxy core's estimateTokens uses (plus per-message
  ## overhead), so the mock's reject line matches admission's arithmetic.
  const overheadPerMessage = 8
  if messages != nil and messages.kind == JArray:
    for m in messages:
      inc result, overheadPerMessage
      result += m{"content"}.getStr("").len div 4
      result += m{"reasoning"}.getStr("").len div 4
      let tcs = m{"tool_calls"}
      if tcs != nil:
        for tc in tcs:
          result += tc{"function"}{"name"}.getStr("").len div 4
          result += tc{"function"}{"arguments"}.getStr("").len div 4 + 4
  if tools != nil:
    result += ($tools).len div 4

proc containsText(messages: JsonNode, needle: string): bool =
  if needle.len == 0 or messages == nil or messages.kind != JArray: return false
  for m in messages:
    if m{"content"}.getStr("").contains(needle): return true

proc markerStart(messages: JsonNode, needle: string): int =
  ## Canonical fixture marker, excluding a checkpoint that summarizes and
  ## therefore legitimately quotes that marker later in its rendered body.
  if needle.len == 0 or messages == nil or messages.kind != JArray: return -1
  for i in 0 ..< messages.len:
    if messages[i]{"content"}.getStr("").startsWith(needle): return i
  -1

proc logRequest(estimate: int, rejected: bool, note: string,
                messages, tools: JsonNode) =
  if mockLog.len == 0: return
  try:
    let f = open(mockLog, fmAppend)
    defer: f.close()
    let line = %*{"tools": tools, "estimate": estimate, "rejected": rejected,
                  "note": note,
                  "checkpoint": containsText(messages, "<context_checkpoint"),
                  "steer": containsText(messages, "Steer: "),
                  "historyMarker": markerStart(messages, mockHistoryMarker) >= 0,
                  "historyMarkerIndex": markerStart(messages, mockHistoryMarker),
                  "sessionId": currentSessionId,
                  "cancelId": currentCancelId,
                  "emitTokens": currentEmitTokens,
                  "purpose": currentPurpose}
    f.writeLine($line)
  except CatchableError:
    discard

let comp = newComponent("llm", "0.1.0-mock")
var workingFirstRound = initTable[string, bool]()
var roundsServed = initTable[string, int]()

discard comp.tool("chat", %*{
  "type": "object",
  "description": "Mock chat (test only)",
  "properties": {
    "messages": {"type": "array"},
    "sessionId": {"type": "string"},
    "cancelId": {"type": "string"},
    "stream": {"type": "boolean"},
    "emitTokens": {"type": "boolean"},
    "purpose": {"type": "string"}
  },
  "required": ["messages"],
  "x-harness": {"hidden": true, "runner": true, "timeoutMs": 120000}
},
proc(c: Component, args: JsonNode): JsonNode =
  currentSessionId = args{"sessionId"}.getStr("")
  currentCancelId = args{"cancelId"}.getStr("")
  currentEmitTokens = args{"emitTokens"}.getBool(true)
  currentPurpose = args{"purpose"}.getStr("")
  let messages = args{"messages"}
  let est = estimateTokens(messages, args{"tools"})
  # The provider's own view of the request: chars/4 plus its tokenizer
  # bias. Rejections and reported usage both speak this scale.
  let providerCount = est + mockPtBias
  let rejectAt = if mockEnforceCtx > 0: mockEnforceCtx else: mockCtx
  if rejectAt > 0 and providerCount > rejectAt:
    logRequest(providerCount, true, "over-window", messages, args{"tools"})
    if mockRawOverflow:
      # The raw phrasing a real host returns — no stable prefix, no window
      # suffix (the provider counts a thinking/output reserve against the
      # window, so its effective input limit is what rejects here).
      raise newException(ValueError,
        "llm error: error, status code: 400, status: 400 Bad Request, " &
        "message: , body: {\"error\":\"Context limit exceeded\"}")
    # The enforcing fake provider: same stable text the real adapter emits
    # (core/retry.nim classifies on the prefix, recovery parses the window).
    raise newException(ValueError,
      "context-overflow: request ~" & $est & " tokens exceeds the mock " &
      "window of " & $mockCtx & "; window " & $mockCtx & " tokens")
  logRequest(providerCount, false, "", messages, args{"tools"})
  if currentPurpose == "compaction" and mockCompactionSleepMs > 0:
    sleep(mockCompactionSleepMs)
  var last = ""
  if messages != nil and messages.kind == JArray and messages.len > 0:
    last = messages[^1]{"content"}.getStr("")
  if last.contains("[COMPACTION INSTRUCTION]"):
    # Deterministic structured checkpoint for compaction fixtures. Echo the
    # first covered user entry: on generation 1 that is the objective; on a
    # later generation it is the rendered previous checkpoint, proving the
    # new checkpoint actually absorbed (rather than stacked beside) it.
    var seed = "Compacted conversation"
    if messages != nil and messages.kind == JArray:
      for i in 0 ..< max(messages.len - 1, 0):
        let m = messages[i]
        let body = m{"content"}.getStr("")
        if m{"role"}.getStr("") == "user" and body.len > 0:
          seed = body
          break
    if seed.len > 3500: seed = seed[0 ..< 3500]
    let excerpt = if seed.len > 240: seed[0 ..< 240] else: seed
    let checkpoint = %*{
      "objective": seed,
      "constraints": ["Keep canonical history unchanged"],
      "decisions": ["Install only a runner-validated checkpoint"],
      "completedWork": [excerpt],
      "currentBlocker": newJNull(),
      "nextSteps": ["Continue from the retained tail"]
    }
    return %*{"content": $checkpoint, "model": "mock-summary-model",
      "usage": {"prompt_tokens": est, "completion_tokens": 120,
                "total_tokens": est + 120}}
  if last.contains("expert-observation"):
    # The tools value is markdown-decorated on purpose ("`git_diff`"):
    # judges habitually wrap names in backticks and the expert must
    # normalize before validating against the catalog (bench finding:
    # decorated names silenced good steers).
    var steer = "{\"action\":\"steer\",\"message\":\"Use `git_diff` for the " &
      "next comparison instead of shell git.\",\"tools\":[\"`git_diff`\"]," &
      "\"confidence\":\"high\",\"reason\":\"dedicated tool exists\"}"
    if last.contains("build"):
      # Names only the tool already in the activity frame: the tool-change
      # gate must suppress this as repetition, not a change of tool.
      steer = "{\"action\":\"steer\",\"message\":\"Use `bash` to run the " &
        "build.\",\"tools\":[\"bash\"],\"confidence\":\"high\"," &
        "\"reason\":\"bash fits\"}"
    return %*{"content": steer, "model": "mock-model",
      # cached-input breakdown (docs/research/EXPERT.md §8): lets t_expert assert the
      # expert's token accounting sees prompt-cache hits
      "usage": {"prompt_tokens": 900, "completion_tokens": 30,
                "total_tokens": 930,
                "prompt_tokens_details": {"cached_tokens": 800}}}
  let sessionId = args{"sessionId"}.getStr("")
  if mockRounds > 0:
    # Scripted multi-round fixture (§8 long-turn): N bash rounds per actual
    # user request, then a final answer echoing the first real user message.
    # Checkpoint/instruction user-role nodes are runner machinery and do not
    # start another scripted batch.
    var userTurns = 0
    if messages != nil and messages.kind == JArray:
      for m in messages:
        let body = m{"content"}.getStr("")
        if m{"role"}.getStr("") == "user" and
            not body.startsWith("<context_checkpoint") and
            not body.startsWith("[COMPACTION INSTRUCTION]"):
          inc userTurns
    let served = roundsServed.getOrDefault(sessionId, 0)
    if served < mockRounds * max(userTurns, 1):
      roundsServed[sessionId] = served + 1
      return %*{"content": "",
                "tool_calls": [%*{"id": "c" & $served, "type": "function",
                                  "function": {"name": "bash",
                                               "arguments": $(%*{"command": mockToolCmd})}}],
                "model": "mock-model",
                # Real providers report usage on tool-call rounds too; the
                # core measures its calibration offset from every response.
                "usage": {"prompt_tokens": providerCount,
                          "completion_tokens": 0,
                          "total_tokens": providerCount}}
    var objective = ""
    if messages != nil and messages.kind == JArray:
      for m in messages:
        let c = m{"content"}.getStr("")
        if m{"role"}.getStr("") == "user" and c.len > 0 and
            not c.startsWith("[") and
            not c.startsWith("<context_checkpoint"):
          objective = c
          break
    var usage = %*{"prompt_tokens": providerCount, "completion_tokens": 10,
                   "total_tokens": providerCount + 10}
    if mockCtx > 0 and not mockHideCtx:
      usage["context"] = %mockCtx
    return %*{"content": "done — " & objective, "model": "mock-model",
              "usage": usage}
  if not workingFirstRound.getOrDefault(sessionId, false):
    workingFirstRound[sessionId] = true
    # The scripted bash call sleeps: it is the expert's delivery window. The
    # runner pumps svc.session.<id>.advise from dispatch's idle slot while
    # the tool call is in flight, so a mid-turn advisory is accepted here.
    return %*{"content": "",
              "tool_calls": [%*{"id": "c1", "type": "function",
                                "function": {"name": "bash",
                                             "arguments": "{\"command\":\"sleep 1.5\"}"}}],
              "model": "mock-model"}
  return %*{"content": "working-done", "model": "mock-model",
            "usage": {"prompt_tokens": 100, "completion_tokens": 10,
                      "total_tokens": 110}})

discard comp.tool("llm_resolve", %*{
  "type": "object",
  "description": "Mock resolve (test only)",
  "properties": {},
  "x-harness": {"hidden": true, "runner": true, "timeoutMs": 10000}
},
proc(c: Component, args: JsonNode): JsonNode =
  # The real llm component reports the resolved model's context window here;
  # admission (§6.1) learns the capacity from it before the first request.
  # NIF_MOCK_HIDE_CTX withholds it to exercise the §6.5 recovery path where
  # capacity is unknown until the provider rejects.
  var r = %*{"ok": true, "model": "mock-model"}
  if mockCtx > 0 and not mockHideCtx:
    r["context"] = %mockCtx
  r)

comp.run()
