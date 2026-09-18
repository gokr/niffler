# Audit — `components/plugins` (Nim, main.nim 763 / versions.nim 71 lines)

MANUAL anchor: `## Component ecosystem (`plugins`)` at **docs/MANUAL.md:674**,
followed by `## Skills` at :721 — bullets :689-719, tool table :681-687.
Elsewhere: contents entry :17, shipped-component row :62 (and `--minimal`
exclusion :98), `NIF_GIT_MIRROR` row :277, `cli install` :443-447,
approval list :460, on-demand policy "plugins" :1477, store kind `plugin`
:2181, interactive-plugin startup :2243-2248, network-test note :2222-2224.
Shipped manifest: `manifest.yaml:36-42` (`binary: var/bin/plugins`,
`autostart: true`, `required: false`, `restart: on-failure`).

## 1. What it offers

The ecosystem front door: it discovers third-party component packages (plain
git repos carrying the GitHub topic `niffler-component`, main.nim:35) and
installs one as a shallow clone in `var/plugins/<slug>@<ref>/`, builds **every
component from source** through the `builder` component, then `core.spawn`s the
service ones (main.nim:1-22, 324-391). No registry, no binaries: the published
source is compiled locally with the same toolchain the harness uses for its own
extensions (main.nim:11-15). It records each install in the store as kind
`plugin` so update/remove know the repo, ref, directory and component list
(main.nim:18-21, 130-147). It also exposes five slash commands for the UI
(main.nim:724-761) and requires only plain `git` + network; the GitHub API is
used **unauthenticated** (main.nim:23-24, 39-41).

## 2. Tools

All five are registered with `"onDemand": true` and **no** `hidden`
(main.nim:520, 607, 628, 653, 700) → **discover-only**: absent from a
conversation's frozen direct toolset, reachable via `discover` + `invoke`
(docs/MANUAL.md:1283-1285, 1477) but directly callable by `cli call` /
`cli install` and by slash commands.

| Tool | file:line | doc-comment purpose | flags | args |
|---|---|---|---|---|
| `plugin_search` | main.nim:521 | Search GitHub for installable Niffler component packages; present results and let the user pick before installing | `onDemand` only — **no approval** | `query` (default `""`) |
| `plugin_installed` | main.nim:608 | List the packages installed on this harness (name, repo, pinned ref, current commit, components) | `onDemand` only | none |
| `plugin_install` | main.nim:629 | Install a package from GitHub: clone, build every component from source, spawn each service component | `approval: "always"`, `timeoutMs: 600000` (main.nim:628) | `repo` (required), `version` |
| `plugin_update` | main.nim:654 | Move a tag pin to the newer release/version tag (remove + reinstall) or pull a branch pin in place, rebuilding only when HEAD moved | `approval: "always"`, `timeoutMs: 600000` (main.nim:653) | `package` (required) |
| `plugin_remove` | main.nim:701 | `core.remove` each supervised component, delete the clone, drop the record | `approval: "always"`, `timeoutMs: 300000` (main.nim:700) | `package` (required) |

No tool carries `x-harness.workspace`, `sessionId`, `noSpawn` or
`sessionContext` — `repo` is a git URL, not a path. Approval count for one
install = 1 (`plugin_install`) + one per service `core.spawn`, because core
gates its own `spawn`/`remove` (core/dispatch.nim:273-276,
core/catalog.nim:75, 86) — matching docs/MANUAL.md:689-691. The nested
`builder.build` calls go component→component (`comp.request`,
sdk/niffler/sdk.nim:213-220) and so do **not** hit core's approval interceptor
(core/dispatch.nim:1556) — one install is not N+1 approval prompts, it is N+1.

Slash surface (one global namespace, every name component-prefixed,
main.nim:724-730): `/plugins` (main.nim:731), `/plugins-search` (:734),
`/plugins-install` (:741, params `repo` + `version`), `/plugins-update` (:755),
`/plugins-remove` (:759) — all bound `tool = <tool name>`, so the approval gate
still applies.

## 3. Configuration

**Env vars — exactly one** (`NIF_ROOT`/`NIF_NATS_URL` are SDK-wide):

| Var | file:line | Default | Effect |
|---|---|---|---|
| `NIF_GIT_MIRROR` | main.nim:355 (`getEnv`, stripped of `/` and spaces) | unset → `https://github.com/` | Clone host prefix: `mirror & "/" & repo & ".git"` (main.nim:355-359). Only the **clone** is mirrored — `resolveTag`/`defaultBranch`/search stay on `api.github.com` (main.nim:34, 86-127). Documented at docs/MANUAL.md:277. |

**No GitHub token knob**: `ghClient` sets only
`Accept: application/vnd.github+json` and a 30 s timeout (main.nim:39-41) —
unauthenticated API (docs/MANUAL.md:710), with anonymous *search* rate limits
tighter than the 60 req/h core API (`maxCalls = 6`, "stay clear of GitHub's
10 searches/min", main.nim:538). Timeouts, none of them documented for these
tools: HTTP 30 s per call (main.nim:40), `builder.build` 320 s (main.nim:256),
`core.spawn` 360 s (main.nim:235), `core.remove` 360 s (main.nim:405),
`git pull` 60 s (main.nim:436), `rev-parse` 15 s (main.nim:621),
`storeList` 10 s (main.nim:614). Requires `git` on `PATH`, checked only by
`plugin_install` (main.nim:641-642), plus live `builder`, `core` and `store`
peers (main.nim:235, 256, 136-147) — under `--minimal` none of them exists
(docs/MANUAL.md:98).

**Layout** — `var/plugins/<slug>@<ref>/` where `<slug>` is the **repo
basename**, not the manifest package name (`repoSlug`, main.nim:72-78;
`pkgSlug` = `slug & "@" & refTag`, main.nim:337-339), and `<ref>` is `head` for
a refless `file://` install (main.nim:338). Clone is shallow:
`git clone --depth 1 [--branch <ref>] <url> <dest>` (main.nim:361-363, 365-366).
Binaries always land in `var/bin/<component name>` (main.nim:244-245, 370).
The clone is post-processed by `writeGoWork`: an **untracked** `go.work`
(main.nim:282-283, 320-321) with `use` entries for exactly the modules the
manifest builds (:295-304) and `replace niffler.dev/sdk => <root>/sdk/go`
(:321), mirroring the module's own `go` directive *or* `go 1.24` (:313-316);
existing `go.work` files are left alone (:282-283) and `go.mod` is deliberately
never touched so `git pull --ff-only` stays clean (:279-281). `file://` URLs
are accepted (local repos/mirrors, main.nim:50-57) and `owner/name`,
`https://github.com/…`, `git@github.com:…` are normalized (main.nim:46-70).

**Manifest contract** (`niffler.json` at the clone root, main.nim:162-230) —
top level `{name, version, components[]}`; missing file → "no niffler.json in
the repo root — is this a component package?" (:163-166), missing `name`
(:171-172), missing/empty `components` (:173-176, :229-230).

| Field | file:line | Behaviour |
|---|---|---|
| `name` | :167 | **Package id**: the store record id, the duplicate check in `doInstall`, the `package` arg of update/remove (:348, :386, :641-644) |
| `version` | :168, :387 | Recorded verbatim in the record only — never compared during update (update resolves refs from GitHub, :677-679) |
| `components[].name` | :177-178, :230 | Component name = spawned component name = binary name |
| `components[].lang` | :179, :225-226 | **`nim` or `go` only** — anything else refuses (:225-226); TS components (`builder.build {lang: "ts"}`, components/builder/main.nim:69) are not installable through this path |
| `components[].main` | :180-182, :227-228 | Repo-relative, non-absolute, no `.`/`..`/empty segments (:157-160); must exist and **not be a symlink** (:227-228) |
| `components[].sources` | :196-201, :228-229 | Go-only same-directory `.go` files beside `main` (:196-201), existing, non-symlink (:228-229), no duplicates (:186-188); passed to the builder as `files` keyed by basename (main.nim:253-254). Go entrypoint with helpers = one package (docs/MANUAL.md:698-701) |
| `components[].defines` | :207-212, :249-250 | Added to `builder.build` as `defines` → `-d:NAME`, Nim only (components/builder/main.nim:88-95) |
| `components[].env` | :202-206, :265-266 | Parsed, validated as a string array, echoed as `env` in the component result… and **never applied**: `core.spawn` takes only `name`/`binary`/`args`/`replicas` (core/catalog.nim:70-75) and the builder has no `env` param (components/builder/main.nim:51). Informational today |
| `components[].interactive` | :183, :259-262 | `true` → built into `var/bin`, **not** passed to `core.spawn` (`{interactive: true, spawned: false, built: "source"}`, absolute binary path); user starts it in a terminal, it is not supervised or restored on boot (tool note main.nim:649; docs/MANUAL.md:702-706, 2243-2248). Removal reports it as `removed: true, interactive: true` + "stop any running terminal client manually" (main.nim:400-403) without touching the process |

**Store record** — kind `plugin`, id = package name, written by `saveRecord`
(main.nim:141-144) as
`{name, repo, ref, dir (absolute), version, components[], addedAt}` (epoch
seconds, main.nim:386-388) — identical to docs/MANUAL.md:2181. Reads fail
closed: a store error makes `pluginRecord` return nil → "not installed"
(main.nim:132-139); a refused put raises and surfaces as an error envelope
(main.nim:141-144). `plugin_installed` reads a **page** of 100 records
(main.nim:614) and adds a derived `commit` from `git rev-parse HEAD` in the
recorded dir at read time (main.nim:616-624).

**Ref resolution and update semantics** — `version` arg → `checkRef`
(main.nim:330, :80-84) → else latest release `tag_name`
(main.nim:90-99) → else the highest **version-looking** tag from
`/tags?per_page=100` (main.nim:100-113; `latestVersionTag` versions.nim:51-72,
`v`-prefix optional, `1.2 == 1.2.0`, `v2.0.0` beats `v2.0.0-rc1`,
non-version tags like `nightly` are never chosen, versions.nim:16-42) → else
`default_branch` (default `"main"`, main.nim:120-127). `file://` installs skip
resolution and clone HEAD (main.nim:329-335). `plugin_update` (main.nim:654-698)
splits two ways: **tag pin + a newer tag** → remove every component, delete the
clone, reinstall at the new tag (main.nim:688-695, record dropped at :693 if
that install fails); **branch pin, no newer tag, or `pinsTag` false** →
`doUpdateBranch` (main.nim:410-490): `git pull --ff-only origin <branch>`
(:436), and only a moved HEAD triggers remove-all + rebuild + respawn
(:461-483) — a no-op pull returns `{updated:false, ref, commit}` and merely
rewrites `go.work` (:440-459). `pinsTag` is what keeps a branch pin from being
silently *downgraded* to a release tag (main.nim:492-504; ref must resolve as
`refs/tags/<ref>` in the clone). Refless (`file://`) records read the branch
from the clone's HEAD once and persist it (:416-431); detached HEAD →
"reinstall instead" (:430-431).

**Failure reporting and leftovers** — build/spawn results are per component:
`{name, binary, spawned: true}` (main.nim:232-239), `{name, binary,
interactive: true, spawned: false, built: "source"}` (:259-262), or
`{name, spawned: false, error: "build failed: …"}` with the compiler tail
**truncated to 400 bytes** (:267-272). If **no** component installs, the clone
is deleted and no record is written: `"no component could be installed"` with
the per-component array (:381-384). A **partial** success saves the record and
keeps the per-component `spawned:false`/`error` entries (:386-388) — the
package is "installed" with silent holes. A failed clone removes the directory
and returns the tail 800 bytes (:365-367); a leftover clone dir whose manifest
name has no record is deleted and retried (:341-350); an existing install
refuses with "already installed: … — use plugin_update, or plugin_remove
first" (:348-349, :645-646). Update after a branch pull with an invalid
manifest drops the record but **leaves the clone** ("manifest invalid after
pull; package removed", :465-468); a pull that moved HEAD but rebuilt nothing
errors with the components already removed and the record still recorded
(:480-483). `plugin_remove` reads the record first (:707-709), removes
components tolerantly (:392-408), deletes the clone, then drops the record — if
that last `storeDel` fails it still returns `ok` with a `warning`, leaving a
record whose `dir` is gone (:713-719).

## 4. MANUAL placement

**Existing home: docs/MANUAL.md:674 `## Component ecosystem (`plugins`)`**
(:674-719, before `## Skills` :721). The section is the right size and the
right audience — keep its structure, and fix/add only the deltas below. The
documented path from discovery to a running component is complete *conceptually*
(:676-679 topic discovery → :683 search → :685 install/clone/build/spawn →
:702-706 the interactive branch), and `cli install <repo>[@<ref>]` (:443-447)
covers the non-LLM path; what is missing is (a) that the tools are
discover-only, (b) the slash-command surface, (c) the manifest fields beyond
`sources`, (d) the ref-resolution order actually implemented, and (e) failure
leftovers. Cross-refs already in place and worth keeping: `NIF_GIT_MIRROR` row
:277, approval list :460, store row :2181, interactive startup :2243-2248,
`x-models-source` packages :716-719 / :1599-1668. No new section is needed;
suggested additions: one `direct vs discover-only` line above the table
(§2), one `Configuration` paragraph for `NIF_GIT_MIRROR` + `git`/network/
peer requirements, a manifest-field table replacing bullet :698-701, and a
3-line "when it fails" paragraph.

## 5. DELTA list

- `MANUAL:693 (+ :686) | CODE: main.nim:86-118, versions.nim:1-10, 51-72 | FIX: update` — "The default ref is the latest release tag, else the default branch" is stale: there is a **version-tag fallback** between the two (`/releases/latest` → highest version-looking `/tags` → default branch), specifically so release-less repos (gokr/niffler-tui) can still move. MANUAL:686's "a package with no releases (tracking a branch)" is therefore wrong for a release-less repo **with** version tags — it is tag-pinned, not branch-pinned. The tool's own param doc is stale the same way (main.nim:640 "empty = latest release, else default branch").
- `MANUAL:685 | CODE: main.nim:337-340, 72-78, 361-363 | FIX: update` — the clone dir is `var/plugins/<repo basename>@<ref>/`, **not** `<pkg>@<ref>` (the manifest package name may differ), `<ref>` is the literal `head` when nothing was resolved, and the clone is `--depth 1`. Say "`var/plugins/<repo-name>@<tag-or-branch-or-head>/` (shallow)".
- `MANUAL:681-687 (table) + :1477 | CODE: main.nim:520, 607, 628, 653, 700 | FIX: add` — all five plugin tools are `onDemand`, i.e. **discover-only**: they are not in a conversation's frozen direct toolset (the section never says so; only the generic policy bullet :1477 lists "plugins"). Add one sentence: "All five are on demand — the agent reaches them through `discover`/`invoke`; slash commands, `cli call` and `cli install` reach them directly."
- `MANUAL:674-719 (whole section) | CODE: main.nim:731-761 | FIX: add` — the **slash surface is undocumented** anywhere in the MANUAL (grep `/plugins-` ⇒ 0 hits): `/plugins` (list), `/plugins-search <query>`, `/plugins-install <repo> [version]`, `/plugins-update <package>`, `/plugins-remove <package>`; names are component-prefixed because slash names are one global namespace with silent-loser collisions (main.nim:724-730).
- `MANUAL:698-701 | CODE: main.nim:196-201, 207-212, 225-226, 265-266 | FIX: add` — the manifest documentation stops at `sources`. Missing fields: `defines` (Nim compile defines, appended as `-d:NAME` by the builder, main.nim:249-250) and `env` (parsed and echoed, but **never applied** — `core.spawn` has no env parameter, core/catalog.nim:70-75). Also missing: `lang` is **`nim`/`go` only** (main.nim:225-226) even though `builder.build` supports `ts`, so a TypeScript package cannot be installed through `plugins`; `version` (manifest) is recorded, never compared; `sources` requires same-directory, non-symlink, non-`_test.go` files that don't duplicate `main` (main.nim:184-201, 228-229).
- `MANUAL:683 | CODE: main.nim:521-605 | FIX: add` — the `plugin_search` row documents only "repo, description, stars". The result also carries `query` (the query that actually hit), `attempts` (every query tried, with `results` or `error`), `hint`, and a `note` when results come from a relaxed query; top-level shape is `{ok, packages:[{repo, description, stars, url}], …}` (:599-604). The relaxation is behavioural and worth one sentence: space-separated words are ANDed by GitHub, so a zero-hit multi-word query is retried by dropping the last word (down to one) and then sweeping single words, capped at 6 search calls (:565-583), with `per_page=20&sort=stars` (:557). Failures are `no packages found` / `GitHub search failed: …` + `attempts` (:585-596).
- `MANUAL:684 | CODE: main.nim:608-626 | FIX: add (small)` — `plugin_installed` returns `{ok, packages:[…]}` where each package is the **stored record plus a derived `commit`** (`git rev-parse HEAD` in the recorded dir at read time, :616-624), and it reads one store **page of 100** (:614) — >100 packages silently truncate.
- `MANUAL:686 | CODE: main.nim:492-504, 680-687, 461-483, 428-431 | FIX: add` — four update facts are not stated: the pin only moves tag→tag because `pinsTag` requires the recorded ref to resolve as a tag in the clone (:492-504 — this is deliberate: a branch pin is never repointed at a release, which would downgrade an install); the already-latest case returns `{updated:false, ref}` after rewriting `go.work` (:680-687); a moved-HEAD branch pull removes all components before rebuilding them, i.e. no atomic swap (:461, :473-483, `removed` in the result); a refless clone in detached HEAD refuses with "reinstall instead" (:430-431).
- `MANUAL:685-687 (failure surface) | CODE: main.nim:381-388, 267-272, 365-367, 341-350 | FIX: add` — failure semantics are undocumented, and they are the thing users hit: every component failing ⇒ clone **deleted**, no record, `"no component could be installed"` + per-component details (:381-384); partial success ⇒ record **written** with `spawned:false` + `error` entries (:386-388); build errors are truncated to 400 bytes and clone errors to 800 (:268-269, :366); a stale clone with no record is wiped and retried (:341-350).
- `MANUAL:687 | CODE: main.nim:713-719; core/catalog.nim:86 | FIX: add (trap)` — `plugin_remove` deletes the clone **before** dropping the record; if the store refuses, it still returns `ok` with a `warning`, leaving a record whose directory is gone. The next `plugin_install` of that repo then refuses with "already installed" (main.nim:645-646) and `plugin_update` fails "package directory missing" (main.nim:420) — the user must remove again (or the store must come back) to clear it.
- `MANUAL:707-709 | CODE: main.nim:641-646, 341-350, 386 | FIX: add (hazard)` — the duplicate-install guard is keyed on the **repo slug** (:641-646) and on the destination's manifest name (:341-350), while the record id is the **manifest name** (:386): installing a second repo whose manifest `name` collides (with non-colliding component names) overwrites the first record, orphaning its clone and its spawned components. Worth one sentence in the record bullet.
- `MANUAL:674-719 (no placement) | CODE: main.nim:274-322, 313-316, 440-459 | FIX: add (small)` — the untracked `go.work` written into every Go clone (SDK `replace` → this harness's `sdk/go`, `use` limited to the manifest's modules, `go` directive mirrored or `go 1.24`) is the reason a manual `make` inside `var/plugins/<…>/` works, and it is missing from the section (the component header documents it, main.nim:16-17).
- `MANUAL:674-719 (no requirements) | CODE: main.nim:23-24, 39-41, 538, 641-642, 235-256 | FIX: add` — `plugins` needs `git` on `PATH` (only checked by `plugin_install`), network access to github.com (clone) **and** api.github.com (search/ref resolution, which `NIF_GIT_MIRROR` does not cover), in `--minimal` boots also requires `builder`/`core`/`store` to exist, and anonymous GitHub **search** is limited to 10 calls/min (its `maxCalls = 6` guard). MANUAL:710 documents only the 60 req/h core-API limit.
- `MANUAL:689-691 | CODE: main.nim:628, 653, 700; core/dispatch.nim:273-276; core/catalog.nim:75, 86 | FIX: none (verified)` — the approval claim is accurate: the three mutating tools carry `approval: "always"`, and each service `core.spawn`/`core.remove` is gated again by core. One clarification is worth adding: the nested `builder.build` calls are component→component (`comp.request`, sdk/niffler/sdk.nim:213-220) and bypass core's approval interceptor (core/dispatch.nim:1556), so a package with N service components prompts 1 + N times per install and per tag update.
- `MANUAL:702-706 | CODE: main.nim:183, 259-262, 370, 400-403, 649 | FIX: none (verified)` — interactive handling matches: built into `var/bin` as an absolute path, never spawned, not supervised/restored, removal returns an explicit `interactive: true` note instead of touching the process, and the install result carries the "interactive components must be started manually" note.
- `MANUAL:707-709 + :2181 | CODE: main.nim:386-388, 141-147 | FIX: none (verified)` — the record shape and lifetime match exactly: `{name, repo, ref, dir, version, components, addedAt}` in kind `plugin` keyed by package name, wiped by `--recover` with the other component records; `pluginRecord` fails closed when the store is unreachable (:132-139).
- `MANUAL:693-694 ("version pins a tag or branch explicitly") | CODE: main.nim:330, 80-84, 46-70 | FIX: none (verified)` — a `version` value is validated as a git ref charset and used as `git clone --branch`, so tag and branch both work; `repo` accepts `owner/name`, github.com https/ssh URLs and `file://` paths (the last undocumented as a *user* feature, only used by tests/docs/MANUAL.md:2227).

Finding count: **17** bullets = **13 deltas** (ref-resolution order, clone layout, discover-only exposure, slash surface, manifest fields, search result shape, installed shape, update facts, failure/leftovers, remove trap, duplicate-name hazard, `go.work`, requirements) + **4 verified-unchanged** (approval gate + prompt count, interactive handling, store record shape, `version` pinning).

## 6. Not user-facing

Mostly nothing to hide: all five tools are the model's own package-management
surface and are already on-demand (MANUAL:1477), and the slash commands are the
UI's own front door (main.nim:731-761) — both belong in the MANUAL. Two
implementation details should stay out of user prose: the GitHub query
relaxation bookkeeping (`attempts`/`maxCalls = 6`, main.nim:538, 565-583) is an
LLM-facing nicety, not a contract; and `writeGoWork`'s exact content
(main.nim:274-322) is an internal convenience — only its *effect* ("a manual
`make` in the clone works") deserves a line. Conversely the manifest's `env`
field is effectively dead (parsed, echoed, never applied — main.nim:202-206,
265-266) and the MANUAL should either say so plainly or the field should be
removed from the format; documenting it as a feature would be a lie. The
`file://` repo form is a test/mirror affordance (main.nim:50-57,
tests/t_plugins.nim, docs/MANUAL.md:2227) — one parenthetical is enough, not a
user-facing feature.
