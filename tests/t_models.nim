## models tests -- baseline catalog, strict resolution, and plugin patches.
##
## Boots the full harness with a deterministic local models.dev fixture,
## builds a source component through the normal builder/spawn path, and proves
## its x-models-source patch appears and disappears with component presence.

import std/[json, os, osproc, strutils]
import natsnim
import helpers

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler"):
    fail("missing core binary -- run `make build` first")
    quit(1)

  let sandbox = newCoreSandbox("models", ["store", "builder", "models"])
  let fixture = repoRoot / "tests" / "fixtures" / "models-api.json"
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = sandbox.root, extra = [
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MODELS_PATH", fixture),
    ("NIF_MODELS_OFFLINE", "1"),
    ("NIF_MODELS_CACHE_DIR", sandbox.root / "var" / "models-cache"),
    ("NIF_MODELS_REFRESH_INTERVAL", "0")
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

  var modelsUp = false
  for i in 0 ..< 100:
    let r = call(nc, "models", "models_sources", newJObject(), 3_000)
    if r{"error"} == nil and r{"providers"}.getInt(0) == 2:
      modelsUp = true
      break
    sleep(200)
  check("models registers with the local baseline", modelsUp)

  let base = call(nc, "models", "models_get",
                  %*{"provider": "deepseek", "model": "deepseek-chat"})
  check("models_get returns exact model metadata",
        base{"model"}{"limit"}{"context"}.getInt(0) == 100000 and
        base{"provider"}{"api"}.getStr("") == "https://api.deepseek.com", $base)

  let reasoning = call(nc, "models", "models_list",
                       %*{"provider": "deepseek", "reasoning": true})
  check("models_list filters capabilities",
        reasoning{"count"}.getInt(0) == 1 and
        reasoning{"models"}[0]{"id"}.getStr("") == "deepseek-reasoner", $reasoning)

  let ambiguous = call(nc, "models", "models_resolve",
                       %*{"reference": "deepseek-chat"})
  check("bare duplicate model id is rejected as ambiguous",
        not ambiguous{"found"}.getBool(true) and ambiguous{"matches"}.len == 2,
        $ambiguous)

  const source = """
    import niffler/sdk

    let comp = newComponent("models-fixture", "0.1.0")
    comp.tool(%*{"hidden": true}):
      proc fixture_models_source(version: int = 1): JsonNode =
        ## Supply deterministic model catalog corrections for the models test.
        ## - version: models source protocol version
        if version != 1:
          return %*{"patch": {}}
        %*{"patch": {
          "deepseek": {"models": {
            "deepseek-chat": {"limit": {"context": 222222}}
          }},
          "fixture-provider": {
            "id": "fixture-provider",
            "name": "Fixture Provider",
            "env": [],
            "npm": "@ai-sdk/openai-compatible",
            "api": "https://fixture.invalid/v1",
            "models": {
              "fixture-model": {
                "id": "fixture-model",
                "name": "Fixture Model",
                "reasoning": true,
                "tool_call": true,
                "modalities": {"input": ["text"], "output": ["text"]},
                "limit": {"context": 333333, "output": 8192},
                "cost": {"input": 0, "output": 0}
              }
            }
          }
        }}

    comp.tools[^1].schema["x-models-source"] = %*{"version": 1, "priority": 200}
    comp.run()
    """.dedent()

  let built = call(nc, "builder", "build",
                   %*{"lang": "nim", "name": "models-fixture", "source": source}, 300_000)
  check("builder builds a model-source plugin", built{"ok"}.getBool(false), $built)
  let spawned = call(nc, "core", "spawn",
                      %*{"name": "models-fixture",
                         "binary": built{"binary"}.getStr("")}, 60_000)
  check("core spawns the model-source plugin", spawned{"ok"}.getBool(false), $spawned)

  var patched = false
  for i in 0 ..< 100:
    let r = call(nc, "models", "models_get",
                 %*{"provider": "deepseek", "model": "deepseek-chat"}, 5_000)
    if r{"model"}{"limit"}{"context"}.getInt(0) == 222222:
      patched = true
      break
    sleep(200)
  check("registered source patch overrides models.dev", patched)

  let added = call(nc, "models", "models_get",
                   %*{"provider": "fixture-provider", "model": "fixture-model"})
  check("source patch can add a provider and model",
        added{"model"}{"limit"}{"context"}.getInt(0) == 333333, $added)

  let catalog = call(nc, "core", "catalog", %*{"op": "list"})
  var sourceHidden = true
  for tool in catalog{"tools"}:
    if tool{"name"}.getStr("") == "fixture_models_source":
      sourceHidden = false
  check("model-source tool stays hidden from the LLM", sourceHidden, $catalog)

  let removed = call(nc, "core", "remove", %*{"name": "models-fixture"}, 60_000)
  check("core removes the model-source plugin", removed{"ok"}.getBool(false), $removed)
  var reverted = false
  for i in 0 ..< 100:
    let r = call(nc, "models", "models_get",
                 %*{"provider": "deepseek", "model": "deepseek-chat"}, 5_000)
    if r{"model"}{"limit"}{"context"}.getInt(0) == 100000:
      reverted = true
      break
    sleep(200)
  check("departed source no longer affects the catalog", reverted)

  # --- refresh policy as a SETTING (config surface, slice 4) ----------------
  # The Go owner helper is exercised end to end: models declares, config
  # validates and forwards, models writes its own record, and the STORED
  # offline flag changes how a forced refresh behaves.
  # The sandbox core already runs its own store (single-writer: a second one
  # would refuse the flock), so the config surface reuses it.
  # Already running since core's boot: waitRegistered only sees FUTURE
  # announcements, so readiness is proved by an answering call.
  var storeUp = false
  for i in 0 ..< 50:
    if call(nc, "store", "list", %*{"kind": "probe"}, 2_000).hasKey("items"):
      storeUp = true
      break
    sleep(200)
  check("store up for the settings check", storeUp)
  let config = startComponent(repoRoot / "var" / "bin" / "config", url, root = sandbox.root)
  defer:
    if config.peekExitCode() == -1: config.terminate()
    config.close()
  var configUp = false
  for i in 0 ..< 50:
    if call(nc, "config", "config_list", %*{}, 2_000).hasKey("ok"):
      configUp = true
      break
    sleep(200)
  check("config up for the settings check", configUp)
  var listed = newJNull()
  for i in 0 ..< 60:
    listed = call(nc, "config", "config_list", %*{})
    if listed{"count"}.getInt(0) > 0: break
    sleep(100)
  var found = false
  if listed{"domains"} != nil and listed{"domains"}.kind == JArray:
    for entry in listed{"domains"}:
      if entry{"domain"}.getStr("") == "models.refresh": found = true
  check("models declares its refresh policy", found, $listed)
  let got = call(nc, "config", "config_get", %*{"domain": "models.refresh"})
  check("refresh defaults are reported, not stored",
        got{"ok"}.getBool(false) and
        got{"defaults"}{"cacheTtlSeconds"}.getFloat(0.0) == 300 and
        got{"values"}{"offline"} == nil, $got)
  let policySet = call(nc, "config", "config_patch", %*{
    "domain": "models.refresh", "patch": {"offline": true}})
  check("offline is set through config", policySet{"ok"}.getBool(false), $policySet)
  # Precedence (stored > env > default) is proved deterministically in
  # components/models/settings_test.go: a bus test can only observe that a
  # refresh was QUEUED, not which policy it used. Here the point is the owner
  # protocol: the stored value round-trips through this component's record.
  let afterSet = call(nc, "config", "config_get", %*{"domain": "models.refresh"})
  check("the stored policy round-trips through the owner",
        afterSet{"values"}{"offline"}.getBool(false) and
        afterSet{"rev"}.getInt(0) == 1, $afterSet)
  let reset = call(nc, "config", "config_reset", %*{"domain": "models.refresh"})
  check("reset returns the policy to its declared defaults", reset{"ok"}.getBool(false), $reset)
  let afterReset = call(nc, "config", "config_get", %*{"domain": "models.refresh"})
  check("the explicit value is gone after reset",
        afterReset{"values"}{"offline"} == nil and
        afterReset{"defaults"}{"offline"}.getBool(true) == false, $afterReset)
  let bad = call(nc, "config", "config_patch", %*{
    "domain": "models.refresh", "patch": {"cacheTtlSeconds": -1}})
  check("a negative TTL is refused before it reaches models",
        bad{"code"}.getStr() == "bad-request", $bad)

  report("MODELS TEST")

main()
