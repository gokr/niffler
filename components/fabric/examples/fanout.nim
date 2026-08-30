## Example 2 — sequential fan-out with aggregation.
##
## The loop lives in the program: N tool calls, one turn, one return value.
## The LLM never re-enters the conversation per item. (Calls are sequential
## until concurrent bridge calls exist — still far cheaper than N round-trips
## through the model.)
##
## Run by the model as one fabric tool call:
##   code = <the program below>, strings = {"dirs": "core,components,sdk,tests"}

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
var parts: seq[string] = @[]
var total = 0
for d in dirs:
  let r = callTool("bash", jobj(
    jpair("command", jesc("find " & d & " -name '*.nim' | xargs wc -l | tail -1"))))
  parts.add(jobj(jpair("dir", jesc(d)), jpair("raw", jesc(r))))
  if r.len > 0: total = total + r.len

finish(jobj(
  jpair("count", jnum(dirs.len)),
  jpair("rawBytes", jnum(total)),
  jpair("dirs", jarr(parts))))
