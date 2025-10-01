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

import std/[strutils, strformat, tables, times, options, logging, json, httpclient, sequtils]
import ../core/[conversation_manager, config, app, database, mode_state, system_prompt]
import ../types/[config as configTypes, messages, agents]
import ../tokenization/[tokenizer]
import ../tools/registry
import ../api/curlyStreaming
import ../mcp/[mcp, tools as mcpTools]
import theme
import table_utils
import nancy
# import linecross  # Used only in comments

type
  CommandResult* = object
    success*: bool
    message*: string
    shouldExit*: bool
    shouldContinue*: bool
    shouldResetUI*: bool

  CommandInfo* = object
    name*: string
    description*: string
    usage*: string
    aliases*: seq[string]

  CommandHandler* = proc(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult

var commandRegistry = initTable[string, tuple[info: CommandInfo, handler: CommandHandler]]()

proc registerCommand*(name: string, description: string, usage: string, 
                     aliases: seq[string], handler: CommandHandler) =
  ## Register a new command with its handler and aliases in the command system
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
      shouldContinue: true,
      shouldResetUI: false
    )
  
  let (_, handler) = commandRegistry[command]
  return handler(args, currentModel)

# Built-in command handlers
proc helpHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  var message = """
Type '/help' for help, '!command' for bash, and '/exit' or '/quit' to leave.

Press Ctrl+C to stop streaming display or exit. Ctrl-Z to suspend.
Press Shift+Tab to switch between Plan and Code mode.

Available commands:
"""
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
      # Update prompt to reflect new model
      # Prompt will be updated on next input cycle
      
      # Persist model change to current conversation if available
      try:
        let currentSession = getCurrentSession()
        if currentSession.isSome():
          let database = getGlobalDatabase()
          if database != nil:
            let conversationId = currentSession.get().conversation.id
            updateConversationModel(database, conversationId, model.nickname)
            debug(fmt"Persisted model change to database for conversation {conversationId}")
      except Exception as e:
        debug(fmt"Failed to persist model change to database: {e.msg}")
      
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
  ## Show current conversation context information using Nancy table
  let messages = conversation_manager.getConversationContext()
  
  var message = "Conversation Context:\n\n"
  
  # Count messages by type and use actual tokens where available, estimates elsewhere
  var userCount = 0
  var assistantCount = 0
  var toolCount = 0
  var toolCallCount = 0
  var userTokensEstimate = 0
  var assistantTokensActual = 0  # Use actual tokens for assistant messages
  var toolTokensEstimate = 0
  
  # Get model nickname for accurate token estimation and correction factor lookup
  let modelNickname = currentModel.nickname
  
  # Get actual assistant message tokens from database
  let database = getGlobalDatabase()
  var assistantActualTokens = initTable[string, int]()  # Map content hash to actual tokens
  
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      assistantActualTokens = getAssistantTokensForConversation(database, conversationId)
    except Exception as e:
      debug(fmt"Failed to get assistant token data from database: {e.msg}")
  
  for msg in messages:
    case msg.role:
    of mrUser: 
      inc userCount
      userTokensEstimate += countTokensForModel(msg.content, modelNickname)
    of mrAssistant: 
      inc assistantCount
      # Use actual tokens if available, otherwise fall back to estimate
      if assistantActualTokens.hasKey(msg.content):
        assistantTokensActual += assistantActualTokens[msg.content]
      else:
        assistantTokensActual += countTokensForModel(msg.content, modelNickname)
      
      # Count tool calls in assistant messages
      if msg.toolCalls.isSome():
        toolCallCount += msg.toolCalls.get().len
        # Add token estimate for tool calls (JSON serialized)
        for toolCall in msg.toolCalls.get():
          let toolCallJson = fmt"""{{"name": "{toolCall.function.name}", "arguments": {toolCall.function.arguments}}}"""
          assistantTokensActual += countTokensForModel(toolCallJson, modelNickname)
    of mrTool: 
      inc toolCount
      toolTokensEstimate += countTokensForModel(msg.content, modelNickname)
    else: discard
  
  # Get token data from conversation cost details (more reliable than message role breakdown)
  var totalTokens = 0
  
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      let conversationDetails = getConversationCostDetailed(database, conversationId)
      totalTokens = conversationDetails.totalInput + conversationDetails.totalOutput + conversationDetails.totalReasoning
    except Exception as e:
      debug(fmt"Failed to get conversation tokens: {e.msg}")
  
  # Get reasoning token data (from both OpenAI-style and thinking token sources)
  var reasoningTokens = 0
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      # Get OpenAI-style reasoning tokens from model_token_usage
      let reasoningStats = getConversationReasoningTokens(database, conversationId)
      reasoningTokens = reasoningStats.totalReasoning
      
      # Add XML thinking tokens from conversation_thinking_token table
      let thinkingTokens = getConversationThinkingTokens(database, conversationId)
      reasoningTokens += thinkingTokens
    except Exception as e:
      debug(fmt"Failed to get reasoning tokens: {e.msg}")

  # Create and display combined context table
  try:
    let systemPromptResult = generateSystemPromptWithTokens(getCurrentMode(), modelNickname)
    let toolSchemaTokens = countToolSchemaTokens(modelNickname)
    
    let combinedTable = formatCombinedContextTable(
      userCount, assistantCount, toolCount,
      userTokensEstimate, assistantTokensActual, toolTokensEstimate,
      reasoningTokens, systemPromptResult.tokens, toolSchemaTokens
    )
    message &= combinedTable & "\n"
    
    # Add correction factor info using model nickname (consistent with storage)
    var correctionFactorStr = ""
    if database != nil:
      let correctionFactor = getCorrectionFactorFromDB(database, modelNickname)
      if correctionFactor.isSome():
        let factor = correctionFactor.get()
        correctionFactorStr = fmt("Using correction factor {factor:.3f}")
      else:
        correctionFactorStr = "No correction factor found"
    else:
      correctionFactorStr = "No correction factor found"
    
    message &= fmt("\n💡  {correctionFactorStr} for {modelNickname} \n")
    
    # Show tool calls if any
    if toolCallCount > 0:
      message &= fmt("\n🔧 Tool calls: {toolCallCount}\n")
  
  
  except Exception as e:
    debug(fmt("Failed to calculate context breakdown: {e.msg}"))
  

  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc inspectHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Generate the HTTP JSON request that would be sent to the API
  var outputFile: string = ""
  
  # Check if user provided a filename
  if args.len > 0:
    outputFile = args[0]
  
  try:
    # Get existing conversation context without adding a new message
    var messages = conversation_manager.getConversationContext()
    messages = truncateContextIfNeeded(messages)
    
    # Insert system message at the beginning
    let (systemMsg, _) = createSystemMessageWithTokens(getCurrentMode(), currentModel.nickname)
    messages.insert(systemMsg, 0)
    
    # Get tool schemas for the request
    let toolSchemas = getAllToolSchemas()
    
    # Create the chat request using existing functions
    let chatRequest = createChatRequest(currentModel, messages, false, some(toolSchemas))
    
    # Convert to JSON using the same function as the actual API call
    let jsonRequest = toJson(chatRequest)
    
    # Pretty print the JSON
    let prettyJson = jsonRequest.pretty(indent = 2)
    
    if outputFile.len > 0:
      # Write to file
      try:
        writeFile(outputFile, prettyJson)
        return CommandResult(
          success: true,
          message: fmt"HTTP request JSON written to: {outputFile}",
          shouldExit: false,
          shouldContinue: true
        )
      except IOError as e:
        return CommandResult(
          success: false,
          message: fmt"Failed to write file: {e.msg}",
          shouldExit: false,
          shouldContinue: true
        )
    else:
      # Display in terminal
      return CommandResult(
        success: true,
        message: prettyJson,
        shouldExit: false,
        shouldContinue: true
      )
      
  except Exception as e:
    return CommandResult(
      success: false,
      message: fmt"Failed to generate request: {e.msg}",
      shouldExit: false,
      shouldContinue: true
    )


proc costHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show session and conversation cost breakdown with detailed token analysis
  var message = ""
  
  # Get global database instance
  let database = getGlobalDatabase()
  
  if database != nil:
    try:
      # Get session costs (since app start)
      let appStartTime = getAppStartTime()
      let sessionCosts = getSessionCostBreakdown(database, appStartTime)
      
      message &= "\nSession (since app start):\n"
      if sessionCosts.totalCost > 0:
        message &= fmt"  Input: {sessionCosts.inputTokens} tokens (${sessionCosts.inputCost:.4f})"
        message &= "\n"
        message &= fmt"  Output: {sessionCosts.outputTokens} tokens (${sessionCosts.outputCost:.4f})"
        message &= "\n"
        if sessionCosts.reasoningTokens > 0:
          message &= fmt"  Reasoning: {sessionCosts.reasoningTokens} tokens (${sessionCosts.reasoningCost:.4f})"
          message &= "\n"
        message &= fmt"  Total: {sessionCosts.inputTokens + sessionCosts.outputTokens + sessionCosts.reasoningTokens} tokens (${sessionCosts.totalCost:.4f})"
        message &= "\n"
      else:
        message &= "  No session costs recorded\n"
      
      # Get conversation costs (current conversation only) with detailed breakdown
      let conversationId = getCurrentConversationId().int
      let conversationDetails = getConversationCostDetailed(database, conversationId)
      
      message &= "\nCurrent Conversation:\n"
      if conversationDetails.totalCost > 0:
        let costTable = formatCostBreakdownTable(
          conversationDetails.rows,
          conversationDetails.totalInput, 
          conversationDetails.totalOutput, 
          conversationDetails.totalReasoning,
          conversationDetails.totalInputCost, 
          conversationDetails.totalOutputCost, 
          conversationDetails.totalReasoningCost,
          conversationDetails.totalCost
        )
        message &= costTable & "\n"
        
        # Add input/output ratio analysis
        if conversationDetails.totalInput > 0 and conversationDetails.totalOutput > 0:
          let ratio = conversationDetails.totalInput.float / conversationDetails.totalOutput.float
          message &= fmt("\n📊 Input/Output Ratio: {ratio:.2f}x")
          if conversationDetails.totalReasoning > 0:
            let reasoningPercent = conversationDetails.totalReasoning.float / conversationDetails.totalOutput.float * 100
            message &= fmt" (reasoning: {reasoningPercent:.1f}% of output)"
          message &= "\n"
      else:
        message &= "  No conversation costs recorded\n"
      
    except Exception as e:
      error(fmt"Database error in cost handler: {e.msg}")
      message &= "  ❌ Database error: " & e.msg & "\n"
      message &= "  💡 Try restarting Niffler to reinitialize database\n"
  else:
    # Database not available
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
    let currentTheme = currentTheme
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
      shouldContinue: true,
      shouldResetUI: true
    )
  else:
    return CommandResult(
      success: false,
      message: "Failed to create new conversation",
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: false
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

proc unarchiveHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Unarchive a conversation
  if args.len == 0:
    return CommandResult(
      success: false,
      message: "Usage: /unarchive <conversation_id>",
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
    if unarchiveConversation(database, conversationId):
      return CommandResult(
        success: true,
        message: fmt"Unarchived conversation ID {conversationId}",
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: fmt"Failed to unarchive conversation ID {conversationId}. Check that it exists and is archived.",
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
  
  # Use Nancy table for search results  
  let currentSession = getCurrentSession()
  let activeId = if currentSession.isSome(): currentSession.get().conversation.id else: -1
  let searchHeader = fmt("Found {results.len} conversations matching '{query}':\n")
  let tableOutput = formatConversationTable(results, activeId, showArchived = true)
  
  return CommandResult(
    success: true,
    message: searchHeader & tableOutput,
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
  
  # Get fresh conversation data from database for accurate message count
  let backend = getGlobalDatabase()
  let freshConvOpt = if backend != nil: getConversationById(backend, conv.id) else: none(Conversation)
  let actualMessageCount = if freshConvOpt.isSome(): freshConvOpt.get().messageCount else: conv.messageCount
  
  let info = fmt"""Current Conversation:
  ID: {conv.id}
  Title: {conv.title}
  Mode: {getCurrentMode()}
  Model: {conv.modelNickname}
  Messages: {actualMessageCount}
  Created: {conv.created_at.format("yyyy-MM-dd HH:mm")}
  Last Activity: {conv.lastActivity.format("yyyy-MM-dd HH:mm")}
  Session Started: {session.startedAt.format("yyyy-MM-dd HH:mm")}"""
  
  return CommandResult(
    success: true,
    message: info,
    shouldExit: false,
    shouldContinue: true
  )

proc modelsHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## List available models from the API endpoint
  try:
    let client = newHttpClient()
    let apiKey = currentModel.apiKey.get("")
    client.headers = newHttpHeaders({
      "Authorization": "Bearer " & apiKey,
      "Accept": "application/json",
      "User-Agent": "Niffler"
    })
    
    let endpoint = currentModel.baseUrl & "/models"
    let response = client.request(endpoint, HttpGet)
    let jsonResponse = parseJson(response.body)
    
    client.close()
    
    # Try to format as a table, fall back to JSON if needed
    let formattedOutput = formatApiModelsTable(jsonResponse)
    
    return CommandResult(
      success: true,
      message: fmt("Models from {endpoint}:\n{formattedOutput}"),
      shouldExit: false,
      shouldContinue: true
    )
  except Exception as e:
    return CommandResult(
      success: false,
      message: fmt"Error fetching models: {e.msg}",
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
    # List active conversations only (archived ones are hidden)
    let conversations = listActiveConversations(database)
    let currentSession = getCurrentSession()
    let activeId = if currentSession.isSome(): currentSession.get().conversation.id else: -1
    
    let tableOutput = formatConversationTable(conversations, activeId, showArchived = false)
    
    return CommandResult(
      success: true,
      message: tableOutput,
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
          
          # Restore mode from conversation with protection
          restoreModeWithProtection(conv.mode)
          
          return CommandResult(
            success: true,
            message: fmt"Switched to conversation: {conv.title}",
            shouldExit: false,
            shouldContinue: true,
            shouldResetUI: true
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
          
          # Restore mode from conversation with protection
          restoreModeWithProtection(conv.mode)
          
          return CommandResult(
            success: true,
            message: fmt"Switched to conversation: {conv.title}",
            shouldExit: false,
            shouldContinue: true,
            shouldResetUI: true
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

proc formatMcpStatus(status: string): string =
  ## Convert MCP status enum to user-friendly string
  case status
  of "mssStopped": "Stopped"
  of "mssStarting": "Starting"
  of "mssRunning": "Running"
  of "mssStopping": "Stopping"
  of "mssError": "Error"
  else: status

proc agentHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle /agent command for showing agent definitions
  let agentsDir = getAgentsDir()
  let agents = loadAgentDefinitions(agentsDir)
  let knownTools = getAllToolNames()

  if args.len == 0:
    # Show table of all agents
    if agents.len == 0:
      return CommandResult(
        success: true,
        message: fmt("No agents found in {agentsDir}\nAgents will be created on next startup."),
        shouldExit: false,
        shouldContinue: true
      )

    var table: TerminalTable
    table.add(bold("Name"), bold("Description"), bold("Tools"), bold("Status"))

    for agent in agents:
      let status = validateAgentDefinition(agent, knownTools)
      let statusIcon = if status.valid:
                         green("✓")
                       elif status.unknownTools.len > 0:
                         yellow("⚠")
                       else:
                         red("✗")
      table.add(
        agent.name,
        truncate(agent.description, 50),
        $agent.allowedTools.len,
        statusIcon
      )

    let tableOutput = renderTableToString(table, maxWidth = 120)

    return CommandResult(
      success: true,
      message: tableOutput & "\n\nUse /agent <name> to view details",
      shouldExit: false,
      shouldContinue: true
    )
  else:
    # Show specific agent details
    let agentName = args[0]
    let agentOpt = agents.filterIt(it.name == agentName)

    if agentOpt.len == 0:
      return CommandResult(
        success: false,
        message: fmt("Agent '{agentName}' not found. Use /agent to list all agents."),
        shouldExit: false,
        shouldContinue: true
      )

    let agent = agentOpt[0]
    let status = validateAgentDefinition(agent, knownTools)

    var message = fmt("┌─ {agent.name} ") & "─".repeat(max(0, 70 - agent.name.len - 3)) & "┐\n"
    message &= fmt("│ Description: {agent.description}\n")
    message &= "│\n"
    message &= fmt("│ Allowed Tools: {agent.allowedTools.join(\", \")}\n")
    message &= "│\n"

    if status.valid:
      if status.unknownTools.len > 0:
        message &= fmt("│ Status: ⚠ Valid (unknown tools: {status.unknownTools.join(\", \")})\n")
      else:
        message &= "│ Status: ✓ Valid\n"
    else:
      message &= fmt("│ Status: ✗ {status.error}\n")

    message &= "│\n"
    message &= fmt("│ File: {agent.filePath}\n")
    message &= "└" & "─".repeat(70) & "┘"

    return CommandResult(
      success: true,
      message: message,
      shouldExit: false,
      shouldContinue: true
    )

proc mcpHandler(args: seq[string], currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle /mcp command for showing MCP server status
  {.gcsafe.}:
    if args.len == 0 or args[0] == "status":
      # Show status of all MCP servers
      let serverList = mcp.listMcpServers()
      if serverList.len == 0:
        return CommandResult(
          success: true,
          message: "No MCP servers configured",
          shouldExit: false,
          shouldContinue: true,
          shouldResetUI: false
        )

      let allServersInfo = mcp.getMcpAllServersInfo()
      if allServersInfo == nil or allServersInfo.kind != JArray:
        return CommandResult(
          success: false,
          message: "MCP server information not available",
          shouldExit: false,
          shouldContinue: true,
          shouldResetUI: false
        )

      var statusLines: seq[string] = @[]
      statusLines.add(fmt"MCP Servers ({serverList.len} configured):")
      statusLines.add("")

      for infoNode in allServersInfo:
        let serverName = infoNode["name"].getStr()
        let info = infoNode
        let status = info["status"].getStr()
        let errorCount = info["errorCount"].getInt()
        let restartCount = info["restartCount"].getInt()
        let lastActivity = info["lastActivitySeconds"].getInt()
        let friendlyStatus = formatMcpStatus(status)

        statusLines.add(fmt"  {serverName}:")
        statusLines.add(fmt"    Status: {friendlyStatus}")
        statusLines.add(fmt"    Errors: {errorCount}")
        statusLines.add(fmt"    Restarts: {restartCount}")
        statusLines.add(fmt"    Last Activity: {lastActivity}s ago")
        statusLines.add("")

      # Show MCP tools
      let toolCount = mcpTools.getMcpToolsCount()
      statusLines.add(fmt("MCP Tools: {toolCount} available"))

      if toolCount > 0:
        statusLines.add("")
        let toolNames = mcpTools.getMcpToolNames()
        for toolName in toolNames:
          let toolInfo = mcpTools.getMcpToolInfo(toolName)
          if toolInfo.hasKey("serverName") and toolInfo.hasKey("description"):
            let server = toolInfo["serverName"].getStr()
            let desc = toolInfo["description"].getStr()
            statusLines.add(fmt"  {toolName} ({server}) - {desc}")

      return CommandResult(
        success: true,
        message: statusLines.join("\n"),
        shouldExit: false,
        shouldContinue: true,
        shouldResetUI: false
      )
    else:
      return CommandResult(
        success: false,
        message: "Usage: /mcp [status]",
        shouldExit: false,
        shouldContinue: true,
        shouldResetUI: false
      )

proc initializeCommands*() =
  ## Initialize the built-in commands
  registerCommand("help", "Show help and available commands", "", @[], helpHandler)
  registerCommand("exit", "Exit Niffler", "", @["quit"], exitHandler)
  registerCommand("model", "Switch model or show current", "[name]", @[], modelHandler)
  registerCommand("context", "Show conversation context information", "", @[], contextHandler)
  registerCommand("inspect", "Generate HTTP JSON request for API inspection", "[filename]", @[], inspectHandler)
  registerCommand("cost", "Show session cost summary and projections", "", @[], costHandler)
  registerCommand("theme", "Switch theme or show current", "[name]", @[], themeHandler)
  registerCommand("markdown", "Toggle markdown rendering", "[on|off]", @["md"], markdownHandler)
  registerCommand("mcp", "Show MCP server status and tools", "[status]", @[], mcpHandler)
  registerCommand("agent", "List/view agent definitions", "[name]", @[], agentHandler)

  # Conversation management commands
  registerCommand("conv", "List/switch conversations", "[id|title]", @[], convHandler)
  registerCommand("new", "Create new conversation", "[title]", @[], newConversationHandler)
  registerCommand("archive", "Archive a conversation", "<id>", @[], archiveHandler)
  registerCommand("unarchive", "Unarchive a conversation", "<id>", @[], unarchiveHandler)
  registerCommand("search", "Search conversations", "<query>", @[], searchConversationsHandler)
  registerCommand("info", "Show current conversation info", "", @[], conversationInfoHandler)
  registerCommand("models", "List available models from API endpoint", "", @[], modelsHandler)