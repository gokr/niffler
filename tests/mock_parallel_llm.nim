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

import std/[json, os, strutils]
import niffler/sdk

let comp = newComponent("llm", "0.1.0-mock")
var workingRounds = 0
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
  workingRounds += 1
  if workingRounds == 1:
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
