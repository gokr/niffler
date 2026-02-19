## Agent Manager
##
## This module manages the lifecycle of agent processes for the Niffler autonomous agent system.
## Key capabilities:
## - Spawn agent processes based on configuration
## - Track running agents (PID, status)
## - Prevent duplicate agent spawns
## - Track agent readiness via database presence
##
## NOTE: This module has been refactored to remove NATS dependencies.
## Agents now communicate via the database instead of NATS.

import std/[osproc, os, strformat, times, options]
import ../types/config
import ../types/agents
import config
import ../core/session
import ../core/database
import ../agent/messaging

type
  SpawnedAgent* = object
    config*: AgentConfig
    process*: Process
    startTime*: DateTime

var spawnedAgents*: seq[SpawnedAgent] = @[]

proc spawnAgent*(agentConfig: AgentConfig, nifflerPath: string = "./src/niffler"): Option[SpawnedAgent] =
  ## Spawn a new agent process
  ## Returns the spawned agent info or none if failed
  
  # Check if agent is already running
  for spawned in spawnedAgents:
    if spawned.config.id == agentConfig.id:
      echo fmt"Agent @{agentConfig.id} is already running"
      return none(SpawnedAgent)
  
  var agentArgs: seq[string] = @["agent", agentConfig.id]
  
  # Add model if specified
  if agentConfig.model.len > 0:
    agentArgs.add("--model=" & agentConfig.model)
  
  try:
    let process = startProcess(
      command = nifflerPath,
      args = agentArgs,
      options = {poStdErrToStdOut, poParentStreams}
    )
    
    let spawned = SpawnedAgent(
      config: agentConfig,
      process: process,
      startTime: now()
    )
    
    spawnedAgents.add(spawned)
    
    echo fmt"✓ Spawned agent @{agentConfig.id} (PID: {process.processID})"
    
    return some(spawned)
    
  except Exception as e:
    echo fmt"✗ Failed to spawn @{agentConfig.id}: {e.msg}"
    return none(SpawnedAgent)

proc waitForAgentReady*(agentId: string, timeoutSec: int = 10): bool =
  ## Wait for an agent to register in the database
  ## Returns true if agent becomes ready within timeout
  
  let database = getGlobalDatabase()
  if database == nil:
    return false
  
  let startTime = now()
  while (now() - startTime).inSeconds < timeoutSec:
    let agent = getAgent(database, agentId)
    if agent.isSome and agent.get().status == asOnline:
      return true
    sleep(500)
  
  return false

proc autoStartAgents*(config: Config, nifflerPath: string = "./src/niffler"): seq[SpawnedAgent] =
  ## Automatically start agents marked with autoStart=true
  ## Returns list of successfully spawned agents
  
  result = @[]
  let database = getGlobalDatabase()
  
  for agentConfig in config.agents:
    if agentConfig.autoStart:
      # Check if already running via database
      if database != nil:
        let agent = getAgent(database, agentConfig.id)
        if agent.isSome and agent.get().status == asOnline:
          echo fmt"→ @{agentConfig.id} is already running (from database)"
          continue
      
      echo fmt"→ Auto-starting agent: @{agentConfig.id}"
      let spawned = spawnAgent(agentConfig, nifflerPath)
      if spawned.isSome:
        result.add(spawned.get())
        
        # Wait for agent to be ready
        if waitForAgentReady(agentConfig.id, timeoutSec = 15):
          echo fmt"✓ @{agentConfig.id} is ready"
        else:
          echo fmt"⚠ @{agentConfig.id} did not report ready within timeout"

proc cleanupAgents*() =
  ## Clean up all spawned agent processes
  for spawned in spawnedAgents:
    if spawned.process.running():
      spawned.process.terminate()
      echo fmt"✓ Terminated @{spawned.config.id}"
  
  spawnedAgents.setLen(0)

proc getRunningAgents*(): seq[SpawnedAgent] =
  ## Get list of currently running agents
  result = @[]
  for spawned in spawnedAgents:
    if spawned.process.running():
      result.add(spawned)
