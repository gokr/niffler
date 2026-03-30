# Configuration Guide

This document describes the configuration model used by the current `niffler-nats` branch.

## Main Config File

The main config file lives at:

- macOS/Linux: `~/.niffler/config.yaml`
- Windows: `%APPDATA%/niffler/config.yaml`

Create it with:

```bash
niffler init
```

`niffler init` copies the repository's `default-config.yaml` as a starter template.

## What Lives In `config.yaml`

The main config file is for global runtime settings such as:

- `models`
- `database`
- `master`
- `agents`
- `mcp_servers`
- `current_theme`
- `markdown_enabled`
- `agent_timeout_seconds`
- `default_max_turns`
- `config`

The default template is documented inline, so it is the best reference for field names and comments.

## Active Config Directories

Niffler also uses a named config directory for prompt content and markdown-based agent definitions.

Examples:

- `~/.niffler/default/`
- `~/.niffler/myteam/`
- `.niffler/default/` inside a project

These directories hold files such as:

- `NIFFLER.md`
- `agents/*.md`

The active config name is selected by the optional `config` field in `config.yaml`.

Example:

```yaml
config: "default"
```

If omitted, Niffler falls back to `default`.

## Resolution Order

For selecting the active config name, Niffler checks:

1. `.niffler/config.yaml` in the current project
2. `~/.niffler/config.yaml`
3. default fallback: `default`

For the active config directory itself, Niffler prefers:

1. project-local `.niffler/<name>/`
2. global `~/.niffler/<name>/`

## Prompt Files

`NIFFLER.md` is the main prompt/instruction file for the active config.

Typical location:

```text
~/.niffler/<active-config>/NIFFLER.md
```

Project-local configs can override it with:

```text
.niffler/<active-config>/NIFFLER.md
```

## Agent Definition Files

Markdown agent definitions live under the active config directory:

```text
~/.niffler/<active-config>/agents/
```

or project-local:

```text
.niffler/<active-config>/agents/
```

These files are the authoritative runtime definition for agent prompt content and tool permissions.

## YAML `agents` Section Versus Markdown Agent Files

Both exist, but they serve different roles.

The YAML `agents` section in `config.yaml` is used for:

- agent IDs and display metadata
- auto-start behavior
- persistent/ephemeral process settings

The markdown files under `agents/*.md` are used for:

- system prompt content
- tool permissions
- markdown-defined agent behavior
- optional per-agent model override from the agent definition

If both are present, the markdown agent definition is the runtime source of truth for the agent itself.

## Switching Configs During A Session

The active config can be changed in memory with the `/config` command.

Examples:

```text
/config
/config default
/config myteam
```

This does not rewrite `config.yaml`; it only changes the current session.

## MCP Servers

MCP servers are configured in `config.yaml` under `mcp_servers`.

Example:

```yaml
mcp_servers:
  filesystem:
    command: "npx"
    args:
      - "-y"
      - "@modelcontextprotocol/server-filesystem"
      - "/path/to/workspace"
    enabled: true
```

See [MCP_SETUP.md](MCP_SETUP.md) for more.

## Related Docs

- [../README.md](../README.md)
- [MODELS.md](MODELS.md)
- [TASK.md](TASK.md)
- [MCP_SETUP.md](MCP_SETUP.md)
