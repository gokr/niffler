## Agent Manager
##
## This module manages the lifecycle of agent processes for the Niffler multi-agent system.
## Key capabilities:
## - Spawn agent processes based on configuration
## - Track running agents (PID, status)
## - Prevent duplicate agent spawns
## - Wait for agent readiness via NATS presence

import std/[osproc, os, strformat, times]
import ../types/config
import nats_client, config
from std/options import isSome, isNone, get
import natswrapper

type
  SpawnedAgent* = object
    config*: AgentConfig
    pid*: int
    startTime*: times.Time

proc startAgent*(agentId: string, nifflerPath: string = "./src/niffler"): SpawnedAgent =
  ## Spawn an agent process
  ## Returns: SpawnedAgent with PID
  ## Note: Agent displays to its own terminal (no stdin/stdout redirection)

  # Find agent configuration
  let globalConfig = getGlobalConfig()
  var agentConfig: AgentConfig

  var found = false
  for agent in globalConfig.agents:
    if agent.id == agentId:
      agentConfig = agent
      found = true
      break

  if not found:
    raise newException(ValueError, fmt"Agent '{agentId}' not found in configuration")

  # Spawn agent process
  # Use poUsePath so agent inherits terminal for display
  let process = startProcess(
    command = nifflerPath,
    args = ["--agent", agentId],
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

  echo fmt"→ Spawned @{agentId} (pid: {pid})"

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

  # Filter agents with auto_start: true
  for agent in config.agents:
    if not agent.autoStart:
      continue

    echo fmt"Checking @{agent.id}..."

    # Check if already running (avoid duplicates)
    if natsClient.isPresent(agent.id):
      echo fmt"✓ @{agent.id} already running"
      continue

    # Check niffler binary exists
    if not fileExists(nifflerPath):
      let absPath = getCurrentDir() / nifflerPath
      if not fileExists(absPath):
        echo fmt"✗ Niffler binary not found: {nifflerPath}"
        echo fmt"✗ Skipping auto-start of @{agent.id}"
        continue
      # Note: We could use absolute path here, but keeping simple for MVP

    # Spawn agent
    try:
      let spawned = startAgent(agent.id, nifflerPath)

      # Wait for agent readiness (heartbeat)
      if waitForAgentReady(natsClient, agent.id, timeoutSec = 15):
        result.add(spawned)
        echo fmt"✓ @{agent.id} auto-started successfully"
      else:
        echo fmt"✗ @{agent.id} failed to report ready (timeout)"

    except Exception as e:
      echo fmt"✗ Failed to spawn @{agent.id}: {e.msg}"
      # Continue with other agents

  # Summary
  if result.len > 0:
    echo fmt"✓ Auto-started {result.len} agent(s)"
  else:
    echo "→ No agents auto-started"

proc getAgentConfig*(agentId: string): AgentConfig =
  ## Get configuration for a specific agent by ID
  ## Raises: ValueError if agent not found

  let globalConfig = getGlobalConfig()
  for agent in globalConfig.agents:
    if agent.id == agentId:
      return agent

  raise newException(ValueError, fmt"Agent '{agentId}' not found in configuration")

# Required imports for configuration access
# Note: These should be available from the calling context