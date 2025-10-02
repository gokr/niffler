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

import std/[logging, strformat, times, options, os]
import ../types/[messages, config, agents]
import channels
import config as configModule

# Placeholder implementations to avoid circular imports
# The real implementations will be available when linked with api.nim
proc sendChatRequestAsync(channels: ptr ThreadChannels, messages: seq[Message],
                          modelConfig: ModelConfig, requestId: string, apiKey: string,
                          maxTokens: int = 8192, temperature: float = 0.7): bool =
  error("sendChatRequestAsync placeholder called - should be linked from api.nim")
  return false

proc tryRecvAPIResponse(channels: ptr ThreadChannels, response: var APIResponse): bool =
  error("tryRecvAPIResponse placeholder called - should be linked from api.nim")
  return false

proc buildTaskSystemPrompt(agent: AgentDefinition, taskDescription: string): string =
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
                     channels: ptr ThreadChannels, apiKey: string): string =
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

  # Send summary request
  let requestId = "task_summary_" & $epochTime()
  if not sendChatRequestAsync(channels, summaryMessages, modelConfig, requestId, apiKey):
    return "Failed to send summary request"

  # Collect summary response
  var summary = ""
  var responseComplete = false
  var attempts = 0
  const maxAttempts = 600  # 1 minute max

  while attempts < maxAttempts and not responseComplete:
    var response: APIResponse
    if tryRecvAPIResponse(channels, response):
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
                  modelConfig: ModelConfig, channels: ptr ThreadChannels): TaskResult =
  ## Execute a task with the given agent in an isolated context
  debug(fmt("Starting task execution with agent '{agent.name}': {description}"))

  try:
    # Get API key for the model
    let apiKey = configModule.readKeyForModel(modelConfig)
    if apiKey.len == 0:
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
    const maxTurns = 10
    var turn = 0
    var taskComplete = false

    while turn < maxTurns and not taskComplete:
      turn.inc()
      debug(fmt("Task turn {turn}/{maxTurns}"))

      # Send request
      let requestId = fmt("task_{agent.name}_{turn}_{epochTime()}")
      if not sendChatRequestAsync(channels, conversationMessages, modelConfig, requestId, apiKey):
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
        if tryRecvAPIResponse(channels, response):
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

      if not responseComplete:
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          toolCalls: totalToolCalls,
          tokensUsed: totalTokens,
          error: "Turn timed out"
        )

      # Add assistant message to history
      if assistantContent.len > 0:
        conversationMessages.add(Message(
          role: mrAssistant,
          content: assistantContent
        ))

      # Check if task is complete
      if toolCalls.len == 0:
        taskComplete = true
      else:
        # Tool execution required - not yet implemented
        return TaskResult(
          success: false,
          summary: "",
          artifacts: @[],
          toolCalls: totalToolCalls,
          tokensUsed: totalTokens,
          error: fmt("Task requires tool execution ({toolCalls.len} calls) - integration pending")
        )

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
    let summary = generateSummary(conversationMessages, modelConfig, channels, apiKey)

    return TaskResult(
      success: true,
      summary: summary,
      artifacts: @[],  # TODO: Extract file references from conversation
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
