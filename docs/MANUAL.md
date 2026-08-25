# Niffler Manual

Everything you need to operate, configure and recover a Niffler harness.
Design rationale: [REBOOT.md](REBOOT.md) · wire protocol: [WIRE.md](WIRE.md) ·
architecture boundary: [ARCHITECTURE.md](ARCHITECTURE.md) · model catalog:
[MODELS.md](MODELS.md) · observation/logging: [OBSERVE.md](OBSERVE.md).

## Layout of a running system

| Path | What it is |
|---|---|
| `core/` | the control plane: system harness (`niffler.nim`: bus bootstrap, supervisor, catalog, dispatch) + session runner (`session.nim`: one process per conversation, the conversation loop) |
| `components/` | shipped component sources: `bash`, `builder`, `store`, `plugins`, `skills`, `fetch`, `hashline-edit`, `grep`, `write`, `observe`, `logfile`, `cli`, `console` (Nim), `models`, `provider` and `llm` (Go) |
| `sdk/` | Nim SDK (`sdk/niffler`) + `sdk/go` (Go) + `sdk/ts` (TypeScript/Node.js, npm package `niffler-sdk`); the envelope in `sdk/envelope.nim` is the artifact |
| `docs/` | this manual + design docs |
| `manifest.yaml` | bootstrap manifest: which components core spawns, in what order, with what restart policy |
| `var/` | **runtime state, gitignored, disposable** — the repo is the snapshot |
| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |
| `var/barrel-db` | the store's embedded KV file — **single-writer**: exactly one `store` process may open it |
| `var/nats-url` | bus address of the last spawned bus; the UI bridge reads it to find core |
| `var/nats-monitor-url` | HTTP monitoring endpoint when core spawned the bus; absent for reused/remote buses |
| `var/logs/`, `var/captures/` | rotating structured logs and explicit observe probe exports ([OBSERVE.md](OBSERVE.md)) |
| `var/nats-pid` | pid of the bus core spawned (crash cleanup only — a live core stops its own bus on exit) |
| `var/build/` | source files of agent-built components (builder's scratch dir) |
| `nimcache/`, `ui/build/`, `ui/frontend/node_modules/`, `ui/frontend/dist/` | build artifacts; `make clean` removes them |

### Shipped components

| Component | Language | Manifest | What it does |
|---|---|---|---|
| `store` | Nim | required | document store over the bus (`put/get/list/del`, rev-based concurrency) |
| `bash` | Nim | required | the classic tool: shell commands with timeout + output cap |
| `builder` | Nim | required | compiles agent-written Nim/Go source into binaries |
| `llm` | Go | required | streaming OpenAI-compatible chat adapter (hidden `chat` tool; `ev.llm.token` deltas; cancellation) — `llm-openai` in `components/llm-openai` is the minimal non-streaming example, swap it in via `manifest.yaml` |
| `models` | Go | optional | models.dev provider/model catalog, atomic cache, strict resolution, and plugin correction/discovery layers ([MODELS.md](MODELS.md)) |
| `provider` | Go | optional | store-backed LLM provider registry: `provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`, `ev.provider.switch` notifications |
| `plugins` | Nim | optional | ecosystem front door: topic search + install/update/remove of packages |
| `skills` | Nim | optional | Agent Skills (SKILL.md): discovery, load, resource access, git-based install/remove |
| `fetch` | Nim | optional | web content retrieval: http/https, HTML→text extraction, size caps with file spill |
| `hashline-edit` | Nim | optional | hash-anchored file editing: `read`/`replace`/`undo_last_replace` on anchors that stay valid across edits |
| `grep` | Nim | optional | ripgrep-backed search: `grep` (contents, path:line:match) and `files` (sorted listing); .gitignore-aware, no shell quoting needed |
| `write` | Nim | optional | atomic whole-file write: create/overwrite/truncate with permission preservation (approval-gated) |
| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |
| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |
| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring ([OBSERVE.md](OBSERVE.md)) |
| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search ([OBSERVE.md](OBSERVE.md)) |

### Session runners

One conversation = one process (`var/bin/session <sessionId>`), spawned by
the system harness on demand. Clients keep calling `svc.core.call`
(tool `session`); the system ensures a runner per session id and forwards
the turn to `svc.session.<sessionId>.call`. The runner is a supervised
child (restart policy `never`); it announces itself as component
`session-<id>` with zero tools, seeds its catalog from
`catalog {op: snapshot}` at startup, and emits the same `ev.session.*`
events as the classic in-core loop. Sessions are ephemeral: history lives
in the store, so a fresh runner resumes the conversation on the next call.
Killing a runner kills only that conversation — the process is the unit of
isolation. Turns never nest either way.

The stdin/stdout tty (`make run`) is an **admin shell**, not a conversation
UI: it only inspects the harness itself — `help`, `status`, `catalog`,
`tools`, `sessions`, `exit` — with arrow-key history and tab completion
(see `core/tty.nim`). The LLM chat lives in the web UI and the `niffler-tui`
plugin; scripting goes through the `cli` component.

## Environment variables

All components load `.env` (from the harness root and cwd, existing shell
env always wins — see below) and inherit core's environment. The full set:

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | the harness root (repo). Core derives it from its binary location if unset, and sets it for all children. Components use it to find the SDK, `var/`, `.env`. Every component runs with **cwd = NIF_ROOT**, so the agent's `bash pwd` is always the home — regardless of where you launched the harness | `<binary location>/../..` |
| `NIF_NATS_URL` | bus to attach to. Unset → core reuses a live bus on `127.0.0.1:4222`, else spawns `nats-server` there (or on a random loopback port when 4222 is taken) and writes `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` forces core to spawn an isolated loopback bus instead of reusing port 4222 — only when `NIF_NATS_URL` is unset (an explicit URL always wins) | unset |
| `NIF_AUTOSTART` | set by an SDK's `ensureHarness` when a UI had to spawn core: that core exits when the last interactive client departs (see Starting and stopping) | unset |
| `NIF_AUTOSTART_IDLE_S` | seconds after the last interactive departure before an autostarted core exits | `10` |
| `NIF_AUTOSTART_BOOT_S` | seconds an autostarted core waits for its first interactive client before giving up | `60` |
| `NIF_ENSURE_ATTACH` | `0` makes `ensureHarness` skip attaching and always spawn a core (tests) | `1` |
| `NIF_OPENAI_API_KEY` | API key for the LLM adapter (`llm`). Required for any conversation turn | — |
| `NIF_OPENAI_BASE_URL` | OpenAI-compatible endpoint | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | model name | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | models catalog provider id for the default LLM connection; common endpoints are inferred when unset | inferred |
| `NIF_OPENAI_CONTEXT` | explicit context window (tokens) the llm reports to core's context guard | `models` catalog, then `llm` fallback |
| `NIF_LLM_PROVIDERS` | JSON object of named providers `{nickname: {baseUrl, apiKey, model, context, catalog}}` the `chat` tool's `provider` arg resolves; the provider registry (`provider` component) supersedes the default when active | `{}` |
| `NIF_MODELS_URL` | models.dev-compatible catalog base or JSON endpoint | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | pinned local baseline catalog; useful for offline/testing | unset |
| `NIF_MODELS_OVERRIDE` | local JSON Merge Patch applied after every plugin source | unset |
| `NIF_MODELS_OFFLINE` | `1` disables remote catalog refresh | unset |
| `NIF_MODELS_CACHE_DIR` | catalog and source-patch cache | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | minimum age before refetching the baseline | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | background refresh interval; `0` disables | `1h` |
| `NIF_FETCH_DIR` | large fetch results and temporary extraction files | `$NIF_ROOT/var/fetch` |
| `NIF_TRAFILATURA` | Trafilatura executable path/name; `off` disables external extraction | auto-detect `trafilatura` on `PATH` |
| `NIF_LOG_LEVEL` | SDK structured-log publication threshold (`debug`, `info`, `warn`, `error`) | `info` |
| `NIF_OBSERVE_RING` | messages retained in observe's global ring | `2000` |
| `NIF_OBSERVE_RING_BYTES` | approximate wire bytes retained in the global ring | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | maximum retained bytes per observed message | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | active + stopped probes retained at once | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | retained bytes per probe | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | confined directory for `observe_dump` | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | aggregate generated-capture quota; oldest files are pruned | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | explicit nats-server HTTP endpoint for an external/reused bus | core discovery file |
| `NIF_LOGFILE_DIR` | JSONL output directory | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation | `10485760` |
| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables) | `5` |
| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl` | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search` | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query | `10000` |
| `NIF_AUTO_APPROVE` | `1` → the approval gate (below) is bypassed. For headless automation only; never set it in a session you care about | unset |

Every Niffler variable carries the `NIF_` prefix, so the harness never
collides with tools that use the bare conventions (`NATS_URL`,
`OPENAI_API_KEY`).

### The `.env` file

`.env` (repo root, gitignored) holds local secrets/config:

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

Loading rules (identical in the Nim SDK, Go SDK and the UI bridge):
existing shell environment **always wins** over `.env`; `.env` is loaded
from the current directory and from `$NIF_ROOT`, in that order. So
`NIF_OPENAI_API_KEY=other ./var/bin/niffler` overrides the file, and
`unset NIF_OPENAI_API_KEY` before starting if you want the file value.

## The bus in one screen

Core speaks exactly one protocol: JSON envelopes over NATS (details in
[WIRE.md](WIRE.md)). Subjects:

```
reg.publish            component announces itself: {name, version, pid, tools:[{name, schema}]}
reg.depart             graceful shutdown announcement
svc.<component>.call   queue-grouped tool call request/reply
ev.session.assistant   {sessionId, content, model?, usage?}   (complete model text)
ev.session.token       {sessionId, content, reasoning}        (live token deltas)
ev.session.toolcall    {sessionId, tool, args, result|error}
ev.session.done        {sessionId, reply} | {sessionId, error}
ev.session.context     {sessionId, promptTokens, context, warning?|trimmed?}
ev.catalog.updated     direct (prompt-facing) tool projection after any
                       registration change; `catalog {op: snapshot}` still
                       returns everything incl. hidden/on-demand schemas
ev.models.updated      effective provider/model/source counts after refresh
ev.provider.switch     provider component → bus: {nickname, previous, at}
ev.llm.token           llm adapter → core: {sessionId, content, reasoning} deltas
ev.sys.drain           core → components: stop taking calls, finish, exit
ev.approval.request    core → UI: {id, tool, args} — human gate (see below)
ev.approval.reply      UI → core: {id, ok}
ev.cancel.<call-id>    cancellation signal (components may subscribe)
```

**Streaming.** The `llm` component streams tokens while generating:
`ev.llm.token` deltas (content + reasoning) → core forwards them for the
active turn as `ev.session.token` → the UI appends them to the live
assistant bubble. The final `ev.session.assistant` event always carries
the complete content, so a missed last frame heals itself. Abort an
in-flight call by publishing to `llm.cancel.<sessionId>`.

`nats sub '>'` attached to the bus shows the harness thinking in real time.
Or better: **the console component** (`./var/bin/console`, not in the
manifest — start it yourself in a second terminal) subscribes to
everything and renders the wire traffic readably: calls with tool + args,
results, errors, events, approvals — it is how you follow a live install
or a stuck-tool call:

```bash
./var/bin/console    # in a separate terminal while the harness runs
```

**The cli component** (`./var/bin/cli`) drives the same bus from a
script or pipeline — non-interactive, CI-friendly (exit 0 on success);
it is the scripting face, the tty admin shell is the interactive one:

```bash
./var/bin/cli catalog                        # components + their tools
./var/bin/cli wait <component> [secs]        # wait for registration
./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
```

`cli install` clones, builds via the builder, spawns every component and
waits for each registration — a plugin repo's CI proves a package by
running the harness itself through this one command. `file://` repo URLs
install from local git repos (hermetic tests, mirrors).

## Approvals

Tools whose schema carries `x-harness.approval: "always"` — currently
`bash`, `builder.build`, `core.spawn`, `core.kill`, `core.remove`,
`plugin_install`, `plugin_update`, `plugin_remove`, `skill_install`,
`skill_remove`, `write`, `observe_send`,
`observe_request`, `observe_dump` — are
gated on a human before they execute:

- **Terminal harness** (`make run`): a `[approval]` prompt with the tool
  name and arguments; answer `y`/`n`.
- **Web UI**: a modal dialog appears with the same details;
  Approve/Deny answers go back over the bus (`ev.approval.request` /
  `ev.approval.reply`).
- **Neither** (service mode with no UI attached): the call is **denied**
  with a clear error — never silently approved.
- Unanswered UI requests time out after 5 minutes and are denied.
- `NIF_AUTO_APPROVE=1` bypasses the gate (headless automation).

## Context window

Core watches how much of the model's context window a conversation uses
and acts *trivially* — no summaries, no token math beyond what the model
reports:

- The window size (`context`) is informational, reported by `llm` on
  every chat call: per-provider `context` and `NIF_OPENAI_CONTEXT` override
  it, then `llm` asks the `models` component's effective catalog. A small
  built-in table and conservative 128K remain as fallback if `models` is
  removed. See [MODELS.md](MODELS.md).

- After every chat call the model's own `usage.prompt_tokens` and the
  window size (`context`, informational from `llm`) are recorded
  and persisted with the assistant message, so the accounting survives
  restarts and session resume.
- At **75%** of the window, core warns once (terminal log; the UI shows a
  note) — `ev.session.context {warning: true}`.
- At **90%**, core trims: whole turns are dropped from the front of the
  conversation (system prompt stays; never below 2 user turns; a note
  message tells the model history was cut). Whole-turn drops keep
  `tool_call_id` pairs intact. `ev.session.context {trimmed: n}`.
- Before the model has reported usage (fresh or resumed session), a
  rough chars/4 estimate stands in.
- The **store keeps the full history** — trimming is in-memory per
  session, so nothing is lost; a resumed session simply re-trims.
- If the API still rejects an over-limit request, the error surfaces as
  a normal llm error (existing behavior). Thresholds are constants in
  `core/conversation.nim` (`ctxWarnRatio`, `ctxTrimRatio`, `minKeepTurns`).

## Self-extension and component lifecycle

The agent adds capabilities at runtime, mid-conversation:

1. writes a component source (Nim: `import niffler/sdk`, typed tool
   pattern; Go: `import sdk "niffler.dev/sdk"` — see the system prompt)
2. `builder.build {lang, name, source}` compiles it into `var/bin/`
3. `core.spawn {name, binary}` starts it; it registers itself; new
   conversations expose its tools directly (when not on demand), existing
   ones reach them via `discover` + `invoke` (docs/DISCOVER.md)
4. `core.kill {name}` stops it temporarily (restored on next boot);
   `core.remove {name}` stops it and deletes its persisted record

**Persistence of shape**: spawned components are recorded in the store
(kind `component`) and restored on boot. `core` itself, the bus, the
catalog and the supervisor are not removable — that asymmetry is the
architecture (ARCHITECTURE.md).

## Component ecosystem (`plugins`)

The `plugins` component is the ecosystem front door — community component
packages are plain GitHub repos with a `niffler.json` manifest at the root
(one repo = one package = N components). Repos tagged with the GitHub
topic `niffler-component` are discoverable without any registry:

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub topic search; returns repo, description, stars |
| `plugin_installed` | the packages installed on this harness |
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`, build each component from source via `builder.build`, then `core.spawn` each service component (approved) |
| `plugin_update {package}` | to the latest release tag: remove, reinstall at the new ref |
| `plugin_remove {package}` | `core.remove` every supervised component, delete the clone, drop the record |

- Install/update/remove all carry `x-harness.approval: "always"` — they
  run third-party code, and every individual spawn/remove is approved
  again by core. Never run them with `NIF_AUTO_APPROVE=1` unless you trust
  the publisher.
- The default ref is the latest release tag, else the default branch.
  `version` pins a tag or branch explicitly.
- Components always build from source via the `builder` — the same path
  agent-written components take. Running Niffler already provides the
  toolchain (Nim/Go, nats.c, libclang), so no extra requirements; every
  platform compiles with its own toolchain.
- A component manifest entry with `"interactive": true` is built into
  `var/bin` but is not passed to `core.spawn`. It is a terminal client (for
  example a TUI) that the user starts manually, so it is not supervised or
  restarted on boot. Stop any running client manually before removing or
  updating its package.
- Install records live in the store (kind `plugin`, id = package name);
  they are wiped by `--recover` like all component records — a fresh boot
  re-clones from the recorded repo/ref on reinstall.
- The GitHub API is used unauthenticated (60 req/h/IP).
- Publishing: add the `niffler-component` topic and tag releases
  (`v1.0.0`). The release workflow in the
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) sample
  dogfoods: it boots a harness and installs the package through
  `plugin_install`, so every tag proves the package installs cleanly.
- A package can extend or correct model metadata by registering a hidden tool
  with `x-models-source: {version: 1, priority: ...}`. The `models` component
  discovers it automatically and applies its JSON Merge Patch while that
  component is present. See [MODELS.md](MODELS.md#source-plugins).

## Skills

The `skills` component gives the agent reusable workflow guidance — the open
[Agent Skills](https://agentskills.io) format (SKILL.md files with YAML
frontmatter), the same convention Claude Code, opencode and Cursor use. It is
read/load only over the bus: no tool adds skills to the prompt, loading is
progressive disclosure through the tool result.

Discovery covers the standard agent directories (first match per skill name
wins — project beats home beats config):

| Source | Directories |
|---|---|
| project | `$NIF_ROOT/.agents/skills`, `$NIF_ROOT/.claude/skills`, `$NIF_ROOT/.opencode/skills` |
| home | `~/.agents/skills`, `~/.claude/skills`, `~/.opencode/skills`, `~/.niffler/skills` |
| config | `~/.config/opencode/skills` (where `npx skills add -g -a opencode` installs) |

| Tool | What it does |
|---|---|
| `skill_list {query?, source?}` | available skills (name, description, version, tags, source, dir); filter by substring or source |
| `skill_search {query, owner?}` | online search of the skills.sh registry (the `npx skills find` backend): name, repo source, install count; the `source`+`name` pair feeds `skill_install` directly |
| `skill_load {name}` | full SKILL.md instructions + resource list into the conversation (the load mechanism) |
| `skill_resources {name}` | the skill's `references/`, `scripts/`, `assets/` files |
| `skill_resource {name, path}` | read one resource on demand |
| `skill_install {repo, skill?, global?}` | clone a git repo, copy the chosen SKILL.md tree into `~/.niffler/skills` (default) or `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | delete a skill from a Niffler-managed directory only |

- `skill_search` is a read-only HTTP call to `https://skills.sh/api/search`
  (unauthenticated); it is not gated on approval. Install is: search →
  `skill_install {repo, skill}` → approval dialog → done.

- Skills installed with `npx skills add <owner>/<repo>` (the skills.sh
  ecosystem CLI) land in the standard dirs above and are discovered without
  reinstall; `skill_install` exists so Niffler works without Node, via plain
  git. It copies only SKILL.md trees — no code runs — and accepts
  `owner/name`, github.com URLs and `file://` local repos (hermetic tests).
- Repos holding several skills (e.g. `vercel-labs/agent-skills`) require the
  `skill` parameter; `skill_install` lists the candidates when it is missing.
- `skill_remove` refuses anything outside `~/.niffler/skills` and
  `$NIF_ROOT/.opencode/skills` — skills other agents installed into shared
  dirs are removed with their own tooling.
- Install and remove carry `x-harness.approval: "always"` (they write outside
  `var/`).

## Provider registry (`provider`)

Configured LLM backends are store records, not a config file. The
`provider` component keeps them under kind `provider` (id = nickname, plus
the `active` marker doc) and exposes them to the agent and to `llm`:

| Tool | What it does |
|---|---|
| `provider_add {nickname, apiKey, baseUrl?, model?, catalog?, context?, plugin?, active?}` | add or update a provider; the first one becomes active automatically |
| `provider_list` | all providers (redacted — no keys), which one is active |
| `provider_active` | the active provider's full config, API key included (for programmatic use) |
| `provider_switch {nickname}` | make another provider active; live-updates the LLM backend |
| `provider_remove {nickname}` | delete a provider; if it was active, another one takes over |
| `provider_export` / `provider_import` | JSON backup/migration round-trip, keys included; import merges and can restore the active marker |

- `provider_add`/`provider_import`/`provider_export` carry
  `x-harness.approval: "always"` — they move API keys in and out of the
  store.
- `llm` resolves its default backend from the active stored provider on
  every chat call, so `provider_switch` takes effect immediately. When the
  `provider` component is absent or nothing is active, `llm` falls back to
  `NIF_OPENAI_*` and the `NIF_LLM_PROVIDERS` table as before.
- A stored provider's explicit `context` (tokens) wins over the models
  catalog; its `catalog` id names the models.dev provider for the context
  lookup, and `plugin` may name a component that hooks provider-specific
  tools. On every switch the component publishes
  `ev.provider.switch {nickname, previous, at}` so such plugins can enable
  or hide their tools.
- The `active` marker is a plain store doc — remove or overwrite it with
  `store` tools if you need manual surgery.

## Fetch

The `fetch` component is the web access tool (a port of the old niffler
`fetch` tool). One tool:

| Tool | What it does |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH an http(s) URL; HTML → clean text via Trafilatura or a pure-Nim fallback; follows redirects; enforces caps |

- `convertToText` (default true) extracts readable text from HTML — JSON
  payloads are always returned verbatim.
- If `trafilatura` is on `PATH`, fetch gives it the already-downloaded HTML
  for higher-quality main-content extraction (bounded to 30 seconds). Missing,
  failed, timed-out, or empty extraction falls back to the built-in
  `htmlparser` walk. Set `NIF_TRAFILATURA` to an executable path/name to
  override detection, or `off` to disable it.
- Responses are capped at `maxSize` (default 10 MiB, max 50 MiB); content
  over 200 KB after processing is written to a file under `$NIF_FETCH_DIR`
  (default `$NIF_ROOT/var/fetch`) and the tool result points at it, so the
  agent reads large pages with its own file tools instead of blowing the
  conversation.
- Errors (non-2xx, timeouts, oversized responses, invalid URLs/methods)
  come back as `ok: false` with the status and a body snippet.
- Read-only network access — no approval gate (like `plugin_search`).

## Recovery — `--recover`

The repo is the snapshot; `var/` is disposable build output. If the agent
(or a bug) breaks a shipped component — overwrote a binary in `var/bin`,
corrupted a spawned component's record, or a self-added component crashes
on boot — start Niffler in recover mode:

```bash
make recover        # stops anything running, then ./var/bin/niffler --recover
```

`--recover` does three things, in order:

1. **Rebuilds the shipped binaries from source** (`make build`, falling
   back to `nimble all`) — fixes overwritten/corrupted `var/bin/*`.
2. **Wipes the store's component records** — spawned components are not
   restored; the harness comes back to the manifest set.
3. Boots normally (interactive). **Conversations and messages survive** —
   only the component shape is reset.

For damage to *sources* (someone edited `components/`, `core/` or `sdk/`):

```bash
# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)
git restore components/ core/ sdk/      # or: git checkout -- .
make build
./var/bin/niffler                       # or just reopen the UI
```

## The store

`store` is a component like any other — a document store over the bus with
`put` / `get` / `list` / `del` and rev-based optimistic concurrency
(`put` accepts `expectRev` and fails with `rev-conflict` on mismatch).
Kinds in use by core:

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` |
| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` — install record of the `plugins` component |

Backend is an embedded BitBarrel (bitcask-style) at `var/barrel-db`.
**Exactly one process owns that file** — never run two `store` processes
against the same barrel (a second core booted against the same root would
do exactly that; use a temp `NIF_ROOT` copy for experiments).

## Testing

```bash
make test        # the whole bus-contract suite (spawns its own NATS per test)
make test-bash   # ... or just one: test-store, test-builder, test-console,
                 # test-plugins, test-skills, test-fetch, test-models,
                 # test-observe, test-logfile, test-core, test-cli,
                 # test-autostart, test-smoke
```

Each test boots the real component binaries (Nim, Go *and* TypeScript —
the envelope is the artifact, so one harness tests every SDK) and drives
them over a private NATS server whose loopback ports are allocated by NATS.
Core-based tests snapshot their required binaries into a unique temporary
`NIF_ROOT`; Barrel, plugin clones, generated components, logs, and caches are
therefore isolated. Individual `make test-*` targets may run concurrently
with each other and a live development harness. Repository build writes are
serialized, while agent-built test components use sandbox-local Nim caches.
Network opt-ins: `NIF_TEST_INSTALL=1` runs the real
`cli install gokr/niffler-weather` + tool validation; `NIF_TEST_NETWORK=1`
runs `plugin_search` against GitHub, `skill_search` against skills.sh, and
the TypeScript builder build
(npm registry). The install pipeline itself is covered hermetically by
`t_plugins` via a local `file://` git repo.
Observe/logfile tests use temporary output directories and never delete the
developer's `var/logs` or `var/captures`. External network opt-ins can still
share provider rate limits even though their local state is isolated.

## Starting and stopping

There is no launcher script — the binaries own the lifecycle:

- **Desktop icon / `niffler-ui`** — the common case. The bridge's first act
  is the SDK's `ensureHarness`: probe `NIF_NATS_URL` → `var/nats-url` →
  127.0.0.1:4222 for a live core; if none answers, spawn `var/bin/niffler`
  detached with `NIF_AUTOSTART=1`. The repo root is baked in at `make ui`
  time (ldflags), so the installed icon works as well as the in-tree binary.
- **Interactive plugins** (e.g. `niffler-tui`) — same `ensureHarness` call,
  so starting one from a terminal also starts the harness when needed.
- **Terminal admin shell** — `./var/bin/niffler` directly. A manually
  started core never self-terminates; stop it with Ctrl-C / SIGTERM.

Interactive frontends register `"client": true` (the SDK's `interactive()`
/ `Component.Client` marker). An **autostarted** core counts them: when the
last one departs it shuts down after `NIF_AUTOSTART_IDLE_S` (default 10s —
a restarting UI re-registers inside that window), taking its components and
spawned bus with it; if none ever arrives it gives up after
`NIF_AUTOSTART_BOOT_S` (default 60s). Closing a UI that attached to a
*manually* started core changes nothing — the core stays up.
`NIF_ENSURE_ATTACH=0` makes `ensureHarness` spawn unconditionally (tests).

## Common tasks

```bash
./var/bin/niffler   # the harness in a terminal (admin shell)
niffler-ui          # the desktop UI — autostarts core; last UI stops it
make build          # rebuild what changed
make test           # the bus-contract suite (each test owns a private bus)
make doctor         # check prerequisites
make clean          # remove all build artifacts (var/, nimcache/, UI build)
```

- **Headless service mode** (no tty, for UIs/automation):
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` —
  serves `svc.core.call`; approval-requiring tools are denied unless a UI
  is attached or `NIF_AUTO_APPROVE=1`.
- **Attach to any bus**: `NIF_NATS_URL=nats://host:4222` (even remote).
- **Probe the bus** without the LLM: one-shot `nim c -r` scripts in
  `tests/` (see AGENTS.md "Debugging the bus").
- **Wails**: build only with `wails build -tags webkit2_41` (Linux);
  plain `go build` produces a stub. `make dev` runs the SPA in a browser
  with the bridge stubbed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI shows "Running in a browser" inside the desktop app | `nats.ts` binding mismatch — `window.go.main.Bridge` must match the Go struct name (ui/README.md) |
| UI banner: bus unreachable | core autostart still in progress or failed — start `./var/bin/niffler` in a terminal to see boot errors |
| `core: WARNING missing binary for <name>` on boot | run `make build` |
| llm error HTTP 401/403 | `NIF_OPENAI_API_KEY` missing or wrong — check `.env` and shell env |
| "approval denied" in headless mode | expected: no human reachable. Attach the UI, use `make run`, or set `NIF_AUTO_APPROVE=1` knowingly |
| two stores fight over `var/barrel-db` | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |
| orphaned `nats-server` | only possible when its core was SIGKILLed (the exit defer was skipped) — kill the pid in `var/nats-pid`, else `pkill -f nats-server` |
| component crashes on boot, restarts in a backoff loop | `core.remove` it via the UI/terminal, or `make recover` |
| agent-modified sources | `git restore components/ core/ sdk/` then `make build` (see Recovery) |
