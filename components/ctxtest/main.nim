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

comp.tool(%*{"hidden": true}):
  proc chat(messages: JsonNode = nil, tools: JsonNode = nil,
            sessionId: string = "", stream: bool = false): JsonNode =
    ## Stub LLM surface for the session runner. Scripted per session kind:
    ## - agent-* sessions (real subagent children): depth-guard attempt,
    ##   then bash work, then final reply.
    ## - "agt-parent": agent_run tool call, then final reply.
    ## - "sp-*": echo the conversation's system message (messages[0]) as the
    ##   final reply — t_systemprompt asserts on what the LLM actually saw.
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
        # Happy path plus framing regression: several adjacent log frames must
        # survive when one pipe read receives them together with the result.
        let prog = "import fabricguest\n" &
          "let r = callTool(\"bash\", jobj(jpair(\"command\", jesc(\"echo fabric-ok\"))))\n" &
          "logg(\"ran bash 1\")\n" &
          "logg(\"ran bash 2\")\n" &
          "logg(\"ran bash 3\")\n" &
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
        # Hybrid plus lease restoration: after the nested session-context
        # agent_run returns, the outer Fabric lease must still admit calls.
        let prog = "import fabricguest\n" &
          "let a = callTool(\"agent_run\", jobj(jpair(\"task\", jesc(\"echo agent-ok and report\"))))\n" &
          "let b = callTool(\"bash\", jobj(jpair(\"command\", jesc(\"echo lease-restored\"))))\n" &
          "finish(jobj(jpair(\"agent\", jesc(a)), jpair(\"after\", jesc(b))))\n"
        return toolCall("t4", "fabric", %*{"code": prog})
      of 4:
        # Forced termination path: the parent must reap and close the guest.
        let loop = "import fabricguest\nvar i = 0\nwhile true:\n  inc i\n"
        return toolCall("t5", "fabric", %*{"code": loop, "timeoutMs": 100})
      of 5:
        # Malformed bridge arguments must be rejected, never changed to {}.
        let malformed = "import fabricguest\n" &
          "discard callTool(\"bash\", \"{\")\n" &
          "finish(\"{}\")\n"
        return toolCall("t6", "fabric", %*{"code": malformed})
      of 6:
        let tiny = "import fabricguest\nfinish(\"{}\")\n"
        return toolCall("t7", "fabric", %*{"code": tiny, "maxCalls": 0})
      of 7:
        let tiny = "import fabricguest\nfinish(\"{}\")\n"
        return toolCall("t8", "fabric",
                        %*{"code": tiny, "timeoutMs": 300_001})
      of 8:
        let large = "import fabricguest\n" &
          "var s = \"\"\n" &
          "for i in 0 ..< 60000:\n  s.add(\"x\")\n" &
          "finish(jesc(s))\n"
        return toolCall("t9", "fabric", %*{"code": large})
      else:
        return %*{"content": "fabric-turn-done"}
    if sessionId.startsWith("sp-"):
      # every turn: echo the conversation's system message (messages[0])
      # so the test asserts on what the LLM actually saw, on turn 1 AND on
      # a resumed turn after the runner died
      var sys = ""
      if messages != nil:
        for m in messages:
          if m{"role"}.getStr("") == "system":
            sys = m{"content"}.getStr("")
            break
      return %*{"content": "sys-echo<<<" & sys & ">>>end"}
    if stage == 0:
      return toolCall("t1", "ctxecho", %*{"msg": "hi"})
    return %*{"content": "nested-turn-done"}
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
    # 6. valid call context is stripped before the target sees its arguments
    let inspect = nestedCall(subject, "ctxinspect", %*{"value": "clean"},
                             lease, 10_000)
    return %*{
      "goodKind": $good.kind,
      "goodOutput": good.args{"output"}.getStr(""),
      "badCode": bad.error{"code"}.getStr(""),
      "hiddenCode": hidden.error{"code"}.getStr(""),
      "chatCode": chatDeny.error{"code"}.getStr(""),
      "invokeCode": invokeDeny.error{"code"}.getStr(""),
      "badArgsCode": badArgs.error{"code"}.getStr(""),
      "badArgsMsg": badArgs.error{"message"}.getStr(""),
      "targetSawSession": inspect.args{"sawSession"}.getBool(true),
    })

comp.run()
