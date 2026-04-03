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

import std/[logging, strformat, times, strutils, tables, options, os]
import ../core/[nats_client, database, agent_dispatch]
import ../comms/discord
import nats_listener
import linecross
import theme
# Import Discord routing functions from nats_listener
export nats_listener.addDiscordRoute, nats_listener.removeDiscordRoute, nats_listener.initDiscordRouting

when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

type DiscordProcessorThread = Thread[pointer]

type
  PendingRequest* = object
    ## Tracks an in-flight request to an agent
    requestId*: string
    agentName*: string
    startTime*: Time
    input*: string
    discordChannelId*: string      ## Empty = from CLI, non-empty = from Discord

  DiscordDisplayMessage* = object
    ## Message to display in CLI from Discord thread
    author*: string
    content*: string
    agentName*: string            ## Target agent (for display)

  MasterState* = object
    ## Runtime state for master coordinator
    natsClient*: NifflerNatsClient
    defaultAgent*: string         ## Initial default agent from config/args
    currentAgent*: string         ## Currently focused agent (updated on @agent usage)
    pendingRequests*: Table[string, PendingRequest]
    running*: bool
    connected*: bool
    # Discord integration
    discordEnabled*: bool
    discordToken*: string
    discordDefaultAgent*: string  ## Default agent for Discord messages
    discordAllowedPeople*: seq[string]
    # Thread communication
    discordDisplayChannel*: system.Channel[DiscordDisplayMessage]
    discordProcessorRunning*: bool
    discordProcessorThread*: DiscordProcessorThread

  AgentInput* = object
    ## Parsed agent routing information
    agentName*: string      # Target agent (empty = default/local)
    input*: string          # Full input to send to agent

var globalMasterState*: ptr MasterState = nil

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

proc initializeMaster*(natsUrl: string, defaultAgent: string = ""): MasterState =
  ## Initialize master state and connect to NATS
  info("Initializing master mode...")

  result.defaultAgent = defaultAgent
  result.currentAgent = defaultAgent  # Start with default agent as current
  result.pendingRequests = initTable[string, PendingRequest]()
  result.running = true
  result.connected = false
  result.discordEnabled = false
  result.discordToken = ""
  result.discordDefaultAgent = ""
  result.discordAllowedPeople = @[]

  # Initialize NATS connection (no client ID for master - no presence needed)
  info(fmt("Connecting to NATS at {natsUrl}..."))
  try:
    result.natsClient = initNatsClient(natsUrl, "master", presenceTTL = 15)
    result.connected = true
    info("Connected to NATS")
  except Exception as e:
    warn(fmt("Failed to connect to NATS: {e.msg}"))
    warn("Master mode will operate in local-only mode")

proc setGlobalMasterState*(state: ptr MasterState) =
  ## Set shared master state for commands and completion
  globalMasterState = state

proc getGlobalMasterState*(): ptr MasterState =
  ## Get shared master state for commands and completion
  result = globalMasterState

proc initializeDiscord*(state: var MasterState, database: DatabaseBackend) =
  ## Initialize Discord integration for master
  ## Called after database is available
  if database == nil:
    return
  
  let discordCfg = getDiscordConfig(database)
  if discordCfg.isNone:
    return
  
  let (token, guildId, channels, defaultAgent, allowedPeople) = discordCfg.get()
  if token.len == 0:
    return
  
  if not isDiscordEnabled(database):
    return
  
  state.discordEnabled = true
  state.discordToken = token
  state.discordDefaultAgent = defaultAgent
  state.discordAllowedPeople = allowedPeople
  
  # Initialize the global Discord message channel
  initDiscordChannel()
  
  # Start Discord in background thread
  startDiscordThread(token, guildId, channels)
  info("Discord integration started")

proc stopDiscordProcessor*(state: var MasterState)
  ## Stop the Discord processor thread

proc shutdownDiscord*(state: var MasterState) =
  ## Stop Discord integration
  if state.discordEnabled:
    stopDiscordProcessor(state)
    stopDiscordBot()
    state.discordEnabled = false
    state.discordToken = ""
    info("Discord integration stopped")

proc formatDiscordDisplay*(msg: DiscordDisplayMessage): string
  ## Format a Discord message for CLI display with special styling

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

proc isDiscordUserAllowed*(state: MasterState, authorName: string, authorId: string): bool =
  ## Check if a Discord user is allowed to talk to the bot
  if state.discordAllowedPeople.len == 0:
    return true

  let normalizedAuthor = authorName.toLowerAscii()
  for allowed in state.discordAllowedPeople:
    let normalizedAllowed = allowed.strip()
    if normalizedAllowed.len == 0:
      continue
    if normalizedAllowed == authorId or normalizedAllowed.toLowerAscii() == normalizedAuthor:
      return true

  return false

proc sendToAgentAsync*(state: var MasterState, agentName: string, input: string, discordChannelId: string = ""): tuple[success: bool, requestId: string, error: string] =
  ## Send a request to an agent asynchronously (fire and forget)
  ## Returns success status, request ID, and error message
  ## Responses will arrive via the NATS listener thread
  ## If discordChannelId is provided, responses will be relayed to Discord
  if not state.connected:
    return (false, "", "Not connected to NATS")

  let prepared = prepareAgentRequest(state.natsClient, agentName, input)
  if not prepared.success:
    return (false, "", prepared.error)

  # Create and track request with Discord context if applicable
  state.pendingRequests[prepared.request.requestId] = PendingRequest(
    requestId: prepared.request.requestId,
    agentName: agentName,
    startTime: getTime(),
    input: input,
    discordChannelId: discordChannelId
  )

  info(fmt("Sending async request {prepared.request.requestId} to agent '{agentName}'"))

  # Publish request and return immediately
  try:
    publishAgentRequest(state.natsClient, prepared.request)
    # Track request for response display
    trackAgentRequest(prepared.request.requestId, agentName, input)
    return (true, prepared.request.requestId, "")
  except Exception as e:
    state.pendingRequests.del(prepared.request.requestId)
    return (false, "", fmt("Failed to send request: {e.msg}"))

proc processDiscordMessagesThread(stateArg: pointer) {.thread.} =
  ## Background thread that processes Discord messages and routes to agents
  {.gcsafe.}:
    let statePtr = cast[ptr MasterState](stateArg)
    info("Discord processor thread started")
    
    while statePtr[].discordProcessorRunning and statePtr[].discordEnabled:
      # Block waiting for Discord messages
      let recvResult = discordMessageChannel.tryRecv()
      if recvResult.dataAvailable:
        let msg = recvResult.msg
        
        # Skip messages from the bot itself
        if msg.authorName == "Niffler":
          debug("Skipping bot's own message")
          continue

        if not statePtr[].isDiscordUserAllowed(msg.authorName, msg.authorId):
          info(fmt("Ignoring Discord message from non-allowed user {msg.authorName} ({msg.authorId})"))
          continue
        
        debug(fmt("Processing Discord message from {msg.authorName}: {msg.content[0..min(30, msg.content.len-1)]}"))
        
        # Parse the message for agent routing
        let parsed = parseAgentInput(msg.content)
        
        var targetAgent = parsed.agentName
        if targetAgent.len == 0:
          # Use default agent for Discord
          if statePtr[].discordDefaultAgent.len > 0:
            targetAgent = statePtr[].discordDefaultAgent
          elif statePtr[].currentAgent.len > 0:
            targetAgent = statePtr[].currentAgent
          elif statePtr[].defaultAgent.len > 0:
            targetAgent = statePtr[].defaultAgent
        
        if targetAgent.len == 0:
          warn("Discord message received but no agent to route to")
          sendDiscordMessage(statePtr[].discordToken, msg.channelId,
            "No agent available. Start an agent with: niffler agent <name>")
          continue
        
        # Check if agent is available
        if not statePtr[].isAgentAvailable(targetAgent):
          let available = statePtr[].discoverAgents()
          var response = ""
          if available.len > 0:
            response = fmt("Agent '@{targetAgent}' not available. Available: {available.join(\", \")}")
          else:
            response = "No agents are running. Start an agent with: niffler agent <name>"
          
          sendDiscordMessage(statePtr[].discordToken, msg.channelId, response)
          continue
        
        # Show Discord message immediately in CLI, even while readline is waiting
        let displayMsg = DiscordDisplayMessage(
          author: msg.authorName,
          content: if parsed.input.len > 0: parsed.input else: msg.content,
          agentName: targetAgent
        )
        writeOutputRaw(formatDiscordDisplay(displayMsg).replace("\n", "\r\n"), addNewline = true, redraw = true)
        
        # Send to agent with Discord context
        let input = if parsed.input.len > 0: parsed.input else: msg.content
        let (success, requestId, error) = statePtr[].sendToAgentAsync(targetAgent, input, msg.channelId)
        
        if success:
          info(fmt("Routed Discord message from {msg.authorName} to @{targetAgent} (requestId: {requestId})"))
          # Register for Discord relay
          addDiscordRoute(requestId, msg.channelId, statePtr[].discordToken)
        else:
          warn(fmt("Failed to route Discord message: {error}"))
          sendDiscordMessage(statePtr[].discordToken, msg.channelId, fmt("Error: {error}"))
      else:
        # No message available, small sleep to prevent busy-wait
        sleep(10)
    
    info("Discord processor thread stopped")

proc startDiscordProcessor*(state: var MasterState) =
  ## Start the Discord processor background thread
  if not state.discordEnabled:
    return
  
  # Initialize the display channel
  state.discordDisplayChannel.open(100)
  state.discordProcessorRunning = true
  
  # Create a pointer to state for the thread
  let statePtr = cast[pointer](addr state)
  
  # Start the thread
  createThread(state.discordProcessorThread, processDiscordMessagesThread, statePtr)
  
  info("Discord processor thread started")

proc stopDiscordProcessor*(state: var MasterState) =
  ## Stop the Discord processor thread
  if state.discordProcessorRunning:
    state.discordProcessorRunning = false
    joinThread(state.discordProcessorThread)
    state.discordDisplayChannel.close()
    info("Discord processor stopped")

proc pollDiscordMessages*(state: var MasterState): seq[DiscordDisplayMessage] =
  ## Poll for Discord display messages from the processor thread
  ## Returns any messages that should be displayed in CLI
  if not state.discordEnabled:
    return
  
  # Check for display messages from Discord thread
  while true:
    let displayResult = state.discordDisplayChannel.tryRecv()
    if not displayResult.dataAvailable:
      break
    result.add(displayResult.msg)

proc formatDiscordDisplay*(msg: DiscordDisplayMessage): string =
  ## Format a Discord message for CLI display with special styling
  let labelStyle = createThemeStyle("magenta", "default", "bright")
  let authorStyle = createThemeStyle("cyan", "default", "bright")
  let arrowStyle = createThemeStyle("white", "default", "dim")
  let agentStyle = createThemeStyle("yellow", "default", "bright")
  let bodyStyle = currentTheme.normal

  let header =
    formatWithStyle("discord", labelStyle) & " " &
    formatWithStyle(msg.author, authorStyle) & " " &
    formatWithStyle("->", arrowStyle) & " " &
    formatWithStyle("@" & msg.agentName, agentStyle)

  let body = formatWithStyle("  " & msg.content, bodyStyle)
  result = header & "\n" & body

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
): int =
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
    echo fmt"💡 Tip: Start the agent first: niffler agent {agentInput.agentName}"
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

  # Stop Discord bot
  if state.discordEnabled:
    stopDiscordBot()
    info("Discord stopped")

  if state.connected:
    state.natsClient.close()

  state.running = false
  info("Master shutdown complete")
