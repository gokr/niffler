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

import std/[logging, strformat, times, strutils, tables, random]
import ../core/[nats_client]
import ../types/[nats_messages]
import nats_listener

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
    defaultAgent*: string         ## Initial default agent from config/args
    currentAgent*: string         ## Currently focused agent (updated on @agent usage)
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
  result.currentAgent = defaultAgent  # Start with default agent as current
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

proc setCurrentAgent*(state: var MasterState, agentName: string) =
  ## Set the current/focused agent for command routing
  state.currentAgent = agentName
  if agentName.len > 0:
    info(fmt("Current agent set to: @{agentName}"))
  else:
    info("Current agent cleared")

proc getCurrentAgent*(state: MasterState): string =
  ## Get the current/focused agent name
  result = state.currentAgent

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

proc sendToAgentAsync*(state: var MasterState, agentName: string, input: string): tuple[success: bool, requestId: string, error: string] =
  ## Send a request to an agent asynchronously (fire and forget)
  ## Returns success status, request ID, and error message
  ## Responses will arrive via the NATS listener thread
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

  info(fmt("Sending async request {requestId} to agent '{agentName}'"))

  # Publish request and return immediately
  try:
    state.natsClient.publish(subject, $request)
    # Track request for response display
    trackAgentRequest(requestId, agentName, input)
    return (true, requestId, "")
  except Exception as e:
    state.pendingRequests.del(requestId)
    return (false, "", fmt("Failed to send request: {e.msg}"))

proc formatAgentResponse*(agentName: string, response: string, success: bool): string =
  ## Format agent response for display (chat-room style)
  if success:
    result = fmt("@{agentName}: {response}")
  else:
    result = fmt("@{agentName}: ❌ {response}")

proc handleAgentRequest*(state: var MasterState, input: string): tuple[handled: bool, output: string] =
  ## Handle input that may be routed to an agent
  ## Returns whether it was handled and any output to display
  ## Note: This is now async - responses arrive via NATS listener thread
  let parsed = parseAgentInput(input)

  # Track if user explicitly targeted an agent
  let explicitAgent = parsed.agentName.len > 0

  # If no agent specified, check for currentAgent (then default)
  var targetAgent = parsed.agentName
  if targetAgent.len == 0:
    if state.currentAgent.len > 0:
      targetAgent = state.currentAgent
    elif state.defaultAgent.len > 0:
      targetAgent = state.defaultAgent
    else:
      # No agent routing - return unhandled
      return (false, "")

  # Check if agent is available
  if not state.connected:
    return (true, "Error: Not connected to NATS. Cannot route to agents.")

  if not state.isAgentAvailable(targetAgent):
    let available = state.discoverAgents()
    # Provide more specific error for commands
    let isCommand = parsed.input.strip().startsWith("/")
    let errorPrefix = if isCommand: "Cannot execute command:" else: "Cannot route request:"
    if available.len > 0:
      return (true, fmt("{errorPrefix} Agent '{targetAgent}' is not available. Available: {available.join(\", \")}"))
    else:
      return (true, fmt("{errorPrefix} Agent '{targetAgent}' is not available. No agents found."))

  # Update currentAgent if user explicitly targeted one
  if explicitAgent:
    state.currentAgent = targetAgent

  # Send to agent asynchronously - responses will arrive via NATS listener
  let (success, _, error) = state.sendToAgentAsync(targetAgent, parsed.input)

  if success:
    # Request sent successfully - no output needed, responses will stream in
    return (true, "")
  else:
    return (true, fmt("@{targetAgent}: ❌ {error}"))

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

proc sendSinglePromptMaster*(
  prompt: string,
  shouldWait: bool,
  natsUrl: string,
  timeout: int = 30000
): int {.gcsafe.} =
  ## Send single prompt via master mode and exit
  ## Returns: 0 on success, 1 on failure

  echo fmt"🚀 Master mode: Processing single prompt"

  # Initialize master state (handles NATS connection internally)
  var masterState = initializeMaster(natsUrl)
  if not masterState.connected:
    echo fmt"❗ Failed to connect to NATS"
    if masterState.connected:
      masterState.natsClient.close()
    return 1

  # 2. Parse @agent syntax
  let agentInput = parseAgentInput(prompt)
  if agentInput.agentName.len == 0:
    echo "❗ Error: No agent specified (use @agent syntax)"
    masterState.natsClient.close()
    return 1

  # 3. Check agent availability
  if not masterState.isAgentAvailable(agentInput.agentName):
    echo fmt"❗ Error: Agent '{agentInput.agentName}' not available"
    echo fmt"💡 Tip: Start the agent first: niffler --agent {agentInput.agentName}"
    masterState.natsClient.close()
    return 1

  # 4. Send request (reuse existing logic!)
  if shouldWait:
    # Wait mode: use existing handleAgentRequest with blocking
    echo fmt"📤 Sending to @{agentInput.agentName} (wait mode)..."
    try:
      let requestResult = sendToAgentAsync(masterState, agentInput.agentName, agentInput.input)
      if requestResult.success:
        echo fmt"✅ Request sent to @{agentInput.agentName}"
        echo fmt"💡 Check the agent terminal for the response"
        echo fmt"⏳ (Enhanced wait mode coming soon)"
        masterState.natsClient.close()
        return 0
      else:
        echo fmt"❌ Failed: {requestResult.error}"
        masterState.natsClient.close()
        return 1
    except Exception as e:
      echo fmt"❌ Error: {e.msg}"
      masterState.natsClient.close()
      return 1
  else:
    # Fire-and-forget: send and exit
    echo fmt"📤 Sending to @{agentInput.agentName} (fire-and-forget)..."
    try:
      discard sendToAgentAsync(masterState, agentInput.agentName, agentInput.input)
      echo fmt"✅ Request sent to @{agentInput.agentName} (output will appear in agent terminal)"
      masterState.natsClient.close()
      return 0
    except Exception as e:
      echo fmt"❌ Failed to send request: {e.msg}"
      masterState.natsClient.close()
      return 1

# Note: handleAgentRequestSync will be implemented in a future version
# For MVP, we use fire-and-forget mode (which works perfectly)

proc cleanup*(state: var MasterState) =
  ## Cleanup master resources
  info("Cleaning up master...")

  if state.connected:
    state.natsClient.close()

  state.running = false
  info("Master shutdown complete")

