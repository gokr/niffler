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

import std/[logging, strformat, times, os, options, strutils, json, tables, atomics]
import ../core/[nats_client, command_parser, config, database, channels, app, session, mode_state, conversation_manager, log_file]
import ../core/task_executor
import ../types/[nats_messages, agents, config as configTypes, messages, mode]
import ../api/[api]
import ../tools/[worker, registry]
import ../mcp/[mcp]
import output_shared
import tool_visualizer
import theme
import commands
import response_templates

type
  CommandClass* = enum
    ccSafeQuick      ## Can run during agentic loop (read-only)
    ccDisruptive     ## Would corrupt agentic loop, return error
    ccAgentic        ## Queue/serialize

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
    # Worker threads
    apiWorker: APIWorker
    toolWorker: ToolWorker
    mcpWorker: MCPWorker
    toolSchemas: seq[ToolDefinition]
    # Concurrent command handling
    agenticActive: Atomic[bool]            ## Is an agentic loop running?
    agenticRequestId: string               ## Current agentic request ID
    pendingAgenticRequests: seq[NatsRequest]  ## Queue for serialization

proc classifyCommand(request: NatsRequest): CommandClass =
  ## Classify a request into safe, disruptive, or agentic category
  let input = request.input.strip()
  if not input.startsWith("/"):
    return ccAgentic  # Prompts are agentic

  let (command, args) = commands.parseCommand(input)

  # Safe read-only commands
  const safeCommands = ["info", "context", "inspect"]
  if command in safeCommands:
    return ccSafeQuick

  # /model alone (show current) is safe
  if command == "model" and args.len == 0:
    return ccSafeQuick

  # Disruptive commands that would corrupt context
  const disruptiveCommands = ["conv", "new", "condense", "plan", "code"]
  if command in disruptiveCommands:
    return ccDisruptive
  if command == "model" and args.len > 0:
    return ccDisruptive  # Switching model mid-conversation

  return ccAgentic

proc loadAgentDefinition(agentName: string): AgentDefinition =
  ## Load agent definition from the active config's agents directory
  ## Uses the session system to determine the correct path (e.g., ~/.niffler/default/agents/)
  let agentsDir = session.getAgentsDir()
  let agentFile = agentsDir / agentName & ".md"

  if not fileExists(agentFile):
    raise newException(IOError, fmt"Agent definition not found: {agentFile}")

  let content = readFile(agentFile)
  result = parseAgentDefinition(content, agentFile)

  let toolsList = result.allowedTools.join(", ")
  info(fmt"Loaded agent '{result.name}' from {agentFile}")
  info(fmt"  Description: {result.description}")
  info(fmt"  Allowed tools: {toolsList}")

proc initializeAgent(agentName: string, agentNick: string, natsUrl: string, modelName: string, level: Level, logFile: string = ""): AgentState =
  ## Initialize agent state and connect to NATS

  # Setup file logging if logFile is provided
  if logFile.len > 0:
    # Setup file and console logging (main function didn't add console logger)
    let logManager = initLogFileManager(logFile)
    setGlobalLogManager(logManager)

    let logger = newFileAndConsoleLogger(logManager)
    addHandler(logger)
    logManager.activateLogFile()
    debug(fmt"File logging enabled: {logFile}")

  # Use nickname for routing if provided, otherwise use agent name
  let effectiveName = if agentNick.len > 0: agentNick else: agentName
  info(fmt"Initializing agent '{agentName}' as '{effectiveName}'...")

  # Initialize runtime mode as agent
  initializeRuntimeMode(rmAgent)

  # Load agent definition using the base agent name
  result.definition = loadAgentDefinition(agentName)

  # Store both original name and effective name
  result.name = effectiveName  # Use effective name for routing
  result.requestCount = 0
  result.startTime = getTime()

  # Initialize NATS connection with presence tracking using effective name
  info(fmt"Connecting to NATS at {natsUrl} as '{effectiveName}'...")
  result.natsClient = initNatsClient(natsUrl, effectiveName, presenceTTL = 15)

  # Initialize database
  info("Initializing database...")
  result.database = initializeGlobalDatabase(level)

  # Load configuration and select model
  info("Loading configuration...")
  let config = loadConfig()

  info(fmt"Looking for model: '{modelName}'")
  var selectedModelName = modelName

  if modelName.len > 0:
    # Try to find specified model
    for model in config.models:
      if model.nickname == modelName:
        result.modelConfig = model
        info(fmt"Found model: {model.nickname} ({model.baseUrl})")
        break

  if result.modelConfig.nickname.len == 0:
    # Check agent definition for default model
    if result.definition.model.isSome():
      selectedModelName = result.definition.model.get()
      info(fmt"Using model from agent definition: '{selectedModelName}'")
      for model in config.models:
        if model.nickname == selectedModelName:
          result.modelConfig = model
          info(fmt"Found model: {model.nickname} ({model.baseUrl})")
          break

  if result.modelConfig.nickname.len == 0:
    # Use first model as default
    if config.models.len > 0:
      result.modelConfig = config.models[0]
      info("Using first available model as fallback")
    else:
      raise newException(IOError, "No models configured")

  info(fmt"Using model: {result.modelConfig.nickname}")

  # Initialize channels for tool execution
  info("Initializing channels...")
  initThreadSafeChannels()
  result.channels = getChannels()

  # Get tool schemas (this also initializes the registry)
  info("Loading tool schemas...")
  result.toolSchemas = getAllToolSchemas()
  info(fmt"Loaded {result.toolSchemas.len} tools")

  # Initialize command system (needed for agent command execution)
  info("Initializing command system...")
  initializeCommands()
  info("Command system initialized")

  # Initialize session manager for thread-safe operations
  # Pass database pool if available
  let pool = if result.database != nil: result.database.pool else: nil
  initSessionManager(pool)
  info("Session manager initialized")

  # NOTE: Workers are started in startAgentMode AFTER this function returns
  # This is important because AgentState is returned by value, and copying
  # Thread objects after createThread corrupts them
  result.running = true

  info(fmt"Agent '{agentName}' initialized successfully")

proc sendResponse(state: var AgentState, requestId: string, content: string, done: bool = false) =
  ## Send a response message back to master
  let response = createResponse(requestId, state.name, content, done)
  state.natsClient.publish("niffler.master.response", $response)

  if done:
    debug(fmt"Sent final response for request {requestId}")
  else:
    debug(fmt"Sent response chunk for request {requestId}")

proc sendStatusUpdate(state: var AgentState, requestId: string, status: string) =
  ## Send a status update message to master
  let update = createStatusUpdate(requestId, state.name, status)
  state.natsClient.publish("niffler.master.status", $update)
  debug(fmt"Sent status update: {status}")

proc ensureAgentConversation(state: var AgentState): bool =
  ## Ensure agent has an active conversation for Ask mode
  ## Creates a new conversation if needed, or uses existing one
  ## Returns true if conversation is ready, false on error
  ## Retries on database lock errors
  const maxRetries = 5
  const retryDelayMs = 200

  let currentConvId = getCurrentConversationId()
  if currentConvId > 0:
    # Already have an active conversation
    debug(fmt"Using existing conversation: {currentConvId}")
    # Make sure session is pointing to this conversation
    for attempt in 1..maxRetries:
      try:
        discard switchToConversation(state.database, currentConvId)
        # Restore mode from conversation to initialize thread-local state
        let convOpt = getConversationById(state.database, currentConvId)
        if convOpt.isSome():
          restoreModeWithProtection(convOpt.get().mode)
        return true
      except Exception as e:
        if "locked" in e.msg and attempt < maxRetries:
          debug(fmt"Database locked, retry {attempt}/{maxRetries}")
          sleep(retryDelayMs * attempt)
        else:
          warn(fmt"Failed to switch to conversation {currentConvId}: {e.msg}")
          break

  # Create a new conversation for this agent
  let title = fmt"Agent: {state.name}"

  for attempt in 1..maxRetries:
    try:
      let convOpt = createConversation(state.database, title, amCode, state.modelConfig.nickname)

      if convOpt.isNone():
        warn("Failed to create conversation for agent")
        return false

      let conv = convOpt.get()

      # Switch session to this conversation (updates global session tracking)
      discard switchToConversation(state.database, conv.id)
      # Restore mode from conversation to initialize thread-local state
      restoreModeWithProtection(conv.mode)

      info(fmt"Created new conversation {conv.id} for agent '{state.name}'")
      return true
    except Exception as e:
      if "locked" in e.msg and attempt < maxRetries:
        echo fmt"[DEBUG] Database locked, retry {attempt}/{maxRetries}"
        sleep(retryDelayMs * attempt)
      else:
        warn(fmt"Database error creating conversation: {e.msg}")
        return false

  return false

proc executeAsk(state: var AgentState, prompt: string, requestId: string): tuple[success: bool, response: string] =
  ## Execute Ask mode: continue conversation with context
  ## Returns the last assistant message (no summary generation)

  # Ensure we have an active conversation
  if not ensureAgentConversation(state):
    return (false, "Failed to create or access conversation (database may be locked)")

  # Get API key
  let apiKeyOpt = app.validateApiKey(state.modelConfig)
  if apiKeyOpt.isNone():
    return (false, "No API key configured")
  let apiKey = apiKeyOpt.get()

  # Build messages with conversation context
  var messages = getConversationContext()

  # Use agent's system prompt from definition
  let systemPromptText = state.definition.systemPrompt
  if systemPromptText.len > 0:
    let systemMsg = Message(role: mrSystem, content: systemPromptText)
    messages.insert(systemMsg, 0)

  # Add user message to conversation (persists to DB)
  let userMsg = conversation_manager.addUserMessage(prompt)
  messages.add(userMsg)

  # Prepare tool schemas filtered by agent's allowed tools
  var agentToolSchemas: seq[ToolDefinition] = @[]
  for tool in state.toolSchemas:
    if tool.function.name in state.definition.allowedTools:
      agentToolSchemas.add(tool)

  # Create and send API request - API worker will handle all tool execution
  let request = APIRequest(
    kind: arkChatRequest,
    requestId: requestId,
    messages: messages,
    model: state.modelConfig.model,
    modelNickname: state.modelConfig.nickname,
    maxTokens: 8192,
    temperature: 0.7,
    baseUrl: state.modelConfig.baseUrl,
    apiKey: apiKey,
    enableTools: agentToolSchemas.len > 0,
    tools: if agentToolSchemas.len > 0: some(agentToolSchemas) else: none(seq[ToolDefinition]),
    agentName: state.name  # For tool permission validation
  )

  if not trySendAPIRequest(state.channels, request):
    return (false, "Failed to send API request")

  # Wait for completion, collecting the response
  var lastContent = ""
  var responseComplete = false
  var pendingToolCalls: Table[string, CompactToolRequestInfo] = initTable[string, CompactToolRequestInfo]()
  var outputAfterToolCall = false
  var isInThinkingBlock = false
  var attempts = 0

  # Calculate timeout from config (default 5 minutes = 300 seconds)
  let timeoutSeconds = getGlobalConfig().agentTimeoutSeconds.get(300)
  let maxAttempts = (timeoutSeconds * 1000) div 100  # Convert to number of 100ms attempts

  while attempts < maxAttempts and not responseComplete:
    var response: APIResponse
    if tryReceiveAPIResponse(state.channels, response):
      if response.requestId == requestId:
        case response.kind:
        of arkReady:
          discard
        of arkStreamChunk:
          # Handle thinking content display (like CLI)
          if response.thinkingContent.isSome():
            let thinkingContent = response.thinkingContent.get()
            let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()

            if not isInThinkingBlock:
              # First thinking chunk - show emoji prefix (flush immediately to avoid buffering issues)
              flushStreamingBuffer(redraw = false)
              let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
              let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
              stdout.write(emojiPrefix & styledContent)
              stdout.flushFile()
              isInThinkingBlock = true
            else:
              # Continuing thinking - write directly without buffering
              let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
              stdout.write(styledContent)
              stdout.flushFile()

          # Display regular content
          if response.content.len > 0:
            if isInThinkingBlock:
              # Transition from thinking to regular content
              finishStreaming()
              writeCompleteLine("")
              isInThinkingBlock = false

            lastContent.add(response.content)
            writeStreamingChunk(response.content)

        of arkToolCallRequest, arkToolCallResult:
          # Use shared template for consistent tool call display
          handleToolCallDisplay(response, pendingToolCalls, outputAfterToolCall)

        of arkStreamComplete:
          finishStreaming()
          if lastContent.len > 0:
            writeCompleteLine("")
          responseComplete = true
        of arkStreamError:
          finishStreaming()
          return (false, response.error)

    sleep(100)
    attempts.inc()

  if not responseComplete:
    return (false, "Response timed out")

  # Return the last assistant response (already persisted to DB by API worker)
  return (true, lastContent)

proc applyModeChange(state: var AgentState, mode: AgentMode) =
  ## Apply mode change to current conversation (persisted to DB)
  let convId = getCurrentConversationId()
  if convId > 0:
    updateConversationMode(state.database, convId, mode)
    debug(fmt"Applied mode change to {mode}")

proc applyModelChange(state: var AgentState, modelNickname: string): bool =
  ## Apply model change to current conversation (persisted to DB)
  ## Returns true if model was found and applied
  let modelOpt = getModel(modelNickname)
  if modelOpt.isNone():
    return false

  state.modelConfig = modelOpt.get()
  let convId = getCurrentConversationId()
  if convId > 0:
    updateConversationModel(state.database, convId, modelNickname)
  debug(fmt"Applied model change to {modelNickname}")
  return true

proc processQuickCommand(state: var AgentState, request: NatsRequest) =
  ## Process quick commands that don't require agentic execution
  ## Safe to call concurrently during an agentic loop (for read-only commands)
  info(fmt"Processing quick command: {request.requestId}")
  state.requestCount.inc()

  try:
    let input = request.input.strip()
    let (command, args) = commands.parseCommand(input)

    # Handle local commands
    const localCommands = ["info", "conv", "new", "context", "inspect", "condense"]

    if command in localCommands:
      info(fmt"Executing local command: /{command}")
      sendStatusUpdate(state, request.requestId, fmt"Executing command: /{command}")

      var sess = initSession()
      var currentModel = state.modelConfig
      let commandResult = executeCommand(command, args, sess, currentModel)
      sendResponse(state, request.requestId, commandResult.message, done = true)

      # Update model if command changed it
      if currentModel.nickname != state.modelConfig.nickname:
        state.modelConfig = currentModel

      info(fmt"Command /{command} executed successfully")
      return

    # Handle /model alone (show current model)
    if command == "model" and args.len == 0:
      sendResponse(state, request.requestId,
        fmt"Current model: {state.modelConfig.nickname} ({state.modelConfig.model})", done = true)
      return

    # Handle /plan or /code alone (just set mode, no prompt)
    if command in ["plan", "code"] and args.len == 0:
      let newMode = if command == "plan": amPlan else: amCode
      applyModeChange(state, newMode)
      sendResponse(state, request.requestId,
        fmt"Switched to {command} mode", done = true)
      return

    # Handle /model with argument (model switch)
    if command == "model" and args.len > 0:
      if applyModelChange(state, args[0]):
        sendResponse(state, request.requestId,
          fmt"Switched to model: {state.modelConfig.nickname}", done = true)
      else:
        sendResponse(state, request.requestId,
          fmt"Unknown model: {args[0]}", done = true)
      return

    # Fallback - unknown quick command
    sendResponse(state, request.requestId,
      fmt"Unknown command: /{command}", done = true)

  except Exception as e:
    error(fmt"Error processing quick command: {e.msg}")
    sendResponse(state, request.requestId, fmt"Error: {e.msg}", done = true)

proc processAgenticRequest(state: var AgentState, request: NatsRequest) =
  ## Process an agentic request (ask/task) - runs in its own thread
  ## This handles the long-running LLM conversation loop
  info(fmt"Processing agentic request {request.requestId}")
  state.requestCount.inc()

  try:
    let input = request.input.strip()

    # Parse routing commands from input (/plan, /task, /model, /code + prompt)
    let parsed = command_parser.parseCommand(input)

    # Apply state changes (persisted to conversation in DB)
    if parsed.mode.isSome():
      let mode = parsed.mode.get()
      let agentMode = if mode == emPlan: amPlan else: amCode
      applyModeChange(state, agentMode)
      sendStatusUpdate(state, request.requestId, fmt"Switched to {mode} mode")

    if parsed.model.isSome():
      let modelNickname = parsed.model.get()
      if applyModelChange(state, modelNickname):
        sendStatusUpdate(state, request.requestId, fmt"Switched to model {modelNickname}")
      else:
        sendResponse(state, request.requestId,
          fmt"Unknown model: {modelNickname}", done = true)
        return

    # Check if we have work to do
    let hasPrompt = parsed.prompt.len > 0
    let isTask = parsed.conversationType.isSome() and parsed.conversationType.get() == ctTask

    if hasPrompt or isTask:
      # Execute the request based on conversation type
      if isTask:
        # Task mode: Fresh isolated context
        sendStatusUpdate(state, request.requestId, "Executing task (fresh context)...")

        let taskResult = executeTask(
          state.definition,
          parsed.prompt,
          state.modelConfig,
          state.channels,
          state.toolSchemas,
          state.database
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

        let askResult = executeAsk(state, parsed.prompt, request.requestId)

        if askResult.success:
          sendResponse(state, request.requestId, askResult.response, done = true)
          echo ""
          echo "[COMPLETED ✓]"
        else:
          sendResponse(state, request.requestId, fmt"Ask failed: {askResult.response}", done = true)
          echo ""
          echo fmt"[FAILED ✗] {askResult.response}"
          warn(fmt"Ask failed: {askResult.response}")

    else:
      # Nothing to do (empty input after parsing)
      sendResponse(state, request.requestId, "No action specified", done = true)

  except Exception as e:
    error(fmt"Error processing agentic request: {e.msg}")
    sendResponse(state, request.requestId, fmt"Error: {e.msg}", done = true)

type
  AgenticThreadParams = object
    state: ptr AgentState
    request: NatsRequest

proc agenticThreadProc(params: AgenticThreadParams) {.thread.} =
  ## Thread procedure for running agentic loops in background
  {.gcsafe.}:
    try:
      processAgenticRequest(params.state[], params.request)
    except Exception as e:
      error(fmt"Agentic thread error: {e.msg}")
    finally:
      # Signal completion by clearing the active flag
      params.state[].agenticActive.store(false)

proc publishHeartbeat(state: var AgentState) =
  ## Publish heartbeat to presence KV store
  try:
    state.natsClient.sendHeartbeat()
    debug("Published heartbeat")
  except Exception as e:
    warn(fmt"Failed to publish heartbeat: {e.msg}")

proc listenForRequests(state: var AgentState) =
  ## Main request listening loop - non-blocking design
  ## Quick commands execute immediately, agentic loops run in background thread
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
  var agenticThread: Thread[AgenticThreadParams]

  while state.running:
    # 1. Check for incoming messages with short timeout
    let maybeMsg = subscription.nextMsg(timeoutMs = 1000)

    if maybeMsg.isSome():
      let msg = maybeMsg.get()

      try:
        # Deserialize request using Sunny
        let request = fromJson(NatsRequest, msg.data)

        info(fmt"Received request: {request.requestId}")
        echo fmt"[REQUEST] {request.input}"
        echo ""

        # Classify and route the request
        let cmdClass = classifyCommand(request)

        case cmdClass:
        of ccSafeQuick:
          # Handle read-only commands immediately (even during agentic loop)
          processQuickCommand(state, request)
          if not state.agenticActive.load():
            echo ""
            echo "Waiting for requests..."
            echo ""

        of ccDisruptive:
          if state.agenticActive.load():
            # Return error - can't disrupt ongoing work
            sendResponse(state, request.requestId,
              "Cannot execute this command while ask/task is running", done = true)
          else:
            # No agentic loop running, safe to execute
            processQuickCommand(state, request)
            echo ""
            echo "Waiting for requests..."
            echo ""

        of ccAgentic:
          if state.agenticActive.load():
            # Queue agentic request for later
            state.pendingAgenticRequests.add(request)
            sendStatusUpdate(state, request.requestId,
              fmt"Queued - agent busy (position {state.pendingAgenticRequests.len})")
            info(fmt"Queued agentic request {request.requestId}, queue size: {state.pendingAgenticRequests.len}")
          else:
            # Start agentic loop in background thread
            state.agenticActive.store(true)
            state.agenticRequestId = request.requestId
            let params = AgenticThreadParams(state: addr state, request: request)
            createThread(agenticThread, agenticThreadProc, params)
            info(fmt"Started agentic thread for request {request.requestId}")

      except Exception as e:
        error(fmt"Failed to parse request: {e.msg}")

    # 2. Check if agentic loop completed and start next queued request
    if not state.agenticActive.load() and state.pendingAgenticRequests.len > 0:
      let nextRequest = state.pendingAgenticRequests[0]
      state.pendingAgenticRequests.delete(0)
      state.agenticActive.store(true)
      state.agenticRequestId = nextRequest.requestId
      let params = AgenticThreadParams(state: addr state, request: nextRequest)
      createThread(agenticThread, agenticThreadProc, params)
      info(fmt"Started queued agentic request {nextRequest.requestId}, remaining queue: {state.pendingAgenticRequests.len}")
      echo ""
      echo fmt"[QUEUE] Processing next request: {nextRequest.input}"
      echo ""

    # 3. Publish heartbeat (always, even during agentic loop)
    let now = getTime()
    if (now - lastHeartbeat).inSeconds() >= heartbeatInterval:
      publishHeartbeat(state)
      lastHeartbeat = now

proc cleanup(state: var AgentState) =
  ## Cleanup agent resources
  info("Cleaning up agent...")

  # Stop worker threads
  info("Stopping worker threads...")
  signalShutdown(state.channels)

  stopMcpWorker(state.mcpWorker)
  info("MCP worker stopped")

  stopToolWorker(state.toolWorker)
  info("Tool worker stopped")

  stopAPIWorker(state.apiWorker)
  info("API worker stopped")

  # Remove presence
  state.natsClient.removePresence()

  # Close NATS connection
  state.natsClient.close()

  # Close database
  state.database.close()

  info("Agent shutdown complete")

proc startAgentMode*(agentName: string, agentNick: string = "", modelName: string = "", natsUrl: string = "nats://localhost:4222", level: Level = lvlInfo, dump: bool = false, dumpsse: bool = false, logFile: string = "", task: string = "", ask: string = "") =
  ## Start agent mode - main entry point
  ## If task is provided, executes single task and exits (no interactive mode)
  ## If ask is provided, executes single ask without summarization and exits
  let displayName = if agentNick.len > 0: fmt"{agentName} (nick: {agentNick})" else: agentName

  if task.len > 0:
    echo fmt"Starting single-shot task execution: {displayName}"
    echo fmt"Task: {task}"
  else:
    echo fmt"Starting Niffler in agent mode: {displayName}"
  echo ""

  var state: AgentState

  try:
    # Initialize agent with nickname support
    state = initializeAgent(agentName, agentNick, natsUrl, modelName, level, logFile)

    # Start worker threads AFTER initializeAgent returns
    # Workers must be started here, not in initializeAgent, because AgentState
    # is returned by value and copying Thread objects after createThread corrupts them
    info("Starting worker threads...")
    let pool = if state.database != nil: state.database.pool else: nil

    state.apiWorker = startAPIWorker(state.channels, level, dump, dumpsse, database = state.database, pool = pool)
    info("API worker started")

    # Configure API worker with model
    if not configureAPIWorker(state.modelConfig):
      warn(fmt("Failed to configure API worker with model {state.modelConfig.nickname}"))

    state.toolWorker = startToolWorker(state.channels, level, dump, database = state.database)
    info("Tool worker started")

    state.mcpWorker = startMcpWorker(state.channels, level)
    info("MCP worker started")

    # Handle single-shot task execution or interactive mode
    if task.len > 0:
      # Single-shot task execution
      echo ""
      echo "Executing task..."
      echo ""

      let taskResult = executeTask(
        state.definition,
        task,
        state.modelConfig,
        state.channels,
        state.toolSchemas,
        state.database
      )

      # Display results
      echo ""
      if taskResult.success:
        echo "=== Task Completed Successfully ==="
        echo ""
        echo taskResult.summary
        echo ""
        if taskResult.artifacts.len > 0:
          echo "Files modified:"
          for artifact in taskResult.artifacts:
            echo "  - ", artifact
          echo ""
        if taskResult.tempArtifacts.len > 0:
          echo "Temporary files:"
          for artifact in taskResult.tempArtifacts:
            echo "  - ", artifact
          echo ""
        echo fmt"Tool calls: {taskResult.toolCalls}, Tokens: {taskResult.tokensUsed}"
      else:
        echo "=== Task Failed ==="
        echo ""
        echo "Error: ", taskResult.error
        echo ""

      # Exit after task completion
      return

    elif ask.len > 0:
      # Single-shot ask execution (like task but without summarization)
      echo ""
      echo "Executing ask..."
      echo ""

      # Use executeAsk which doesn't generate summary
      let askResult = executeAsk(state, ask, "cli_ask_" & $epochTime())

      if askResult.success:
        echo askResult.response
      else:
        echo "Error: ", askResult.response

      # Exit after ask completion
      return

    else:
      # Interactive mode - start listening for requests
      listenForRequests(state)

  except Exception as e:
    error(fmt"Agent mode failed: {e.msg}")
    echo fmt"Error: {e.msg}"
    quit(1)
  finally:
    cleanup(state)
