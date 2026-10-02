# Niffler

[English](README.md) · [简体中文](README.zh.md) · [繁體中文](README.zh-TW.md) ·
[website](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler is a minimal, self-extending agent harness. Core and every capability
run as separate processes and communicate with JSON envelopes over NATS. The
agent can build and spawn new components while a conversation is running.
Niffler is designed to run from its own clone, which is the harness instance's
home.

## Why Niffler

- **Modular to the process boundary.** Like Pi and DeepSeek Harness, but one
  level lower: every capability is its own OS process behind one wire
  protocol (JSON envelopes over NATS), and the agent builds, spawns and
  removes components mid-conversation — no teardown code, no leaked
  children. See [ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Batteries included.** `fabric` (programmable tool calls), `agent`/`expert`
  (subagents and an advisory peer), `git`, `mcp`, `lsp`, `repomap` (Aider's
  tree-sitter + PageRank port), `skills`, `plugins`, `processes`,
  `observe`/`logfile` — work other harnesses leave to plugins. See the
  [shipped components](docs/MANUAL.md#shipped-components).
- **Opt-in experiments stay opt-in.** `jev` (advisory discovery over a local
  decision model) ships in the manifest as an inert on-demand advisor, and its
  runtime is a supervised launcher you enable with a spawn record — no
  heavyweight dependency is ever forced on a stock `make build`/`make setup`.
  See [Advisory discovery](docs/MANUAL.md#advisory-discovery-jev-and-the-von-launcher).
- **Open models, all providers.** Any OpenAI-compatible endpoint — local,
  open-weight or hosted — via `.env` or a store-backed provider registry;
  ChatGPT/Claude subscription OAuth and a models.dev-backed catalog. See
  [providers](docs/MANUAL.md#provider-registry-provider) and the
  [model catalog](docs/MANUAL.md#model-catalog-models).
- **Progressive tool disclosure.** A small, frozen direct toolset; everything
  else is one `discover`/`invoke` away, appended as history instead of prompt
  bloat. See [MANUAL](docs/MANUAL.md#progressive-tool-discovery).
- **The human stays in the loop.** Approval-gated tools with manifest digests
  and a per-conversation `ask`/`auto` mode; with no human reachable the call
  is denied, never silently allowed. See [approvals](docs/MANUAL.md#approvals).
- **Polyglot.** Mostly Nim and Go, but no component is bound to a language:
  SDKs for Nim, Go and TypeScript, and a shipped bash demo with no SDK at
  all. See [ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **The bus is the API.** `niffler-tui`, `cli` and `console`
  are equal bus clients; several can attach at once and each builds and
  installs independently (the TUI is its own plugin). See
  [starting and stopping](docs/MANUAL.md#starting-and-stopping).
- **Built for long runs.** Frozen prompt/tool prefixes keep prompt caches
  warm; durable compaction and bounded overflow recovery keep sessions alive;
  soft `/limit` budgets sit beside a hard runaway guard. See the
  [context window](docs/MANUAL.md#context-window).
- **Local-first, clone-as-instance.** Conversations and component state live
  in `var/` (SQLite by default) and the harness runs its own NATS bus, with
  no central service. See [layout](docs/MANUAL.md#layout-of-a-running-system).

The current release is [v0.3.0](https://github.com/gokr/niffler/releases/tag/v0.3.0).
See [CHANGELOG.md](CHANGELOG.md) for changes since that release.

## Quick start

Requirements: Nim 2.2.12+ and Go. `make setup` installs those and the other
platform prerequisites (Ubuntu/macOS) plus the Nimble dependencies. Node.js 20+
and npm are needed only for TypeScript components. Niffler uses the pure-Nim
[natsnim](https://github.com/gokr/natsnim) client; no `libnats` or `cnats`
installation is needed.

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

A Wails-based desktop UI does exist, but it is an **experimental side project**
in its own repository — [gokr/niffler-ui](https://github.com/gokr/niffler-ui).
It is unmaintained right now and behind `niffler-tui`, so this harness neither
builds, installs nor tests it (`make install-ui` is gone; `cli install
gokr/niffler-ui` can still fetch it as a package if you want to poke at it).

`make doctor` inspects prerequisites; `make down-here` stops only this clone's
processes.

Testing is covered by the command table below: `make test` is the complete
gate.

## Commands

Everything below is a `make` target (the Makefile is the front door); the
desktop UI is a plugin (`gokr/niffler-ui`), so its own build targets live there.

| Command | What it does |
|---|---|
| `make setup` | platform prerequisites (Ubuntu/macOS) plus the Nimble dependencies |
| `make build` | core + all components into `var/bin` (no UI toolchain) |
| `make all` | `build` (the default target; the desktop UI is its own plugin now) |
| `make run` | build, then start `./var/bin/niffler` (the terminal admin shell) |
| `make install` | PATH entries for `niffler`, `niffler-cli`, `niffler-console`, plus `niffler-tui` on request |
| `make install-tui` | `make install WITH_TUI=1`: the above plus the `niffler-tui` chat client |
| `make install-ui` | build + install the desktop UI plugin (`gokr/niffler-ui`) and its launcher |
| `make install-lsp` | install the default language servers for the `lsp` component |
| `make dev` | retired: the SPA dev server lives in `gokr/niffler-ui` (`make dev` there) |
| `make test` | the complete gate: the bus-contract suite (the UI's own tests and typecheck live in `gokr/niffler-ui`) |
| `make test-server` | the bus-contract suite (each test owns a private NATS + `NIF_ROOT`) |
| `make test-<name>` | one component's contract test, e.g. `make test-fetch` |
| `make gotest` | Go unit tests and vet (`-race` where it matters) |
| `make clean` | remove build artifacts (never `rm -rf var` by hand) |
| `make down` | stop stray harnesses, components and bus processes anywhere on the machine |
| `make down-here` | the same, scoped to this checkout — bench worktrees and other clones survive |
| `make recover` | stop everything, rebuild the shipped binaries, wipe spawned-component records, restart |
| `make doctor` | check prerequisites and report what is missing |
| `make uninstall` | remove the installed PATH entries |
| `make ram` | report the RAM of the running stacks (harness, components, bus, clients) |
| `make install-jev` | install the Von runtime behind the optional `jev` advisor (~5.4 GB) |
| `make smoke` | legacy one-shot end-to-end script (prefer `make test`) |

### Chat commands (web UI and `niffler-tui`)

Type `/` in the composer — `Tab` completes. `/help` prints the list below
live, with each command's arguments and every key combo. The built-ins are:
`/components`, `/discover`, `/profile`, `/provider`, `/model`, `/effort`,
`/approvals`, `/limit`, `/compact`, `/connect`, `/status`, `/new`, `/session`,
`/think`, `/tools`, `/locale`, `/info` and `/help`; commands contributed by
installed plugins are listed by `/help` under their own heading.

### Admin shell (`niffler`)

`niffler` is not a chat UI: it runs `help`, `status`, `catalog`, `tools`,
`sessions`, and `exit`/`quit` (or `Ctrl-D`). Conversations run in
`niffler-tui` and the desktop UI; scripting goes through `niffler-cli`
(`catalog` / `wait` / `call` / `install`).

## Keyboard shortcuts

Web UI (desktop app and browser):

| Keys | Where | What |
|---|---|---|
| `Enter` / `Esc` | composer | send the message (`Esc` first dismisses an open completion popup) |
| `Shift+Enter` | composer | newline instead of sending |
| `↑` / `↓` | composer | walk command history; the unsent draft is preserved |
| `Tab` / `Shift+Tab` | `/…` in the composer | open slash completion / cycle the candidates |
| `Enter` / `Esc` | completion popup | accept the highlighted command / dismiss the popup |
| `Ctrl+T` | anywhere | cycle the reasoning display: full → brief → off |
| `Ctrl+E` | anywhere | cycle tool cards: brief → full → off |
| `Ctrl+G` | anywhere | cycle the thinking effort |
| `Enter` / `Esc` | approval prompt | approve / deny a gated tool call |

The admin shell follows the terminal instead: `↑`/`↓` line history, `Tab`
completion, `Ctrl-D` (or `exit`/`quit`) to leave, `Ctrl-C` to interrupt.
`niffler-tui` keeps the same `Ctrl+T` / `Ctrl+E` / `Ctrl+G` display cycles.

## Documentation

- [Manual](docs/MANUAL.md) — installation details, configuration, tools,
  providers, UIs, recovery, testing and troubleshooting (also
  [简体中文](docs/MANUAL.zh.md) · [繁體中文](docs/MANUAL.zh-TW.md)).
- [Wire protocol](docs/WIRE.md) — JSON envelopes, subjects, errors,
  cancellation and session context.
- [Architecture](docs/ARCHITECTURE.md) — why core, components and NATS are
  separate, and the invariants contributors must preserve.
- [Open work](docs/PLAN.md) — current deferred work.
- [Research index](docs/research/README.md) — design history and prior-art
  studies; research notes are not operating instructions.
- [Fabric guide](docs/FABRIC_GUIDE.md) — programmable orchestration and
  subagents.
- [Model source plugins](docs/MODEL_SOURCES.md) — worked example of a
  catalog-correcting component.
- [Settings design](docs/research/SETTINGS.md) — settings work that is not yet shipped.

## Developing components

Nim, Go and TypeScript components use the SDKs in `sdk/`. The normal extension
path is: write source, call `build`, then call `spawn`. Read the
[component lifecycle](docs/MANUAL.md#self-extension-and-component-lifecycle),
the [wire contract](docs/WIRE.md), and [AGENTS.md](AGENTS.md) before changing
architecture or adding a component.

Community components are installed through the `plugins` component; see the
[plugin section of the manual](docs/MANUAL.md#component-ecosystem-plugins).

## Philosophies

- **Open models, all providers.** Local, open-weight and hosted models get the
  same first-class path: an OpenAI-compatible default, subscription OAuth
  where a vendor offers nothing else, and a models.dev-backed catalog that
  keeps limits, capabilities and prices as data. Adding an
  OpenAI-compatible provider is a config entry, not a code path.
- **Improvements are measured, not asserted.** `bench/` runs Niffler against
  pi, opencode, CodeWhale and Claude Code on the same tasks and models,
  comparing time-to-green, token cost and patch quality across the full31,
  SWE-bench Verified and DeepSWE suites. Features land on that evidence — and
  sometimes only behind a gate, like the repo map's auto-append, which ships on
  by default but withholds small or stub maps because the A/Bs disagreed — with
  reports committed under `bench/reports/`.
- **Chinese is a first-class language here.** The READMEs are English,
  Simplified and Traditional Chinese, and the web UI is fully localized
  (`en`/`zh`/`zh-TW`) with typed catalogs — a missing translation fails
  typecheck.
- **Stealing with pride and gratefulness.** We take the best ideas we can find
  in other harnesses — Pi, DeepSeek Harness, CodeWhale, OpenCode, Reasonix,
  Aider, OpenHands, … — and re-check each against Niffler's invariants before
  it ships. The studies name their source and pinned commit, vendored code
  keeps its license, and everything lives in
  [docs/research/](docs/research/).
