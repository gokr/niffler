## Agent Mode CLI
##
## Implements agent mode where Niffler runs as a specialized agent
## listening for requests via NATS and executing tasks autonomously.
##
## Architecture:
## - Loads agent definition from ~/.niffler/agents/<name>.md
## - Connects to NATS server
## - Subscribes to niffler.agent.<name>.request
## - Publishes heartbeats to JetStream KV presence store
## - Processes requests and sends responses
##
## Message Flow:
## 1. Receive NatsRequest via NATS
## 2. Parse commands (/plan, /model, etc.)
## 3. Execute via task_executor or conversation
## 4. Send NatsResponse messages (streaming)
## 5. Send final response with done=true

import std/[logging, strformat, times, os, options, strutils, json]
import ../core/[nats_client, command_parser, config, database, channels]
import ../core/task_executor
import ../types/[nats_messages, agents, config as configTypes, messages]
import ../api/curlyStreaming

type
  AgentState = object
    ## Runtime state for agent
    name: string
    definition: AgentDefinition
    natsClient: NifflerNatsClient
    modelConfig: configTypes.ModelConfig
    database: DatabaseBackend
    channels: ptr ThreadChannels
    running: bool
    requestCount: int
    startTime: Time

proc loadAgentDefinition(agentName: string): AgentDefinition =
  ## Load agent definition from ~/.niffler/agents/<name>.md
  let agentsDir = getHomeDir() / ".niffler" / "agents"
  let agentFile = agentsDir / agentName & ".md"

  if not fileExists(agentFile):
    raise newException(IOError, fmt"Agent definition not found: {agentFile}")

  let content = readFile(agentFile)
  result = parseAgentDefinition(content, agentFile)

  let toolsList = result.allowedTools.join(", ")
  info(fmt"Loaded agent '{result.name}' from {agentFile}")
  info(fmt"  Description: {result.description}")
  info(fmt"  Allowed tools: {toolsList}")

proc initializeAgent(agentName: string, natsUrl: string, modelName: string, level: Level): AgentState =
  ## Initialize agent state and connect to NATS
  info(fmt"Initializing agent '{agentName}'...")

  # Load agent definition
  result.name = agentName
  result.definition = loadAgentDefinition(agentName)
  result.requestCount = 0
  result.startTime = getTime()

  # Initialize NATS connection with presence tracking
  info(fmt"Connecting to NATS at {natsUrl}...")
  result.natsClient = initNatsClient(natsUrl, agentName, presenceTTL = 15)

  # Initialize database
  info("Initializing database...")
  result.database = initializeGlobalDatabase(level)

  # Load configuration and select model
  info("Loading configuration...")
  let config = loadConfig()

  if modelName.len > 0:
    # Try to find specified model
    for model in config.models:
      if model.nickname == modelName:
        result.modelConfig = model
        break

  if result.modelConfig.nickname.len == 0:
    # Use first model as default
    if config.models.len > 0:
      result.modelConfig = config.models[0]
    else:
      raise newException(IOError, "No models configured")

  info(fmt"Using model: {result.modelConfig.nickname}")

  # Initialize channels for tool execution
  info("Initializing channels...")
  initThreadSafeChannels()
  result.channels = getChannels()

  result.running = true

  info(fmt"Agent '{agentName}' initialized successfully")

proc sendResponse(state: var AgentState, requestId: string, content: string, done: bool = false) =
  ## Send a response message back to master
  let response = createResponse(requestId, content, done)
  let responseJson = $response.toJson()

  state.natsClient.publish("niffler.master.response", responseJson)

  if done:
    debug(fmt"Sent final response for request {requestId}")
  else:
    debug(fmt"Sent response chunk for request {requestId}")

proc sendStatusUpdate(state: var AgentState, requestId: string, status: string) =
  ## Send a status update message to master
  let update = createStatusUpdate(requestId, state.name, status)
  let updateJson = $update.toJson()

  state.natsClient.publish("niffler.master.status", updateJson)
  debug(fmt"Sent status update: {status}")

proc processRequest(state: var AgentState, request: NatsRequest) =
  ## Process an incoming request from master
  info(fmt"Processing request {request.requestId}")
  state.requestCount.inc()

  try:
    # Parse commands from input
    let parsed = parseCommand(request.input)

    # Send status update
    sendStatusUpdate(state, request.requestId, "Processing request...")

    # Handle mode switches
    if parsed.mode.isSome():
      let modeName = $parsed.mode.get()
      sendStatusUpdate(state, request.requestId, fmt"Switching to {modeName} mode")

    # Handle model switches
    if parsed.model.isSome():
      let modelNickname = parsed.model.get()
      sendStatusUpdate(state, request.requestId, fmt"Switching to model {modelNickname}")

      # TODO: Update modelConfig based on nickname
      # For now, just send status

    # Get tool schemas for task execution
    # TODO: Get actual tool schemas from tool registry
    let toolSchemas: seq[ToolDefinition] = @[]

    # Execute the request based on conversation type
    if parsed.conversationType.isSome() and parsed.conversationType.get() == ctTask:
      # Task mode: Fresh isolated context
      sendStatusUpdate(state, request.requestId, "Executing task (fresh context)...")

      let taskResult = executeTask(
        state.definition,
        parsed.prompt,
        state.modelConfig,
        state.channels,
        toolSchemas
      )

      if taskResult.success:
        sendResponse(state, request.requestId, taskResult.summary, done = true)
        info(fmt"Task completed successfully: {taskResult.toolCalls} tool calls, {taskResult.tokensUsed} tokens")
      else:
        sendResponse(state, request.requestId, fmt"Task failed: {taskResult.error}", done = true)
        warn(fmt"Task failed: {taskResult.error}")

    else:
      # Ask mode: Continue/create conversation
      sendStatusUpdate(state, request.requestId, "Processing ask (building context)...")

      # TODO: Implement ask mode with conversation continuation
      # For now, just send a placeholder response
      sendResponse(state, request.requestId, "Ask mode not yet implemented", done = true)

  except Exception as e:
    error(fmt"Error processing request: {e.msg}")
    sendResponse(state, request.requestId, fmt"Error: {e.msg}", done = true)

proc publishHeartbeat(state: var AgentState) =
  ## Publish heartbeat to presence KV store
  try:
    state.natsClient.sendHeartbeat()
    debug("Published heartbeat")
  except Exception as e:
    warn(fmt"Failed to publish heartbeat: {e.msg}")

proc listenForRequests(state: var AgentState) =
  ## Main request listening loop
  let subject = fmt"niffler.agent.{state.name}.request"
  info(fmt"Subscribing to {subject}")

  var subscription = state.natsClient.subscribe(subject)
  defer: subscription.unsubscribe()

  info(fmt"Agent '{state.name}' ready for requests...")
  let toolsList = state.definition.allowedTools.join(", ")
  echo ""
  echo fmt"Agent: {state.name}"
  echo fmt"Model: {state.modelConfig.nickname}"
  echo fmt"Tools: {toolsList}"
  echo fmt"Listening on: {subject}"
  echo ""
  echo "Waiting for requests..."
  echo ""

  var lastHeartbeat = getTime()
  const heartbeatInterval = 5  # seconds

  while state.running:
    # Check for incoming messages with short timeout
    let maybeMsg = subscription.nextMsg(timeoutMs = 1000)

    if maybeMsg.isSome():
      let msg = maybeMsg.get()

      try:
        # Deserialize request
        let json = parseJson(msg.data)
        let request = fromJson(json, NatsRequest)

        info(fmt"Received request: {request.requestId}")
        echo fmt"[REQUEST] {request.input}"
        echo ""

        # Process request
        processRequest(state, request)
        echo ""
        echo "Waiting for requests..."
        echo ""

      except Exception as e:
        error(fmt"Failed to parse request: {e.msg}")

    # Publish heartbeat if needed
    let now = getTime()
    if (now - lastHeartbeat).inSeconds() >= heartbeatInterval:
      publishHeartbeat(state)
      lastHeartbeat = now

proc cleanup(state: var AgentState) =
  ## Cleanup agent resources
  info("Cleaning up agent...")

  # Remove presence
  state.natsClient.removePresence()

  # Close NATS connection
  state.natsClient.close()

  # Close database
  state.database.close()

  info("Agent shutdown complete")

proc startAgentMode*(agentName: string, natsUrl: string = "nats://localhost:4222", modelName: string = "", level: Level = lvlInfo) =
  ## Start agent mode - main entry point
  echo fmt"Starting Niffler in agent mode: {agentName}"
  echo ""

  var state: AgentState

  try:
    # Initialize agent
    state = initializeAgent(agentName, natsUrl, modelName, level)

    # Start listening for requests
    listenForRequests(state)

  except Exception as e:
    error(fmt"Agent mode failed: {e.msg}")
    echo fmt"Error: {e.msg}"
    quit(1)
  finally:
    cleanup(state)
