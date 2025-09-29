# Task Tool Implementation Plan

## Overview
This document outlines the plan for implementing a task tool with autonomous agent execution capabilities. The key innovation is a **soft agent type system** where agents are defined via markdown files in `~/.niffler/agents/`, making the system user-extensible without code changes.

## Current State Analysis
- **Existing todolist tool**: Already provides task management with persistence
- **Tool registry**: Well-designed object variant system for easy extensibility
- **Multi-agent design**: Comprehensive architecture document exists
- **Threading system**: Robust channel-based communication between workers
- **Channel architecture**: Can support isolated execution environments per task

## Implementation Plan

### Phase 1: Agent Definition System
1. **Agent Type Definitions** (`src/types/agents.nim`)
   - Define `AgentDefinition` type (name, description, allowedTools, systemPrompt, filePath)
   - Define `AgentValidationError` enum for validation status
   - Define `AgentStatus` type for validation results
   - Implement markdown parser for agent definition files
   - Implement validation logic (check required sections, unknown tools)

2. **Agent Initialization** (`src/core/config.nim` or new `src/core/init.nim`)
   - Embed default agent definitions (general-purpose.md, code-focused.md) in binary
   - Create `~/.niffler/agents/` directory on first run
   - Write default agents to disk if not present
   - Implement agent loading with file system enumeration
   - Support user-created agent definitions (override/extend defaults)

### Phase 2: Agent Management UI
3. **Agent Command** (`src/ui/cli.nim`)
   - Implement `/agent` command with nancy table display
   - Show agent list: name, description, tool count, validation status (✓/✗/⚠)
   - Implement `/agent <name>` to show detailed agent view
   - Add validation error display with helpful messages
   - Implement tab completion for agent names
   - Optional: Add `/reload agents` for hot reload

4. **Tool Access Control** (`src/tools/registry.nim`)
   - Implement `isToolAllowedForAgent(toolName, agent)` function
   - Add validation in tool worker before execution
   - Return clear error messages for unauthorized tool use
   - Support checking for unknown tools (warnings)

### Phase 3: Task Execution System
5. **Task Executor Core** (`src/core/task_executor.nim`)
   - Create isolated execution environment per task
   - Spawn dedicated thread with own API worker instance
   - Create task-specific channel pair for API communication
   - Share global tool worker (already thread-safe)
   - Build task-specific system prompt from agent definition
   - Maintain separate message history per task
   - Implement timeout and resource limits

6. **Task Tool** (`src/tools/task.nim`)
   - Implement task tool schema (agent_type, description, estimated_complexity)
   - Create task creation logic with agent selection
   - Implement task execution orchestration
   - Add result condensation (ask task LLM for summary)
   - Define `TaskResult` type (success, summary, artifacts, metrics, error)
   - Return condensed result to main agent (not full conversation)

### Phase 4: Integration and Persistence
7. **Database Schema Extensions** (`src/core/database.nim`)
   - Add `task_executions` table (conversation_id, agent_type, description, status, timestamps, tokens, result_summary)
   - Add `task_messages` table (task_execution_id, role, content, timestamp)
   - Implement task execution tracking and history
   - Add queries for task audit trails and debugging

8. **System Prompt Integration** (`src/core/system_prompt.nim`)
   - Update main agent system prompt to include task tool
   - Document task tool capabilities and agent types
   - Add instructions for when to use autonomous tasks
   - Include guidelines for task description clarity
   - Document available agents and their capabilities

### Phase 5: UI and Polish
9. **Task Monitoring UI** (`src/ui/cli.nim`)
   - Display task approval prompt before execution
   - Show task progress during execution
   - Display task results when complete
   - Add error handling and recovery UI
   - Optional: Show detailed task conversation on demand

10. **Testing and Documentation**
    - Create test suites for agent loading and validation
    - Test task execution isolation and thread safety
    - Test tool access control enforcement
    - Verify database persistence and recovery
    - Document agent definition format for users

## Soft Agent Type System

### Agent Definition Format

Agents are defined via markdown files in `~/.niffler/agents/`. Each file must have three sections:

**Example: `~/.niffler/agents/general-purpose.md`**

```markdown
# General Purpose Agent

## Description
Safe research and analysis agent for gathering information without modifying the system.

## Allowed Tools
- read
- list
- fetch
- grep
- glob

## System Prompt

You are a research and analysis agent. Your role is to gather information, analyze code,
and provide comprehensive findings without making any modifications to the system.

### Your Capabilities
- Read and analyze files
- Search through codebases
- Fetch web content for research
- Explore directory structures

### Your Constraints
- You CANNOT edit or create files
- You CANNOT execute bash commands
- You CANNOT modify the system in any way
- You MUST return a concise summary of your findings

### Task Execution
When assigned a task, work autonomously to gather all relevant information, then provide
a clear summary with:
1. Key findings
2. Files/resources examined
3. Specific recommendations or answers
4. Any blockers or limitations encountered
```

### Default Agents Provided

**`general-purpose.md`**
- **Tools**: read, list, fetch, grep, glob
- **Purpose**: Research, analysis, information gathering
- **Constraints**: Cannot edit, create, or execute commands

**`code-focused.md`**
- **Tools**: read, list, fetch, grep, glob, create
- **Purpose**: Code generation, analysis, safe file creation
- **Constraints**: Cannot edit existing files or execute commands

### User-Defined Agents

Users can create custom agents by adding new markdown files to `~/.niffler/agents/`:
- `security-scanner.md` - Read-only security analysis with bash for safe scans
- `documentation-writer.md` - Read and create for documentation generation
- `test-runner.md` - Read and bash for test execution and reporting
- `api-tester.md` - Fetch and bash for API endpoint testing

### Agent Validation

**Validation checks**:
- ✓ Has `## Description` section
- ✓ Has `## Allowed Tools` section with at least one tool
- ✓ Has `## System Prompt` section
- ⚠ Warning if tools are not in registry (may be future tools)

**Status indicators** (in `/agent` command):
- ✓ (green) - Valid definition
- ✗ (red) - Parse error or missing required section
- ⚠ (yellow) - Valid but references unknown tools

### Agent Management Commands

**`/agent`** - Show table of all agents with status
```
┌────────────────────┬──────────────────────────────────┬───────┬────────┐
│ Name               │ Description                      │ Tools │ Status │
├────────────────────┼──────────────────────────────────┼───────┼────────┤
│ general-purpose    │ Research and analysis agent      │ 5     │ ✓      │
│ code-focused       │ Code generation and analysis     │ 6     │ ✓      │
│ my-custom-agent    │ Custom testing agent             │ 4     │ ✓      │
└────────────────────┴──────────────────────────────────┴───────┴────────┘
```

**`/agent <name>`** - Show detailed agent view
```
┌─ general-purpose ───────────────────────────────────────────────────────┐
│ Description: Research and analysis agent for gathering information      │
│              without modifying the system                               │
│                                                                          │
│ Allowed Tools: read, list, fetch, grep, glob                           │
│                                                                          │
│ Status: ✓ Valid                                                         │
│                                                                          │
│ File: ~/.niffler/agents/general-purpose.md                             │
└─────────────────────────────────────────────────────────────────────────┘
```

### Safety and Execution Constraints

**Tool Access Control**:
- Enforced via whitelist in agent definition
- Tool worker validates tool use against agent's allowedTools
- Clear error messages for unauthorized tool attempts

**Task Execution Constraints**:
- **No Task Spawning**: Tasks cannot create other tasks (prevents recursion)
- **Limited Tool Access**: Each agent has explicit tool subset
- **Timeout Limits**: Each task has execution time limits
- **User Confirmation**: All autonomous tasks require approval before execution
- **Isolated Execution**: Each task runs in its own thread with dedicated API worker
- **Result Condensation**: Tasks return summaries, not full conversation history

## Task Execution Architecture

### Isolated Execution Environment

Each task runs in its own execution environment, similar to the main conversation loop but isolated:

```
Task Execution Environment:
├── Dedicated thread (spawned per task)
├── Isolated API worker instance (own channel pair)
├── Shared tool worker (already thread-safe, reused)
├── Task-specific system prompt (from agent definition)
├── Separate message history (not mixed with main conversation)
└── Result condensation (summary back to main agent)
```

**Key differences from main loop**:
- Main loop: Single persistent conversation with full history
- Task loop: Isolated conversation with condensed result output

### Result Condensation Strategy

Tasks don't return full conversation history (token-inefficient). Instead:

```nim
type
  TaskResult* = object
    success*: bool
    summary*: string        # LLM-generated summary of findings
    artifacts*: seq[string] # File paths created/read
    toolCalls*: int         # Metrics for tracking
    tokensUsed*: int
    error*: string          # If failed
```

**At task completion**, the task's LLM generates a summary:
```
"Summarize your work in 2-3 sentences for the main agent.
Include key findings, files created/read, and any blockers."
```

This summary becomes the tool result returned to the main agent.

### Database Schema

**Task execution tracking**:

```sql
CREATE TABLE task_executions (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER,      -- Parent conversation
  agent_type TEXT NOT NULL,     -- Agent name (e.g., "general-purpose")
  task_description TEXT,
  status TEXT,                  -- pending, running, completed, failed
  started_at TEXT,
  completed_at TEXT,
  tokens_used INTEGER,
  result_summary TEXT,
  FOREIGN KEY(conversation_id) REFERENCES conversations(id)
);

CREATE TABLE task_messages (
  id INTEGER PRIMARY KEY,
  task_execution_id INTEGER,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TEXT,
  FOREIGN KEY(task_execution_id) REFERENCES task_executions(id)
);
```

**Benefits**:
- Audit trail of all task executions
- Token usage tracking per task
- Full conversation retrieval for debugging
- Task performance metrics

## Implementation Files to Create/Modify

### New Files
- `src/types/agents.nim` - Agent types, validation, markdown parsing
- `src/core/task_executor.nim` - Task execution orchestration
- `src/tools/task.nim` - Task tool implementation
- `~/.niffler/agents/general-purpose.md` - Default research agent
- `~/.niffler/agents/code-focused.md` - Default code generation agent

### Modified Files
- `src/tools/registry.nim` - Add tool access control for agents
- `src/core/database.nim` - Add task execution tables
- `src/ui/cli.nim` - Add `/agent` command and task approval UI
- `src/core/system_prompt.nim` - Add task tool documentation
- `src/core/config.nim` - Add agent initialization logic

## Testing Strategy
- Test agent definition loading and validation
- Test markdown parsing with valid and invalid definitions
- Test tool access control enforcement
- Test task execution isolation and thread safety
- Verify database persistence for task history
- Test UI interaction and approval flows
- Ensure graceful error handling and recovery
- Test result condensation and summary generation

## Benefits of This Approach

### User Extensibility
- **No Code Changes Required**: Users add agents by creating markdown files
- **Transparent Definitions**: Agent capabilities clearly documented
- **Shareable**: Agent definitions are portable files
- **Version Control**: Users can track agent changes in git

### Safety and Control
- **Explicit Tool Whitelists**: Clear boundaries on what each agent can do
- **No Task Spawning**: Prevents recursive execution and runaway tasks
- **User Approval**: All autonomous tasks require confirmation
- **Isolated Execution**: Tasks don't interfere with main conversation

### Clean Architecture
- **Leverages Existing Systems**: Uses tool registry and threading infrastructure
- **Consistent Patterns**: `/agent` command mirrors `/model` command
- **Simple Enforcement**: Whitelist checking is straightforward
- **Scalable Design**: Add agents without recompiling

### Developer Experience
- **Self-Documenting**: Agent definitions serve as documentation
- **Easy Testing**: Each agent type can be tested independently
- **Clear Separation**: Task execution isolated from main loop
- **Maintainable**: Soft types avoid hardcoded agent logic

## Architecture Summary

### Threading Model
- **Main Thread**: UI and user interaction
- **API Worker Thread**: Main conversation with LLM
- **Tool Worker Thread**: Shared tool execution (thread-safe)
- **Task Threads**: One per active task with isolated API worker

### Agent System
- **Soft Types**: Defined via markdown, no enum or hardcoded types
- **Tool Whitelists**: Enforced at execution time by tool worker
- **Validation**: Parse-time checks for required sections
- **Hot Reload**: Optional reload without restart

### Task Execution Flow
1. Main agent calls `task` tool with agent_type and description
2. User approves task execution
3. Task executor spawns dedicated thread with isolated API worker
4. Task runs with agent-specific system prompt and tool restrictions
5. Task completes and generates summary via final LLM call
6. Summary returned to main agent as tool result
7. Task conversation and metrics stored in database

### Data Flow
```
User → Main Agent → task tool call → Task Executor
                                            ↓
                                    Spawn Task Thread
                                            ↓
                                    Isolated API Worker
                                            ↓
                                    Tool Worker (shared)
                                            ↓
                                    Generate Summary
                                            ↓
                                    Return to Main Agent
```

This approach provides powerful autonomous execution while maintaining safety, simplicity, and user control.