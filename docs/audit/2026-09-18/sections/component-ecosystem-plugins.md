# Worklist slice: Component ecosystem (plugins)

From `worklist.tsv` (6 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A046 (trim)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 715-720 points at `gokr/niffler-weather` as the sample package
- CODE: `manifest.yaml:128-138` also documents the MCP bridge as a spawned-component example
- FIX: keep; add a pointer to `components/dialog/dialog.sh` (a whole bash component, no SDK) as the third reference shape.

## A219 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 677–679 "plain GitHub repos with a `niffler.json` manifest at the root (one repo = one package = N components)"
- CODE: the manifest contract is never spelled out anywhere in MANUAL — `name` + `components: [{name, lang, main, sources?, env?, defines?, interactive?}]` (`components/plugins/main.nim:153–154,163–230`)
- FIX: add a small schema block: "`niffler.json` = `{name, components: [{name, lang: "nim"|"go"|"ts", main, sources?, env?, defines?, interactive?}]}`; `lang` is validated (`:219–221`), `main`/`sources` must exist and not be symlinks (`:222–227`), and a manifest with no components is rejected (`:230`)."

## A220 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (`defines`, `env` never mentioned)
- CODE: `defines` is an array validated per component (`components/plugins/main.nim:205–213`) and forwarded to `builder.build` (`:249–256`); `env` is an array of `NAME=value` strings passed through to `core.spawn` (`:257–258`, and echoed in the install result)
- FIX: one line each — "`defines` (array of `-d:`-style prepends) and `env` (array of `NAME=value`) are passed through to the builder and the spawn, so a package can carry its own configuration without editing the manifest."

## A221 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 688–691 "`plugin_install {repo, version?}` — clone `var/plugins/<pkg>@<ref>/` … then `core.spawn` each service component"
- CODE: the clone is refused when a record for the package already exists ("already installed … — use plugin_update for a newer version, or plugin_remove first", `components/plugins/main.nim:348–351`), and the clone is shallow (`git clone --depth 1`, `:361–363`) with an untracked `go.work` written in to redirect a repo's sibling-checkout SDK dependency (`writeGoWork`, `:274,369`)
- FIX: add "`plugin_install` on an already-installed package is an error, not a re-install — use `plugin_update` (or `plugin_remove` first); the clone is shallow and carries an untracked `go.work` for Go packages that expect a sibling SDK checkout."

## A222 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 680 "`plugin_search {query?}` — GitHub topic search; returns repo, description, stars"
- CODE: a zero-hit multi-word query is retried with fewer words, and the reply carries `query` (winning), `attempts`, `tried` and an install `hint` (`components/plugins/main.nim:520–600`); results do not include an install count
- FIX: extend the row: "returns `repo`, `description`, `stars` (plus the winning `query` and per-attempt diagnostics — GitHub ANDs query words, so a zero-hit query is retried with fewer words)."

## A223 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 712 "The GitHub API is used unauthenticated (60 req/h/IP)."
- CODE: verified — no token or `Authorization` header is read anywhere in `components/plugins/main.nim` (headers set at `:41`); no `NIF_GITHUB_TOKEN` exists
- FIX: none (keep the warning; it is the honest rate limit).

