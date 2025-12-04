## Bash Command Execution Tool
##
## This tool provides secure command execution with timeout protection and
## non-zero exit code handling. It returns structured JSON output for
## non-zero exit codes instead of raising exceptions.
##
## Features:
## - Command timeout protection (default 30 seconds)
## - JSON output for failed commands with exit codes
## - Input validation and sanitization
## - Safe command execution through common utilities

import std/json
import ../types/tools
import ../types/tool_args
import common

proc executeBash*(args: JsonNode): string =
  ## Execute bash command with timeout and exit code handling
  ## Returns output on success or JSON with exit code info on failure
  var parsedArgs = parseWithDefaults(BashArgs, args, "bash")

  if parsedArgs.command.len == 0:
    raise newToolValidationError("bash", "command", "non-empty string", "empty string")

  validateTimeout(parsedArgs.timeout)

  try:
    let output = getCommandOutput(parsedArgs.command, timeout = parsedArgs.timeout)
    # Success case (exit code 0) - return output or indicator for empty output
    if output.len == 0:
      return "(success: no output)"
    return output
  except ToolExecutionError as e:
    # Non-zero exit code - return JSON with exit code info instead of failing
    let resultJson = %*{
      "output": e.output,
      "exit_code": e.exitCode,
      "success": false,
      "command": parsedArgs.command
    }
    return $resultJson
  except ToolError as e:
    # Other tool errors (timeouts, etc.) should still be errors
    raise e
  except Exception as e:
    raise newToolExecutionError("bash", "Command execution failed: " & e.msg, -1, "")