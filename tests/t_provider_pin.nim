## Provider-pin integrity: a conversation never silently changes backend.
##
## The bug this pins: resolving a conversation's PINNED provider can fail
## transiently (the provider registry busy, restarting, or simply absent from a
## --minimal boot). Core used to swallow that failure, leave the provider out of
## the chat call, and let llm resolve its ACTIVE provider instead — so a
## conversation pinned to "synthetic" quietly ran on whatever NIF_OPENAI_*
## pointed at, and the model id it still carried was then rejected there with
## `unknown provider "synthetic" (have: default)` on every turn.
##
## Two guarantees, both proven here end to end:
##   - llm (Go unit tests) never answers a pinned nickname with the environment
##     table when the registry could not answer;
##   - core REFUSES a pinned turn it cannot resolve, instead of running it
##     against a different provider — the fake endpoint must receive nothing.

import std/[json, net, os, osproc, strutils]
import natsnim
import helpers

# --------------------------------------------------------------------------
# a fake OpenAI-compatible endpoint: SSE chat completions, every request's model
# recorded so the test can prove which backend a turn reached.

proc sendAll(peer: Socket, payload: string) =
  var sent = 0
  while sent < payload.len:
    let n = peer.send(unsafeAddr payload[sent], payload.len - sent)
    if n <= 0:
      return
    sent += n

proc serveChat(portFile: string) =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let (_, port) = server.getLocalAddr()
  writeFile(portFile, $port)
  while true:
    var peer: owned(Socket)
    server.accept(peer)
    var head = ""
    var line = ""
    while true:
      peer.readLine(line)
      if line.strip().len == 0: break
      head.add(line & "\n")
    var body = ""
    for raw in head.splitLines():
      let lower = raw.toLowerAscii()
      if lower.startsWith("content-length:"):
        let n = parseInt(raw.split(':')[1].strip())
        body = newString(n)
        var got = 0
        while got < n:
          let chunk = peer.recv(addr body[got], n - got)
          if chunk <= 0: break
          got += chunk
    if head.startsWith("POST") and head.splitLines()[0].contains("/chat/completions"):
      try:
        writeFile(portFile & ".log",
                  (if fileExists(portFile & ".log"): readFile(portFile & ".log") else: "") &
                  $parseJson(body){"model"} & "\n")
      except CatchableError:
        discard
      let chunk = """{"id":"c1","object":"chat.completion.chunk","created":1,"model":"fake","choices":[{"index":0,"delta":{"role":"assistant","content":"fake-ok"},"finish_reason":null}]}"""
      let stop = """{"id":"c1","object":"chat.completion.chunk","created":1,"model":"fake","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"""
      sendAll(peer, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
        "Connection: close\r\n\r\n" &
        "data: " & chunk & "\n\ndata: " & stop & "\n\ndata: [DONE]\n\n")
    else:
      sendAll(peer, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
        "Connection: close\r\n\r\n")
    peer.close()

proc main() =
  if paramCount() == 2 and paramStr(1) == "serve":
    serveChat(paramStr(2))
    return

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  # NO provider component: this is both a --minimal boot and the shape of a
  # registry outage — llm cannot answer for any stored nickname.
  let sandbox = newCoreSandbox("provider-pin", ["store", "models", "llm"])
  let portFile = sandbox.root / "fake-port"
  let chat = startProcess(getAppFilename(), args = @["serve", portFile])
  defer:
    if chat.running(): chat.terminate()
    chat.close()
  for _ in 0 ..< 100:
    if fileExists(portFile): break
    sleep(30)
  check("fake chat endpoint up", fileExists(portFile))
  let baseURL = "http://127.0.0.1:" & readFile(portFile) & "/v1"

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = sandbox.root, extra = [
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MODELS_OFFLINE", "1"),
    ("NIF_MODELS_REFRESH_INTERVAL", "0"),
    ("NIF_OPENAI_API_KEY", "sk-test-provider-pin"),
    ("NIF_OPENAI_BASE_URL", baseURL),
    ("NIF_OPENAI_MODEL", "env-default-model")
  ])
  defer:
    if coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running():
        coreProc.kill()
        sleep(200)
    coreProc.close()
    removeDir(sandbox.root)

  var up = false
  for i in 0 ..< 100:
    let r = call(nc, "llm", "llm_resolve", newJObject(), 5_000)
    if r{"error"} == nil and r{"ok"}.getBool(false):
      up = true
      break
    sleep(200)
  check("llm boots and resolves the unpinned default", up)
  # Provider/model readiness does not imply core readiness: the turns below
  # call svc.core.call, so wait for core itself (see waitCoreUp in helpers).
  check("core accepts calls before the first turn", waitCoreUp(nc))

  # --- 1. the pin that cannot be resolved: the turn must FAIL, not reroute
  # (a session turn reports ok:true with outcome "error" — the conversation
  # itself is alive; the TURN is what failed)
  let pinned = call(nc, "core", "session", %*{
    "sessionId": "provider-pin-blocked", "content": "say hi",
    "provider": "synthetic", "model": "syn:large:text"
  }, 120_000)
  check("a turn pinned to an unresolvable provider fails",
        pinned{"outcome"}.getStr("") == "error", $pinned)
  let refusal = pinned{"turnError"}.getStr("")
  check("the refusal names the pinned provider",
        refusal.contains("synthetic"), $pinned)
  check("the refusal says it did not reroute",
        refusal.contains("refusing the turn"), $pinned)
  check("the refusal explains the registry, not a missing record",
        refusal.contains("registry") or refusal.contains("provider component"),
        $pinned)

  # The proof of no reroute: the environment default's endpoint saw nothing.
  var reachedDefault = false
  if fileExists(portFile & ".log"):
    for line in readFile(portFile & ".log").splitLines():
      if line.strip() == "\"syn:large:text\"" or line.strip() == "\"env-default-model\"":
        reachedDefault = true
  check("the other backend was never called", not reachedDefault,
        if fileExists(portFile & ".log"): readFile(portFile & ".log") else: "(no requests)")

  # --- 2. the same conversation, pin cleared: it runs on the harness default
  let cleared = call(nc, "core", "session", %*{
    "sessionId": "provider-pin-blocked", "content": "say hi",
    "provider": "", "model": ""
  }, 120_000)
  check("clearing the pin lets the conversation run again",
        cleared{"outcome"}.getStr("") == "success" and
        cleared{"reply"}.getStr("") == "fake-ok", $cleared)
  var askedDefault = false
  if fileExists(portFile & ".log"):
    for line in readFile(portFile & ".log").splitLines():
      if line.strip() == "\"env-default-model\"":
        askedDefault = true
  check("the default backend received the resolved model", askedDefault,
        if fileExists(portFile & ".log"): readFile(portFile & ".log") else: "(no requests)")

  report("PROVIDER PIN TEST")

main()
