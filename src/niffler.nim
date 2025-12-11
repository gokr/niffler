## Main CLI Entry Point - parseopt version
##
## Uses parseopt for flexible command-line argument parsing with full control
## over subcommands and option handling.

import std/[os, logging, parseopt, strutils]
import core/[config, database, session, app]
import ui/[cli, agent_cli, nats_monitor]
import types/config as configTypes

const VERSION* = staticExec("cd " & currentSourcePath().parentDir().parentDir() & " && nimble dump | grep '^version:' | cut -d'\"' -f2")


type
  CliArgs = object
    command: string      # "", "agent", "model", "init", "nats-monitor"
    model: string
    agentName: string
    agentNick: string
    natsUrl: string
    logLevel: string
    dump: bool
    dumpsse: bool
    dumpJson: bool
    logFile: string
    help: bool
    version: bool

    # For 'model' subcommand
    modelSubCmd: string    # "list" or empty
    # For 'init' subcommand
    initPath: string
    # For 'agent' subcommand
    task: string           # Single-shot task to execute
    ask: string            # Single-shot ask (like task but without summarization)

proc parseCliArgs(): CliArgs =
  ## Parse command line arguments using parseopt
  result = CliArgs(
    command: "",
    natsUrl: "nats://localhost:4222",
    logLevel: "NOTICE",
    dump: false,
    dumpsse: false,
    dumpJson: false,
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
      of "nick": result.agentNick = val
      of "nats": result.natsUrl = val
      of "loglevel": result.logLevel = val
      of "dump": result.dump = true
      of "dumpsse": result.dumpsse = true
      of "dump-json": result.dumpJson = true
      of "log": result.logFile = val
      of "task", "t": result.task = val
      of "ask", "a": result.ask = val
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
  niffler agent <name> [options]                  # Start agent
  niffler model list                              # List models
  niffler init [path]                             # Initialize config
  niffler nats-monitor [options]                  # Monitor NATS traffic

NOTE: All long options require '=' for values (e.g., --model=gpt4, --nick=test123)

OPTIONS:
  -m, --model=<nickname>     Select model by nickname
      --loglevel=<level>     Set logging level [DEBUG|INFO|NOTICE|WARN|ERROR|FATAL] (default: NOTICE)
      --dump                 Show HTTP requests & responses
      --dumpsse              Show raw SSE lines as they arrive
      --dump-json            Show complete Chat Completion API response as single JSON (accumulated from streaming)

  Debug combinations:
    --dump --dumpsse          Show HTTP + raw SSE protocol debug info
    --dump-json              Show only final JSON response (no protocol debug)
      --log=<filename>       Redirect debug output to log file
      --nats=<url>           NATS server URL [default: nats://localhost:4222]
  -h, --help                 Show this help message
  -v, --version              Show version

AGENT COMMAND OPTIONS:
      --nick=<nickname>      Instance nickname for multiple agent instances
  -t, --task="<text>"        Execute single task and exit (no interactive mode)
  -a, --ask="<text>"         Execute single ask and exit (no task summarization)

EXAMPLES:
  niffler                              # Start interactive mode
  niffler --model=kimik2               # Interactive with specific model
  niffler --loglevel=DEBUG             # Enable debug logging
  niffler --loglevel=ERROR --model=gpt4  # Error logging only with specific model

  niffler agent coder                # Start coder agent (interactive)
  niffler agent researcher --nick=alpha      # Researcher with nickname
  niffler agent coder --nick=prod --model=kimik2  # Coder with nick and model
  niffler agent coder --task="What is 7+8?" --model=kimi  # Single-shot task
  niffler agent coder --ask="List files in src/" --model=kimi  # Single-shot ask
  niffler agent coder --loglevel=DEBUG  # Agent with debug logging

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


proc parseLogLevel(levelStr: string): Level =
  ## Parse string log level to logging.Level enum
  let upperLevel = levelStr.toUpper()
  case upperLevel
  of "DEBUG": result = lvlDebug
  of "INFO": result = lvlInfo
  of "NOTICE": result = lvlNotice
  of "WARN": result = lvlWarn
  of "ERROR": result = lvlError
  of "FATAL": result = lvlFatal
  else:
    handleError("Invalid log level: '" & levelStr & "'. Available levels: DEBUG, INFO, NOTICE, WARN, ERROR, FATAL")


proc startMasterMode(modelName: string, level: Level, dump: bool, dumpsse: bool, dumpJson: bool, logFile: string = "", natsUrl: string = "nats://localhost:4222") =
  ## Start master mode with CLI interface for agent routing

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
  startCLIMode(session, modelConfig, database, level, dump, dumpsse, natsUrl)

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

  # Set logging level from loglevel argument
  let level = parseLogLevel(args.logLevel)

  # Setup console logging only if no file logging requested
  # File logging modes will handle their own console+file setup
  let consoleLogger = newConsoleLogger(useStderr = true)
  if args.logFile.len == 0:
    addHandler(consoleLogger)
  setLogFilter(level)

  # Show logging status now that logger is set up
  let upperLevel = args.logLevel.toUpper()
  if upperLevel in ["DEBUG", "INFO"]:
    debug(upperLevel & " logging enabled")

  # Handle subcommands
  case args.command
  of "agent":
    if args.agentName == "":
      handleError("agent command requires a name", true)

    startAgentMode(args.agentName, args.agentNick, args.model, args.natsUrl, level, args.dump, args.dumpsse, args.dumpJson, args.logFile, args.task, args.ask)

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
    startNatsMonitor(args.natsUrl, level, args.dump, args.dumpsse, args.logFile)
    quit(0)

  of "":
    # Interactive mode with agent routing
    startMasterMode(args.model, level, args.dump, args.dumpsse, args.dumpJson, args.logFile, args.natsUrl)

  else:
    handleError("Unknown command: " & args.command, true)

when isMainModule:
  let args = parseCliArgsMain()
  dispatchCmd(args)
