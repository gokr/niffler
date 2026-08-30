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

import std/[json, strutils, tables]
import natswrapper
import niffler/sdk

let comp = newComponent("ctxtest", "0.1.0")

var chatStage = initTable[string, int]()
  ## sessionId -> chat calls served (single-threaded SDK poll loop)

proc toolCall(id, name: string, args: JsonNode): JsonNode =
  ## One assistant tool-call turn for the stub LLM.
  %*{"content": "",
     "tool_calls": %*[{"id": id, "type": "function",
                       "function": {"name": name,
                                    "arguments": $args}}]}

comp.tool:
  proc chat(messages: JsonNode = nil, tools: JsonNode = nil,
            sessionId: string = "", stream: bool = false): JsonNode =
    ## Stub LLM surface for the session runner. Scripted per session kind:
    ## - agent-* sessions (real subagent children): depth-guard attempt,
    ##   then bash work, then final reply.
    ## - "agt-parent": agent_run tool call, then final reply.
    ## - anything else (t_nested): ctxecho probe, then final reply.
    let stage = chatStage.mgetOrPut(sessionId, 0)
    chatStage[sessionId] = stage + 1
    if sessionId.startsWith("agent-"):
      case stage
      of 0: return toolCall("t1", "agent_run", %*{"task": "try to spawn"})
      of 1: return toolCall("t2", "bash", %*{"command": "echo agent-ok"})
      else: return %*{"content": "subagent-done"}
    if sessionId == "agt-parent":
      if stage == 0:
        return toolCall("t1", "agent_run",
                        %*{"task": "echo agent-ok via a subagent"})
      return %*{"content": "agent-turn-done"}
    if sessionId == "si-live":
      if stage == 0:
        # current-session introspection: no sessionId arg — the runner must
        # inject its own id (t_core asserts the tool result carries it)
        return toolCall("t1", "session_info", %*{})
      return %*{"content": "introspect-done"}
    if sessionId == "fab-test":
      case stage
      of 0:
        # happy path: guest calls bash through the bridge, finishes with one value
        let prog = "import fabricguest\n" &
          "let r = callTool(\"bash\", jobj(jpair(\"command\", jesc(\"echo fabric-ok\"))))\n" &
          "logg(\"ran bash\")\n" &
          "finish(jobj(jpair(\"bashResult\", jesc(r))))\n"
        return toolCall("t1", "fabric", %*{"code": prog})
      of 1:
        # compile-error path: real Nim diagnostics come back
        let bad = "import fabricguest\nfinish(jobj(jpair(\"x\" jnum(1))))\n"
        return toolCall("t2", "fabric", %*{"code": bad})
      of 2:
        # budget path: an infinite call loop must die at maxCalls
        let loop = "import fabricguest\n" &
          "var i = 0\n" &
          "while true:\n" &
          "  inc i\n" &
          "  discard callTool(\"bash\", jobj(jpair(\"command\", jesc(\"echo x\"))))\n"
        return toolCall("t3", "fabric", %*{"code": loop, "maxCalls": 5})
      of 3:
        # hybrid: the program delegates a judgment task to a subagent; the
        # subagent's own spawn attempt is denied at dispatch (noSpawn)
        let prog = "import fabricguest\n" &
          "let a = callTool(\"agent_run\", jobj(jpair(\"task\", jesc(\"echo agent-ok and report\"))))\n" &
          "finish(jobj(jpair(\"agent\", jesc(a))))\n"
        return toolCall("t4", "fabric", %*{"code": prog})
      else:
        return %*{"content": "fabric-turn-done"}
    if stage == 0:
      return toolCall("t1", "ctxecho", %*{"msg": "hi"})
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
    # 4. name-based rejection: chat and invoke are internal surfaces
    let chatDeny = nestedCall(subject, "chat", %*{"sessionId": sess}, lease, 10_000)
    let invokeDeny = nestedCall(subject, "invoke",
                            %*{"tool": "bash", "arguments": {}}, lease, 10_000)
    # 5. required-args validation: bash without "command" -> bad-args
    let badArgs = nestedCall(subject, "bash", %*{"timeoutMs": 5}, lease, 10_000)
    return %*{
      "goodKind": $good.kind,
      "goodOutput": good.args{"output"}.getStr(""),
      "badCode": bad.error{"code"}.getStr(""),
      "hiddenCode": hidden.error{"code"}.getStr(""),
      "chatCode": chatDeny.error{"code"}.getStr(""),
      "invokeCode": invokeDeny.error{"code"}.getStr(""),
      "badArgsCode": badArgs.error{"code"}.getStr(""),
      "badArgsMsg": badArgs.error{"message"}.getStr(""),
    })

comp.run()
