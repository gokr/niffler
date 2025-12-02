# Niffler - AI Assistant in Nim

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.4.0-green.svg)

**Niffler** is a "Claude Code" style AI assistant built in Nim with support for multiple AI models and providers, a builtin tool system and a fully persistent conversation model using TiDB (MySQL-compatible distributed database). Niffler is heavily inspired by Claude Code but was initially started when I stumbled over [Octofriend](https://github.com/synthetic-lab/octofriend/). It has evolved into a distributed multi agent system where each agent runs as its own Niffler process and collaborates in a "chat room style" using NATS.

**NOTE: Niffler is to a large extent coded using Claude Code!**

## 🏗️ Architecture & Design

Niffler features a **distributed multi-agent architecture** where specialized agents run as separate processes and collaborate via NATS messaging in a chat room model.

**Current Architecture:**
- **Multi-Agent System**: Named agents (coder, researcher, etc.) run in isolated processes with dedicated tools
- **Chat Room Model**: Agents communicate via NATS subjects like `niffler.agent.{name}.request`
- **Master-Worker Pattern**: Master Niffler orchestrates agents using `@agent` routing syntax
- **Process Isolation**: Each agent has independent terminal, tool permissions, and memory space
- **Thread-Safe Workers**: Each agent uses dedicated worker threads for UI, API, and tool execution
- **Persistent Storage**: TiDB database for conversation history, agent state, and usage tracking

**Key Features:**
- 🤖 **Multi-Agent**: Process-per-agent with specialized tool sets and capabilities
- 💬 **Chat Room Model**: NATS-based messaging enables agent collaboration (`niffler.agent.*`)
- 🎮 **Master Orchestration**: Central CLI with `@agent` syntax for routing and management
- 🧵 **Multi-threaded**: Per-agent worker threads for UI, API, and tool operations
- 💾 **Persistent**: TiDB storage for conversations, agents, and state across restarts
- 🛠️ **Tool System**: Built-in tools + MCP integration per agent
- 🔄 **Secure**: Path sanitization, tool permissions, and agent-based access control
- 📡 **NATS**: Distributed messaging backbone for all agent coordination

Learn more about the multi-agent architecture in **[doc/TASK.md](doc/TASK.md)** and system design in **[doc/ARCHITECTURE.md](doc/ARCHITECTURE.md)**.


## 🤖 AI Capabilities

- **Multi-Model Support**: Seamlessly switch between different AI models (OpenAI, Anthropic, and other OpenAI-compatible APIs)
- **Plan/Code Mode System**: Toggle between planning and coding modes with mode-specific system prompts
- **Dynamic System Prompts**: Context-aware prompts that include workspace information, git status, and project details
- **Agent-Based Single-Shot Tasks**: Scripting support via `--task` flag in agent mode for immediate responses
- **Model Management**: Easy configuration and switching between AI models
- **Thinking Token Support**: Manages, shows and stores reasoning tokens separately
- **Custom Instructions**: NIFFLER.md handling with include directive support

## 👥 Multi-Agent System

Niffler's unique **chat room model** enables multiple specialized agents to collaborate via NATS messaging.

### How It Works

**Master Niffler** (the orchestrator):
```bash
# Start the master CLI
./src/niffler

# Route requests to agents using @agent syntax
> @coder refactor the database module
> @researcher find the best HTTP library for Nim
```

**Agent Processes** (specialized workers):
```bash
# Terminal 1: Start specialized agents
./src/niffler agent coder          # Coding and implementation tasks
./src/niffler agent researcher     # Research and analysis
./src/niffler agent bash_helper    # Shell operations
```

### Key Features

- **Named Agents**: Each agent has a unique name (coder, researcher, etc.)
- **Auto-Start**: Agents marked `auto_start: true` launch automatically with master
- **Independent Processes**: Each agent runs in its own terminal window
- **Tool Permissions**: Each agent can have different tool access (e.g., read-only vs full access)
- **Task vs Ask Model**: `Task` for isolated execution, `Ask` for conversation continuation

### Quick Start

```bash
# Terminal 1: Start your agents
./src/niffler agent coder
./src/niffler agent researcher

# Terminal 2: Start master and begin collaborating
./src/niffler

# Check which agents are available
> /agents

# Route a task to an agent
> @coder /task "Create a REST API server"

# Have a conversation with an agent
> @researcher "Compare authentication methods"
```

**Learn more:** See [doc/TASK.md](doc/TASK.md) for complete multi-agent documentation and [doc/EXAMPLES.md](doc/EXAMPLES.md) for usage patterns.

## 💰 Token Counting & Cost Tracking

Niffler features an intelligent token estimation system with dynamic correction factors that learns from actual API usage to provide increasingly accurate cost predictions.

**Features:**
- **Heuristic-Based Estimation**: 7-16% accuracy using language-specific heuristics without heavy tokenizers
- **Dynamic Learning**: Automatically improves accuracy through comparison with actual API responses
- **Cost Optimization**: Better estimates lead to more accurate cost predictions
- **Model-Specific**: Each model gets its own correction factor based on real usage data

**Learn More:** Complete details about the token estimation system and cost tracking in **[doc/TOKEN_COUNTING.md](doc/TOKEN_COUNTING.md)**.


## 🛠️ Tool System & Extensions

Niffler includes a comprehensive tool system that enables AI assistants to safely interact with your development environment.

### Core Tools
- **bash**: Execute shell commands with timeout control and process management
- **read**: Read file contents with encoding detection and size limits
- **list**: Directory listing with filtering, sorting, and metadata display
- **edit**: Advanced file editing with diff-based operations and backup creation
- **create**: Safe file creation with directory management and permission control
- **fetch**: HTTP/HTTPS content fetching with web scraping capabilities
- **todolist**: Task management and todo tracking with persistent state

**Learn More:** Complete documentation of the tool system, security features, and custom tool development in **[doc/TOOLS.md](doc/TOOLS.md)**.

### MCP (Model Context Protocol) Integration

Extend Niffler's capabilities with external MCP servers that provide additional specialized tools and resources for your development workflow.

**Key Features:**
- **External Server Support**: Integration with any MCP-compatible server
- **Automatic Discovery**: Tools are automatically discovered at startup
- **Flexible Configuration**: Easy YAML-based server setup
- **Health Monitoring**: Automatic server health checks and recovery

**Popular MCP Servers:**
- **Filesystem**: Secure file operations with directory access controls
- **GitHub**: Repository management, issue tracking, and PR operations
- **Git**: Version control operations and repository management

**Quick Setup:**
```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/projects"]
    enabled: true

  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "your-github-token"
    enabled: true
```

**Check Status:**
```bash
# View all MCP servers and available tools
/mcp status
```

**Learn More:** Complete MCP setup guide with installation, configuration, and troubleshooting in **[doc/MCP_SETUP.md](doc/MCP_SETUP.md)**.

## 📦 Installation

### Prerequisites
- Nim 2.2.4 or later
- Git
- **NATS Server**: Required for multi-agent IPC and will be automatically started by Niffler

#### NATS Server Installation

Niffler requires a NATS server for communication between agents. You have several options:

**Option 1: Docker (Recommended)**
```bash
# Pull and run NATS server
docker run -d --name nats -p 4222:4222 nats:latest

# Or using docker-compose
echo 'version: "3.7"
services:
  nats:
    image: nats:latest
    ports:
      - "4222:4222"
    command: ["-js"]  # Enable JetStream for persistence
' > docker-compose.yml
docker-compose up -d
```

**Option 2: Binary Download**
```bash
# Download the latest NATS server binary
curl -L https://github.com/nats-io/nats-server/releases/latest/download/nats-server-linux-amd64.tar.gz | tar xz
sudo mv nats-server-*/nats-server /usr/local/bin/nats-server

# Or download specific version
OS=linux ARCH=amd64 VERSION=2.10.7
wget https://github.com/nats-io/nats-server/releases/download/v${VERSION}/nats-server-${VERSION}-${OS}-${ARCH}.tar.gz
tar xzf nats-server-${VERSION}-${OS}-${ARCH}.tar.gz
sudo mv nats-server-${VERSION}-${OS}-${ARCH}/nats-server /usr/local/bin/
```

**Option 3: Package Manager**
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y nats-server

# macOS
brew install nats-server

# Windows (using Chocolatey)
choco install nats-server
```

Once installed, you can start NATS with:
```bash
nats-server -js  # -js enables JetStream for persistence
```

**Note**: Niffler will automatically detect and connect to a running NATS server on `localhost:4222`. If no server is running, Niffler will attempt to start one automatically.

### Optional Prerequisites (Enhanced Rendering)
- **[batcat](https://github.com/sharkdp/bat)**: For syntax-highlighted file content display
- **[delta](https://github.com/dandavison/delta)**: For advanced diff visualization with side-by-side view and word-level highlighting
- **[trafilatura](https://trafilatura.readthedocs.io/)**: For enhanced web content extraction with the fetch tool

If these tools are not installed, Niffler will automatically fall back to built-in rendering.

### System Libraries

Before building, ensure you have the required system libraries installed:

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install -y libnats3.7t64 libnats-dev
```

**Linux (CentOS/RHEL/Fedora):**
```bash
# For CentOS/RHEL
sudo yum install nats-devel
# Or for Fedora
sudo dnf install nats-devel
```

**macOS:**
```bash
brew install nats
```

**Windows:**
> The NATS library is typically bundled with the Nim package on Windows.

## 🏗️ Building Niffler

Niffler needs to be built from source at this time. Follow these steps to build and install the application on your system.

### Build Notes

- All compilation requires `--threads:on -d:ssl` flags (automatically set in build configuration)
- The optimized build (`nimble build`) creates a single static binary
- Windows users may need to install Visual Studio Build Tools for native compilation

## 🎯 Quick Start

### 1. Initialize Configuration
```bash
niffler init
```
This creates default configuration files:
- **Linux/macOS**: `~/.niffler/config.yaml` and `~/.niffler/NIFFLER.md`
- **Windows**: `%APPDATA%\niffler\config.yaml` and `%APPDATA%\niffler\NIFFLER.md`

The NIFFLER.md file contains customizable system prompts that you can edit to tailor Niffler's behavior to your preferences.

### 2. Configure Your AI Model
Edit the configuration file to add (or enable) at least one AI model and API key:
```yaml
models:
  - nickname: "gpt4"
    baseUrl: "https://api.openai.com/v1"
    model: "gpt-4"
    apiKey: "your-api-key-here"
    enabled: true
```

### 3. Start Interactive Mode
```bash
niffler
```

## 💻 Usage Examples

### Interactive Mode (Master CLI)
```bash
# Start interactive mode with agent routing
niffler

# Within interactive mode, route to agents:
> @coder fix the bug in main.nim
> @researcher find the best HTTP library

# List available models
niffler model list

# Use specific model
niffler --model=gpt4

# Enable debug logging
niffler --debug

# Enable info logging
niffler --info

# Enable HTTP request/response dumping for debugging
niffler --dump

# Combine debug and dump for maximum visibility
niffler --debug --dump
```

### Single-Shot Tasks (Agent Mode)
```bash
# Execute a single task with an agent and exit
# Perfect for scripting and automation
niffler agent coder --task="Create a README for this project"

# With specific model
niffler agent researcher --task="Find latest version of all dependencies" --model=kimi

# Route a command with mode switching
niffler agent coder --task="/plan analyze the codebase structure"

# Script-friendly - chain multiple tasks
niffler agent coder --task="Lint all source files"
niffler agent researcher --task="Find latest version of all dependencies"
```

### Configuration Management
```bash
# Initialize configuration
niffler init

# Initialize with custom path
niffler init /path/to/config
```

## 📚 Documentation

- **[Configuration Guide](doc/CONFIG.md)** - Comprehensive configuration documentation
- **[Model Setup](doc/MODELS.md)** - AI model configuration and providers
- **[Tool System](doc/TOOLS.md)** - Tool execution, security, and extensions
- **[MCP Setup](doc/MCP_SETUP.md)** - External tool server integration
- **[Architecture](doc/ARCHITECTURE.md)** - System design and architecture
- **[Usage Examples](doc/EXAMPLES.md)** - Common patterns and workflows
- **[Multi-Agent System](doc/TASK.md)** - Agent-based architecture

## 🧪 Development

### Running Tests
```bash
# Run all tests
nimble test
```

### Building
```bash
# Development build
nim c src/niffler.nim

# Release build
nimble build
```

### Debugging

The `--dump` flag provides complete HTTP request and response logging and `--debug` provides debug logging.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Nim Programming Language**: For providing an excellent, performant language for systems programming
- **Original Octofriend**: For inspiring the feature set and a very friendly Discord

