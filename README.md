# Niffler

[English](README.md) · [简体中文](README.zh.md) · [繁體中文](README.zh-TW.md) ·
[website](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler is a minimal, self-extending agent harness. Core and every capability
run as separate processes and communicate with JSON envelopes over NATS. The
agent can build and spawn new components while a conversation is running.
Niffler is designed to run from its own clone, which is the harness instance's
home.

The current release is [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0).
See [CHANGELOG.md](CHANGELOG.md) for changes since that release.

## Quick start

Requirements: Nim 2.2.12+, Go, Node.js 20+ and npm. The desktop UI additionally
needs Wails and WebKitGTK 4.1 on Linux. Niffler uses the pure-Nim
[natsnim](https://github.com/gokr/natsnim) client; no `libnats` or `cnats`
installation is needed.

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                         # Ubuntu/macOS prerequisites and Nimble deps
cp .env.example .env               # add an LLM API key; edit other settings as needed
make                                # core, components and desktop UI
./ui/build/bin/niffler-ui           # the UI starts the local harness
```

For a component-only build, use `make build`. `./var/bin/niffler` is the
terminal admin shell (not the conversation UI); `./var/bin/niffler --minimal`
starts only the minimal store/bash/LLM profile. Run `make doctor` to inspect
prerequisites. Use `make down-here` to stop only this clone's processes.

To run the frontend in a browser during development:

```bash
make dev
```

The UI is optional. `make test-ui` runs frontend tests without NATS;
`make test-server` runs the bus-contract suite; `make test` runs the complete
gate. `make gotest` runs the Go tests, vet and race checks.

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
