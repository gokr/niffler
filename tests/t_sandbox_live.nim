## t_sandbox_live — the milestone seen through a REAL harness, not a fixture.
##
## The unit contracts (t_sandbox_conversation, t_sandbox_propagation,
## t_sandbox_strict, t_bash_guard) each inject `__sandbox` directly or drive
## core with hand-built arguments. None of them proves the thing an operator
## does: boot a harness, start a conversation, turn its policy on with the
## human control, and have an ordinary `bash` tool call come back confined.
##
## This test exists because that gap is not hypothetical. During the slice a
## green suite hid a stale `var/bin/bash` (the Makefile target did not depend on
## guard.nim), so every "session-dispatched bash" check was exercising the
## PREVIOUS guard. Only a run through the assembled harness catches that class.
##
## No model is involved: the turn-starting path is skipped by invoking the
## `session` tool's `invoke` directly, which still goes through the runner's own
## dispatch (the same place the policy is read and injected).

import std/[json, os, osproc, strutils]
import natsnim
import niffler/sdk
import helpers

proc waitRegistered(nc: NatsConnection, name: string, secs = 30): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  return false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "niffler-sandbox", "session"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)

  let sandbox = newCoreSandbox("sandboxlive", ["store", "bash", "systemprompt"])
  let root = sandbox.root
  echo "sandbox root: ", root
  # The launcher lives beside the bash binary; a session-driven launch resolves
  # it from getAppDir(), so it must be in the sandbox too.
  copyFileWithPermissions(repoRoot / "var" / "bin" / "niffler-sandbox",
                          sandbox.sandboxBin("niffler-sandbox"))

  let (server, url, _) = startNatsMonitoring()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "5")],
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
  check("bash registered", waitRegistered(nc, "bash"))

  # The conversation's workspace: a plain directory under the sandbox root, so
  # a host-escape check can point at something genuinely outside it.
  let ws = root / "workspace"
  createDir(ws)
  let hostSide = root / "host-only"
  createDir(hostSide)
  writeFile(hostSide / "secret", "HOST-SECRET-VALUE")
  let conv = "live-sbx-" & $getCurrentProcessId()

  proc invoke(tool: string, args: JsonNode, timeoutMs = 60_000): JsonNode =
    ## A tool call dispatched by the conversation's OWN runner process — the
    ## path the model takes, minus the model. Goes through svc.core.call, which
    ## forwards to the conversation's runner, exactly as a client does.
    let data = callEnvelope("session",
      %*{"sessionId": conv, "cwd": ws,
         "invoke": {"tool": tool, "arguments": args}}, "live").encode()
    var msg: ptr natsMsg
    let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call",
                                    data.cstring, data.len.cint,
                                    timeoutMs.int64)
    if not checkStatus(st): return %*{"error": "nats " & $st}
    let reply = decode($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if reply.kind == ekError:
      return %*{"error": reply.error{"message"}.getStr("component error")}
    reply.args

  # --- 1. before the policy: an ordinary unguarded launch ---------------
  let before = invoke("bash", %*{"command": "echo LIVE-BEFORE"})
  check("a conversation with no policy runs bash normally",
        ($before).contains("LIVE-BEFORE"), $before)
  check("and no sandbox verdict is attached",
        not ($before).contains("\"applied\""), $before)

  # --- 2. the human turns the policy on --------------------------------
  let enabled = call(nc, "core", "session",
    %*{"sessionId": conv, "sandbox": %*{"enabled": true}}, 30_000)
  check("the human control accepted the enable",
        enabled{"error"} == nil and
        enabled{"sandbox"}{"enabled"}.getBool(false), $enabled)
  check("the readback still does not claim confinement for the whole conversation",
        not enabled{"sandbox"}{"enforced"}.getBool(true), $enabled)

  # --- 3. the same call, now confined ----------------------------------
  # .env is the DEFAULT deny: this proves the deny rule is enforced on a launch
  # that still runs, rather than satisfied by refusing to run.
  writeFile(ws / ".env", "LIVE-SECRET=must-not-leak")
  let after = invoke("bash", %*{"command":
    "cat .env 2>/dev/null; echo LIVE-MARK; cat " & quoteShell(hostSide / "secret") &
    " 2>/dev/null; echo END-MARK"})
  let text = $after
  check("the confined call actually ran", text.contains("LIVE-MARK"), text)
  check("the default .env deny is enforced (secret not disclosed)",
        not text.contains("must-not-leak"), text)
  check("a host file outside the workspace is not readable",
        not text.contains("HOST-SECRET-VALUE"), text)
  check("the result reports an applied sandbox",
        text.contains("\"applied\"") and text.contains("\"shell\""), text)
  check("and it reports strict reach, not a weaker one",
        text.contains("\"strict\""), text)

  # --- 4. ordinary workspace work still functions ----------------------
  let work = invoke("bash", %*{"command": "echo WROTE > out.txt && cat out.txt"})
  check("workspace writes still work under the policy",
        ($work).contains("WROTE"), $work)
  check("the file really landed in the workspace", fileExists(ws / "out.txt"))

  # --- 5. the decision survives a fresh runner -------------------------
  # A resumed conversation re-reads its durable policy; a policy that only
  # lived in the runner's memory would quietly lapse here.
  let runnerGone = call(nc, "core", "session",
    %*{"sessionId": conv, "stop": true}, 15_000)
  discard runnerGone
  sleep(3000)
  let resumed = invoke("bash", %*{"command": "cat .env 2>/dev/null; echo RESUMED-MARK"})
  check("a fresh runner still confines the conversation",
        ($resumed).contains("RESUMED-MARK") and
        not ($resumed).contains("must-not-leak") and
        ($resumed).contains("\"applied\""), $resumed)

  report("SANDBOX LIVE")
  removeDir(root)

main()
