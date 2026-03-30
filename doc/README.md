# Niffler Documentation

This directory now keeps the current, user-facing documentation for the `niffler-nats` branch.

## Start Here

- [../README.md](../README.md): installation, first run, TiDB playground, and quick start
- [CONFIG.md](CONFIG.md): config file layout, active config directories, and prompt files
- [MODELS.md](MODELS.md): model entries, credentials, local models, and provider examples

## Core Guides

- [TASK.md](TASK.md): master mode, agent mode, `@agent`, and agent definition files
- [TOOLS.md](TOOLS.md): built-in tools and MCP-discovered tools
- [MCP_SETUP.md](MCP_SETUP.md): how to configure MCP servers in `config.yaml`
- [EXAMPLES.md](EXAMPLES.md): common workflows and command examples
- [ARCHITECTURE.md](ARCHITECTURE.md): implementation-level system overview
- [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md): TiDB tables and persisted data
- [THINK.md](THINK.md): reasoning/thinking token behavior
- [TOKEN_COUNTING.md](TOKEN_COUNTING.md): token estimation and cost tracking

## Research And Historical Material

Older design notes, roadmap material, experiments, and superseded reference docs live under [research/](research/).

This includes:

- `research/ADVANCED_CONFIG.md`
- `research/CCPROMPTS.md`
- `research/DEVELOPMENT.md`
- `research/MCP.md`
- `research/TOKENS.md`
- `research/TOKENIZER.md`
- existing research notes already in `research/`

## Notes

- The docs in this directory should describe current behavior in this branch.
- Research docs may be historically interesting, but are not guaranteed to match the current implementation.
