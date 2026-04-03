## Shared action runtime for CLI commands and tools

import std/[algorithm, sequtils, strformat, strutils]
import types
import ../core/[agent_manager, session]
import ../types/agents
import ../tools/registry
import ../ui/master_cli
import ../ui/table_utils
import nancy

proc renderAgentDefinitionList*(currentSession: Session): ActionResult =
  let agentsDir = currentSession.getAgentsDir()
  let agents = loadAgentDefinitions(agentsDir)
  let knownTools = getAllToolNames()

  if agents.len == 0:
    return ActionResult(
      success: true,
      message: fmt("No agents found in {agentsDir}\nAgents will be created on next startup."),
      shouldExit: false,
      shouldContinue: true
    )

  var table: TerminalTable
  table.add(bold("Name"), bold("Description"), bold("Tools"), bold("Status"))

  for agent in agents:
    let status = validateAgentDefinition(agent, knownTools)
    let statusIcon = if status.valid:
      green("✓")
    elif status.unknownTools.len > 0:
      yellow("⚠")
    else:
      red("✗")
    table.add(agent.name, truncate(agent.description, 50), $agent.allowedTools.len, statusIcon)

  ActionResult(
    success: true,
    message: renderTableToString(table, maxWidth = 120) & "\n\nUse /agent show <name> to view details",
    shouldExit: false,
    shouldContinue: true
  )

proc renderAgentDefinitionDetails*(currentSession: Session, agentName: string): ActionResult =
  let agents = loadAgentDefinitions(currentSession.getAgentsDir())
  let knownTools = getAllToolNames()
  let agentOpt = agents.filterIt(it.name == agentName)

  if agentOpt.len == 0:
    return ActionResult(
      success: false,
      message: fmt("Agent '{agentName}' not found. Use /agent list to see available definitions."),
      shouldExit: false,
      shouldContinue: true
    )

  let agent = agentOpt[0]
  let status = validateAgentDefinition(agent, knownTools)

  var message = fmt("Agent: {agent.name}\n")
  message &= fmt("Description: {agent.description}\n\n")
  message &= "Allowed Tools: " & agent.allowedTools.join(", ") & "\n"

  if status.valid:
    if status.unknownTools.len > 0:
      message &= "Status: ⚠ Valid (unknown tools: " & status.unknownTools.join(", ") & ")\n"
    else:
      message &= "Status: ✓ Valid\n"
  else:
    message &= fmt("Status: ✗ {status.error}\n")

  message &= fmt("File: {agent.filePath}")
  ActionResult(success: true, message: message, shouldExit: false, shouldContinue: true)

proc renderRunningAgents*(): ActionResult =
  let runningAgents = listRunningAgentProcesses().sortedByIt(it.routingName)
  let masterStatePtr = getGlobalMasterState()
  let presentAgents = if masterStatePtr != nil and masterStatePtr[].connected:
    masterStatePtr[].discoverAgents()
  else:
    @[]

  if runningAgents.len == 0 and presentAgents.len == 0:
    return ActionResult(success: true, message: "No running agents.", shouldExit: false, shouldContinue: true)

  var table: TerminalTable
  table.add(bold("Agent"), bold("PID"), bold("Model"), bold("Presence"))

  for agent in runningAgents:
    let modelName = if agent.modelName.len > 0: agent.modelName else: "-"
    let presence = if agent.routingName in presentAgents: green("online") else: yellow("starting")
    table.add(formatRunningAgentLabel(agent), $agent.pid, modelName, presence)

  for agentName in presentAgents:
    if runningAgents.anyIt(it.routingName == agentName):
      continue
    table.add(agentName, "-", "-", green("online"))

  ActionResult(success: true, message: renderTableToString(table, maxWidth = 120), shouldExit: false, shouldContinue: true)

proc startAgentInstance*(agentName: string, nick: string = "", model: string = ""): ActionResult =
  try:
    let masterStatePtr = getGlobalMasterState()
    let spawned = startAgent(agentName, agentNick = nick, modelOverride = model, nifflerPath = "./niffler")
    let routingName = if nick.len > 0: nick else: agentName
    let ready = if masterStatePtr != nil and masterStatePtr[].connected:
      waitForAgentReady(masterStatePtr[].natsClient, routingName, timeoutSec = 15)
    else:
      false
    let label = if nick.len > 0: fmt("{nick} ({agentName})") else: agentName
    let readiness = if ready: "online" else: "spawned"
    ActionResult(success: true, message: fmt("Started {label} (pid {spawned.pid}, {readiness})."), shouldExit: false, shouldContinue: true)
  except Exception as e:
    ActionResult(success: false, message: fmt("Failed to start agent: {e.msg}"), shouldExit: false, shouldContinue: true)

proc stopAgentInstance*(routingName: string): ActionResult =
  let matches = listRunningAgentProcesses().filterIt(it.routingName == routingName)
  if matches.len == 0:
    return ActionResult(success: false, message: fmt("No running agent matches '{routingName}'. Use /agent running to inspect live agents."), shouldExit: false, shouldContinue: true)
  if matches.len > 1:
    return ActionResult(success: false, message: fmt("Multiple running agents match '{routingName}'. Use a unique nick before stopping."), shouldExit: false, shouldContinue: true)

  if stopAgent(routingName):
    return ActionResult(success: true, message: fmt("Stopped {formatRunningAgentLabel(matches[0])}."), shouldExit: false, shouldContinue: true)
  ActionResult(success: false, message: fmt("Failed to stop '{routingName}'."), shouldExit: false, shouldContinue: true)

proc dispatchTaskToAgent*(targetAgent: string, description: string): ActionResult =
  let masterStatePtr = getGlobalMasterState()
  if masterStatePtr == nil:
    return ActionResult(success: false, message: "Master state not available for task dispatch.", shouldExit: false, shouldContinue: true)
  if not masterStatePtr[].connected:
    return ActionResult(success: false, message: "Not connected to NATS. Cannot dispatch tasks to agents.", shouldExit: false, shouldContinue: true)

  let command = "/task " & description
  let (success, requestId, error) = masterStatePtr[].sendToAgentAsync(targetAgent, command)
  if success:
    return ActionResult(success: true, message: fmt("Dispatched task to {targetAgent} (request {requestId})."), shouldExit: false, shouldContinue: true)

  ActionResult(success: false, message: error, shouldExit: false, shouldContinue: true)
