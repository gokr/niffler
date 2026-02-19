## Agent Messaging Module
##
## Handles inter-agent communication via the database. Agents can send messages
## to each other and poll for new messages.

import std/[options, json, strformat, times, tables, logging, os]
import ../core/database
import debby/pools
import debby/mysql

type
  AgentMessenger* = ref object
    db*: DatabaseBackend
    myAgentId*: string
    pollInterval*: int
    running*: bool

proc newAgentMessenger*(db: DatabaseBackend, agentId: string): AgentMessenger =
  ## Create a new agent messenger
  result = AgentMessenger(
    db: db,
    myAgentId: agentId,
    pollInterval: 5000,  ## 5 second default poll interval
    running: false
  )

proc registerAgent*(
  db: DatabaseBackend,
  agentId, persona: string,
  capabilities: JsonNode = newJObject(),
  config: JsonNode = newJObject()
): bool =
  ## Register a new agent in the database
  if db == nil:
    return false
  
  db.pool.withDb:
    # Check if agent already exists
    let existing = db.filter(Agent, it.agentId == agentId)
    if existing.len > 0:
      # Update existing agent
      var agent = existing[0]
      agent.status = asOnline
      agent.lastHeartbeat = some(now().utc())
      agent.capabilities = $capabilities
      agent.config = $config
      db.update(agent)
      return true
    
    # Create new agent
    var agent = Agent(
      id: 0,
      agentId: agentId,
      persona: persona,
      status: asOnline,
      lastHeartbeat: some(now().utc()),
      capabilities: $capabilities,
      config: $config,
      createdAt: now().utc()
    )
    db.insert(agent)
  
  return true

proc unregisterAgent*(db: DatabaseBackend, agentId: string) =
  ## Mark an agent as offline
  if db == nil:
    return
  
  db.pool.withDb:
    let agents = db.filter(Agent, it.agentId == agentId)
    if agents.len > 0:
      var agent = agents[0]
      agent.status = asOffline
      agent.lastHeartbeat = none(DateTime)
      db.update(agent)

proc updateAgentStatus*(db: DatabaseBackend, agentId: string, status: AgentStatus) =
  ## Update an agent's status
  if db == nil:
    return
  
  db.pool.withDb:
    let agents = db.filter(Agent, it.agentId == agentId)
    if agents.len > 0:
      var agent = agents[0]
      agent.status = status
      agent.lastHeartbeat = some(now().utc())
      db.update(agent)

proc sendHeartbeat*(db: DatabaseBackend, agentId: string) =
  ## Send a heartbeat to show the agent is alive
  if db == nil:
    return
  
  db.pool.withDb:
    let agents = db.filter(Agent, it.agentId == agentId)
    if agents.len > 0:
      var agent = agents[0]
      agent.lastHeartbeat = some(now().utc())
      if agent.status == asOffline:
        agent.status = asOnline
      db.update(agent)

proc sendMessage*(
  db: DatabaseBackend,
  fromAgent, toAgent: string,
  messageType: AgentMessageType,
  subject, content: string,
  metadata: JsonNode = newJObject(),
  parentMessageId: Option[int] = none(int)
): int =
  ## Send a message to another agent
  if db == nil:
    return 0
  
  var message = AgentMessage(
    id: 0,
    createdAt: now().utc(),
    fromAgent: fromAgent,
    toAgent: toAgent,
    messageType: messageType,
    subject: subject,
    content: content,
    metadata: $metadata,
    readAt: none(DateTime),
    parentMessageId: parentMessageId
  )
  
  db.pool.withDb:
    db.insert(message)
  
  return message.id

proc sendBroadcast*(
  db: DatabaseBackend,
  fromAgent: string,
  messageType: AgentMessageType,
  subject, content: string,
  metadata: JsonNode = newJObject()
): int =
  ## Send a broadcast message to all agents
  if db == nil:
    return 0
  
  var message = AgentMessage(
    id: 0,
    createdAt: now().utc(),
    fromAgent: fromAgent,
    toAgent: "",  ## Empty means broadcast
    messageType: messageType,
    subject: subject,
    content: content,
    metadata: $metadata,
    readAt: none(DateTime),
    parentMessageId: none(int)
  )
  
  db.pool.withDb:
    db.insert(message)
  
  return message.id

proc getUnreadMessages*(db: DatabaseBackend, agentId: string): seq[AgentMessage] =
  ## Get all unread messages for an agent
  if db == nil:
    return @[]
  
  db.pool.withDb:
    ## Get direct messages and broadcasts
    let messages = db.query(AgentMessage, """
      SELECT * FROM agent_message
      WHERE (to_agent = ? OR to_agent = '') AND read_at IS NULL
      ORDER BY created_at ASC
    """, agentId)
    return messages

proc markMessageAsRead*(db: DatabaseBackend, messageId: int) =
  ## Mark a message as read
  if db == nil:
    return
  
  db.pool.withDb:
    let messages = db.filter(AgentMessage, it.id == messageId)
    if messages.len > 0:
      var message = messages[0]
      message.readAt = some(now().utc())
      db.update(message)

proc getMessage*(db: DatabaseBackend, messageId: int): Option[AgentMessage] =
  ## Get a message by ID
  if db == nil:
    return none(AgentMessage)
  
  db.pool.withDb:
    let messages = db.filter(AgentMessage, it.id == messageId)
    if messages.len > 0:
      return some(messages[0])
  
  return none(AgentMessage)

proc listAgents*(db: DatabaseBackend): seq[Agent] =
  ## List all registered agents
  if db == nil:
    return @[]
  
  db.pool.withDb:
    return db.filter(Agent)

proc getAgent*(db: DatabaseBackend, agentId: string): Option[Agent] =
  ## Get an agent by ID
  if db == nil:
    return none(Agent)
  
  db.pool.withDb:
    let agents = db.filter(Agent, it.agentId == agentId)
    if agents.len > 0:
      return some(agents[0])
  
  return none(Agent)

proc getOnlineAgents*(db: DatabaseBackend): seq[Agent] =
  ## Get all online agents
  if db == nil:
    return @[]
  
  db.pool.withDb:
    return db.filter(Agent, it.status == asOnline)

proc messengerLoop*(messenger: AgentMessenger) {.gcsafe.} =
  ## Main message polling loop
  messenger.running = true
  info(fmt("Agent messenger started for {messenger.myAgentId}"))
  
  while messenger.running:
    try:
      # Send heartbeat
      sendHeartbeat(messenger.db, messenger.myAgentId)
      
      # Check for new messages
      let messages = getUnreadMessages(messenger.db, messenger.myAgentId)
      for message in messages:
        info(fmt("Received message from {message.fromAgent}: {message.subject}"))
        
        # Mark as read
        markMessageAsRead(messenger.db, message.id)
        
        # TODO: Process the message (call registered handlers)
        # For now, just log it
      
      # Sleep before next poll
      sleep(messenger.pollInterval)
    except Exception as e:
      error(fmt("Error in messenger loop: {e.msg}"))
      sleep(messenger.pollInterval)
  
  info(fmt("Agent messenger stopped for {messenger.myAgentId}"))

proc startMessenger*(messenger: AgentMessenger) =
  ## Start the messenger in a new thread
  if messenger.running:
    warn("Messenger is already running")
    return
  
  # TODO: Proper threading implementation
  # For now, run synchronously
  messengerLoop(messenger)
  # spawn messengerLoop(messenger)

proc stopMessenger*(messenger: AgentMessenger) =
  ## Stop the messenger
  messenger.running = false
  unregisterAgent(messenger.db, messenger.myAgentId)
  info("Messenger stop requested")

proc findAgentByCapability*(db: DatabaseBackend, capability: string): seq[Agent] =
  ## Find agents that have a specific capability
  if db == nil:
    return @[]
  
  db.pool.withDb:
    let agents = db.filter(Agent)
    result = @[]
    for agent in agents:
      try:
        let caps = parseJson(agent.capabilities)
        if caps.hasKey(capability):
          result.add(agent)
      except:
        discard
