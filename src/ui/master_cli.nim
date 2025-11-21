## Master Mode CLI
##
## Implements master mode where Niffler acts as a coordinator that routes
## requests to agent processes via NATS messaging.
##
## Architecture:
## - Connects to NATS server
## - Discovers available agents via presence KV store
## - Parses @agent syntax to route requests
## - Receives and displays responses from agents
##
## Input Syntax:
## - @coder fix the bug           -> Ask request to coder
## - @coder /task refactor code   -> Task request to coder
## - @researcher /plan find docs  -> Plan mode task to researcher
## - Without @: use default agent or fall back to local processing

import std/[logging, strformat, times, os, options, strutils, tables, json, sequtils, random]
import ../core/[nats_client, command_parser, config, database, channels]
import ../types/[nats_messages, config as configTypes]
import sunny

type
  PendingRequest* = object
    ## Tracks an in-flight request to an agent
    requestId*: string
    agentName*: string
    startTime*: Time
    input*: string

  MasterState* = object
    ## Runtime state for master coordinator
    natsClient*: NifflerNatsClient
    defaultAgent*: string
    pendingRequests*: Table[string, PendingRequest]
    running*: bool
    connected*: bool

  AgentInput* = object
    ## Parsed agent routing information
    agentName*: string      # Target agent (empty = default/local)
    input*: string          # Full input to send to agent

proc parseAgentInput*(input: string): AgentInput =
  ## Parse @agent syntax from input
  ## Returns agent name and remaining input
  ##
  ## Examples:
  ##   "@coder fix bug"        -> agentName="coder", input="fix bug"
  ##   "@coder /task refactor" -> agentName="coder", input="/task refactor"
  ##   "fix bug"               -> agentName="", input="fix bug"
  let trimmed = input.strip()

  if trimmed.startsWith("@"):
    # Find end of agent name (space or end of string)
    var idx = 1
    while idx < trimmed.len and not trimmed[idx].isSpaceAscii():
      idx.inc()

    result.agentName = trimmed[1..<idx]

    # Rest of input after agent name
    if idx < trimmed.len:
      result.input = trimmed[idx..^1].strip()
    else:
      result.input = ""
  else:
    result.agentName = ""
    result.input = trimmed

proc generateRequestId(): string =
  ## Generate a unique request ID
  let timestamp = getTime().toUnix()
  let randomVal = rand(999999)
  result = fmt("{timestamp}-{randomVal}")

proc initializeMaster*(natsUrl: string, defaultAgent: string = ""): MasterState =
  ## Initialize master state and connect to NATS
  info("Initializing master mode...")

  result.defaultAgent = defaultAgent
  result.pendingRequests = initTable[string, PendingRequest]()
  result.running = true
  result.connected = false

  # Initialize NATS connection (no client ID for master - no presence needed)
  info(fmt("Connecting to NATS at {natsUrl}..."))
  try:
    result.natsClient = initNatsClient(natsUrl, "master", presenceTTL = 15)
    result.connected = true
    info("Connected to NATS")
  except Exception as e:
    warn(fmt("Failed to connect to NATS: {e.msg}"))
    warn("Master mode will operate in local-only mode")

proc discoverAgents*(state: MasterState): seq[string] =
  ## Discover available agents via NATS presence
  if not state.connected:
    return @[]

  try:
    result = state.natsClient.listPresent()
    debug(fmt("Discovered {result.len} agents: {result.join(\", \")}"))
  except Exception as e:
    warn(fmt("Failed to discover agents: {e.msg}"))
    result = @[]

proc isAgentAvailable*(state: MasterState, agentName: string): bool =
  ## Check if a specific agent is available
  if not state.connected:
    return false

  try:
    result = state.natsClient.isPresent(agentName)
  except Exception as e:
    warn(fmt("Failed to check agent availability: {e.msg}"))
    result = false

proc sendToAgent*(state: var MasterState, agentName: string, input: string,
                  timeoutMs: int = 30000): tuple[success: bool, response: string, error: string] =
  ## Send a request to an agent and wait for response
  ## Returns success status, response content, and error message
  if not state.connected:
    return (false, "", "Not connected to NATS")

  # Check if agent is available
  if not state.isAgentAvailable(agentName):
    return (false, "", fmt("Agent '{agentName}' is not available"))

  let requestId = generateRequestId()
  let subject = fmt("niffler.agent.{agentName}.request")

  # Create and track request
  let request = createRequest(requestId, agentName, input)
  state.pendingRequests[requestId] = PendingRequest(
    requestId: requestId,
    agentName: agentName,
    startTime: getTime(),
    input: input
  )

  info(fmt("Sending request {requestId} to agent '{agentName}'"))

  # Publish request
  try:
    state.natsClient.publish(subject, $request)
  except Exception as e:
    state.pendingRequests.del(requestId)
    return (false, "", fmt("Failed to send request: {e.msg}"))

  # Subscribe to response channel
  let responseSubject = "niffler.master.response"
  var subscription = state.natsClient.subscribe(responseSubject)
  defer: subscription.unsubscribe()

  # Also subscribe to status updates
  let statusSubject = "niffler.master.status"
  var statusSubscription = state.natsClient.subscribe(statusSubject)
  defer: statusSubscription.unsubscribe()

  # Wait for responses
  var accumulatedResponse = ""
  let startTime = getTime()
  let deadline = startTime + initDuration(milliseconds = timeoutMs)

  while getTime() < deadline:
    # Check for status updates
    let maybeStatus = statusSubscription.nextMsg(timeoutMs = 100)
    if maybeStatus.isSome():
      try:
        let status = fromJson(NatsStatusUpdate, maybeStatus.get().data)
        if status.requestId == requestId:
          echo fmt("  [{status.agentName}] {status.status}")
      except Exception as e:
        debug(fmt("Failed to parse status update: {e.msg}"))

    # Check for response
    let maybeMsg = subscription.nextMsg(timeoutMs = 100)
    if maybeMsg.isSome():
      try:
        let response = fromJson(NatsResponse, maybeMsg.get().data)
        if response.requestId == requestId:
          accumulatedResponse &= response.content

          if response.done:
            state.pendingRequests.del(requestId)
            let elapsed = (getTime() - startTime).inMilliseconds()
            info(fmt("Request {requestId} completed in {elapsed}ms"))
            return (true, accumulatedResponse, "")
      except Exception as e:
        debug(fmt("Failed to parse response: {e.msg}"))

  # Timeout
  state.pendingRequests.del(requestId)
  return (false, accumulatedResponse, fmt("Request timed out after {timeoutMs}ms"))

proc formatAgentResponse*(agentName: string, response: string, success: bool): string =
  ## Format agent response for display
  if success:
    result = """
─────────────────────────────────────────
✓ @""" & agentName & """ completed
─────────────────────────────────────────
""" & response & """
─────────────────────────────────────────"""
  else:
    result = """
─────────────────────────────────────────
✗ @""" & agentName & """ failed
─────────────────────────────────────────
""" & response & """
─────────────────────────────────────────"""

proc handleAgentRequest*(state: var MasterState, input: string): tuple[handled: bool, output: string] =
  ## Handle input that may be routed to an agent
  ## Returns whether it was handled and any output to display
  let parsed = parseAgentInput(input)

  # If no agent specified, check for default
  var targetAgent = parsed.agentName
  if targetAgent.len == 0:
    if state.defaultAgent.len > 0:
      targetAgent = state.defaultAgent
    else:
      # No agent routing - return unhandled
      return (false, "")

  # Check if agent is available
  if not state.connected:
    return (true, "Error: Not connected to NATS. Cannot route to agents.")

  if not state.isAgentAvailable(targetAgent):
    let available = state.discoverAgents()
    if available.len > 0:
      return (true, fmt("Error: Agent '{targetAgent}' is not available. Available: {available.join(\", \")}"))
    else:
      return (true, fmt("Error: Agent '{targetAgent}' is not available. No agents found."))

  # Send to agent
  echo fmt("→ Sending to @{targetAgent}...")
  let (success, response, error) = state.sendToAgent(targetAgent, parsed.input)

  if success:
    return (true, formatAgentResponse(targetAgent, response, true))
  else:
    let errMsg = if error.len > 0: error else: response
    return (true, formatAgentResponse(targetAgent, errMsg, false))

proc showAgentStatus*(state: MasterState) =
  ## Display status of available agents
  echo ""
  echo "Agent Status"
  echo "============"

  if not state.connected:
    echo "Not connected to NATS"
    echo ""
    return

  let agents = state.discoverAgents()
  if agents.len == 0:
    echo "No agents currently available"
  else:
    for agent in agents:
      echo fmt("  ✓ @{agent} - available")

  echo ""

proc cleanup*(state: var MasterState) =
  ## Cleanup master resources
  info("Cleaning up master...")

  if state.connected:
    state.natsClient.close()

  state.running = false
  info("Master shutdown complete")

proc startMasterMode*(natsUrl: string = "nats://localhost:4222",
                      defaultAgent: string = "",
                      modelName: string = "",
                      level: Level = lvlInfo) =
  ## Start master mode - main entry point
  ## This is a lightweight wrapper that can be called from niffler.nim
  ## The actual input loop integration happens in cli.nim
  echo "Niffler Master Mode"
  echo ""

  var state: MasterState

  try:
    state = initializeMaster(natsUrl, defaultAgent)
    showAgentStatus(state)

  except Exception as e:
    error(fmt("Master mode initialization failed: {e.msg}"))
    echo fmt("Error: {e.msg}")

  finally:
    cleanup(state)
