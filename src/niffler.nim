## Main CLI Entry Point - Autonomous Agent Version
##
## Entry point for the autonomous Niffler agent. Minimal DB config is read
## from file/environment, everything else is stored in the database.

import std/[os, logging, parseopt, strutils, strformat, tables, options, times, json]
import core/[config, database, session, app]
import core/db_config
import ui/cli
import comms/channel
import workspace/manager
import autonomous/task_queue
import agent/messaging
import types/config as configTypes

const VERSION* = staticExec("cd " & currentSourcePath().parentDir().parentDir() & " && nimble dump | grep '^version:' | cut -d'\"' -f2")

type
  CliArgs = object
    command: string
    model: string
    agentName: string
    logLevel: string
    dump: bool
    dumpsse: bool
    dumpJson: bool
    logFile: string
    help: bool
    version: bool

proc parseCliArgs(): CliArgs =
  ## Parse command line arguments using parseopt
  result = CliArgs(
    command: "",
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
      if result.command == "":
        if key in ["agent", "model", "init"]:
          result.command = key
        else:
          discard
      elif result.command == "agent" and result.agentName == "":
        result.agentName = key

    of cmdLongOption, cmdShortOption:
      case key
      of "model", "m": result.model = val
      of "loglevel": result.logLevel = val
      of "dump": result.dump = true
      of "dumpsse": result.dumpsse = true
      of "dump-json": result.dumpJson = true
      of "log": result.logFile = val
      of "help", "h": result.help = true
      of "version", "v": result.version = true
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdEnd:
      break

proc showHelp() =
  ## Display comprehensive help information
  echo """
Niffler - Autonomous AI Agent

USAGE:
  niffler [options]                               # Interactive mode
  niffler agent [name] [options]                  # Start agent with persona

NOTE: All long options require '=' for values (e.g., --model=gpt4)

OPTIONS:
  -m, --model=<nickname>     Select model by nickname
      --loglevel=<level>     Set logging level [DEBUG|INFO|NOTICE|WARN|ERROR|FATAL]
      --dump                 Show HTTP requests & responses
      --dumpsse              Show raw SSE lines
      --dump-json            Show complete API response as JSON
      --log=<filename>       Redirect debug output to log file
  -h, --help                 Show this help message
  -v, --version              Show version

EXAMPLES:
  niffler                              # Start interactive mode
  niffler --model=kimik2               # Interactive with specific model
  niffler agent coder                  # Start agent with 'coder' persona
  niffler agent --loglevel=DEBUG       # Start agent with debug logging

DATABASE CONFIGURATION:
  Minimal database config is read from: ~/.config/niffler/db_config.yaml
  Or via environment variables:
    NIFFLER_DB_HOST      Database host (default: 127.0.0.1)
    NIFFLER_DB_PORT      Database port (default: 4000)
    NIFFLER_DB_DATABASE  Database name (default: niffler)
    NIFFLER_DB_USERNAME  Database user (default: root)
    NIFFLER_DB_PASSWORD  Database password (default: empty)

All other configuration (models, personas, channels) is stored in the database.
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

proc startAgentMode(
  agentName: string,
  modelName: string,
  level: Level,
  dump: bool,
  dumpsse: bool,
  dumpJson: bool,
  logFile: string = ""
) =
  ## Start agent mode with autonomous capabilities
  
  # Load minimal DB config
  let minimalConfig = loadMinimalDbConfig()
  let dbConfig = toDatabaseConfig(minimalConfig)
  
  # Initialize database
  let database = createDatabaseBackend(dbConfig)
  if database == nil:
    handleError("Failed to initialize database. Check your database configuration.")
  
  # Initialize workspace manager
  let workspaceMgr = newWorkspaceManager(database)
  
  # Register this agent
  let agentId = if agentName.len > 0: agentName else: "niffler-" & $getTime().toUnix()
  let capabilities = %*{}
  let agentConfig = %*{
    "model": modelName
  }
  
  if not registerAgent(database, agentId, "default", capabilities, agentConfig):
    handleError("Failed to register agent")
  
  # Start task processor
  let taskProcessor = newTaskProcessor(database, workspaceMgr, agentId)
  startTaskProcessor(taskProcessor)
  
  # Start agent messenger
  let messenger = newAgentMessenger(database, agentId)
  startMessenger(messenger)
  
  # Start interactive CLI
  var session: Session
  # TODO: Update startCLIMode to work with new structure
  # For now, just print a message
  echo fmt("Agent '{agentId}' started. Task processor running.")
  echo "Press Ctrl+C to stop."
  
  # Wait for shutdown signal
  while true:
    sleep(1000)

proc dispatchCmd(args: CliArgs) =
  ## Dispatch parsed commands to appropriate handlers
  
  if args.help:
    showHelp()
    quit(0)

  if args.version:
    showVersion()
    quit(0)

  let level = parseLogLevel(args.logLevel)

  # Setup logging
  let consoleLogger = newConsoleLogger(useStderr = true)
  if args.logFile.len == 0:
    addHandler(consoleLogger)
  setLogFilter(level)

  case args.command
  of "agent":
    startAgentMode(args.agentName, args.model, level, args.dump, args.dumpsse, args.dumpJson, args.logFile)

  of "model":
    echo "Model list not yet implemented in database config mode"
    quit(0)

  of "init":
    echo "Config initialization not yet implemented"
    quit(0)

  of "":
    # Interactive mode
    startAgentMode("", args.model, level, args.dump, args.dumpsse, args.dumpJson, args.logFile)

  else:
    handleError("Unknown command: " & args.command, true)

when isMainModule:
  let args = parseCliArgs()
  dispatchCmd(args)
