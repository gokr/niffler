# Docs audit — `components/builder/` (Nim, 215 lines: `main.nim`, 11 567 bytes)

Scope: what the component offers, its two tools and every argument, its
configuration and toolchain, and how `docs/MANUAL.md` covers it. Line numbers
are as of the **3082-line** revision read while finalizing this report — the
MANUAL is being edited concurrently, so a shifted number is expected and the
quotes are the stable anchor (the convention in this directory's README).
Read-only audit; every claim carries file:line. Component version `0.1.0`
(`components/builder/main.nim:47`), manifest entry `manifest.yaml:29-32`
(`autostart: true`, `required: true`, `restart: on-failure`, **no `replicas`** →
one process).

Evidence classes used below: **live** = read off this checkout's running harness
on 2026-09-19 (`./var/bin/cli call catalog '{"op":"schemas","tools":["build","info"]}'`,
`./var/bin/cli call catalog '{"op":"components"}'`, `/proc/<builder-pid>/environ`);
**tree** = a real agent-built component left in `var/`; everything else is code.
Quoted MANUAL text is verbatim **modulo line-wrap and indentation** (whitespace
collapsed) — the manual's continuation lines are indented, so a quote that spans
two of them cannot be byte-identical in a single line. `main.nim:` is shorthand
for `components/builder/main.nim`.

## 1. What it offers

`builder` is the compile step of self-extension: it turns source that the agent
wrote during a conversation into an executable under `var/bin/`, so the next call
can be `core.spawn`. It registers exactly **two** tools — `build`
(`main.nim:49-201`) and `info` (`main.nim:203-213`) — **live**:

```
build   component builder v0.1.0   x-harness {approval: always, timeoutMs: 300000, onDemand: true}
info    component builder v0.1.0   x-harness {onDemand: true}
```

Its own description of the contract (`main.nim:52-72`, exactly what the LLM
reads): *"Compile a new component from source into a binary under var/bin. Use
this when the harness lacks a capability that no existing tool covers … then
invoke core.spawn with the returned binary — the component registers itself and
becomes available through discover."*

### The three languages, and what each one generates

| | Nim | Go | TypeScript |
|---|---|---|---|
| source written to | `var/build/<name with `-`→`_`>.nim` (`main.nim:83-85`) | `var/build/<name>/main.go` + `files` (`main.nim:107-130`) | `var/build/<name>/main.ts` (`main.nim:152-154`) |
| scaffolding generated | none — the SDK path comes from the compiler flags | `go.mod`: `module <name>`, `go 1.24`, `require niffler.dev/sdk v0.0.0`, `replace niffler.dev/sdk => <root>/sdk/go` (`main.nim:131-135`) | `package.json` (`niffler-sdk: file:<root>/sdk/ts`, `nats ^2.29.0`, `typescript ^5.5.0`, `@types/node ^22`) + `tsconfig.json` (`main.nim:155-166`) |
| compile command | `nim c --hints:off -d:release [-d:X…] --path:<root>/sdk -o:<tmp> <src>` (`main.nim:96-99`) | `go mod tidy && go build -o <tmp> .` in `var/build/<name>` (`main.nim:138-141`) | `npm install [--registry $NIF_NPM_REGISTRY] --no-audit --no-fund --loglevel=error` then `./node_modules/.bin/tsc` (`main.nim:170-180`) |
| what `var/bin/<name>` is | the ELF binary (`main.nim:103`) | the ELF binary (`main.nim:145`) | a **node wrapper**: `#!/usr/bin/env node` + `require("<abs>/var/build/<name>/dist/main.js")`, mode 0755 (`main.nim:186-195`) |
| extra prerequisite | `nim` on PATH | `go` on PATH (+ network for `go mod tidy` on non-SDK imports) | `node` **and** `npm` on PATH — refused with a clear error when missing (`main.nim:149-151`) |

The TS wrapper is why `dist/main.js` is checked before the move
(`main.nim:183-185`): the "binary" the agent spawns is a 2-line script that
`require`s the tsc output by **absolute path**. The `file:` SDK dependency works
only because `sdk/ts` carries `"prepare": "npm run build"`
(`sdk/ts/package.json`), so `npm install` builds `sdk/ts/dist` first; that is a
registry/network dependency on the SDK checkout, not just on `nats`.

**Tree evidence that this path is real, in this very clone:** `var/build/`
holds `deepseek.nim` (an agent-written Nim component with a `component` store
record and `var/bin/deepseek`), and `var/build/tui/` — 28 flat `.go` files,
432 336 bytes of extras plus a 106 098-byte `main.go`, with a builder-shaped
`go.mod` (`module tui`, `replace niffler.dev/sdk => /home/gokr/git/nifflerprod/sdk/go`)
whose `go` directive `go mod tidy` raised to `1.25.8`, and `var/bin/tui` as the
resulting Go ELF. The corresponding Nim caches are `var/nimcache/var_build_deepseek`
and `var/nimcache/var_build_synthetic`.

### Source → catalog registration (the whole flow)

1. `build` writes source under `<NIF_ROOT>/var/build/`, compiles to
   `var/bin/<name>.tmp-<pid>`, `moveFile`s it to `var/bin/<name>`
   (`main.nim:74-75`, `86-87`, `103`) and returns the path.
2. `core.spawn {name, binary}` (`core/dispatch.nim:308-346`): refuses a name that
   is already supervised, resolves a relative binary against the root, requires
   the file to exist, clamps `replicas` to 1–16, starts the child, and persists
   a `component` record `{name, binary(abs), policy, replicas, args, addedAt}`
   (verified **live**: `cli call list '{"kind":"component"}'`). **The source is
   not in the record** — `var/build/` is the only copy.
3. The child publishes `reg.publish` (`sdk/niffler/sdk.nim:846`,
   payload `regPayload` `sdk/niffler/sdk.nim:530-540`) and core inserts its tools
   into the catalog (`core/catalog.nim:640-680`).
4. Exposure: `build`/`info` are `onDemand`, so they never sit in a conversation's
   frozen direct toolset; the *new* component's own tools are direct in a new
   conversation and reach existing ones through `discover` + `invoke`
   (`sdk/niffler/sdk.nim` `info.flow`, MANUAL.md:897-899).
5. Registration is **fire-and-forget**: `announce` only publishes
   (`sdk/niffler/sdk.nim:541-542`) and no reply is checked, while core refuses the
   *entire* registration on a duplicate/missing tool name
   (`core/catalog.nim:654-673`). Consequence: a component whose tool name collides
   keeps running, prints its own `<name> v<ver> online on <url> (<N> tools)` line
   (`sdk/niffler/sdk.nim:847-848`), is **absent from the catalog forever**, and the
   only trace is core's stdout `catalog: rejecting <name> — tool '<t>' already
   provided by <owner>`. `spawn` still returns `ok: true`.

## 2. Tools

| Tool | Args (schema) | x-harness | Handler |
|---|---|---|---|
| `build` | `lang` (string, required), `name` (string, required), `source` (string, required), `files` (object), `defines` (object — **wrong type, see below**) | `approval: "always"`, `timeoutMs: 300000`, `onDemand: true` | `main.nim:50-201` |
| `info` | none (`properties: {}`) | `onDemand: true` | `main.nim:204-213` |

Both are defined in `components/builder/main.nim` by the SDK's `comp.tool` macro;
the schemas above are **live** (`catalog {op:"schemas"}`), i.e. exactly what the
LLM sees. `required: ["lang","name","source"]`. There is no `lang` enum in the
schema — the accepted spellings are unstated in-band and only the code's
`case lang` knows them (`main.nim:81-201`), with
`{ok:false, error: "unsupported lang '<x>' (supported: nim, go, ts)"}` as the
only feedback.

### Argument semantics

- `lang` — `"nim"`, `"go"` or `"ts"`, matched exactly (case-sensitive) by
  `case lang of` (`main.nim:81`, `106`, `148`, `199`).
- `name` — lowercase-hyphen component name **and** the binary name
  (`main.nim:67`). Validated by `validComponentName` (`main.nim:12-23`): 1–64
  chars, only `a-z`, `0-9` and single non-adjacent hyphens, no leading/trailing
  hyphen. `../escape`, `Foo`, `a_b`, `a--b`, `-a`, `a-` are all refused with
  `{ok:false, error: "name must be 1-64 lowercase letters, digits, and single hyphens"}`
  (`main.nim:76-78`). This is the path-traversal guard (t_builder asserts it).
- `source` — the full entrypoint source (`main.nim:68`). No size cap in the
  component; the ceiling is the bus payload (core raises nats-server to
  `max_payload: 8388608`, `core/niffler.nim:45-49`).
- `files` — **Go only**: a JSON *object* of flat `*.go` filename → source string,
  written beside `main.go` into the same package (`main.nim:111-130`). Rejected
  when not an object; capped at 64 entries and 2 000 000 bytes total; each
  filename validated by `validGoSourceName` (`main.nim:25-34`): ≤128 chars,
  ends `.go`, not `main.go`, not `*_test.go`, and only `[A-Za-z0-9._-]` — so no
  directories, no nested modules. A Nim or TS build **ignores `files`
  silently** (neither branch reads it: `main.nim:82-105`, `148-198`).
- `defines` — **Nim only**: array of names appended as `-d:NAME`
  (`main.nim:89-95`, example `["ssl"]` at `main.nim:70-72`). Each is validated by
  `validDefine` (`main.nim:36-45`, ≤64 chars, `[A-Za-z0-9_.]` — deliberately
  cannot inject a flag). A non-array value is **silently ignored**
  (`if defines != nil and defines.kind == JArray`, `main.nim:89`), and Go/TS
  builds ignore it entirely.

### The `defines` schema is wrong on the wire (code bug)

**Live**, the LLM sees (verbatim from `catalog {op:"schemas"}`):

```json
"defines": {"type": "object", "description": "Optional array of Nim compile defines, e.g. [\"ssl\"] for"}
```

Two defects, both in the tool's own declaration:

1. **Type.** `defines` is declared `JsonNode` (`main.nim:51`), and the SDK maps
   every `JsonNode` parameter to `{"type": "object"}`
   (`sdk/niffler/sdk.nim:920-921`) — while the handler only honours a JArray
   (`main.nim:89`). The schema the model plans against therefore contradicts the
   only shape that works. Declaring `defines: seq[string]` would publish
   `{"type":"array","items":{"type":"string"}}`
   (`sdk/niffler/sdk.nim:924-926`, and the macro already unwraps `seq` into
   `argStrSeq`/`argStrSeqD`)
   (`sdk/niffler/sdk.nim:1109-1113`). Nothing validates arguments against the
   schema in core, so the failure is silent, not loud.
2. **Truncated description.** The doc line breaks after `- defines:` and the
   continuation is indented two extra spaces (`main.nim:70-72`). The SDK's doc
   extractor takes `- param: text` on one line as the parameter doc and appends
   every other prose line to the *tool* description
   (`sdk/niffler/sdk.nim:939-958`), so the parameter doc stops at
   "…e.g. `["ssl"] for`" and the sentence's tail — "HTTPS-capable httpclient —
   appended as -d:NAME (validated; Nim identifier characters only)" — lands at the
   end of the tool description, after "…bare semantic names (read, edit, bash, …)."
   The fix is one line of doc comment.

### The approval gate

`build` carries `x-harness.approval: "always"` (`main.nim:49`); the gate is
enforced by core's dispatcher, not by the component
(`core/dispatch.nim:1636-1640`), so it applies to LLM/session calls
(`NIF_AUTO_APPROVE=1` bypasses; deny-by-default when no human is reachable —
`core/approval.nim`). `info` is deliberately **not** gated. `plugins` calls the
builder **component-to-component** (`comp.request("builder","build",…,320_000)`,
`components/plugins/main.nim:256`), which bypasses core's gate and `timeoutMs`
entirely; the approval there is on `plugin_install` itself
(`components/plugins/main.nim:628`).

### Timeouts

- Advertised: `x-harness.timeoutMs: 300000` → core waits 300 s for `build`
  (`core/dispatch.nim:1638-1641`; default is 120000, `core/dispatch.nim:173`).
  `info` takes the 120 s default.
- Actual per-command budgets inside the handler: Nim `runCmd` gets **no**
  timeout → the SDK default **120 000 ms** (`main.nim:96-99`;
  `sdk/niffler/procutil.nim:70`) — a cold, big Nim release build is killed with
  exit 124 after 2 minutes even though the schema advertises 5; Go gets 300 000
  (`main.nim:141`); `npm install` 300 000 (`main.nim:175`); `tsc` 120 000
  (`main.nim:180`).
- On a dispatch timeout core also publishes `cancel.build` and waits briefly for
  a partial reply (`core/dispatch.nim:1403-1421`). The builder does not subscribe
  `cancel.<component>` and declares no `x-harness.sessionId`, so the message is
  dropped and the compile keeps running to its own deadline (docs/WIRE.md
  "Cancellation": "Components without a subscription drop the message and run to
  completion or deadline"). Contrast `bash`, which subscribes and kills the
  command's process group (`components/bash/main.nim:55-94`).

### Result shapes

Success (`main.nim:104-105`, `146-147`, `196-198`) is the same for all three
languages:

```json
{"ok": true, "lang": "nim|go|ts", "name": "<name>",
 "binary": "<abs>/var/bin/<name>", "log": "<head? tail, 500 bytes>"}
```

Failure always has `ok: false` and one of these shapes:

| cause | shape | code |
|---|---|---|
| bad name | `{ok:false, error:"name must be 1-64 …"}` (no `lang`) | `main.nim:76-78` |
| bad define | `{ok:false, lang, error:"invalid define: <name>"}` | `main.nim:92-94` |
| bad `files` | `{ok:false, lang, error:"files must be an object…" / "files may contain at most 64 Go sources" / "invalid additional Go source filename: <f>" / "Go source <f> must be a string" / "additional Go sources exceed 2 MB"}` | `main.nim:112-129` |
| compile error | `{ok:false, lang, error: <compiler output, last 2000 bytes>}` | `main.nim:100-102`, `142-144`, `176-182` |
| ts scaffolding missing | `{ok:false, lang, error:"node and npm are required on PATH for ts components"}` / `"tsc produced no dist/main.js"` | `main.nim:149-151`, `183-185` |
| unknown language | `{ok:false, error:"unsupported lang '<x>' (supported: nim, go, ts)"}` (no `lang`) | `main.nim:199-201` |

`log`/`error` are `tailBytes`-truncated with a leading `…` marker snapped to a
UTF-8 boundary (`sdk/niffler/procutil.nim:181-189`). Two things the result does
**not** carry: the compiler's exit code, and any distinction between "killed at
its timeout (124)" and "failed to compile" — both arrive as
`error: <output tail>`, so a timeout with empty output is unreadable. A failed
compile leaves the previous `var/bin/<name>` untouched (the temp file is removed,
`main.nim:101`, `143`).

## 3. Configuration

### Environment variables

The component itself reads **one** variable (`grep -n getEnv components/builder/main.nim`
→ line 170 only):

| Variable | Where | Meaning | Default |
|---|---|---|---|
| `NIF_NPM_REGISTRY` | `main.nim:170-171` | `--registry <url>` added to the ts `npm install` (e.g. `https://registry.npmmirror.com`) | npm's default registry |
| `NIF_ROOT` | via `rootDir()` (`sdk/subjects.nim:34-36`, used at `main.nim:73-75`, `206-208`) | everything the tool writes/returns is rooted here: `var/build`, `var/bin`, the `sdk` paths in `info` | `.` (cwd) — but core sets it process-globally for every child (`core/supervisor.nim:129`), so inside a harness it is the harness root (**live**: `/proc/$(pgrep -f var/bin/builder)/environ` → `NIF_ROOT=/home/gokr/git/nifflerprod`, and `info` returned `/home/gokr/git/nifflerprod/sdk`) |

There is **no `NIF_BUILDER_*` / `NIF_BUILD_*` knob**. The rest of the
environment reaches it through the SDK, not through this component:
`NIF_NATS_URL` (bus), `.env` from cwd and `$NIF_ROOT/.env` loaded at boot
(`sdk/niffler/sdk.nim:790-791`), and core-side `NIF_AUTO_APPROVE`
(`core/approval.nim`). A spawned component inherits the parent environment
(`core/supervisor.nim:124`) with `NIF_ROOT` set.

### Toolchain invoked

Every command is run through `bash -c`, as the leader of its own process group,
with combined stdout+stderr captured to a temp file (`sdk/niffler/procutil.nim:70-133`):

| Purpose | Exact command | Timeout |
|---|---|---|
| Nim | `nim c --hints:off -d:release [-d:<define>…] --path:<root>/sdk -o:<root>/var/bin/<name>.tmp-<pid> <root>/var/build/<name_>.nim` | 120 000 ms (SDK default — `main.nim:96-99`) |
| Go | `cd <root>/var/build/<name> && go mod tidy && go build -o <root>/var/bin/<name>.tmp-<pid> .` | 300 000 ms (`main.nim:138-141`) |
| TS install | `cd <root>/var/build/<name> && npm install [--registry <NIF_NPM_REGISTRY>] --no-audit --no-fund --loglevel=error` | 300 000 ms (`main.nim:172-175`) |
| TS compile | `cd <root>/var/build/<name> && ./node_modules/.bin/tsc` | 120 000 ms (`main.nim:178-180`) |

The Nim branch looks self-contained but is not: the compile runs with the
builder's own cwd, and Nim reads `config.nims` from the **source file's
directory chain**, so `<root>/config.nims` is what supplies
- the `~/.nimble/pkgs2` scan for `natsnim`/`yaml`/`bitbarrel` — without it
  `import niffler/sdk` cannot compile at all (`config.nims:12-23`);
- a per-entrypoint `nimcache` at `<root>/var/nimcache/var_build_<name>`
  (`config.nims:62-68`; **tree**: `var/nimcache/var_build_deepseek`,
  `var_build_synthetic`);
- `-d:ssl` for every build plus the PCRE link flags (`config.nims:38-50`) — so
  the tool's own `defines: ["ssl"]` example is redundant on a shipped harness.

`tests/t_builder.nim:28-34` has to copy `config.nims` and `niffler.nimble` into
its sandbox root for exactly this reason — evidence that a `NIF_ROOT` without
them cannot build a Nim component, which nothing documents.

### Filesystem effects (all under `NIF_ROOT`)

| Path | What |
|---|---|
| `var/build/<name>.nim` / `var/build/<name>/` | the written source; **the only copy**. Never pruned — `var/build` grows one entry per component ever built (Go/TS directories keep `node_modules`, `dist`, `go.sum`) |
| `var/bin/<name>` | the compiled artifact (binary, or the TS node wrapper) |
| `var/nimcache/var_build_<name>` | Nim object cache, via `config.nims` |
| `var/logs/<name>.log` | the spawned component's stdout+stderr (`core/supervisor.nim:126-136`) — where a registering child's `rejected registration` story is *not* visible; that line is on core's stdout |

### The build lock

The Makefile serializes repository build writes with
`scripts/with-build-lock.sh` (exclusive for builds/clean, shared for test runs;
`Makefile:67-68`, lock file `.niffler-build.lock`, `scripts/with-build-lock.sh:22`).
**The builder does not participate**: no lock, no `flock`, no
`NIF_BUILD_LOCK`/`NIF_CONF_KEEP` reference anywhere in the component
(`grep -rn with-build-lock components/` is empty). So a runtime `builder.build`
is not serialized against `make build`/`make clean`: `clean` is `rm -rf var`
under the exclusive lock (`Makefile:581-582`) and can delete `var/bin`/`var/build`
under a running compile, after which the `moveFile` throws into the SDK's handler
wrapper and the caller gets an error envelope with code `boom`
(`sdk/niffler/sdk.nim:725-727`) instead of a binary. Two concurrent
`builder.build` calls cannot overlap *within* the process (the Nim SDK pump is
serial, one message at a time, `sdk/niffler/sdk.nim:856+`); two *harness roots* sharing one `NIF_ROOT`
would share the scratch dir.

## 4. How docs/MANUAL.md covers it today

The `builder` component has **no dedicated section**. It is named in the layout
tables, the shipped-components row, the approval list, one env row, the
self-extension chapter, the plugins chapter, the tool-exposure policy, and two
test notes. Verbatim, with today's line numbers:

- **MANUAL.md:43** (layout): ``| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |``
- **MANUAL.md:52** (layout): ``| `var/build/` | source files of agent-built components (builder's scratch dir) |``
- **MANUAL.md:63** (shipped components, the only description): ``| `builder` | Nim | required | compiles agent-written Nim/Go/TypeScript source into binaries: `build {lang, name, source, files?, defines?}` (approval-gated, on demand) and `info` (on demand: the per-language source skeleton and SDK locations) |``
- **MANUAL.md:184-186** (minimal boot): `` `builder`, `plugins`, `skills`, `fetch`, `models`, `provider`, the dedicated file tools, and observation/logging do not start.``
- **MANUAL.md:355-356** (state and configuration): ``and everything derived is `var/` (regenerable — delete it and `make build` + a boot rebuilds the world).``
- **MANUAL.md:401** (environment table): ``| `NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default |``
- **MANUAL.md:482** (build knobs): ``**Build and script knobs** — read by the scripts around the harness, never by components: … `NIF_BUILD_LOCK` (lock file `scripts/with-build-lock.sh` flocks — exclusive for builds, shared for test runs) …``
- **MANUAL.md:636-638** (approvals): ``Tools whose schema carries `x-harness.approval: "always"` — currently `bash`, `build` (the `builder` component), core's `spawn`, `kill` and `remove`, …``
- **MANUAL.md:894-899** (self-extension steps 2-3): ``2. `build {lang, name, source, files?, defines?}` (the `builder` component) compiles it into `var/bin/` (`files` adds further Go sources, `defines` passes compiler defines)`` / ``3. `spawn {name, binary, replicas?}` (core) starts it; it registers itself; new conversations expose its tools directly (when not on demand), existing ones reach them via `discover` + `invoke` …``
- **MANUAL.md:905-906**: ``A fabric program that stabilizes takes the same route: `fabricprog` is the scratchpad, `builder.build` + `core.spawn` is graduation``
- **MANUAL.md:932-933** (persistence of shape): ``**Persistence of shape**: spawned components are recorded in the store (kind `component`) and restored on normal boot.``
- **MANUAL.md:963-969** (plugins build path): ``Components always build from source via the `builder` — the same path agent-written components take.`` … ``A Go entry may declare `"sources": ["component/helper.go", ...]`; these must be non-symlink, same-package `.go` files beside `main`, and the builder compiles them as one package.``
- **MANUAL.md:970-971**: ``A component manifest entry with `"interactive": true` is built into `var/bin` but is not passed to `core.spawn`.``
- **MANUAL.md:975-977**: ``A manifest entry may carry `defines` (an array of `-d:`-style prepends) and `env` (an array of `NAME=value` strings). Both are passed through — `defines` to the builder, `env` to the spawn …``
- **MANUAL.md:1865-1867** (progressive discovery): ``A binary under `var/bin` is inert until manifest autostart, `core.spawn`, or a plugin install starts it.``
- **MANUAL.md:2067** (shipped policy): ``- Core lifecycle/status/catalog, builder, plugins, and fetch.``
- **MANUAL.md:2944-2945** (testing): ``Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches.``
- **MANUAL.md:2951-2954** (testing, network opt-in): ```NIF_TEST_NETWORK=1` runs `plugin_search` against GitHub, `skill_search` against skills.sh, and the TypeScript builder build (npm registry).``

The frozen system prompt adds only one line —
`components/systemprompt/baseprompt.txt:20` ``skills, builder (new components — build, then core.spawn).`` — and
`core/conversation.nim:42-43`'s degraded fallback prompt says the same. So the
MANUAL is the only real documentation, and it stops at the three argument names.

### What is missing or stale

**Obligatorily missing** (a reader cannot learn it from any doc):

1. **The result shape.** No `ok`/`binary`/`log`/`error`, no "compile errors are
truncated to 2000 chars", no note that a timeout and a compile error look alike.
2. **Multi-file components beyond Go.** `files` is documented only as "adds
further Go sources" (MANUAL.md:895) and as manifest `sources`
(MANUAL.md:966-969). That a Nim or TS build **silently ignores `files`**, and
that the limit is 64 files / 2 MB, is nowhere. The ship of a 28-file Go
component in this very checkout (`var/build/tui/`) shows how load-bearing `files`
is — it is the second argument an agent reaches for.
3. **The TypeScript flow.** Only two facts exist: `**NIF_NPM_REGISTRY**` (MANUAL.md:401)
and "the TypeScript builder build (npm registry)" (MANUAL.md:2953). Nothing says
`node`+`npm` are required on PATH, that `package.json`/`tsconfig.json` are
generated, that `niffler-sdk` is wired as a `file:` dependency into `<root>/sdk/ts`
(and therefore needs that checkout, plus its own `prepare` build), or that the
"binary" is a `node` wrapper `require`-ing `var/build/<name>/dist/main.js` by
absolute path.
4. **The lock, and what `make clean` does to agent-built components.** MANUAL.md:482
correctly lists `NIF_BUILD_LOCK` as script-only, and MANUAL.md:2944-2945 says build
writes are serialized — but the builder is *not* in that lock, and a `make clean`
(`rm -rf var`) during a build, or after one, deletes both the source
(`var/build/`) and the artifact (`var/bin/`) while the `component` record
survives. The next boot then reports `core: WARNING missing binary for <name>`
(`core/niffler.nim:505-507`) and there is **no way back** short of re-writing the
source — a direct contradiction of MANUAL.md:355-356's "everything derived is
`var/` (regenerable … a boot rebuilds the world)".
5. **The failure modes of self-extension.** A tool-name collision makes core
refuse the whole registration *silently* (MANUAL.md:894-899 promises "it
registers itself"); rebuilding a live component needs `kill` before `spawn`
(spawn answers `component already supervised: <name>`, `core/dispatch.nim:330-332`).
6. **The limits.** Name rules (the reason `../escape` is refused), the
`config.nims` dependency of every Nim build, the 2-minute internal Nim budget
against the advertised 5 minutes, and that a cancelled turn does not stop a
running compile.

**Stale / incomplete wording:** MANUAL.md:63's "`info` (on demand: the
per-language source skeleton and SDK locations)" undersells `info` (it also
returns the *flow* and the naming rule) but is otherwise right; MANUAL.md:43's
`var/bin/` row describes only `make build` output, although agent-built binaries
land there too and are the rows an operator will find surprising; MANUAL.md:52
says "source files", though for Go/TS it is a whole directory with
`node_modules`/`dist`/`go.sum`; MANUAL.md:975-977 promises manifest `defines` are
"passed through", which is true but inert for `lang: go`/`ts` packages (see the
row under **Component ecosystem**).

**Proposed placement:** a new section ``## Building components (`builder`)``
inserted after `## Self-extension and component lifecycle` (which ends at
MANUAL.md:936) and before `## Component ecosystem (`plugins`)` (MANUAL.md:938),
with subsections `### The tools`, `### The three languages`, `### Safety rules
and limits`, `### Where output lands`, `### Configuration and the build lock`;
plus a Contents line after MANUAL.md:18 and one state-table row for `var/build`.
Keep MANUAL.md:63 as the one-line summary.

## 5. DELTA list

Row format: `- MANUAL: <exact current quote, or the word absent> | CODE: <path:line> | FIX: <verb + proposed wording>`.
Groups are exact `## ` headings of the current `docs/MANUAL.md` (3082-line revision);
the bracketed tag before the verb in `FIX` is the finding class.

## Layout of a running system

- MANUAL: "| `var/bin/` | built binaries (system core + session runner + components). Rebuilt by `make build` |" | CODE: `components/builder/main.nim:75`, `103`, `145`, `195` (every `build` returns `<root>/var/bin/<name>`) | FIX: update [doc-edit] — add "; agent-built components (`builder.build`) land here too, beside the system binaries"
- MANUAL: "| `var/build/` | source files of agent-built components (builder's scratch dir) |" | CODE: `main.nim:74`, `84` (Nim: one `<name_>.nim`), `107` (Go: `<name>/` with `go.mod`/`main.go`/`go.sum`), `152` (TS: `<name>/` with `package.json`/`tsconfig.json`/`node_modules/`/`dist/`) | FIX: update [doc-edit] — "; for Go and TypeScript it is a whole project directory (generated `go.mod`, `package.json`/`tsconfig.json`, `node_modules`), never pruned. It is the **only** copy of an agent-built component's source — deleting `var/` orphans the persisted `component` record"
- MANUAL: "and everything derived is `var/` (regenerable — delete it and `make build` + a boot rebuilds the world)" | CODE: `core/dispatch.nim:340-343` (the persisted `component` record holds only `{name, binary, policy, replicas, args, addedAt}` — no source), `core/niffler.nim:505-507` (boot then prints `core: WARNING missing binary for <name>` and skips it), `main.nim:74-75` (source lives only in `var/build`) | FIX: update [wrong] — "everything derived is `var/`, **except agent-built components**: their source exists only under `var/build/` and their binary only under `var/bin/`, so `make clean` deletes both while the `component` record survives — the next boot warns `missing binary for <name>` and the component cannot be restored. Rebuild it with `builder.build` + `core.spawn`, or `core.remove` the record"
- MANUAL: "A binary under `var/bin` is inert until manifest autostart, `core.spawn`, or a plugin install starts it." | CODE: `main.nim:104-105` (build returns the path), `core/dispatch.nim:308-346` (spawn), `components/plugins/main.nim:256-263` (install spawns) | FIX: none [verified] — accurate; the only unstated part is that the build→spawn pair is the documented self-extension step (MANUAL.md:894-899).
- MANUAL: "compiles agent-written Nim/Go/TypeScript source into binaries: `build {lang, name, source, files?, defines?}` (approval-gated, on demand) and `info` (on demand: the per-language source skeleton and SDK locations)" | CODE: `main.nim:49` (`approval: always`, `timeoutMs: 300000`, `onDemand: true`), `main.nim:203` (`info`, `onDemand` only), **live** `catalog {op:schemas}` returns exactly those two tools, `required: [lang,name,source]` | FIX: none [verified] — the row is right about both tools, the five arguments, the gate and the exposure; only depth is missing (see the next rows).
- MANUAL: "`info` (on demand: the per-language source skeleton and SDK locations)" | CODE: `main.nim:206-213` (returns `langs`, `sdk`, `sdkGo`, `sdkTs`, `naming`, `flow`, `nim`, `go`, `ts`), **live** `info` result (same nine keys), `tests/t_builder.nim:49-52` (compiles `info{"go"}` verbatim as a Go component — the skeleton is the contract) | FIX: update [doc-edit] — "`info` (on demand) returns the SDK paths (`sdk`/`sdkGo`/`sdkTs`), the global tool-naming rule, the build→spawn→discover `flow` string, and a complete compiling skeleton per language — the fastest way to write a component that builds on the first try."
- MANUAL: "`build {lang, name, source, files?, defines?}`" | CODE: `main.nim:76-78` (`validComponentName`), `main.nim:25-34` (`validGoSourceName`), `main.nim:36-45` (`validDefine`), `main.nim:89` (`defines.kind == JArray`), `main.nim:111-130` (Go-only `files`) | FIX: add [missing] — the row should carry the rules an agent must satisfy before calling: `name` is 1–64 chars of `a-z0-9` and single hyphens (that is the traversal guard — `../escape` is refused with `name must be 1-64 lowercase letters, digits, and single hyphens`); `files` is **Go only** (≤64 flat `*.go` sources, ≤2 MB total, no `main.go`, no `*_test.go`, no directories) and is silently ignored by Nim/TS builds; `defines` is **Nim only** (`-d:NAME`, `[A-Za-z0-9_.]`, ≤64 chars) and a non-array value is silently ignored.
- MANUAL: "`builder`, `plugins`, `skills`, `fetch`, `models`, `provider`, the dedicated file tools, and observation/logging do not start." | CODE: `core/niffler.nim:25` (`minimalComponents = ["store", "bash", "llm"]`), `core/niffler.nim:473` (every manifest entry outside that list is skipped) | FIX: none [verified] — in `--minimal` `builder` (and its tool schemas) really is left out; the records of previously spawned components stay in the store.

## Self-extension and component lifecycle

- MANUAL: absent (the result shape of `build` anywhere in the MANUAL) | CODE: `main.nim:104-105`, `146-147`, `196-198` (success `{ok, lang, name, binary, log}`), `main.nim:100-102`, `142-144`, `176-182` (failure `{ok:false, lang, error: <compiler output tail>}`, 2000 bytes), `sdk/niffler/procutil.nim:181-189` (UTF-8-safe tail with a `…` marker) | FIX: add [missing] — "`build` returns `{ok, lang, name, binary, log}` on success and `{ok: false, lang, error}` on failure, where `error` is the compiler's own output tail (2000 bytes) — check the return instead of assuming `var/bin/<name>` exists. There is no exit code in the result, so a build killed at its internal budget (Nim 120 s, Go/`npm install` 300 s, `tsc` 120 s) looks like a compile error with whatever output it had produced."
- MANUAL: absent (the 300000 ms `x-harness.timeoutMs` of `build` and the per-command budgets inside it) | CODE: `main.nim:49` (`timeoutMs: 300000`), `core/dispatch.nim:1638-1641` (enforced), `main.nim:96-99` (Nim `runCmd` with no timeout → 120 000 ms default, `sdk/niffler/procutil.nim:70`) | FIX: code bug [code-bug?] — the advertised 300 s does not match any Nim build's real budget: pass an explicit `300_000` to the Nim `runCmd` (or lower the schema to what is true), because today the dispatch timeout fires while a listener-based `bash`-style partial reply is unavailable.
- MANUAL: absent (the schema the model actually plans against — the MANUAL names the arguments, never their published types) | CODE: `main.nim:50-51` (`defines: JsonNode`), `sdk/niffler/sdk.nim:920-921` (`JsonNode` → `"type": "object"`), `main.nim:89` (handler requires `JArray`), `main.nim:70-72` (the doc comment's wrapped `- defines:` line), `sdk/niffler/sdk.nim:939-958` (doc extractor: only single-line `- param:` lines are parameter docs) | FIX: code bug [code-bug?] — make the declaration match reality: `defines: seq[string]` (publishes `array` of `string`) and keep the `- defines:` doc line unbroken. Today the LLM is told "Optional array of Nim compile defines, e.g. `["ssl"] for`" in a field typed `object`, with the rest of the sentence glued to the end of the tool description.
- MANUAL: absent (what a cancelled turn does to a build already running) | CODE: `main.nim:49` (no `sessionId`), `docs/WIRE.md` "Cancellation" (components opt in by subscribing `cancel.<component>` and matching the injected `__session.session`), `components/bash/main.nim:55-94` (the reference implementation: kill the process group, exit 130), `core/dispatch.nim:1403-1421` (core publishes the cancel and waits briefly for a partial reply) | FIX: add [missing] — "a cancelled turn does not stop a build: core publishes `cancel.build`, the builder has no subscription and no `x-harness.sessionId`, so the compiler keeps running to its own deadline and only the reply is abandoned. Wait for the tool result before cancelling, or kill the component (`core.kill {name: "builder"}`)."

## Approvals

- MANUAL: "Tools whose schema carries `x-harness.approval: "always"` — currently `bash`, `build` (the `builder` component), core's `spawn`, `kill` and `remove`, …" | CODE: `main.nim:49` (gate), `core/dispatch.nim:1636-1640` (enforcement), `components/plugins/main.nim:256` (a peer component calls `svc.builder.call` directly — no gate, no `timeoutMs`), `components/plugins/main.nim:628` (`plugin_install` carries its own) | FIX: update [doc-edit] — add a sentence after the list: "The gate is enforced by core's dispatcher, so it covers LLM/session calls; a component that calls `svc.builder.call` directly (the `plugins` install path) is not gated — that caller carries its own approval."

## Environment variables

- MANUAL: "`NIF_NPM_REGISTRY` | npm registry for `builder` ts-component installs (e.g. `https://registry.npmmirror.com`) | npm default" | CODE: `main.nim:170-171` (`--registry <url>` on `npm install`; empty → no flag) | FIX: none [verified] — accurate; the row is the only TS-related fact in the MANUAL today.
- MANUAL: "**Build and script knobs** — read by the scripts around the harness, never by components: … `NIF_BUILD_LOCK` (lock file `scripts/with-build-lock.sh` flocks — exclusive for builds, shared for test runs) …" | CODE: `scripts/with-build-lock.sh:22`, `Makefile:67-68`, `Makefile:581-582` (`clean` = `rm -rf var` under the exclusive lock), `components/builder/main.nim` (no lock call anywhere), `core/supervisor.nim:124` (children inherit the environment) | FIX: update [delta] — the sentence is true about components, but it hides the consequence: `builder.build` runs **outside** the lock, so `make build`/`make clean` in a second terminal can race a runtime build — `clean` deletes `var/bin` and `var/build` under it. Add: "`builder.build` deliberately does not take this lock — stop the harness (or avoid `make clean`) while an agent is building a component."

## Component ecosystem (`plugins`)

- MANUAL: "A manifest entry may carry `defines` (an array of `-d:`-style prepends) and `env` (an array of `NAME=value` strings). Both are passed through — `defines` to the builder, `env` to the spawn …" | CODE: `components/plugins/main.nim:249-250` (passed regardless of `lang`), `main.nim:89-95` (read only in the Nim branch), `main.nim:111-130` (files: Go branch only) | FIX: update [doc-edit] — "`defines` is a **Nim-only** affordance: a `lang: "go"` or `lang: "ts"` manifest entry that declares `defines` builds fine and silently ignores them — verify by behaviour, not by manifest."
- MANUAL: "A Go entry may declare `"sources": ["component/helper.go", ...]`; these must be non-symlink, same-package `.go` files beside `main`, and the builder compiles them as one package." | CODE: `components/plugins/main.nim:251-255` (keyed by `extractFilename()` — the directory is *flattened*), `main.nim:25-34` | FIX: update [doc-edit] — say that only the **basename** survives: "`sources` paths are flattened to their filename before they reach the builder, so two files with the same basename collide and subdirectories cannot exist in the build directory; the cap is 64 files / 2 MB, and a subpackage (`component/foo/bar.go`) is not buildable at all."

## Progressive tool discovery

- MANUAL: "- Core lifecycle/status/catalog, builder, plugins, and fetch." | CODE: `main.nim:49` (`build` onDemand), `main.nim:203` (`info` onDemand) | FIX: none [verified] — both builder tools are on demand, exactly as listed; no builder tool is direct or hidden.

## Testing

- MANUAL: "Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches." | CODE: `Makefile:67-68` (`BUILD_LOCK`/`TEST_LOCK`), `tests/t_builder.nim:28-34` (the sandbox gets its own `config.nims` + `nimcache`), `components/builder/main.nim` (no lock) | FIX: update [delta] — scope the claim: "Repository build writes (`make build`, `make clean`) are serialized by `scripts/with-build-lock.sh`; a runtime `builder.build` is not part of that lock, and agent-built components compile with the checkout's `var/nimcache/var_build_<name>` unless a sandbox overrides it."
- MANUAL: "`NIF_TEST_NETWORK=1` runs `plugin_search` against GitHub, `skill_search` against skills.sh, and the TypeScript builder build (npm registry)." | CODE: `tests/t_builder.nim:136-154` (the TS case is skipped with a note unless `NIF_TEST_NETWORK=1`), `main.nim:149-151`, `172-180` | FIX: none [verified] — accurate, and it explains why a `make test` run proves nothing about the TS path: `node`/`npm` presence, the `file:` SDK wiring and the wrapper are only exercised by that opt-in.

## Troubleshooting

- MANUAL: absent (nothing about a component that builds and spawns but never appears in the catalog) | CODE: `core/catalog.nim:654-673` (a duplicate/missing tool name refuses the ENTIRE registration; core prints `catalog: rejecting <name> — tool '<t>' already provided by <owner> (refused; use component-prefixed tool names)`), `sdk/niffler/sdk.nim:541-542` + `846-848` (registration is a fire-and-forget publish; the component still prints `online`), `main.nim:62-65` (the tool's own advice: prefix every tool with the component name; bare semantic names belong to shipped components) | FIX: add [missing] — a Troubleshooting entry: "**`spawn` said ok, but the component is not in the catalog.** Its registration was refused — almost always a tool name that already exists (names are globally unique; prefix yours with the component name). The component process is alive and logs `<name> v<ver> online`; core's stdout carries the reason (`catalog: rejecting …`). Fix the tool name, rebuild, `core.kill {name}`, `core.spawn` again."
- MANUAL: absent (rebuilding a component that is already running) | CODE: `core/dispatch.nim:330-332` (spawn refuses: `component already supervised: <name>`), `core/dispatch.nim:347-356` (`kill` removes the child and drops the catalog entry but keeps the record), `main.nim:103`/`145`/`195` (the rebuild renames a fresh binary over `var/bin/<name>`) | FIX: add [missing] — "A rebuild does **not** reach the running process (the old inode keeps executing): to pick up new code, `core.kill {name}` (record kept) and then `core.spawn {name, binary}`; `spawn` refuses while the name is supervised."

## 6. Not user-facing, and how this was verified

Nothing in `builder` is hidden infrastructure: both tools are ordinary catalog
tool registrations (`main.nim:49`, `203`), both `onDemand`, and neither is
`hidden` or `runner`. The component keeps **no state of its own** — no store
writes, no `$XDG_CONFIG_HOME` file, no in-process cache; its durable footprint is
three filesystem paths (`var/build`, `var/bin`, `var/nimcache/var_build_<name>`)
plus the `component` record that **core** writes on spawn. That is why the
recovery story above is the sharpest finding: core remembers a component whose
only source lived in a disposable directory.

Three behaviours change what a user sees without appearing in any doc, each worth
a sentence in the MANUAL:

1. a component that builds, spawns and logs `online` yet never appears in the
   catalog (refused registration, `core/catalog.nim:654-673`);
2. a TS component whose "binary" is an absolute-path `require` into
   `var/build/` (`main.nim:189-191`) — copying `var/bin/<name>` elsewhere, or
   wiping `var/`, breaks it in a way no error message explains;
3. the 2-minute internal Nim budget against an advertised 5 (`main.nim:96-99`).

### Verification performed (2026-09-19, this checkout, current tree)

- `./var/bin/cli call catalog '{"op":"schemas","tools":["build","info"]}'` — the
  two schemas, `required`, `x-harness` flags, the wrong `defines` type and the
  truncated `defines` description (all quoted verbatim above).
- `./var/bin/cli call catalog '{"op":"components"}'` → `builder: [build, info]`.
- `./var/bin/cli call info '{}'` — the live `info` result (SDK paths under the
  real root, all nine keys).
- `./var/bin/cli call list '{"kind":"component"}'` and `/proc/<builder-pid>/environ`
  — the persisted record shape (`{name, binary, policy, replicas, args, addedAt}`,
  no source) and `NIF_ROOT` injection.
- Tree artifacts: `var/build/deepseek.nim`, `var/build/tui/` (28 `.go` files, `go.mod`
  with the builder's `replace` line), `var/nimcache/var_build_*`.
- Every MANUAL quote in this report and every cited `file:line` was re-checked
  against the current tree by script — the 21-span list in section 4 plus all 16
  quoted delta rows (the other 6 state `MANUAL: absent`) and 100+ `file:line`
  citations. Every quote matches the current manual modulo its line-wrap and
  indentation (stated in the header); line numbers are the 3082-line revision's.
  **Not** run: an actual `builder.build`
  (approval-gated — it would prompt a human), `make test-builder` (no code
  changed by this audit), and the `NIF_TEST_NETWORK=1` TypeScript path.

### Findings per class (22 rows)

| class | count | rows |
|---|---|---|
| `verified` | 6 | MANUAL 1865-1867, 63 (tool surface), 184-186 (minimal boot exclusion), 401, 2067, 2951-2954 |
| `doc-edit` | 6 | MANUAL 43, 52, 63 (`info` depth), 636-638, 975-977, 966-969 |
| `missing` | 5 | MANUAL 63 ×3 (safety rules, result shape, cancellation) + the two Troubleshooting entries (refused registration, rebuild workflow) |
| `code-bug?` | 2 | MANUAL 63 (the `defines` schema/description; the 300 s vs 120 s timeout) |
| `delta` | 2 | MANUAL 482 and 2944-2945 (the build lock does not cover a runtime build) |
| `wrong` | 1 | MANUAL 355-356 (`var/` is not regenerable for agent-built components) |

### The five findings that matter most

1. **`make clean` permanently orphans agent-built components** (MANUAL:355-356 is
   false for them): their source exists only in `var/build/`, and the store
   record carries no source — the next boot warns `missing binary for <name>`
   and nothing can restore it (`core/dispatch.nim:340-343`,
   `core/niffler.nim:505-507`, `main.nim:74-75`).
2. **The `defines` parameter is broken on the wire**: typed `object` (from
   `JsonNode`) while only a JSON array works, and its description is cut
   mid-sentence with the rest glued to the tool description
   (`main.nim:51`, `70-72`, `89`; `sdk/niffler/sdk.nim:920-921`, `939-958`).
3. **A refused registration is invisible** — a colliding tool name makes core
   drop the whole registration while the component keeps running and `spawn`
   returned `ok` (`core/catalog.nim:654-673`, `sdk/niffler/sdk.nim:541-542`).
   This is the one failure a self-extending agent hits and cannot diagnose from
   its own tool output.
4. **The advertised 300 s build timeout is not the real one**: the Nim compile
   uses `runCmd`'s 120 000 ms default (`main.nim:96-99`,
   `sdk/niffler/procutil.nim:70`), and neither failure shape carries an exit code,
   so a timeout reads as a compile error.
5. **A cancelled turn leaves the compiler running**: no `x-harness.sessionId`, no
   `cancel.build` subscription (`main.nim:49`; contrast
   `components/bash/main.nim:55-94`) — the reply is abandoned, the CPU is not.

