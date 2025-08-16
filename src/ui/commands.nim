## Command System for Niffler
##
## This module provides a unified command system for handling slash commands
## across different UI modes (CLI, enhanced, TUI).
##
## Features:
## - Command parsing and validation
## - Command completion and suggestions
## - Unified command execution interface
## - Extensible command registration system

import std/[strutils, strformat, tables]
import ../core/[history, config]
import ../types/config as configTypes

type
  CommandResult* = object
    success*: bool
    message*: string
    shouldExit*: bool
    shouldContinue*: bool

  CommandInfo* = object
    name*: string
    description*: string
    usage*: string
    aliases*: seq[string]

  CommandHandler* = proc(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult

var commandRegistry = initTable[string, tuple[info: CommandInfo, handler: CommandHandler]]()

proc registerCommand*(name: string, description: string, usage: string, 
                     aliases: seq[string], handler: CommandHandler) =
  ## Register a new command
  let info = CommandInfo(
    name: name,
    description: description, 
    usage: usage,
    aliases: aliases
  )
  commandRegistry[name] = (info, handler)
  
  # Register aliases
  for alias in aliases:
    commandRegistry[alias] = (info, handler)

proc getAvailableCommands*(): seq[CommandInfo] =
  ## Get list of all available commands (excluding aliases)
  result = @[]
  var seen = initTable[string, bool]()
  
  for name, (info, handler) in commandRegistry:
    if not seen.hasKey(info.name):
      result.add(info)
      seen[info.name] = true

proc getCommandCompletions*(input: string): seq[CommandInfo] =
  ## Get command completions for the given input
  let available = getAvailableCommands()
  if input.len == 0:
    return available
  
  result = @[]
  let searchTerm = input.toLower()
  
  # Only match command names that start with the search term
  for cmd in available:
    if cmd.name.toLower().startsWith(searchTerm):
      result.add(cmd)

proc parseCommand*(input: string): tuple[command: string, args: seq[string]] =
  ## Parse a command input string
  if not input.startsWith("/"):
    return ("", @[])
  
  let parts = input[1..^1].split(' ')
  if parts.len == 0:
    return ("", @[])
  
  result.command = parts[0].toLower()
  result.args = if parts.len > 1: parts[1..^1] else: @[]

proc executeCommand*(command: string, args: seq[string], 
                    currentModel: var configTypes.ModelConfig): CommandResult =
  ## Execute a command with the given arguments
  if not commandRegistry.hasKey(command):
    return CommandResult(
      success: false,
      message: fmt"Unknown command: /{command}. Type '/help' for available commands.",
      shouldExit: false,
      shouldContinue: true
    )
  
  let (info, handler) = commandRegistry[command]
  return handler(args, currentModel)

# Built-in command handlers
proc helpHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  var message = "Available commands:\n"
  let commands = getAvailableCommands()
  
  for cmd in commands:
    message.add(fmt"  /{cmd.name}")
    if cmd.usage.len > 0:
      message.add(fmt" {cmd.usage}")
    message.add(fmt" - {cmd.description}\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc exitHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  return CommandResult(
    success: true,
    message: "Goodbye!",
    shouldExit: true,
    shouldContinue: false
  )

proc modelsHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  let config = loadConfig()
  var message = "Available models:\n"
  
  for model in config.models:
    let marker = if model.nickname == currentModel.nickname: " (current)" else: ""
    message.add(fmt"  {model.nickname} - {model.model}{marker}\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc modelHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  if args.len == 0:
    return CommandResult(
      success: false,
      message: "Usage: /model <name>",
      shouldExit: false,
      shouldContinue: true
    )
  
  let modelName = args[0]
  let config = loadConfig()
  
  for model in config.models:
    if model.nickname == modelName:
      currentModel = model
      # Note: Model switching will be handled by the calling UI
      return CommandResult(
        success: true,
        message: fmt"Switched to model: {currentModel.nickname} ({currentModel.model})",
        shouldExit: false,
        shouldContinue: true
      )
  
  return CommandResult(
    success: false,
    message: fmt"Model '{modelName}' not found. Use '/models' to see available models.",
    shouldExit: false,
    shouldContinue: true
  )

proc clearHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  clearHistory()
  return CommandResult(
    success: true,
    message: "Conversation history cleared.",
    shouldExit: false,
    shouldContinue: true
  )

proc initializeCommands*() =
  ## Initialize the built-in commands
  registerCommand("help", "Show help and available commands", "", @[], helpHandler)
  registerCommand("exit", "Exit Niffler", "", @["quit"], exitHandler)
  registerCommand("models", "List available models", "", @[], modelsHandler)
  registerCommand("model", "Switch to a different model", "<name>", @[], modelHandler)
  registerCommand("clear", "Clear conversation history", "", @[], clearHandler)