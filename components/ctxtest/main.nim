## ctxtest — test-only component for the nested-call proxy (tests/t_nested.nim).
##
## Not in the manifest; compiled and started by the test itself. Provides:
## - a stub `chat` LLM: turn 1 returns one tool call to `ctxecho`, turn 2
##   finishes the turn — so a conversation runs without a real LLM;
## - `ctxecho` (x-harness.sessionContext): from inside the live turn it
##   exercises the nested-call proxy on svc.session.<id>.tool — one call with
##   the live lease (must succeed through to the bash component), one with a
##   bogus lease, and one targeting a hidden core tool. The evidence comes
##   back in the tool result so the test can assert on all three.

import std/[json, tables]
import natswrapper
import niffler/sdk

let comp = newComponent("ctxtest", "0.1.0")

var chatStage = initTable[string, int]()
  ## sessionId -> chat calls served (single-threaded SDK poll loop)

comp.tool:
  proc chat(messages: JsonNode = nil, tools: JsonNode = nil,
            sessionId: string = "", stream: bool = false): JsonNode =
    ## Stub LLM surface for the session runner.
    let stage = chatStage.mgetOrPut(sessionId, 0)
    chatStage[sessionId] = stage + 1
    if stage == 0:
      return %*{"content": "",
                "tool_calls": %*[{
                  "id": "t1", "type": "function",
                  "function": {"name": "ctxecho",
                               "arguments": "{\"msg\":\"hi\"}"}}]}
    return %*{"content": "nested-turn-done"}
comp.tools[^1].schema["x-harness"] = %*{"hidden": true}

proc nestedCall(subject, tool: string, args: JsonNode, lease: string,
                timeoutMs: int): Envelope =
  ## One request over the nested-call proxy with an explicit lease value.
  let env = callEnvelope(tool, args, "ctxtest")
  env.args["__session"] = %*{"lease": lease}
  comp.requestEnvelope(subject, env, timeoutMs)

# low-level registration: the handler needs the raw args (__session)
let ctxSchema = toolSchema(
  %*{"msg": {"type": "string", "description": "Ignored marker"}},
  description = "Test tool gated on a live session; probes the nested-call proxy.")
ctxSchema["x-harness"] = %*{"sessionContext": true}
discard comp.tool("ctxecho", ctxSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let sess = toolArgs{"__session"}{"session"}.getStr("")
    let lease = toolArgs{"__session"}{"lease"}.getStr("")
    if sess.len == 0 or lease.len == 0:
      return %*{"error": "no session context injected"}
    let subject = "svc.session." & sess & ".tool"
    # 1. valid lease -> dispatch reaches the bash component and returns
    let good = nestedCall(subject, "bash", %*{"command": "echo nested-ok"},
                          lease, 30_000)
    # 2. bogus lease -> denied before dispatch
    let bad = nestedCall(subject, "bash", %*{"command": "echo nope"},
                         "bogus-lease", 10_000)
    # 3. hidden core tool (session is x-harness.hidden) -> denied by admission
    let hidden = nestedCall(subject, "session",
                            %*{"sessionId": sess, "content": "nope"},
                            lease, 10_000)
    return %*{
      "goodKind": $good.kind,
      "goodOutput": good.args{"output"}.getStr(""),
      "badCode": bad.error{"code"}.getStr(""),
      "hiddenCode": hidden.error{"code"}.getStr(""),
    })

comp.run()
