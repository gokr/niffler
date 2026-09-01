## Test-only nested-call target that reports whether private context leaked.

import std/json
import niffler/sdk

let comp = newComponent("ctxsink", "0.1.0")

let inspectSchema = toolSchema(
  %*{"value": {"type": "string"}}, required = @["value"],
  description = "Test whether nested proxy context reached a target component.")
discard comp.tool("ctxinspect", inspectSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    %*{"value": toolArgs{"value"}.getStr(""),
       "sawSession": toolArgs{"__session"} != nil})

comp.run()
