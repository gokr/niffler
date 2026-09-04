## Nil-safe JsonNode helpers — the missing half of std/json.
##
## std/json's typed getters (getStr/getInt/getBool/getFloat/...) treat a
## nil node as "missing" and return the default. Everything else is a
## latent SIGSEGV: `.kind`, `.len`, `$`, and iteration all dereference
## nil — and `{}` navigation returns nil for every missing key, so
## `x{"a"}{"b"}.kind == JString` or `for it in x{"items"}:` crash the
## process the first time the key is absent. Every field read should go
## through the nil-safe getters; every structural check belongs here.
##
## Pure std/json, no deps — core imports it directly (like envelope).

import std/json

proc jkind*(n: JsonNode): JsonNodeKind =
  ## Nil-safe kind probe: JNull for a nil node, else n.kind.
  if n.isNil: JNull else: n.kind

proc isStr*(n: JsonNode): bool =
  ## True when n is a JSON string (nil-safe).
  n.jkind == JString

proc isObj*(n: JsonNode): bool =
  ## True when n is a JSON object (nil-safe).
  n.jkind == JObject

proc isArr*(n: JsonNode): bool =
  ## True when n is a JSON array (nil-safe).
  n.jkind == JArray

proc listOf*(n: JsonNode): seq[JsonNode] =
  ## Nil-safe array iteration: [] for nil or non-array, else the elements.
  ## `for it in x{"items"}.listOf:` never SIGSEGVs, whatever the shape.
  if n.isArr: n.elems else: @[]

proc jdump*(n: JsonNode): string =
  ## Nil-safe `$`: "null" for a nil node, else the compact JSON text.
  if n.isNil: "null" else: $n
