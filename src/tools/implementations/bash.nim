import std/json
import ../../types/tools
import ../common
import ../registry

type
  BashTool* = ref object of ToolDef
    cwd*: string

proc newBashTool*(): BashTool =
  result = BashTool()
  result.name = "bash"
  result.description = "Runs a bash command in the cwd. The bash command is run as a subshell, not connected to a PTY, so don't run interactive commands: only run commands that will work headless. Do NOT attempt to pipe echo, printf, etc commands to work around this. If it's interactive, either figure out a non-interactive variant to run instead, or if that's impossible, as a last resort you can ask the user to run the command, explaining that it's interactive. Often interactive commands provide flags to run them non-interactively. Prefer those flags."

proc validate*(tool: BashTool, args: JsonNode) =
  ## Validate bash tool arguments
  validateArgs(args, @["cmd", "timeout"])
  
  let cmd = getArgStr(args, "cmd")
  let timeout = getArgInt(args, "timeout")
  
  if cmd.len == 0:
    raise newToolValidationError("bash", "cmd", "non-empty string", "empty string")
  
  validateTimeout(timeout)

proc execute*(tool: BashTool, args: JsonNode): string =
  ## Execute bash command
  let cmd = getArgStr(args, "cmd")
  let timeout = getArgInt(args, "timeout")
  
  try:
    return getCommandOutput(cmd, timeout = timeout)
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("bash", "Command execution failed: " & e.msg, -1, "")

# Register the tool
proc registerBashTool*() =
  let tool = newBashTool()
  let registryPtr = getGlobalToolRegistry()
  var registry = registryPtr[]
  registry.register(tool)

# Create the tool definition for the registry
when isMainModule:
  registerBashTool()