## Command System for Niffler
##
## This module provides a unified command system for handling slash commands
## for the CLI interface.
##
## Features:
## - Command parsing and validation
## - Command completion and suggestions
## - Unified command execution interface
## - Extensible command registration system

import std/[strutils, strformat, tables, times, options, logging]
import ../core/[conversation_manager, config, app, database]
import ../types/[config as configTypes, messages, mode]
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
  debug(fmt"getCommandCompletions called with input='{input}', available commands: {available.len}")
  
  if input.len == 0:
    debug("Returning all available commands")
    return available
  
  result = @[]
  let searchTerm = input.toLower()
  debug(fmt"Searching for commands starting with '{searchTerm}'")
  
  # Only match command names that start with the search term
  for cmd in available:
    debug(fmt"Checking command '{cmd.name}' against '{searchTerm}'")
    if cmd.name.toLower().startsWith(searchTerm):
      debug(fmt"Match found: {cmd.name}")
      result.add(cmd)
  
  debug(fmt"Returning {result.len} completions")

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
  
  let (_, handler) = commandRegistry[command]
  return handler(args, currentModel)

# Built-in command handlers
proc helpHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  var message = """
Type '/help' for help and '/exit' or '/quit' to leave.
Press Ctrl+C to stop streaming display or exit. Ctrl-Z to suspend.
Press Shift+Tab to switch between Plan and Code mode.

Available commands:\n"""
  let commands = getAvailableCommands()
  
  for cmd in commands:
    message &= "  /{cmd.name}".fmt
    if cmd.usage.len > 0:
      message &= " {cmd.usage}".fmt
    message &= " - {cmd.description}\n".fmt
  
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


proc modelHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  if args.len == 0:
    # Show current model
    return CommandResult(
      success: true,
      message: fmt"Current model: {currentModel.nickname} ({currentModel.model})",
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
    message: fmt"Model '{modelName}' not found. Use '/model' to see available models.",
    shouldExit: false,
    shouldContinue: true
  )


proc contextHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show current conversation context information
  let messages = conversation_manager.getConversationContext()
  let estimatedTokens = estimateTokenCount(messages)
  
  var message = "Conversation Context:\n"
  message &= "  Messages in context: " & $messages.len & "\n"
  message &= "  Estimated tokens: " & $estimatedTokens & "\n"
  
  # Show breakdown by message type
  var userCount = 0
  var assistantCount = 0
  var toolCount = 0
  var toolCallCount = 0
  
  for msg in messages:
    case msg.role:
    of mrUser: inc userCount
    of mrAssistant: 
      inc assistantCount
      # Count tool calls in assistant messages
      if msg.toolCalls.isSome():
        toolCallCount += msg.toolCalls.get().len
    of mrTool: inc toolCount
    else: discard
  
  message &= "  Breakdown: " & $userCount & " user, " & $assistantCount & " assistant, " & $toolCount & " tool messages\n"
  if toolCallCount > 0:
    message &= "  Tool calls: " & $toolCallCount & "\n"
  
  if messages.len >= DEFAULT_MAX_CONTEXT_MESSAGES:
    message &= "  📝 Context is at maximum size (" & $DEFAULT_MAX_CONTEXT_MESSAGES & " messages)\n"
  
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
  message &= "  Session input tokens: " & $sessionCounts.inputTokens & "\n"
  message &= "  Session output tokens: " & $sessionCounts.outputTokens & "\n"
  message &= "  Session total tokens: " & $sessionCounts.totalTokens & "\n"
  message &= "  Model context limit: " & $currentModel.context & " tokens\n"
  
  if currentModel.context > 0 and sessionCounts.inputTokens > 0:
    let usagePercent = (sessionCounts.inputTokens * 100) div currentModel.context
    message &= "  Current context usage: " & $usagePercent & "%\n"
    
    if usagePercent > 80:
      message &= "  🚨 High context usage - consider starting a new conversation with /new\n"
    elif usagePercent > 60:
      message &= "  ⚠️  Moderate context usage\n"
  
  # Show cost information if available
  let hasInputCost = currentModel.inputCostPerMToken.isSome()
  let hasOutputCost = currentModel.outputCostPerMToken.isSome()
  
  if hasInputCost or hasOutputCost:
    message &= "\nCost Information:\n"
    
    # Calculate current session cost
    var currentCost = 0.0
    if hasInputCost and sessionCounts.inputTokens > 0:
      let inputCostPerToken = currentModel.inputCostPerMToken.get() / 1_000_000.0
      currentCost += float(sessionCounts.inputTokens) * inputCostPerToken
    if hasOutputCost and sessionCounts.outputTokens > 0:
      let outputCostPerToken = currentModel.outputCostPerMToken.get() / 1_000_000.0
      currentCost += float(sessionCounts.outputTokens) * outputCostPerToken
    
    if currentCost > 0.0:
      message &= "  Current cost: " & formatCost(currentCost) & "\n"
    
    if hasInputCost:
      let inputRate = currentModel.inputCostPerMToken.get()
      message &= "  Input cost: $" & inputRate.formatFloat(ffDecimal, 2) & " per million tokens\n"
    
    if hasOutputCost:
      let outputRate = currentModel.outputCostPerMToken.get()
      message &= "  Output cost: $" & outputRate.formatFloat(ffDecimal, 2) & " per million tokens\n"
    
    # No projections - user finds them unhelpful
  else:
    message &= "\n💡 Add inputCostPerMToken/outputCostPerMToken to model config for cost tracking\n"
  
  message &= "\n💡 Use '/new [title]' to start fresh and reduce context costs\n"
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc costHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show session cost summary with accurate model-specific breakdown
  let sessionCounts = conversation_manager.getSessionTokens()
  let messages = conversation_manager.getConversationContext()
  
  var message = "Session Cost Summary:\n"
  
  # Get global database instance
  let database = getGlobalDatabase()
  
  # Try to get accurate cost breakdown from database
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      let (totalCost, breakdown) = getConversationCostBreakdown(database, conversationId)
      
      message &= "  Session: " & $messages.len & " messages, " & $sessionCounts.totalTokens & " tokens\n"
      
      if totalCost > 0:
        message &= "  Total session cost: " & formatCost(totalCost) & "\n"
        message &= "\nCost Breakdown by Model:\n"
        
        for line in breakdown:
          message &= "  " & line & "\n"
      else:
        message &= "  No cost data available for current session\n"
        message &= "  💡 Cost tracking will begin after your next message\n"
    except Exception as e:
      error(fmt"Database error in cost handler: {e.msg}")
      message &= "  ❌ Database error: " & e.msg & "\n"
      message &= "  💡 Try restarting Niffler to reinitialize database\n"
  else:
    # Database not available - simplified message
    message &= "  Session: " & $messages.len & " messages, " & $sessionCounts.totalTokens & " tokens\n"
    message &= "  ❌ Database not available for cost tracking\n"
    message &= "  💡 Database will be automatically created when available\n"
  
  message &= "\n💡 Use '/new [title]' to start a fresh conversation\n"
  
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
      message: fmt"Theme '{themeName}' not found. Use '/theme' to see available themes.",
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

proc pasteHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle the paste command - note: linecross handles clipboard automatically via Ctrl+V
  return CommandResult(
    success: true,
    message: "Clipboard paste is available via Ctrl+V when typing. Linecross handles system clipboard integration automatically.",
    shouldExit: false,
    shouldContinue: true
  )

# Conversation Management Commands



proc newConversationHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Create a new conversation
  let database = getGlobalDatabase()
  if database == nil:
    return CommandResult(
      success: false,
      message: "Database not available for conversation management",
      shouldExit: false,
      shouldContinue: true
    )
  
  let title = if args.len > 0: args.join(" ") else: ""
  let currentMode = getCurrentMode()
  let convOpt = createConversation(database, title, currentMode, currentModel.nickname)
  
  if convOpt.isSome():
    let conv = convOpt.get()
    # Switch to the new conversation
    discard switchToConversation(database, conv.id)
    return CommandResult(
      success: true,
      message: fmt"Created and switched to new conversation: {conv.title} (ID: {conv.id})",
      shouldExit: false,
      shouldContinue: true
    )
  else:
    return CommandResult(
      success: false,
      message: "Failed to create new conversation",
      shouldExit: false,
      shouldContinue: true
    )

proc archiveHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Archive a conversation
  if args.len == 0:
    return CommandResult(
      success: false,
      message: "Usage: /archive <conversation_id>",
      shouldExit: false,
      shouldContinue: true
    )
  
  let database = getGlobalDatabase()
  if database == nil:
    return CommandResult(
      success: false,
      message: "Database not available for conversation management",
      shouldExit: false,
      shouldContinue: true
    )
  
  try:
    let conversationId = parseInt(args[0])
    if archiveConversation(database, conversationId):
      return CommandResult(
        success: true,
        message: fmt"Archived conversation ID {conversationId}",
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: fmt"Failed to archive conversation ID {conversationId}. Check that it exists.",
        shouldExit: false,
        shouldContinue: true
      )
  except ValueError:
    return CommandResult(
      success: false,
      message: "Invalid conversation ID. Use a number.",
      shouldExit: false,
      shouldContinue: true
    )

proc searchConversationsHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Search conversations by title or content
  if args.len == 0:
    return CommandResult(
      success: false,
      message: "Usage: /search <query>",
      shouldExit: false,
      shouldContinue: true
    )
  
  let database = getGlobalDatabase()
  if database == nil:
    return CommandResult(
      success: false,
      message: "Database not available for conversation management",
      shouldExit: false,
      shouldContinue: true
    )
  
  let query = args.join(" ")
  let results = searchConversations(database, query)
  
  if results.len == 0:
    return CommandResult(
      success: true,
      message: fmt"No conversations found matching '{query}'",
      shouldExit: false,
      shouldContinue: true
    )
  
  var message = fmt"Found {results.len} conversations matching '{query}':\n"
  for conv in results:
    message &= fmt"  #{conv.id}: {conv.title} - {conv.mode}/{conv.modelNickname}\n"
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc conversationInfoHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show current conversation info
  let currentSession = getCurrentSession()
  if currentSession.isNone():
    return CommandResult(
      success: true,
      message: "No active conversation",
      shouldExit: false,
      shouldContinue: true
    )
  
  let session = currentSession.get()
  let conv = session.conversation
  let info = fmt"""Current Conversation:
  ID: {conv.id}
  Title: {conv.title}
  Mode: {conv.mode}
  Model: {conv.modelNickname}
  Messages: {conv.messageCount}
  Created: {conv.created_at.format("yyyy-MM-dd HH:mm")}
  Last Activity: {conv.lastActivity.format("yyyy-MM-dd HH:mm")}
  Session Started: {session.startedAt.format("yyyy-MM-dd HH:mm")}"""
  
  return CommandResult(
    success: true,
    message: info,
    shouldExit: false,
    shouldContinue: true
  )

proc convHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Unified conversation command - list when no args, switch when args provided
  let database = getGlobalDatabase()
  if database == nil:
    return CommandResult(
      success: false,
      message: "Database not available for conversation management",
      shouldExit: false,
      shouldContinue: true
    )
  
  if args.len == 0:
    # List all conversations (like /conversations but with proper formatting)
    let conversations = listConversations(database)
    if conversations.len == 0:
      return CommandResult(
        success: true,
        message: "No conversations found. Create one with '/new [title]'",
        shouldExit: false,
        shouldContinue: true
      )
    
    var message = "Conversations:\n"
    let currentSession = getCurrentSession()
    let activeId = if currentSession.isSome(): currentSession.get().conversation.id else: -1
    
    for conv in conversations:
      let activeMarker = if conv.id == activeId: " (current)" else: ""
      let statusMarker = if conv.isActive: "" else: " [archived]"
      message &= fmt"  #{conv.id}: {conv.title} - {conv.mode}/{conv.modelNickname} ({conv.messageCount} messages){activeMarker}{statusMarker}\n"
      let c = conv.created_at.format("yyyy-MM-dd HH:mm")
      let a = conv.lastActivity.format("yyyy-MM-dd HH:mm")
      message &= fmt"    Created: {c}, Last activity: {a}\n"
    
    return CommandResult(
      success: true,
      message: message,
      shouldExit: false,
      shouldContinue: true
    )
  else:
    # Switch to conversation (like /switch)
    let input = args.join(" ")
    
    # Try to parse as integer ID first
    try:
      let conversationId = parseInt(input)
      if switchToConversation(database, conversationId):
        # Get the conversation to update currentModel
        let convOpt = getConversationById(database, conversationId)
        if convOpt.isSome():
          let conv = convOpt.get()
          # Update current model to match conversation's model
          let config = loadConfig()
          for model in config.models:
            if model.nickname == conv.modelNickname:
              currentModel = model
              break
          
          return CommandResult(
            success: true,
            message: fmt"Switched to conversation: {conv.title} (Mode: {conv.mode}, Model: {conv.modelNickname})",
            shouldExit: false,
            shouldContinue: true
          )
        else:
          return CommandResult(
            success: false,
            message: fmt"Failed to retrieve conversation details for ID {conversationId}",
            shouldExit: false,
            shouldContinue: true
          )
      else:
        return CommandResult(
          success: false,
          message: fmt"Failed to switch to conversation ID {conversationId}. Check that it exists.",
          shouldExit: false,
          shouldContinue: true
        )
    except ValueError:
      # Not a valid integer, try to find by title
      let conversations = listConversations(database)
      var matchedConv: Option[Conversation] = none(Conversation)
      
      # Look for exact title match first
      for conv in conversations:
        if conv.title.toLower() == input.toLower():
          matchedConv = some(conv)
          break
      
      # If no exact match, look for partial match
      if matchedConv.isNone():
        for conv in conversations:
          if conv.title.toLower().contains(input.toLower()):
            matchedConv = some(conv)
            break
      
      if matchedConv.isSome():
        let conv = matchedConv.get()
        if switchToConversation(database, conv.id):
          # Update current model to match conversation's model
          let config = loadConfig()
          for model in config.models:
            if model.nickname == conv.modelNickname:
              currentModel = model
              break
          
          return CommandResult(
            success: true,
            message: fmt"Switched to conversation: {conv.title} (Mode: {conv.mode}, Model: {conv.modelNickname})",
            shouldExit: false,
            shouldContinue: true
          )
        else:
          return CommandResult(
            success: false,
            message: fmt"Failed to switch to conversation: {conv.title}",
            shouldExit: false,
            shouldContinue: true
          )
      else:
        return CommandResult(
          success: false,
          message: fmt"No conversation found matching '{input}'. Use '/conv' to see all conversations.",
          shouldExit: false,
          shouldContinue: true
        )

proc initializeCommands*() =
  ## Initialize the built-in commands
  registerCommand("help", "Show help and available commands", "", @[], helpHandler)
  registerCommand("exit", "Exit Niffler", "", @["quit"], exitHandler)
  registerCommand("model", "Switch model or show current", "[name]", @[], modelHandler)
  registerCommand("context", "Show conversation context information", "", @[], contextHandler)
  registerCommand("tokens", "Show detailed token usage information", "", @[], tokensHandler)
  registerCommand("cost", "Show session cost summary and projections", "", @[], costHandler)
  registerCommand("theme", "Switch theme or show current", "[name]", @[], themeHandler)
  registerCommand("markdown", "Toggle markdown rendering", "[on|off]", @["md"], markdownHandler)
  registerCommand("paste", "Show clipboard contents", "", @[], pasteHandler)
  
  # Conversation management commands
  registerCommand("conv", "List/switch conversations", "[id|title]", @[], convHandler)
  registerCommand("new", "Create new conversation", "[title]", @[], newConversationHandler)
  registerCommand("archive", "Archive a conversation", "<id>", @[], archiveHandler)
  registerCommand("search", "Search conversations", "<query>", @[], searchConversationsHandler)
  registerCommand("info", "Show current conversation info", "", @[], conversationInfoHandler)