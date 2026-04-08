# Actions

## Purpose

Niffler now has a shared Action layer that sits underneath:

- slash commands for humans
- tool calls for agents

The goal is to avoid implementing the same behavior twice and to make help, permissions, and orchestration use the same source of truth.

In short:

- actions define what the system can do
- commands are one UI for actions
- tools are one API for actions

## Current Shape

Core action modules:

- `src/actions/types.nim`
- `src/actions/registry.nim`
- `src/actions/runtime.nim`

Shared transport for sending work to running agents:

- `src/core/agent_dispatch.nim`

Current action-backed areas:

- agent management
- task dispatch to running agents
- conversation create/list/switch/archive/info

## Surfaces

Each action can be exposed on one or more surfaces:

- `asMasterCli`
- `asAgentCli`
- `asTool`

This is how `/help` is generated and how we distinguish:

- master-only commands
- agent-routable commands
- agent-callable tools

## Capability Model

The capability model is intentionally small.

It currently exists only for action-backed tools, not for every tool in the system.

Current capabilities:

- `inspect_agents`
- `manage_agents`
- `dispatch_tasks`
- `manage_conversations`
- `inspect_system`

This is deliberately narrow. The intent is not to build a general RBAC system.

Instead, it answers one focused question:

"If an agent is allowed to use a high-level orchestration tool, which operations inside that tool should it be allowed to invoke?"

## Why This Is Not Too Complex

The capability model is kept simple in three ways.

### 1. Tool allowlists still remain the outer gate

Agents still declare allowed tool names in their markdown definitions.

That means:

- if an agent does not list `agent_manage`, it cannot use `agent_manage` at all
- if an agent does not list `task_dispatch`, it cannot use `task_dispatch` at all

Capabilities do not replace tool allowlists. They only refine action-backed tools.

### 2. Capabilities are only used for action-backed tools

Normal tools like `read`, `bash`, `edit`, and `fetch` are still controlled by tool name allowlists.

Capabilities are only used for tools that bundle multiple high-level operations, such as:

- `agent_manage`
- `task_dispatch`

### 3. Transitional defaults keep current agents working

To avoid breaking existing agent definitions, effective capabilities are derived from allowed tool names when explicit capabilities are missing.

Current transitional mapping:

- `agent_manage` implies:
  - `inspect_agents`
  - `manage_agents`
- `task_dispatch` implies:
  - `dispatch_tasks`

This means existing agents keep working while newer definitions can become more explicit.

## Agent Definitions

Agent definitions may include frontmatter like:

```md
---
allowed_tools:
  - read
  - task_dispatch
capabilities:
  - dispatch_tasks
---
```

`capabilities` is an advanced permission layer only for action-backed orchestration tools.
It is usually unnecessary for normal coding or research agents.

If omitted, transitional defaults are derived from action-backed tool names.

## Filtering And Enforcement

There are now two layers.

### 1. Schema filtering at exposure time

When an agent session is prepared, the tool schema list is filtered based on:

- allowed tool names
- effective action capabilities

This means an agent may see:

- only inspection operations in `agent_manage`
- no `task_dispatch` tool at all if it lacks `dispatch_tasks`

### 2. Enforcement at execution time

The tool worker also validates action-backed tool calls against effective capabilities.

This prevents a model from bypassing schema filtering by calling a hidden operation directly.

So the rule is:

- filtered exposure for guidance
- worker enforcement for safety

## Shared Dispatch Model

Agent request sending is now shared through `src/core/agent_dispatch.nim`.

This module owns:

- request ID generation
- request preparation
- request publishing

The master CLI uses the shared transport in a non-blocking way.

The `task_dispatch` tool uses the same transport, and then optionally waits for a final result because tools need to return something useful to the caller.

This keeps the transport unified while still supporting different calling patterns.

## Current Limitations

- Not every command is fully migrated to Action execution yet.
- Some master-only commands are Action-registered for help/metadata but still use older handler logic internally.
- The capability model currently covers only action-backed orchestration tools.

That is intentional. The current design prefers a small, understandable mechanism over a broad authorization system.

## Practical Guidance

When adding new orchestration features:

1. add or reuse an action
2. decide which surfaces expose it
3. if it is bundled into an action-backed tool, assign a small explicit capability
4. keep tool-name allowlists as the coarse permission gate

If a feature does not need per-operation refinement, do not add a new capability.

## Relationship To Skills

Skills are not actions.

- actions define executable operations
- skills define reusable workflow guidance

Skills should help an agent decide when to use actions such as:

- `agent_manage`
- `task_dispatch`

But they should not replace the action or permission model itself.
