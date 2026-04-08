# Changelog

All notable changes to this project from January 1st, 2026.

## [Unreleased]

### 2026-04-08

#### Documentation
- Clarify build and runtime requirements
- Refresh landing page and workflow guides

### 2026-04-07

#### Features
- Auto-register plan files created in plan mode
- Add plan file creation instructions to Plan mode

#### Bug Fixes
- Fix Discord routing and strengthen skill loading requirements

### 2026-04-06

#### Refactoring
- Drop config agents section and persistent agent flag
- Move agent runtime config into markdown frontmatter

### 2026-04-05

#### Features
- Add plan file support and config directory initialization
- Show mode indicator in Master mode prompt
- Add planFilePath field to conversation database
- Implement Discord routing via NATS from agents to Master
- Add agent-aware Discord routing and /tools command

#### Bug Fixes
- Enforce plan workflow and align conversation queries

#### Refactoring
- Simplify templates to single NIFFLER_TEMPLATE
- Update Discord tool with centralized access control

### 2026-04-04

#### Features
- Enhance skill tool with nested skill support and resource operations
- Add nested skills support with child skills and resources
- Add config field to default config template
- Add action handlers for skill and discord commands
- Add agent capabilities support
- Add developer message support
- Add localOnly flag for action commands
- Implement skill tool
- Add core skill types and discovery system
- Integrate skills into system prompt
- Add /skill CLI commands

#### Bug Fixes
- Fix: Add config field to default config template

#### Refactoring
- Clean up system prompt templates and add skills guidance
- Minor cleanup and refactoring

#### Tests
- Support local MySQL in test database helpers
- Add action capabilities and dispatch tests
- Add skill system tests

#### Documentation
- Update documentation for deprecated template variables
- Update test README with skills and actions tests
- Update documentation for skills system and capabilities
- Add ACTIONS.md documenting action system

### 2026-04-03

#### Features
- Register orchestration tools for agents
- Add orchestration tools for agent management
- Improve Discord routing and master relay flow

#### Refactoring
- Unify agent actions and help metadata

#### Bug Fixes
- Align agent config storage and agent tests

#### Documentation
- Clarify multi-agent agent-definition behavior

### 2026-04-02

#### Features
- Integrate Discord with master mode
- Add todolist completion reminder to prevent premature task termination

#### Bug Fixes
- Start Discord bot immediately when /discord enable is run
- Correct help formatting and command usage strings
- Use .items for JsonNode iteration in Discord commands
- Restore dependency comments in nimble file
- Use conversation-scoped todolists instead of global

#### Refactoring
- Improve Discord UX - token/configure/enable flow
- Consolidate tests and add testament test groups

#### Chores
- Minor cleanup and import fixes
- Reorganize documentation structure
- Clean up repo root
- Update .gitignore for compiled binaries

#### Documentation
- Make todolist comment database-agnostic
- Update comments to reflect generic MySQL support
- Update documentation for swarm architecture and Discord setup

### 2026-04-01

#### Features
- Add cancel request support for stopping running tasks

#### Bug Fixes
- Fix compilation after cherry-pick: add missing imports, remove AgentMessage references
- Fix merge: restore NATS files, fix agents command placeholder

#### Merges
- Merge niffler-nats: Keep NATS, add autonomous agent tables, Discord integration

#### Documentation
- Update README with new multi-agent architecture and Discord integration

### 2026-03-31

#### Bug Fixes
- Correct agent timeout calculation after sleep change
- MySQL compatibility - wrap index creation in try/except
- Revert complex database connection pool changes

#### Debug
- Add tracing to /context command to find hang point

#### Features
- Add DB debug logging to track pool blocking

### 2026-03-30

#### Features
- Add automatic database connection resilience for TiDB Cloud

#### Bug Fixes
- Improve database connection resilience with health checks
- Handle empty agent responses and show completion indicator
- Fix MCP startup blocking and repair README

#### Improvements
- Improve LM Studio tool and thinking compatibility

#### Documentation
- Tweaked README
- Refresh default config and streamline docs

#### Chores
- Various merges and repository maintenance

### 2026-03-29

#### Bug Fixes
- Fix agent presentation workflow for NATS demo

#### Refactoring
- Use package-based linecross imports

### 2026-02-20

#### Features
- Integrate task queue with existing task execution system
- Add Discord bot integration with dimscord

#### Documentation
- Add Discord bot setup documentation

### 2026-02-19

#### Features
- Add autonomous agent architecture modules
- Add autonomous agent database schema

#### Documentation
- Add transformation planning and progress documentation
- Add comprehensive architecture map

#### Updates
- Update entry point and README for autonomous agent
- Update UI for autonomous agent mode

#### Refactoring
- Refactor agent manager for database-based communication

## Summary Statistics

- **Total commits**: 100
- **Date range**: 2026-02-19 to 2026-04-08
- **Main contributors**: Göran Krampe

### Categories
- Features (feat): ~45 commits
- Bug fixes (fix): ~25 commits
- Documentation (docs): ~15 commits
- Refactoring (refactor): ~10 commits
- Tests (test): ~5 commits
- Chores (chore): ~5 commits

### Major Themes

1. **Skills System** - Complete implementation of skill types, discovery, nested skills, and CLI commands
2. **Multi-agent Architecture** - Autonomous agents with NATS messaging, Discord routing, and orchestration tools
3. **Plan Mode** - Plan file support, workflow enforcement, and mode indicators
4. **Discord Integration** - Bot setup, routing, master mode integration, and UX improvements
5. **Database Resilience** - Connection pooling, health checks, and TiDB Cloud support
6. **Action System** - Capability handlers, command dispatch, and agent actions
