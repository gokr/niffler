## Task Executor
##
## This module implements isolated task execution for autonomous agents.
## Each task runs with its own message history and restricted tool access.
##
## Key Features:
## - Isolated execution environment per task
## - Agent-specific system prompt
## - Separate message history (not mixed with main conversation)
## - Tool access validation via AgentContext
## - Result condensation via LLM summary
##
## Architecture:
## - Tasks execute in the same thread as the main conversation for simplicity
## - Uses existing API worker and tool worker (thread-safe)
## - Builds task-specific system prompt from agent definition
## - Collects metrics (tokens, tool calls, artifacts)
## - Asks LLM to summarize results before returning to main agent

import std/[logging, strformat, times, options, os, strutils, sets, json, algorithm]
import ../types/[messages, config, agents]
import channels
import config as configModule
import completion_detection

proc extractArtifacts*(messages: seq[Message]): seq[string] =
  ## Extract file paths from tool calls in the conversation
  var fileSet = initHashSet[string]()

  for msg in messages:
    if msg.role == mrAssistant and msg.toolCalls.isSome():
      for toolCall in msg.toolCalls.get():
        # Extract file paths from file operation tools
        case toolCall.function.name:
        of "read", "create", "edit":
          # These tools have a "path" or "file_path" argument
          try:
            let args = parseJson(toolCall.function.arguments)
            if args.hasKey("path"):
              fileSet.incl(args["path"].getStr())
            elif args.hasKey("file_path"):
              fileSet.incl(args["file_path"].getStr())
          except JsonParsingError, KeyError:
            # Invalid JSON or missing key, skip
            discard
        of "list":
          # List tool has a "directory" argument
          try:
            let args = parseJson(toolCall.function.arguments)
            if args.hasKey("directory"):
              fileSet.incl(args["directory"].getStr())
            elif args.hasKey("path"):
              fileSet.incl(args["path"].getStr())
          except JsonParsingError, KeyError:
            discard
        else:
          discard

  # Convert set to sorted list
  result = @[]
  for path in fileSet:
    result.add(path)
  result.sort()

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

proc generateSummary(conversationMessages: seq[Message], modelConfig: ModelConfig,
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
    tools: some(toolSchemas)
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
                  toolSchemas: seq[ToolDefinition]): TaskResult =
  ## Execute a task with the given agent in an isolated context
  debug(fmt("Starting task execution with agent '{agent.name}': {description}"))

  try:
    # Get API key for the model
    let apiKey = configModule.readKeyForModel(modelConfig)
    if apiKey.len == 0:
      # Check if this is a local server that doesn't require authentication
      let baseUrl = modelConfig.baseUrl.toLower()
      if baseUrl.contains("localhost") or baseUrl.contains("127.0.0.1"):
        # Local server - use empty string as valid key
        discard
      else:
        # Remote server - API key required but not found
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          toolCalls: 0,
          tokensUsed: 0,
          error: fmt("No API key configured for model '{modelConfig.nickname}'")
        )

    # Build task-specific system prompt
    let systemPrompt = buildTaskSystemPrompt(agent, description)

    # Create initial messages for the task
    var initialMessages: seq[Message] = @[]

    # Add system prompt
    initialMessages.add(Message(
      role: mrSystem,
      content: systemPrompt
    ))

    # Add task description as user message
    initialMessages.add(Message(
      role: mrUser,
      content: description
    ))

    # Execute task conversation loop (max 10 turns)
    debug("Executing task conversation")
    var conversationMessages = initialMessages
    var totalTokens = 0
    var totalToolCalls = 0
    let maxTurns = getMaxTurnsForAgent(some(agent))
    var turn = 0
    var taskComplete = false

    while turn < maxTurns and not taskComplete:
      turn.inc()
      debug(fmt("Task turn {turn}/{maxTurns}"))

      # Send request via channels
      let requestId = fmt("task_{agent.name}_{turn}_{epochTime()}")
      let request = APIRequest(
        kind: arkChatRequest,
        requestId: requestId,
        messages: conversationMessages,
        model: modelConfig.model,
        modelNickname: modelConfig.nickname,
        maxTokens: 8192,
        temperature: 0.7,
        baseUrl: modelConfig.baseUrl,
        apiKey: apiKey,
        enableTools: true,  # Enable tools for task execution
        tools: some(toolSchemas)
      )

      if not trySendAPIRequest(channels, request):
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          toolCalls: totalToolCalls,
          tokensUsed: totalTokens,
          error: "Failed to send API request"
        )

      # Collect response
      var assistantContent = ""
      var toolCalls: seq[LLMToolCall] = @[]
      var responseComplete = false
      var attempts = 0
      const maxAttempts = 3000  # 5 minutes per turn

      while attempts < maxAttempts and not responseComplete:
        var response: APIResponse
        if tryReceiveAPIResponse(channels, response):
          if response.requestId == requestId:
            case response.kind:
            of arkReady:
              debug("API ready")
            of arkStreamChunk:
              assistantContent.add(response.content)
              # Check for tool calls in chunk
              if response.toolCalls.isSome():
                for tc in response.toolCalls.get():
                  toolCalls.add(tc)
                  totalToolCalls.inc()
                  debug(fmt("Tool call: {tc.function.name}"))
            of arkStreamComplete:
              let usage = response.usage
              totalTokens += usage.inputTokens + usage.outputTokens
              responseComplete = true
            of arkStreamError:
              return TaskResult(
                success: false,
                summary: "",
                artifacts: @[],
                toolCalls: totalToolCalls,
                tokensUsed: totalTokens,
                error: fmt("API error: {response.error}")
              )
            else:
              discard

        sleep(100)
        attempts.inc()

      # Exit loop if we have tool calls (don't wait for arkStreamComplete)
      if toolCalls.len > 0:
        debug(fmt"Exited response loop with {toolCalls.len} tool calls (will execute)")
        break

      if not responseComplete and attempts >= maxAttempts:
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          toolCalls: totalToolCalls,
          tokensUsed: totalTokens,
          error: "Turn timed out"
        )

      # Add assistant message to history (always add if has content or tool calls)
      if assistantContent.len > 0 or toolCalls.len > 0:
        conversationMessages.add(Message(
          role: mrAssistant,
          content: assistantContent,
          toolCalls: if toolCalls.len > 0: some(toolCalls) else: none(seq[LLMToolCall])
        ))

      # Check for completion signal
      let completionSignal = detectCompletionSignal(assistantContent)
      if completionSignal != csNone:
        debug(fmt"Completion signal detected in task: {completionSignal}")

      # Check if task is complete (completion signal OR no tool calls)
      taskComplete = completionSignal != csNone or toolCalls.len == 0

      if not taskComplete:
        # Execute tools and add results to conversation
        let agentContext = AgentContext(
          isMainAgent: false,
          agent: agent
        )

        for toolCall in toolCalls:
          debug(fmt("Executing tool: {toolCall.function.name}"))

          # Validate tool is allowed for this agent
          if not isToolAllowed(agentContext, toolCall.function.name):
            let allowedTools = agent.allowedTools.join(", ")
            let errorMsg = fmt("Tool '{toolCall.function.name}' not allowed for agent '{agent.name}'. Allowed tools: {allowedTools}")
            warn(errorMsg)
            conversationMessages.add(Message(
              role: mrTool,
              content: fmt("Error: {errorMsg}"),
              toolCallId: some(toolCall.id)
            ))
            continue

          # Send tool request to tool worker
          let toolRequest = ToolRequest(
            kind: trkExecute,
            requestId: toolCall.id,
            toolName: toolCall.function.name,
            arguments: toolCall.function.arguments,
            agentName: agent.name  # Pass agent name for permission validation
          )

          if not trySendToolRequest(channels, toolRequest):
            warn(fmt("Failed to send tool request for {toolCall.function.name}"))
            conversationMessages.add(Message(
              role: mrTool,
              content: "Error: Failed to send tool request",
              toolCallId: some(toolCall.id)
            ))
            continue

          # Wait for tool response with timeout
          var toolResponseReceived = false
          var toolAttempts = 0
          const maxToolAttempts = 3000  # 5 minutes per tool

          while toolAttempts < maxToolAttempts and not toolResponseReceived:
            let maybeResponse = tryReceiveToolResponse(channels)
            if maybeResponse.isSome():
              let toolResponse = maybeResponse.get()
              if toolResponse.requestId == toolCall.id:
                # Add tool result to conversation
                let toolContent = if toolResponse.kind == trkResult:
                  toolResponse.output
                else:
                  fmt("Error: {toolResponse.error}")

                conversationMessages.add(Message(
                  role: mrTool,
                  content: toolContent,
                  toolCallId: some(toolCall.id)
                ))

                toolResponseReceived = true
                debug(fmt("Tool {toolCall.function.name} completed successfully"))
                break

            sleep(100)
            toolAttempts.inc()

          if not toolResponseReceived:
            warn(fmt("Tool execution timed out for {toolCall.function.name}"))
            conversationMessages.add(Message(
              role: mrTool,
              content: "Error: Tool execution timed out",
              toolCallId: some(toolCall.id)
            ))

        # Continue conversation with tool results (don't mark as complete)
        taskComplete = false

    if not taskComplete:
      return TaskResult(
        success: false,
        summary: "",
        artifacts: @[],
        toolCalls: totalToolCalls,
        tokensUsed: totalTokens,
        error: fmt("Task did not complete within {maxTurns} turns")
      )

    # Generate summary of results
    debug("Generating summary")
    let summary = generateSummary(conversationMessages, modelConfig, channels, apiKey, toolSchemas)

    # Extract artifacts (file paths) from conversation
    let artifacts = extractArtifacts(conversationMessages)
    debug(fmt("Extracted {artifacts.len} artifacts: {artifacts.join(\", \")}"))

    return TaskResult(
      success: true,
      summary: summary,
      artifacts: artifacts,
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
      toolCalls: 0,
      tokensUsed: 0,
      error: fmt("Task execution failed: {e.msg}")
    )
