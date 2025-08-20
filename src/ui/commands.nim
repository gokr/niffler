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

import std/[strutils, strformat, tables, options, formatfloat, logging]
import ../core/[history, config, app, database]
import ../types/[config as configTypes, messages]
import theme

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
    message.add("  /{cmd.name}".fmt)
    if cmd.usage.len > 0:
      message.add(" {cmd.usage}".fmt)
    message.add(" - {cmd.description}\n".fmt)
  
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
    message.add("  {model.nickname} - {model.model}{marker}\n".fmt)
  
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

proc contextHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show current conversation context information
  let messages = getConversationContext()
  let estimatedTokens = estimateTokenCount(messages)
  let historyLength = getHistoryLength()
  
  var message = "Conversation Context:\n"
  message.add("  Messages in context: " & $messages.len & "\n")
  message.add("  Total history items: " & $historyLength & "\n")
  message.add("  Estimated tokens: " & $estimatedTokens & "\n")
  
  if estimatedTokens > TOKEN_WARNING_THRESHOLD:
    message.add("  ⚠️  Warning: Approaching token limits\n")
  
  # Show breakdown by message type
  var userCount = 0
  var assistantCount = 0
  var toolCount = 0
  
  for msg in messages:
    case msg.role:
    of mrUser: inc userCount
    of mrAssistant: inc assistantCount
    of mrTool: inc toolCount
    else: discard
  
  message.add("  Breakdown: " & $userCount & " user, " & $assistantCount & " assistant, " & $toolCount & " tool messages\n")
  
  if messages.len >= DEFAULT_MAX_CONTEXT_MESSAGES:
    message.add("  📝 Context is at maximum size (" & $DEFAULT_MAX_CONTEXT_MESSAGES & " messages)\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc tokensHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show detailed token usage and cost information
  let sessionCounts = getSessionTokens()
  
  var message = "Token Usage & Cost Information:\n"
  message.add("  Session input tokens: " & $sessionCounts.promptTokens & "\n")
  message.add("  Session output tokens: " & $sessionCounts.completionTokens & "\n")
  message.add("  Session total tokens: " & $sessionCounts.totalTokens & "\n")
  message.add("  Model context limit: " & $currentModel.context & " tokens\n")
  
  if currentModel.context > 0 and sessionCounts.promptTokens > 0:
    let usagePercent = (sessionCounts.promptTokens * 100) div currentModel.context
    message.add("  Current context usage: " & $usagePercent & "%\n")
    
    if usagePercent > 80:
      message.add("  🚨 High context usage - consider using /clear\n")
    elif usagePercent > 60:
      message.add("  ⚠️  Moderate context usage\n")
  
  # Show cost information if available
  let hasInputCost = currentModel.inputCostPerMToken.isSome()
  let hasOutputCost = currentModel.outputCostPerMToken.isSome()
  
  if hasInputCost or hasOutputCost:
    message.add("\nCost Information:\n")
    
    if hasInputCost:
      let inputRate = currentModel.inputCostPerMToken.get()
      message.add("  Input cost: $" & inputRate.formatFloat(ffDecimal, 2) & " per million tokens\n")
    
    if hasOutputCost:
      let outputRate = currentModel.outputCostPerMToken.get()
      message.add("  Output cost: $" & outputRate.formatFloat(ffDecimal, 2) & " per million tokens\n")
    
    # No projections - user finds them unhelpful
  else:
    message.add("\n💡 Add inputCostPerMToken/outputCostPerMToken to model config for cost tracking\n")
  
  message.add("\n💡 Use '/clear' to reset context and reduce costs\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc costHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show session cost summary with accurate model-specific breakdown
  let sessionCounts = getSessionTokens()
  let messages = getConversationContext()
  
  var message = "Session Cost Summary:\n"
  
  # Get global database instance
  let database = getGlobalDatabase()
  
  # Try to get accurate cost breakdown from database
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      let (totalCost, breakdown) = getConversationCostBreakdown(database, conversationId)
      
      message.add("  Session: " & $messages.len & " messages, " & $sessionCounts.totalTokens & " tokens\n")
      
      if totalCost > 0:
        message.add("  Total session cost: " & formatCost(totalCost) & "\n")
        message.add("\nCost Breakdown by Model:\n")
        
        for line in breakdown:
          message.add("  " & line & "\n")
      else:
        message.add("  No cost data available for current session\n")
        message.add("  💡 Cost tracking will begin after your next message\n")
    except Exception as e:
      error(fmt"Database error in cost handler: {e.msg}")
      message.add("  ❌ Database error: " & e.msg & "\n")
      message.add("  💡 Try restarting Niffler to reinitialize database\n")
  else:
    # Fallback to old calculation method if database is not available
    message.add("  Session: " & $messages.len & " messages, " & $sessionCounts.totalTokens & " tokens\n")
    message.add("  ⚠️  Database not available - using estimated costs\n")
    message.add("  💡 Database will be automatically created when available\n")
    
    # Get cost information from model config
    let hasInputCost = currentModel.inputCostPerMToken.isSome()
    let hasOutputCost = currentModel.outputCostPerMToken.isSome()
    
    if hasInputCost or hasOutputCost:
      # Calculate session costs based on actual token usage
      var sessionInputCost = 0.0
      var sessionOutputCost = 0.0
      var sessionTotalCost = 0.0
      
      if hasInputCost:
        let inputCostPerToken = currentModel.inputCostPerMToken.get() / 1_000_000.0
        sessionInputCost = sessionCounts.promptTokens.float * inputCostPerToken
        sessionTotalCost += sessionInputCost
      
      if hasOutputCost:
        let outputCostPerToken = currentModel.outputCostPerMToken.get() / 1_000_000.0
        sessionOutputCost = sessionCounts.completionTokens.float * outputCostPerToken
        sessionTotalCost += sessionOutputCost
      
      if sessionInputCost > 0:
        message.add("  Input cost: " & formatCost(sessionInputCost) & "\n")
      if sessionOutputCost > 0:
        message.add("  Output cost: " & formatCost(sessionOutputCost) & "\n")
      if sessionTotalCost > 0:
        message.add("  Total session cost: " & formatCost(sessionTotalCost) & "\n")
      
      # Show cost breakdown
      if hasInputCost:
        let inputRate = currentModel.inputCostPerMToken.get()
        message.add("  Input rate: $" & inputRate.formatFloat(ffDecimal, 2) & " per million tokens\n")
      if hasOutputCost:
        let outputRate = currentModel.outputCostPerMToken.get()
        message.add("  Output rate: $" & outputRate.formatFloat(ffDecimal, 2) & " per million tokens\n")
      
      # Cost per message average
      if messages.len > 0 and sessionTotalCost > 0:
        let avgCostPerMessage = sessionTotalCost / messages.len.float
        message.add("  Average per message: " & formatCost(avgCostPerMessage) & "\n")
    else:
      message.add("  💡 Add cost tracking to model config:\n")
      message.add("     inputCostPerMToken = 10.0     # Example: $10 per million tokens\n")
      message.add("     outputCostPerMToken = 30.0    # Example: $30 per million tokens\n")
  
  message.add("\n💡 Use '/clear' to reset context and costs\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc themesHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show available themes
  let availableThemes = getAvailableThemes()
  let currentThemeName = getCurrentTheme().name
  
  var message = "Available themes:\n"
  for themeName in availableThemes:
    let marker = if themeName == currentThemeName: " (current)" else: ""
    message.add("  {themeName}{marker}\n".fmt)
  
  message.add("\nUse '/theme <name>' to switch themes\n")
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc themeHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Switch to a different theme or show current theme
  if args.len == 0:
    # Show current theme
    let currentTheme = getCurrentTheme()
    return CommandResult(
      success: true,
      message: fmt"Current theme: {currentTheme.name}",
      shouldExit: false,
      shouldContinue: true
    )
  
  let themeName = args[0]
  
  if setCurrentTheme(themeName):
    return CommandResult(
      success: true,
      message: fmt"Switched to theme: {themeName}",
      shouldExit: false,
      shouldContinue: true
    )
  else:
    return CommandResult(
      success: false,
      message: fmt"Theme '{themeName}' not found. Use '/themes' to see available themes.",
      shouldExit: false,
      shouldContinue: true
    )

proc markdownHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Toggle markdown rendering or show current status
  if args.len == 0:
    # Show current status
    let config = loadConfig()
    let enabled = isMarkdownEnabled(config)
    let status = if enabled: "enabled" else: "disabled"
    return CommandResult(
      success: true,
      message: fmt"Markdown rendering: {status}",
      shouldExit: false,
      shouldContinue: true
    )
  
  let action = args[0].toLower()
  case action:
  of "on", "enable", "true", "1":
    # Enable markdown (this would need config saving implementation)
    return CommandResult(
      success: true,
      message: "Markdown rendering enabled for this session",
      shouldExit: false,
      shouldContinue: true
    )
  of "off", "disable", "false", "0":
    # Disable markdown (this would need config saving implementation)
    return CommandResult(
      success: true,
      message: "Markdown rendering disabled for this session",
      shouldExit: false,
      shouldContinue: true
    )
  else:
    return CommandResult(
      success: false,
      message: "Usage: /markdown [on|off]",
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
  registerCommand("context", "Show conversation context information", "", @[], contextHandler)
  registerCommand("tokens", "Show detailed token usage information", "", @[], tokensHandler)
  registerCommand("cost", "Show session cost summary and projections", "", @[], costHandler)
  registerCommand("themes", "List available themes", "", @[], themesHandler)
  registerCommand("theme", "Switch theme or show current theme", "[name]", @[], themeHandler)
  registerCommand("markdown", "Toggle markdown rendering", "[on|off]", @["md"], markdownHandler)