## Example 2 — fan-out with aggregation (deliberately sequential).
##
## The loop lives in the program: N tool calls, one turn, one return value.
## The LLM never re-enters the conversation per item. (This example calls
## one at a time; for independent calls that may overlap on the bus, use
## `batch(...)` — see retry-loop.nim or the t_fabric batch turn. Either way
## it is far cheaper than N round-trips through the model.)
##
## Run by the model as one fabric tool call:
##   tools = ["bash"], code = <the program below>,
##   strings = {"dirs": "core,components,sdk,tests"}

import fabricguest

# explode the CSV from strings into one bash call per directory
var dirs: seq[string] = @[]
let csv = stringArg("dirs")
var cur = ""
for c in csv:
  if c == ',':
    dirs.add(cur)
    cur = ""
  else:
    cur.add(c)
dirs.add(cur)

# fan out: count Nim lines per directory
var parts = newJArray()
var total = 0
for d in dirs:
  let r = tools.bash(
    command = "find " & d & " -name '*.nim' | xargs wc -l | tail -1")
  parts.add(%*{"dir": d, "result": r})
  total += ($r).len

finish($(%*{"count": dirs.len, "rawBytes": total, "dirs": parts}))
