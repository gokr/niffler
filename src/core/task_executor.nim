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

import std/[logging, strformat]
import ../types/[messages, config, agents]
import channels

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

proc executeTask*(agent: AgentDefinition, description: string,
                  modelConfig: ModelConfig, channels: ptr ThreadChannels): TaskResult =
  ## Execute a task with the given agent in an isolated context
  debug(fmt("Starting task execution with agent '{agent.name}': {description}"))

  try:
    # Build task-specific system prompt
    let systemPrompt = buildTaskSystemPrompt(agent, description)

    # Create initial user message with the task
    let userMessage = Message(
      role: mrUser,
      content: description
    )

    # Create a minimal message history for this task (not saved to database)
    var taskMessages: seq[Message] = @[userMessage]

    # TODO: Execute the task by calling the API worker
    # For now, return a placeholder result
    return TaskResult(
      success: true,
      summary: fmt("Task would be executed with agent '{agent.name}'"),
      artifacts: @[],
      toolCalls: 0,
      tokensUsed: 0,
      error: "Task execution not yet implemented - placeholder result"
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
