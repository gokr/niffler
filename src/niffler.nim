## Main CLI Entry Point
##
## This is the primary entry point for Niffler, an AI-powered terminal assistant.
## It provides command-line interface handling using docopt for elegant subcommand parsing.
##
## Design Decisions:
## - Uses docopt for self-documenting command-line interface
## - Default behavior (no subcommand) starts interactive mode
## - Single prompts can be sent via --prompt/-p option
## - Supports multiple logging levels (debug, info, dump)


import std/[os, tables, logging, strformat]
import docopt

import core/[config, app, channels, history, database]
import core/log_file as logFileModule
import api/curlyStreaming
import ui/cli
import types/config as configTypes

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2") 

proc init(configPath: string = "") =
  ## Initialize Niffler configuration
  let path = if configPath.len == 0: getDefaultConfigPath() else: configPath
  initializeConfig(path)

proc showModels() = 
  ## List available models and configurations
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

proc initializeAppSystems(level: Level, dump: bool = false, logFile: string = "") =
  ## Initialize common app systems
  if logFile.len > 0:
    # Setup file and console logging
    let logManager = logFileModule.initLogFileManager(logFile)
    logFileModule.setGlobalLogManager(logManager)
    logManager.activateLogFile()
    let logger = logFileModule.newFileAndConsoleLogger(logManager)
    addHandler(logger)
  else:
    # Setup console-only logging
    let consoleLogger = newConsoleLogger()
    addHandler(consoleLogger)
  
  setLogFilter(level)
  initThreadSafeChannels()
  initHistoryManager()
  initDumpFlag()
  setDumpEnabled(dump)

proc selectModelFromConfig(modelName: string, config: configTypes.Config): configTypes.ModelConfig =
  ## Select model from configuration by name or use default
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
  ## Start interactive mode with CLI interface
  # Initialize app systems
  initializeAppSystems(level, dump, logFile)
  
  # Load configuration and select model
  let config = loadConfig()
  let selectedModel = selectModelFromConfig(modelName, config)
  
  # Initialize database
  let database = initializeGlobalDatabase(level)
  
  # Start a new conversation for cost tracking
  discard startNewConversation()
  
  # Start CLI mode
  try:
    startCLIMode(selectedModel, database, level, dump)
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
  -i --info              Show info level logging
  -d --debug             Show debug level logging
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

