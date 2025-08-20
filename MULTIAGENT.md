# Multi-Agent Niffler Architecture

This document outlines a design for implementing a multi-agent system using niffler, where multiple specialized AI agents can run concurrently and be coordinated through a master UI interface.

## Concept Overview

The multi-agent system would consist of:
1. **Master Niffler UI** - Main interface for entering prompts with agent routing via nicknames
2. **Agent Niffler Instances** - Specialized agents running as separate processes, each showing their own conversations
3. **Inter-Process Communication** - Coordination layer between master and agents

## Current Architecture Analysis

### Core Strengths for Multi-Agent Extension

**Thread-based Architecture**: Niffler uses dedicated worker threads (API worker, Tool worker) with thread-safe channel communication via `src/core/channels.nim`. This provides a solid foundation for extending to inter-process communication.

**Configuration System**: The flexible model configuration in `src/core/config.nim` supports multiple AI providers and nicknames, making it easy to assign different models to different agents.

**Message Types**: Well-defined message protocols in `src/types/messages.nim` for API requests/responses and tool execution can be extended for agent communication.

**CLI Framework**: Uses docopt for command parsing and supports model selection via `--model` flag, providing a foundation for agent-specific startup.

### Current Components Relevant to Multi-Agent

- **Main Entry Point** (`src/niffler.nim`): CLI parsing and mode selection - can be extended for agent modes
- **CLI Interface** (`src/ui/cli.nim`): Interactive terminal UI with model switching - can be adapted for agent routing
- **Threading System** (`src/core/channels.nim`): Thread-safe message passing - template for IPC
- **API Worker** (`src/api/api.nim`): LLM communication - each agent would have its own
- **Configuration** (`src/core/config.nim`): Model management - can support agent-specific configs

## Multi-Agent Implementation Strategy

### 1. Agent Routing Layer

**Extend CLI Interface**: Add agent nickname parsing to detect patterns like `@agent_name: prompt` in user input.

**Agent Registry**: Central registry of active agents with their communication endpoints, health status, and capabilities.

**Request Routing**: Intelligent routing system that:
- Parses agent nicknames from prompts
- Routes requests to appropriate agents
- Handles fallbacks if agents are unavailable
- Supports broadcast messages to multiple agents

### 2. Inter-Process Communication (IPC)

**Unix Domain Sockets**: Use for local agent communication (high performance, low latency)

**TCP Sockets**: For network-distributed agents running on different machines

**Message Protocol**: Extend existing `APIRequest`/`APIResponse` types for IPC:
```nim
type
  AgentRequest* = object
    agentId*: string
    requestId*: string
    prompt*: string
    context*: seq[Message]
    metadata*: Table[string, string]

  AgentResponse* = object
    agentId*: string
    requestId*: string
    content*: string
    status*: AgentStatus
    toolCalls*: Option[seq[ToolCall]]
```

**Agent Discovery**: Simple protocol for agents to register/announce themselves with capabilities and status.

### 3. Agent Architecture Options

#### Option A: Process-per-Agent (Recommended)

Each agent runs as a separate niffler process with:
- Unique configuration and model assignment
- Isolated conversation history and context
- Dedicated UI showing only their conversations
- Specialized tool permissions and capabilities

```bash
# Start agents
niffler --agent-mode --agent-name "code_expert" --model "claude-3.5-sonnet"
niffler --agent-mode --agent-name "bash_helper" --model "gpt-4o"
niffler --agent-mode --agent-name "researcher" --model "claude-3-haiku"

# Start master UI
niffler --master-mode
```

#### Option B: Thread-per-Agent

Extend current threading to support multiple agent threads within the same process:
- Shared process space but isolated contexts
- More complex state management
- Better resource usage but harder to isolate failures

### 4. Specific Implementation Components

#### New Modules

**Agent Communication** (`src/core/ipc.nim`):
```nim
type
  IPCChannel* = object
    socket*: Socket
    protocol*: IPCProtocol
    
  AgentEndpoint* = object
    id*: string
    name*: string
    capabilities*: seq[string]
    socketPath*: string
    lastSeen*: DateTime

proc connectToAgent*(endpoint: AgentEndpoint): IPCChannel
proc sendToAgent*(channel: IPCChannel, request: AgentRequest): bool
proc receiveFromAgent*(channel: IPCChannel): Option[AgentResponse]
```

**Agent Router** (`src/core/router.nim`):
```nim
type
  AgentRouter* = object
    agents*: Table[string, AgentEndpoint]
    channels*: Table[string, IPCChannel]

proc parseAgentNickname*(prompt: string): tuple[agent: string, cleanPrompt: string]
proc routeToAgent*(router: var AgentRouter, agentId: string, prompt: string): Future[AgentResponse]
proc broadcastToAgents*(router: var AgentRouter, prompt: string): seq[AgentResponse]
```

**Agent Manager** (`src/core/agents.nim`):
```nim
type
  Agent* = object
    id*: string
    name*: string
    model*: ModelConfig
    process*: Process
    status*: AgentStatus
    capabilities*: seq[string]

proc startAgent*(config: AgentConfig): Agent
proc stopAgent*(agent: var Agent)
proc healthCheck*(agent: Agent): bool
proc restartAgent*(agent: var Agent)
```

#### Extensions to Existing Modules

**CLI Interface** (`src/ui/cli.nim`):
- Add agent nickname parsing: `@agent_name: prompt`
- Display list of active agents with status indicators
- Show agent attribution in responses
- Add `/agents` command to list and manage agents

**Configuration** (`src/core/config.nim`):
```nim
type
  AgentConfig* = object
    id*: string
    name*: string
    model*: string
    capabilities*: seq[string]
    toolPermissions*: seq[string]
    socketPath*: string
    autoStart*: bool

  Config* = object
    # ... existing fields
    agents*: seq[AgentConfig]
    masterMode*: bool
    agentDiscovery*: DiscoveryConfig
```

**Message Types** (`src/types/messages.nim`):
```nim
type
  AgentMessageKind* = enum
    amkRequest, amkResponse, amkHeartbeat, amkShutdown
    
  AgentMessage* = object
    kind*: AgentMessageKind
    agentId*: string
    requestId*: string
    content*: string
    timestamp*: DateTime
```

### 5. Implementation Phases

#### Phase 1: Foundation
1. **IPC Communication Layer**
   - Unix domain socket implementation
   - Message serialization/deserialization using existing JSON patterns
   - Connection pooling and error handling
   - Basic agent discovery protocol

2. **Agent Process Mode**
   - New CLI flags: `--agent-mode --agent-name "specialist"`
   - Agent-specific UI showing only their conversations
   - Agent startup and registration with master

#### Phase 2: Routing and Communication
3. **Agent Registration System**
   - Agents announce themselves on startup
   - Central registry with health checking
   - Dynamic agent discovery and removal

4. **Master UI Extensions**
   - Parse `@agent_name:` prefix in prompts
   - Route requests to appropriate agents
   - Display agent responses with attribution
   - Add `/agents` command for management

#### Phase 3: Advanced Features
5. **Agent Specialization**
   - Tool permission systems per agent
   - Capability-based routing
   - Agent-specific prompt templates
   - Context sharing between agents

6. **Reliability and Monitoring**
   - Agent health monitoring
   - Automatic restart of failed agents
   - Load balancing for multiple agents of same type
   - Conversation persistence across agent restarts

### 6. Usage Examples

#### Basic Agent Communication
```bash
# In master UI:
@code_expert: Help me debug this Nim threading issue
@bash_helper: List all running processes on port 8080
@researcher: Find documentation for nim-noise library
```

#### Multi-Agent Collaboration
```bash
# Research + Implementation workflow:
@researcher: Find best practices for HTTP streaming in Nim
# (researcher responds with documentation)

@code_expert: Based on that research, help me implement HTTP streaming
# (code expert provides implementation)

@bash_helper: Test the HTTP streaming implementation
# (bash helper runs tests and reports results)
```

#### Agent Management
```bash
# In master UI:
/agents list                    # Show all active agents
/agents start researcher        # Start a specific agent
/agents stop bash_helper        # Stop an agent
/agents restart code_expert     # Restart an agent
/agents status                  # Show health status of all agents
```

### 7. Configuration Example

```toml
# ~/.config/niffler/config.toml

[master]
enabled = true
discovery_port = 8765
socket_dir = "/tmp/niffler"

[[agents]]
id = "code_expert"
name = "Code Expert"
model = "claude-3.5-sonnet"
capabilities = ["coding", "debugging", "architecture"]
tool_permissions = ["read", "edit", "create", "bash"]
auto_start = true

[[agents]]
id = "bash_helper"
name = "Bash Helper"
model = "gpt-4o"
capabilities = ["system", "commands", "troubleshooting"]
tool_permissions = ["bash", "read", "list"]
auto_start = true

[[agents]]
id = "researcher"
name = "Research Assistant"
model = "claude-3-haiku"
capabilities = ["research", "documentation", "analysis"]
tool_permissions = ["fetch", "read"]
auto_start = false
```

### 8. Technical Considerations

#### Nim-Specific Advantages
- **Memory Safety**: Nim's deterministic memory management ideal for long-running agent processes
- **Threading Model**: Current threading architecture easily extensible to IPC
- **Compilation**: Fast compilation enables quick agent deployment and updates
- **No GC Pause**: Deterministic cleanup important for real-time agent communication

#### Performance Considerations
- **Socket Pooling**: Reuse connections to avoid setup overhead
- **Message Batching**: Batch small requests to reduce IPC overhead
- **Context Caching**: Share common context between agents efficiently
- **Health Monitoring**: Lightweight heartbeat system to detect failed agents

#### Security Considerations
- **Process Isolation**: Each agent runs in separate process space
- **Tool Permissions**: Fine-grained control over what each agent can do
- **Socket Security**: Unix domain sockets with proper file permissions
- **Input Validation**: Sanitize all inter-agent communication

### 9. Migration Path

1. **Backward Compatibility**: All existing niffler functionality continues to work
2. **Gradual Adoption**: Users can start with single agents and expand
3. **Configuration Evolution**: Extend existing config format rather than replace
4. **UI Enhancement**: Master mode enhances rather than replaces current CLI

### 10. Future Extensions

#### Advanced Agent Capabilities
- **Agent Chains**: Automatically route complex tasks through multiple agents
- **Context Sharing**: Agents can share conversation context when needed
- **Learning**: Agents learn from each other's successful interactions
- **Specialization**: Agents can develop expertise in specific domains over time

#### Distributed Deployment
- **Network Agents**: Agents running on remote machines
- **Cloud Integration**: Agents running in cloud environments
- **Load Balancing**: Multiple instances of the same agent type
- **Failover**: Automatic failover to backup agents

This architecture leverages niffler's existing strengths while providing a powerful, flexible multi-agent framework that maintains the simplicity and reliability of the current design.