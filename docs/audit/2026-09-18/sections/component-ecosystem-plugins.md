# Worklist slice: Component ecosystem (plugins)

From `worklist.tsv` (8 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

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

## A544 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "A manifest entry may carry `defines` (an array of `-d:`-style prepends) and `env` (an array of `NAME=value` strings). Both are passed through — `defines` to the builder, `env` to the spawn …"
- CODE: `components/plugins/main.nim:249-250` (passed regardless of `lang`), `main.nim:89-95` (read only in the Nim branch), `main.nim:111-130` (files: Go branch only)
- FIX: update [doc-edit] — "`defines` is a **Nim-only** affordance: a `lang: "go"` or `lang: "ts"` manifest entry that declares `defines` builds fine and silently ignores them — verify by behaviour, not by manifest."

## A545 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "A Go entry may declare `"sources": ["component/helper.go", ...]`; these must be non-symlink, same-package `.go` files beside `main`, and the builder compiles them as one package."
- CODE: `components/plugins/main.nim:251-255` (keyed by `extractFilename()` — the directory is *flattened*), `main.nim:25-34`
- FIX: update [doc-edit] — say that only the **basename** survives: "`sources` paths are flattened to their filename before they reach the builder, so two files with the same basename collide and subdirectories cannot exist in the build directory; the cap is 64 files / 2 MB, and a subpackage (`component/foo/bar.go`) is not buildable at all."

## A600 (verified)
source: `components/dialog.md`

- MANUAL: MANUAL: "`components/dialog/dialog.sh` — a whole bash component with no SDK at all."
- CODE: components/dialog/dialog.sh:1-19 (envelope + bare `reg.publish` written by hand), docs/WIRE.md:44-47 (the registration shape it speaks)
- FIX: fix: none — verified, and it should stay the teaching example [verified]

