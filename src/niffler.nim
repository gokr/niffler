## Main CLI Entry Point - parseopt version
##
## Uses parseopt for flexible command-line argument parsing with full control
## over subcommands and option handling.

import std/[os, logging, parseopt]
import core/[config, database, session, app]
import ui/[cli, agent_cli, nats_monitor]
import types/config as configTypes

const VERSION* = staticExec("cd " & currentSourcePath().parentDir().parentDir() & " && nimble dump | grep '^version:' | cut -d'\"' -f2")

proc init(configPath: string = "") =
  ## Initialize Niffler configuration at specified path or default location
  let path = if configPath.len == 0: getDefaultConfigPath() else: configPath
  initializeConfigManager()

proc showModels() =
  ## List available models and their base URLs from configuration
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

type
  CliArgs = object
    command: string      # "", "agent", "model", "init", "nats-monitor"
    model: string
    prompt: string
    agentName: string
    agentNick: string
    natsUrl: string
    debug: bool
    info: bool
    dump: bool
    logFile: string
    help: bool
    version: bool

    # For 'model' subcommand
    modelSubCmd: string    # "list" or empty
    # For 'init' subcommand
    initPath: string

proc parseCliArgs(): CliArgs =
  ## Parse command line arguments using parseopt
  result = CliArgs(
    command: "",
    natsUrl: "nats://localhost:4222",
    debug: false,
    info: false,
    dump: false,
    help: false,
    version: false
  )

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      # Handle subcommands and their arguments
      if result.command == "":
        # This is the first argument - could be a subcommand or part of interactive args
        if key in ["agent", "model", "init"]:
          result.command = key
        elif key == "nats-monitor":
          result.command = "nats-monitor"
        else:
          # Treat as positional argument for interactive mode
          # (unlikely case - usually we use flags for positioning arguments)
          discard
      elif result.command == "agent" and result.agentName == "":
        result.agentName = key
      elif result.command == "model" and result.modelSubCmd == "":
        result.modelSubCmd = key
      elif result.command == "init" and result.initPath == "":
        result.initPath = key

    of cmdLongOption, cmdShortOption:
      case key
      of "model", "m": result.model = val
      of "prompt", "p": result.prompt = val
      of "nick": result.agentNick = val
      of "nats": result.natsUrl = val
      of "debug", "d": result.debug = true
      of "info", "i": result.info = true
      of "dump": result.dump = true
      of "log": result.logFile = val
      of "help", "h": result.help = true
      of "version", "v": result.version = true
      of "agent":
        if result.command == "":
          result.command = "agent"
          if val.len > 0:
            result.agentName = val
      of "nats-monitor":
        result.command = "nats-monitor"
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdEnd:
      # End of command line arguments
      break

proc showHelp() =
  ## Display comprehensive help information
  echo """
Niffler - your friendly magical AI buddy

USAGE:
  niffler [options]                               # Interactive mode
  niffler --prompt="<text>" [options]            # Single prompt
  niffler agent <name> [options]                  # Start agent
  niffler model list                              # List models
  niffler init [path]                             # Initialize config
  niffler nats-monitor [options]                  # Monitor NATS traffic

NOTE: All long options require '=' for values (e.g., --model=gpt4, --nick=test123)

OPTIONS:
  -m, --model=<nickname>     Select model by nickname
  -p, --prompt="<text>"      Single prompt and exit
  -i, --info                 Info level logging
  -d, --debug                Debug level logging
      --dump                 Show HTTP requests & responses
      --log=<filename>       Redirect debug output to log file
      --nats=<url>           NATS server URL [default: nats://localhost:4222]
  -h, --help                 Show this help message
  -v, --version              Show version

AGENT COMMAND OPTIONS:
      --nick=<nickname>      Instance nickname for multiple agent instances

EXAMPLES:
  niffler                              # Start interactive mode
  niffler --model=gpt4               # Interactive with specific model
  niffler --prompt="hello" --debug   # Single prompt with debugging

  niffler agent coder                # Start coder agent
  niffler agent researcher --nick=alpha      # Researcher with nickname
  niffler agent coder --nick=prod --model=gpt4  # Coder with nick and model

  niffler model list                   # List available models
  niffler init                         # Initialize config at default location
  niffler init /path/to/config        # Initialize config at custom path
  niffler nats-monitor                  # Monitor NATS traffic (debug mode)
"""

proc showVersion() =
  ## Display version information
  echo "Niffler ", VERSION

proc handleError(message: string, showHelp: bool = false) =
  ## Display error message and optionally show help
  echo "Error: ", message
  if showHelp:
    echo ""
    showHelp()
  quit(1)


proc sendSinglePrompt(prompt: string, modelName: string, level: Level, dump: bool, logFile: string) =
  ## Send a single prompt and exit
  echo "Single prompt: ", prompt
  echo "Model: ", modelName
  echo "Note: Full single prompt functionality to be integrated with existing CLI systems"

proc startInteractiveMode(modelName: string, level: Level, dump: bool, logFile: string = "", natsUrl: string = "nats://localhost:4222") =
  ## Start interactive CLI mode with specified model and logging configuration

  # Initialize configuration components
  let config = loadConfig()
  let database = initializeGlobalDatabase(level)

  # Select model
  let modelConfig = if modelName.len > 0:
    selectModelFromConfig(config, modelName)
  else:
    config.models[0]

  # Start the interactive CLI mode with proper input loop
  # Signal handling and cleanup are handled inside startCLIMode
  var session: Session
  startCLIMode(session, modelConfig, database, level, dump, natsUrl)

proc parseCliArgsMain(): CliArgs =
  ## Parse command line arguments with error handling
  try:
    result = parseCliArgs()
  except CatchableError as e:
    handleError("Failed to parse command line arguments: " & e.msg, true)

proc dispatchCmd(args: CliArgs) =
  ## Dispatch parsed commands to appropriate handlers

  # Handle help and version first
  if args.help:
    showHelp()
    quit(0)

  if args.version:
    showVersion()
    quit(0)

  # Set logging level
  var level = lvlNotice
  if args.debug:
    level = lvlDebug
    debug "Debug logging enabled"
  elif args.info:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)

  # Handle subcommands
  case args.command
  of "agent":
    if args.agentName == "":
      handleError("agent command requires a name", true)

    startAgentMode(args.agentName, args.agentNick, args.model, args.natsUrl, level, args.dump)

  of "model":
    if args.modelSubCmd == "list":
      let config = loadConfig()
      echo "Available models:"
      for model in config.models:
        echo "  ", model.nickname, " (", model.baseUrl, ")"
    else:
      handleError("Unknown model subcommand. Use 'niffler model list'", true)
    quit(0)

  of "init":
    let path = if args.initPath.len > 0: args.initPath else: ""
    let fullPath = if path.len == 0: getDefaultConfigPath() else: path
    initializeConfigManager()
    echo "Configuration initialized at: ", fullPath
    quit(0)

  of "nats-monitor":
    startNatsMonitor(args.natsUrl, level)
    quit(0)

  of "":
    # Interactive mode or single prompt
    if args.prompt.len == 0:
      # Start interactive mode (master mode with agent routing)
      startInteractiveMode(args.model, level, args.dump, args.logFile, args.natsUrl)
    else:
      # Send single prompt
      sendSinglePrompt(args.prompt, args.model, level, args.dump, args.logFile)

  else:
    handleError("Unknown command: " & args.command, true)

when isMainModule:
  let args = parseCliArgsMain()
  dispatchCmd(args)
