## Hermetic native relay tests; no VM, SSH, NATS or remote mutations.
import std/[net, nativesockets, os, osproc, streams, strutils]
import std/posix
import ../components/cli/relay

proc require(ok: bool, label: string) =
  doAssert ok, label
  echo "OK: ", label

proc main() =
  # A broken pump must fail boundedly rather than hang the server test pool.
  discard alarm(30)
  defer: discard alarm(0)
  let cli = getEnv("NIF_REPO_ROOT", getCurrentDir()) / "var/bin/cli"
  for text in ["", "0", "65536", "-1", "1;id", "localhost:4222", "nats://127.0.0.1:4222", " 42", "+42"]:
    var refused = false
    try: discard relayPort(text)
    except ValueError: refused = true
    require(refused, "port refuses " & text)
  require(relayPort("65535") == Port(65535), "largest valid port")
  for args in [@["relay"], @["relay", "--help"], @["relay", "4222", "extra"]]:
    let p = startProcess(cli, args = args, options = {})
    require(p.waitForExit(2000) != 0, "bad relay args fail")
    require(p.outputStream.readAll() == "", "usage never contaminates stdout")
    require(p.errorStream.readAll().contains("cli relay:"), "stderr diagnosis")
    p.close()

  let listener = net.newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let port = listener.getLocalAddr()[1]
  let payload = "\x00\xff\r\n".repeat(100_000)
  let response = "\xff\x00reply\n".repeat(100_000)
  let server = fork()
  if server == 0:
    var peer: Socket
    listener.accept(peer)
    var received = ""
    while true:
      let chunk = peer.recv(65536)
      if chunk.len == 0: break
      received.add(chunk)
    if received != payload: quit(2)
    peer.send(response)
    peer.close()
    quit(0)
  let p = startProcess(cli, args = ["relay", $port], options = {})
  p.inputStream.write(payload)
  p.inputStream.flush()
  p.inputStream.close()
  require(p.outputStream.readAll() == response, "large binary payload, backpressure and TCP half-close")
  require(p.waitForExit(3000) == 0, "relay exits on peer EOF")
  require(p.errorStream.readAll() == "", "success has no diagnostics")
  p.close()
  var status: cint
  discard waitpid(server, status, 0)
  require(status == 0, "peer received complete binary upload before half-close")

  # A server closing first must terminate the lane while stdin stays open.
  let closing = startProcess(cli, args = ["relay", $port], options = {})
  var peer: Socket
  listener.accept(peer)
  peer.send("bye\x00")
  peer.close()
  require(closing.waitForExit(3000) == 0, "peer close with stdin open is bounded")
  require(closing.outputStream.readAll() == "bye\x00", "peer tail is drained")
  closing.close()

  let cancelled = startProcess(cli, args = ["relay", $port], options = {})
  listener.accept(peer)
  cancelled.terminate()
  require(cancelled.waitForExit(3000) != 0, "cancellation terminates relay")
  require(peer.recv(1) == "", "cancellation closes socket")
  peer.close()
  cancelled.close()
  listener.close()

  let refused = startProcess(cli, args = ["relay", $port], options = {})
  require(refused.waitForExit(3000) != 0, "connection failure refuses without fallback")
  require(refused.outputStream.readAll() == "", "connection error keeps stdout clean")
  refused.close()
  echo "RELAY TEST PASSED"

main()
