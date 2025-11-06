# MCP Server Support for Niffler

This document outlines the plan for adding MCP (Model Context Protocol) server support to Niffler, enabling AI-powered terminal assistance with extensible tool capabilities.

## Overview

MCP server support will allow Niffler to communicate with external MCP servers that provide additional tools and capabilities beyond the built-in tools. This enables repository-specific tooling, filesystem operations, git integration, and more.

## Architecture

### Current Architecture Foundation

Niffler already has a solid foundation for MCP integration:

- **Configuration System**: Global config at `~/.niffler/config.yaml` with `McpServerConfig` type already defined
- **Tool Registry**: Extensible system in `src/tools/registry.nim` supporting object variant-based tools
- **Thread-based Architecture**: Multi-threaded design with dedicated workers for API, tools, and UI
- **Channel Communication**: Thread-safe message passing between workers via `src/core/channels.nim`

### MCP Integration Architecture

The MCP integration will use a **separate MCP worker thread** approach for better isolation and scalability:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Main Thread   │    │   API Worker    │    │  Tool Worker    │
│   (UI / Coord)  │◄──►│ (LLM Comm)      │◄──►│ (Built-in Tools)│
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┤
                                 │                       │
                                 ▼                       ▼
                            ┌─────────────────┐    ┌─────────────────┐
                            │   MCP Worker    │    │   MCP Servers   │
                            │ (Protocol Mgmt) │◄──►│ (External Tools)│
                            └─────────────────┘    └─────────────────┘
```

## Configuration System

### Enhanced MCP Server Configuration

The existing `McpServerConfig` type will be enhanced:

```nim
McpServerConfig* = object
  command*: string                    # Command to start the server
  args*: Option[seq[string]]         # Command arguments
  env*: Option[Table[string, string]] # Environment variables
  workingDir*: Option[string]        # Working directory
  timeout*: Option[int]             # Timeout in seconds
  enabled*: bool                    # Enable/disable specific servers
  name*: string                     # Human-readable name
```

### Repository-Specific Configuration

**Multi-layered Configuration Priority:**
1. Repository-local `.niffler/config.yaml` (highest priority)
2. User global `~/.niffler/config.yaml` (fallback)
3. Built-in defaults (lowest priority)

**Repository Structure:**
```
.git/
.niffler/
├── config.yaml          # Repository-specific MCP servers and overrides
├── tools/              # Repository-specific tools (optional)
│   └── custom_tools.nim
└── prompts/            # Repository-specific system prompts (optional)
    ├── REPO.md
    └── PROJECT.md
```

**Configuration Merge Logic:**
- Repository config completely overrides global `mcpServers` section
- Other sections (models, themes, etc.) merge with repository taking precedence
- Repository config can disable global servers by setting `enabled: false`

### Example Repository Configuration

```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem"]
    workingDir: "/Users/gokr/projects"
    enabled: true
    name: "Filesystem Access"

  git:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-git"]
    workingDir: "."
    env:
      GIT_REPO_PATH: "."
    enabled: true
    name: "Git Operations"
```

### Repository Configuration Discovery

Configuration discovery works by:
1. Starting at current working directory
2. Traversing up until finding `.git/` (repo root) or filesystem root
3. Looking for `.niffler/config.yaml` at detected repo root
4. Merging with global configuration using priority rules

## Implementation Plan

### Phase 1: Core MCP Infrastructure

**1. MCP Communication Protocol (`src/mcp/protocol.nim`)**
- Implement JSON-RPC 2.0 client for MCP
- Add MCP message types (initialize, call_tool, list_tools, etc.)
- Create MCP client with connection management

**2. MCP Worker Thread (`src/mcp/mcp.nim`)**
- New worker thread dedicated to MCP server communication
- Channel-based communication with main thread
- Connection pooling for multiple MCP servers
- Error handling and reconnection logic

**3. MCP Tool Integration (`src/mcp/tools.nim`)**
- Bridge between MCP tools and Niffler tool registry
- Dynamic tool discovery from MCP servers
- Tool schema conversion (MCP ↔ OpenAI format)
- Execution proxy for MCP tool calls

### Phase 2: Configuration System Enhancement

**1. Enhanced Config Types (`src/types/config.nim`)**
- Expand `McpServerConfig` with new fields
- Add repository configuration tracking
- Configuration merging logic

**2. Configuration Loading (`src/core/config.nim`)**
- Repository detection and config loading
- Configuration merging with priority
- Default repository config creation

**3. MCP Server Management (`src/mcp/manager.nim`)**
- Server lifecycle management (start/stop/restart)
- Health monitoring and automatic restart
- Resource cleanup and shutdown handling

### Phase 3: UI and Integration

**1. Tool Registry Updates (`src/tools/registry.nim`)**
- Add MCP tools to registry
- Dynamic tool registration
- Tool availability reporting

**2. MCP Commands (`src/niffler.nim`)**
- CLI commands for MCP management:
  - `niffler mcp list` - List configured servers
  - `niffler mcp start <server>` - Start specific server
  - `niffler mcp stop <server>` - Stop specific server
  - `niffler mcp status` - Show server status

**3. UI Integration (`src/ui/cli.nim`)**
- Show MCP server status in UI
- Handle MCP tool calls transparently
- MCP-specific error messages and feedback

### Phase 4: Advanced Features

**1. Repository-Specific Features**
- Per-repository MCP server configurations
- Automatic MCP server discovery in `.niffler/` directory
- Git-aware configuration context

**2. Security and Sandboxing**
- MCP server sandboxing
- Path access restrictions
- Resource usage limits

**3. Performance Optimization**
- Connection pooling and reuse
- Tool result caching
- Parallel MCP server communication

## MCP Protocol Implementation

### Message Types

```nim
# Core MCP message types
type
  McpRequestKind* = enum
    mcrkInitialize, mcrkListTools, mcrkCallTool, mcrkShutdown

  McpResponseKind* = enum
    mcrrkSuccess, mcrrkError, mcrrkToolResult

  McpRequest* = object
    jsonrpc*: string  # Always "2.0"
    id*: string
    method*: string
    params*: JsonNode

  McpResponse* = object
    jsonrpc*: string  # Always "2.0"
    id*: string
    result*: Option[JsonNode]
    error*: Option[McpError]
```

### Tool Schema Conversion

MCP tools need to be converted to OpenAI-compatible format:

```nim
proc convertMcpToolToOpenai*(mcpTool: McpTool): ToolDefinition =
  # Convert MCP tool schema to OpenAI function calling format
  # Handle input/output schema differences
  # Map tool names and descriptions appropriately
```

## Security Considerations

### MCP Server Sandboxing
- Run MCP servers with restricted permissions
- Limit filesystem access to specific directories
- Control network access for external MCP servers

### Path Access Controls
- Validate all file paths passed to MCP servers
- Restrict MCP server access to project directories
- Prevent access to sensitive system files

### Resource Limits
- Implement timeouts for MCP tool execution
- Limit memory usage per MCP server
- Control concurrent MCP server connections

## Performance Considerations

### Connection Management
- Use connection pooling for MCP server connections
- Implement keep-alive mechanisms
- Handle connection failures gracefully

### Tool Result Caching
- Cache results from MCP tools where appropriate
- Implement cache invalidation strategies
- Respect MCP server caching headers

### Parallel Execution
- Support concurrent MCP tool execution
- Load balance across multiple MCP servers
- Prioritize critical tools

## Error Handling

### MCP Server Errors
- Graceful handling of MCP server crashes
- Automatic restart mechanisms
- Fallback to built-in tools when MCP unavailable

### Tool Execution Errors
- Clear error messages for MCP tool failures
- Retry mechanisms for transient failures
- Error reporting to users with actionable information

## Integration Points

### With Existing Tool System
- MCP tools appear alongside built-in tools
- Same confirmation mechanism for "dangerous" operations
- Consistent tool result formatting

### With Configuration System
- Seamless integration with existing config loading
- Repository-specific configuration merging
- Environment variable support

### With UI System
- Transparent MCP tool execution
- Status indicators for MCP servers
- MCP-specific error display

## Testing Strategy

### Unit Tests
- MCP protocol message handling
- Tool schema conversion
- Configuration merging logic

### Integration Tests
- MCP server communication
- Tool execution flow
- Multi-threaded coordination

### End-to-End Tests
- Complete MCP workflow
- Repository configuration scenarios
- Error recovery scenarios

## Rollout Plan

### Alpha Release
- Core MCP infrastructure
- Basic MCP server support
- Repository configuration detection

### Beta Release
- Advanced configuration options
- Performance optimizations
- Security hardening

### Stable Release
- Complete feature set
- Comprehensive testing
- Documentation completion

## Future Extensions

### Dynamic MCP Server Discovery
- Automatic detection of MCP servers in node_modules
- Configuration file parsing for MCP server definitions
- Plugin system for MCP server management

### MCP Tool Composition
- Compose multiple MCP tools into higher-level tools
- Tool chaining and pipelining
- Result transformation and filtering

### Advanced Features
- MCP server monitoring and metrics
- Tool usage analytics
- Intelligent MCP server selection

## Conclusion

This plan provides a comprehensive approach to adding MCP server support to Niffler while maintaining the existing architecture's strengths. The repository-specific configuration system enables powerful, context-aware tool capabilities that can be tailored to individual project needs.

The implementation follows Niffler's established patterns for threading, configuration, and tool management, ensuring a clean integration that enhances rather than disrupts the existing system.