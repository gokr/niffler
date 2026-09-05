---
name: niffler-harness
description: Operational guide to the running Niffler harness itself — lifecycle and boot profiles, session runners, the store and how to read conversations out of it, self-extension end-to-end, bus debugging (console, cli, observe, logfile), plugins, skills, approvals and recovery. Load when driving, configuring, recovering or debugging the harness rather than doing a task inside it.
---

# Niffler harness — operating the thing itself

Niffler is a self-extending harness: a system core plus one process per
component, speaking JSON envelopes over NATS. This skill covers operating and
debugging that machinery; `niffler-tools` is the which-tool-for-the-job map
and `niffler-fabric` is how to program tools. The repo snapshot is the source
of truth; `var/` is disposable runtime state (remove artifacts with
`make clean`, never a bare `rm -rf var`).

## Lifecycle

- `make run` (or `./var/bin/niffler`) — the tty is an **admin shell**
  (help/status/catalog/tools/sessions), not a chat UI. Chat lives in the web
  UI and the niffler-tui plugin; scripting goes through the `cli` component.
- `--minimal` — boot profile, not a lockdown: only `store`, `bash`, `llm`
  start; persisted spawned components are not restored (their store records
  remain and a normal boot restores them).
- `--recover` (`make recover`) — stop everything, rebuild shipped binaries,
  wipe spawned-component records, restart.
- `make down` — stop stray harnesses/components and nats-server. Run it when
  a fresh store refuses to start (a detached core holds
  `var/barrel-db.lock`) or before a cold start.
- Autostart: a UI's first act is the SDK's `ensureHarness` — probe env →
  `var/nats-url` → `127.0.0.1:4222`, else spawn core with `NIF_AUTOSTART=1`.
  An autostarted core exits when the last interactive client departs
  (idle 10 s) or none arrives (boot grace 60 s). Manually started cores
  never self-terminate.
- One conversation = one process: an ephemeral session runner
  (`var/bin/session <id>`, restart `never`) that resumes from the store —
  killing it loses only the in-flight turn. Missing binary → `make build`.
- When a supervised child dies, the supervisor shows the tail of
  `var/logs/<name>.log` — look there first.

## The store

Document store over the bus: `put/get/list/del` with rev-based optimistic
concurrency. Engines register as the same component `store` with identical
tools (boot-time `NIF_STORE_BACKEND=barrel|sqlite|tidb`); consumers never
learn which is live. File engines are single-writer — never run two stores
against one file. Kinds include `conversation`, `message`, plugin install
records, the provider registry — and your own durable state.

Reading a conversation while a harness is on the bus:

```bash
./var/bin/cli call list '{"kind":"conversation"}'
./var/bin/cli call list '{"kind":"message","idPrefix":"<convId>:","limit":1000}'
./var/bin/cli call get '{"kind":"conversation","id":"<convId>"}'
```

Mind which store answers — the bus may host another harness's store
(`readlink /proc/$(pgrep -f bin/store | head -1)/cwd` shows which db it
owns). Offline, values are plain JSON inside `var/barrel-db`.

## Self-extension end-to-end

write source → `builder.build` (Nim/Go/TS; a Go component gets its
`go.mod` `replace` wired automatically) → `core.spawn` (approval-gated) →
`discover` → `invoke`.

- `replicas: N` (1–16) only for stateless or externally coordinated
  components (existing NATS queue group); never for single-writer state
  (`store`, `edit` undo).
- `core.kill` stops a group temporarily; `core.remove` also deletes the
  persisted record (it will not come back on boot).
- Tool names are globally unique — core rejects duplicate registration.
- `manifest.yaml` is the bootstrap set; `--minimal` filters it to
  store/bash/llm.

The `x-harness.*` schema extensions core honors:

| Key | Effect |
|---|---|
| `hidden` | tool invisible to the LLM (e.g. `chat`) |
| `onDemand` | kept out of the frozen direct set; reachable via discover+invoke |
| `approval` | enforced human gate (terminal y/N; UI broadcast; `NIF_AUTO_APPROVE=1` bypasses — headless only) |
| `timeoutMs` | per-tool timeout |
| `effect` | `"read"` (parallel) vs `"write"` (exclusive) in the fabric batch host |
| `sessionId` | runner injects `__session.session` for cancel matching |
| `sessionContext` | injects live `__session` + nested-call lease |
| `noSpawn` | subagents cannot spawn subagents |
| `workspace` | path-shaped args resolve against the conversation workspace |

## Debugging the bus

- `./var/bin/console` — subscribes `>` and renders every envelope readably;
  run it in a second terminal to follow any harness activity live.
- `./var/bin/cli` — scriptable driver: `catalog` / `wait <comp>` /
  `call <tool> '<json>'` / `install <repo>[@<ref>]`, exit 0 on success.
  One-shot turn probe without any UI (needs an API key):
  `cli call session '{"sessionId":"probe-x","content":"Ping"}'`.
- `catalog {op: list}` — catch bad registrations (each `schema.type` must be
  `"object"`); `doctor` — one-shot health probe; `status` — live processes.
- `observe` / `logfile` — bounded live ring + probes; rotating JSONL with
  bounded search (`ev.log.expert` carries the expert peer's judgments). For
  debugging the harness itself, not the task.
- Prompt-cache discipline: the request prefix — frozen system prompt + frozen
  direct tool schemas — must stay byte-stable for the conversation's
  lifetime; history only grows. Never splice a volatile fact (time, a file
  edit, a catalog change) into the head; append it as a new message.
  `ev.session.context` reports `cacheHitTokens`/`cacheHitRatio`; the only
  legitimate full miss is a trim (`reason: "reset:trim"`).

## Plugins and skills

- Plugins: `plugin_search` → `plugin_install` (clone into
  `var/plugins/<pkg>@<ref>`, build from source, spawn service components) →
  `plugin_update` / `plugin_remove`. Records live under store kind `plugin`;
  `"interactive": true` packages are built but not spawned (start them
  manually, e.g. niffler-tui). Clones honor `NIF_GIT_MIRROR`.
- Skills: discovery order project → bundled → home → config (first match per
  name wins); bundled (`skills/` in the repo) are never removable.
  `skill_audit` shows shadowed duplicates that `skill_list` hides. Loading a
  skill appends to the conversation history — it never changes the frozen
  prefix.

## Config and secrets

`.env` (repo root, gitignored) holds local config; existing shell env always
wins, and components load it from cwd then `$NIF_ROOT`. Every harness
variable carries the `NIF_` prefix (`NIF_OPENAI_*`, `NIF_NATS_URL`,
`NIF_STORE_BACKEND`, …) — full table in docs/MANUAL.md. Never commit
`.env`; never put secrets in store documents or task prompts.

## Recovery cheatsheet

| Symptom | Action |
|---|---|
| Boot fails, store refuses to start | `make down` (stale core holds the barrel-db flock), check `var/logs`, restart |
| Child component keeps dying | read the supervisor's `var/logs/<name>.log` tail; `make build` if the binary is stale |
| Spawned components misbehave | `core.kill <name>` (temporary) or `core.remove` + respawn |
| Broken build state | `make recover` (rebuild + wipe spawn records) |
| Orphaned NATS after killing components | `make down` before a cold start |
| Conversations look lost | they are not — read them from the store (recipe above) |
