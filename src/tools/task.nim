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
import ../core/[config as configModule, task_executor, channels, session as sessionMod]

# Thread-local storage for channels (set by tool worker)
var taskToolChannels* {.threadvar.}: ptr ThreadChannels
var taskToolModelConfig* {.threadvar.}: ModelConfig

proc setTaskToolContext*(channels: ptr ThreadChannels, modelConfig: ModelConfig) =
  ## Set the context needed for task execution (called by tool worker)
  taskToolChannels = channels
  taskToolModelConfig = modelConfig

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
        let agentsDir = sessionMod.getAgentsDir()
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
      let agentsDir = sessionMod.getAgentsDir()
      let agents = loadAgentDefinitions(agentsDir)
      let agent = agents.findAgent(agentType)

      if agent.name.len == 0:
        return $ %*{
          "error": fmt("Agent '{agentType}' not found. Use agent_type='list' to see available agents.")
        }

      # Check if we have the required context for task execution
      if taskToolChannels.isNil:
        return $ %*{
          "error": "Task execution context not available. Task tool requires channels to be set."
        }

      # Get model configuration
      let modelNickname = if args.hasKey("model_nickname"): args["model_nickname"].getStr() else: ""
      let modelConfig = if modelNickname.len > 0:
        # User specified a model
        let config = configModule.loadConfig()
        var foundModel: ModelConfig
        var found = false
        for m in config.models:
          if m.nickname == modelNickname:
            foundModel = m
            found = true
            break
        if not found:
          return $ %*{
            "error": fmt("Model '{modelNickname}' not found in configuration")
          }
        foundModel
      elif taskToolModelConfig.nickname.len > 0:
        # Use the stored model config from context
        taskToolModelConfig
      else:
        return $ %*{
          "error": "No model specified and no default model available"
        }

      # Execute the task using the task executor
      let taskResult = task_executor.executeTask(agent, description, modelConfig, taskToolChannels)

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
