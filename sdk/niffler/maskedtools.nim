## Fail-closed adapter for tools whose autonomous readers are not confined.
## Schemas remain unchanged; refusals are ordinary append-only tool results.
import std/[json, os, strutils]
import ./sdk

proc masksConfigured*(): bool =
  ## Any nonblank entry counts, including relative or malformed entries.
  ## Never silently ignore policy that cannot yet be enforced.
  for line in getEnv("NIF_BASH_SANDBOX_MASKS", "").splitLines():
    if line.strip().len > 0: return true

proc guardedHandler(original: ToolHandler): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    if masksConfigured():
      return %*{"ok": false, "error": "E_MASK_UNCONFINED",
        "text": "[E_MASK_UNCONFINED] Tool refused: operator masks are configured, but this component's autonomous readers are not confined. No tool action was started. Use a mask-aware reader or a guarded shell instead."}
    original(c, args)

proc refuseUnconfinedReaders*(c: Component) =
  ## Component-local explicit opt-in, installed after all tool registrations.
  ## Wrapping every handler also covers diagnostic and management paths that
  ## could expose cached data. No component-name logic enters core or SDK pump.
  for tool in mitems(c.tools):
    tool.handler = guardedHandler(tool.handler)
