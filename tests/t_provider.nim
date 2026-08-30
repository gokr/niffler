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
  # Session runners are spawned on demand rather than manifest-supervised.
  copyFileWithPermissions(repoRoot / "var" / "bin" / "session",
                          sandbox.sandboxBin("session"))
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
  check("provider_add stores and activates the first provider without echoing its key",
        add1{"ok"}.getBool(false) and add1{"active"}.getBool(false) and
        add1{"provider"}{"baseUrl"}.getStr("") == "https://api.deepseek.com" and
        add1{"provider"}{"hasKey"}.getBool(false) and
        not ($add1).contains("sk-test-deepseek"), $add1)

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
        add3{"ok"}.getBool(false) and add3{"provider"}{"model"}.getStr("") == "deepseek-reasoner" and
        not ($add3).contains("sk-test-deepseek-2"), $add3)

  # --- update: change model without resending or losing the secret
  var changedSub: ptr natsSubscription
  doAssert checkStatus(natsConnection_SubscribeSync(
    addr changedSub, nc.conn, "ev.provider.changed".cstring))
  let updated = call(nc, "provider", "provider_update", %*{
    "nickname": "deepseek", "model": "deepseek-chat", "catalog": "deepseek"
  })
  check("provider_update changes non-secret settings",
        updated{"ok"}.getBool(false) and
        updated{"provider"}{"model"}.getStr("") == "deepseek-chat" and
        updated{"provider"}{"hasKey"}.getBool(false), $updated)
  var changedSeen = ""
  let changedDeadline = epochTime() + 5.0
  while epochTime() < changedDeadline:
    var msg: ptr natsMsg
    if natsSubscription_NextMsg(addr msg, changedSub, 500) == NATS_OK:
      changedSeen = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      if changedSeen.contains("\"op\":\"update\""): break
  check("provider mutations publish a redacted changed event",
        changedSeen.contains("\"nickname\":\"deepseek\"") and
        not changedSeen.contains("sk-test"), changedSeen)
  natsSubscription_Destroy(changedSub)

  let afterUpdate = call(nc, "provider", "provider_active", newJObject())
  check("provider_update preserves the stored API key",
        afterUpdate{"provider"}{"apiKey"}.getStr("") == "sk-test-deepseek-2", $afterUpdate)

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

  let safeStatus = call(nc, "provider", "provider_status", newJObject())
  check("provider_status reports the effective provider without a key",
        safeStatus{"ok"}.getBool(false) and
        safeStatus{"source"}.getStr("") == "store" and
        safeStatus{"provider"}{"nickname"}.getStr("") == "deepseek" and
        safeStatus{"provider"}{"hasKey"}.getBool(false) and
        not ($safeStatus).contains("sk-test"), $safeStatus)

  let publicCatalog = call(nc, "core", "catalog", %*{"op": "list"})
  var leakedInternalProviderTool = false
  for tool in publicCatalog{"tools"}:
    if tool{"name"}.getStr("") in ["provider_active", "provider_get"]:
      leakedInternalProviderTool = true
  check("provider credential reads stay hidden from the LLM catalog",
        not leakedInternalProviderTool, $publicCatalog)

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
        active{"ok"}.getBool(false) and active{"source"}.getStr("") == "store" and
        active{"provider"}{"nickname"}.getStr("") == "openrouter" and
        active{"provider"}{"apiKey"}.getStr("") == "sk-test-openrouter" and
        active{"provider"}{"context"}.getInt(0) == 123456, $active)

  let resolved = call(nc, "llm", "llm_resolve", %*{"model": "custom-model"})
  check("llm_resolve safely reports effective provider/model/context",
        resolved{"ok"}.getBool(false) and
        resolved{"provider"}.getStr("") == "openrouter" and
        resolved{"providerSource"}.getStr("") == "store" and
        resolved{"model"}.getStr("") == "custom-model" and
        resolved{"context"}.getInt(0) == 123456 and
        resolved{"contextSource"}.getStr("") == "provider" and
        not ($resolved).contains("sk-test"), $resolved)

  let pinned = call(nc, "llm", "llm_resolve", %*{
    "provider": "deepseek", "model": "deepseek-reasoner"
  })
  check("llm_resolve can retain a non-active stored provider by nickname",
        pinned{"ok"}.getBool(false) and
        pinned{"provider"}.getStr("") == "deepseek" and
        pinned{"providerSource"}.getStr("") == "store" and
        pinned{"model"}.getStr("") == "deepseek-reasoner", $pinned)

  # --- session config: persist a model selection without making an API call
  var statusSub: ptr natsSubscription
  doAssert checkStatus(natsConnection_SubscribeSync(
    addr statusSub, nc.conn, "ev.session.status".cstring))
  let configured = call(nc, "core", "session", %*{
    "sessionId": "provider-model-config", "model": "custom-session-model"
  }, 30_000)
  check("model-only session call persists selection without inference",
        configured{"ok"}.getBool(false) and
        configured{"modelOverride"}.getStr("") == "custom-session-model" and
        configured{"model"}.getStr("") == "custom-session-model" and
        configured{"context"}.getInt(0) == 123456, $configured)
  var statusSeen = ""
  let statusDeadline = epochTime() + 5.0
  while epochTime() < statusDeadline:
    var msg: ptr natsMsg
    if natsSubscription_NextMsg(addr msg, statusSub, 500) == NATS_OK:
      statusSeen = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      if statusSeen.contains("provider-model-config"): break
  check("model-only session call publishes resolved context status",
        statusSeen.contains("custom-session-model") and
        statusSeen.contains("123456"), statusSeen)
  natsSubscription_Destroy(statusSub)

  let configuredHeader = call(nc, "store", "get", %*{
    "kind": "conversation", "id": "provider-model-config"
  })
  let configuredMessages = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": "provider-model-config:"
  })
  check("model-only session call updates the header and creates no messages",
        configuredHeader{"value"}{"modelOverride"}.getStr("") == "custom-session-model" and
        configuredMessages{"items"}.len == 0,
        $configuredHeader & " " & $configuredMessages)

  # --- session config: persist a thinking-effort selection (the TUI's
  # ctrl+g cycle) without inference and without being rejected as a
  # malformed session call.
  let effort = call(nc, "core", "session", %*{
    "sessionId": "provider-thinking-effort", "thinking": "high"
  }, 30_000)
  check("thinking-only session call persists effort without inference",
        effort{"ok"}.getBool(false) and
        effort{"thinkingEffort"}.getStr("") == "high" and
        effort{"error"} == nil, $effort)
  let effortHeader = call(nc, "store", "get", %*{
    "kind": "conversation", "id": "provider-thinking-effort"
  })
  check("thinking-only session call updates the header",
        effortHeader{"value"}{"thinkingEffort"}.getStr("") == "high",
        $effortHeader)
  let cleared = call(nc, "core", "session", %*{
    "sessionId": "provider-thinking-effort", "thinking": ""
  }, 30_000)
  check("clearing effort returns to provider default",
        cleared{"ok"}.getBool(false) and
        cleared{"thinkingEffort"}.getStr("") == "", $cleared)

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

  # --- environment fallback: clear and restore the stored global default
  let envDefault = call(nc, "provider", "provider_use_environment", newJObject())
  check("provider_use_environment clears the stored active marker",
        envDefault{"source"}.getStr("") == "environment" and
        not envDefault{"ok"}.getBool(true), $envDefault)
  let backToDeepseek = call(nc, "provider", "provider_switch",
                            %*{"nickname": "deepseek"})
  check("stored provider can be selected again after environment fallback",
        backToDeepseek{"ok"}.getBool(false), $backToDeepseek)

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

  # --- session model override + effective context/usage persistence.
  # A tiny local OpenAI-compatible SSE fixture records the actual wire model,
  # avoiding external credentials/network in this contract test.
  let fixturePortFile = sandbox.root / "var" / "openai-fixture.port"
  let fixtureRequests = sandbox.root / "var" / "openai-fixture.requests"
  let fixture = startProcess("python3", workingDir = repoRoot, args = @[
    repoRoot / "tests" / "fixtures" / "openai_stream_server.py",
    fixturePortFile, fixtureRequests
  ], options = {poUsePath, poParentStreams})
  defer: stopProcess(fixture)
  var fixturePort = ""
  for i in 0 ..< 100:
    if fileExists(fixturePortFile):
      fixturePort = readFile(fixturePortFile).strip()
      if fixturePort.len > 0: break
    sleep(20)
  check("OpenAI stream fixture starts", fixturePort.len > 0)

  if fixturePort.len > 0:
    let fixtureProvider = call(nc, "provider", "provider_update", %*{
      "nickname": "local",
      "baseUrl": "http://127.0.0.1:" & fixturePort & "/v1",
      "model": "provider-default",
      "context": 98765
    })
    check("fixture provider update preserves its key",
          fixtureProvider{"ok"}.getBool(false) and
          fixtureProvider{"provider"}{"model"}.getStr("") == "provider-default" and
          fixtureProvider{"provider"}{"context"}.getInt(0) == 98765,
          $fixtureProvider)

    var statusSub: ptr natsSubscription
    doAssert checkStatus(natsConnection_SubscribeSync(
      addr statusSub, nc.conn, "ev.session.status".cstring))
    let turn = call(nc, "core", "session", %*{
      "sessionId": "provider-model-e2e",
      "content": "reply exactly OK",
      "model": "selected-model"
    }, 30_000)
    check("session completes with a conversation model override",
          turn{"ok"}.getBool(false) and turn{"reply"}.getStr("") == "OK" and
          turn{"modelOverride"}.getStr("") == "selected-model", $turn)
    var usageStatus = ""
    let statusDeadline = epochTime() + 5.0
    while epochTime() < statusDeadline:
      var msg: ptr natsMsg
      if natsSubscription_NextMsg(addr msg, statusSub, 500) == NATS_OK:
        let eventText = $natsMsg_GetData(msg)
        natsMsg_Destroy(msg)
        if eventText.contains("\"model\":\"selected-model\"") and
           eventText.contains("\"usedTokens\":124"):
          usageStatus = eventText
          break
    natsSubscription_Destroy(statusSub)
    check("session status event carries resolved model/context and total usage",
          usageStatus.contains("\"provider\":\"local\"") and
          usageStatus.contains("\"context\":98765"), usageStatus)

    let wire = if fileExists(fixtureRequests): readFile(fixtureRequests) else: ""
    check("session sends the selected model on the OpenAI wire",
          wire.contains("\"model\": \"selected-model\"") and
          wire.contains("\"stream\": true"), wire)

    let header = call(nc, "store", "get", %*{
      "kind": "conversation", "id": "provider-model-e2e"
    })
    let hv = header{"value"}
    check("conversation header persists provider/model/effective context/total usage",
          header{"ok"}.getBool(false) and
          hv{"modelOverride"}.getStr("") == "selected-model" and
          hv{"provider"}.getStr("") == "local" and
          hv{"model"}.getStr("") == "selected-model" and
          hv{"context"}.getInt(0) == 98765 and
          hv{"promptTokens"}.getInt(0) == 123 and
          hv{"contextUsed"}.getInt(0) == 124, $header)

    let messages = call(nc, "store", "list", %*{
      "kind": "message", "idPrefix": "provider-model-e2e:", "limit": 100
    })
    var assistantMetadata = false
    for item in messages{"items"}:
      let value = item{"value"}
      if value{"role"}.getStr("") == "assistant":
        assistantMetadata = value{"provider"}.getStr("") == "local" and
          value{"model"}.getStr("") == "selected-model" and
          value{"context"}.getInt(0) == 98765 and
          value{"usage"}{"total_tokens"}.getInt(0) == 124
    check("assistant message persists actual provider/model/context/usage",
          assistantMetadata, $messages)

    let clearTurn = call(nc, "core", "session", %*{
      "sessionId": "provider-model-e2e",
      "content": "reply exactly OK again",
      "model": ""
    }, 30_000)
    check("empty model explicitly clears the conversation override",
          clearTurn{"ok"}.getBool(false) and
          clearTurn{"modelOverride"}.getStr("not-empty").len == 0, $clearTurn)
    let cleared = call(nc, "store", "get", %*{
      "kind": "conversation", "id": "provider-model-e2e"
    })
    check("cleared override resolves and persists the provider default",
          cleared{"value"}{"modelOverride"}.getStr("not-empty").len == 0 and
          cleared{"value"}{"model"}.getStr("") == "provider-default",
          $cleared)

  # --- provider administration is discoverable without bloating every prompt
  let catalog = call(nc, "core", "catalog", %*{"op": "list"})
  var providerTools = 0
  for tool in catalog{"tools"}:
    let name = tool{"name"}.getStr("")
    if name.startsWith("provider_"): inc providerTools
  check("provider tools are omitted from the direct LLM projection",
        providerTools == 0, $catalog)
  let discovered = call(nc, "core", "discover", %*{"component": "provider"})
  check("provider administration tools are advertised on demand",
        discovered{"component"}{"onDemand"}.len == 6 and
        not ($discovered).contains("provider_active"), $discovered)
  let snapshot = call(nc, "core", "catalog", %*{"op": "snapshot"})
  var providerSnapshot: JsonNode
  for item in snapshot{"components"}:
    if item{"name"}.getStr("") == "provider":
      providerSnapshot = item
  check("full catalog keeps all provider tools and hides credential access",
        providerSnapshot != nil and providerSnapshot{"tools"}.len == 11 and
        ($providerSnapshot).contains("provider_active") and
        ($providerSnapshot).contains("provider_update") and
        ($providerSnapshot).contains("\"hidden\":true"), $providerSnapshot)

  report("PROVIDER TEST")

main()
