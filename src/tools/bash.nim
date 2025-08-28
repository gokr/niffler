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
    let output = getCommandOutput(command, timeout = timeout)
    # Success case (exit code 0) - return output as before
    return output
  except ToolExecutionError as e:
    # Non-zero exit code - return JSON with exit code info instead of failing
    let resultJson = %*{
      "output": e.output,
      "exit_code": e.exitCode,
      "success": false,
      "command": command
    }
    return $resultJson
  except ToolError as e:
    # Other tool errors (timeouts, etc.) should still be errors
    raise e
  except Exception as e:
    raise newToolExecutionError("bash", "Command execution failed: " & e.msg, -1, "")