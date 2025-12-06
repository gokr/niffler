## Task Executor
##
## This module implements isolated task execution for autonomous agents.
## Each task runs with its own conversation and persists to the database.
##
## Key Features:
## - Creates isolated conversation for each task
## - Delegates tool execution to the API worker's agentic loop
## - Database persistence for all messages
## - Generates summary after task completion
## - Switches back to previous conversation when done
##
## Architecture:
## - Uses the API worker's executeAgenticLoop for all tool calling
## - Creates a new conversation, switches to it, executes, switches back
## - Summary generation happens after task completion

import std/[logging, strformat, times, options, os, strutils, sets, json, algorithm, tables]
import ../types/[messages, config, agents, mode]
import channels
import config as configModule
import database
import conversation_manager
import ../ui/[tool_visualizer, output_shared, response_templates]

type
  ArtifactCategories* = object
    modified*: seq[string]     ## Files created or edited
    temporary*: seq[string]    ## Temp files (e.g., fetch cache)

proc isTemporaryPath(path: string): bool =
  ## Check if path is a temporary file location
  path.startsWith("/tmp/") or path.startsWith("/var/tmp/") or
    path.contains("/tmp/niffler/")

proc extractArtifactCategories*(messages: seq[Message]): ArtifactCategories =
  ## Extract file paths from tool calls, categorized by type
  var modifiedSet = initHashSet[string]()
  var tempSet = initHashSet[string]()

  for msg in messages:
    if msg.role == mrAssistant and msg.toolCalls.isSome():
      for toolCall in msg.toolCalls.get():
        case toolCall.function.name:
        of "create", "edit":
          # Only track write operations as "modified"
          try:
            let args = parseJson(toolCall.function.arguments)
            var path = ""
            if args.hasKey("path"):
              path = args["path"].getStr()
            elif args.hasKey("file_path"):
              path = args["file_path"].getStr()

            if path.len > 0:
              if isTemporaryPath(path):
                tempSet.incl(path)
              else:
                modifiedSet.incl(path)
          except JsonParsingError, KeyError:
            discard
        of "fetch":
          # Fetch tool creates temp files
          try:
            let args = parseJson(toolCall.function.arguments)
            if args.hasKey("output_path"):
              let path = args["output_path"].getStr()
              if path.len > 0:
                tempSet.incl(path)
          except JsonParsingError, KeyError:
            discard
        else:
          discard

  # Convert sets to sorted lists
  for path in modifiedSet:
    result.modified.add(path)
  result.modified.sort()

  for path in tempSet:
    result.temporary.add(path)
  result.temporary.sort()

proc extractArtifacts*(messages: seq[Message]): seq[string] =
  ## Extract modified file paths from tool calls (create/edit only)
  ## For categorized extraction, use extractArtifactCategories instead
  let categories = extractArtifactCategories(messages)
  result = categories.modified

proc buildTaskSystemPrompt*(agent: AgentDefinition, taskDescription: string): string =
  ## Build system prompt for task execution combining agent prompt and task context
  result = agent.systemPrompt
  result.add("\n\n## Your Assigned Task\n\n")
  result.add(taskDescription)
  result.add("\n\n## Available Tools\n\n")
  for tool in agent.allowedTools:
    result.add("- " & tool & "\n")
  result.add("\n## Instructions\n\n")
  result.add("Work autonomously to complete this task. When finished, provide a clear summary of:\n")
  result.add("1. What you accomplished\n")
  result.add("2. Files you read or created\n")
  result.add("3. Key findings or results\n")
  result.add("4. Any blockers or limitations\n")

proc generateSummary*(conversationMessages: seq[Message], modelConfig: ModelConfig,
                     channels: ptr ThreadChannels, apiKey: string,
                     toolSchemas: seq[ToolDefinition]): string =
  ## Ask LLM to summarize task results
  debug("Generating task summary")

  var summaryMessages: seq[Message] = @[]

  # Add system prompt for summarization
  summaryMessages.add(Message(
    role: mrSystem,
    content: """You are a task result summarizer. Review the conversation and provide a concise summary including:
1. What was accomplished
2. Files read or created (if any)
3. Key findings or results
4. Any blockers or limitations

Keep the summary brief (2-4 sentences) but informative."""
  ))

  # Add the task conversation history (skip system prompt, just show the work)
  for i, msg in conversationMessages:
    if i > 0:  # Skip the first message (task system prompt)
      summaryMessages.add(msg)

  # Add summarization request
  summaryMessages.add(Message(
    role: mrUser,
    content: "Please provide a brief summary of what was accomplished in this task."
  ))

  # Send summary request via channels
  let requestId = "task_summary_" & $epochTime()
  let request = APIRequest(
    kind: arkChatRequest,
    requestId: requestId,
    messages: summaryMessages,
    model: modelConfig.model,
    modelNickname: modelConfig.nickname,
    maxTokens: 2048,  # Summaries don't need many tokens
    temperature: 0.7,
    baseUrl: modelConfig.baseUrl,
    apiKey: apiKey,
    enableTools: false,  # No tools needed for summarization
    tools: some(toolSchemas),
    agentName: ""  # No agent restriction for summary
  )

  if not trySendAPIRequest(channels, request):
    return "Failed to send summary request"

  # Collect summary response
  var summary = ""
  var responseComplete = false
  var attempts = 0
  const maxAttempts = 600  # 1 minute max

  while attempts < maxAttempts and not responseComplete:
    var response: APIResponse
    if tryReceiveAPIResponse(channels, response):
      if response.requestId == requestId:
        case response.kind:
        of arkReady:
          discard
        of arkStreamChunk:
          summary.add(response.content)
        of arkStreamComplete:
          responseComplete = true
        of arkStreamError:
          return fmt("Summary error: {response.error}")
        else:
          discard

    sleep(100)
    attempts.inc()

  if not responseComplete:
    return "Summary request timed out"

  if summary.len == 0:
    return "Summary generation produced no output"

  return summary

proc executeTask*(agent: AgentDefinition, description: string,
                  modelConfig: ModelConfig, channels: ptr ThreadChannels,
                  toolSchemas: seq[ToolDefinition],
                  database: DatabaseBackend): TaskResult =
  ## Execute a task with the given agent in an isolated conversation
  ## Creates a new conversation, delegates to API worker, generates summary, switches back
  debug(fmt("Starting task execution with agent '{agent.name}': {description}"))

  try:
    # Get API key for the model
    let apiKey = configModule.readKeyForModel(modelConfig)
    if apiKey.len == 0:
      # Check if this is a local server that doesn't require authentication
      let baseUrl = modelConfig.baseUrl.toLower()
      if not (baseUrl.contains("localhost") or baseUrl.contains("127.0.0.1")):
        # Remote server - API key required but not found
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          tempArtifacts: @[],
          toolCalls: 0,
          tokensUsed: 0,
          error: fmt("No API key configured for model '{modelConfig.nickname}'")
        )

    # Save current conversation ID to restore later
    let previousConvId = getCurrentConversationId()
    debug(fmt"Saved previous conversation: {previousConvId}")

    # Create a task-specific conversation
    let taskTitle = fmt"Task: {description[0..min(50, description.len-1)]}..."
    let taskConvOpt = createConversation(database, taskTitle, amCode, modelConfig.nickname)

    if taskConvOpt.isNone():
      return TaskResult(
        success: false,
        summary: "",
        artifacts: @[],
        tempArtifacts: @[],
        toolCalls: 0,
        tokensUsed: 0,
        error: "Failed to create task conversation"
      )

    let taskConv = taskConvOpt.get()
    discard switchToConversation(database, taskConv.id)
    debug(fmt"Created and switched to task conversation: {taskConv.id}")

    # Build task-specific system prompt
    let systemPrompt = buildTaskSystemPrompt(agent, description)

    # Build initial messages
    var initialMessages: seq[Message] = @[]
    initialMessages.add(Message(role: mrSystem, content: systemPrompt))
    initialMessages.add(Message(role: mrUser, content: description))

    # Add user message to conversation (persists to DB)
    discard conversation_manager.addUserMessage(description)

    # Filter tool schemas to only include agent's allowed tools
    var agentToolSchemas: seq[ToolDefinition] = @[]
    for tool in toolSchemas:
      if tool.function.name in agent.allowedTools:
        agentToolSchemas.add(tool)

    # Create and send API request - API worker will handle tool execution
    let requestId = fmt("task_{agent.name}_{epochTime()}")
    let request = APIRequest(
      kind: arkChatRequest,
      requestId: requestId,
      messages: initialMessages,
      model: modelConfig.model,
      modelNickname: modelConfig.nickname,
      maxTokens: 8192,
      temperature: 0.7,
      baseUrl: modelConfig.baseUrl,
      apiKey: apiKey,
      enableTools: agentToolSchemas.len > 0,
      tools: if agentToolSchemas.len > 0: some(agentToolSchemas) else: none(seq[ToolDefinition]),
      agentName: agent.name  # For tool permission validation
    )

    if not trySendAPIRequest(channels, request):
      # Restore previous conversation
      if previousConvId > 0:
        discard switchToConversation(database, previousConvId)
      return TaskResult(
        success: false,
        summary: "",
        artifacts: @[],
        tempArtifacts: @[],
        toolCalls: 0,
        tokensUsed: 0,
        error: "Failed to send API request"
      )

    # Wait for completion - API worker handles all tool execution via executeAgenticLoop
    var totalTokens = 0
    var totalToolCalls = 0
    var responseComplete = false
    var pendingToolCalls: Table[string, CompactToolRequestInfo] = initTable[string, CompactToolRequestInfo]()
    var outputAfterToolCall = false
    var lastContent = ""

    # Timeout configuration (default 5 minutes per request, but allow much longer for tasks)
    let timeoutSeconds = getGlobalConfig().agentTimeoutSeconds.get(300) * 2  # Double for tasks
    let maxAttempts = (timeoutSeconds * 1000) div 100  # Convert to number of 100ms attempts

    var attempts = 0
    while attempts < maxAttempts and not responseComplete:
      var response: APIResponse
      if tryReceiveAPIResponse(channels, response):
        if response.requestId == requestId:
          case response.kind:
          of arkReady:
            debug("API ready for task")
          of arkStreamChunk:
            if response.content.len > 0:
              lastContent.add(response.content)
              # Display streaming content
              writeStreamingChunk(response.content)
            # Count tool calls from chunks
            if response.toolCalls.isSome():
              totalToolCalls += response.toolCalls.get().len
          of arkToolCallRequest, arkToolCallResult:
            # Display tool execution progress
            handleToolCallDisplay(response, pendingToolCalls, outputAfterToolCall)
            # Count tool requests (not results to avoid double-counting)
            if response.kind == arkToolCallRequest:
              totalToolCalls += 1
          of arkStreamComplete:
            finishStreaming()
            totalTokens = response.usage.totalTokens
            responseComplete = true
            debug(fmt"Task completed: {totalTokens} tokens, {totalToolCalls} tool calls")
          of arkStreamError:
            finishStreaming()
            # Restore previous conversation
            if previousConvId > 0:
              discard switchToConversation(database, previousConvId)
            return TaskResult(
              success: false,
              summary: "",
              artifacts: @[],
              tempArtifacts: @[],
              toolCalls: totalToolCalls,
              tokensUsed: totalTokens,
              error: fmt("API error: {response.error}")
            )

      sleep(100)
      attempts.inc()

    if not responseComplete:
      # Restore previous conversation
      if previousConvId > 0:
        discard switchToConversation(database, previousConvId)
      return TaskResult(
        success: false,
        summary: "",
        artifacts: @[],
        tempArtifacts: @[],
        toolCalls: totalToolCalls,
        tokensUsed: totalTokens,
        error: "Task timed out"
      )

    # Load conversation from database for summary generation
    let conversationMessages = getConversationContext()
    debug(fmt"Loaded {conversationMessages.len} messages for summary")

    # Generate summary of results
    debug("Generating summary")
    let summary = generateSummary(conversationMessages, modelConfig, channels, apiKey, toolSchemas)

    # Extract artifacts (file paths) from conversation
    let categories = extractArtifactCategories(conversationMessages)
    debug(fmt("Extracted {categories.modified.len} modified files, {categories.temporary.len} temp files"))

    # Restore previous conversation
    if previousConvId > 0:
      discard switchToConversation(database, previousConvId)
      debug(fmt"Restored previous conversation: {previousConvId}")

    return TaskResult(
      success: true,
      summary: summary,
      artifacts: categories.modified,
      tempArtifacts: categories.temporary,
      toolCalls: totalToolCalls,
      tokensUsed: totalTokens,
      error: ""
    )

  except Exception as e:
    error(fmt("Task execution error: {e.msg}"))
    return TaskResult(
      success: false,
      summary: "",
      artifacts: @[],
      tempArtifacts: @[],
      toolCalls: 0,
      tokensUsed: 0,
      error: fmt("Task execution failed: {e.msg}")
    )
