## SDK smoke test — proves the bus end-to-end without an LLM.
##
## Spawns a NATS server, starts the bash component, waits for its
## registration, calls svc.bash.call with a call envelope, checks the reply.

import std/[json, net, os, osproc, strtabs, strutils]
import natswrapper
import envelope
import niffler/sdk

proc main() =
  # init the NATS library (SDK does this in newComponent)
  let initSt = nats_Open(-1)
  if not checkStatus(initSt):
    echo "FAIL: nats_Open: " & getErrorString(initSt)
    quit(1)

  # spawn NATS on a free port
  var s = newSocket()
  s.bindAddr(Port(0))
  let port = int(s.getLocalAddr()[1])
  s.close()
  let natsUrl = "nats://127.0.0.1:" & $port
  let server = startProcess("nats-server", args = ["-p", $port],
                            options = {poUsePath})

  var nc: NatsConnection
  var connected = false
  for i in 0 ..< 40:
    try:
      nc = connect(natsUrl)
      connected = true
      break
    except CatchableError:
      sleep(100)
  if not connected:
    echo "FAIL: cannot connect to " & natsUrl
    quit(1)

  # start the bash component
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bashBin = root / "var" / "bin" / "bash"
  if not fileExists(bashBin):
    echo "FAIL: " & bashBin & " missing — run `nimble build` first"
    quit(1)
  var env = newStringTable(modeCaseSensitive)
  env["NIF_ROOT"] = root
  env["NATS_URL"] = natsUrl
  let bashProc = startProcess(bashBin, workingDir = root, env = env,
                              options = {poUsePath})

  # wait for registration on reg.publish
  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, "reg.publish".cstring)
  if not checkStatus(st):
    echo "FAIL: subscribe: " & getErrorString(st)
    quit(1)
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
    quit(1)
  natsSubscription_Destroy(sub)

  # call svc.bash.call with a call envelope
  let callEnv = callEnvelope("bash", %*{"command": "echo hello-from-bash; ls /nonexistent; echo done", "timeoutMs": 10000})
  let data = callEnv.encode()
  var reply: ptr natsMsg
  let r = natsConnection_Request(addr reply, nc.conn, "svc.bash.call".cstring,
                                 data.cstring, data.len.cint, 15000 * 1_000_000)
  if r != NATS_OK:
    echo "FAIL: request: " & getErrorString(r)
    quit(1)
  let resp = decode($natsMsg_GetData(reply))
  natsMsg_Destroy(reply)
  if resp.kind != ekResult:
    echo "FAIL: expected result, got " & $resp.kind & ": " & $resp
    quit(1)
  let exitCode = resp.args{"exit_code"}.getInt(-1)
  let output = resp.args{"output"}.getStr("")
  # last command in the chain is `echo done`, so exit code is 0
  if exitCode != 0 or not output.contains("hello-from-bash") or not output.contains("No such file") or not output.contains("done"):
    echo "FAIL: unexpected result: " & $resp.args
    quit(1)
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
  echo if stillRunning: "WARN: bash ignored drain (killed)" else: "OK: bash drained and exited"

  # --- store round trip (barrel-backed document store) -----------------
  let storeBin = root / "var" / "bin" / "store"
  if not fileExists(storeBin):
    echo "FAIL: " & storeBin & " missing — run `nimble all` first"
    quit(1)
  var storeEnv = newStringTable(modeCaseSensitive)
  storeEnv["NIF_ROOT"] = root
  storeEnv["NATS_URL"] = natsUrl
  let storeProc = startProcess(storeBin, workingDir = root, env = storeEnv,
                               options = {poUsePath})
  var storeUp = false
  for i in 0 ..< 100:
    sleep(100)
    # probe: put a test doc
    var msg: ptr natsMsg
    let putEnv = callEnvelope("put", %*{"kind": "test", "id": "doc1",
                                       "value": %*{"hello": "world"}})
    let data2 = putEnv.encode()
    let r2 = natsConnection_Request(addr msg, nc.conn, "svc.store.call".cstring,
                                    data2.cstring, data2.len.cint, 5000 * 1_000_000)
    if r2 == NATS_OK:
      let resp2 = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if resp2.kind == ekResult:
        storeUp = true
        if not resp2.args{"ok"}.getBool(false):
          echo "FAIL: store put: " & $resp2.args
          quit(1)
        echo "OK: store put rev=" & $resp2.args{"rev"}.getInt(-1)
        break
  if not storeUp:
    echo "FAIL: store never came up"
    quit(1)

  proc storeCall(tool: string, args: JsonNode): JsonNode =
    var msg: ptr natsMsg
    let env = callEnvelope(tool, args)
    let data = env.encode()
    let r = natsConnection_Request(addr msg, nc.conn, "svc.store.call".cstring,
                                   data.cstring, data.len.cint, 5000 * 1_000_000)
    if r != NATS_OK:
      echo "FAIL: store " & tool & ": " & getErrorString(r)
      quit(1)
    result = decode($natsMsg_GetData(msg)).args
    natsMsg_Destroy(msg)

  let got = storeCall("get", %*{"kind": "test", "id": "doc1"})
  if not got{"ok"}.getBool(false) or got{"value"}{"hello"}.getStr("") != "world":
    echo "FAIL: store get: " & $got
    quit(1)
  echo "OK: store get " & $got{"value"}

  let listed = storeCall("list", %*{"kind": "test"})
  if not listed{"ok"}.getBool(false) or listed{"items"}.len != 1:
    echo "FAIL: store list: " & $listed
    quit(1)
  echo "OK: store list found " & $listed{"items"}.len & " doc"

  let updated = storeCall("put", %*{"kind": "test", "id": "doc1",
                                    "value": %*{"hello": "niffler"},
                                    "expectRev": got{"rev"}.getInt(0)})
  if not updated{"ok"}.getBool(false):
    echo "FAIL: store put expectRev: " & $updated
    quit(1)
  echo "OK: store put expectRev -> rev " & $updated{"rev"}.getInt(-1)

  let conflict = storeCall("put", %*{"kind": "test", "id": "doc1",
                                      "value": %*{"hello": "clobber"},
                                      "expectRev": 99})
  if conflict{"ok"}.getBool(false) or conflict{"code"}.getStr("") != "rev-conflict":
    echo "FAIL: store expectRev conflict: " & $conflict
    quit(1)
  echo "OK: store rev conflict detected"

  discard storeCall("del", %*{"kind": "test", "id": "doc1"})
  let gone = storeCall("get", %*{"kind": "test", "id": "doc1"})
  if gone{"ok"}.getBool(false) or gone{"code"}.getStr("") != "not-found":
    echo "FAIL: store del: " & $gone
    quit(1)
  echo "OK: store del -> not-found"

  nc.publish("ev.sys.drain", drainEnv.encode())
  sleep(500)
  storeProc.close()

  server.terminate()
  server.close()
  nc.close()
  echo "SMOKE TEST PASSED"

main()
