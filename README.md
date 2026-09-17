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
  orchestrate tools), `agent` (subagents: background, continuable and
  forkable), `expert` (an advisory peer), `git`, `mcp` (external MCP
  servers), `lsp` (any language server, configured as data), `repomap`
  (Aider's [repo map](https://github.com/Aider-AI/aider): a tree-sitter
  symbol graph ranked by PageRank), `skills`, `plugins`, `processes`
  (background jobs), `fetch`, `grep`, `edit`, plus `observe`/`logfile` for
  the bus itself.
- **Focused on open models.** One adapter, no vendor lock-in: the default
  `openai-chat` protocol speaks plain Chat Completions, so any
  OpenAI-compatible endpoint works — DeepSeek, OpenRouter, a local
  vLLM/llama.cpp/Ollama server — configured through `.env` or the
  store-backed `provider` registry and switchable at runtime. Anthropic
  Messages and ChatGPT/Claude subscription OAuth are supported when you want
  a hosted model.
- **Subscriptions work, and model data is first-class.** Sign in with
  ChatGPT Plus/Pro or Claude Pro/Max — browser PKCE, or a device code on a
  headless box, with tokens refreshing automatically — instead of buying API
  credits; or register any API-key provider and switch it live. The `models`
  layer resolves limits, context windows and prices from models.dev, an
  offline seed and override layers, and each conversation pins its own model
  and thinking effort.
- **Progressive tool disclosure.** Each conversation gets a small, frozen
  direct toolset; everything else stays one `discover`/`invoke` away.
  `discover` returns a tool's schema as an ordinary tool result (appended
  history, not prompt bloat), `invoke` is the fixed gateway that calls it,
  and on-demand components — `git`, `mcp`, `agent`, `lsp`, … — cost nothing
  until the model asks for them.
- **The human stays in the loop.** Tools can require approval, and the
  request carries a manifest with a source digest, so "always allow" can be
  scoped to that exact tool content. Each conversation picks its gate mode
  (`/approvals ask|auto`), and when no human is reachable the call is denied —
  never silently allowed.
- **Polyglot by construction.** Most of Niffler is Nim and Go, but no
  component is tied to a language: the contract is JSON envelopes over NATS,
  SDKs exist for Nim, Go and TypeScript, and the shipped
  [`dialog`](components/dialog/dialog.sh) demo is a bash script with no SDK
  at all. The same neutrality points inward — language servers, file patterns
  and toolchains are declarative config or plugin components, never changes
  to shared components.
- **The bus is the API.** Every client — the `niffler-tui` terminal client,
  the web UI, `niffler-cli` scripts and CI, `niffler-console` — is just
  another bus citizen: anything that speaks JSON envelopes can observe,
  script or drive conversations.
- **UIs are just bus clients.** A client holds no conversation state of its
  own, so several can attach to one harness at the same time — the terminal
  client, the desktop app, your own scripts — and each UI builds and installs
  independently. The desktop UI ships in this repo (`make install-ui`); the
  terminal client is a plugin from a separate repo,
  [gokr/niffler-tui](https://github.com/gokr/niffler-tui), installed by
  `make install-tui` — the proof that a UI is just another component.
- **Cache- and cost-disciplined by design.** A conversation's system prompt
  and direct tool schemas are frozen for its lifetime and history only grows,
  so provider prompt caches keep hitting turn after turn.
- **Long sessions stay alive.** Compaction runs behind a durable context
  projection and checkpoint, provider context-overflow gets bounded recovery,
  and budgets are explicit: the human's soft limits (`/limit rounds=N`) ask
  "keep going?", while the hard `NIF_MAX_TURN_ROUNDS` guard ends a runaway
  turn loudly instead of hanging.
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

## Philosophies

- **Open models, all providers.** Local, open-weight and hosted models get the
  same first-class path: an OpenAI-compatible default, subscription OAuth
  where a vendor offers nothing else, and a models.dev-backed catalog that
  keeps limits, capabilities and prices as data. Adding an
  OpenAI-compatible provider is a config entry, not a code path.
- **Improvements are measured, not asserted.** `bench/` runs Niffler against
  pi, opencode, CodeWhale and Claude Code on the same tasks and models,
  comparing time-to-green, token cost and patch quality across the full30,
  SWE-bench Verified and DeepSWE suites. Features land on that evidence — and
  sometimes stay off it, like the repo map's auto-append, which ships disabled
  because the A/Bs disagreed — with reports committed under `bench/reports/`.
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
