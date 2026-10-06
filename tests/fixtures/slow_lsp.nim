## Fixture component: an `lsp` whose pump is BUSY — every request is answered
## only after SLOW_LSP_MS (default 5000). It stands in for a cold language
## server whose check is running in the lsp component's idle seam, which is
## the real reason the next request's ack can be seconds away.
##
## Used by tests/t_edit_lsp_slow.nim: a mutation must never wait for it.

import std/[json, os, strutils]
import niffler/sdk

let comp = newComponent("lsp", "0.0.0-slow-fixture")
let delayMs = try: parseInt(getEnv("SLOW_LSP_MS", "5000"))
              except CatchableError: 5000

discard comp.tool("lsp", toolSchema(%*{
  "operation": {"type": "string"},
  "path": {"type": "string"}
}, @["operation"],
  "Slow stand-in for a busy lsp pump (test fixture)."),
  proc(c: Component, args: JsonNode): JsonNode =
    sleep(delayMs)
    return %*{"ok": true, "pending": true, "count": 0,
              "text": "fixture: late ack"})

discard comp.tool("lsp_servers", toolSchema(%*{}, @[],
  "Slow stand-in (test fixture)."),
  proc(c: Component, args: JsonNode): JsonNode =
    sleep(delayMs)
    return %*{"servers": []})

comp.run()
