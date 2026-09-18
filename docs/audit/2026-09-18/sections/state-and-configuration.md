# Worklist slice: State and configuration

From `worklist.tsv` (10 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A019 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 239 "process lifetime — components read env once at boot; **a config change is `core.kill` + `core.spawn`**"
- CODE: children inherit **core's** environment, not the shell you type in: `core/supervisor.nim:117-124` (`startChild`, "env = nil inherits the parent environment")
- FIX: "components read env once at boot, so a change needs `core.kill` + `core.spawn` — **except** a variable exported in the shell that started core: the child inherits core's environment, so a shell-only change requires restarting the harness (or putting it in `.env`, which every component reloads at its own startup: `sdk/niffler/sdk.nim:771`). Manifest-level settings (`NIF_STORE_BACKEND`) are resolved by core at boot." Same wording should replace MANUAL 895 ("read at boot (config change = `core.kill` + `core.spawn`)").

## A020 (doc-edit, dup:mechanisms-obs.md for)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 244 `var/` row lists `bin/, logs/, models/, nats-url/nats-pid, processes/, repomap-tags/, fetch/, captures/, store.db`
- CODE: missing `toolout/` (`components/bash/main.nim:27-34`), `approval-sources/` (`core/approval.nim:99-121`), `mcp-results/` (`components/mcp-bridge/operations.go:152`), `review-receipts/` (`components/git/main.nim:364`), `fabric-cache/` (`components/fabric/fabric.nim:117`), `plugins/` (`components/plugins/main.nim:337`), `nats-monitor-url`
- FIX: add them; this table is the map a debugging operator uses. `[dup]` mechanisms-obs.md for `approval-sources/`.

## A021 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 245-250 "Home / project files … skills trees (project `.agents|.claude|.opencode/skills` > bundled `skills/` > home `~/.niffler/skills` + agent-standard dirs > `~/.config/opencode/skills`)"
- CODE: correct — the search path is exactly project `.agents/.claude/.opencode/skills`, bundled `<repo>/skills`, home `.agents/.claude/.opencode/.niffler/skills`, then `$XDG_CONFIG_HOME/opencode/skills`, first match wins, fresh walk per call, with the compiled-in `(baked)` tree as the last resort (`components/skills/main.nim:200-220`)
- FIX: add the baked last-resort source (only mentioned in the `NIF_SKILLS_BUNDLED_DIR` env row today).

## A022 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 254 "The **repomap, lsp and skills** components additionally treat `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo *markers*"
- CODE: wrong on both counts — `skills` walks no build files at all (fixed dirs, `components/skills/main.nim:200-215`), and the two that do use different sets: lsp per language (`.go`→`go.mod`/`go.work`, TS→`tsconfig.json`/`package.json`, `.nim`→`*.nimble`/`config.nims`, `components/lsp/roots.nim:29-34`) and repomap (`package.json`, `Cargo.toml`, `go.mod`, `config.nims`, `components/repomap/main.nim:134`)
- FIX: "The `lsp` and `repomap` components treat build files (`go.mod`/`go.work`, `tsconfig.json`/`package.json`, `*.nimble`/`config.nims`, `Cargo.toml`) as repo *markers* — where to walk from, not configuration they parse. `skills` uses fixed directories only."

## A023 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 240-241 "boot decisions are environment, identity/selection is the store, per-conversation choice is the conversation header, display is the browser"
- CODE: matches `core/conversation.nim:203-215` (header fields), `core/dispatch.nim:394-402` (`profile` records), `ui/frontend/src/lib/*` (localStorage) ✔
- FIX: none.

## A027 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 233/239 "`.env` (root, gitignored) holds secrets and local overrides; shell env wins"
- CODE: also true, and the loader is hardened beyond what MANUAL says: 1 MiB cap, symlinks/multiply-linked files refused, no `$VAR` expansion (`sdk/dotenv.nim:1-27,40-52`)
- FIX: one sentence — "`.env` must be a plain regular file: symlinked or hardlinked copies are refused, the file is capped at 1 MiB, and values are never variable-expanded".

## A110 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 239 and 895** — "a config change is `core.kill` + `core.spawn`" is incomplete: children inherit core's environment (`core/supervisor.nim:117-124`), so a variable exported only in the shell that launched core survives a kill+spawn unchanged.

## A264 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:240 (state table, Environment/.env row) "components read env once at boot; a config change is `core.kill` + `core.spawn`" (repeated MANUAL:336 and MANUAL:879)
- CODE: the supervisor passes **no env** to children — core/supervisor.nim:118-120 comment + :160 `startProcess("/bin/sh", workingDir = sup.root, …)` inherits core's environment, so a variable **exported in core's shell env** cannot be changed by kill+spawn at any level; children do re-read `.env` itself at their own boot (sdk/niffler/sdk.nim:771, sdk/go/component.go:414, sdk/ts/src/component.ts:242, core/session.nim:37)
- FIX: "`.env` edits apply when the component is respawned (`core.kill` + `core.spawn`); a change to a variable *exported in the shell environment* requires restarting the harness — children inherit core's environment and shell env beats `.env`."

## A460 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Spool naming and boot wipe**: `var/processes/pN.out` / `pN.err` (`main.nim:295-296`), all `*.out`/`*.err` deleted at boot (`main.nim:130-141`), ids continue from the persisted `nextId` and never restart at `p1` (`main.nim:106-113, 124, 293-294`). MANUAL:246 mentions only "`processes/` spools". → half a line; useful for debugging.

## A464 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:2182 `| provider | nickname (plus the active marker doc) | **redacted-at-rest** LLM provider registry` — WRONG, and contradicts MANUAL:241 ("credentials included").
- CODE: secrets stored plaintext, main.go:49-74, 403, oauth.go:681,738; redaction is response-only, main.go:77-95.
- FIX: update → "`{nickname, authType, protocol, apiKey|oauth{access,refresh,expires,accountId}, baseUrl, model, catalog, context, plugin, stripPrefix}`; **credentials are stored in plaintext — the store file itself is the secret**; tools return redacted summaries." (2 sentences; fold into the kind-table cell.)

