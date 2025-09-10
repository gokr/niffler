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
import ../core/constants
import common

proc executeBash*(args: JsonNode): string =
  ## Execute bash command with timeout and exit code handling
  ## Returns output on success or JSON with exit code info on failure
  let command = getArgStr(args, "command")
  let timeout = if args.hasKey("timeout"): getArgInt(args, "timeout") else: DEFAULT_TIMEOUT
    
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