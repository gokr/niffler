## Nested-call proxy tests (fabric Phase 0, docs/research/FABRIC.md).
##
## Boots a sandbox core (store + bash, no LLM) plus a test-only component
## (components/ctxtest) whose stub `chat` drives one real session turn.
## Inside that turn a sessionContext-flagged tool exercises the nested-call
## proxy end to end: live-lease call through to bash, bogus-lease denial,
## hidden-tool denial. Also verifies: session_prepare returns a live runner
## subject, and a sessionContext tool fails closed when no turn is running.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing binaries — run `make build` first")
    quit(1)
  let sandbox = newCoreSandbox("nested", ["store", "bash"])
  let root = sandbox.root
  let coreBin = sandbox.sandboxBin("niffler")
  defer: removeDir(root)

  # compile the test-only component into the sandbox
  let ctxBin = sandbox.sandboxBin("ctxtest")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & ctxBin,
    repoRoot / "components" / "ctxtest" / "main.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("ctxtest component failed to compile")
    quit(1)
  let sinkBin = sandbox.sandboxBin("ctxsink")
  let sinkCompile = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & sinkBin,
    repoRoot / "components" / "ctxtest" / "sink.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: sinkCompile.close()
  if waitForExit(sinkCompile, 120_000) != 0:
    fail("ctxsink component failed to compile")
    quit(1)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var eventSub: ptr natsSubscription
  let eventSt = natsConnection_SubscribeSync(addr eventSub, nc.conn,
                                              "ev.session.toolcall".cstring)
  doAssert checkStatus(eventSt)
  defer: natsSubscription_Destroy(eventSub)

  var coreProc = startComponent(coreBin, url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")])
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

  # start the test component and wait for registration
  let ctxProc = startComponent(ctxBin, url, root = root)
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitRegistered(nc, "ctxtest"))
  let sinkProc = startComponent(sinkBin, url, root = root)
  defer:
    if sinkProc.running():
      sinkProc.terminate()
      sleep(800)
      if sinkProc.running(): sinkProc.kill()
    sinkProc.close()
  check("ctxsink registered", waitRegistered(nc, "ctxsink"))

  # --- session_prepare: delegated child-runner preparation -----------------
  let sessionId = "nested-test"
  let prep = call(nc, "core", "session_prepare",
                  %*{"sessionId": sessionId}, 30_000)
  check("session_prepare returns subject",
        prep{"subject"}.getStr("") == "svc.session." & sessionId & ".call",
        $prep)
  # the runner registered during session_prepare (reg.publish already in the
  # past) — probe its subject directly: empty content is a status query
  var runnerUp = false
  var lastStatus = ""
  for i in 0 ..< 50:
    let st = call(nc, "session." & sessionId, "session",
                  %*{"sessionId": sessionId, "model": ""}, 3_000)
    lastStatus = $st
    if st{"error"} == nil:
      runnerUp = true
      break
    sleep(200)
  check("runner registered", runnerUp, lastStatus)

  # --- one live turn driven by the stub chat -------------------------------
  # ctxecho runs inside the turn with a live lease and reports the three
  # nested-call probes in its result; the stub chat finishes the turn.
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sessionId, "content": "go"}, 120_000)
  check("turn completed",
        turn{"reply"}.getStr("") == "nested-turn-done", $turn)

  # fetch the ctxecho evidence from the persisted transcript: message 3 is
  # the tool result (1: user, 2: assistant tool_calls, 3: tool result).
  var transcript = ""
  for i in 1 .. 6:
    let m = call(nc, "store", "get",
                 %*{"kind": "message",
                    "id": sessionId & ":" & align($i, 6, '0')}, 10_000)
    if m{"error"} != nil: break
    transcript.add($m)
  check("nested call with live lease reached bash",
        transcript.contains("nested-ok"), transcript)
  check("bogus lease denied",
        transcript.contains("bad-lease"), transcript)
  check("hidden tool denied at proxy",
        transcript.contains("denied"), transcript)
  check("chat rejected by name at proxy",
        transcript.contains("chatCode\\\":\\\"denied"), transcript)
  check("invoke rejected by name at proxy",
        transcript.contains("invokeCode\\\":\\\"denied"), transcript)
  check("missing required arg rejected at proxy",
        transcript.contains("badArgsCode\\\":\\\"bad-args") and
        transcript.contains("command"), transcript)
  check("nested target did not receive private session context",
        transcript.contains("targetSawSession\\\":false"), transcript)

  var publicArgsClean = false
  for i in 0 ..< 10:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, eventSub, 300)
    if st != NATS_OK: break
    let event = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if event{"payload"}{"tool"}.getStr("") == "ctxecho":
      publicArgsClean = event{"payload"}{"args"}{"__session"} == nil
  check("session event did not expose private session context", publicArgsClean)

  # --- fail closed: sessionContext tool without a live turn ----------------
  # Direct call (no dispatch, no injection): the proxy sees no live lease.
  let direct = call(nc, "ctxtest", "ctxecho", %*{"msg": "x"}, 15_000)
  check("direct call without turn returns tool result (probe-level denial)",
        direct{"error"} != nil or direct{"goodCode"}.getStr("") == "" or
        direct{"goodCode"}.getStr("no-session") == "no-session", $direct)

  report("nested")

main()
