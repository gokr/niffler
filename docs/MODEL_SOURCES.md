# Model source plugins — authoring guide

A *model source* is an ordinary component that adds or corrects model-catalog
data: a wrong context limit, a retired model, a provider the models.dev
baseline does not know yet. Sources are discovered automatically while the
component is registered and removed when it departs.

The contract (the `x-models-source` marker, the `{version: 1}` call, the
JSON Merge Patch result and the merge order) is specified in
[MANUAL.md](MANUAL.md#source-plugins). This page is the worked example.

## A minimal Nim source

```nim
import niffler/sdk

let comp = newComponent("my-models", "0.1.0")
comp.tool(%*{"hidden": true}):
  proc my_models_source(version: int = 1): JsonNode =
    ## Add or correct model catalog data for My Provider.
    ## - version: models source protocol version
    %*{"patch": {
      "my-provider": {
        "id": "my-provider",
        "name": "My Provider",
        "env": ["MY_PROVIDER_API_KEY"],
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.example.com/v1",
        "models": {
          "my-model": {
            "id": "my-model",
            "name": "My Model",
            "reasoning": true,
            "tool_call": true,
            "modalities": {"input": ["text"], "output": ["text"]},
            "limit": {"context": 200000, "output": 32000},
            "cost": {"input": 1.0, "output": 5.0}
          }
        }
      }
    }}

comp.tools[^1].schema["x-models-source"] = %*{"version": 1, "priority": 200}
comp.run()
```

The tool must be `hidden` — it is a registration surface for the `models`
component, not something the LLM calls.

## Packaging

Put the source in a normal `niffler.json` package (see the
[plugins chapter](MANUAL.md#component-ecosystem-plugins)). Installation,
update, removal, process isolation and persistence are handled by the
existing `plugins` component and the core lifecycle; a package may ship the
models source alongside other components.

Higher `priority` wins when two sources patch the same field; registered
sources are applied in ascending priority then by `component/tool`, and
`NIF_MODELS_OVERRIDE` is always applied last. Verify with
`models_sources` (provenance, freshness, stale fallback) and
`models_get`/`models_resolve` after a refresh.
