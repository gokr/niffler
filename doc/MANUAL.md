# Niffler User Manual

**Niffler** is an AI-powered terminal assistant written in Nim that provides a conversational interface to interact with AI models while supporting tool calling for file operations, command execution, and web fetching.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Configuration](#configuration)
3. [Models & AI Providers](#models--ai-providers)
4. [Using Niffler](#using-niffler)
5. [Multi-Agent System](#multi-agent-system)
6. [Tools](#tools)
7. [MCP Integration](#mcp-integration)
8. [Plan & Code Modes](#plan--code-modes)
9. [Thinking Tokens](#thinking-tokens)
10. [Cost Tracking](#cost-tracking)
11. [Command Reference](#command-reference)
12. [Troubleshooting](#troubleshooting)

---

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/niffler.git
cd niffler

# Install dependencies
nimble install -y

# Build
nimble build
```

### Initialize Configuration

```bash
# Create default configuration
./src/niffler init

# This creates:
# - ~/.niffler/config.yaml - Main configuration
# - ~/.niffler/default/ - Default prompts
# - ~/.niffler/cc/ - Claude Code style prompts
```

### Set Up Database (TiDB)

```bash
# Run TiDB with Docker
docker run -d --name tidb -p 4000:4000 pingcap/tidb:latest

# Create database
mysql -h 127.0.0.1 -P 4000 -u root -e "CREATE DATABASE niffler;"
```

### Configure Your First Model

Edit `~/.niffler/config.yaml`:

```yaml
models:
  - nickname: "sonnet"
    base_url: "https://api.anthropic.com/v1"
    api_key_env: "ANTHROPIC_API_KEY"
    model: "claude-sonnet-4-5-20250929"
    context: 200000
    inputCostPerMToken: 3000
    outputCostPerMToken: 15000
```

Set your API key:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Start Using Niffler

```bash
# Interactive mode
./src/niffler

# Single prompt
./src/niffler -p "Hello, world!"

# With specific model
./src/niffler --model sonnet
```

---

## Configuration

### Configuration Files

| File | Purpose |
|------|---------|
| `~/.niffler/config.yaml` | Main configuration (models, database, MCP) |
| `~/.niffler/<config>/NIFFLER.md` | System prompts |
| `~/.niffler/<config>/agents/` | Agent definitions |
| `.niffler/config.yaml` | Project-level config override |

### Config Selection

Niffler uses a layered config resolution:

1. **Project-level**: `.niffler/config.yaml` in current directory
2. **User-level**: `~/.niffler/config.yaml`
3. **Default fallback**: `"default"`

Switch configs at runtime:
```
/config              # List available configs
/config cc           # Switch to Claude Code style
/config default      # Switch back to default
```

### NIFFLER.md Files

NIFFLER.md files contain system prompts with special sections:

- `# Common System Prompt` - Base prompt for all modes
- `# Plan Mode Prompt` - Additional instructions for Plan mode
- `# Code Mode Prompt` - Additional instructions for Code mode

**Variable Substitution:**
- `{availableTools}` - List of available tools
- `{currentDir}` - Working directory
- `{currentTime}` - Current timestamp
- `{osInfo}` - Operating system info
- `{gitInfo}` - Git repository info

**Example NIFFLER.md:**
```markdown
# Common System Prompt

You are Niffler, a helpful AI assistant.
Available tools: {availableTools}
Working in: {currentDir}

# Plan Mode Prompt

Focus on analysis and planning before implementation.

# Code Mode Prompt

Focus on implementation and execution.
```

### File Inclusion

Include other files using `@include`:
```markdown
# Common System Prompt

@include shared-guidelines.md

# Project Instructions

@include CLAUDE.md
```

---

## Models & AI Providers

### Supported Providers

Niffler supports any OpenAI-compatible API:

#### Anthropic Claude
```yaml
nickname: "sonnet"
base_url: "https://api.anthropic.com/v1"
api_key_env: "ANTHROPIC_API_KEY"
model: "claude-sonnet-4-5-20250929"
context: 200000
inputCostPerMToken: 3000
outputCostPerMToken: 15000
```

#### OpenAI
```yaml
nickname: "gpt4o"
base_url: "https://api.openai.com/v1"
api_key_env: "OPENAI_API_KEY"
model: "gpt-4o"
context: 128000
inputCostPerMToken: 250
outputCostPerMToken: 1000
```

#### OpenRouter
```yaml
nickname: "deepseek"
base_url: "https://openrouter.ai/api/v1"
api_key_env: "OPENROUTER_API_KEY"
model: "deepseek/deepseek-chat"
context: 64000
```

#### Local Models (Ollama)
```yaml
nickname: "local"
base_url: "http://localhost:11434/v1"
api_key_env: "OLLAMA_API_KEY"
model: "llama3.3:70b"
context: 128000
inputCostPerMToken: 0
outputCostPerMToken: 0
```

### Model Fields

| Field | Required | Description |
|-------|----------|-------------|
| `nickname` | Yes | Short name for selection |
| `base_url` | Yes | API endpoint |
| `api_key_env` | Yes | Environment variable for API key |
| `model` | Yes | Full model identifier |
| `context` | No | Context window size (default: 128000) |
| `inputCostPerMToken` | No | Cost per million input tokens (cents) |
| `outputCostPerMToken` | No | Cost per million output tokens (cents) |

### Switching Models

```
/model              # List available models
/model sonnet       # Switch to sonnet
/model haiku        # Switch to haiku
```

---

## Using Niffler

### Basic Usage

```bash
# Interactive mode
./src/niffler

# Single prompt (non-interactive)
./src/niffler -p "Explain quantum computing"

# Specify model
./src/niffler --model sonnet

# Enable debug logging
./src/niffler --loglevel=DEBUG

# Dump HTTP requests/responses
./src/niffler --dump
```

### Terminal Features

- **←/→ Arrow Keys**: Navigate within input line
- **↑/↓ Arrow Keys**: Command history
- **Home/End**: Jump to start/end of line
- **Ctrl+C**: Cancel current LLM stream or exit
- **Colored prompts** with mode indicators
- **Persistent history** across sessions

Note: Ctrl+C cancels local LLM streaming. Agent requests via NATS cannot currently be canceled mid-flight.

### Conversation Management

```
/conv               # List conversations
/conv 42            # Switch to conversation 42
/new                # Start new conversation
/clear              # Clear current conversation
/rename "New Name"  # Rename conversation

/archive 42         # Archive conversation
/unarchive 42       # Restore archived conversation
```

### Database Integration

All conversations are saved to TiDB automatically:

```bash
# View conversations
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT id, title, created_at FROM conversation ORDER BY created_at DESC LIMIT 10"

# View messages
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT role, content FROM conversation_message WHERE conversation_id = 1"
```

---

## Multi-Agent System

Niffler supports distributed multi-agent architecture where specialized agents run as separate processes and collaborate via NATS messaging.

### Architecture

```
Master Process (./src/niffler)
    |
    | NATS Message Bus
    |
    ├─→ Agent: coder
    ├─→ Agent: researcher
    └─→ Agent: tester
```

### Starting Agents

**Terminal 1 - Start Agents:**
```bash
# Start specialized agents
./src/niffler agent coder
./src/niffler agent researcher
```

**Terminal 2 - Master CLI:**
```bash
# Start master
./src/niffler

# Check available agents
> /agents

# Route work to agents
> @coder /task "Create a REST API"
> @researcher "Research authentication methods"
```

### Task vs Ask Model

**Task** (`@agent /task prompt`) - Isolated execution:
- Creates fresh context
- No conversation history
- Returns result and summary
- Example: `@coder /task "Create unit tests"`

**Ask** (`@agent prompt`) - Conversation continuation:
- Continues existing context
- Multi-turn collaboration
- Builds on previous interactions
- Example: `@coder "Refactor the code"`

### Agent Configuration

Agents are defined via markdown files in `~/.niffler/<config>/agents/`:

```markdown
# Coder Agent

## Description
Specialized in code analysis and implementation.

## Model
sonnet

## Allowed Tools
- read
- edit
- create
- bash
- list

## System Prompt

You are a coding expert. Available tools: {availableTools}
```

Required sections:
- `## Description` - Agent purpose
- `## Allowed Tools` - Whitelist of tools
- `## System Prompt` - LLM instructions

Optional sections:
- `## Model` - Override default model

**YAML vs Markdown Agents:**

The `agents` section in `config.yaml` controls process behavior (auto-start, persistence).
The markdown files under `agents/*.md` define runtime behavior (prompts, tool permissions).
If both exist, markdown files are the source of truth for agent behavior.

### Managing Agents

```
/agents              # List all agents
/agent coder         # Show agent details
```

---

## Tools

Niffler provides built-in tools for AI-assisted development:

### Core Tools

#### bash
Execute shell commands with timeout control.

```json
{
  "name": "bash",
  "arguments": {
    "command": "ls -la src/",
    "timeout": 5000,
    "workingDir": "/path"
  }
}
```

#### read
Read file contents with size limits and line ranges.

```json
{
  "name": "read",
  "arguments": {
    "path": "src/main.py",
    "startLine": 1,
    "endLine": 50
  }
}
```

#### list
List directory contents with filtering.

```json
{
  "name": "list",
  "arguments": {
    "path": "src/",
    "recursive": true,
    "filter": "*.nim"
  }
}
```

#### edit
Edit files with diff-based operations.

```json
{
  "name": "edit",
  "arguments": {
    "path": "config.py",
    "operation": "replace",
    "oldText": "DEBUG = False",
    "newText": "DEBUG = True"
  }
}
```

Operations: `replace`, `insert`, `delete`, `append`, `prepend`, `rewrite`

#### create
Create new files with directory management.

```json
{
  "name": "create",
  "arguments": {
    "path": "scripts/setup.sh",
    "content": "#!/bin/bash\necho 'Done'",
    "createDirs": true
  }
}
```

#### fetch
Fetch web content with HTTP support.

```json
{
  "name": "fetch",
  "arguments": {
    "url": "https://api.github.com/repos/owner/repo",
    "headers": {"Accept": "application/json"},
    "extractText": true
  }
}
```

### Tool Security

- **Path validation** prevents directory traversal
- **Command sanitization** prevents injection
- **Configurable timeouts** prevent hanging
- **Confirmation required** for dangerous operations (bash, edit, create)

---

## MCP Integration

MCP (Model Context Protocol) allows Niffler to integrate with external servers for additional tools.

### Quick Start

1. **Install Node.js** (required for most MCP servers)
2. **Configure in `config.yaml`:**

```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    enabled: true

  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "${GITHUB_TOKEN}"
    enabled: true
```

3. **Verify:**
```
/mcp status
```

### Popular MCP Servers

| Server | Tools |
|--------|-------|
| filesystem | read_file, write_file, list_directory |
| github | create_repository, create_issue, list_issues |
| git | git_status, git_diff, git_commit |

### Configuration Options

```yaml
mcpServers:
  server-name:
    command: "executable"
    args: ["-arg1", "value1"]
    env:
      VAR_NAME: "value"
    workingDir: "/path"
    timeout: 30000
    enabled: true
```

---

## Plan & Code Modes

Niffler features an intelligent mode system that adapts behavior based on the task.

### Plan Mode

Focus on analysis, research, and task breakdown:
- Emphasizes understanding requirements
- **File protection**: Cannot edit existing files
- Can only edit files created during current plan session

```
/plan
> Analyze the codebase and identify bottlenecks
```

### Code Mode

Focus on implementation and execution:
- Emphasizes making concrete changes
- Full file access for editing

```
/code
> Implement the optimizations we planned
```

### Mode Persistence

- Mode stored per conversation
- Resuming conversation restores mode
- Visual indicator in prompt (green=plan, blue=code)

### Plan Mode File Protection

When in Plan mode:
- Files existing before plan mode are **protected**
- Only files created during the session can be edited
- Switching to Code mode removes all restrictions

---

## Thinking Tokens

Niffler supports reasoning/thinking tokens from advanced AI models.

### Supported Models

- **GPT-5** and OpenAI reasoning models
- **Claude 4** and Anthropic reasoning models
- **DeepSeek R1** and similar reasoning models

### Configuration

```yaml
models:
  - nickname: "sonnet-thinking"
    model: "claude-sonnet-4-5-20250929"
    include_reasoning_in_context: true
    thinking_format: "anthropic"
    max_thinking_tokens: 4000
```

### Reasoning Levels

- `low`: 2048 tokens (light reasoning)
- `medium`: 4096 tokens (balanced)
- `high`: 8196 tokens (deep reasoning)

### Benefits

- **Self-correcting AI**: Models catch their own reasoning errors
- **Transparency**: See how conclusions are reached
- **Better first responses**: Reduced trial-and-error

---

## Cost Tracking

Niffler tracks token usage and costs automatically.

### Cost Configuration

```yaml
models:
  - nickname: "sonnet"
    model: "claude-sonnet-4-5-20250929"
    inputCostPerMToken: 3000      # $3.00 per million
    outputCostPerMToken: 15000    # $15.00 per million
```

### Viewing Costs

Session costs displayed in status line:
```
↑1.2k ↓450 15% of 200k $0.012
```

- `↑1.2k` - Input tokens
- `↓450` - Output tokens
- `15% of 200k` - Context usage
- `$0.012` - Session cost

### Database Queries

```sql
-- Recent usage
SELECT * FROM model_token_usage ORDER BY created_at DESC LIMIT 10;

-- Total cost by model
SELECT model, SUM(total_cost) FROM model_token_usage GROUP BY model;

-- Daily costs
SELECT DATE(created_at), SUM(total_cost)
FROM model_token_usage
WHERE created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY DATE(created_at);
```

---

## Command Reference

### Navigation Commands

| Command | Description |
|---------|-------------|
| `/help` | Show help message |
| `/quit`, `/exit` | Exit Niffler |
| `/clear` | Clear current conversation |
| `/new` | Start new conversation |

### Conversation Commands

| Command | Description |
|---------|-------------|
| `/conv` | List conversations |
| `/conv <id>` | Switch to conversation |
| `/rename <name>` | Rename conversation |
| `/archive <id>` | Archive conversation |
| `/unarchive <id>` | Restore conversation |
| `/search <query>` | Search conversations |

### Configuration Commands

| Command | Description |
|---------|-------------|
| `/config` | List configs |
| `/config <name>` | Switch config |
| `/model` | List models |
| `/model <nickname>` | Switch model |
| `/plan` | Switch to plan mode |
| `/code` | Switch to code mode |

### Multi-Agent Commands

| Command | Description |
|---------|-------------|
| `/agents` | List agents |
| `/agent <name>` | Show agent details |

### MCP Commands

| Command | Description |
|---------|-------------|
| `/mcp status` | Show MCP server status |
| `/mcp reload` | Reload MCP servers |

### Utility Commands

| Command | Description |
|---------|-------------|
| `/cost` | Show session cost |
| `/tokens` | Show token usage |
| `/todo` | Manage todo lists |
| `/dump` | Toggle HTTP dump mode |

---

## Troubleshooting

### API Key Issues

**Error:** `API key environment variable not set`

**Solution:**
```bash
# Verify environment variable
echo $ANTHROPIC_API_KEY

# Set in shell profile
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Database Connection

**Error:** `Failed to connect to database`

**Solution:**
```bash
# Check TiDB is running
docker ps | grep tidb

# Verify connection
mysql -h 127.0.0.1 -P 4000 -u root -e "SELECT 1"

# Create database if missing
mysql -h 127.0.0.1 -P 4000 -u root -e "CREATE DATABASE niffler;"
```

### Model Not Found

**Error:** `Model not found: <nickname>`

**Solution:**
- Check `~/.niffler/config.yaml` for correct nickname
- Verify model is in the `models` array
- Use `/model` to list available models

### MCP Server Issues

**Problem:** MCP server not starting

**Solution:**
```bash
# Test command manually
npx -y @modelcontextprotocol/server-filesystem /path/to/test

# Check Node.js installation
which node
node --version

# Check environment variables
env | grep GITHUB_TOKEN
```

### Debug Mode

Enable debug logging for troubleshooting:
```bash
./src/niffler --loglevel=DEBUG

# With HTTP dump
./src/niffler --dump

# Both
./src/niffler --loglevel=DEBUG --dump
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Slow responses | Check network, try different model |
| High token usage | Use `/clear` to reset context |
| Tools not working | Verify tool permissions in agent config |
| Mode not switching | Check you're not in protected plan mode |

### Getting Help

1. Check this manual
2. Review [EXAMPLES.md](EXAMPLES.md) for usage patterns
3. Check [ARCHITECTURE.md](ARCHITECTURE.md) for technical details
4. File an issue on GitHub

---

**Last Updated:** 2025-04-01
**Version:** 0.4.0
