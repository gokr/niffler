# Worklist slice: component: lsp

From `worklist.tsv` (13 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A401 (doc-edit)
source: `components/lsp.md`

- MANUAL: Make the server binary available (PATH or a fallback dir above), or run `make install-lsp` (`Makefile:645-650` → `scripts/install-lsp.sh`).

## A402 (doc-edit)
source: `components/lsp.md`

- MANUAL: Add a registry entry — via the `lsp_registry add` tool (`main.nim:962-1009`), the niffler-tui `/lsp` picker (documented `docs/MANUAL.md:1000-1005`), or by hand-writing `$XDG_CONFIG_HOME/niffler-lsp/servers.json` (example `docs/MANUAL.md:1008-1014`).

## A403 (doc-edit)
source: `components/lsp.md`

- MANUAL: Nothing else: `OPERATIONS` and the tool surface are language-independent (`main.nim:48-50`, `:1063-1080`); `tests/t_lsp.nim:1-13` asserts exactly this ("a new language with zero code changes, live on the next call"). This is the AGENTS.md rule, stated in the component header (`main.nim:9-12`) and the manifest comment (`manifest.yaml:149-150`).

## A407 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:955-956` "structured `[E_LSP_*]` errors (`E_LSP_UNAVAILABLE`, `E_LSP_UNSUPPORTED`, `E_LSP_TIMEOUT`, `E_LSP_SCOPE`, `E_NOT_FOUND`)"
- CODE: `main.nim:290`, `:377`, `:403` (E_LSP_PROTOCOL); `:109`, `:134`, `:997` (E_LSP_REGISTRY); `:990` (E_LSP_CONFLICT); `:864` (E_NOT_TEXT); `:811-837` (E_BAD_SHAPE)
- FIX: add the missing codes to the list — `E_LSP_PROTOCOL` (server crash/bad frame), `E_LSP_REGISTRY` (invalid registry JSON/entry), `E_LSP_CONFLICT` (extension already mapped), `E_NOT_TEXT` (binary file), `E_BAD_SHAPE` (missing/invalid argument).

## A408 (code-bug?)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:302` "`NIF_LSP_BIN_DIRS` | extra directories searched for server binaries beyond PATH (tilde-expanded)"
- CODE: `components/lsp/roots.nim:77-82` (splits on `PathSep`, no tilde expansion — a `~/x` entry never matches)
- FIX: either drop "(tilde-expanded)" for "colon-separated **absolute** directories", or add `expandTilde` in `fallbackBinDirs`; the doc-side fix is cheaper and the current claim is wrong.

## A409 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:1022-1024` "~/.local/bin, ~/.dotnet/tools" (fallback dirs)
- CODE: `roots.nim:82` also includes `$HOME/bin`
- FIX: add `~/bin` to the list (and in the `lsp` tool description at `main.nim:1077` if you want them to agree).

## A410 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: absent (limits/timeouts unmentioned in `:934-1031`; only the caps at `:953`)
- CODE: `main.nim:42-46`, `:232`, `:1079`
- FIX: add a short paragraph after `:963` — "Each query has a 60 s budget and `initialize` 30 s inside the tool's 90 s envelope; diagnostics wait 1.5 s after the first push. At most eight server processes are kept alive (LRU-evicted), one per (server, workspace root), and any timeout or protocol error retires that instance so the next query starts fresh."

## A411 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:975-980` "Paths are confined to the conversation workspace … `..` and absolute escapes are refused" (no root/marker story; MANUAL:251-254 mentions markers only in passing)
- CODE: `main.nim:838-871`, `roots.nim:23-68`
- FIX: add two sentences in `### How the model uses it` — "Without an explicit `workspaceRoot`, the server root is the file's nearest module marker for its language (go.mod/go.work, Cargo.toml, tsconfig.json/package.json, pyproject.toml, `*.nimble`/config.nims, compile_commands.json/CMakeLists.txt), else the workspace; the walk never climbs above the workspace. Unknown extensions fall back to `.git`, so an unregistered language still gets the clone root."

## A412 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: absent — the marker table is per-language code, not registry data
- CODE: `roots.nim:29-36` (`case ext` table) vs registry fields at `main.nim:105-137` (no `rootMarkers`)
- FIX: document the degradation and close the loop by exposing an optional `rootMarkers` array per registry entry (data, per AGENTS.md): "Root markers per extension are built in; a language added purely as a registry entry keeps the built-in fallback (`.git`, then the workspace) until a marker list for it is added." If a config field is not wanted, state the fallback explicitly so users know why a monorepo root may be chosen.

## A413 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: absent — the `didSave` echo
- CODE: `main.nim:902-909`, capability `:271-273`
- FIX: one sentence in `### How the model uses it` — "After `didOpen` the component echoes the current bytes as `didSave`, because the nimsuggest-based Nim servers publish diagnostics only on save (it is a no-op for open-push servers such as pyright, clangd and bash-language-server)."

## A415 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:1028-1030` "The registry is re-read on every call, so edits take effect immediately."
- CODE: `main.nim:150-158`
- FIX: append — "A malformed file or entry is skipped with a warning on stderr (visible in `var/logs/lsp.log`) instead of failing the query."

## A416 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:1023` "`make install-lsp` installs them idempotently (Go, Nim and TS are mandatory … the rest are y/n prompts, `--all` for unattended installs …)"
- CODE: `Makefile:645-650`, `scripts/install-lsp.sh:23`, `:36-44`
- FIX: name the invocation (`make install-lsp ALL=1` ⇒ `--all`), note that a non-TTY run skips the optional languages, that the target dir is `$NIF_LSP_BIN` else `~/.local/bin` (worth an env-table row next to `:302`), that nothing is installed with `sudo`, and that missing runtimes (JDK/.NET/rustup) are reported with the exact command rather than auto-installed.

## A417 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:1022-1024` lists the nine built-in servers (correct — matches `main.nim:74-93`)
- CODE: `main.nim:69-76`
- FIX: optional one-clause note: "Nim's default is `nimtortoise`; `nimlangserver` and `nimlsp` stay selectable by adding an entry of that name."

