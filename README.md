# Niffler - AI Assistant in Nim

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.4.0-green.svg)

**Niffler** is a "Claude Code" style AI assistant built in Nim with support for multiple AI models and providers, a builtin tool system and a fully persistent conversation model using TiDB (MySQL-compatible distributed database). Niffler is heavily inspired by Claude Code but was initially started when I stumbled over [Octofriend](https://github.com/synthetic-lab/octofriend/). It has evolved into a distributed multi agent system where each agent runs as its own Niffler process and collaborates in a "chat room style" using NATS.

**NOTE: Niffler is to a large extent coded using Claude Code!**

## Quick Start

### 1. Install prerequisites

- Nim 2.2.4 or later
- Git
- NATS Server
- TiDB

#### Nim
Install Nim (compiler and tools) via [choosenim](https://nim-lang.org/install_unix.html):

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

#### TiDB
The easiest way to get TiDB running locally is to install `tiup` and start a named playground:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
```

Then start a persistent playground:

```bash
tiup playground --tag niffler
```

Why use `--tag niffler`:

- It stores the cluster data under `~/.tiup/data/niffler`
- You can stop it and later start the same named playground again with the same command
- Niffler can keep using the same local TiDB instance across restarts

Useful playground commands:

```bash
# Start or resume the same named playground
tiup playground --tag niffler

# Connect with the built-in client
tiup client

# Show running playground processes
tiup playground display
```

Niffler expects TiDB on `127.0.0.1:4000` by default, which matches the normal playground setup.

#### NATS Server Installation
Niffler requires a NATS server for communication between agents.

macOS:

```bash
brew install nats-server
```

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y nats-server
```

Start it with:

```bash
nats-server -js
```

### 2. Install system libraries

macOS:

```bash
brew install cnats
brew install mariadb-connector-c
```

If the MySQL client library is not found at runtime, you may also need:

```bash
export DYLD_LIBRARY_PATH="$(brew --prefix mariadb-connector-c)/lib:$DYLD_LIBRARY_PATH"
```

You may also need to help the compiler find Apple SDK headers:

```bash
export CPATH="$(xcrun --show-sdk-path)/usr/include"
```

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y libnats3.7t64 libnats-dev
```

Windows:

> The NATS library is typically bundled with the Nim package on Windows.

### 3. Build Niffler

```bash
nimble build
```

### 4. Initialize config

```bash
./src/niffler init
```

- macOS/Linux: `~/.niffler/config.yaml`
- Windows: `%APPDATA%/niffler/config.yaml`

### 5. Add credentials if needed

The default config is meant to start cleanly on a fresh machine.

- Local models such as Ollama and LM Studio can work without remote API keys
- Enabled remote models without usable credentials are reported at startup
- You can either edit `api_key` in `config.yaml` or set the matching `api_env_var`

```bash
export OPENROUTER_API_KEY="your-key-here"
./src/niffler
```

### 6. Start Niffler

```bash
./src/niffler
```

For more detailed setup and reference material, keep reading below.

## Overview

Niffler is a terminal-first coding assistant with:

- Multiple model providers via OpenAI-compatible APIs
- Local model support through Ollama and LM Studio
- Persistent conversations stored in TiDB
- Multi-agent routing over NATS with `@agent` syntax
- Built-in tools plus MCP integration
- Markdown rendering, prompt files, and model-specific settings

## Multi-Agent Architecture

Niffler supports a distributed multi-agent system with two modes:

### Master Mode
Master Niffler reads configuration from `~/.niffler/config.yaml` and syncs it to the database. It provides:
- CLI interface with `@agent` routing
- Discord integration for remote access
- NATS-based coordination with agents

```bash
./src/niffler  # Start master with CLI
./src/niffler --nats-url=nats://localhost:4222  # Custom NATS URL
```

### Agent Mode
Agents bootstrap from minimal CLI args, then pull all config from database:
- No filesystem config needed
- Connect to NATS and optional Discord channels
- Stateless - can be deployed anywhere

```bash
./src/niffler agent coder --db-host=127.0.0.1 --db-port=4000 --db-name=niffler
```

### Communication Channels
- **NATS**: Real-time agent coordination (required)
- **Discord**: Alternative interface for master and agents (optional)
- **Database**: Persistent task queue, configuration, and workspace management

### Routing Examples
```bash
# In master CLI:
> @coder fix the bug in main.nim
> @researcher compare HTTP libraries for Nim
> /agents  # List connected agents
> /sync    # Reload config from YAML and sync to database
```

More detail lives in:

- [doc/TASK.md](doc/TASK.md)
- [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md)

## Features

- Plan/code workflow with mode-aware prompting
- Tool calling for shell, file, web, and task operations
- Thinking-token support for models that expose reasoning
- Token and cost tracking
- MCP server integration
- **Discord integration** - Use Niffler via Discord (see `src/comms/discord.nim`)
- **Task queue** - Persistent task queue with priority and retry logic
- **Workspace management** - Multi-project support with file watchers and webhooks

Details live in:

- [doc/TOOLS.md](doc/TOOLS.md)
- [doc/MCP_SETUP.md](doc/MCP_SETUP.md)
- [doc/TOKEN_COUNTING.md](doc/TOKEN_COUNTING.md)
- [doc/MODELS.md](doc/MODELS.md)

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

# Set logging level
niffler --loglevel=DEBUG       # Verbose debugging
niffler --loglevel=INFO        # General information
niffler --loglevel=NOTICE      # Default (notice and above)
niffler --loglevel=WARN        # Warnings and above
niffler --loglevel=ERROR       # Errors only

# Enable HTTP request/response dumping for debugging
niffler --dump

# Combine loglevel and dump for maximum visibility
niffler --loglevel=DEBUG --dump
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

- **[Documentation Index](doc/README.md)** - Overview of current docs and research notes
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

The `--dump` flag provides complete HTTP request and response logging and `--loglevel=DEBUG` provides detailed debug logging. Use `--loglevel=INFO` for general information logging.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Nim Programming Language**: For providing an excellent, performant language for systems programming
- **Original Octofriend**: For inspiring the feature set and a very friendly Discord
