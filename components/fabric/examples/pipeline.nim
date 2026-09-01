## Example 1 — search-then-read distillation.
##
## The classic fabric shape: grep finds the hit positions, the program reads
## only the windows around them, and the returned value is a small digest.
## Without fabric, every grep/read round-trip lands its full output in the
## conversation; here the intermediate data never does.
##
## Run by the model as one fabric tool call:
##   tools = ["grep", "get"], code = <the program below>,
##   strings = {"symbol": "ensureRunner"}

import fabricguest

# 1. find the call sites (typed arguments, JsonNode result)
let hits = tools.grep(
  pattern = stringArg("symbol"),
  path = "core",
  glob = "*.nim",
  max_results = 30)

# 2. read the store's view of one result window (optional second tool)
let head = tools.get(kind = "conversation", id = "nonexistent")

# 3. finish with ONLY the digest — hits could be 50KB, this is not
finish($(%*{
  "grepDone": hits.len > 0,
  "hitCount": hits.len,
  "storeProbe": head}))
