## Nil-safe JsonNode helpers (sdk/niffler/jsonx.nim): the `.kind`/iterate/`$`
## on nil traps this suite has hit twice in production code. Pure std/json —
## no bus needed, runs in milliseconds.

import std/json
import niffler/sdk

proc main() =
  var failures = 0
  proc check(name: string, ok: bool, detail = "") =
    if ok: echo "OK: ", name
    else:
      echo "FAIL: ", name, (if detail.len > 0: " — " & detail else: "")
      inc failures

  let missing = %*{"n": 1}
  let nilNode: JsonNode = nil

  # jkind: the crashing pattern `x{"a"}.kind` — safe everywhere now.
  check("jkind nil", nilNode.jkind == JNull)
  check("jkind missing key", missing{"a"}.jkind == JNull)
  check("jkind string", (%"x").jkind == JString)
  check("jkind object", missing.jkind == JObject)

  # typed checks
  check("isStr nil", not nilNode.isStr)
  check("isStr missing", not missing{"a"}.isStr)
  check("isStr hit", (%*{"t": "s"}){"t"}.isStr)
  check("isObj nil", not nilNode.isObj)
  check("isObj hit", missing.isObj)
  check("isArr nil", not nilNode.isArr)
  check("isArr hit", newJArray().isArr)

  # listOf: the documented AGENTS.md trap — iterating a missing key.
  var seen = 0
  for it in missing{"items"}.listOf: inc seen
  check("listOf missing key iterates zero", seen == 0)
  for it in nilNode.listOf: inc seen
  check("listOf nil iterates zero", seen == 0)
  let arr = %*[1, 2, 3]
  var sum = 0
  for it in arr.listOf: sum += it.getInt()
  check("listOf iterates elements", sum == 6)
  check("listOf non-array is empty", (%*{"a": 1}){"a"}.listOf.len == 0)

  # jdump: $ on nil segfaults (toUgly case node.kind)
  check("jdump nil", nilNode.jdump == "null")
  check("jdump value", (%*{"a": 1}).jdump == "{\"a\":1}")

  if failures > 0:
    echo "JSONX TEST FAILED"
    quit(1)
  echo "JSONX TEST PASSED"

main()
