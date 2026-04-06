## Agent type definitions, validation, and markdown parsing

import std/[strutils, os, options, streams, tables]
import yaml

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
    name*: string                ## Routing name, derived from file name
    description*: string
    allowedTools*: seq[string]
    capabilities*: seq[string]
    systemPrompt*: string
    filePath*: string
    maxTurns*: Option[int]
    model*: Option[string]  # Default model for this agent
    autoStart*: bool
    persistent*: bool

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
      capabilities: @[],
      systemPrompt: "",
      filePath: "",
      model: none(string),  # Main agent uses default model selection
      autoStart: false,
      persistent: true
    ),
    isMainAgent: true
  )

proc splitYamlFrontmatter(content: string): tuple[frontmatter: string, body: string] =
  let lines = content.splitLines()
  if lines.len < 2 or lines[0] != "---":
    return ("", content)

  var endIndex = -1
  for i in 1..<lines.len:
    if lines[i] == "---":
      endIndex = i
      break

  if endIndex < 0:
    return ("", content)

  result.frontmatter = lines[1..<endIndex].join("\n")
  result.body = lines[(endIndex + 1)..<lines.len].join("\n").strip()

proc parseYamlFrontmatter(frontmatter: string): YamlNode =
  var stream = newStringStream(frontmatter)
  var root: YamlNode
  load(stream, root)
  stream.close()
  result = root

proc getYamlString(node: YamlNode, key: string, default: string = ""): string =
  if node.kind != yMapping:
    return default
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == yScalar:
      return v.content
  return default

proc getYamlSeq(node: YamlNode, key: string): seq[string] =
  result = @[]
  if node.kind != yMapping:
    return
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == ySequence:
      for item in v.elems:
        if item.kind == yScalar:
          result.add(item.content)

proc getYamlBool(node: YamlNode, key: string, default: bool): bool =
  if node.kind != yMapping:
    return default
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == yScalar:
      let content = v.content.toLowerAscii()
      return content == "true" or content == "yes" or content == "1"
  return default

proc getYamlInt(node: YamlNode, key: string): Option[int] =
  if node.kind != yMapping:
    return none(int)
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        return some(parseInt(v.content))
      except ValueError:
        return none(int)
  return none(int)

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
    artifacts*: seq[string]       ## File paths created/edited
    tempArtifacts*: seq[string]   ## Temporary files (e.g., fetch cache)
    toolCalls*: int               ## Number of tool calls made
    tokensUsed*: int              ## Total tokens consumed
    messages*: int                ## Number of messages in conversation
    durationMs*: int              ## Duration in milliseconds
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
  result.autoStart = false
  result.persistent = true

  let (frontmatter, bodyContent) = splitYamlFrontmatter(mdContent)

  if frontmatter.len > 0:
    let yamlNode = parseYamlFrontmatter(frontmatter)

    let description = getYamlString(yamlNode, "description")
    if description.len > 0:
      result.description = description

    let allowedTools = getYamlSeq(yamlNode, "allowed_tools")
    if allowedTools.len > 0:
      result.allowedTools = allowedTools

    let capabilities = getYamlSeq(yamlNode, "capabilities")
    if capabilities.len > 0:
      result.capabilities = capabilities

    let model = getYamlString(yamlNode, "model")
    if model.len > 0:
      result.model = some(model)

    let maxTurns = getYamlInt(yamlNode, "max_turns")
    if maxTurns.isSome():
      result.maxTurns = maxTurns

    result.autoStart = getYamlBool(yamlNode, "auto_start", false)
    result.persistent = getYamlBool(yamlNode, "persistent", true)

  var lines = bodyContent.splitLines()
  var currentSection = ""
  var descriptionLines: seq[string]
  var toolLines: seq[string]
  var capabilityLines: seq[string]
  var promptLines: seq[string]
  var modelLine = ""  # Model should be a single line

  for line in lines:
    if line.startsWith("## Description"):
      currentSection = "description"
      continue
    elif line.startsWith("## Model"):
      currentSection = "model"
      continue
    elif line.startsWith("## Allowed Tools"):
      currentSection = "tools"
      continue
    elif line.startsWith("## Capabilities"):
      currentSection = "capabilities"
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
    of "model":
      # Model is a single line (the model nickname)
      if line.strip().len > 0 and modelLine.len == 0:
        modelLine = line.strip()
    of "tools":
      let toolLine = line.strip()
      if toolLine.startsWith("-") or toolLine.startsWith("*"):
        let tool = toolLine[1..^1].strip()
        if tool.len > 0:
          toolLines.add(tool)
    of "capabilities":
      let capabilityLine = line.strip()
      if capabilityLine.startsWith("-") or capabilityLine.startsWith("*"):
        let capability = capabilityLine[1..^1].strip()
        if capability.len > 0:
          capabilityLines.add(capability)
    of "prompt":
      promptLines.add(line)
    else:
      discard

  if result.description.len == 0:
    result.description = descriptionLines.join(" ")

  if result.allowedTools.len == 0:
    result.allowedTools = toolLines

  if result.capabilities.len == 0:
    result.capabilities = capabilityLines

  result.systemPrompt = promptLines.join("\n").strip()

  if modelLine.len > 0 and result.model.isNone():
    result.model = some(modelLine)

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
