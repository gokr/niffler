# Niffler

[English](README.md) · [简体中文](README.zh.md) · [繁體中文](README.zh-TW.md) ·
[website](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler is a minimal, self-extending agent harness. Core and every capability
run as separate processes and communicate with JSON envelopes over NATS. The
agent can build and spawn new components while a conversation is running.
Niffler is designed to run from its own clone, which is the harness instance's
home.

## Why Niffler

- **Modular and extensible to the process boundary.** Niffler shares the
  minimal-harness philosophy of [Pi](https://pi.dev) and
  [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), but
  takes it one level lower: every capability is its own OS process behind a
  single wire protocol (JSON envelopes over NATS), not an in-process plugin.
  The agent writes, builds and spawns new components mid-conversation, swaps
  implementations at runtime, and removes one with `core.kill` — no teardown
  code, no leaked children.
- **More batteries included.** Shipped components cover work other harnesses
  leave to third-party plugins: `fabric` (the model writes Nim programs that
  orchestrate tools), `agent`/`expert` (subagents and an advisory peer),
  `git`, `mcp` (external MCP servers), `lsp` (any language server, configured
  as data), `skills`, `plugins`, `repomap`, `processes` (background jobs),
  `fetch`, `grep`, `edit`, plus `observe`/`logfile` for the bus and
  `models`/`provider` for LLM access.
- **Language-agnostic by construction.** SDKs in Nim, Go and TypeScript;
  adding support for a language is a config entry or a plugin component,
  never a change to shared components.
- **The bus is the API.** Every client — the `niffler-tui` terminal client,
  the web UI, `niffler-cli` scripts and CI, `niffler-console` — is just
  another bus citizen: anything that speaks JSON envelopes can observe,
  script or drive conversations.
- **Cache- and cost-disciplined by design.** A conversation's system prompt
  and direct tool schemas are frozen for its lifetime and history only grows,
  so provider prompt caches keep hitting; large toolsets stay reachable
  through `discover`/`invoke` instead of inflating every request.
- **Local-first, clone-as-instance.** The clone is the instance: conversations
  and component state live in `var/` (SQLite by default), the harness manages
  its own NATS bus, and there is no central service to depend on.

The current release is [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0).
See [CHANGELOG.md](CHANGELOG.md) for changes since that release.

## Quick start

Requirements: Nim 2.2.12+ and Go. `make setup` installs those and the other
platform prerequisites (Ubuntu/macOS) plus the Nimble dependencies. Node.js 20+
and npm are only needed for TypeScript components and the web UI; the optional
desktop UI additionally needs Wails and WebKitGTK 4.1 on Linux. Niffler uses the
pure-Nim [natsnim](https://github.com/gokr/natsnim) client; no `libnats` or
`cnats` installation is needed.

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                    # Ubuntu/macOS prerequisites and Nimble deps
cp .env.example .env          # add an LLM API key; edit other settings as needed
make build                    # core + components (no UI toolchain)
make install-tui              # PATH entries + the niffler-tui terminal client
niffler-tui                   # terminal chat; boots this clone's harness
```

`make install-tui` is `make install WITH_TUI=1`: it links `niffler`,
`niffler-cli`, `niffler-console` and the `niffler-tui` wrapper into a user bin
directory (`NIF_BIN_DIR=~/bin` overrides the location) and installs the
[niffler-tui](https://github.com/gokr/niffler-tui) plugin. Plain `make install`
asks about the plugin on a terminal instead.

`niffler-tui` is the conversation client; `niffler` (or `./var/bin/niffler`) is
the terminal admin shell — status, catalog, sessions, not a chat UI — and
`niffler --minimal` boots only the minimal store/bash/LLM profile.

The desktop UI is optional:

```bash
make install-ui         # build the Wails UI, then add it to ~/.local/bin with
                        # a launcher entry and icon (Linux; alias: make ui-install)
```

`make dev` runs the frontend in a browser with the bridge stubbed; `make doctor`
inspects prerequisites; `make down-here` stops only this clone's processes.

Testing: `make test-ui` runs frontend tests without NATS; `make test-server`
runs the bus-contract suite; `make test` runs the complete gate; `make gotest`
runs the Go tests, vet and race checks.

## Documentation

- [Manual](docs/MANUAL.md) — installation details, configuration, tools,
  providers, UIs, recovery, testing and troubleshooting.
- [Wire protocol](docs/WIRE.md) — JSON envelopes, subjects, errors,
  cancellation and session context.
- [Architecture](docs/ARCHITECTURE.md) — why core, components and NATS are
  separate, and the invariants contributors must preserve.
- [Open work](docs/PLAN.md) — current deferred work.
- [Research index](docs/research/README.md) — design history and prior-art
  studies; research notes are not operating instructions.
- [Fabric guide](docs/FABRIC_GUIDE.md) — programmable orchestration and
  subagents.
- [Settings design](docs/SETTINGS.md) — settings work that is not yet shipped.

## Developing components

Nim, Go and TypeScript components use the SDKs in `sdk/`. The normal extension
path is: write source, call `builder.build`, then call `core.spawn`. Read the
[component lifecycle](docs/MANUAL.md#self-extension-and-component-lifecycle),
the [wire contract](docs/WIRE.md), and [AGENTS.md](AGENTS.md) before changing
architecture or adding a component.

Community components are installed through the `plugins` component; see the
[plugin section of the manual](docs/MANUAL.md#component-ecosystem-plugins).
