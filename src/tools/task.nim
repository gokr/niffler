## Task Tool
##
## This tool allows the main agent to create autonomous tasks executed by specialized agents.
##
## Features:
## - Agent selection by name
## - Task description with context
## - Isolated execution environment
## - Result condensation (summary back to main agent)
##
## Usage:
## {
##   "agent_type": "general-purpose",
##   "description": "Research how Nim's async system works and summarize key concepts",
##   "estimated_complexity": "moderate"
## }

import std/[json, logging, strformat, strutils]
import ../types/[agents, config]
import ../core/[config as configModule]

proc getArgStr(args: JsonNode, key: string): string =
  ## Extract string argument from JSON node
  if args.hasKey(key):
    return args[key].getStr()
  return ""

proc executeTask*(args: JsonNode): string {.gcsafe.} =
  ## Execute a task with the specified agent
  {.gcsafe.}:
    try:
      # Parse arguments
      let agentType = getArgStr(args, "agent_type")
      let description = getArgStr(args, "description")
      let complexity = if args.hasKey("estimated_complexity"): args["estimated_complexity"].getStr() else: "moderate"

      debug(fmt("Task tool called: agent={agentType}, complexity={complexity}"))

      # Handle special "list" command to show available agents
      if agentType == "list":
        let agentsDir = getAgentsDir()
        let agents = loadAgentDefinitions(agentsDir)
        var agentList = "Available agents:\n\n"
        for agent in agents:
          let toolsList = agent.allowedTools.join(", ")
          agentList.add(fmt("- {agent.name}: {agent.description}\n"))
          agentList.add(fmt("  Tools: {toolsList}\n\n"))
        return $ %*{
          "success": true,
          "agents": agentList
        }

      # Load agent definition
      let agentsDir = getAgentsDir()
      let agents = loadAgentDefinitions(agentsDir)
      let agent = agents.findAgent(agentType)

      if agent.name.len == 0:
        return $ %*{
          "error": fmt("Agent '{agentType}' not found. Use agent_type='list' to see available agents.")
        }

      # Get current model config (TODO: make this accessible from gcsafe context)
      # For now, use a placeholder - this will be improved when we integrate with the full system
      let modelConfig = ModelConfig(
        nickname: "placeholder",
        baseUrl: "",
        model: "",
        context: 0,
        enabled: true
      )

      # Execute the task (placeholder for now)
      # TODO: Get actual channels pointer and execute task
      let taskResult = TaskResult(
        success: true,
        summary: fmt("Task execution for agent '{agentType}' not yet fully implemented. Task description: {description}"),
        artifacts: @[],
        toolCalls: 0,
        tokensUsed: 0,
        error: ""
      )

      # Return the result
      return $ %*{
        "success": taskResult.success,
        "summary": taskResult.summary,
        "artifacts": taskResult.artifacts,
        "tool_calls": taskResult.toolCalls,
        "tokens_used": taskResult.tokensUsed,
        "error": taskResult.error
      }

    except Exception as e:
      error(fmt("Task tool execution failed: {e.msg}"))
      return $ %*{
        "error": fmt("Task tool error: {e.msg}")
      }
