import std/json
import ../types/tools
import common

type
  BashTool* = ref object of InternalTool
    cwd*: string

proc newBashTool*(): BashTool =
  result = BashTool()
  result.name = "bash"
  result.description = "Runs a bash command in the cwd. The bash command is run as a subshell, not connected to a PTY, so don't run interactive commands: only run commands that will work headless. Do NOT attempt to pipe echo, printf, etc commands to work around this. If it's interactive, either figure out a non-interactive variant to run instead, or if that's impossible, as a last resort you can ask the user to run the command, explaining that it's interactive. Often interactive commands provide flags to run them non-interactively. Prefer those flags."

proc execute*(tool: BashTool, args: JsonNode): string =
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