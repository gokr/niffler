## Sandbox policy PROPAGATION — stage B contract.
##
## Stage A persisted a human's decision. This stage's only claim is that the
## SAME decision reaches every dispatch path, because a policy one path honors
## and another ignores is the failure mode the whole slice exists to prevent.
##
## Everything here asserts WHAT A COMPONENT RECEIVED, never that it was
## confined: enforcement is stage C, and conflating the two is how "the harness
## sandboxes bash" gets said about code that only ships a JSON document.
##
## Cases:
## - a declaring tool receives the policy, with the conversation's own identity;
## - a non-declaring tool receives NOTHING, even when it asks (opt-in is data);
## - a caller-supplied `__sandbox` is OVERWRITTEN, not merged — an argument the
##   model can write is not a policy;
## - a direct bus call (no conversation) gets no policy at all: it cannot
##   borrow another conversation's reach;
## - a human update is visible to the next dispatch (bounded cache), and a
##   different conversation's policy is never substituted.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "ctxtest"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("sandboxprop", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  copyFileWithPermissions(repoRoot / "var" / "bin" / "ctxtest",
                          sandbox.sandboxBin("ctxtest"))

  let (server, url, _) = startNatsMonitoring()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "2")],
                                logFile = root / "var" / "test-logs" / "core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running(): coreProc.kill()
      sleep(200)
    if coreProc != nil: coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  let ctxProc = startComponent(sandbox.sandboxBin("ctxtest"), url, root = root,
                               logFile = root / "var" / "test-logs" / "ctxtest.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))

  # Calls go through the SESSION tool, which is how the model reaches a
  # component: `invoke` on a live conversation, dispatched by its runner — the
  # same path every tool call takes. `session` with `invoke` is the
  # session-scoped control, so the runner is the dispatcher and stage A's
  # per-conversation policy is what it consults.
  # The phase's point is that the RUNNER's dispatch is what a component sees,
  # and a runner is what carries a conversation's policy — so each call goes
  # through `session {invoke}` (core's own `invoke` tool has no conversation and
  # therefore, correctly, no policy). The result envelope is reshaped here into
  # the same {"result": …} shape the rest of this file asserts on.
  proc invoke(session, tool: string, args: JsonNode, timeoutMs = 30_000): JsonNode =
    let data = callEnvelope("session",
      %*{"sessionId": session,
         "invoke": {"tool": tool, "arguments": args}}, "sbxprop").encode()
    var msg: ptr natsMsg
    let st = natsConnection_Request(addr msg, nc.conn,
                                    "svc.core.call", data.cstring,
                                    data.len.cint, timeoutMs.int64)
    if not checkStatus(st): return %*{"error": "nats " & $st}
    let reply = decode($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if reply.kind == ekError:
      return %*{"error": reply.error{"message"}.getStr("component error")}
    reply.args

  let conv = "sbxprop-a"

  # --- 1. a declaring tool receives the policy --------------------------
  let seen = invoke(conv, "sandbox_probe", %*{})
  check("a declaring tool is dispatched", seen{"error"} == nil, $seen)
  let probe = seen{"result"}
  let sawPolicy = probe != nil and probe.kind == JObject and
                  probe{"present"}.getBool(false)
  check("the declaring tool received a policy", sawPolicy, $seen)
  if sawPolicy and probe{"policy"} != nil and probe{"policy"}.kind == JObject:
    let p = probe{"policy"}
    check("the policy names its conversation", p{"session"}.getStr("") == conv, $p)
    check("the policy carries the workspace root",
          p{"readRoots"} != nil and p{"readRoots"}.len >= 1, $p)
    check("the policy is reported as NOT enforced",
          not p{"enforced"}.getBool(true), $p)
    check("a stored policy is visible as persisted-or-default",
          p{"persisted"} != nil, $p)

  # --- 2. a non-declaring tool receives nothing -------------------------
  # Opt-in is DATA in the schema, so a component that did not ask must not be
  # handed the document — and a smuggled argument must be dropped, not relayed.
  let optedOut = invoke(conv, "sandbox_not_opted_in",
    %*{"__sandbox": {"enabled": true, "readRoots": ["/forged"]}})
  check("a non-declaring tool is dispatched", optedOut{"error"} == nil, $optedOut)
  check("a non-declaring tool receives NO policy",
        optedOut{"result"} == nil or
        not optedOut{"result"}{"present"}.getBool(true), $optedOut)
  var notInKeys: seq[string] = @[]
  if optedOut{"result"}{"keys"} != nil:
    for k in optedOut{"result"}{"keys"}: notInKeys.add k.getStr("")
  check("a smuggled __sandbox never reaches a non-declaring tool",
        "__sandbox" notin notInKeys, $notInKeys)

  # --- 3. a forged policy is overwritten, not merged --------------------
  # The model supplies tool arguments; a policy it can write is decorative.
  let forged = invoke(conv, "sandbox_probe",
    %*{"__sandbox": {"enabled": true, "readRoots": ["/forged"],
                     "session": "someone-else"}})
  check("forged probe dispatched", forged{"error"} == nil, $forged)
  var forgedPolicy: JsonNode = nil
  if forged{"result"} != nil: forgedPolicy = forged{"result"}{"policy"}
  check("the forged session was replaced",
        forgedPolicy != nil and forgedPolicy{"session"}.getStr("") == conv,
        $forged)
  var forgedReads: seq[string] = @[]
  if forgedPolicy != nil and forgedPolicy{"readRoots"} != nil:
    for r in forgedPolicy{"readRoots"}: forgedReads.add r.getStr("")
  check("the forged read root is gone", "/forged" notin forgedReads, $forgedReads)

  # --- 4. a direct bus call has no conversation, so no policy -----------
  # A caller with no session must not be handed any conversation's reach.
  let direct = call(nc, "ctxtest", "sandbox_probe", %*{}, 20_000)
  check("a direct call is dispatched", direct{"error"} == nil, $direct)
  check("a direct call receives NO policy",
        not direct{"present"}.getBool(true), $direct)

  # --- 5. a human update reaches the next dispatch ----------------------
  let approved = root / "prop-approved"
  createDir(approved)
  let edited = call(nc, "core", "session",
    %*{"sessionId": conv, "sandbox": {"enabled": true,
                                      "addWrite": [approved]}}, 20_000)
  check("the human update was accepted", edited{"error"} == nil, $edited)
  # The dispatch cache is bounded (2s), so wait past it rather than assuming
  # the old snapshot is still live — and prove the NEW one arrives.
  sleep(2500)
  let after = invoke(conv, "sandbox_probe", %*{})
  var afterPolicy: JsonNode = nil
  if after{"result"} != nil: afterPolicy = after{"result"}{"policy"}
  var afterWrites: seq[string] = @[]
  if afterPolicy != nil and afterPolicy{"writeRoots"} != nil:
    for r in afterPolicy{"writeRoots"}: afterWrites.add r.getStr("")
  check("the approved write root reaches the component",
        approved in afterWrites, $after)
  check("enablement reaches the component",
        afterPolicy != nil and afterPolicy{"enabled"}.getBool(false), $after)

  # --- 6. another conversation never borrows it -------------------------
  let other = "sbxprop-b"
  let otherSeen = invoke(other, "sandbox_probe", %*{})
  var otherPolicy: JsonNode = nil
  if otherSeen{"result"} != nil: otherPolicy = otherSeen{"result"}{"policy"}
  var otherWrites: seq[string] = @[]
  if otherPolicy != nil and otherPolicy{"writeRoots"} != nil:
    for r in otherPolicy{"writeRoots"}: otherWrites.add r.getStr("")
  check("a second conversation sees its OWN policy",
        otherPolicy != nil and otherPolicy{"session"}.getStr("") == other,
        $otherSeen)
  check("a second conversation does not inherit the first's roots",
        approved notin otherWrites, $otherSeen)
  check("a second conversation stays off",
        otherPolicy != nil and not otherPolicy{"enabled"}.getBool(true),
        $otherSeen)

  report("SANDBOX POLICY PROPAGATION")

main()
