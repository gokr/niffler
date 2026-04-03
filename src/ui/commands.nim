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

import std/[strutils, strformat, tables, times, options, logging, json, httpclient, sequtils, osproc]
import ../actions/[registry as actionRegistry, types as actionTypes]
import ../actions/runtime as actionRuntime
import ../core/[conversation_manager, config, app, database, mode_state, system_prompt, session, condense, db_config]
import ../core/skills_discovery
import ../core/context_assembly
import ../types/[config as configTypes, messages, mode, skills]
import ../tokenization/[tokenizer]
import ../tools/registry
import ../tools/skill
import ../api/curlyStreaming
import ../mcp/[mcp, tools as mcpTools]
import theme
import table_utils
# import linecross  # Used only in comments

type
  CommandCategory* = enum
    ccGlobal = "global"    ## Commands that run in master niffler only
    ccAgent = "agent"      ## Commands that run in agent context

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
    category*: CommandCategory

  CommandHandler* = proc(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult

var commandRegistry = initTable[string, tuple[info: CommandInfo, handler: CommandHandler]]()

proc toCommandResult(actionResult: actionTypes.ActionResult): CommandResult =
  CommandResult(
    success: actionResult.success,
    message: actionResult.message,
    shouldExit: actionResult.shouldExit,
    shouldContinue: actionResult.shouldContinue,
    shouldResetUI: actionResult.shouldResetUI
  )

proc toActionResult(commandResult: CommandResult): actionTypes.ActionResult =
  actionTypes.ActionResult(
    success: commandResult.success,
    message: commandResult.message,
    shouldExit: commandResult.shouldExit,
    shouldContinue: commandResult.shouldContinue,
    shouldResetUI: commandResult.shouldResetUI
  )

proc registerCommand*(name: string, description: string, usage: string,
                     aliases: seq[string], handler: CommandHandler,
                     category: CommandCategory = ccGlobal) =
  ## Register a new command with its handler and aliases in the command system
  let info = CommandInfo(
    name: name,
    description: description,
    usage: usage,
    aliases: aliases,
    category: category
  )
  commandRegistry[name] = (info, handler)

  # Register aliases
  for alias in aliases:
    commandRegistry[alias] = (info, handler)

proc registerCommandAction(name: string, description: string, usage: string,
                          aliases: seq[string], handler: CommandHandler,
                          category: CommandCategory, actionId: string,
                          commandPattern: string, surfaces: set[actionTypes.ActionSurface],
                          routableToAgent: bool = false,
                          toolName: Option[string] = none(string),
                          agentCapabilities: set[actionTypes.ActionCapability] = {},
                          showInHelp: bool = true,
                          localOnly: bool = false) =
  ## Register a command and its corresponding action metadata
  registerCommand(name, description, usage, aliases, handler, category)
  actionRegistry.registerAction(actionTypes.ActionDefinition(
    id: actionId,
    description: description,
    commandPattern: commandPattern,
    aliases: aliases,
    surfaces: surfaces,
    routableToAgent: routableToAgent,
    toolName: toolName,
    agentCapabilities: agentCapabilities,
    showInHelp: showInHelp,
    localOnly: localOnly
  ))

proc registerActionOnly(actionId: string, description: string, commandPattern: string,
                       surfaces: set[actionTypes.ActionSurface],
                       handler: actionTypes.ActionHandler,
                       routableToAgent: bool = false,
                       toolName: Option[string] = none(string),
                       agentCapabilities: set[actionTypes.ActionCapability] = {},
                       showInHelp: bool = true,
                       localOnly: bool = false) =
  ## Register metadata and executor for non-top-level action commands
  actionRegistry.registerAction(actionTypes.ActionDefinition(
    id: actionId,
    description: description,
    commandPattern: commandPattern,
    aliases: @[],
    surfaces: surfaces,
    routableToAgent: routableToAgent,
    toolName: toolName,
    agentCapabilities: agentCapabilities,
    showInHelp: showInHelp,
    localOnly: localOnly
  ), handler)

proc getAvailableCommands*(): seq[CommandInfo] =
  ## Get list of all available commands (excluding aliases)
  result = @[]
  var seen = initTable[string, bool]()

  for name, (info, handler) in commandRegistry:
    if not seen.hasKey(info.name):
      result.add(info)
      seen[info.name] = true

proc getCommandsByCategory*(category: CommandCategory): seq[CommandInfo] =
  ## Get list of commands filtered by category (excluding aliases)
  result = @[]
  var seen = initTable[string, bool]()

  for name, (info, handler) in commandRegistry:
    if not seen.hasKey(info.name) and info.category == category:
      result.add(info)
      seen[info.name] = true

proc getCommandCategory*(commandName: string): Option[CommandCategory] =
  ## Get the category of a command by name
  if commandRegistry.hasKey(commandName):
    return some(commandRegistry[commandName].info.category)
  return none(CommandCategory)

proc isAgentCommand*(commandName: string): bool =
  ## Check if a command is an agent command
  let cat = getCommandCategory(commandName)
  result = cat.isSome() and cat.get() == ccAgent

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
                    session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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
  return handler(args, session, currentModel)

proc padHelpName(name: string, width: int): string =
  if name.len >= width:
    return name
  name & repeat(' ', width - name.len)

proc renderHelpEntries(entries: seq[tuple[name: string, description: string]]): string =
  if entries.len == 0:
    return ""

  var width = 0
  for entry in entries:
    width = max(width, entry.name.len)

  let paddedWidth = min(width + 2, 44)
  for entry in entries:
    if entry.name.len >= paddedWidth:
      result &= "  " & entry.name & "\n"
      result &= repeat(' ', paddedWidth + 2) & entry.description & "\n"
    else:
      result &= "  " & padHelpName(entry.name, paddedWidth) & entry.description & "\n"

proc buildToolHelpEntries(actions: seq[actionTypes.ActionDefinition]): seq[tuple[name: string, description: string]] =
  var grouped = initOrderedTable[string, seq[actionTypes.ActionDefinition]]()

  for action in actions:
    let toolName = action.toolName.get()
    if toolName notin grouped:
      grouped[toolName] = @[]
    grouped[toolName].add(action)

  for toolName, groupedActions in grouped:
    var descriptions: seq[string] = @[]
    var capabilities: seq[string] = @[]

    for action in groupedActions:
      descriptions.add(action.description)
      for capability in action.agentCapabilities:
        let formatted = actionRegistry.formatActionCapability(capability)
        if formatted notin capabilities:
          capabilities.add(formatted)

    let summary = if groupedActions.len == 1:
      descriptions[0]
    else:
      let covered = groupedActions.mapIt("/" & it.commandPattern).join(", ")
      fmt("Covers {covered}.")

    let capabilitySuffix = if capabilities.len > 0:
      " Requires: " & capabilities.join(", ").replace("_", "\\_")
    else:
      ""

    result.add(("`" & toolName & "`", summary & capabilitySuffix))

# Built-in command handlers
proc helpHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  var message = """
Type '/help' for help, '!command' for bash, and '/exit' or '/quit' to leave.
Use '@agent prompt' to send to an agent, or '/focus agent' to set default.
Use '/new <title>' to create a new conversation (routes to focused agent).
Use '/plan' or '/code' to switch modes.

  Press Ctrl+C to cancel streaming or exit.

"""
  let masterActions = actionRegistry.getMasterCliActions()
  let routedActions = actionRegistry.getRoutableAgentActions()
  let toolActions = actionRegistry.getToolCallableActions()

  let masterOnlyActions = masterActions.filterIt(it.toolName.isNone())
  let masterToolActions = masterActions.filterIt(it.toolName.isSome())

  let masterOnlyEntries = masterOnlyActions.mapIt(("/" & it.commandPattern, it.description))
  let masterToolEntries = masterToolActions.mapIt(("/" & it.commandPattern, it.description))
  let routedEntries = routedActions.mapIt(("/" & it.commandPattern, it.description))
  let toolEntries = buildToolHelpEntries(toolActions)

  if masterOnlyEntries.len > 0:
    message &= formatWithStyle("Master-Only Commands:", currentTheme.header2) & "\n"
    message &= renderHelpEntries(masterOnlyEntries)

  if masterToolEntries.len > 0:
    message &= "\n" & formatWithStyle("Master Actions:", currentTheme.header2) & "\n"
    message &= renderHelpEntries(masterToolEntries)

  if routedEntries.len > 0:
    message &= "\n" & formatWithStyle("Agent Commands:", currentTheme.header2) & "\n"
    message &= "  Route with `@agent` or `/focus`.\n"
    message &= renderHelpEntries(routedEntries)

  if toolEntries.len > 0:
    message &= "\n" & formatWithStyle("Agent-Callable Tools:", currentTheme.header2) & "\n"
    message &= renderHelpEntries(toolEntries)

  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc exitHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  return CommandResult(
    success: true,
    message: "Goodbye!",
    shouldExit: true,
    shouldContinue: false
  )


proc modelHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

            # Update the in-memory conversation object to reflect the change
            currentSession.get().conversation.modelNickname = model.nickname
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


proc contextHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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
  
  debug("Getting conversation cost details...")
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      let conversationDetails = getConversationCostDetailed(database, conversationId)
      totalTokens = conversationDetails.totalInput + conversationDetails.totalOutput + conversationDetails.totalReasoning
      debug(fmt"Got conversation cost details: {totalTokens} total tokens")
    except Exception as e:
      debug(fmt"Failed to get conversation tokens: {e.msg}")
  
  # Get reasoning token data (from both OpenAI-style and thinking token sources)
  var reasoningTokens = 0
  debug("Getting reasoning tokens...")
  if database != nil:
    try:
      let conversationId = getCurrentConversationId().int
      # Get OpenAI-style reasoning tokens from model_token_usage
      let reasoningStats = getConversationReasoningTokens(database, conversationId)
      reasoningTokens = reasoningStats.totalReasoning
      debug(fmt"Got reasoning tokens: {reasoningTokens}")
      
      # Add XML thinking tokens from conversation_thinking_token table
      debug("Getting thinking tokens from DB...")
      let thinkingTokens = getConversationThinkingTokens(database, conversationId)
      reasoningTokens += thinkingTokens
      debug(fmt"Got thinking tokens: {thinkingTokens}, total: {reasoningTokens}")
    except Exception as e:
      debug(fmt"Failed to get reasoning tokens: {e.msg}")

  # Create and display combined context table
  debug("Generating context table...")
  try:
    debug("Creating session...")
    let sess = initSession()
    debug("Generating system prompt with tokens...")
    let systemPromptResult = generateSystemPromptWithTokens(getCurrentMode(), sess, modelNickname)
    debug(fmt"System prompt generated: {systemPromptResult.tokens.total} tokens")
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

proc inspectHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Generate the HTTP JSON request that would be sent to the API
  var outputFile: string = ""
  var section: string = ""
  let validSections = ["messages", "tools", "model", "system"]
  
  # Support `/inspect <section>` to show only a specific part of the request
  # while keeping `/inspect <filename>` as the existing file output behavior.
  if args.len > 0:
    let firstArg = args[0].toLowerAscii()
    if firstArg in validSections:
      section = firstArg
      if args.len > 1:
        outputFile = args[1]
    else:
      outputFile = args[0]
  
  try:
    # Get existing conversation context without adding a new message
    var messages = conversation_manager.getConversationContext()
    messages = truncateContextIfNeeded(messages)

    # Insert system message at the beginning
    let sess = initSession()
    let (systemMsg, _) = createSystemMessageWithTokens(getCurrentMode(), sess, currentModel.nickname)
    messages.insert(systemMsg, 0)
    
    # Get tool schemas for the request
    let toolSchemas = getAllToolSchemas()
    
    # Create the chat request using existing functions
    let chatRequest = createChatRequest(currentModel, messages, false, some(toolSchemas))
    
    # Convert to JSON using the same function as the actual API call
    let jsonRequest = toJson(chatRequest)
    
    let outputJson =
      if section == "messages":
        if jsonRequest.hasKey("messages"):
          jsonRequest["messages"]
        else:
          return CommandResult(
            success: false,
            message: "Generated request does not contain a messages field",
            shouldExit: false,
            shouldContinue: true
          )
      elif section == "tools":
        if jsonRequest.hasKey("tools"):
          jsonRequest["tools"]
        else:
          return CommandResult(
            success: false,
            message: "Generated request does not contain a tools field",
            shouldExit: false,
            shouldContinue: true
          )
      elif section == "model":
        if jsonRequest.hasKey("model"):
          jsonRequest["model"]
        else:
          return CommandResult(
            success: false,
            message: "Generated request does not contain a model field",
            shouldExit: false,
            shouldContinue: true
          )
      elif section == "system":
        if jsonRequest.hasKey("messages"):
          var systemMessages = newJArray()
          for msg in jsonRequest["messages"]:
            if msg.kind == JObject and msg.hasKey("role") and msg["role"].kind == JString and msg["role"].getStr() == "system":
              systemMessages.add(msg)
          systemMessages
        else:
          return CommandResult(
            success: false,
            message: "Generated request does not contain a messages field",
            shouldExit: false,
            shouldContinue: true
          )
      else:
        jsonRequest

    # Pretty print the JSON
    let prettyJson = outputJson.pretty(indent = 2)
    
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

proc condenseHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Condense current conversation by creating a new conversation with LLM-generated summary
  var strategy = csLlmSummary

  # Parse strategy argument if provided
  if args.len > 0:
    let strategyStr = args[0].toLowerAscii()
    case strategyStr:
    of "llm", "llm_summary", "llm-summary":
      strategy = csLlmSummary
    of "truncate":
      return CommandResult(
        success: false,
        message: "Truncate strategy not yet implemented",
        shouldExit: false,
        shouldContinue: true
      )
    of "smart", "smart_window", "smart-window":
      return CommandResult(
        success: false,
        message: "Smart window strategy not yet implemented",
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: fmt"Unknown condensation strategy: {args[0]}. Use: llm_summary (default), truncate, or smart_window",
        shouldExit: false,
        shouldContinue: true
      )

  try:
    # Get current conversation info
    let currentConvId = getCurrentConversationId()
    if currentConvId <= 0:
      return CommandResult(
        success: false,
        message: "No active conversation to condense",
        shouldExit: false,
        shouldContinue: true
      )

    # Get message count for progress display
    let messageCount = getConversationContext().len
    if messageCount == 0:
      return CommandResult(
        success: false,
        message: "Cannot condense empty conversation",
        shouldExit: false,
        shouldContinue: true
      )

    info(fmt("Condensing conversation {currentConvId} ({messageCount} messages) using {strategy} strategy..."))

    # Get database backend
    let backend = getGlobalDatabase()
    if backend == nil:
      return CommandResult(
        success: false,
        message: "Database not available",
        shouldExit: false,
        shouldContinue: true
      )

    # Create condensed conversation
    let condensationResult = createCondensedConversation(backend, strategy, currentModel)

    if condensationResult.success:
      var message = fmt"""Conversation condensed successfully!

Original conversation: {currentConvId} ({condensationResult.originalMessageCount} messages)
New conversation: {condensationResult.newConversationId}
Strategy: {strategy}

Summary length: {condensationResult.summary.len} characters

The conversation has been switched to the new condensed conversation.
You can return to the original with: /switch {currentConvId}

Summary (first 500 chars):
{condensationResult.summary[0..min(499, condensationResult.summary.len-1)]}"""

      if condensationResult.summary.len > 500:
        message &= "\n..."

      return CommandResult(
        success: true,
        message: message,
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: fmt"Failed to condense conversation: {condensationResult.errorMessage}",
        shouldExit: false,
        shouldContinue: true
      )

  except Exception as e:
    return CommandResult(
      success: false,
      message: fmt"Error condensing conversation: {e.msg}",
      shouldExit: false,
      shouldContinue: true
    )


proc costHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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


proc themeHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc markdownHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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



proc newConversationHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc archiveHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc unarchiveHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc searchConversationsHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc conversationInfoHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc modelsHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc convHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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

proc mcpHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult
proc configHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult

proc agentListAction(args: seq[string], session: var Session,
                    currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard args
  discard currentModel
  result = actionRuntime.renderAgentDefinitionList(session)

proc agentShowAction(args: seq[string], session: var Session,
                    currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard currentModel
  if args.len < 1:
    return actionTypes.ActionResult(success: false, message: "Usage: /agent show <name>", shouldExit: false, shouldContinue: true)
  result = actionRuntime.renderAgentDefinitionDetails(session, args[0])

proc agentRunningAction(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard args
  discard session
  discard currentModel
  result = actionRuntime.renderRunningAgents()

proc agentStartAction(args: seq[string], session: var Session,
                     currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard session
  discard currentModel
  if args.len < 1:
    return actionTypes.ActionResult(success: false, message: "Usage: /agent start <name> [--nick=<nick>] [--model=<model>]", shouldExit: false, shouldContinue: true)

  let agentName = args[0]
  var nick = ""
  var model = ""
  for arg in args[1..^1]:
    if arg.startsWith("--nick="):
      nick = arg[7..^1]
    elif arg.startsWith("--model="):
      model = arg[8..^1]
    else:
      return actionTypes.ActionResult(success: false, message: fmt("Unknown option '{arg}'. Use --nick= or --model="), shouldExit: false, shouldContinue: true)

  try:
    return actionRuntime.startAgentInstance(agentName, nick, model)
  except Exception as e:
    return actionTypes.ActionResult(success: false, message: fmt("Failed to start agent: {e.msg}"), shouldExit: false, shouldContinue: true)

proc agentStopAction(args: seq[string], session: var Session,
                    currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard session
  discard currentModel
  if args.len < 1:
    return actionTypes.ActionResult(success: false, message: "Usage: /agent stop <routing-name>", shouldExit: false, shouldContinue: true)

  let routingName = args[0]
  return actionRuntime.stopAgentInstance(routingName)

proc conversationNewAction(args: seq[string], session: var Session,
                          currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(newConversationHandler(args, session, currentModel))

proc conversationArchiveAction(args: seq[string], session: var Session,
                              currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(archiveHandler(args, session, currentModel))

proc conversationUnarchiveAction(args: seq[string], session: var Session,
                                currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(unarchiveHandler(args, session, currentModel))

proc conversationInfoAction(args: seq[string], session: var Session,
                           currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(conversationInfoHandler(args, session, currentModel))

proc conversationSwitchAction(args: seq[string], session: var Session,
                             currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(convHandler(args, session, currentModel))

proc taskDispatchAction(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  discard session
  discard currentModel
  if args.len < 2:
    return actionTypes.ActionResult(success: false, message: "Usage: task_dispatch <target> <description>", shouldExit: false, shouldContinue: true)

  let target = args[0]
  let description = args[1..^1].join(" ")
  return actionRuntime.dispatchTaskToAgent(target, description)

proc newConversationActionHandler(args: seq[string], session: var Session,
                                 currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.new", args, session, currentModel))

proc archiveActionHandler(args: seq[string], session: var Session,
                         currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.archive", args, session, currentModel))

proc unarchiveActionHandler(args: seq[string], session: var Session,
                           currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.unarchive", args, session, currentModel))

proc conversationInfoActionHandler(args: seq[string], session: var Session,
                                  currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.info", args, session, currentModel))

proc conversationSwitchActionHandler(args: seq[string], session: var Session,
                                    currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.switch", args, session, currentModel))

proc focusPlaceholder(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult
proc taskHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult
proc planHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult
proc codeHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult

proc costAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(costHandler(args, session, currentModel))

proc themeAction(args: seq[string], session: var Session,
                currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(themeHandler(args, session, currentModel))

proc markdownAction(args: seq[string], session: var Session,
                   currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(markdownHandler(args, session, currentModel))

proc modelsAction(args: seq[string], session: var Session,
                 currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(modelsHandler(args, session, currentModel))

proc mcpAction(args: seq[string], session: var Session,
              currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(mcpHandler(args, session, currentModel))

proc configAction(args: seq[string], session: var Session,
                 currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(configHandler(args, session, currentModel))

proc costActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.cost", args, session, currentModel))

proc themeActionHandler(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.theme", args, session, currentModel))

proc markdownActionHandler(args: seq[string], session: var Session,
                          currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.markdown", args, session, currentModel))

proc modelsActionHandler(args: seq[string], session: var Session,
                        currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.models", args, session, currentModel))

proc mcpActionHandler(args: seq[string], session: var Session,
                     currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.mcp", args, session, currentModel))

proc configActionHandler(args: seq[string], session: var Session,
                        currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.config", args, session, currentModel))

proc exitAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(exitHandler(args, session, currentModel))

proc focusAction(args: seq[string], session: var Session,
                currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(focusPlaceholder(args, session, currentModel))

proc modelAction(args: seq[string], session: var Session,
                currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(modelHandler(args, session, currentModel))

proc contextAction(args: seq[string], session: var Session,
                  currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(contextHandler(args, session, currentModel))

proc inspectAction(args: seq[string], session: var Session,
                  currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(inspectHandler(args, session, currentModel))

proc condenseAction(args: seq[string], session: var Session,
                   currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(condenseHandler(args, session, currentModel))

proc planAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(planHandler(args, session, currentModel))

proc codeAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(codeHandler(args, session, currentModel))

proc exitActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.exit", args, session, currentModel))

proc focusActionHandler(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.focus", args, session, currentModel))

proc modelActionHandler(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.model", args, session, currentModel))

proc contextActionHandler(args: seq[string], session: var Session,
                         currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.context", args, session, currentModel))

proc inspectActionHandler(args: seq[string], session: var Session,
                         currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.inspect", args, session, currentModel))

proc condenseActionHandler(args: seq[string], session: var Session,
                          currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.condense", args, session, currentModel))

proc planActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.plan", args, session, currentModel))

proc codeActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("agent.code", args, session, currentModel))

proc helpAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(helpHandler(args, session, currentModel))

proc searchAction(args: seq[string], session: var Session,
                 currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(searchConversationsHandler(args, session, currentModel))

proc taskAction(args: seq[string], session: var Session,
               currentModel: var configTypes.ModelConfig): actionTypes.ActionResult =
  result = toActionResult(taskHandler(args, session, currentModel))

proc helpActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("system.help", args, session, currentModel))

proc searchActionHandler(args: seq[string], session: var Session,
                        currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("conversation.search", args, session, currentModel))

proc taskActionHandler(args: seq[string], session: var Session,
                      currentModel: var configTypes.ModelConfig): CommandResult =
  toCommandResult(actionRegistry.executeAction("task.dispatch", args, session, currentModel))

proc agentHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle /agent subcommands for definitions and running agents
  if args.len == 0:
    return CommandResult(
      success: true,
      message: """Agent commands:

  /agent list
  /agent show <name>
  /agent running
  /agent start <name> [--nick=<nick>] [--model=<model>]
  /agent stop <routing-name>

Shorthand:
  /agent <name>        Show definition details

Use @name to route a prompt to a running agent.""",
      shouldExit: false,
      shouldContinue: true
    )

  let subcommand = args[0].toLowerAscii()
  case subcommand
  of "list":
    return toCommandResult(actionRegistry.executeAction("agent.listDefinitions", @[], session, currentModel))
  of "show":
    return toCommandResult(actionRegistry.executeAction("agent.showDefinition", if args.len > 1: @[args[1]] else: @[], session, currentModel))
  of "running":
    return toCommandResult(actionRegistry.executeAction("agent.listRunning", @[], session, currentModel))
  of "start":
    return toCommandResult(actionRegistry.executeAction("agent.start", if args.len > 1: args[1..^1] else: @[], session, currentModel))
  of "stop":
    return toCommandResult(actionRegistry.executeAction("agent.stop", if args.len > 1: @[args[1]] else: @[], session, currentModel))
  else:
    return toCommandResult(actionRegistry.executeAction("agent.showDefinition", @[args[0]], session, currentModel))

proc skillHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle /skill subcommands for skill management
  if args.len == 0:
    return CommandResult(
      success: true,
      message: """Skill commands:

  /skill list [--loaded]       List available or loaded skills
  /skill load <name>           Load a skill into active context
  /skill unload <name|--all>   Remove skill(s) from context
  /skill show <name>           Display skill details
  /skill search <query>        Find skills by name/description/tag
  /skill refresh               Re-scan skill directories
  /skill download <repo> [--skill <name>] [--global]
                               Install from skills.sh registry

Skills are reusable instruction modules loaded on demand.
Loaded skills are injected into the system prompt.

Tip: Use --skill to install a specific skill from repos with multiple skills.
Example: /skill download damusix/skills --skill htmx""",
      shouldExit: false,
      shouldContinue: true
    )
  
  let subcommand = args[0].toLowerAscii()
  
  case subcommand
  of "list", "ls":
    let loadedOnly = args.len > 1 and ("--loaded" in args or "-l" in args)
    let language = if args.len > 1 and args[1].startsWith("--lang="): args[1][7..^1] else: ""
    let tag = if args.len > 1 and args[1].startsWith("--tag="): args[1][6..^1] else: ""
    
    let registry = getGlobalSkillRegistry()
    var skills: seq[Skill] = @[]
    
    if loadedOnly:
      skills = getLoadedSkillsList()
    elif language.len > 0:
      skills = getSkillsByLanguage(registry, language)
    elif tag.len > 0:
      skills = getSkillsByTag(registry, tag)
    else:
      for name, skill in registry.skills.pairs:
        skills.add(skill)
    
    if skills.len == 0:
      return CommandResult(
        success: true,
        message: if loadedOnly: "No skills currently loaded." else: "No skills found. Try 'refresh' or 'download'.",
        shouldExit: false,
        shouldContinue: true
      )
    
    var lines: seq[string] = @[]
    lines.add(fmt("Skills ({skills.len}):"))
    for skill in skills:
      var line = fmt("  • {skill.name}")
      if skill.version.isSome:
        line &= fmt(" (v{skill.version.get})")
      let desc = if skill.description.len > 60: skill.description[0..60] & "..." else: skill.description
      line &= fmt(" - {desc}")
      if isSkillLoadedGlobal(skill.name):
        line &= " [loaded]"
      lines.add(line)
    
    return CommandResult(
      success: true,
      message: lines.join("\n"),
      shouldExit: false,
      shouldContinue: true
    )
  
  of "load":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "Usage: /skill load <name>",
        shouldExit: false,
        shouldContinue: true
      )
    
    let skillName = args[1]
    let registry = getGlobalSkillRegistry()
    
    if skillName notin registry.skills:
      return CommandResult(
        success: false,
        message: fmt("Skill '{skillName}' not found. Use '/skill list' to see available skills."),
        shouldExit: false,
        shouldContinue: true
      )
    
    if isSkillLoadedGlobal(skillName):
      return CommandResult(
        success: true,
        message: fmt("Skill '{skillName}' is already loaded."),
        shouldExit: false,
        shouldContinue: true
      )
    
    if loadSkillGlobal(skillName):
      let skill = registry.skills[skillName]
      let loadedCount = getGlobalSkillRegistry().loadedSkills.len
      
      # Check if model supports developer messages
      let supportsDeveloper = currentModel.supportsDeveloperMessage.get(false)
      
      if supportsDeveloper:
        # Inject skill as developer message (Option C)
        let contextPlan = buildContextPlan(@[skill])
        let adaptedContent = getAdaptedSkillContent(contextPlan)
        if adaptedContent.len > 0:
          let devContent = "## Skill: " & skillName & "\n\n" & adaptedContent
          discard conversation_manager.addDeveloperMessage(devContent)
          markSkillInjectedAsDeveloper(skillName)
          return CommandResult(
            success: true,
            message: fmt("Loaded skill: {skillName}\n{skill.description}\n\nInjected as developer message.\nLoaded skills: {loadedCount}"),
            shouldExit: false,
            shouldContinue: true
          )
      
      # Fallback to system prompt injection (Option A)
      return CommandResult(
        success: true,
        message: fmt("Loaded skill: {skillName}\n{skill.description}\n\nWill be included in system prompt.\nLoaded skills: {loadedCount}"),
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: "Failed to load skill",
        shouldExit: false,
        shouldContinue: true
      )
  
  of "unload":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "Usage: /skill unload <name|--all>",
        shouldExit: false,
        shouldContinue: true
      )
    
    if args[1] == "--all" or args[1] == "-a":
      unloadAllSkillsGlobal()
      return CommandResult(
        success: true,
        message: "All skills unloaded. Note: Developer messages remain in history.",
        shouldExit: false,
        shouldContinue: true
      )
    
    let skillName = args[1]
    if not isSkillLoadedGlobal(skillName):
      return CommandResult(
        success: false,
        message: fmt("Skill '{skillName}' is not loaded."),
        shouldExit: false,
        shouldContinue: true
      )
    
    if unloadSkillGlobal(skillName):
      unmarkSkillInjectedAsDeveloper(skillName)
      let loadedCount = getGlobalSkillRegistry().loadedSkills.len
      return CommandResult(
        success: true,
        message: fmt("Unloaded skill: {skillName}. Loaded skills: {loadedCount}"),
        shouldExit: false,
        shouldContinue: true
      )
    else:
      return CommandResult(
        success: false,
        message: "Failed to unload skill",
        shouldExit: false,
        shouldContinue: true
      )
  
  of "show":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "Usage: /skill show <name>",
        shouldExit: false,
        shouldContinue: true
      )
    
    let skillName = args[1]
    let registry = getGlobalSkillRegistry()
    
    if skillName notin registry.skills:
      return CommandResult(
        success: false,
        message: fmt("Skill '{skillName}' not found."),
        shouldExit: false,
        shouldContinue: true
      )
    
    let skill = registry.skills[skillName]
    var lines: seq[string] = @[]
    lines.add(fmt("# Skill: {skill.name}"))
    
    if skill.version.isSome:
      lines.add(fmt("Version: {skill.version.get}"))
    if skill.license.isSome:
      lines.add(fmt("License: {skill.license.get}"))
    
    lines.add("")
    lines.add(skill.description)
    
    if skill.compatibility.isSome:
      let compat = skill.compatibility.get
      if compat.languages.len > 0:
        lines.add(fmt("Languages: {compat.languages.join(\", \")}"))
      if compat.agents.len > 0:
        lines.add(fmt("Compatible with: {compat.agents.join(\", \")}"))
    
    if skill.metadata.isSome:
      let meta = skill.metadata.get
      if meta.author.isSome:
        lines.add(fmt("Author: {meta.author.get}"))
      if meta.tags.len > 0:
        lines.add(fmt("Tags: {meta.tags.join(\", \")}"))
    
    lines.add("")
    lines.add("Loaded: " & (if isSkillLoadedGlobal(skillName): "Yes" else: "No"))
    
    return CommandResult(
      success: true,
      message: lines.join("\n"),
      shouldExit: false,
      shouldContinue: true
    )
  
  of "search", "find":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "Usage: /skill search <query>",
        shouldExit: false,
        shouldContinue: true
      )
    
    let query = args[1..^1].join(" ")
    let registry = getGlobalSkillRegistry()
    let matches = findSkillInRegistry(registry, query)
    
    if matches.len == 0:
      return CommandResult(
        success: true,
        message: fmt("No skills matching '{query}'."),
        shouldExit: false,
        shouldContinue: true
      )
    
    var lines: seq[string] = @[]
    lines.add(fmt("Found {matches.len} skill(s):"))
    for skill in matches:
      lines.add(fmt("  • {skill.name} - {skill.description[0..min(60, skill.description.len-1)]}"))
    
    return CommandResult(
      success: true,
      message: lines.join("\n"),
      shouldExit: false,
      shouldContinue: true
    )
  
  of "refresh":
    refreshSkillRegistry()
    let registry = getGlobalSkillRegistry()
    return CommandResult(
      success: true,
      message: fmt("Refreshed skill registry. Found {registry.skills.len} skills."),
      shouldExit: false,
      shouldContinue: true
    )
  
  of "download", "install", "add":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: """Usage: /skill download <repo> [--skill <name>] [--global]

Repos often contain multiple skills. Use --skill to install only one.

Examples:
  /skill download damusix/skills --skill htmx
  /skill download vercel-labs/agent-skills --skill frontend-design
  /skill download saisudhir14/golang-agent-skill
  /skill download damusix/skills --global""",
        shouldExit: false,
        shouldContinue: true
      )
    
    let repo = args[1]
    var skillName = ""
    var global = false
    
    for i in 2..<args.len:
      if args[i] == "--skill" and i + 1 < args.len:
        skillName = args[i + 1]
      elif args[i] == "--global" or args[i] == "-g":
        global = true
    
    var cmd = "npx skills add " & repo
    if skillName.len > 0:
      cmd &= " --skill " & skillName
    if global:
      cmd &= " -g"
    cmd &= " -a opencode -y"
    
    try:
      let (output, exitCode) = execCmdEx(cmd)
      if exitCode == 0:
        refreshSkillRegistry()
        let registry = getGlobalSkillRegistry()
        return CommandResult(
          success: true,
          message: fmt("Skill installed successfully.\n\n{output}\n\nFound {registry.skills.len} skills. Use '/skill list' to see them."),
          shouldExit: false,
          shouldContinue: true
        )
      else:
        return CommandResult(
          success: false,
          message: fmt("Failed to install skill (exit code {exitCode}):\n\n{output}"),
          shouldExit: false,
          shouldContinue: true
        )
    except Exception as e:
      return CommandResult(
        success: false,
        message: "Failed to run skills CLI: " & e.msg & "\n\nMake sure Node.js and npm are installed.",
        shouldExit: false,
        shouldContinue: true
      )
  
  else:
    return CommandResult(
      success: false,
      message: fmt("Unknown subcommand: {subcommand}. Type '/skill' for usage."),
      shouldExit: false,
      shouldContinue: true
    )

proc mcpHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
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
        message: statusLines.join("\r\n"),
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

proc configHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle config command - list or switch configurations
  if args.len == 0:
    # List available configs - build complete output as single string
    let configs = listAvailableConfigs(session)
    var lines: seq[string] = @[]

    # First show current config info
    lines.add(getConfigInfoString(session))
    lines.add("")

    # Then show available configs
    lines.add("Available configs:")

    if configs.global.len > 0:
      lines.add("  Global:")
      for cfg in configs.global:
        let marker = if cfg == session.currentConfig: " (active)" else: ""
        lines.add(fmt("    - {cfg}{marker}"))

    if configs.project.len > 0:
      lines.add("  Project:")
      for cfg in configs.project:
        let marker = if cfg == session.currentConfig: " (active)" else: ""
        lines.add(fmt("    - {cfg}{marker}"))

    return CommandResult(
      success: true,
      message: lines.join("\n"),
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: false
    )
  else:
    # Switch or reload config
    let targetConfig = args[0]
    let (success, reloaded) = switchConfig(session, targetConfig)

    if not success:
      return CommandResult(
        success: false,
        message: fmt("Config '{targetConfig}' not found"),
        shouldExit: false,
        shouldContinue: true,
        shouldResetUI: false
      )

    var lines: seq[string] = @[]
    if reloaded:
      lines.add(fmt("Reloaded config: {targetConfig}"))
    else:
      lines.add(fmt("Switched to config: {targetConfig}"))

    lines.add(getConfigInfoString(session))

    return CommandResult(
      success: true,
      message: lines.join("\n"),
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: true  # Reload prompts
    )

proc focusPlaceholder(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Placeholder - /focus is handled specially in cli.nim with masterState access
  return CommandResult(
    success: true,
    message: "Focus command handled in CLI",
    shouldExit: false,
    shouldContinue: true
  )

proc taskHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Handle /task command for executing isolated tasks
  if args.len == 0:
    return CommandResult(
      success: false,
      message: "Usage: /task <description>",
      shouldExit: false,
      shouldContinue: true
    )

  # This should only be reached if no agent is focused
  # The CLI routing will send /task to focused agents
  # If we get here, it means no agent was available
  return CommandResult(
    success: false,
    message: "/task requires an agent to be focused. Use /focus <agent> or @agent /task <description>",
    shouldExit: false,
    shouldContinue: true
  )

proc planHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Switch to plan mode
  setCurrentMode(amPlan)
  updateCurrentSessionMode(amPlan)

  # Persist mode change to database
  let database = getGlobalDatabase()
  if database != nil:
    let conversationId = getCurrentConversationId().int
    if conversationId > 0:
      updateConversationMode(database, conversationId, amPlan)

  return CommandResult(
    success: true,
    message: "Switched to Plan mode - focus on analysis and planning",
    shouldExit: false,
    shouldContinue: true,
    shouldResetUI: true
  )

proc codeHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Switch to code mode
  setCurrentMode(amCode)
  updateCurrentSessionMode(amCode)

  # Persist mode change to database
  let database = getGlobalDatabase()
  if database != nil:
    let conversationId = getCurrentConversationId().int
    if conversationId > 0:
      updateConversationMode(database, conversationId, amCode)

  return CommandResult(
    success: true,
    message: "Switched to Code mode - ready for implementation",
    shouldExit: false,
    shouldContinue: true,
    shouldResetUI: true
  )

# ========================================
# Discord Configuration Commands
# ========================================

proc discordStatusHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Show current Discord configuration
  var message = ""
  let database = getGlobalDatabase()
  
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  let discordConfig = loadDiscordConfigFromDb(database)
  
  if discordConfig.isNone:
    message = "📋 Discord not configured\n\n"
    message &= "Use '/discord token <token>' to set up Discord integration."
  else:
    let config = discordConfig.get()
    message = "📋 Discord Configuration:\n\n"
    
    let enabled = if config.hasKey("enabled"): config["enabled"].getBool() else: false
    let statusIcon = if enabled: "✅" else: "❌"
    let statusText = if enabled: "Enabled" else: "Disabled"
    message &= fmt("  Status: {statusIcon} {statusText}") & "\n"
    
    if config.hasKey("token"):
      let token = config["token"].getStr()
      let maskedToken = if token.len > 10: token[0..9] & "..." else: "***"
      message &= fmt("  Token: {maskedToken}") & "\n"
    
    if config.hasKey("guildId") and config["guildId"].getStr().len > 0:
      let guildId = config["guildId"].getStr()
      message &= fmt("  Guild ID: {guildId}") & "\n"

    if config.hasKey("defaultAgent") and config["defaultAgent"].getStr().len > 0:
      let defaultAgent = config["defaultAgent"].getStr()
      message &= fmt("  Default agent: @{defaultAgent}") & "\n"

    if config.hasKey("allowedPeople") and config["allowedPeople"].kind == JArray:
      let allowedPeople = config["allowedPeople"]
      if allowedPeople.len > 0:
        message &= "  Allowed people: "
        var peopleList: seq[string] = @[]
        for person in allowedPeople.items:
          peopleList.add(person.getStr())
        message &= peopleList.join(", ") & "\n"
      else:
        message &= "  Allowed people: (none - everyone allowed)\n"
    else:
      message &= "  Allowed people: (none - everyone allowed)\n"
    
    if config.hasKey("monitoredChannels") and config["monitoredChannels"].kind == JArray:
      let channels = config["monitoredChannels"]
      if channels.len > 0:
        message &= "  Monitored channels: "
        var channelList: seq[string] = @[]
        for ch in channels.items:
          channelList.add(ch.getStr())
        message &= channelList.join(", ") & "\n"
    
    message &= "\n💡 Use '/discord agent <name>' to set Discord's default agent"
    message &= "\n💡 Use '/discord people add <name>' to restrict who can talk to the bot"
    message &= "\n💡 Use '/discord enable' or '/discord disable' to toggle"
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc discordTokenHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Set Discord bot token
  if args.len < 1:
    return CommandResult(
      success: false,
      message: "❌ Usage: /discord token <token> [guildId]\n\n" &
                "Example: /discord token OTk2MTg5NjQxNjk3MjYzMDQw.GhK7Xa.abc123 123456789",
      shouldExit: false,
      shouldContinue: true
    )
  
  let token = args[0]
  let guildId = if args.len > 1: args[1] else: ""
  
  let database = getGlobalDatabase()
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  # Load existing config or create new
  var config = loadDiscordConfigFromDb(database)
  var newConfig = if config.isSome: config.get() else: %*{"enabled": false}
  
  newConfig["token"] = %token
  if guildId.len > 0:
    newConfig["guildId"] = %guildId
  
  # Ensure has monitoredChannels array
  if not newConfig.hasKey("monitoredChannels"):
    newConfig["monitoredChannels"] = %*[]
  if not newConfig.hasKey("allowedPeople"):
    newConfig["allowedPeople"] = %*[]
  
  saveDiscordConfigToDb(database, newConfig)
  
  var message = "✅ Discord token saved!\n\n"
  message &= fmt("  Token: {token[0..min(9, token.len-1)]}...") & "\n"
  if guildId.len > 0:
    message &= fmt("  Guild ID: {guildId}") & "\n"
  message &= "\n💡 Use '/discord enable' to start the bot"
  
  return CommandResult(
    success: true,
    message: message,
    shouldExit: false,
    shouldContinue: true
  )

proc discordChannelsHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Manage monitored Discord channels
  if args.len < 1:
    return CommandResult(
      success: false,
      message: "❌ Usage: /discord channels <add|remove|list> [channel]\n\n" &
                "Examples:\n" &
                "  /discord channels list\n" &
                "  /discord channels add general\n" &
                "  /discord channels remove general",
      shouldExit: false,
      shouldContinue: true
    )
  
  let action = args[0].toLowerAscii()
  let database = getGlobalDatabase()
  
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  let discordConfig = loadDiscordConfigFromDb(database)
  
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured. Use '/discord token <token>' first.",
      shouldExit: false,
      shouldContinue: true
    )
  
  var config = discordConfig.get()
  
  case action
  of "list":
    var message = "📋 Monitored Channels:\n\n"
    if config.hasKey("monitoredChannels") and config["monitoredChannels"].kind == JArray:
      let channels = config["monitoredChannels"]
      if channels.len > 0:
        var idx = 1
        for ch in channels.items:
          message &= fmt("  {idx}. {ch.getStr()}") & "\n"
          idx += 1
      else:
        message &= "  (none - all channels monitored)\n"
    else:
      message &= "  (none - all channels monitored)\n"
    message &= "\n💡 When no channels specified, bot monitors all channels it has access to"
    return CommandResult(
      success: true,
      message: message,
      shouldExit: false,
      shouldContinue: true
    )
  
  of "add":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "❌ Usage: /discord channels add <channel>",
        shouldExit: false,
        shouldContinue: true
      )
    
    let channel = args[1]
    
    if not config.hasKey("monitoredChannels") or config["monitoredChannels"].kind != JArray:
      config["monitoredChannels"] = %*[]
    
    # Check if already in list
    for ch in config["monitoredChannels"]:
      if ch.getStr() == channel:
        return CommandResult(
          success: false,
          message: fmt"❌ Channel '{channel}' is already in the list",
          shouldExit: false,
          shouldContinue: true
        )
    
    config["monitoredChannels"].add(%channel)
    saveDiscordConfigToDb(database, config)
    
    return CommandResult(
      success: true,
      message: fmt"✅ Added '{channel}' to monitored channels\n\n💡 Use '/discord channels list' to see all channels",
      shouldExit: false,
      shouldContinue: true
    )
  
  of "remove", "rm", "delete":
    if args.len < 2:
      return CommandResult(
        success: false,
        message: "❌ Usage: /discord channels remove <channel>",
        shouldExit: false,
        shouldContinue: true
      )
    
    let channel = args[1]
    
    if not config.hasKey("monitoredChannels") or config["monitoredChannels"].kind != JArray:
      return CommandResult(
        success: false,
        message: "❌ No channels configured",
        shouldExit: false,
        shouldContinue: true
      )
    
    var newChannels: seq[JsonNode] = @[]
    var found = false
    for ch in config["monitoredChannels"]:
      if ch.getStr() != channel:
        newChannels.add(ch)
      else:
        found = true
    
    if not found:
      return CommandResult(
        success: false,
        message: fmt"❌ Channel '{channel}' not found in list",
        shouldExit: false,
        shouldContinue: true
      )
    
    config["monitoredChannels"] = %newChannels
    saveDiscordConfigToDb(database, config)
    
    return CommandResult(
      success: true,
      message: fmt"✅ Removed '{channel}' from monitored channels",
      shouldExit: false,
      shouldContinue: true
    )
  
  else:
    return CommandResult(
      success: false,
      message: fmt"❌ Unknown action '{action}'. Use: add, remove, or list",
      shouldExit: false,
      shouldContinue: true
    )

proc discordAgentHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Set or show the default agent for Discord messages without @agent prefix
  let database = getGlobalDatabase()

  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )

  let discordConfig = loadDiscordConfigFromDb(database)
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured. Use '/discord token <token>' first.",
      shouldExit: false,
      shouldContinue: true
    )

  var config = discordConfig.get()

  if args.len == 0:
    if config.hasKey("defaultAgent") and config["defaultAgent"].getStr().len > 0:
      let defaultAgent = config["defaultAgent"].getStr()
      return CommandResult(
        success: true,
        message: fmt("Discord default agent: @{defaultAgent}"),
        shouldExit: false,
        shouldContinue: true
      )

    return CommandResult(
      success: true,
      message: "Discord default agent not set. Use '/discord agent <name>' to set one.",
      shouldExit: false,
      shouldContinue: true
    )

  let agentName = args[0]
  if agentName == "none" or agentName == "clear":
    if config.hasKey("defaultAgent"):
      config.delete("defaultAgent")
    saveDiscordConfigToDb(database, config)
    return CommandResult(
      success: true,
      message: "✅ Cleared Discord default agent",
      shouldExit: false,
      shouldContinue: true
    )

  config["defaultAgent"] = %agentName
  saveDiscordConfigToDb(database, config)
  return CommandResult(
    success: true,
    message: fmt("✅ Set Discord default agent to @{agentName}\n\n💡 Messages without @agent in Discord will now route there"),
    shouldExit: false,
    shouldContinue: true
  )

proc discordPeopleHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Manage allowlist of Discord users who can talk to the bot
  let database = getGlobalDatabase()

  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )

  let discordConfig = loadDiscordConfigFromDb(database)
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured. Use '/discord token <token>' first.",
      shouldExit: false,
      shouldContinue: true
    )

  var config = discordConfig.get()
  if not config.hasKey("allowedPeople") or config["allowedPeople"].kind != JArray:
    config["allowedPeople"] = %*[]

  if args.len == 0:
    return CommandResult(
      success: false,
      message: "❌ Usage: /discord people <add|remove|list|clear> [name]\n\nExamples:\n  /discord people list\n  /discord people add gokr\n  /discord people remove gokr\n  /discord people clear",
      shouldExit: false,
      shouldContinue: true
    )

  let action = args[0].toLowerAscii()
  case action
  of "list":
    var message = "📋 Allowed Discord People:\n\n"
    if config["allowedPeople"].len > 0:
      var idx = 1
      for person in config["allowedPeople"].items:
        message &= fmt("  {idx}. {person.getStr()}") & "\n"
        idx += 1
    else:
      message &= "  (none - everyone is allowed)\n"
    message &= "\n💡 Entries match Discord username case-insensitively, or user ID exactly"
    return CommandResult(success: true, message: message, shouldExit: false, shouldContinue: true)

  of "add":
    if args.len < 2:
      return CommandResult(success: false, message: "❌ Usage: /discord people add <name-or-id>", shouldExit: false, shouldContinue: true)
    let person = args[1]
    for existing in config["allowedPeople"].items:
      if existing.getStr().toLowerAscii() == person.toLowerAscii():
        return CommandResult(success: false, message: fmt("❌ '{person}' is already allowed"), shouldExit: false, shouldContinue: true)
    config["allowedPeople"].add(%person)
    saveDiscordConfigToDb(database, config)
    return CommandResult(success: true, message: fmt("✅ Added '{person}' to allowed Discord people"), shouldExit: false, shouldContinue: true)

  of "remove", "rm", "delete":
    if args.len < 2:
      return CommandResult(success: false, message: "❌ Usage: /discord people remove <name-or-id>", shouldExit: false, shouldContinue: true)
    let person = args[1]
    var newPeople: seq[JsonNode] = @[]
    var found = false
    for existing in config["allowedPeople"].items:
      if existing.getStr().toLowerAscii() == person.toLowerAscii():
        found = true
      else:
        newPeople.add(existing)
    if not found:
      return CommandResult(success: false, message: fmt("❌ '{person}' not found in allowed people"), shouldExit: false, shouldContinue: true)
    config["allowedPeople"] = %newPeople
    saveDiscordConfigToDb(database, config)
    return CommandResult(success: true, message: fmt("✅ Removed '{person}' from allowed Discord people"), shouldExit: false, shouldContinue: true)

  of "clear":
    config["allowedPeople"] = %*[]
    saveDiscordConfigToDb(database, config)
    return CommandResult(success: true, message: "✅ Cleared allowed Discord people list\n\n💡 Everyone can now talk to the bot", shouldExit: false, shouldContinue: true)

  else:
    return CommandResult(success: false, message: fmt("❌ Unknown action '{action}'. Use: add, remove, list, or clear"), shouldExit: false, shouldContinue: true)

proc discordEnableHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Enable Discord integration
  let database = getGlobalDatabase()
  
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  let discordConfig = loadDiscordConfigFromDb(database)
  
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured. Use '/discord token <token>' first.",
      shouldExit: false,
      shouldContinue: true
    )
  
  var config = discordConfig.get()
  config["enabled"] = %true
  saveDiscordConfigToDb(database, config)
  
  return CommandResult(
    success: true,
    message: "✅ Discord integration enabled\n\n💡 Starting Discord bot...",
    shouldExit: false,
    shouldContinue: true
  )

proc discordDisableHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Disable Discord integration
  let database = getGlobalDatabase()
  
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  let discordConfig = loadDiscordConfigFromDb(database)
  
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured",
      shouldExit: false,
      shouldContinue: true
    )
  
  var config = discordConfig.get()
  config["enabled"] = %false
  saveDiscordConfigToDb(database, config)
  
  return CommandResult(
    success: true,
    message: "✅ Discord integration disabled",
    shouldExit: false,
    shouldContinue: true
  )

proc discordTestHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Test Discord connection (validate token)
  let database = getGlobalDatabase()
  
  if database == nil:
    return CommandResult(
      success: false,
      message: "❌ Database not available",
      shouldExit: false,
      shouldContinue: true
    )
  
  let discordConfig = loadDiscordConfigFromDb(database)
  
  if discordConfig.isNone:
    return CommandResult(
      success: false,
      message: "❌ Discord not configured. Use '/discord token <token>' first.",
      shouldExit: false,
      shouldContinue: true
    )
  
  let config = discordConfig.get()
  
  if not config.hasKey("token"):
    return CommandResult(
      success: false,
      message: "❌ Discord token not configured",
      shouldExit: false,
      shouldContinue: true
    )
  
  let token = config["token"].getStr()
  
  # Test token by calling Discord API
  try:
    var client = newHttpClient()
    client.headers = newHttpHeaders({"Authorization": fmt"Bot {token}"})
    
    let response = client.getContent("https://discord.com/api/v10/users/@me")
    let userJson = parseJson(response)
    
    let username = userJson["username"].getStr()
    let discriminator = if userJson.hasKey("discriminator"): userJson["discriminator"].getStr() else: "0"
    
    var message = "✅ Discord connection successful!\n\n"
    message &= fmt("  Bot: {username}#{discriminator}") & "\n"
    
    if config.hasKey("enabled") and config["enabled"].getBool():
      message &= "  Status: ✅ Enabled\n"
    else:
      message &= "  Status: ❌ Disabled (use '/discord enable')\n"
    
    message &= "\n💡 Bot is ready to receive messages in the master process."
    
    return CommandResult(
      success: true,
      message: message,
      shouldExit: false,
      shouldContinue: true
    )
  except Exception as e:
    return CommandResult(
      success: false,
      message: fmt"❌ Discord connection failed: {e.msg}\n\n💡 Check that your token is valid",
      shouldExit: false,
      shouldContinue: true
    )

proc discordHandler(args: seq[string], session: var Session, currentModel: var configTypes.ModelConfig): CommandResult =
  ## Discord command dispatcher
  if args.len < 1:
    return CommandResult(
      success: false,
      message: "❌ Usage: /discord <status|token|channels|agent|people|enable|disable|test>\n\n" &
                "Discord commands:\n" &
                "  status   - Show current Discord configuration\n" &
                "  token    - Set Discord bot token\n" &
                "  channels - Manage monitored channels\n" &
                "  agent    - Set/show Discord default agent\n" &
                "  people   - Manage allowed Discord users\n" &
                "  enable   - Enable and start Discord bot\n" &
                "  disable  - Disable and stop Discord bot\n" &
                "  test     - Test Discord connection",
      shouldExit: false,
      shouldContinue: true
    )
  
  let subcommand = args[0].toLowerAscii()
  var subArgs: seq[string] = @[]
  if args.len > 1:
    subArgs = args[1..^1]
  
  case subcommand
  of "status":
    return discordStatusHandler(subArgs, session, currentModel)
  of "token", "connect":
    return discordTokenHandler(subArgs, session, currentModel)
  of "channels", "channel":
    return discordChannelsHandler(subArgs, session, currentModel)
  of "agent":
    return discordAgentHandler(subArgs, session, currentModel)
  of "people", "users":
    return discordPeopleHandler(subArgs, session, currentModel)
  of "enable", "on":
    return discordEnableHandler(subArgs, session, currentModel)
  of "disable", "off":
    return discordDisableHandler(subArgs, session, currentModel)
  of "test":
    return discordTestHandler(subArgs, session, currentModel)
  else:
    return CommandResult(
      success: false,
      message: fmt("❌ Unknown subcommand '{subcommand}'") & "\n\n" &
                "Use '/discord' to see available commands",
      shouldExit: false,
      shouldContinue: true
    )

proc initializeCommands*() =
  ## Initialize the built-in commands
  # Global commands - run in master niffler only
  registerCommandAction("help", "Show help and available commands", "", @[], helpActionHandler, ccGlobal,
    "system.help", "help", {actionTypes.asMasterCli})
  registerCommandAction("focus", "Set/show focused agent for commands", "[agent|none]", @[], focusActionHandler, ccGlobal,
    "agent.focus", "focus [agent|none]", {actionTypes.asMasterCli})
  registerCommandAction("exit", "Exit Niffler", "", @["quit"], exitActionHandler, ccGlobal,
    "system.exit", "exit", {actionTypes.asMasterCli})
  registerCommandAction("config", "Switch or list configs", "[name]", @[], configActionHandler, ccGlobal,
    "system.config", "config [name]", {actionTypes.asMasterCli})
  registerCommandAction("cost", "Show session cost summary and projections", "", @[], costActionHandler, ccGlobal,
    "system.cost", "cost", {actionTypes.asMasterCli})
  registerCommandAction("theme", "Switch theme or show current", "[name]", @[], themeActionHandler, ccGlobal,
    "system.theme", "theme [name]", {actionTypes.asMasterCli})
  registerCommandAction("markdown", "Toggle markdown rendering", "[on|off]", @["md"], markdownActionHandler, ccGlobal,
    "system.markdown", "markdown [on|off]", {actionTypes.asMasterCli})
  registerCommandAction("mcp", "Show MCP server status and tools", "[status]", @[], mcpActionHandler, ccGlobal,
    "system.mcp", "mcp [status]", {actionTypes.asMasterCli})
  registerCommandAction("agent", "Manage agent definitions and live agents", "[subcommand]", @[], agentHandler, ccGlobal,
    "agent.help", "agent", {actionTypes.asMasterCli}, showInHelp = false)
  registerCommandAction("archive", "Archive a conversation", "<id>", @[], archiveActionHandler, ccGlobal,
    "conversation.archive", "archive <id>", {actionTypes.asMasterCli})
  registerCommandAction("unarchive", "Unarchive a conversation", "<id>", @[], unarchiveActionHandler, ccGlobal,
    "conversation.unarchive", "unarchive <id>", {actionTypes.asMasterCli})
  registerCommandAction("search", "Search conversations", "<query>", @[], searchActionHandler, ccGlobal,
    "conversation.search", "search <query>", {actionTypes.asMasterCli})
  registerCommandAction("models", "List available models from API endpoint", "", @[], modelsActionHandler, ccGlobal,
    "system.models", "models", {actionTypes.asMasterCli})
  registerCommandAction("discord", "Discord bot configuration", "<status,token,channels,agent,people,enable,disable,test>", @[], discordHandler, ccGlobal,
    "system.discord", "discord <status,token,channels,agent,people,enable,disable,test>", {actionTypes.asMasterCli})
  registerCommandAction("skill", "Manage skills - reusable instruction modules", "<subcommand>", @["skills"], skillHandler, ccAgent,
    "system.skill", "skill <subcommand>", {actionTypes.asMasterCli, actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)

  # Agent commands - run in agent context
  registerCommandAction("model", "Switch model or show current", "[name]", @[], modelActionHandler, ccAgent,
    "agent.model", "model [name]", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("context", "Show conversation context information", "", @[], contextActionHandler, ccAgent,
    "agent.context", "context", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("inspect", "Generate HTTP JSON request for API inspection", "[messages,tools,model,system] [filename]", @[], inspectActionHandler, ccAgent,
    "agent.inspect", "inspect [messages,tools,model,system] [filename]", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("condense", "Create condensed conversation with LLM summary", "[strategy]", @[], condenseActionHandler, ccAgent,
    "conversation.condense", "condense [strategy]", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("conv", "List/switch conversations", "[id|title]", @[], conversationSwitchActionHandler, ccAgent,
    "conversation.switch", "conv [id|title]", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("new", "Create new conversation", "[title]", @[], newConversationActionHandler, ccAgent,
    "conversation.new", "new [title]", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("info", "Show current conversation info", "", @[], conversationInfoActionHandler, ccAgent,
    "conversation.info", "info", {actionTypes.asAgentCli}, routableToAgent = true, localOnly = true)
  registerCommandAction("task", "Execute a task in fresh context", "<description>", @[], taskActionHandler, ccAgent,
    "task.dispatch", "task <description>", {actionTypes.asAgentCli}, routableToAgent = true)
  registerCommandAction("plan", "Switch to plan mode", "", @[], planActionHandler, ccAgent,
    "agent.plan", "plan", {actionTypes.asAgentCli}, routableToAgent = true)
  registerCommandAction("code", "Switch to code mode", "", @[], codeActionHandler, ccAgent,
    "agent.code", "code", {actionTypes.asAgentCli}, routableToAgent = true)

  registerActionOnly("agent.listDefinitions", "List available agent definitions.", "agent list",
    {actionTypes.asMasterCli, actionTypes.asTool}, agentListAction,
    toolName = some("agent_manage"), agentCapabilities = {actionTypes.acInspectAgents})
  registerActionOnly("agent.showDefinition", "Show details for a specific agent definition.", "agent show <name>",
    {actionTypes.asMasterCli, actionTypes.asTool}, agentShowAction,
    toolName = some("agent_manage"), agentCapabilities = {actionTypes.acInspectAgents})
  registerActionOnly("agent.listRunning", "List running agent instances and presence state.", "agent running",
    {actionTypes.asMasterCli, actionTypes.asTool}, agentRunningAction,
    toolName = some("agent_manage"), agentCapabilities = {actionTypes.acInspectAgents})
  registerActionOnly("agent.start", "Start a new agent instance from a definition.", "agent start <name> [--nick=<nick>] [--model=<model>]",
    {actionTypes.asMasterCli, actionTypes.asTool}, agentStartAction,
    toolName = some("agent_manage"), agentCapabilities = {actionTypes.acManageAgents})
  registerActionOnly("agent.stop", "Stop a running agent by routing name.", "agent stop <routing-name>",
    {actionTypes.asMasterCli, actionTypes.asTool}, agentStopAction,
    toolName = some("agent_manage"), agentCapabilities = {actionTypes.acManageAgents})
  registerActionOnly("conversation.new", "Create a new conversation.", "new [title]",
    {actionTypes.asAgentCli}, conversationNewAction, routableToAgent = true)
  registerActionOnly("conversation.switch", "List or switch conversations.", "conv [id|title]",
    {actionTypes.asAgentCli}, conversationSwitchAction, routableToAgent = true)
  registerActionOnly("conversation.archive", "Archive a conversation.", "archive <id>",
    {actionTypes.asMasterCli}, conversationArchiveAction)
  registerActionOnly("conversation.unarchive", "Unarchive a conversation.", "unarchive <id>",
    {actionTypes.asMasterCli}, conversationUnarchiveAction)
  registerActionOnly("conversation.info", "Show current conversation info.", "info",
    {actionTypes.asAgentCli}, conversationInfoAction, routableToAgent = true)
  registerActionOnly("system.exit", "Exit Niffler.", "exit",
    {actionTypes.asMasterCli}, exitAction)
  registerActionOnly("system.help", "Show help and available commands.", "help",
    {actionTypes.asMasterCli}, helpAction)
  registerActionOnly("agent.focus", "Set or show focused agent.", "focus [agent|none]",
    {actionTypes.asMasterCli}, focusAction)
  registerActionOnly("agent.model", "Switch model or show current.", "model [name]",
    {actionTypes.asAgentCli}, modelAction, routableToAgent = true)
  registerActionOnly("agent.context", "Show conversation context information.", "context",
    {actionTypes.asAgentCli}, contextAction, routableToAgent = true)
  registerActionOnly("agent.inspect", "Generate HTTP JSON request for API inspection.", "inspect [messages,tools,model,system] [filename]",
    {actionTypes.asAgentCli}, inspectAction, routableToAgent = true)
  registerActionOnly("conversation.condense", "Create condensed conversation with LLM summary.", "condense [strategy]",
    {actionTypes.asAgentCli}, condenseAction, routableToAgent = true)
  registerActionOnly("conversation.search", "Search conversations.", "search <query>",
    {actionTypes.asMasterCli}, searchAction)
  registerActionOnly("agent.plan", "Switch to plan mode.", "plan",
    {actionTypes.asAgentCli}, planAction, routableToAgent = true)
  registerActionOnly("agent.code", "Switch to code mode.", "code",
    {actionTypes.asAgentCli}, codeAction, routableToAgent = true)
  registerActionOnly("system.config", "Switch or list configs.", "config [name]",
    {actionTypes.asMasterCli}, configAction)
  registerActionOnly("system.cost", "Show session cost summary and projections.", "cost",
    {actionTypes.asMasterCli}, costAction)
  registerActionOnly("system.theme", "Switch theme or show current.", "theme [name]",
    {actionTypes.asMasterCli}, themeAction)
  registerActionOnly("system.markdown", "Toggle markdown rendering.", "markdown [on|off]",
    {actionTypes.asMasterCli}, markdownAction)
  registerActionOnly("system.mcp", "Show MCP server status and tools.", "mcp [status]",
    {actionTypes.asMasterCli}, mcpAction)
  registerActionOnly("system.models", "List available models from the API endpoint.", "models",
    {actionTypes.asMasterCli}, modelsAction)
  registerActionOnly("task.dispatch", "Execute a task in fresh context.", "task <description>",
    {actionTypes.asAgentCli}, taskAction, routableToAgent = true)
  registerActionOnly("task.dispatchToAgent", "Dispatch a fresh-context /task request to a running agent.", "task_dispatch <target> <description>",
    {actionTypes.asTool}, taskDispatchAction,
    toolName = some("task_dispatch"), agentCapabilities = {actionTypes.acDispatchTasks})
