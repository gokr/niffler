## mock_parallel_llm — test-only `llm` stand-in for tests/t_parallel.nim.
##
## Answers chat deterministically over the bus, no provider, no network. On
## the first working round it returns a scripted batch of tool_calls chosen by
## NIF_MOCK_SCENARIO:
##   wave        — read a.txt, read b.txt, grep needle, files *.txt
##                 (4 parallel-safe calls, 2 same-component pairs)
##   interleave  — read a.txt, bash "echo serial-ok", read b.txt
##                 (a non-parallel bash call splitting two read waves)
##   slow        — sa_slow, sb_slow (two 1s-sleeping tools on two different
##                 spawned components — proves cross-component concurrency)
##   replica     — sr_slow ×8 (one logical component, four process replicas in
##                 its NATS queue group — proves same-component concurrency;
##                 handlers report pid + start/finish stamps so the assertion
##                 checks real overlap instead of wall-clock timing)
## Every later working round returns the final reply "parallel-done".

import std/[json, os, strutils, tables]
import niffler/sdk

let comp = newComponent("llm", "0.1.0-mock")
var workingRounds = initTable[string, int]()
let scenario = getEnv("NIF_MOCK_SCENARIO", "wave")

## NIF_MOCK_FAIL_FIRST (retry scenario): fail the first N chat calls with a
## retryable 503 before answering normally — exercises the runner's B3
## auto-retry. 0 (default) never fails.
var failFirst = 0
block:
  let v = getEnv("NIF_MOCK_FAIL_FIRST", "0")
  try: failFirst = parseInt(v)
  except CatchableError: discard
var chatCalls = 0

discard comp.tool("chat", %*{
  "type": "object",
  "description": "Mock chat (test only)",
  "properties": {
    "messages": {"type": "array"},
    "sessionId": {"type": "string"},
    "stream": {"type": "boolean"}
  },
  "required": ["messages"],
  "x-harness": {"hidden": true, "timeoutMs": 120000}
},
proc(c: Component, args: JsonNode): JsonNode =
  inc chatCalls
  if chatCalls <= failFirst:
    # Bus-level error envelope → the runner's dispatchToolCall raises with
    # this message, classified retryable (503).
    raise newException(ValueError, "llm HTTP 503: mock transient outage")
  # Strict providers reject dangling assistant calls on the next request.
  var outstanding: seq[string]
  for message in args{"messages"}:
    if message{"role"}.getStr("") == "tool":
      let id = message{"tool_call_id"}.getStr("")
      let idx = outstanding.find(id)
      if idx < 0: raise newException(ValueError, "unmatched tool result")
      outstanding.delete(idx)
    else:
      if outstanding.len > 0:
        raise newException(ValueError, "missing tool results")
      let calls = message{"tool_calls"}
      if calls != nil and calls.kind == JArray:
        for call in calls:
          discard parseJson(call{"function", "arguments"}.getStr("{}"))
          outstanding.add(call{"id"}.getStr(""))
  if outstanding.len > 0:
    raise newException(ValueError, "missing tool results")
  let sid = args{"sessionId"}.getStr("")
  workingRounds[sid] = workingRounds.getOrDefault(sid) + 1
  if scenario == "truncated":
    let round = workingRounds[sid]
    if round == 1 or (round == 2 and sid == "truncated-twice"):
      return %*{"finish_reason": "length", "tool_calls": [
        {"id": "cut-valid-" & $round, "type": "function", "function": {
          "name": "bash", "arguments": "{\"command\":\"touch forbidden.txt\"}"}},
        {"id": "cut-bad-" & $round, "type": "function", "function": {
          "name": "bash", "arguments": "{"}}]}
    if round == 2:
      return %*{"finish_reason": "tool_calls", "tool_calls": [
        {"id": "reissued", "type": "function", "function": {
          "name": "bash", "arguments": "{\"command\":\"touch reissued.txt\"}"}}]}
    return %*{"content": "reissue-done"}
  if scenario == "provenance":
    # Issue #101 end-to-end: one bash call that reports the provenance it was
    # handed. Drives the REAL dispatch seam and the runner's resolved turn
    # identity, not a hand-built __session.
    if workingRounds[sid] == 1:
      return %*{"content": "", "model": "mock-model", "tool_calls": [
        {"id": "p1", "type": "function",
         "function": {"name": "bash", "arguments":
           """{"command":"echo SID=[$NIF_SESSION_ID] MODEL=[$NIF_MODEL] PROVIDER=[$NIF_PROVIDER]"}"""}}]}
    return %*{"content": "provenance-done", "model": "mock-model"}
  if scenario == "stuck" or scenario == "stuck-progress":
    # Issue #135. "stuck" repeats one call whose RESULT never changes; the turn
    # must end `stuck` after one steer. "stuck-progress" repeats the SAME call
    # but the result changes every time (a counter file), which is a legitimate
    # poll and must NOT be failed — the detector compares result digests.
    let round = workingRounds[sid]
    if round > 40:
      return %*{"content": "gave up", "model": "mock-model"}
    let args =
      if scenario == "stuck": """{"command":"echo same"}"""
      else: """{"command":"n=$(cat n.txt 2>/dev/null || echo 0); echo $((n+1)) > n.txt; cat n.txt"}"""
    return %*{"content": "", "model": "mock-model", "tool_calls": [
      {"id": "s" & $round, "type": "function",
       "function": {"name": "bash", "arguments": args}}]}
  if scenario == "component-death":
    # Issue #116: ask for a tool on a component the test kills mid-call, then
    # close the turn with a report so the transcript is complete.
    if workingRounds[sid] == 1:
      return %*{"content": "", "model": "mock-model", "tool_calls": [
        {"id": "c1", "type": "function",
         "function": {"name": "hang", "arguments": "{}"}}]}
    return %*{"content": "component-death-done", "model": "mock-model"}
  if workingRounds[sid] == 1:
    var calls = newJArray()
    var n = 0
    let fn = proc(name, arguments: string) =
      inc n
      calls.add(%*{"id": "c" & $n, "type": "function",
                   "function": {"name": name, "arguments": arguments}})
    case scenario
    of "wave":
      fn("read", """{"path":"a.txt"}""")
      fn("read", """{"path":"b.txt"}""")
      fn("grep", """{"pattern":"needle"}""")
      fn("files", """{"glob":"*.txt"}""")
    of "interleave":
      fn("read", """{"path":"a.txt"}""")
      fn("bash", """{"command":"echo serial-ok"}""")
      fn("read", """{"path":"b.txt"}""")
    of "slow":
      fn("sa_slow", "{}")
      fn("sb_slow", "{}")
    of "replica":
      for i in 1 .. 8:
        fn("sr_slow", "{\"label\":\"call-" & $i & "\"}")
    else:
      return %*{"content": "unknown scenario", "model": "mock-model"}
    return %*{"content": "", "tool_calls": calls, "model": "mock-model"}
  return %*{"content": "parallel-done", "model": "mock-model",
            "usage": {"prompt_tokens": 100, "completion_tokens": 10,
                      "total_tokens": 110,
                      "prompt_tokens_details": {"cached_tokens": 80}}})

discard comp.tool("llm_resolve", %*{
  "type": "object",
  "description": "Mock resolve (test only)",
  "properties": {},
  "x-harness": {"hidden": true, "timeoutMs": 10000}
},
proc(c: Component, args: JsonNode): JsonNode =
  %*{"ok": true, "model": "mock-model"})

comp.run()
