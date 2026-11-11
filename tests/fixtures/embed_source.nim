## Test-only metadata provider that declares one embed model through
## `x-embed-source` v1.
##
## Why a fixture and not the real plugin: the shipped declaration lives in
## `gokr/niffler-synthetic`, which the gate cannot clone, and the two facts
## this fixture pins — that a declaration's `dimensions`/`limit` merge over a
## configured embed model, and that the patch reaches the EMBEDDING view only —
## are properties of the models catalog, not of any one vendor. The provider
## nickname it patches is `fixture-embed`, chosen so it never collides with a
## models.dev baseline id: a fixture that shadowed a real provider would test
## the baseline, not the merge.
import std/[json, strutils]
import niffler/sdk

const provider = "fixture-embed"
const model = "fixture/embed-small"

let c = newComponent("fixture-embed-source", "0.1.0")

proc declaration(): JsonNode =
  result = %*{"patch": {provider: {"available": {model: {
    "id": model,
    "name": model.split('/')[^1],
    "dimensions": 384,
    "limit": {"context": 512}}}}}}

discard c.tool("fixture_embed_source", %*{
  "type": "object",
  "properties": {"version": {"type": "integer",
    "description": "embed source protocol version"}},
  "description": "Test fixture: an x-embed-source v1 JSON Merge Patch.",
  "x-embed-source": {"version": 1, "priority": 200}},
  proc(c: Component, a: JsonNode): JsonNode =
    let version = a{"version"}.getInt(1)
    if version != 1:
      raise newException(ValueError, "unsupported embed source version " & $version)
    declaration(),
  %*{"hidden": true, "timeoutMs": 5000})

c.run()
