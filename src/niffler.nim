## Main CLI Entry Point
##
## This is the primary entry point for Niffler, an AI-powered terminal assistant.
## It orchestrates the complete application lifecycle from command parsing to system initialization.
##
## Design Decisions:
## - Uses docopt for self-documenting command-line interface with subcommand support
## - Dual-mode operation: interactive CLI (default) and single-prompt execution
## - Comprehensive system initialization: logging, thread-safe channels, database, session management
## - Model selection from configuration with fallback to default and error handling
## - Flexible logging system supporting console-only and file+console output modes
## - Thread-safe architecture with dedicated channels for inter-worker communication
##
## Command Structure:
## - init: Initialize configuration at specified or default path
## - model list: Display configured models with their base URLs
## - Default: Start interactive mode or execute single prompt with --prompt
##
## System Integration:
## - Coordinates core modules: config, channels, conversation_manager, database
## - Bridges CLI interface with API worker and tool execution systems
## - Handles graceful shutdown and error recovery for all application modes


import std/[os, tables, logging, strformat]
import docopt

import core/[config, channels, conversation_manager, database, session]
import core/log_file as logFileModule
import api/curlyStreaming
import ui/cli
import types/config as configTypes

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2") 

proc init(configPath: string = "") =
  ## Initialize Niffler configuration at specified path or default location
  let path = if configPath.len == 0: getDefaultConfigPath() else: configPath
  initializeConfig(path)

proc showModels() =
  ## List available models and their base URLs from configuration
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

proc initializeAppSystems(level: Level, dump: bool = false, logFile: string = ""): DatabaseBackend =
  ## Initialize common application systems (logging, channels, database) and return database backend
  if logFile.len > 0:
    # Setup file and console logging
    let logManager = logFileModule.initLogFileManager(logFile)
    logFileModule.setGlobalLogManager(logManager)
    logManager.activateLogFile()
    let logger = logFileModule.newFileAndConsoleLogger(logManager)
    addHandler(logger)
  else:
    # Setup console-only logging
    let consoleLogger = newConsoleLogger(useStderr = true)
    addHandler(consoleLogger)
  
  setLogFilter(level)
  initThreadSafeChannels()
  initDumpFlag()
  setDumpEnabled(dump)
  
  # Initialize database
  result = database.initializeGlobalDatabase(level)
  
  # Get database pool for cross-thread history sharing
  let pool = if result != nil: result.pool else: nil
  
  # Initialize session manager with pool - will be reset in CLI mode with conversation ID
  initSessionManager(pool)

proc selectModelFromConfig(modelName: string, config: configTypes.Config): configTypes.ModelConfig =
  ## Select model from configuration by nickname or use default model with warning
  if modelName.len > 0:
    # Find model by nickname
    for model in config.models:
      if model.nickname == modelName:
        return model
    echo fmt"Warning: Model '{modelName}' not found, using default: {config.models[0].nickname}"
  
  if config.models.len > 0:
    return config.models[0]
  else:
    echo "Error: No models configured. Please run 'niffler init' first."
    quit(1)

proc startInteractiveMode(modelName: string, level: Level, dump: bool, logFile: string = "") =
  ## Start interactive CLI mode with specified model and logging configuration
  # Initialize app systems and get database
  let databaseBackend = initializeAppSystems(level, dump, logFile)

  # Initialize session
  var sess = initSession()
  displayConfigInfo(sess)
  echo ""

  # Load configuration and select model
  let config = loadConfig()
  let selectedModel = selectModelFromConfig(modelName, config)

  # Start CLI mode (database already initialized earlier)
  try:
    startCLIMode(sess, selectedModel, databaseBackend, level, dump)
  except Exception as e:
    echo fmt"CLI mode failed: {e.msg}"
    echo "CLI requires linecross library for enhanced input"
    quit(1)

let doc = """
Niffler - your friendly magical AI buddy

Usage:
  niffler [--model <nickname>] [--prompt <text>] [options]
  niffler init [<path>] [options]
  niffler model list [options]
  niffler --version
  niffler --help

Options:
  -h --help              Show this help message
  -v --version           Show version of Niffler
  -m --model <nickname>  Select model by nickname
  -p --prompt "<text>"   Perform single prompt and exit
  -i --info              Show info level logging (to stderr)
  -d --debug             Show debug level logging  (to stderr)
  --dump                 Show HTTP requests & responses
  --log <filename>       Redirect debug/dump output to log files

Commands:
  init                   Initialize configuration
  model list             List available models
"""

when isMainModule:
  # Parse command line arguments using docopt
  let args = docopt(doc, version = "Niffler " & VERSION)
  
  # Handle subcommands
  if args["init"]:
    let configPath = if args["<path>"] and args["<path>"].kind != vkNone: $args["<path>"] else: ""
    init(configPath)
    quit(0)
  elif args["model"]:
    if args["list"]:
      showModels()
      quit(0)
    else:
      echo "Unknown model subcommand. Use 'niffler model list'"
      quit(1)
  
  # Set logging level based on options
  var level = lvlNotice
  if args["--debug"]:
    level = lvlDebug
    debug "Debug logging enabled"
  elif args["--info"]:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)
  
  # Extract options
  let model = if args["--model"] and args["--model"].kind != vkNone: $args["--model"] else: ""
  let prompt = if args["--prompt"] and args["--prompt"].kind != vkNone: $args["--prompt"] else: ""
  let dump = args["--dump"]
  let logFile = if args["--log"] and args["--log"].kind != vkNone: $args["--log"] else: ""

  if prompt.len == 0:
    # Start interactive mode
    startInteractiveMode(model, level, dump, logFile)
  else:
    # Send single prompt
    sendSinglePrompt(prompt, model, level, dump, logFile)

