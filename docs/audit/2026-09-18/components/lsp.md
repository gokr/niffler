# docs-audit: `components/lsp` (Nim)

Audit target: `/home/gokr/git/nifflerprod/components/lsp/` (`main.nim` 1439 lines, `roots.nim` 108).
Method: grep + windowed reads; every claim carries `file:line`. Read-only.

## 1. What it offers

- One generic seam over **any stdio language server**; the component knows no
  languages — extension → server is *data* (`components/lsp/main.nim:1-12`, `:59`).
- Three model-facing tools — `lsp` (8 operations), `lsp_servers`, `lsp_registry`
  (`main.nim:1063`, `:1082`, `:1087`) — plus the standard hidden `selftest`
  (`main.nim:1437` → `sdk/niffler/sdk.nim:155`).
- Read-only semantic intelligence: diagnostics, file outline (`documentSymbol`),
  repo-wide `workspaceSymbol`, `goToDefinition`, `findReferences`,
  `goToImplementation`, `hover`, and `warmup` (pre-start servers, `main.nim:48`).
- Per query: transient document lifecycle (`didOpen` with current bytes →
  request → `didClose`, `main.nim:895-925`), one server instance per
  (server, workspace) reused across queries (`main.nim:216`, `:430`).
- Results are capped (100 locations / 16 000 chars, `main.nim:40-41`) with
  truncation metadata; failures are structured `[E_LSP_*]` codes (`main.nim:55`).
- Scope: `path` must stay inside the workspace root, `..` components refused
  (`main.nim:853-856`); unconfigured extension/missing binary degrades to
  `E_LSP_UNAVAILABLE` with the fix in the message (`main.nim:448-474`, `:874`).

## 2. Tools

| Tool | One-line purpose (doc comment) | `x-harness` flags | Exposure |
|---|---|---|---|
| `lsp` | Query a language server for precise, semantic code intelligence (8 operations). `main.nim:1063-1080` | `timeoutMs: 90000`, `onDemand: true`, `effect: "read"`, `workspace: {pathFields: ["path"]}` (`main.nim:1079`) | discover-only (`onDemand`) |
| `lsp_servers` | List configured language servers: name, launch command, extension map, provenance (`builtin`/`user`). `main.nim:1082-1085` | `timeoutMs: 10000`, `onDemand: true`, `effect: "read"` | discover-only |
| `lsp_registry` | Mutate the language-server registry: which server binary handles which file extension. `main.nim:1087-1098` | `timeoutMs: 10000`, `onDemand: true`, `approval: "always"` (no `effect` → default write) | discover-only, approval-gated |
| `selftest` | Standard hidden component self test used by `/doctor`; deep mode boots every configured server against throwaway fixtures (`main.nim:1208`, `:1330`, registration `main.nim:1437`; `sdk/niffler/sdk.nim:155-167` sets `hidden: true`) | hidden, registered by the SDK helper | hidden |

- `lsp` params: `operation` (enum of the 8 ops), `path`, `query`, `line`,
  `character`, `workspaceRoot`; required `operation` + `path`
  (`main.nim:1064-1078`). `line`/`character` are one-based UTF-16 and required
  for everything except `diagnostics`/`documentSymbol`/`workspaceSymbol`
  (`main.nim:1069-1073`, enforced `:831-837`).
- `lsp_registry` params: `action` (`add`|`remove`), `name`, `command`,
  `extensions`, `initializationOptions`; schema declares no required list
  (`main.nim:1088-1095`) — add/remove self-validate (`main.nim:970-983`).
- `lsp_sweep` is **not** a tool here: the only occurrence in the repo is a
  scratch artifact path, `var/nimcache/scratch_lsp_sweep/lsp_sweep.json`
  (no registration in `components/lsp/main.nim` or `tests/`).
- Registry tool behavior worth knowing: `add` requires a name of
  `[a-z0-9-]` (`main.nim:970-972`), refuses an extension already mapped to a
  *different* server with `E_LSP_CONFLICT` (`main.nim:987-992`), writes
  atomically (`main.nim:931-937`); `remove` only touches user entries and
  otherwise fails `E_LSP_UNAVAILABLE` (`main.nim:1010-1019`).
- `lsp_servers` returns `{servers: [{name, command, extensions, source}],
  path, note}` (`main.nim:939-960`).

## 3. Configuration

### Env vars

| Var | file:line | Default | Notes |
|---|---|---|---|
| `NIF_LSP_REGISTRY` | `main.nim:100` | — | absolute path of the user registry; overrides XDG (`main.nim:97-103`) |
| `XDG_CONFIG_HOME` | `main.nim:102` | `~/.config` | base of the registry path → `$XDG_CONFIG_HOME/niffler-lsp/servers.json` (`main.nim:103`) |
| `NIF_LSP_BIN_DIRS` | used `main.nim:446`, `:451`, `:1249`; parsed `roots.nim:77-82` | — | colon-separated extra dirs searched for server binaries beyond PATH |
| `NIF_LSP_BIN` | `scripts/install-lsp.sh:23` | `$HOME/.local/bin` | installer-only: where `install-lsp` puts downloaded binaries (not read by the component) |

No other knobs: `grep -n 'getEnv' components/lsp/*.nim` yields only
`NIF_LSP_REGISTRY`, `XDG_CONFIG_HOME` and `NIF_LSP_BIN_DIRS`. Timeouts and
instance caps are compile-time constants (`main.nim:42-46`, `:741-744`).

### Registry file (the declarative seam)

- Path: `$NIF_LSP_REGISTRY`, else `$XDG_CONFIG_HOME/niffler-lsp/servers.json`
  (default `~/.config/niffler-lsp/servers.json`) — `main.nim:97-103`.
- Load: built-in defaults first, the user file **replaces entries by name**;
  re-read on every call (`main.nim:138-159`); a malformed file or entry is
  skipped with a warning on stderr, never fatal (`main.nim:150-158`).
- Entry fields (`parseConf`, `main.nim:105-137`): `command` (argv array, or a
  plain string split on whitespace — no quoting), `extensions` (map
  `".ext" → "languageId"`, keys must start with `.`, lowercased),
  optional `initializationOptions` (passed through to `initialize`,
  `main.nim:135-136`, used at `:477`). No `rootMarkers` field exists.
- Built-in defaults, 9 servers (`main.nim:67-93`): `gopls` (.go),
  `nimtortoise` (.nim/.nims), `typescript-language-server --stdio`
  (.ts/.tsx/.mts/.cts/.js/.jsx/.mjs/.cjs), `pyright-langserver --stdio`
  (.py/.pyi), `rust-analyzer` (.rs), `clangd` (.c/.h/.cpp/.cc/.cxx/.hpp/.hh),
  `bash-language-server start` (.sh/.bash), `jdtls` (.java), `csharp-ls` (.cs).
  Nim deliberately defaults to nimtortoise; nimlangserver/nimlsp remain
  user-registry-selectable by name (`main.nim:69-76`).
- Lookup: when two servers claim one extension, the alphabetically first name
  wins (`serverFor`, `main.nim:161-173`).
- Binary resolution: PATH first, then `NIF_LSP_BIN_DIRS` and
  `~/go/bin`, `~/.nimble/bin`, `~/.local/bin`, `~/.dotnet/tools`, `~/bin`
  (`roots.nim:75-83`), with an executable-bit check (`roots.nim:85-107`).

### Adding a language with zero code changes

1. Make the server binary available (PATH or a fallback dir above), or run
   `make install-lsp` (`Makefile:645-650` → `scripts/install-lsp.sh`).
2. Add a registry entry — via the `lsp_registry add` tool
   (`main.nim:962-1009`), the niffler-tui `/lsp` picker (documented
   `docs/MANUAL.md:1000-1005`), or by hand-writing
   `$XDG_CONFIG_HOME/niffler-lsp/servers.json` (example `docs/MANUAL.md:1008-1014`).
3. Nothing else: `OPERATIONS` and the tool surface are language-independent
   (`main.nim:48-50`, `:1063-1080`); `tests/t_lsp.nim:1-13` asserts exactly
   this ("a new language with zero code changes, live on the next call").
   This is the AGENTS.md rule, stated in the component header
   (`main.nim:9-12`) and the manifest comment (`manifest.yaml:149-150`).

`make install-lsp` detail: mandatory Go/Nim/TS, optional languages are y/n
prompts (empty = yes), `--all` (= `make install-lsp ALL=1`) installs
unattended, a non-TTY run skips optional languages, never `sudo`, only writes
under `$HOME`; missing runtimes (JDK/.NET/rustup) are not auto-installed and
the failure names the command (`scripts/install-lsp.sh:12-19`, `:23`, `:36-44`).

### Workspace / root handling and timeouts

- `path` is resolved against `workspaceRoot`; the core's
  `x-harness.workspace {pathFields: ["path"]}` extension pre-resolves relative
  paths against the **conversation workspace** (`main.nim:1079`, `:485-486`,
  `:843-846`). A caller-supplied relative `workspaceRoot` resolves against the
  harness root, and with no `workspaceRoot` the root is the harness root
  (`main.nim:838-848`).
- Unless the caller pins a root, the server root is **derived**: walk up from
  the file to the nearest per-language marker — go.mod/go.work, Cargo.toml,
  tsconfig.json/package.json, pyproject.toml/setup.py/setup.cfg,
  `*.nimble`/config.nims, compile_commands.json/CMakeLists.txt — always
  `.git`, else the workspace; the walk never goes above the workspace
  (`main.nim:868-871`, `roots.nim:23-36`, `:55-68`).
- `warmup` (and core on `ev.workspace.opened`, `main.nim:1030-1045`) censuses
  a directory: ≤5 000 files, 2 s budget, junk dirs skipped, at most **2**
  servers pre-started (`main.nim:741-744`, `:749-806`), then publishes
  `ev.lsp.warm` with `{workspace, warmed, skipped}` (`main.nim:1049-1054`).
- Timeouts/limits: per-operation 60 s (`QUERY_TIMEOUT_MS`, `main.nim:44`),
  `initialize` 30 s (`main.nim:45`), diagnostics settle 1.5 s (`main.nim:43`),
  tool envelope cap 90 s (`main.nim:1079`), ≤8 live server processes with LRU
  eviction (`main.nim:42`, `:232-242`), 4 KB stderr tail for error messages
  (`main.nim:46`, `:258`).
- Nim-family quirk encoded in the flow: because all nimsuggest-based servers
  publish diagnostics only on save, the component echoes the just-opened bytes
  as `didSave` after `didOpen` (`main.nim:271-273`, `:902-909`).

## 4. MANUAL placement

- Existing: `## Language servers (\`lsp\`)` — **docs/MANUAL.md:934**, section
  body `:934-1031` (next heading `## Background processes` at `:1033`);
  TOC entry `docs/MANUAL.md:20`; sub-headings `### The tools` `:944`,
  `### How the model uses it` `:966`, `### How the user adds a language` `:996`.
- Related, already correct: shipped-components row `docs/MANUAL.md:66`;
  env rows `:301-302`; state/config table `:243`, `:251-254`;
  `/doctor deep` behavior `:1318-1322`; Common tasks `:2276`; `make install-lsp`
  `:2276`.
- Proposed additions (smallest edits, no new section): extend the `lsp` row
  and the tools table in place; add a `### Limits and timeouts` paragraph after
  `:963`; add two sentences on root derivation + the didSave echo in
  `### How the model uses it` (after `:980`); complete the error-code list at
  `:955-956`; extend `### How the user adds a language` with the conflict rule
  and the `ALL=1`/`--all` note.

The documented path "install a language server → the agent can ask for
definitions" is **complete** today (install `:1022-1026` → registry `:996-1030`
→ tool use `:944-996`), but three things on that path are undocumented:
`E_LSP_CONFLICT` (a second install attempt fails until the old mapping is
removed), the root-derivation/marker rule, and the timeout/limit envelope.

## 5. DELTA list

- MANUAL: `docs/MANUAL.md:66` "| `lsp` | Nim | optional | language-server seam: one `lsp` tool — `diagnostics` … `hover` —" (no `warmup`, no `lsp_servers`/`lsp_registry`) | CODE: `components/lsp/main.nim:1063`, `:1082`, `:1087`, ops `:48-50` | FIX: update row — replace "one `lsp` tool" with "the `lsp` tool (eight operations — add `warmup` to the list), plus `lsp_servers` (list the merged registry) and `lsp_registry` (add/remove a server entry, approval-gated); all on-demand". Keep the existing "never code" sentence.
- MANUAL: `docs/MANUAL.md:948` "| `lsp {operation, path, line?, character?}` |" | CODE: `components/lsp/main.nim:1063-1078` | FIX: update signature to `lsp {operation, path, query?, line?, character?, workspaceRoot?}` and add one clause: "`workspaceRoot` pins the server root; without it the root is derived from the file's nearest module marker (`go.mod`, `Cargo.toml`, `tsconfig.json`/`package.json`, `pyproject.toml`, `*.nimble`, …), falling back to the workspace."
- MANUAL: `docs/MANUAL.md:950` "`lsp_registry {action: add|remove, name, command, extensions?}` | Mutate the user registry (approval-gated write); `add` also overrides a built-in of the same name" | CODE: `components/lsp/main.nim:970-992`, `:1017-1019` | FIX: update — "`add` takes `{name (lowercase letters/digits/hyphens), command, extensions: {".ext": "languageId"}, initializationOptions?}`, overrides a built-in of the same name, and refuses an extension already mapped to another server with `E_LSP_CONFLICT` (remove that mapping first). `remove` deletes user entries only."
- MANUAL: `docs/MANUAL.md:955-956` "structured `[E_LSP_*]` errors (`E_LSP_UNAVAILABLE`, `E_LSP_UNSUPPORTED`, `E_LSP_TIMEOUT`, `E_LSP_SCOPE`, `E_NOT_FOUND`)" | CODE: `main.nim:290`, `:377`, `:403` (E_LSP_PROTOCOL); `:109`, `:134`, `:997` (E_LSP_REGISTRY); `:990` (E_LSP_CONFLICT); `:864` (E_NOT_TEXT); `:811-837` (E_BAD_SHAPE) | FIX: add the missing codes to the list — `E_LSP_PROTOCOL` (server crash/bad frame), `E_LSP_REGISTRY` (invalid registry JSON/entry), `E_LSP_CONFLICT` (extension already mapped), `E_NOT_TEXT` (binary file), `E_BAD_SHAPE` (missing/invalid argument).
- MANUAL: `docs/MANUAL.md:302` "`NIF_LSP_BIN_DIRS` | extra directories searched for server binaries beyond PATH (tilde-expanded)" | CODE: `components/lsp/roots.nim:77-82` (splits on `PathSep`, no tilde expansion — a `~/x` entry never matches) | FIX: either drop "(tilde-expanded)" for "colon-separated **absolute** directories", or add `expandTilde` in `fallbackBinDirs`; the doc-side fix is cheaper and the current claim is wrong.
- MANUAL: `docs/MANUAL.md:1022-1024` "~/.local/bin, ~/.dotnet/tools" (fallback dirs) | CODE: `roots.nim:82` also includes `$HOME/bin` | FIX: add `~/bin` to the list (and in the `lsp` tool description at `main.nim:1077` if you want them to agree).
- MANUAL: absent (limits/timeouts unmentioned in `:934-1031`; only the caps at `:953`) | CODE: `main.nim:42-46`, `:232`, `:1079` | FIX: add a short paragraph after `:963` — "Each query has a 60 s budget and `initialize` 30 s inside the tool's 90 s envelope; diagnostics wait 1.5 s after the first push. At most eight server processes are kept alive (LRU-evicted), one per (server, workspace root), and any timeout or protocol error retires that instance so the next query starts fresh."
- MANUAL: `docs/MANUAL.md:975-980` "Paths are confined to the conversation workspace … `..` and absolute escapes are refused" (no root/marker story; MANUAL:251-254 mentions markers only in passing) | CODE: `main.nim:838-871`, `roots.nim:23-68` | FIX: add two sentences in `### How the model uses it` — "Without an explicit `workspaceRoot`, the server root is the file's nearest module marker for its language (go.mod/go.work, Cargo.toml, tsconfig.json/package.json, pyproject.toml, `*.nimble`/config.nims, compile_commands.json/CMakeLists.txt), else the workspace; the walk never climbs above the workspace. Unknown extensions fall back to `.git`, so an unregistered language still gets the clone root."
- MANUAL: absent — the marker table is per-language code, not registry data | CODE: `roots.nim:29-36` (`case ext` table) vs registry fields at `main.nim:105-137` (no `rootMarkers`) | FIX: document the degradation and close the loop by exposing an optional `rootMarkers` array per registry entry (data, per AGENTS.md): "Root markers per extension are built in; a language added purely as a registry entry keeps the built-in fallback (`.git`, then the workspace) until a marker list for it is added." If a config field is not wanted, state the fallback explicitly so users know why a monorepo root may be chosen.
- MANUAL: absent — the `didSave` echo | CODE: `main.nim:902-909`, capability `:271-273` | FIX: one sentence in `### How the model uses it` — "After `didOpen` the component echoes the current bytes as `didSave`, because the nimsuggest-based Nim servers publish diagnostics only on save (it is a no-op for open-push servers such as pyright, clangd and bash-language-server)."
- MANUAL: `docs/MANUAL.md:981-987` "runs a bounded extension census (stops at 5 000 files or a 2 s budget) and pre-starts servers for the most prevalent languages" | CODE: `main.nim:741-744`, `:1049-1054` | FIX: add "(at most two servers; `node_modules`, `vendor`, `dist`, `build`, `target` and other junk dirs are skipped) and publishes `ev.lsp.warm` with `{workspace, warmed, skipped}` so UIs can show which servers came up."
- MANUAL: `docs/MANUAL.md:1028-1030` "The registry is re-read on every call, so edits take effect immediately." | CODE: `main.nim:150-158` | FIX: append — "A malformed file or entry is skipped with a warning on stderr (visible in `var/logs/lsp.log`) instead of failing the query."
- MANUAL: `docs/MANUAL.md:1023` "`make install-lsp` installs them idempotently (Go, Nim and TS are mandatory … the rest are y/n prompts, `--all` for unattended installs …)" | CODE: `Makefile:645-650`, `scripts/install-lsp.sh:23`, `:36-44` | FIX: name the invocation (`make install-lsp ALL=1` ⇒ `--all`), note that a non-TTY run skips the optional languages, that the target dir is `$NIF_LSP_BIN` else `~/.local/bin` (worth an env-table row next to `:302`), that nothing is installed with `sudo`, and that missing runtimes (JDK/.NET/rustup) are reported with the exact command rather than auto-installed.
- MANUAL: `docs/MANUAL.md:1022-1024` lists the nine built-in servers (correct — matches `main.nim:74-93`) | CODE: `main.nim:69-76` | FIX: optional one-clause note: "Nim's default is `nimtortoise`; `nimlangserver` and `nimlsp` stay selectable by adding an entry of that name."

## 6. Not user-facing

- `roots.nim` is a pure, side-effect-free helper module (root derivation +
  PATH-fallback binary resolution) imported by the component and by
  `tests/t_lsp.nim` (`roots.nim:1-17`) — no bus surface, nothing to document.
- `lsp_sweep` does not exist as a tool; only the scratch artifact
  `var/nimcache/scratch_lsp_sweep/lsp_sweep.json` remains, so no MANUAL entry is
  warranted (if `lsp_sweep` was an internal probe, it is gone from source).
- `selftest` is registered hidden (`sdk/niffler/sdk.nim:167`) and reached only
  through `doctor`/`/doctor` (documented at `docs/MANUAL.md:1318-1322`) — the
  lsp section should not list it as a model-facing tool.
- `ev.lsp.warm` is a UI/inspection event (`main.nim:1049-1054`); documenting it
  in the lsp section is enough, no other doc needs it.
