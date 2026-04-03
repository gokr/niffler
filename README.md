# Niffler - Autonomous Swarm Software Development

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.5.0-green.svg)

**Niffler** is an autonomous multi-agent system for software development. Multiple AI agents collaborate as a swarm, coordinated through a shared database and real-time NATS messaging. The master Niffler process acts as a control center, directing agents via CLI or Discord.

**Key idea**: Instead of one AI assistant, run a swarm of specialized agents that discover each other, share context, and collaborate on complex software tasks.

**NOTE: Niffler is largely coded using Claude Code and Niffler itself!**

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Master Niffler                            │
│  - Control center with CLI/Discord interface                     │
│  - Routes tasks to agents via NATS                               │
│  - Syncs configuration to database                               │
│  - Monitors agent health and presence                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ NATS (pub/sub)
                              ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│   Agent: Coder   │  │ Agent: Researcher │  │  Agent: Tester   │
│  - Reads DB      │  │  - Reads DB       │  │  - Reads DB      │
│  - NATS messages │  │  - NATS messages  │  │  - NATS messages │
│  - Independent   │  │  - Independent    │  │  - Independent   │
│  - Specialized   │  │  - Specialized    │  │  - Specialized   │
└──────────────────┘  └──────────────────┘  └──────────────────┘
                              │
                              │ Shared Database (TiDB/MySQL)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    TiDB / MySQL Database                         │
│  - Conversation persistence                                       │
│  - Token usage and cost tracking                                  │
│  - Task queue with priorities                                     │
│  - Agent configuration and presence                               │
│  - Workspace management                                           │
└─────────────────────────────────────────────────────────────────┘
```

### Components

**Master Niffler** - Control center that:
- Provides CLI interface with `@agent` routing
- Syncs configuration from `~/.niffler/config.yaml` to database
- Discovers available agents via NATS presence
- Routes requests and commands to agents
- Optional Discord integration for remote control

**Agent Nifflers** - Independent workers that:
- Bootstrap from database (no local config needed)
- Connect to NATS for real-time messaging
- Execute tasks independently with tool access
- Maintain presence and heartbeat
- Can be deployed anywhere with DB/NATS access

**Communication Channels**:
- **NATS**: Real-time agent coordination (required)
- **Discord**: Remote interface for master and agents (optional)
- **Database**: Persistent state, configuration, task queues

## Quick Start

### 1. Install prerequisites

- Nim 2.2.4 or later
- Git
- NATS Server
- TiDB or MySQL

#### Nim
Install Nim via [choosenim](https://nim-lang.org/install_unix.html):

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

#### TiDB or MySQL
Niffler uses MySQL-compatible features. TiDB is preferred for future vector search support.

**TiDB Playground** (recommended):
```bash
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
tiup playground --tag niffler
```

**MySQL** (local):
```bash
# Ubuntu/Debian
sudo apt install mysql-server

# macOS
brew install mysql
```

#### NATS Server
Required for agent communication:

```bash
# macOS
brew install nats-server

# Ubuntu/Debian
sudo apt install nats-server

# Start with JetStream
nats-server -js
```

### 2. Install system libraries

**macOS**:
```bash
brew install cnats mariadb-connector-c
```

**Ubuntu/Debian**:
```bash
sudo apt install libnats3.7t64 libnats-dev libmariadb-dev
```

### 3. Build Niffler

```bash
nimble build
```

### 4. Initialize config

```bash
./niffler init
```

### 5. Configure models

Edit `~/.niffler/config.yaml` to add your API keys, or set environment variables:

```bash
export OPENROUTER_API_KEY="your-key-here"
export REQUESTY_API_KEY="your-key-here"
```

### 6. Start the swarm

**Terminal 1 - Start NATS**:
```bash
nats-server -js
```

**Terminal 2 - Start database** (if not running):
```bash
tiup playground --tag niffler
# or: mysql-server
```

**Terminal 3 - Start master**:
```bash
./niffler
```

**Terminal 4+ - Start agents**:
```bash
./niffler agent coder
./niffler agent researcher
./niffler agent tester
```

### 7. Route tasks to agents

In master CLI:
```
> @coder fix the build failure in src/api.nim
> @researcher find the best NATS client for Nim
> @coder /task implement error handling for the API

> /agents          # List available agents
> /focus coder     # Set default agent
> fix this bug     # Routes to focused agent
```

## Usage

### Master Mode (Control Center)

Start master with CLI interface:
```bash
./niffler                                    # Default NATS URL
./niffler --nats-url=nats://localhost:4222   # Custom NATS
```

Master commands:
```
@coder fix the bug           # Route to specific agent
/agents                      # List connected agents
/focus coder                 # Set default agent
/model synthetic-glm5        # Switch model
/conv                        # List conversations
/new                         # New conversation
/help                        # Show all commands
```

### Agent Mode (Workers)

Start agents that pull config from database:
```bash
./niffler agent coder --db-host=127.0.0.1 --db-port=4000 --db-name=niffler
./niffler agent researcher --db-host=127.0.0.1 --db-port=4000
```

Single-shot tasks:
```bash
./niffler agent coder --task="Fix the build failure" --model=synthetic-glm5
./niffler agent researcher --task="Find HTTP libraries for Nim"
```

### Discord Integration

Agents and master can communicate via Discord:
```bash
./niffler --discord --discord-token="YOUR_BOT_TOKEN"
./niffler agent coder --discord --discord-token="YOUR_BOT_TOKEN"
```

See [doc/DISCORD_SETUP.md](doc/DISCORD_SETUP.md) for configuration.

## Agent Definitions

Agents are defined in markdown files under `~/.niffler/<config>/agents/`:

```markdown
# Coder Agent

## Description
Specialized in code analysis and implementation.

## Model
synthetic-glm5

## Allowed Tools
- read
- edit
- create
- bash
- list
- fetch

## System Prompt

You are a coding expert. Available tools: {availableTools}
```

Agent configuration in `config.yaml` controls process behavior:
```yaml
agents:
  - id: "coder"
    name: "Code Expert"
    model: "synthetic-glm5"
    auto_start: true
    persistent: true
    tool_permissions:
      - read
      - edit
      - create
      - bash
      - list
      - fetch
```

## Roadmap

**Current**:
- ✅ Master-agent routing over NATS
- ✅ Conversation persistence in TiDB
- ✅ Agent presence and discovery
- ✅ Tool execution with permissions
- ✅ Discord integration
- ✅ Task queue with priorities

**In Progress**:
- 🔄 Agent-to-agent direct messaging
- 🔄 Shared context store for collaboration
- 🔄 Workflow orchestration

**Planned**:
- ⏳ Agent capability discovery and auto-matching
- ⏳ Hierarchical task decomposition
- ⏳ Multi-agent collaboration on single task
- ⏳ Visual workflow definition
- ⏳ Agent reputation and reliability scoring

## Documentation

- **[MANUAL.md](doc/MANUAL.md)** - Comprehensive user manual
- **[TOOLS.md](doc/TOOLS.md)** - Built-in tools reference
- **[SKILLS.md](SKILLS.md)** - Skills system (reusable instruction modules)
- **[ACTIONS.md](ACTIONS.md)** - Action system architecture
- **[MCP_SETUP.md](doc/MCP_SETUP.md)** - MCP server integration
- **[EXAMPLES.md](doc/EXAMPLES.md)** - Usage patterns
- **[DISCORD_SETUP.md](doc/DISCORD_SETUP.md)** - Discord bot setup
- **[CONTRIBUTING.md](doc/CONTRIBUTING.md)** - Contributing guide

Developer docs in [doc/research/](doc/research/):
- Architecture details
- Database schema
- Implementation notes

## Development

```bash
# Run tests
nimble test

# Development build
nim c src/niffler.nim

# Release build
nimble build

# Debug logging
./niffler --loglevel=DEBUG --dump
```

## License

MIT License - see [LICENSE](LICENSE) file.

## Acknowledgments

- **Nim Programming Language** - Performant systems programming
- **Claude Code** - Inspiration for the tool-calling workflow
- **Octofriend** - Initial Discord integration inspiration
