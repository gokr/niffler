# Niffler

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.5.0-green.svg)

Niffler is an AI terminal assistant written in Nim. It supports local interactive use, tool calling, reusable skills, and optional multi-agent orchestration over NATS.

The current branch adds and tightens several user-facing workflows that should be reflected when this is merged back to `main`:

- plan and code modes with stronger plan-mode protections
- reusable skills that can be loaded or downloaded on demand
- agent runtime configuration stored in markdown frontmatter
- Discord routing through the master and agent messaging flow

## Core Features

- Interactive terminal assistant with conversation history
- Tool calling for shell commands, file reads, edits, creation, and web fetches
- Plan mode for analysis and task breakdown
- Code mode for implementation work
- Skills system for reusable workflow guidance
- Optional multi-agent routing with `@agent` commands over NATS
- Discord integration for remote access
- Database-backed conversation persistence and token usage tracking

## Quick Start

### 1. Install prerequisites

Build requirements:

- Nim 2.2.4 or later
- Git
- Clang
- libclang development headers (`libclang-dev` on Debian/Ubuntu)

Runtime requirements:

- TiDB or MySQL

Optional for multi-agent mode:

- NATS Server

### 2. Install system libraries

macOS:

```bash
brew install cnats mariadb-connector-c pcre
```

Ubuntu/Debian:

```bash
sudo apt install libnats3.7t64 libnats-dev libmariadb-dev xsel libpcre3 libpcre3-dev
```

For a typical Ubuntu/Debian setup, this is usually enough to build and run the local assistant:

```bash
sudo apt install clang libclang-dev libmariadb-dev
```

If you want multi-agent mode, also install NATS support and the server:

```bash
sudo apt install libnats-dev nats-server
```

### 3. Build

```bash
nimble build
```

### 4. Initialize config

```bash
./niffler init
```

This creates `~/.niffler/config.yaml` and the active config directories used for prompts and agent definitions.

### 5. Configure a model

Edit `~/.niffler/config.yaml` and set either `api_key` directly or `api_env_var`.

Example:

```yaml
models:
  - nickname: "openrouter-free"
    base_url: "https://openrouter.ai/api/v1"
    model: "qwen/qwen3-coder:free"
    api_env_var: "OPENROUTER_API_KEY"
    enabled: true
```

Then export the key:

```bash
export OPENROUTER_API_KEY="your-key-here"
```

### 6. Start Niffler

```bash
./niffler
```

Useful commands:

```text
/help
/model
/new
/conv
/plan
/code
```

## Modes

### Plan Mode

`/plan` switches the conversation into analysis mode.

- emphasizes investigation, task breakdown, and design
- protects files that existed before the current plan session
- allows editing files created during the current plan session
- supports creating plan files that are tracked for that session

Example:

```text
/plan
Analyze the codebase and propose the smallest safe fix.
```

### Code Mode

`/code` switches back to implementation mode.

- removes plan-mode edit restrictions
- is intended for concrete file changes and execution

```text
/code
Implement the approved fix and run the tests.
```

See `doc/MANUAL.md` for the full plan/code workflow.

## Skills

Skills are reusable instruction modules that help an agent apply a specific workflow.

Common commands:

```text
/skill list
/skill load golang
/skill show golang
/skill download vercel-labs/agent-skills --skill frontend-design
```

Niffler discovers skills from:

- `.agents/skills/`
- `.claude/skills/`
- `~/.agents/skills/`
- `~/.niffler/skills/`

See `SKILLS.md` and `doc/MANUAL.md` for details.

## Multi-Agent Mode

Niffler can also run a master process and multiple named agents that communicate over NATS.

### Start infrastructure

Database:

```bash
tiup playground --tag niffler
```

NATS:

```bash
nats-server -js
```

### Start master and agents

Terminal 1:

```bash
./niffler
```

Terminal 2+:

```bash
./niffler agent coder
./niffler agent researcher
./niffler agent tester
```

### Route work from master

```text
@coder fix the build failure in src/api.nim
@researcher find the best NATS client for Nim
@coder /task implement error handling for the API

/agents
/focus coder
fix this bug
```

## Agent Definitions

Agent runtime configuration now lives in markdown files under the active config directory, typically `~/.niffler/<config>/agents/`.

Example:

```markdown
---
model: openrouter-free
allowed_tools:
  - read
  - edit
  - create
  - bash
  - list
  - fetch
auto_start: true
max_turns: 30
---

# Coder Agent

## Description
Specialized in code analysis and implementation.

## System Prompt
You are a coding expert.
```

Important frontmatter fields:

- `allowed_tools`: required tool whitelist
- `model`: optional model override
- `auto_start`: startup hint used when `master.auto_start_agents` is enabled
- `max_turns`: optional per-agent turn limit override
- `capabilities`: optional advanced permission layer for action-backed orchestration tools

`capabilities` is usually unnecessary for ordinary coding agents. Normal tools like `read`, `edit`, `create`, `bash`, `fetch`, and `todolist` are controlled by `allowed_tools`.

The markdown file is the authoritative runtime definition for the agent.

## Discord

Discord support is optional and works alongside the master and agent flow.

See `doc/DISCORD_SETUP.md` for setup and command details.

## Documentation

- `doc/MANUAL.md` - full user manual
- `doc/EXAMPLES.md` - workflows and examples
- `doc/TOOLS.md` - built-in tools reference
- `SKILLS.md` - skills system details
- `ACTIONS.md` - action and orchestration model
- `doc/DISCORD_SETUP.md` - Discord setup
- `doc/MCP_SETUP.md` - MCP server integration
- `doc/CONTRIBUTING.md` - contributor guide
- `doc/README.md` - documentation index

## Development

```bash
nimble test
nim c src/niffler.nim
nimble build
./niffler --loglevel=DEBUG --dump
```

## License

MIT License. See `LICENSE`.
