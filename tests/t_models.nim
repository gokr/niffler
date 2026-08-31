## models tests -- baseline catalog, strict resolution, and plugin patches.
##
## Boots the full harness with a deterministic local models.dev fixture,
## builds a source component through the normal builder/spawn path, and proves
## its x-models-source patch appears and disappears with component presence.

import std/[json, os, osproc, strutils]
import natswrapper
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

  report("MODELS TEST")

main()
