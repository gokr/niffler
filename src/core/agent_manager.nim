## Agent Manager
##
## This module manages the lifecycle of agent processes for the Niffler multi-agent system.
## Key capabilities:
## - Spawn agent processes based on configuration
## - Track running agents (PID, status)
## - Prevent duplicate agent spawns
## - Wait for agent readiness via NATS presence

import std/[osproc, os, strformat, times, strutils, sequtils]
import ../types/config
import ../types/agents
import nats_client
from std/options import isSome, isNone, get
import natswrapper
import ../core/session
when defined(posix):
  import posix

type
  SpawnedAgent* = object
    config*: AgentConfig
    pid*: int
    startTime*: times.Time

  RunningAgentInfo* = object
    pid*: int
    baseAgentName*: string
    routingName*: string
    modelName*: string

proc formatRunningAgentLabel*(agent: RunningAgentInfo): string =
  ## Format a running agent label for CLI display
  if agent.routingName.len > 0 and agent.routingName != agent.baseAgentName:
    return fmt"{agent.routingName} ({agent.baseAgentName})"
  agent.baseAgentName

proc parseRunningAgent(line: string): RunningAgentInfo =
  ## Parse a ps output line into running agent info
  let trimmed = line.strip()
  if trimmed.len == 0:
    return

  let firstSpace = trimmed.find({' ', '\t'})
  if firstSpace <= 0:
    return

  let pidStr = trimmed[0..<firstSpace].strip()
  let argsStr = trimmed[firstSpace + 1..^1].strip()
  if pidStr.len == 0 or argsStr.len == 0:
    return

  try:
    result.pid = parseInt(pidStr)
  except ValueError:
    return

  let parts = argsStr.splitWhitespace()
  var baseAgentName = ""
  for i, part in parts:
    if part == "agent" and i + 1 < parts.len:
      baseAgentName = parts[i + 1]
      break
    if part == "--agent" and i + 1 < parts.len:
      baseAgentName = parts[i + 1]
      break
    if part.startsWith("--agent="):
      baseAgentName = part[8..^1].strip()
      break

  if baseAgentName.len == 0:
    result.pid = 0
    return

  result.baseAgentName = baseAgentName
  result.routingName = result.baseAgentName

  for part in parts:
    if part.startsWith("--nick="):
      let nick = part[7..^1].strip()
      if nick.len > 0:
        result.routingName = nick
    elif part.startsWith("--model="):
      result.modelName = part[8..^1].strip()

proc listRunningAgentProcesses*(): seq[RunningAgentInfo] =
  ## List running niffler agent processes from the local process table
  let (output, exitCode) = execCmdEx("ps -eo pid=,args=")
  if exitCode != 0:
    return @[]

  for line in output.splitLines():
    if "niffler" notin line or (" agent " notin line and "--agent" notin line):
      continue

    let parsed = parseRunningAgent(line)
    if parsed.pid > 0 and parsed.baseAgentName.len > 0:
      result.add(parsed)

proc stopAgent*(routingName: string): bool =
  ## Stop a running agent by routing name (nick or base name)
  let runningAgents = listRunningAgentProcesses().filterIt(it.routingName == routingName)
  if runningAgents.len != 1:
    return false

  when defined(posix):
    result = kill(Pid(runningAgents[0].pid), SIGTERM) == 0
  else:
    discard execCmdEx(fmt"kill {runningAgents[0].pid}")
    result = true

proc fallbackAgentConfig(agentId: string): AgentConfig =
  AgentConfig(
    id: agentId,
    name: agentId,
    description: "",
    model: "",
    capabilities: @[],
    toolPermissions: @[],
    autoStart: false
  )

proc loadAgentRuntimeConfig(agentId: string): AgentConfig =
  ## Load runtime agent configuration from the agent markdown definition.
  let agentsDir = session.getAgentsDir()
  let agentFile = agentsDir / agentId & ".md"

  if not fileExists(agentFile):
    return fallbackAgentConfig(agentId)

  let content = readFile(agentFile)
  let agentDef = parseAgentDefinition(content, agentFile)
  return AgentConfig(
    id: agentId,
    name: agentId,
    description: agentDef.description,
    model: agentDef.model.get(""),
    capabilities: agentDef.capabilities,
    toolPermissions: agentDef.allowedTools,
    autoStart: agentDef.autoStart
  )

proc startAgent*(agentId: string, agentNick: string = "", modelOverride: string = "", nifflerPath: string = "./src/niffler"): SpawnedAgent =
  ## Spawn an agent process
  ## Returns: SpawnedAgent with PID
  ## Note: Agent displays to its own terminal (no stdin/stdout redirection)

  let agentConfig = loadAgentRuntimeConfig(agentId)

  # Load agent definition to get model configuration
  var agentArgs = @["--agent", agentId]
  if agentNick.len > 0:
    agentArgs.add("--nick=" & agentNick)

  if modelOverride.len > 0:
    agentArgs.add("--model=" & modelOverride)

  try:
    # Try to load agent definition from agents directory
    let agentsDir = session.getAgentsDir()
    let agentFile = agentsDir / agentId & ".md"
    if modelOverride.len == 0 and fileExists(agentFile):
      let content = readFile(agentFile)
      let agentDef = parseAgentDefinition(content, agentFile)
      if agentDef.model.isSome():
        # Pass model from agent definition
        agentArgs.add("--model=" & agentDef.model.get())
        echo fmt"→ Using model from agent definition: {agentDef.model.get()}"
  except Exception:
    # If we can't load agent definition, spawn without model parameter
    # The agent will use its default logic (first model or fallback)
    discard

  # Spawn agent process
  # Use poUsePath so agent inherits terminal for display
  let process = startProcess(
    command = nifflerPath,
    args = agentArgs,
    options = {poUsePath}
  )

  # Get PID immediately after spawn
  let pid = process.processID()

  # Create tracking record
  result = SpawnedAgent(
    config: agentConfig,
    pid: pid,
    startTime: times.getTime()
  )

  let displayName = if agentNick.len > 0: fmt"@{agentNick} ({agentId})" else: fmt"@{agentId}"
  echo fmt"→ Spawned {displayName} (pid: {pid})"

proc waitForAgentReady*(natsClient: NifflerNatsClient, agentId: string, timeoutSec: int = 10): bool =
  ## Poll for agent presence heartbeat with timeout
  ## Returns: true if agent ready, false if timeout

  echo fmt"⏳ Waiting for @{agentId} to be ready..."

  let startTime = times.getTime()
  let timeoutMs = timeoutSec * 1000

  while (times.getTime() - startTime).inMilliseconds < timeoutMs:
    if natsClient.isPresent(agentId):
      echo fmt"✓ @{agentId} is ready"
      return true
    sleep(500)  # Poll every 500ms

  echo fmt"✗ @{agentId} failed to start within {timeoutSec}s"
  return false

proc autoStartAgents*(config: Config, natsClient: NifflerNatsClient, nifflerPath: string = "./src/niffler"): seq[SpawnedAgent] =
  ## Auto-start agents marked with auto_start: true
  ## Returns: List of successfully spawned agents

  result = @[]

  # Check if auto-start enabled
  if config.master.isNone or not config.master.get().autoStartAgents:
    echo "→ Auto-start disabled in master configuration"
    return result

  echo "→ Auto-starting agents..."

  let agents = loadAgentDefinitions(session.getAgentsDir())

  for agent in agents:
    if not agent.autoStart:
      continue

    echo fmt"Checking @{agent.name}..."

    # Check if already running (avoid duplicates)
    if natsClient.isPresent(agent.name):
      echo fmt"✓ @{agent.name} already running"
      continue

    # Check niffler binary exists
    if not fileExists(nifflerPath):
      let absPath = getCurrentDir() / nifflerPath
      if not fileExists(absPath):
        echo fmt"✗ Niffler binary not found: {nifflerPath}"
        echo fmt"✗ Skipping auto-start of @{agent.name}"
        continue
      # Note: We could use absolute path here, but keeping simple for MVP

    # Spawn agent
    try:
      let spawned = startAgent(agent.name, nifflerPath = nifflerPath)

      # Wait for agent readiness (heartbeat)
      if waitForAgentReady(natsClient, agent.name, timeoutSec = 15):
        result.add(spawned)
        echo fmt"✓ @{agent.name} auto-started successfully"
      else:
        echo fmt"✗ @{agent.name} failed to report ready (timeout)"

    except Exception as e:
      echo fmt"✗ Failed to spawn @{agent.name}: {e.msg}"
      # Continue with other agents

  # Summary
  if result.len > 0:
    echo fmt"✓ Auto-started {result.len} agent(s)"
  else:
    echo "→ No agents auto-started"

proc getAgentConfig*(agentId: string): AgentConfig =
  ## Get agent runtime configuration from the markdown definition
  let agentsDir = session.getAgentsDir()
  let agentFile = agentsDir / agentId & ".md"
  if not fileExists(agentFile):
    raise newException(ValueError, fmt"Agent '{agentId}' not found")

  let config = loadAgentRuntimeConfig(agentId)
  return config

# Required imports for configuration access
# Note: These should be available from the calling context
