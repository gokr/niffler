## Stable JSON representation for wire identity digests. No bus or core state.
import std/[algorithm, json]

proc canonicalJson*(node: JsonNode): string =
  ## Stable JSON independent of object insertion order.
  if node == nil: return "null"
  case node.kind
  of JObject:
    var keys: seq[string]
    for key, value in node: keys.add(key)
    keys.sort()
    result.add('{')
    for i, key in keys:
      if i > 0: result.add(',')
      result.add($(%key))
      result.add(':')
      result.add(canonicalJson(node[key]))
    result.add('}')
  of JArray:
    result.add('[')
    for i in 0 ..< node.len:
      if i > 0: result.add(',')
      result.add(canonicalJson(node[i]))
    result.add(']')
  else:
    result = $node
