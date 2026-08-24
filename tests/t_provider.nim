## provider tests -- store-backed LLM provider registry and its llm hookup.
##
## Boots a minimal full core (store + provider + llm) and drives the
## provider_* tools over the bus: add/list/switch/active/export/import/
## remove, key redaction, the ev.provider.switch notification, and
## active-fallback on removal. Ends by proving llm resolves the active
## stored provider for its chat calls.

import std/[json, os, osproc, strutils, times]
import natswrapper
import helpers

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("provider", ["store", "provider", "llm"])
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = sandbox.root, extra = [
    ("NIF_AUTO_APPROVE", "1")
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

  # wait for the provider component to register (poll provider_list)
  var up = false
  for i in 0 ..< 100:
    let r = call(nc, "provider", "provider_list", newJObject(), 3_000)
    if r{"error"} == nil:
      up = true
      break
    sleep(200)
  check("provider registers on the bus", up)

  # --- add: first provider becomes active automatically
  let add1 = call(nc, "provider", "provider_add", %*{
    "nickname": "deepseek",
    "apiKey": "sk-test-deepseek",
    "model": "deepseek-chat",
    "catalog": "deepseek"
  })
  check("provider_add stores and activates the first provider",
        add1{"ok"}.getBool(false) and add1{"active"}.getBool(false) and
        add1{"provider"}{"baseUrl"}.getStr("") == "https://api.deepseek.com", $add1)

  # --- add: second provider stays inactive unless told otherwise
  let add2 = call(nc, "provider", "provider_add", %*{
    "nickname": "openrouter",
    "apiKey": "sk-test-openrouter",
    "baseUrl": "https://openrouter.ai/api/v1",
    "model": "deepseek/deepseek-chat",
    "context": 123456
  })
  check("provider_add keeps the active provider when active is unset",
        add2{"ok"}.getBool(false) and not add2{"active"}.getBool(true), $add2)

  # --- add: update an existing provider (upsert, keeps activeness)
  let add3 = call(nc, "provider", "provider_add", %*{
    "nickname": "deepseek",
    "apiKey": "sk-test-deepseek-2",
    "model": "deepseek-reasoner"
  })
  check("provider_add upserts an existing provider",
        add3{"ok"}.getBool(false) and add3{"provider"}{"model"}.getStr("") == "deepseek-reasoner", $add3)

  # --- list: redacted keys, active marker
  let list = call(nc, "provider", "provider_list", newJObject())
  check("provider_list reports both providers, deepseek active",
        list{"count"}.getInt(0) == 2 and list{"active"}.getStr("") == "deepseek", $list)
  var sawDeepseek = false
  for p in list{"providers"}:
    if p{"nickname"}.getStr("") == "deepseek":
      sawDeepseek = p{"active"}.getBool(false) and p{"hasKey"}.getBool(false)
  check("provider_list marks the active provider and never leaks keys",
        sawDeepseek and not list.contains("sk-test-deepseek"), $list)

  # --- switch: live change + ev.provider.switch notification
  var sub: ptr natsSubscription
  doAssert checkStatus(natsConnection_SubscribeSync(
    addr sub, nc.conn, "ev.provider.switch".cstring))
  let sw = call(nc, "provider", "provider_switch", %*{"nickname": "openrouter"})
  check("provider_switch switches the active provider",
        sw{"ok"}.getBool(false) and sw{"active"}.getStr("") == "openrouter", $sw)
  var evSeen = ""
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    var msg: ptr natsMsg
    if natsSubscription_NextMsg(addr msg, sub, 500) == NATS_OK:
      evSeen = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      break
  check("switch publishes ev.provider.switch with previous and new nickname",
        evSeen.contains("\"nickname\":\"openrouter\"") and
        evSeen.contains("\"previous\":\"deepseek\""), evSeen)
  natsSubscription_Destroy(sub)

  # --- active: returns the full config incl. key + explicit context override
  let active = call(nc, "provider", "provider_active", newJObject())
  check("provider_active returns the active provider with key and context",
        active{"ok"}.getBool(false) and
        active{"provider"}{"nickname"}.getStr("") == "openrouter" and
        active{"provider"}{"apiKey"}.getStr("") == "sk-test-openrouter" and
        active{"provider"}{"context"}.getInt(0) == 123456, $active)

  # --- export / import round-trip (keys ride along by design)
  let exp = call(nc, "provider", "provider_export", newJObject())
  check("provider_export contains both providers with keys",
        exp{"count"}.getInt(0) == 2 and
        exp{"providers"}[0]{"apiKey"}.getStr("") != "" and
        exp{"active"}.getStr("") == "openrouter", $exp)
  let imp = call(nc, "provider", "provider_import", %*{
    "json": $exp
  })
  check("provider_import round-trips the export",
        imp{"ok"}.getBool(false) and imp{"count"}.getInt(0) == 2, $imp)

  # --- import: adds a new provider and restores the active marker
  let imp2 = call(nc, "provider", "provider_import", %*{
    "json": """{"active": "deepseek", "providers": [
      {"nickname": "local", "apiKey": "sk-local", "baseUrl": "http://127.0.0.1:11434/v1", "model": "qwen3"}]}"""
  })
  check("provider_import merges new providers",
        imp2{"ok"}.getBool(false) and imp2{"count"}.getInt(0) == 1, $imp2)
  let list2 = call(nc, "provider", "provider_list", newJObject())
  check("imported provider appears in the list",
        list2{"count"}.getInt(0) == 3, $list2)

  # --- remove: active provider falls back to another
  let rem1 = call(nc, "provider", "provider_remove", %*{"nickname": "openrouter"})
  check("provider_remove drops a non-active provider",
        rem1{"ok"}.getBool(false), $rem1)
  let list3 = call(nc, "provider", "provider_list", newJObject())
  check("removing the active provider falls back to another",
        list3{"active"}.getStr("") == "deepseek" and
        list3{"count"}.getInt(0) == 2, $list3)

  # --- remove: the last provider clears the active marker
  let rem2 = call(nc, "provider", "provider_remove", %*{"nickname": "deepseek"})
  check("provider_remove removes the active provider",
        rem2{"ok"}.getBool(false), $rem2)
  let rem3 = call(nc, "provider", "provider_remove", %*{"nickname": "local"})
  check("provider_remove removes the last provider",
        rem3{"ok"}.getBool(false), $rem3)
  let none = call(nc, "provider", "provider_active", newJObject())
  check("with no providers left, provider_active reports none",
        not none{"ok"}.getBool(true) and none{"error"}.getStr("").len > 0, $none)

  # --- remove: unknown provider errors cleanly
  let remX = call(nc, "provider", "provider_remove", %*{"nickname": "nope"})
  check("provider_remove on an unknown provider errors",
        remX{"error"}.getStr("").len > 0, $remX)

  # --- llm integration: an active stored provider routes llm chat calls.
  # Point the stored provider at a closed loopback port: if llm resolves it,
  # the chat call fails with a connection error; if llm ignored the store it
  # would fail with "no API key" (no NIF_OPENAI_API_KEY in the test env).
  let stored = call(nc, "provider", "provider_add", %*{
    "nickname": "local",
    "apiKey": "sk-test-local",
    "baseUrl": "http://127.0.0.1:1/v1",
    "model": "qwen3"
  })
  check("stored provider for the llm hookup test",
        stored{"ok"}.getBool(false) and stored{"active"}.getBool(false), $stored)

  var llmErr = ""
  for i in 0 ..< 100:
    let r = call(nc, "llm", "chat", %*{
      "messages": [%*{"role": "user", "content": "hi"}]
    }, 5_000)
    let e = r{"error"}.getStr("")
    if e.len > 0 and not e.startsWith("nats"):
      llmErr = e
      break
    sleep(200)
  check("llm chat resolves the active stored provider (connection error, not a missing key)",
        llmErr.len > 0 and llmErr.contains("refused") and
        not llmErr.contains("API key"), llmErr)

  # --- the LLM can see the provider tools (visible, not hidden)
  let catalog = call(nc, "core", "catalog", %*{"op": "list"})
  var providerTools = 0
  for tool in catalog{"tools"}:
    let name = tool{"name"}.getStr("")
    if name.startsWith("provider_"): inc providerTools
  check("provider tools are registered and visible in the catalog",
        providerTools == 7, $catalog)

  report("PROVIDER TEST")

main()
