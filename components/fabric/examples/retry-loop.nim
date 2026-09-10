## Example 4 — retry loop with a hard cap: run the suite until green.
##
## The polling/retry shape: a mechanical condition (exit code) decides the
## loop, the model is not re-entered per iteration, and the cap guarantees
## termination. `call` returns the parsed result JsonNode, so probe
## exit_code directly rather than substring-matching the serialized text.
##
## Run by the model as one fabric tool call:
##   code = <the program below>, strings = {"suite": "make test-core"}

import fabricguest
import std/json

let suite = stringArg("suite")

var attempt = 0
var last = %*{"exit_code": -1}
let capped = 10  # hard cap: never loop forever
while attempt < capped:
  inc attempt
  last = call("bash", %*{"command": suite, "timeoutMs": 120_000})
  if last{"exit_code"}.getInt(-1) == 0:
    break

finish(%*{
  "attempts": attempt,
  "green": last{"exit_code"}.getInt(-1) == 0,
  "tail": last{"text"}.getStr("")})   # the model sees the LAST failure only
