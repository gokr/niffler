# Model catalog

The `models` component is Niffler's replaceable provider/model metadata plane.
It does not belong in core and it is not a universal inference adapter. It
answers which providers and models exist, how they are addressed, what they
support, and their limits and prices. An `llm` component still owns the actual
wire protocol, authentication flow, request transforms, and streaming.

The design borrows the useful common shape from Pi and OpenCode:

- models.dev is the broad curated baseline.
- A small embedded seed makes a first offline boot useful.
- The last validated download is written atomically and retained on failure.
- Corrections and provider discovery are deterministic layers, not edits to
  the downloaded file.
- User-supplied model ids are resolved strictly; ambiguous bare ids are never
  selected by catalog order.

## Merge order

The effective catalog is rebuilt in this order:

1. `NIF_MODELS_PATH`, the cached models.dev catalog, or the embedded seed.
2. Registered `x-models-source` plugins, ascending by `priority` and then by
   `component/tool`. A larger priority therefore wins.
3. `NIF_MODELS_OVERRIDE`, always last.

Plugin and local layers are JSON Merge Patches (RFC 7396): objects merge,
arrays and scalar values replace, and `null` deletes a key. The full
models.dev shape is preserved, including fields Niffler does not yet use.

The component refreshes at startup and hourly. A models.dev download is
skipped while its cache is younger than five minutes. HTTP fetches are bounded,
retried, validated (a catalog with no usable model entries is rejected, so a
malformed response cannot replace the last-known-good cache), and atomically
renamed into `var/models/api.json`. Each registered plugin source also has a
last-known-good patch under `var/models/sources/`; that patch is used when the
source temporarily fails, but only while the source component remains
registered. The local override keeps its previous patch when the file is
unreadable mid-rewrite. A failed refresh is retried automatically (30s or the
configured interval, whichever is sooner) so crash reconciliation without
`reg.depart` is not stranded until the next hourly tick. `ev.sys.drain`
cancels refresh work and shuts the component down.

## Tools

| Tool | Purpose |
|---|---|
| `models_providers` | provider connection metadata and configured status, never secret values |
| `models_list` | filtered model search with capabilities, modalities, limits, and costs |
| `models_get` | exact provider/model descriptor for another component |
| `models_resolve` | strict `provider/model` or globally unique bare-id resolution |
| `models_refresh` | queue a refresh of models.dev and every live extension source |
| `models_sources` | provenance, freshness, stale fallback, and error diagnostics |

`models_list {status: "active"}` also matches models whose status field is
absent (models.dev omits it for normal models). List results are trimmed when
they would exceed the bus payload limit, and an oversized single descriptor
errors instead of timing out on the wire. Descriptor metadata is recursively
redacted: secret-like keys (api keys, tokens, passwords, credentials,
authorization headers, private keys, cookies) never reach a caller, at
provider or model level.

`llm` asks `models_get` for the selected model's context window. Explicit
provider `context` and `NIF_OPENAI_CONTEXT` still win, and the existing small
fallback remains available if `models` is removed. Provider endpoints are
classified by hostname, not URL substring. Interactive clients should call the
hidden, credential-free `llm_resolve {model?}` rather than duplicating this
precedence: it reports the effective global provider, optional conversation
model override, catalog, context, and each value's provenance.

## Source plugins

A model source is an ordinary component installed by `plugins`. One hidden
tool carries this registration extension:

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

`models` discovers marked tools from `reg.publish` and from core's full catalog
snapshot, so component boot order does not matter. It calls the tool with
`{"version": 1}`. The result is:

```json
{
  "patch": {
    "openai": {
      "models": {
        "model-with-wrong-limit": {"limit": {"context": 200000}},
        "retired-model": null
      }
    }
  }
}
```

Minimal Nim source component:

```nim
import niffler/sdk

let comp = newComponent("my-models", "0.1.0")
comp.tool:
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
comp.tools[^1].schema["x-harness"] = %*{"hidden": true}
comp.run()
```

Put that component in a normal `niffler.json` package. Installation, update,
removal, process isolation, and persistence are already handled by the existing
`plugins` and core lifecycle. Removing the source component immediately removes
its patch from the effective catalog. No model-specific extension mechanism is
added to core.

## Configuration

| Variable | Meaning | Default |
|---|---|---|
| `NIF_MODELS_URL` | models.dev-compatible base URL or full JSON endpoint | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | pinned local baseline; disables remote baseline reads | unset |
| `NIF_MODELS_OVERRIDE` | local JSON Merge Patch applied last | unset |
| `NIF_MODELS_OFFLINE` | `1` disables remote baseline fetches | unset |
| `NIF_MODELS_CACHE_DIR` | cache and source-patch directory | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | minimum age before another baseline fetch | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | background refresh interval; `0` disables | `1h` |

The component only reports which credential environment names a provider uses
and whether one is set. It never returns credential values. Provider-specific
OAuth, ambient credentials, headers, request transformations, and native API
behavior belong in inference adapter components, which can be shipped or
installed as plugins independently of this catalog.
