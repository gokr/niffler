# Worklist slice: State and configuration

From `worklist.tsv` (14 rows). `class` is one of
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

## A299 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:233-247 (state table; no `niffler-edit` row)
- CODE: `main.nim:474-481`
- FIX: add a row — `| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json` (else `~/.config/niffler-edit/undo.json`): last pre-edit bytes per file + per-conversation seen-state digests | durable |`. It is the only durable artifact this component owns; deleting it only loses undo history and unchanged-read stubs, never file content.

## A460 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Spool naming and boot wipe**: `var/processes/pN.out` / `pN.err` (`main.nim:295-296`), all `*.out`/`*.err` deleted at boot (`main.nim:130-141`), ids continue from the persisted `nextId` and never restart at `p1` (`main.nim:106-113, 124, 293-294`). MANUAL:246 mentions only "`processes/` spools". → half a line; useful for debugging.

## A464 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:2182 `| provider | nickname (plus the active marker doc) | **redacted-at-rest** LLM provider registry` — WRONG, and contradicts MANUAL:241 ("credentials included").
- CODE: secrets stored plaintext, main.go:49-74, 403, oauth.go:681,738; redaction is response-only, main.go:77-95.
- FIX: update → "`{nickname, authType, protocol, apiKey|oauth{access,refresh,expires,accountId}, baseUrl, model, catalog, context, plugin, stripPrefix}`; **credentials are stored in plaintext — the store file itself is the secret**; tools return redacted summaries." (2 sentences; fold into the kind-table cell.)

## A499 (doc-edit)
source: `components/skills.md`

- MANUAL: **D1 — MANUAL:250 precedence is wrong.** `project skills shadow home skills shadow bundled skills`
- CODE: `main.nim:205-213` puts `bundled` third, before all four `home` dirs (and MANUAL:737-741 says the same)
- FIX: `project > bundled > home > config`.

## A531 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "and everything derived is `var/` (regenerable — delete it and `make build` + a boot rebuilds the world)"
- CODE: `core/dispatch.nim:340-343` (the persisted `component` record holds only `{name, binary, policy, replicas, args, addedAt}` — no source), `core/niffler.nim:505-507` (boot then prints `core: WARNING missing binary for <name>` and skips it), `main.nim:74-75` (source lives only in `var/build`)
- FIX: update [wrong] — "everything derived is `var/`, **except agent-built components**: their source exists only under `var/build/` and their binary only under `var/bin/`, so `make clean` deletes both while the `component` record survives — the next boot warns `missing binary for <name>` and the component cannot be restored. Rebuild it with `builder.build` + `core.spawn`, or `core.remove` the record"

## A695 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`logs/` bus JSONL + child logs, `models/` catalog cache"
- CODE: components/logfile/main.nim:33-36,111-120
- FIX: update — [doc-edit] replace with "`logs/` bus JSONL + per-component JSONL with `.1`…`.N` rotations + child logs, `models/` catalog cache", so the state table names the sink's rotation generations and not only the child logs that share the directory.

## A753 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:365 "`store.db` (the store engine's file — exactly one owner)"
- CODE: `components/store-sqlite/main.go:81,136`, `components/store/main.nim:43,58`, `tools/store_migrate.nim:90-96`
- FIX: update — "…`store.db` (the SQLite engine's file) or `barrel-db` (the barrel engine's) — whichever `NIF_STORE_BACKEND` selected, plus its `.lock`, which exactly one `store` process may hold at a time."

## A754 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:361 "conversation headers, messages, the `provider` registry (credentials included)"
- CODE: `docs/MANUAL.md:2877-2897` (the kind table)
- FIX: none (verified) — the summary matches the table and the table matches the code.

