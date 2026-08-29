## Example 1 — search-then-read distillation.
##
## The classic fabric shape: grep finds the hit positions, the program reads
## only the windows around them, and the returned value is a small digest.
## Without fabric, every grep/read round-trip lands its full output in the
## conversation; here the intermediate data never does.
##
## Run by the model as one fabric tool call:
##   code = <the program below>, strings = {"symbol": "ensureRunner"}

import fabricguest

# 1. find the call sites (raw JSON result string)
let hits = callTool("grep", jobj(
  jpair("pattern", jesc(stringArg("symbol"))),
  jpair("path", jesc("core")),
  jpair("glob", jesc("*.nim")),
  jpair("max_results", jnum(30))))

# 2. read the store's view of one result window (optional second tool)
let head = callTool("get", jobj(
  jpair("kind", jesc("conversation")),
  jpair("id", jesc("nonexistent"))))

# 3. finish with ONLY the digest — hits could be 50KB, this is not
finish(jobj(
  jpair("grepDone", jbool(hits.len > 0)),
  jpair("hitCount", jnum(hits.len)),
  jpair("storeProbe", jesc(head))))
