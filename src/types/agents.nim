## Agent type definitions, validation, and markdown parsing

import std/[strutils, os, options]

type
  AgentValidationError* = enum
    aveNone = "Valid"
    aveMissingDescription = "Missing '## Description' section"
    aveMissingTools = "Missing '## Allowed Tools' section"
    aveMissingPrompt = "Missing '## System Prompt' section"
    aveEmptyTools = "No tools specified"
    aveParseError = "Markdown parsing failed"

  AgentStatus* = object
    valid*: bool
    error*: AgentValidationError
    unknownTools*: seq[string]

  AgentDefinition* = object
    name*: string
    description*: string
    allowedTools*: seq[string]
    systemPrompt*: string
    filePath*: string
    maxTurns*: Option[int]

  AgentContext* = object
    ## Context about which agent is executing (for tool access control)
    agent*: AgentDefinition
    isMainAgent*: bool  ## True if this is the main agent (has full access)

# Predefined main agent context (full access to all tools)
proc createMainAgentContext*(): AgentContext =
  ## Create an agent context for the main agent with full tool access
  AgentContext(
    agent: AgentDefinition(
      name: "main",
      description: "Main Niffler agent with full tool access",
      allowedTools: @[],  # Empty means all tools allowed
      systemPrompt: "",
      filePath: ""
    ),
    isMainAgent: true
  )

proc createAgentContext*(agent: AgentDefinition): AgentContext =
  ## Create an agent context for a specific agent
  AgentContext(
    agent: agent,
    isMainAgent: false
  )

proc isToolAllowed*(context: AgentContext, toolName: string): bool =
  ## Check if a tool is allowed for this agent context
  if context.isMainAgent:
    return true  # Main agent has access to all tools

  # For task agents, check the whitelist
  return toolName in context.agent.allowedTools

# Task execution types
type
  TaskStatus* = enum
    tsPending = "pending"
    tsRunning = "running"
    tsCompleted = "completed"
    tsFailed = "failed"

  TaskResult* = object
    success*: bool
    summary*: string              ## LLM-generated summary of findings
    artifacts*: seq[string]       ## File paths created/read
    toolCalls*: int               ## Number of tool calls made
    tokensUsed*: int              ## Total tokens consumed
    error*: string                ## Error message if failed

  TaskExecution* = object
    id*: int                      ## Database ID
    conversationId*: int          ## Parent conversation ID
    agentName*: string            ## Agent executing the task
    description*: string          ## Task description
    status*: TaskStatus           ## Current status
    startedAt*: string            ## ISO timestamp
    completedAt*: string          ## ISO timestamp
    result*: TaskResult           ## Final result

proc parseAgentDefinition*(mdContent: string, filePath: string): AgentDefinition =
  ## Parse markdown file into agent definition
  result.filePath = filePath
  result.name = filePath.splitFile.name

  var lines = mdContent.splitLines()
  var currentSection = ""
  var descriptionLines: seq[string]
  var toolLines: seq[string]
  var promptLines: seq[string]

  for line in lines:
    if line.startsWith("## Description"):
      currentSection = "description"
      continue
    elif line.startsWith("## Allowed Tools"):
      currentSection = "tools"
      continue
    elif line.startsWith("## System Prompt"):
      currentSection = "prompt"
      continue
    elif line.startsWith("#"):
      currentSection = ""
      continue

    case currentSection
    of "description":
      if line.strip().len > 0:
        descriptionLines.add(line.strip())
    of "tools":
      let toolLine = line.strip()
      if toolLine.startsWith("-") or toolLine.startsWith("*"):
        let tool = toolLine[1..^1].strip()
        if tool.len > 0:
          toolLines.add(tool)
    of "prompt":
      promptLines.add(line)
    else:
      discard

  result.description = descriptionLines.join(" ")
  result.allowedTools = toolLines
  result.systemPrompt = promptLines.join("\n").strip()

proc validateAgentDefinition*(agent: AgentDefinition, knownTools: seq[string]): AgentStatus =
  ## Validate agent definition and return status
  result.valid = true
  result.error = aveNone
  result.unknownTools = @[]

  if agent.description.len == 0:
    return AgentStatus(valid: false, error: aveMissingDescription)

  if agent.allowedTools.len == 0:
    return AgentStatus(valid: false, error: aveMissingTools)

  if agent.systemPrompt.len == 0:
    return AgentStatus(valid: false, error: aveMissingPrompt)

  for tool in agent.allowedTools:
    if tool notin knownTools:
      result.unknownTools.add(tool)

proc loadAgentDefinitions*(agentsDir: string): seq[AgentDefinition] =
  ## Load all agent definitions from directory
  result = @[]

  if not dirExists(agentsDir):
    return result

  for file in walkFiles(agentsDir / "*.md"):
    try:
      let content = readFile(file)
      let agent = parseAgentDefinition(content, file)
      result.add(agent)
    except Exception as e:
      echo "Warning: Failed to load agent from ", file, ": ", e.msg

proc findAgent*(agents: seq[AgentDefinition], name: string): AgentDefinition =
  ## Find agent by name, returns empty AgentDefinition if not found
  for agent in agents:
    if agent.name == name:
      return agent
  return AgentDefinition()

proc hasAgent*(agents: seq[AgentDefinition], name: string): bool =
  ## Check if agent exists by name
  for agent in agents:
    if agent.name == name:
      return true
  return false
