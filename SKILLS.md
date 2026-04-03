# Skills System

## Purpose

Skills are reusable instruction modules that can be loaded on demand for an agent.

They are not the same as:

- actions: the core executable operations in the system
- tools: one machine-facing way to invoke actions
- commands: one human-facing way to invoke actions

Skills sit above those layers and influence how an agent approaches a class of work.

Examples:

- orchestration
- incident debugging
- code review
- documentation research

In short:

- skills = strategy and workflow guidance
- actions = what the system can do
- tools/commands = how those actions are invoked

## Implementation Status

Niffler now supports the [Agent Skills specification](https://agentskills.io) and can load skills from:

- Local project directories (`.agents/skills/`, `.claude/skills/`)
- Global user directories (`~/.config/opencode/skills/`)
- [skills.sh](https://skills.sh) registry (via `npx skills add`)

### Core Files

| File | Purpose |
|------|---------|
| `src/types/skills.nim` | Skill type definitions |
| `src/types/context_assembly.nim` | AdaptedSkill, ContextPlan types |
| `src/core/skills_discovery.nim` | YAML parsing, skill discovery |
| `src/core/context_assembly.nim` | Tool mapping, context assembly |
| `src/tools/skill.nim` | Skill tool implementation |

### Skill Tool Operations

```json
{
  "operation": "list|load|unload|show|search|refresh|download",
  "name": "skill-name",
  "query": "search query",
  "repo": "owner/repo"
}
```

| Operation | Description |
|-----------|-------------|
| `list` | List available or loaded skills |
| `load` | Load a skill into active context |
| `unload` | Remove a skill from context |
| `show` | Display skill details |
| `search` | Find skills by name/description |
| `refresh` | Re-scan skill directories |
| `download` | Install from skills.sh registry |

## Context Assembly Layer

The recommended architecture is now implemented. Niffler uses an internal context assembly layer that:

1. Maintains structured context components in memory
2. Renders final request messages at call time
3. Adapts skills from other harnesses to Niffler's tool set

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Skill Registry                      │
│  .agents/skills/                                     │
│  ~/.config/opencode/skills/                          │
└─────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────┐
│              Context Assembly Layer                  │
│                                                      │
│  State:                                              │
│    - basePrompt: string (stable)                    │
│    - activeSkills: seq[AdaptedSkill]                 │
│    - toolWhitelist: seq[string]                      │
│                                                      │
│  Render:                                             │
│    1. System: basePrompt + adapted skill content     │
│    2. Tools: filtered by whitelist (optional)        │
│    3. Developer prompt: task-specific guidance       │
└─────────────────────────────────────────────────────┘
```

### Skill Adaptation

Skills from skills.sh are written for other harnesses. Niffler adapts them via:

1. **Heuristic tool mapping**: Maps tool names from other harnesses
   - `Bash` → `bash`
   - `GlobTool` → `list`
   - `apply_patch` → `edit`
   - `Bash(git:*)` → `bash`

2. **Content adaptation**: Replaces tool references in skill content

3. **Tool whitelisting**: Skills can filter available tools

### Heuristic Tool Mappings

| Original Tool | Mapped To | Confidence |
|---------------|-----------|------------|
| `Bash` | `bash` | 1.0 |
| `Read`, `ReadFile` | `read` | 1.0 |
| `GlobTool`, `find_files` | `list` | 0.9 |
| `apply_patch` | `edit` | 1.0 |
| `WriteFile` | `create` | 1.0 |
| `Bash(git:*)` | `bash` | 1.0 |
| `Bash(npm:*)` | `bash` | 0.95 |

## SKILL.md Format

Niffler follows the [Agent Skills specification](https://agentskills.io/specification):

```yaml
---
name: skill-name
description: When to use this skill and what it does
version: "1.0.0"
license: MIT
compatibility:
  agents: [claude-code, opencode, cursor]
  languages: [go, python]
metadata:
  author: username
  tags: [tag1, tag2]
  category: languages
allowed-tools: Bash(git:*) Read
---

# Skill Instructions

Step-by-step guidance here...
```

### Required Fields

| Field | Description |
|-------|-------------|
| `name` | Unique identifier (lowercase, hyphens) |
| `description` | When to activate and what it does |

### Optional Fields

| Field | Description |
|-------|-------------|
| `version` | Semantic version |
| `license` | License name |
| `compatibility.agents` | Compatible agents |
| `compatibility.languages` | Language-specific skills |
| `metadata.tags` | Search/discovery tags |
| `allowed-tools` | Pre-approved tool list |

## Progressive Disclosure

Following the Agent Skills specification, Niffler supports progressive disclosure:

1. **Metadata** (~100 tokens): `name` and `description` loaded at startup
2. **Instructions** (< 5000 tokens): Full `SKILL.md` content when skill is activated
3. **Resources** (on demand): Scripts, references loaded only when needed

## Using skills.sh

Skills can be discovered and installed from [skills.sh](https://skills.sh):

```bash
# Install a skill
npx skills add saisudhir14/golang-agent-skill

# List available skills in a repo
npx skills add vercel-labs/agent-skills --list

# Install specific skill
npx skills add vercel-labs/agent-skills --skill frontend-design
```

The skill tool can also download skills programmatically:

```json
{
  "operation": "download",
  "repo": "vercel-labs/agent-skills",
  "skill": "frontend-design",
  "global": false
}
```

## Relationship To Agent Definitions

Agent markdown files and skills serve different purposes.

Agent definition markdown should describe:

- the agent's identity
- its purpose
- its default constraints
- its capabilities and allowed actions/tools

Skills should describe:

- when to use a workflow
- how to approach the work
- what actions/tools to prefer
- what guardrails to apply
- what output shape is expected

Skills should not be copied into agent markdown. They are reusable modules.

## Harness Engineering Insights

Based on [HumanLayer's research](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents):

### What Works

- ✅ Start simple, add config when agent fails
- ✅ Progressive disclosure (don't stuff all instructions upfront)
- ✅ Sub-agents as context firewalls
- ✅ Silent success, verbose errors for back-pressure

### What Doesn't Work

- ❌ Installing dozens of skills "just in case"
- ❌ Running full test suite every session
- ❌ Micro-optimizing tool access per sub-agent
- ❌ Auto-generated agentfiles

## Future Improvements

1. **LLM-based adaptation**: Use a fast model for ambiguous tool mappings
2. **Tool filtering**: Implement `toolWhitelist` filtering in API requests
3. **Sub-skill references**: Support `references/` directory for deeper content
4. **Hooks integration**: Pre/post tool hooks for verification
5. **Context monitoring**: Track context window usage to avoid "dumb zone"

## References

- [Agent Skills Specification](https://agentskills.io)
- [skills.sh Registry](https://skills.sh)
- [Claude Code Skills Docs](https://code.claude.com/docs/en/skills)
- [Harness Engineering Guide](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents)
