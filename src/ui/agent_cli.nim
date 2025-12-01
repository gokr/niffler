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

import std/[logging, strformat, times, os, options, strutils, json, random]
import ../core/[nats_client, command_parser, config, database, channels, app, session, mode_state, conversation_manager, log_file, completion_detection]
import ../core/task_executor
import ../types/[nats_messages, agents, config as configTypes, messages, mode]
import ../api/[api]
import ../tools/[worker, registry]
import ../mcp/[mcp]
import output_shared
import tool_visualizer
import theme
import commands

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
    conversationId: int  # Active conversation for Ask mode
    # Worker threads
    apiWorker: APIWorker
    toolWorker: ToolWorker
    mcpWorker: MCPWorker
    toolSchemas: seq[ToolDefinition]

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
  if modelName.len > 0:
    # Try to find specified model
    for model in config.models:
      if model.nickname == modelName:
        result.modelConfig = model
        info(fmt"Found model: {model.nickname} ({model.baseUrl})")
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
  initSessionManager(pool, epochTime().int)
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

  if state.conversationId > 0:
    # Already have an active conversation
    debug(fmt"Using existing conversation: {state.conversationId}")
    # Make sure session is pointing to this conversation
    for attempt in 1..maxRetries:
      try:
        discard switchToConversation(state.database, state.conversationId)
        return true
      except Exception as e:
        if "locked" in e.msg and attempt < maxRetries:
          debug(fmt"Database locked, retry {attempt}/{maxRetries}")
          sleep(retryDelayMs * attempt)
        else:
          warn(fmt"Failed to switch to conversation {state.conversationId}: {e.msg}")
          state.conversationId = 0
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
      state.conversationId = conv.id

      # Switch session to this conversation
      discard switchToConversation(state.database, conv.id)

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

proc executeAskMode(state: var AgentState, prompt: string, requestId: string): tuple[success: bool, summary: string] =
  ## Execute Ask mode: continue conversation with context
  ## Displays streaming output to agent terminal, sends completion to master

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

  echo ""

  # Prepare tool schemas filtered by agent's allowed tools
  var agentToolSchemas: seq[ToolDefinition] = @[]
  for tool in state.toolSchemas:
    if tool.function.name in state.definition.allowedTools:
      agentToolSchemas.add(tool)

  # Conversation loop (handle tool calls)
  let maxTurns = getMaxTurnsForAgent(some(state.definition))
  var turn = 0
  var totalTokens = 0
  var totalToolCalls = 0
  var finalResponse = ""

  while turn < maxTurns:
    turn.inc()
    debug(fmt"Ask turn {turn}/{maxTurns}")

    # Create and send API request
    let turnRequestId = fmt"ask_{state.name}_{turn}_{rand(100000)}"
    let request = APIRequest(
      kind: arkChatRequest,
      requestId: turnRequestId,
      messages: messages,
      model: state.modelConfig.model,
      modelNickname: state.modelConfig.nickname,
      maxTokens: 8192,
      temperature: 0.7,
      baseUrl: state.modelConfig.baseUrl,
      apiKey: apiKey,
      enableTools: agentToolSchemas.len > 0,
      tools: if agentToolSchemas.len > 0: some(agentToolSchemas) else: none(seq[ToolDefinition])
    )

    if not trySendAPIRequest(state.channels, request):
      return (false, "Failed to send API request")

    # Collect and display streaming response
    var assistantContent = ""
    var toolCalls: seq[LLMToolCall] = @[]
    var responseComplete = false
    var isInThinkingBlock = false
    var attempts = 0

    # Calculate timeout from config (default 5 minutes = 300 seconds)
    let timeoutSeconds = getGlobalConfig().agentTimeoutSeconds.get(300)
    let maxAttempts = (timeoutSeconds * 1000) div 10  # Convert to number of 10ms attempts

    while attempts < maxAttempts and not responseComplete:
      var response: APIResponse
      if tryReceiveAPIResponse(state.channels, response):
        if response.requestId == turnRequestId:
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

              assistantContent.add(response.content)
              writeStreamingChunk(response.content)

            # Collect tool calls
            if response.toolCalls.isSome():
              for tc in response.toolCalls.get():
                toolCalls.add(tc)
                totalToolCalls.inc()

          of arkStreamComplete:
            finishStreaming()
            if assistantContent.len > 0:
              writeCompleteLine("")
            totalTokens += response.usage.inputTokens + response.usage.outputTokens
            responseComplete = true
          of arkStreamError:
            finishStreaming()
            return (false, fmt"API error: {response.error}")
          of arkToolCallRequest:
            # Display tool request from API (different from our tool execution)
            finishStreaming()
            let toolRequest = response.toolRequestInfo
            let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
            writeCompleteLine(formattedRequest & " ⏳")
          of arkToolCallResult:
            # Display tool result from API
            let toolResult = response.toolResultInfo
            let formattedResult = formatCompactToolResultWithIndent(toolResult)
            writeCompleteLine(formattedResult)

      sleep(10)
      attempts.inc()

    if not responseComplete:
      return (false, "Response timed out")

    # Store final response for summary
    finalResponse = assistantContent

    # Add assistant message to conversation (persists to DB)
    if assistantContent.len > 0:
      var assistantMsg = conversation_manager.addAssistantMessage(assistantContent)
      if toolCalls.len > 0:
        assistantMsg.toolCalls = some(toolCalls)
      messages.add(Message(
        role: mrAssistant,
        content: assistantContent,
        toolCalls: if toolCalls.len > 0: some(toolCalls) else: none(seq[LLMToolCall])
      ))

    # Check for completion signal
    let completionSignal = detectCompletionSignal(assistantContent)
    if completionSignal != csNone:
      debug(fmt"Completion signal detected in ask mode: {completionSignal}")
      break

    # If no tool calls, conversation turn is complete
    if toolCalls.len == 0:
      break

    # Execute tool calls
    let agentContext = AgentContext(
      isMainAgent: false,
      agent: state.definition
    )

    for toolCall in toolCalls:
      # Display tool call - parse args string to JsonNode
      let argsJson = try:
        parseJson(toolCall.function.arguments)
      except:
        newJObject()

      let toolRequest = CompactToolRequestInfo(
        toolCallId: toolCall.id,
        toolName: toolCall.function.name,
        args: argsJson
      )
      let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
      writeCompleteLine(formattedRequest & " ⏳")

      # Validate tool is allowed
      if not isToolAllowed(agentContext, toolCall.function.name):
        let errorMsg = fmt"Tool '{toolCall.function.name}' not allowed for agent '{state.name}'"
        writeCompleteLine(formatWithStyle(fmt"  ✗ {errorMsg}", currentTheme.error))
        messages.add(Message(role: mrTool, content: errorMsg, toolCallId: some(toolCall.id)))
        discard conversation_manager.addToolMessage(errorMsg, toolCall.id)
        continue

      # Send to tool worker
      let toolReq = ToolRequest(
        kind: trkExecute,
        requestId: toolCall.id,
        toolName: toolCall.function.name,
        arguments: toolCall.function.arguments,
        agentName: state.definition.name
      )

      if not trySendToolRequest(state.channels, toolReq):
        let errorMsg = "Failed to send tool request"
        writeCompleteLine(formatWithStyle(fmt"  ✗ {errorMsg}", currentTheme.error))
        messages.add(Message(role: mrTool, content: errorMsg, toolCallId: some(toolCall.id)))
        discard conversation_manager.addToolMessage(errorMsg, toolCall.id)
        continue

      # Wait for tool response
      var toolResponseReceived = false
      var toolAttempts = 0
      const maxToolAttempts = 3000

      while toolAttempts < maxToolAttempts and not toolResponseReceived:
        let maybeResponse = tryReceiveToolResponse(state.channels)
        if maybeResponse.isSome():
          let toolResponse = maybeResponse.get()
          if toolResponse.requestId == toolCall.id:
            let toolContent = if toolResponse.kind == trkResult:
              toolResponse.output
            else:
              fmt"Error: {toolResponse.error}"

            # Display tool result
            let resultInfo = CompactToolResultInfo(
              toolCallId: toolCall.id,
              toolName: toolCall.function.name,
              resultSummary: toolContent,
              success: toolResponse.kind == trkResult
            )
            let formattedResult = formatCompactToolResultWithIndent(resultInfo)
            writeCompleteLine(formattedResult)

            # Add to conversation
            messages.add(Message(role: mrTool, content: toolContent, toolCallId: some(toolCall.id)))
            discard conversation_manager.addToolMessage(toolContent, toolCall.id)

            toolResponseReceived = true
            break

        sleep(10)
        toolAttempts.inc()

      if not toolResponseReceived:
        let errorMsg = "Tool execution timed out"
        writeCompleteLine(formatWithStyle(fmt"  ✗ {errorMsg}", currentTheme.error))
        messages.add(Message(role: mrTool, content: errorMsg, toolCallId: some(toolCall.id)))
        discard conversation_manager.addToolMessage(errorMsg, toolCall.id)

  # Return full response (no truncation)
  let summary = finalResponse

  info(fmt"Ask completed: {totalToolCalls} tool calls, {totalTokens} tokens")
  return (true, summary)

proc processRequest(state: var AgentState, request: NatsRequest) =
  ## Process an incoming request from master
  info(fmt"Processing request {request.requestId}")
  state.requestCount.inc()

  try:
    # Check if input is an agent command (like /info, /conv, etc.)
    if request.input.strip().startsWith("/"):
      let (command, args) = commands.parseCommand(request.input)

      # Check if this is an agent command (not a routing command like /plan, /task)
      if command.len > 0 and isAgentCommand(command):
        info(fmt"Executing agent command: /{command}")
        sendStatusUpdate(state, request.requestId, fmt"Executing command: /{command}")

        # Execute the command in agent context
        var sess = initSession()
        var currentModel = state.modelConfig
        let commandResult = executeCommand(command, args, sess, currentModel)

        # Send the command output back to master
        sendResponse(state, request.requestId, commandResult.message, done = true)

        # Update model if changed
        if currentModel.nickname != state.modelConfig.nickname:
          state.modelConfig = currentModel

        info(fmt"Command /{command} executed successfully")
        return

    # Parse routing commands from input (/plan, /task, /model)
    let parsed = command_parser.parseCommand(request.input)

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

    # Execute the request based on conversation type
    if parsed.conversationType.isSome() and parsed.conversationType.get() == ctTask:
      # Task mode: Fresh isolated context
      sendStatusUpdate(state, request.requestId, "Executing task (fresh context)...")

      let taskResult = executeTask(
        state.definition,
        parsed.prompt,
        state.modelConfig,
        state.channels,
        state.toolSchemas
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

      let askResult = executeAskMode(state, parsed.prompt, request.requestId)

      if askResult.success:
        sendResponse(state, request.requestId, askResult.summary, done = true)
        echo ""
        echo "[COMPLETED ✓]"
      else:
        sendResponse(state, request.requestId, fmt"Ask failed: {askResult.summary}", done = true)
        echo ""
        echo fmt"[FAILED ✗] {askResult.summary}"
        warn(fmt"Ask failed: {askResult.summary}")

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
        # Deserialize request using Sunny
        let request = fromJson(NatsRequest, msg.data)

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

proc startAgentMode*(agentName: string, agentNick: string = "", modelName: string = "", natsUrl: string = "nats://localhost:4222", level: Level = lvlInfo, dump: bool = false, logFile: string = "", task: string = "") =
  ## Start agent mode - main entry point
  ## If task is provided, executes single task and exits (no interactive mode)
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

    state.apiWorker = startAPIWorker(state.channels, level, dump, database = state.database, pool = pool)
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
        state.toolSchemas
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
        echo fmt"Tool calls: {taskResult.toolCalls}, Tokens: {taskResult.tokensUsed}"
      else:
        echo "=== Task Failed ==="
        echo ""
        echo "Error: ", taskResult.error
        echo ""

      # Exit after task completion
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
