## SDK smoke test — proves the bus end-to-end without an LLM.
##
## Spawns a NATS server, starts the bash component, waits for its
## registration, calls svc.bash.call with a call envelope, checks the reply.

import std/[json, os, osproc, strutils]
import natswrapper
import envelope
import helpers

proc main() =
  # init the NATS library (SDK does this in newComponent)
  let initSt = nats_Open(-1)
  if not checkStatus(initSt):
    echo "FAIL: nats_Open: " & getErrorString(initSt)
    raise newException(AssertionDefect, "smoke test failed")

  let (server, natsUrl) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(natsUrl)
  defer: nc.close()

  # start the bash component
  let root = getEnv("NIF_REPO_ROOT",
                    getEnv("NIF_ROOT", getAppDir().parentDir()))
  let bashBin = root / "var" / "bin" / "bash"
  if not fileExists(bashBin):
    echo "FAIL: " & bashBin & " missing — run `nimble build` first"
    raise newException(AssertionDefect, "smoke test failed")
  let runtimeRoot = tempRoot("smoke")
  defer: removeDir(runtimeRoot)
  var bashProc = startComponent(bashBin, natsUrl, root = runtimeRoot)
  defer:
    if bashProc != nil and bashProc.running(): bashProc.terminate()
    if bashProc != nil: bashProc.close()

  # wait for registration on reg.publish
  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, "reg.publish".cstring)
  if not checkStatus(st):
    echo "FAIL: subscribe: " & getErrorString(st)
    raise newException(AssertionDefect, "smoke test failed")
  var registered = false
  for i in 0 ..< 100:
    var msg: ptr natsMsg
    let r = natsSubscription_NextMsg(addr msg, sub, 100)
    if r == NATS_OK:
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      if data.contains("bash"):
        registered = true
        echo "OK: bash registered"
        break
  if not registered:
    echo "FAIL: bash never registered"
    raise newException(AssertionDefect, "smoke test failed")
  natsSubscription_Destroy(sub)

  # call svc.bash.call with a call envelope
  let callEnv = callEnvelope("bash", %*{"command": "echo hello-from-bash; ls /nonexistent; echo done", "timeoutMs": 10000})
  let data = callEnv.encode()
  var reply: ptr natsMsg
  let r = natsConnection_Request(addr reply, nc.conn, "svc.bash.call".cstring,
                                 data.cstring, data.len.cint, 15000)
  if r != NATS_OK:
    echo "FAIL: request: " & getErrorString(r)
    raise newException(AssertionDefect, "smoke test failed")
  let resp = decode($natsMsg_GetData(reply))
  natsMsg_Destroy(reply)
  if resp.kind != ekResult:
    echo "FAIL: expected result, got " & $resp.kind & ": " & $resp
    raise newException(AssertionDefect, "smoke test failed")
  let exitCode = resp.args{"exit_code"}.getInt(-1)
  let output = resp.args{"text"}.getStr("")
  # last command in the chain is `echo done`, so exit code is 0
  if exitCode != 0 or not output.contains("hello-from-bash") or not output.contains("No such file") or not output.contains("done"):
    echo "FAIL: unexpected result: " & $resp.args
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: bash tool result: exit_code=" & $exitCode & " output=" & output.replace("\n", " | ")

  # graceful shutdown of the component
  let drainEnv = Envelope(v: 1, id: newId(), kind: ekEvent, payload: newJObject())
  nc.publish("ev.sys.drain", drainEnv.encode())
  sleep(500)
  let stillRunning = bashProc.running()
  if stillRunning:
    bashProc.terminate()
    sleep(200)
  bashProc.close()
  bashProc = nil
  echo if stillRunning: "WARN: bash ignored drain (killed)" else: "OK: bash drained and exited"

  # --- store round trip (barrel-backed document store) -----------------
  let storeBin = root / "var" / "bin" / "store"
  if not fileExists(storeBin):
    echo "FAIL: " & storeBin & " missing — run `nimble all` first"
    raise newException(AssertionDefect, "smoke test failed")
  var storeProc = startComponent(storeBin, natsUrl, root = runtimeRoot)
  defer:
    if storeProc != nil and storeProc.running(): storeProc.terminate()
    if storeProc != nil: storeProc.close()
  var storeUp = false
  for i in 0 ..< 100:
    sleep(100)
    # probe: put a test doc
    var msg: ptr natsMsg
    let putEnv = callEnvelope("put", %*{"kind": "test", "id": "doc1",
                                       "value": %*{"hello": "world"}})
    let data2 = putEnv.encode()
    let r2 = natsConnection_Request(addr msg, nc.conn, "svc.store.call".cstring,
                                    data2.cstring, data2.len.cint, 5000)
    if r2 == NATS_OK:
      let resp2 = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if resp2.kind == ekResult:
        storeUp = true
        if not resp2.args{"ok"}.getBool(false):
          echo "FAIL: store put: " & $resp2.args
          raise newException(AssertionDefect, "smoke test failed")
        echo "OK: store put rev=" & $resp2.args{"rev"}.getInt(-1)
        break
  if not storeUp:
    echo "FAIL: store never came up"
    raise newException(AssertionDefect, "smoke test failed")

  proc storeCall(tool: string, args: JsonNode): JsonNode =
    var msg: ptr natsMsg
    let env = callEnvelope(tool, args)
    let data = env.encode()
    let r = natsConnection_Request(addr msg, nc.conn, "svc.store.call".cstring,
                                   data.cstring, data.len.cint, 5000)
    if r != NATS_OK:
      echo "FAIL: store " & tool & ": " & getErrorString(r)
      raise newException(AssertionDefect, "smoke test failed")
    result = decode($natsMsg_GetData(msg)).args
    natsMsg_Destroy(msg)

  let got = storeCall("get", %*{"kind": "test", "id": "doc1"})
  if not got{"ok"}.getBool(false) or got{"value"}{"hello"}.getStr("") != "world":
    echo "FAIL: store get: " & $got
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: store get " & $got{"value"}

  let listed = storeCall("list", %*{"kind": "test"})
  if not listed{"ok"}.getBool(false) or listed{"items"}.len != 1:
    echo "FAIL: store list: " & $listed
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: store list found " & $listed{"items"}.len & " doc"

  let updated = storeCall("put", %*{"kind": "test", "id": "doc1",
                                    "value": %*{"hello": "niffler"},
                                    "expectRev": got{"rev"}.getInt(0)})
  if not updated{"ok"}.getBool(false):
    echo "FAIL: store put expectRev: " & $updated
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: store put expectRev -> rev " & $updated{"rev"}.getInt(-1)

  let conflict = storeCall("put", %*{"kind": "test", "id": "doc1",
                                      "value": %*{"hello": "clobber"},
                                      "expectRev": 99})
  if conflict{"ok"}.getBool(false) or conflict{"code"}.getStr("") != "rev-conflict":
    echo "FAIL: store expectRev conflict: " & $conflict
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: store rev conflict detected"

  discard storeCall("del", %*{"kind": "test", "id": "doc1"})
  let gone = storeCall("get", %*{"kind": "test", "id": "doc1"})
  if gone{"ok"}.getBool(false) or gone{"code"}.getStr("") != "not-found":
    echo "FAIL: store del: " & $gone
    raise newException(AssertionDefect, "smoke test failed")
  echo "OK: store del -> not-found"

  nc.publish("ev.sys.drain", drainEnv.encode())
  sleep(500)
  if storeProc.running():
    storeProc.terminate()
    sleep(200)
  storeProc.close()
  storeProc = nil

  echo "SMOKE TEST PASSED"

main()
