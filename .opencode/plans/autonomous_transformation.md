# Niffler Autonomous Agent Transformation Plan

## Vision

Transform Niffler from a CLI-focused interactive assistant into a **fully autonomous agent** that:
- Works independently on tasks, reporting results back
- Communicates via multiple channels (Discord, CLI, future: Slack, web)
- Manages multiple workspaces through database
- Coordinates with other Niffler agents via TiDB messaging
- Responds to task queues, file watchers, scheduled jobs, and webhooks

---

## Summary of Changes

| Aspect | Current | New |
|--------|---------|-----|
| **Interaction Model** | CLI-driven, user prompts | Autonomous, multiple channels |
| **Communication** | NATS for multi-agent | TiDB-based messaging |
| **Workspace** | Single working directory | Database-managed projects |
| **UI** | CLI as primary | Channels: Discord, CLI, future |
| **Task Execution** | User-initiated | Queue/watch/schedule/webhook triggered |
| **Agent Identity** | Single instance | Configurable personas |

---

## Phase 1: Foundation - Communication Abstraction

### 1.1 Create Communication Channel Interface

**New directory: `src/comms/`**

```
src/comms/
├── channel.nim      # Abstract CommunicationChannel interface
├── message.nim      # Message types for cross-channel communication
├── discord.nim      # Discord implementation
└── cli_channel.nim  # CLI as a channel implementation
```

**Core Interface (`channel.nim`):**
```nim
type
  ChannelMessage = object
    id: string
    sourceChannel: string    # "discord", "cli", etc.
    sourceId: string         # Discord message ID, CLI session ID
    senderId: string         # Discord user ID, "cli_user"
    senderName: string
    content: string
    workspaceId: Option[int] # Which workspace this relates to
    replyTo: Option[string]  # Thread/conversation ID
    metadata: JsonNode       # Channel-specific data

  ChannelResponse = object
    content: string
    reactions: seq[string]   # For Discord reactions
    replyTo: Option[string]
    metadata: JsonNode

  CommunicationChannel = ref object of RootObj
    name: string
    enabled: bool

method start*(channel: CommunicationChannel) {.base.} = discard
method stop*(channel: CommunicationChannel) {.base.} = discard
method sendMessage*(channel: CommunicationChannel, msg: ChannelMessage): Future[void]
method sendNotification*(channel: CommunicationChannel, title, body: string): Future[void]
```

### 1.2 Discord Integration

**Dependencies:** Need a Discord library for Nim. Options:
- `dimscord` - Pure Nim Discord library
- Write HTTP-based integration using Discord REST API

**Features to implement:**
- Bot connection and authentication
- Message receiving (mentions, DMs, monitored channels)
- Message sending with formatting
- Reaction handling
- Presence/status updates

**Configuration (`config.yaml`):**
```yaml
channels:
  discord:
    enabled: true
    token: "YOUR_BOT_TOKEN"
    guildId: "123456789"
    monitoredChannels:
      - "general"
      - "dev-alerts"
    commandPrefix: "!"
    notifyOn:
      taskComplete: true
      taskError: true
      workspaceChange: false
```

### 1.3 CLI as Channel

Refactor `src/ui/cli.nim` to implement `CommunicationChannel` interface. The CLI becomes just another way to talk to Niffler, not the primary interface.

---

## Phase 2: Autonomous Engine

### 2.1 Task Queue System

**New directory: `src/autonomous/`**

```
src/autonomous/
├── task_queue.nim    # Task queue processor
├── file_watcher.nim  # File system monitoring
├── scheduler.nim     # Cron-like job scheduling
└── webhook.nim       # HTTP webhook receiver
```

**Database Schema:**
```sql
CREATE TABLE task_queue (
  id INT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  workspace_id INT,
  priority INT DEFAULT 0,
  status ENUM('pending', 'running', 'completed', 'failed') DEFAULT 'pending',
  task_type VARCHAR(50),      -- 'user_request', 'file_change', 'scheduled', 'webhook'
  source_channel VARCHAR(50), -- 'discord', 'cli', 'internal'
  source_id VARCHAR(255),
  instruction TEXT,
  context JSON,               -- Additional context data
  result TEXT,
  error TEXT,
  started_at TIMESTAMP NULL,
  completed_at TIMESTAMP NULL,
  assigned_agent VARCHAR(100),
  INDEX idx_status_priority (status, priority DESC),
  INDEX idx_workspace (workspace_id)
);
```

**Task Queue Processor:**
```nim
proc processTaskQueue*(db: DatabaseBackend, agent: AgentDefinition) =
  ## Main loop for autonomous task processing
  while not shutdown:
    let task = fetchNextTask(db, agent.name)
    if task.isSome:
      executeTask(task.get())
    else:
      sleep(1000)  # Poll interval
```

### 2.2 File Watcher

Monitor configured directories for changes and trigger tasks.

**Database Schema:**
```sql
CREATE TABLE watched_path (
  id INT AUTO_INCREMENT PRIMARY KEY,
  workspace_id INT,
  path VARCHAR(500),
  patterns JSON,          -- ["*.nim", "src/**/*.nim"]
  events ENUM('create', 'modify', 'delete', 'all') DEFAULT 'all',
  task_template TEXT,     -- Instruction template with {file} placeholder
  enabled BOOLEAN DEFAULT TRUE
);
```

**Implementation:** Use `std/os` with `walkDir` polling or integrate with `inotify`/`FSEvents`.

### 2.3 Job Scheduler

Cron-like scheduling for recurring tasks.

**Database Schema:**
```sql
CREATE TABLE scheduled_job (
  id INT AUTO_INCREMENT PRIMARY KEY,
  workspace_id INT,
  name VARCHAR(100),
  cron_expr VARCHAR(100),     -- Standard cron expression
  instruction TEXT,
  last_run TIMESTAMP NULL,
  next_run TIMESTAMP,
  enabled BOOLEAN DEFAULT TRUE
);
```

### 2.4 Webhook Receiver

HTTP server for receiving external triggers (GitHub webhooks, etc.).

**Database Schema:**
```sql
CREATE TABLE webhook_endpoint (
  id INT AUTO_INCREMENT PRIMARY KEY,
  path VARCHAR(100),          -- /webhook/github-pr
  secret VARCHAR(255),
  task_template TEXT,
  enabled BOOLEAN DEFAULT TRUE
);

CREATE TABLE webhook_event (
  id INT AUTO_INCREMENT PRIMARY KEY,
  endpoint_id INT,
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  headers JSON,
  payload JSON,
  task_id INT,               -- Link to created task
  processed BOOLEAN DEFAULT FALSE
);
```

---

## Phase 3: Workspace Management

### 3.1 Database-Managed Workspaces

**New directory: `src/workspace/`**

```
src/workspace/
├── manager.nim    # Workspace CRUD and context switching
├── context.nim    # Active workspace state
└── resolver.nim   # Path resolution across workspaces
```

**Database Schema:**
```sql
CREATE TABLE workspace (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100),
  path VARCHAR(500),
  description TEXT,
  git_remote VARCHAR(500),
  default_branch VARCHAR(100),
  settings JSON,              -- Project-specific settings
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_accessed TIMESTAMP
);

CREATE TABLE workspace_file (
  id INT AUTO_INCREMENT PRIMARY KEY,
  workspace_id INT,
  path VARCHAR(500),
  last_modified TIMESTAMP,
  indexed_at TIMESTAMP,
  metadata JSON
);
```

**Workspace Manager:**
```nim
type
  WorkspaceManager = ref object
    db: DatabaseBackend
    activeWorkspace: Option[int]
    workspaceCache: Table[int, Workspace]

proc listWorkspaces*(mgr: WorkspaceManager): seq[Workspace]
proc createWorkspace*(mgr: WorkspaceManager, name, path: string): Workspace
proc setActiveWorkspace*(mgr: WorkspaceManager, id: int)
proc resolvePath*(mgr: WorkspaceManager, relativePath: string): string
```

### 3.2 Tool Modifications

Update tools to work with workspace context instead of current working directory:
- `read`, `edit`, `create`, `list`, `bash` - Accept workspace context
- Path resolution through `WorkspaceManager`

---

## Phase 4: Agent Messaging via TiDB

### 4.1 Inter-Agent Communication

**New directory: `src/agent/`**

```
src/agent/
├── messaging.nim   # TiDB-based message queue
├── presence.nim    # Agent heartbeat/presence
├── mailbox.nim     # Message inbox/outbox
└── coordinator.nim # Multi-agent task coordination
```

**Database Schema:**
```sql
CREATE TABLE agent (
  id INT AUTO_INCREMENT PRIMARY KEY,
  agent_id VARCHAR(100) UNIQUE,  -- Unique agent identifier
  persona VARCHAR(100),          -- "coder", "reviewer", "tester"
  status ENUM('online', 'busy', 'offline') DEFAULT 'offline',
  last_heartbeat TIMESTAMP,
  capabilities JSON,             -- Available tools, skills
  config JSON                    -- Model, system prompt overrides
);

CREATE TABLE agent_message (
  id INT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  from_agent VARCHAR(100),
  to_agent VARCHAR(100),         -- NULL for broadcast
  message_type ENUM('task', 'query', 'response', 'notification'),
  subject VARCHAR(255),
  content TEXT,
  metadata JSON,
  read_at TIMESTAMP NULL,
  parent_message_id INT          -- For threading
);
```

**Message Flow:**
```
Agent A → INSERT INTO agent_message (to_agent='agent_b', ...)
Agent B polls: SELECT * FROM agent_message WHERE to_agent='agent_b' AND read_at IS NULL
Agent B processes, marks read: UPDATE agent_message SET read_at=NOW() WHERE id=...
```

### 4.2 Agent Presence

Heartbeat-based presence tracking:
```nim
proc startHeartbeat*(db: DatabaseBackend, agentId: string) =
  spawn heartbeatLoop(db, agentId)

proc heartbeatLoop(db: DatabaseBackend, agentId: string) =
  while not shutdown:
    db.exec("UPDATE agent SET last_heartbeat = NOW(), status = ? WHERE agent_id = ?", 
            getStatus(), agentId)
    sleep(5000)
```

### 4.3 Task Delegation Between Agents

```nim
proc delegateTask*(db: DatabaseBackend, toAgent: string, instruction: string): int =
  ## Create task assigned to another agent
  let taskId = db.insertId("""
    INSERT INTO task_queue (task_type, instruction, assigned_agent, status)
    VALUES ('delegated', ?, ?, 'pending')
  """, instruction, toAgent)
  
  # Notify agent
  db.exec("""
    INSERT INTO agent_message (from_agent, to_agent, message_type, subject, content)
    VALUES (?, ?, 'task', 'New task assigned', ?)
  """, myAgentId, toAgent, $taskId)
  
  return taskId
```

---

## Phase 5: Remove NATS

### Files to Delete
- `src/core/nats_client.nim`
- `src/ui/master_cli.nim`
- `src/ui/agent_cli.nim`
- `src/ui/nats_listener.nim`
- `src/ui/nats_monitor.nim`
- `src/types/nats_messages.nim`

### Files to Modify
- `src/niffler.nim` - Remove NATS-related commands and modes
- `src/core/config.nim` - Remove NATS configuration
- `src/types/config.nim` - Remove NATS config types
- `src/core/channels.nim` - Remove any NATS-related channel logic

---

## Phase 6: Configuration Updates

### New Config Structure

```yaml
# Agent identity
agent:
  id: "niffler-coder-1"
  persona: "coder"        # References persona definition

# Personas (replaces agents/)
personas:
  coder:
    description: "General coding agent"
    model: "claude-sonnet"
    systemPrompt: |
      You are an autonomous coding agent...
    allowedTools:
      - read
      - edit
      - create
      - bash
      - list
      - fetch

  reviewer:
    description: "Code review agent"
    model: "claude-sonnet"
    allowedTools:
      - read
      - list
      - fetch

# Communication channels
channels:
  discord:
    enabled: true
    token: "${DISCORD_TOKEN}"
    guildId: "123456789"
    monitoredChannels: ["general", "dev"]
  cli:
    enabled: true

# Autonomous features
autonomous:
  taskPollInterval: 1000      # ms
  heartbeatInterval: 5000     # ms
  maxConcurrentTasks: 3

# Webhook server
webhooks:
  enabled: true
  port: 8080
  endpoints:
    - path: /github
      secret: "${GITHUB_WEBHOOK_SECRET}"
      taskTemplate: |
        Process GitHub webhook: {payload}

# Workspaces
workspaces:
  - name: "niffler"
    path: "/home/user/projects/niffler"
  - name: "other-project"
    path: "/home/user/projects/other"

# Scheduled jobs
scheduledJobs:
  - name: "daily-summary"
    cron: "0 9 * * *"
    instruction: "Generate a summary of yesterday's activity"

# File watchers
fileWatchers:
  - workspace: "niffler"
    patterns: ["src/**/*.nim"]
    events: ["modify"]
    taskTemplate: "Review changes in {file}"
```

---

## Implementation Order

### Phase 1: Foundation (Week 1-2)
1. Create `src/comms/channel.nim` with interface
2. Create `src/comms/message.nim` with message types
3. Add `agent`, `agent_message`, `workspace` tables to database
4. Create `src/workspace/manager.nim`
5. Refactor existing tools to accept workspace context

### Phase 2: Discord Integration (Week 2-3)
1. Add Discord library dependency
2. Implement `src/comms/discord.nim`
3. Wire Discord messages to task queue
4. Implement notification sending

### Phase 3: Autonomous Engine (Week 3-4)
1. Create `src/autonomous/task_queue.nim`
2. Implement task processor loop
3. Create `src/autonomous/scheduler.nim`
4. Create `src/autonomous/file_watcher.nim`
5. Create `src/autonomous/webhook.nim`

### Phase 4: Agent Messaging (Week 4-5)
1. Create `src/agent/messaging.nim`
2. Create `src/agent/presence.nim`
3. Implement inter-agent task delegation
4. Test multi-agent scenarios

### Phase 5: Cleanup (Week 5-6)
1. Remove all NATS code
2. Refactor CLI to channel implementation
3. Update all documentation
4. Integration tests

---

## Database Migration Script

```sql
-- New tables for autonomous agent system

-- Agent identity and presence
CREATE TABLE IF NOT EXISTS agent (
  id INT AUTO_INCREMENT PRIMARY KEY,
  agent_id VARCHAR(100) UNIQUE NOT NULL,
  persona VARCHAR(100),
  status ENUM('online', 'busy', 'offline') DEFAULT 'offline',
  last_heartbeat TIMESTAMP NULL,
  capabilities JSON,
  config JSON,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Inter-agent messaging
CREATE TABLE IF NOT EXISTS agent_message (
  id INT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  from_agent VARCHAR(100),
  to_agent VARCHAR(100),
  message_type ENUM('task', 'query', 'response', 'notification', 'broadcast'),
  subject VARCHAR(255),
  content TEXT,
  metadata JSON,
  read_at TIMESTAMP NULL,
  parent_message_id INT,
  INDEX idx_to_agent (to_agent, read_at),
  INDEX idx_from_agent (from_agent)
);

-- Workspaces
CREATE TABLE IF NOT EXISTS workspace (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL,
  path VARCHAR(500) NOT NULL,
  description TEXT,
  git_remote VARCHAR(500),
  default_branch VARCHAR(100) DEFAULT 'main',
  settings JSON,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_accessed TIMESTAMP NULL
);

-- Task queue
CREATE TABLE IF NOT EXISTS task_queue (
  id INT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  workspace_id INT,
  priority INT DEFAULT 0,
  status ENUM('pending', 'running', 'completed', 'failed', 'cancelled') DEFAULT 'pending',
  task_type VARCHAR(50),
  source_channel VARCHAR(50),
  source_id VARCHAR(255),
  instruction TEXT,
  context JSON,
  result TEXT,
  error TEXT,
  started_at TIMESTAMP NULL,
  completed_at TIMESTAMP NULL,
  assigned_agent VARCHAR(100),
  conversation_id INT,
  INDEX idx_status (status, priority DESC),
  INDEX idx_workspace (workspace_id),
  FOREIGN KEY (workspace_id) REFERENCES workspace(id)
);

-- Scheduled jobs
CREATE TABLE IF NOT EXISTS scheduled_job (
  id INT AUTO_INCREMENT PRIMARY KEY,
  workspace_id INT,
  name VARCHAR(100) NOT NULL,
  cron_expr VARCHAR(100) NOT NULL,
  instruction TEXT NOT NULL,
  last_run TIMESTAMP NULL,
  next_run TIMESTAMP,
  enabled BOOLEAN DEFAULT TRUE,
  FOREIGN KEY (workspace_id) REFERENCES workspace(id)
);

-- File watchers
CREATE TABLE IF NOT EXISTS watched_path (
  id INT AUTO_INCREMENT PRIMARY KEY,
  workspace_id INT NOT NULL,
  path VARCHAR(500) NOT NULL,
  patterns JSON,
  events ENUM('create', 'modify', 'delete', 'all') DEFAULT 'all',
  task_template TEXT,
  enabled BOOLEAN DEFAULT TRUE,
  FOREIGN KEY (workspace_id) REFERENCES workspace(id)
);

-- Webhook endpoints
CREATE TABLE IF NOT EXISTS webhook_endpoint (
  id INT AUTO_INCREMENT PRIMARY KEY,
  path VARCHAR(100) UNIQUE NOT NULL,
  secret VARCHAR(255),
  task_template TEXT,
  workspace_id INT,
  enabled BOOLEAN DEFAULT TRUE,
  FOREIGN KEY (workspace_id) REFERENCES workspace(id)
);

-- Webhook events
CREATE TABLE IF NOT EXISTS webhook_event (
  id INT AUTO_INCREMENT PRIMARY KEY,
  endpoint_id INT,
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  headers JSON,
  payload JSON,
  task_id INT,
  processed BOOLEAN DEFAULT FALSE,
  FOREIGN KEY (endpoint_id) REFERENCES webhook_endpoint(id)
);
```

---

## Key Design Decisions

1. **TiDB over NATS**: Simpler stack, already have TiDB, no new infrastructure
2. **Polling over Push**: Task queue polling is simpler and works with TiDB
3. **Channel Abstraction**: Makes adding new communication methods easy
4. **Workspace-Centric**: All operations are in workspace context
5. **Persona System**: Flexible agent definitions with tool restrictions

---

## Open Questions

1. **Discord library choice**: `dimscord` vs custom HTTP implementation?
2. **File watcher implementation**: Polling vs native OS notifications?
3. **Webhook server**: Separate port or integrate with existing HTTP?
4. **Task concurrency**: How many tasks can run simultaneously per agent?
5. **Agent discovery**: How do agents find each other's capabilities?

---

## Success Criteria

- [ ] Niffler can run autonomously, processing tasks from queue
- [ ] Discord integration works with all specified features
- [ ] Multiple workspaces can be managed
- [ ] Agents can communicate via TiDB
- [ ] All NATS code removed
- [ ] Tests pass for new functionality
