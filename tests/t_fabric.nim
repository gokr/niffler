## fabric component tests (fabric Phase 2, docs/FABRIC.md).
##
## Boots a sandbox core (store + bash, no LLM) with the stub component
## (components/ctxtest) and the fabric component. Drives one session turn
## whose stub LLM issues three fabric calls: a happy-path program (guest
## calls bash through the bridge, logs, finishes with one value), a
## compile-error program (real Nim diagnostics returned), and a budget
## program (infinite call loop dies at maxCalls). Asserts the results from
## the persisted transcript and the ev.fabric.log activity stream.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "fabric", "fabric-exec"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("fabric", ["store", "bash"])
  let root = sandbox.root
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric",
                          sandbox.sandboxBin("fabric"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric-exec",
                          sandbox.sandboxBin("fabric-exec"))
    # NOTE: fabric-exec bakes the worktree's fabricguest path at compile
    # time — the test runs from the same worktree, so it resolves

  let ctxBin = sandbox.sandboxBin("ctxtest")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & ctxBin,
    repoRoot / "components" / "ctxtest" / "main.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 180_000) != 0:
    fail("ctxtest component failed to compile")
    quit(1)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")],
                                logFile = "/tmp/opencode/core-fab.log")
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

  # capture the activity stream: the guest's logg() must surface as
  # ev.fabric.log events while the turn runs
  var logSub: ptr natsSubscription
  let logSt = natsConnection_SubscribeSync(addr logSub, nc.conn,
                                           "ev.fabric.log".cstring)
  doAssert checkStatus(logSt)
  var logLines = 0

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = "/tmp/opencode/ctxtest-fab.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let fabProc = startComponent(sandbox.sandboxBin("fabric"), url, root = root,
                               logFile = "/tmp/opencode/fabric.log")
  defer:
    if fabProc.running():
      fabProc.terminate()
      sleep(800)
      if fabProc.running(): fabProc.kill()
    fabProc.close()
  check("fabric registered", waitComponent(nc, "fabric"))

  let sessionId = "fab-test"
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sessionId, "content": "go"}, 300_000)
  check("turn completed",
        turn{"reply"}.getStr("") == "fabric-turn-done", $turn)

  # count ev.fabric.log events delivered while the turn ran
  for i in 0 ..< 10:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, logSub, 300)
    if st != NATS_OK: break
    natsMsg_Destroy(msg)
    inc logLines
  check("guest logg() surfaced as ev.fabric.log", logLines >= 1)

  # the three fabric results live in the persisted transcript: user(1),
  # assistant(2), tool(3), assistant(4), tool(5), assistant(6), tool(7)
  var transcript = ""
  for i in 1 .. 12:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": sessionId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    transcript.add(m{"value"}{"content"}.getStr(""))

  check("guest bash call through the bridge succeeded",
        transcript.contains("fabric-ok"), transcript)
  check("compile error returned real diagnostics",
        transcript.contains("diagnostics") and
        transcript.contains("Error"), transcript)
  check("maxCalls budget enforced",
        transcript.contains("maxCalls budget exceeded"), transcript)

  report("fabric")

main()
