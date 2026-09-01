## Example 4 — retry loop with a hard cap: run the suite until green.
##
## The polling/retry shape: a mechanical condition (exit code) decides the
## loop, the model is not re-entered per iteration, and the cap guarantees
## termination. This is the "light guest" pattern: no std/json import, the
## result JSON is probed with substring checks — cold eval stays ~ms.
##
## Run by the model as one fabric tool call:
##   code = <the program below>, strings = {"suite": "make test-core"}

import fabricguest

let suite = stringArg("suite")

var attempt = 0
var lastOutput = ""
let capped = 10  # hard cap: never loop forever
while attempt < capped:
  inc attempt
  let r = callTool("bash", jobj(
    jpair("command", jesc(suite)),
    jpair("timeoutMs", jnum(120000))))
  lastOutput = r
  if r.contains("\"exit_code\":0"):
    break

finish(jobj(
  jpair("attempts", jnum(attempt)),
  jpair("green", jbool(lastOutput.contains("\"exit_code\":0"))),
  jpair("tail", jesc(lastOutput))))     # the model sees the LAST failure only
