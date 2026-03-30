# Multi-Agent Guide

This document describes how the multi-agent flow works in the current `niffler-nats` branch.

## Overview

Niffler supports a master-and-agent setup over NATS.

- The master CLI accepts user input and routes work with `@agent`
- Agent processes run as separate Niffler processes
- Agents communicate over NATS
- Conversations and token usage are persisted in TiDB

## Running The Master

Start the normal CLI:

```bash
./src/niffler
```

Inside the CLI, route requests with `@agent`:

```text
@coder fix the build failure
@researcher compare NATS clients for Nim
@coder /task add JSON logging to the worker
```

## Running Agents

Each agent is a separate process:

```bash
./src/niffler agent coder
./src/niffler agent researcher
```

The agent name passed on the command line selects the markdown agent definition to load.

## Ask Versus Task

### Ask

Default `@agent prompt` behavior continues the agent's current conversation.

Example:

```text
@coder refactor the config loader
```

### Task

`@agent /task ...` runs an isolated task flow.

Example:

```text
@coder /task create a small REST example
```

## Agent Definitions

The authoritative runtime agent definition is a markdown file under the active config directory.

Typical locations:

- `~/.niffler/<active-config>/agents/*.md`
- `.niffler/<active-config>/agents/*.md`

The active config directory is selected by the `config` field in `config.yaml` and by the runtime session.

## YAML `agents` Section

The `agents` section in `config.yaml` is still important, but it is not the whole agent definition.

It is used for:

- process metadata
- auto-start behavior
- persistent/ephemeral intent
- default model metadata used by the agent manager

The markdown files are used for:

- prompt content
- allowed tools
- markdown-defined behavior
- optional agent-specific model override

## Auto-Start

If master mode is connected to NATS, it can auto-start agents listed in `config.yaml` with:

```yaml
master:
  auto_start_agents: true

agents:
  - id: "coder"
    auto_start: true
```

Both conditions are needed:

- `master.auto_start_agents` must be true
- the individual agent entry must have `auto_start: true`

## Agent Availability

Master mode discovers agents through NATS presence tracking.

In the CLI, use:

```text
/agents
```

to see available agents.

## Model Selection For Agents

Agents can get their model from more than one place.

In practice, the model used by a running agent can come from:

1. `--model` passed when the agent process is started
2. the markdown agent definition if it declares a model
3. normal fallback model selection logic from the loaded config

## Related Docs

- [CONFIG.md](CONFIG.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [EXAMPLES.md](EXAMPLES.md)
