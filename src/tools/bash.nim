import std/json
import ../types/tools
import common

proc executeBash*(args: JsonNode): string =
  ## Execute bash command
  let command = getArgStr(args, "command")
  let timeout = if args.hasKey("timeout"): getArgInt(args, "timeout") else: 30000
    
  if command.len == 0:
    raise newToolValidationError("bash", "command", "non-empty string", "empty string")
  
  validateTimeout(timeout)

  try:
    return getCommandOutput(command, timeout = timeout)
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("bash", "Command execution failed: " & e.msg, -1, "")