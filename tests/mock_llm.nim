## mock_llm — test-only `llm` stand-in (tests/t_expert.nim, docs/research/EXPERT.md).
##
## Answers chat deterministically over the bus, no provider, no network:
## - a call whose last message carries the "expert-observation" marker is an
##   expert judgment: answers with a steer JSON naming git_diff (the sandbox
##   runs the real git component, so the expert's tool validation passes);
## - the first working turn round returns a scripted bash tool_call, which
##   keeps the turn in its tool loop long enough for the expert to judge and
##   deliver turn-bound advice mid-turn;
## - every later working round returns the final reply "working-done".
##
## The mock replaces var/bin/llm inside the test sandbox only.

import std/[json, strutils]
import niffler/sdk

let comp = newComponent("llm", "0.1.0-mock")
var workingRounds = 0

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
  let messages = args{"messages"}
  var last = ""
  if messages != nil and messages.kind == JArray and messages.len > 0:
    last = messages[^1]{"content"}.getStr("")
  if last.contains("expert-observation"):
    # The tools value is markdown-decorated on purpose ("`git_diff`"):
    # judges habitually wrap names in backticks and the expert must
    # normalize before validating against the catalog (bench finding:
    # decorated names silenced good steers).
    return %*{"content":
      "{\"action\":\"steer\",\"message\":\"Use `git_diff` for the next " &
      "comparison instead of shell git.\",\"tools\":[\"`git_diff`\"]," &
      "\"confidence\":\"high\",\"reason\":\"dedicated tool exists\"}",
      "model": "mock-model",
      # cached-input breakdown (docs/research/EXPERT.md §8): lets t_expert assert the
      # expert's token accounting sees prompt-cache hits
      "usage": {"prompt_tokens": 900, "completion_tokens": 30,
                "total_tokens": 930,
                "prompt_tokens_details": {"cached_tokens": 800}}}
  workingRounds += 1
  if workingRounds == 1:
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
  "x-harness": {"hidden": true, "timeoutMs": 10000}
},
proc(c: Component, args: JsonNode): JsonNode =
  %*{"ok": true, "model": "mock-model"})

comp.run()
