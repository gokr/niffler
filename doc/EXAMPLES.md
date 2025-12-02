# Niffler Usage Examples

This document provides detailed examples and usage patterns for Niffler's features. For installation and basic setup, see the [main README](../README.md).

## Table of Contents

- [Multi-Agent System](#multi-agent-system)
- [Plan/Code Mode System](#plancode-mode-system)
- [Thinking Token Support](#thinking-token-support)
- [Plan Mode File Protection](#plan-mode-file-protection)
- [Enhanced Terminal Features](#enhanced-terminal-features)
- [Archive and Unarchive Commands](#archive-and-unarchive-commands)
- [Configuration Management](#configuration-management)
- [NIFFLER.md System Prompt Customization](#nifflermd-system-prompt-customization)
- [Debugging API Issues](#debugging-api-issues)

## Multi-Agent System

Niffler's distributed multi-agent architecture allows specialized agents to collaborate via NATS messaging in a chat room model.

### Basic Multi-Agent Workflow

**Start your agents (Terminal 1):**
```bash
# Start multiple specialized agents
./src/niffler agent coder
./src/niffler agent researcher

# Agent terminals will display:
# [AGENT] coder listening on niffler.agent.coder.request
# [AGENT] researcher listening on niffler.agent.researcher.request
```

**Use the master CLI (Terminal 2):**
```bash
# Start master
./src/niffler

# Check which agents are available
> /agents
# Output:
# Active Agents:
#   ✅ @coder (online for 2m15s)
#   ✅ @researcher (online for 2m10s)

# Route work to agents using @ syntax
> @coder /task "Create a REST API for user management"

# Have a conversation with an agent
> @researcher "What are the best authentication methods for web APIs?"
```

### Task vs Ask Model

**Task Model** (`/task`) - Isolated execution:
```bash
# Creates fresh context, no conversation history
> @coder /task "Create unit tests for the auth module"

# Agent will:
# 1. Create fresh conversation context
# 2. Execute the task with tools
# 3. Return result and summary
# 4. Restore previous context
```

**Ask Model** (default) - Conversation continuation:
```bash
# Continues existing conversation context
> @coder "Refactor the database queries we discussed earlier"

# Agent will:
# 1. Load previous conversation history
# 2. Continue the discussion
# 3. Maintain context across multiple messages
```

### Collaborative Agent Work

**Research + Implementation pattern:**
```bash
# Step 1: Research options
> @researcher /task "Research 3 JavaScript testing frameworks and compare them"

# Step 2: Implement based on research
> @coder /task "Set up the recommended testing framework from @researcher's findings"
```

**Debugging workflow:**
```bash
# Step 1: Investigate issue
> @coder "Why is the API returning 500 errors?"

# Step 2: Get research help
> @researcher "What are common causes of 500 errors in this framework?"

# Step 3: Fix the issue
> @coder "Apply the fix based on the research findings"
```

### Agent Configuration

**Auto-start agents on master launch:**
```yaml
# ~/.niffler/config.yaml
masters:
  enabled: true
  auto_start_agents: true
  default_agent: "coder"

agents:
  - id: "coder"
    name: "Coder Agent"
    auto_start: true
    persistent: true
    model: "claude-sonnet"
    capabilities: ["coding", "debugging", "architecture"]
    tool_permissions: ["read", "edit", "create", "bash", "list", "fetch"]

  - id: "researcher"
    name: "Research Agent"
    auto_start: true
    persistent: false
    model: "haiku"
    capabilities: ["research", "analysis"]
    tool_permissions: ["read", "list", "fetch"]
```

### Single-Prompt Agent Routing

**Fire-and-forget tasks:**
```bash
# Route to agent and exit immediately
./src/niffler --prompt="@coder /task Create a README for this project"

# Output appears in the agent's terminal, not the calling terminal
```

**Script-friendly usage:**
```bash
#!/bin/bash
# batch_tasks.sh

# Send multiple tasks to different agents
./src/niffler --prompt="@coder /task Lint all source files"
sleep 1
./src/niffler --prompt="@researcher /task Find latest version of all dependencies"
sleep 1
./src/niffler --prompt="@coder /task Update dependencies to latest versions"
```

### Agent Management

**List active agents:**
```bash
> /agents

# Output:
# Active Agents:
#   ✅ @coder (online, idle)
#   ✅ @researcher (online, busy - Task in progress)
#   ⏸ @tester (paused)
```

**Check agent status in real-time:**
```bash
# Status updates published to niffler.master.status
# Agents show: [REQUEST], [WORKING], [COMPLETED] states
```

### Best Practices

1. **Use named agents for specialization:**
   - `@coder` for implementation tasks
   - `@researcher` for investigation and analysis
   - `@tester` for testing and QA

2. **Use `/task` for one-off operations:**
   - Fresh context prevents history pollution
   - Isolated from conversation history
   - Returns clear summary and artifacts

3. **Use conversation (Ask) for refinement:**
   - Multi-turn problem solving
   - Building on previous context
   - Iterative development

4. **Monitor agent output:**
   - Each agent displays work in its own terminal
   - Real-time streaming of responses
   - Tool execution visible for debugging

**Learn more:** See [doc/TASK.md](doc/TASK.md) for complete multi-agent architecture documentation and [doc/DEVELOPMENT.md](doc/DEVELOPMENT.md) for implementation details.

## Plan/Code Mode System

Niffler features an intelligent mode system that adapts its behavior based on the current task. Learn more about the system prompts in [CONFIG.md](CONFIG.md#niffler.md-files).

### Mode Switching

- **Shift+Tab**: Toggle between Plan and Code modes
- **Visual Indicators**: Mode displayed in prompt with color coding (green for plan, blue for code)
- **Dynamic Prompts**: Each mode has specialized system prompts for optimal AI behavior

### Plan Mode

- Focus on analysis, research, and task breakdown
- Emphasizes understanding requirements before implementation
- Encourages thorough exploration of codebases and documentation
- **File Protection**: Automatically prevents editing files that existed before entering plan mode to maintain separation between planning and implementation phases

**Usage:**
```bash
# Toggle to plan mode with Shift+Tab, then:
niffler
# [Shift+Tab]
# > Analyze the codebase structure and identify performance bottlenecks
```

### Code Mode

- Focus on implementation and execution
- Emphasizes making concrete changes and testing
- Optimized for completing established plans and fixing issues
- **Full File Access**: Allows editing all files for active development and implementation

**Usage:**
```bash
# Toggle to code mode with Shift+Tab, then:
niffler
# [Shift+Tab]
# > Implement the performance optimizations we planned
```

### Advanced Mode Features

**Switching modes in single prompt:**
```bash
# Use /plan or /code commands in prompt
niffler --prompt="/plan Analyze the database module"
niffler --prompt="/code Optimize the database queries"
```

**Mode persistence:**
- Mode is stored per conversation
- Resuming a conversation restores the previous mode
- Visual indicator in prompt shows current mode

## Thinking Token Support

Niffler includes cutting-edge support for **thinking tokens** (reasoning tokens) from next-generation AI models. These models can show their internal reasoning process, which Niffler automatically captures, stores, and integrates into conversations.

### Supported Models

- **GPT-5** and future OpenAI reasoning models (native `reasoning_content` field)
- **Claude 4** and Anthropic reasoning models (XML `<thinking>` blocks)
- **DeepSeek R1** and similar reasoning-capable models
- **Privacy models** with encrypted/redacted reasoning content

### Key Features

- **Real-time Reasoning Capture**: Automatically detects and stores thinking content during streaming responses
- **Multi-provider Support**: Handles different reasoning formats transparently
- **Conversation Persistence**: Thinking tokens are stored in the database and linked to conversation history
- **Cost Tracking**: Reasoning tokens are tracked separately and included in usage/cost calculations
- **Enhanced Problem Solving**: See exactly how the AI reaches its conclusions

### Configuration Example

```yaml
# ~/.niffler/config.yaml
models:
  - nickname: "gpt5-reasoning"
    baseUrl: "https://api.openai.com/v1"
    model: "gpt5-turbo"
    reasoning: "high"
    reasoningContent: "visible"
    reasoningCostPerMToken: 10.0
    enabled: true

thinkingTokensEnabled: true
defaultReasoningLevel: "medium"
```

**Reasoning Levels:**
- `low`: 2048 tokens (light reasoning)
- `medium`: 4096 tokens (balanced reasoning)
- `high`: 8196 tokens (deep reasoning)
- `none`: No reasoning tokens

**Reasoning Content Visibility:**
- `visible`: Show reasoning to user (default)
- `hidden`: Hide reasoning but store in database
- `encrypted`: Encrypt reasoning for privacy

### Benefits

- **Self-Correcting AI**: Models can catch and fix their own reasoning errors
- **Transparency**: Users see exactly how conclusions are reached
- **Better First Responses**: Reduced trial-and-error through deliberate reasoning
- **Multi-Turn Intelligence**: Preserved reasoning context across conversation turns

For detailed implementation information, see [THINK.md](THINK.md).

## Plan Mode File Protection

Niffler implements intelligent file protection to maintain clear separation between planning and implementation phases.

### How It Works

- When entering **Plan Mode**, Niffler initializes an empty "created files" list for the conversation
- As new files are created during the Plan Mode session, they are automatically tracked in this list
- The AI assistant can **only edit files that were created during the current Plan Mode session**
- Existing files (that existed before Plan Mode) are protected from editing to prevent accidental changes during planning
- When switching to **Code Mode**, file tracking is cleared and all file editing restrictions are removed

### When Protection is Activated

- **Manual Mode Toggle**: Pressing `Shift+Tab` to enter Plan Mode
- **Conversation Loading**: When loading a conversation that's already in Plan Mode
- **Application Startup**: If the last active conversation was in Plan Mode
- **Conversation Switching**: Using `/conv` command to switch to a Plan Mode conversation

### File Creation Tracking

- **Automatic Detection**: Files created via the `create` tool are automatically added to the created files list
- **Persistent Tracking**: Created file lists are stored per conversation in the database
- **Path Normalization**: Uses relative paths for portability across different working directories
- **Session Scope**: Each Plan Mode session maintains its own created files list

### User Experience

- **Transparent Operation**: File creation tracking happens automatically without user intervention
- **Clear Error Messages**: Informative messages when attempting to edit protected files:

```
Cannot edit existing files in plan mode. Only files created during this plan mode session can be edited.
Switch to code mode to edit existing files, or create new files which can then be edited.
```

- **Visual Indicators**: Mode displayed in prompt with color coding (green for plan, blue for code)
- **Seamless Transitions**: Automatic tracking management during mode switches
- **New File Creation**: Full ability to create and subsequently edit new files during planning

### Database Integration

- **Persistent State**: Created file lists are stored in the conversation database and survive application restarts
- **Efficient Storage**: File lists are stored as compact JSON arrays in the database
- **Automatic Cleanup**: Created file tracking is cleared when exiting Plan Mode
- **Cross-Session Consistency**: File creation tracking works correctly when resuming conversations across different sessions

### Technical Implementation

- File protection is checked at tool execution time, not file system level
- Uses thread-safe database operations for created file list management
- Implements "fail-open" error handling - allows operations if database is unavailable
- Integrates with Niffler's conversation management and mode switching system
- Files created during Plan Mode are automatically tracked by the `create` tool

## Enhanced Terminal Features

### Cursor Key Support

- **←/→ Arrow Keys**: Navigate within your input line for editing
- **↑/↓ Arrow Keys**: Navigate through command history (persisted across sessions)
- **Home/End**: Jump to beginning/end of current line
- **Ctrl+C**: Graceful exit
- **Ctrl+Z**: Suspend to background (Unix/Linux/macOS)
- **Shift+Tab**: Toggle between Plan and Code modes

### Visual Enhancements

- **Colored Prompts**: Username appears in blue and cannot be backspaced over
- **Mode Indicators**: Current mode (plan/code) with color coding in prompt
- **History Persistence**: Your conversation history is saved to a TiDB database and restored between sessions
- **Cross-Platform**: Works consistently on Windows, Linux, and macOS

### Database Integration

All conversations are automatically saved to a TiDB database. See [CONFIG.md#database-setup-tidb](CONFIG.md#database-setup-tidb) for configuration details.

## Archive and Unarchive Commands

Niffler provides conversation archiving functionality to help you organize your conversations while preserving them for future reference. Archived conversations are hidden from the main conversation list but can be restored when needed.

### `/archive` Command

Archive a conversation to remove it from the active conversation list:

```bash
# Archive a conversation by ID
/archive 123

# Archive multiple conversations
/archive 456
/archive 789
```

**Features:**
- **Soft Delete**: Archived conversations are preserved in the database but marked as inactive
- **Tab Completion**: Press Tab after `/archive` to see a formatted table of active conversations
- **Immediate Effect**: Archived conversations disappear from `/conv` list immediately
- **Data Preservation**: All messages, tokens, and metadata are retained

**Use Cases:**
- Clean up your conversation list while keeping important discussions
- Archive completed projects or resolved issues
- Organize conversations by project status (active vs. completed)

### `/unarchive` Command

Restore an archived conversation back to the active list:

```bash
# Unarchive a conversation by ID
/unarchive 123

# Unarchive multiple conversations
/unarchive 456
/unarchive 789
```

**Features:**
- **Full Restoration**: Restores conversations with all original messages and metadata
- **Tab Completion**: Press Tab after `/unarchive` to see a formatted table of archived conversations
- **Seamless Integration**: Restored conversations appear immediately in `/conv` list
- **Context Preservation**: Original mode, model, and conversation settings are maintained

**Use Cases:**
- Revisiting past projects or decisions
- Referencing old solutions or approaches
- Continuing paused conversations
- Researching historical context

### Archive Management Workflow

**1. Viewing Conversations:**
```bash
# List only active conversations (default)
/conv

# List all conversations including archived (via search)
/search "your query"
```

**2. Archiving Process:**
```bash
# See active conversations
/conv

# Archive completed conversation
/archive 42

# Verify it's archived
/conv  # Should no longer show conversation 42
```

**3. Unarchiving Process:**
```bash
# Find archived conversations
/unarchive  # Press Tab to see archived list

# Restore conversation
/unarchive 42

# Verify it's active
/conv  # Should now show conversation 42
```

**4. Search Integration:**
The `/search` command includes both active and archived conversations, making it easy to find content regardless of archive status:

```bash
# Search across all conversations
/search "project planning"
# Results show both active and archived matches
```

### Database Integration

Archived conversations are managed through Niffler's TiDB database system:

- **Data Structure**: Uses `is_active` boolean field in `conversation` table
- **Performance**: Lightweight boolean toggle operation
- **Persistence**: Archive status survives application restarts and is stored in TiDB

### Best Practices

**When to Archive:**
- Completed projects or tasks
- Resolved issues or debugging sessions
- Old reference conversations you might need later
- Conversations you want to keep but don't need active access to

**When to Unarchive:**
- Revisiting past projects or decisions
- Referencing old solutions or approaches
- Continuing paused conversations
- Researching historical context

**Archive Management Tips:**
- Use descriptive conversation titles to easily identify them later
- Archive conversations in batches when cleaning up
- Use `/search` to find specific content in archived conversations
- Consider archiving rather than deleting to preserve valuable context

## Configuration Management

### Initialize Configuration

```bash
# Initialize with default settings
niffler init

# Initialize with custom path
niffler init /path/to/config

# Check current config location
cat ~/.niffler/config.yaml
```

### Configuration Files

**Linux/macOS:**
- Default: `~/.niffler/config.yaml`
- Directory: `~/.niffler/` (hidden directory)
- Instructions: `~/.niffler/NIFFLER.md`

**Windows:**
- Default: `%APPDATA%\niffler\config.yaml`
- Directory: `%APPDATA%\niffler\`
- Instructions: `%APPDATA%\niffler\NIFFLER.md`

### Runtime Configuration

```bash
# Switch configuration styles (in-memory only)
/config              # List available configs
/config cc           # Switch to Claude Code style
/config default      # Switch back to default
```

**Note:** `/config` does NOT modify any config.yaml files. It only changes the active config for the current session.

See [CONFIG.md](CONFIG.md) for comprehensive configuration documentation.

## NIFFLER.md System Prompt Customization

Niffler supports advanced customization through NIFFLER.md files that can contain both system prompts and project instructions.

### Supported Sections

NIFFLER.md recognizes these special sections:

- **`# Common System Prompt`** - Base system prompt used for all modes
- **`# Plan Mode Prompt`** - Additional instructions for Plan mode
- **`# Code Mode Prompt`** - Additional instructions for Code mode
- **`# Tool Descriptions`** - Custom tool descriptions (future feature)

Other sections (e.g., `# Project Guidelines`) are included as instruction content but not used as system prompts.

### Variable Substitution

System prompts support these template variables:

- `{availableTools}` - List of available tools
- `{currentDir}` - Current working directory
- `{currentTime}` - Current timestamp
- `{osInfo}` - Operating system information
- `{gitInfo}` - Git repository information
- `{projectInfo}` - Project context information

### Example NIFFLER.md

```markdown
# Common System Prompt

You are Niffler, a specialized assistant for this project.
Available tools: {availableTools}
Working in: {currentDir}

# Plan Mode Prompt

In plan mode, focus on:
- Analyzing requirements
- Breaking down tasks
- Research and planning

# Code Mode Prompt

In code mode, focus on:
- Implementation
- Testing
- Bug fixes

# Project Guidelines

These guidelines will appear in instruction files, not system prompts.
```

### File Inclusion

Include other files using the `@include` directive:

```markdown
# Common System Prompt

Base prompt content here.

@include shared-guidelines.md

# Project Instructions

@include CLAUDE.md
@include docs/coding-standards.md
```

**Features:**
- **Relative paths** - Resolved relative to the NIFFLER.md file location
- **Absolute paths** - Used as-is
- **Error handling** - Missing files shown as comments in output
- **Recursive processing** - Included files can have their own `@include` directives

### Project-Specific Overrides

Place a `.niffler/config.yaml` file in your project to select a specific config:

```yaml
# .niffler/config.yaml
config: "cc"  # Use Claude Code style for this project
```

Create a `NIFFLER.md` in your project directory for project-specific instructions:

```bash
# In your project directory
cat > NIFFLER.md << 'EOF'
# Project Guidelines

This project uses:
- Python 3.11+
- PostgreSQL 14+
- Django 4.2+

# Additional Instructions

Always use type hints and follow PEP 8.
EOF
```

For comprehensive NIFFLER.md documentation, see [CONFIG.md](CONFIG.md#niffler.md-files).

## Debugging API Issues

The `--dump` flag provides complete HTTP request and response logging for debugging API communication:

```bash
# Basic usage with dump
niffler -p "Hello" --dump

# Combine with debug for maximum visibility
niffler -p "Debug this" --debug --dump
```

**What `--dump` shows:**
- Complete request headers (Authorization masked for security)
- Full JSON request body with tools, messages, and parameters
- Real-time streaming response with individual SSE chunks
- Token usage information in final response chunk

**Use cases:**
- Debugging API connectivity issues
- Understanding request formatting
- Monitoring token usage patterns
- Verifying streaming response handling
- Troubleshooting model-specific issues

**Example debugging session:**
```bash
# Terminal 1: Start Niffler with dump for visibility
niffler --dump

# In Niffler prompt, try your command
> /model gpt4 explain quantum computing

# Terminal 1 shows:
# [DUMP] Request URL: https://api.openai.com/v1/chat/completions
# [DUMP] Request body: {...}
# [DUMP] Response: {...}
```

See [TOKEN_COUNTING.md](TOKEN_COUNTING.md) for token usage debugging.

---

**Additional Resources:**
- [Configuration Guide](CONFIG.md) - Detailed configuration documentation
- [Tool System](TOOLS.md) - Complete tool system documentation
- [Model Setup](MODELS.md) - AI provider configuration

**Last Updated:** 2025-12-02
