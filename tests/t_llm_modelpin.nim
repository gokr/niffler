## llm model/provider pin contract: the provider's own model is never refused.
##
## The regression this pins: the guard that stops a model pinned without its
## provider read ownership from a `models_list` substring page (query + limit
## 50). A model id several providers share is buried under near-misses — the
## live catalog has 245 entries mentioning "deepseek-flash", and
## deepseek/deepseek-flash sorted 56th — so the page clipped the resolved
## provider's own entry and every pin-less conversation died on its first turn
## with "model … is served by provider 302ai, but this call resolved provider
## deepseek". Ownership now comes from `models_resolve`, and the provider's own
## configured model is exempt.
##
## Boots store + models (a generated fixture reproducing the clip: 60 near-miss
## providers sort between the alphabetical owner and the real one) + llm against
## a fake OpenAI-compatible endpoint, and drives a real session turn.

import std/[json, net, os, osproc, strutils]
import natsnim
import helpers

const sharedModel = "deepseek-flash"      # served by 302ai AND deepseek
const otherModel = "deepseek-other"       # the provider's OWN configured model
const foreignModel = "zz-302ai-only"      # served only by 302ai

# --------------------------------------------------------------------------
# a fake OpenAI-compatible endpoint: SSE chat completions, every request's model
# recorded so the test can prove the pin reached the provider.

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
    # Record what the adapter asked for; the harness's live-model probe and any
    # other endpoint hit answer 404 below and are ignored by recording nothing.
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

# --------------------------------------------------------------------------
# the catalog fixture, generated because the near-miss providers must outnumber
# one models_list page.

proc buildFixture(apiBaseURL: string): JsonNode =
  var catalog = newJObject()
  # The alphabetical first owner of the shared id — this is what the clipped
  # page showed, and it is why the guard named 302ai for deepseek's own model.
  catalog["302ai"] = %*{
    "id": "302ai", "name": "302ai",
    "api": "https://api.302.ai/v1", "env": ["THREE_ZERO_TWO_API_KEY"],
    "models": {"deepseek-flash": {"id": "deepseek-flash", "name": "Shared Flash"},
               "zz-302ai-only": {"id": "zz-302ai-only", "name": "302ai Only"}}
  }
  for i in 0 ..< 60:
    let id = "aa" & align($i, 2, '0')
    catalog[id] = %*{
      "id": id, "name": id, "api": "https://" & id & ".invalid/v1",
      "models": {("deepseek-flash-lite-" & $i): {"id": "deepseek-flash-lite-" & $i}}
    }
  catalog["deepseek"] = %*{
    "id": "deepseek", "name": "DeepSeek",
    "api": apiBaseURL, "env": ["NIF_OPENAI_API_KEY"],
    "models": {
      sharedModel: {"id": sharedModel, "name": "DeepSeek Flash",
                    "limit": {"context": 123456, "output": 4096}},
      otherModel: {"id": otherModel, "name": "DeepSeek Other",
                   "limit": {"context": 654321, "output": 2048}}
    }
  }
  catalog

proc main() =
  if paramCount() == 2 and paramStr(1) == "serve":
    serveChat(paramStr(2))
    return

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("llm-modelpin", ["store", "models", "llm"])
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

  let fixture = sandbox.root / "var" / "models-api.json"
  createDir(fixture.parentDir())
  writeFile(fixture, $buildFixture("https://api.deepseek.com"))

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = sandbox.root, extra = [
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MODELS_PATH", fixture),
    ("NIF_MODELS_OFFLINE", "1"),
    ("NIF_MODELS_REFRESH_INTERVAL", "0"),
    # The harness default provider, pointed at the fake, with the catalog id
    # pinned explicitly so the guard's judgment never depends on hostname
    # inference. Its OWN model is `otherModel`.
    ("NIF_OPENAI_API_KEY", "sk-test-modelpin"),
    ("NIF_OPENAI_BASE_URL", baseURL),
    ("NIF_OPENAI_MODEL", otherModel),
    ("NIF_OPENAI_PROVIDER", "deepseek")
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
    let r = call(nc, "models", "models_get",
                 %*{"provider": "deepseek", "model": sharedModel}, 3_000)
    if r{"error"} == nil and r{"model"}{"id"}.getStr("") == sharedModel:
      up = true
      break
    sleep(200)
  check("models boots with the generated catalog", up)

  # --- the shape that broke the guard: a substring page clips the real owner
  let page = call(nc, "models", "models_list",
                  %*{"query": sharedModel, "limit": 50}, 5_000)
  var onPage = false
  for m in page{"models"}:
    if m{"provider"}.getStr("") == "deepseek" and m{"id"}.getStr("") == sharedModel:
      onPage = true
  check("models_list clips the resolved provider's own entry (the regression shape)",
        page{"total"}.getInt(0) == 62 and page{"count"}.getInt(0) == 50 and not onPage,
        $page)
  let resolved = call(nc, "models", "models_resolve", %*{"reference": sharedModel}, 5_000)
  check("models_resolve names both owners of the shared id",
        not resolved{"found"}.getBool(true) and
        resolved{"matches"}.len == 2 and
        ($resolved{"matches"}).contains("deepseek/" & sharedModel), $resolved)

  # --- the regression: resolving the shared model for its own provider
  let pinned = call(nc, "llm", "llm_resolve", %*{"model": sharedModel}, 10_000)
  check("llm_resolve accepts a shared model the resolved provider serves",
        pinned{"error"} == nil and pinned{"ok"}.getBool(false) and
        pinned{"provider"}.getStr("") == "default" and
        pinned{"catalog"}.getStr("") == "deepseek" and
        pinned{"context"}.getInt(0) == 123456, $pinned)

  # --- the provider's own configured model stays exempt
  let own = call(nc, "llm", "llm_resolve", %*{"model": otherModel}, 10_000)
  check("llm_resolve accepts the provider's own configured model",
        own{"error"} == nil and own{"model"}.getStr("") == otherModel, $own)
  let implicit = call(nc, "llm", "llm_resolve", newJObject(), 10_000)
  check("llm_resolve accepts the pin-less default",
        implicit{"error"} == nil and implicit{"model"}.getStr("") == otherModel, $implicit)

  # --- the guard's original purpose is intact: a model only another provider
  # serves is still refused, naming it.
  let foreign = call(nc, "llm", "llm_resolve", %*{"model": foreignModel}, 10_000)
  check("a model the resolved provider does not serve is still refused",
        foreign{"error"}.getStr("").contains(foreignModel) and
        foreign{"error"}.getStr("").contains("302ai") and
        foreign{"error"}.getStr("").contains("deepseek"), $foreign)

  # --- end to end: a real conversation turn pinned to the shared model reaches
  # the provider instead of dying in the guard.
  let turn = call(nc, "core", "session", %*{
    "sessionId": "llm-modelpin-shared", "content": "say hi", "model": sharedModel
  }, 120_000)
  check("a turn pinned to a shared model completes",
        turn{"ok"}.getBool(false) and turn{"reply"}.getStr("") == "fake-ok" and
        turn{"modelOverride"}.getStr("") == sharedModel and
        turn{"providerOverride"}.getStr("") == "default", $turn)
  var asked = false
  if fileExists(portFile & ".log"):
    for line in readFile(portFile & ".log").splitLines():
      if line.strip() == "\"" & sharedModel & "\"":
        asked = true
  check("the provider received the pinned model", asked,
        if fileExists(portFile & ".log"): readFile(portFile & ".log") else: "(no requests)")

  report("LLM MODELPIN TEST")

main()
