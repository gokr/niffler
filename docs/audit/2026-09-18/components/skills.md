# Docs audit — `components/skills/` (Nim, 598 LOC, one file)

Read-only audit. No builds/tests run. Every claim cites `file:line`.
MANUAL.md line numbers are from the current 2324-line file (`## Skills` at 721).

## 1. What it offers

- A **discovery + progressive-disclosure library of Agent Skills** (SKILL.md = YAML
  frontmatter + markdown body) — "they do not add tools, they add strategy"
  (`components/skills/main.nim:1-41`). Eight tools, one component, no bus service and no
  `.call` subject (`main.nim:598` is the only registration outside `comp.tool`).
- **Nothing is injected into a prompt**: `skill_load` returns the SKILL.md body as a tool
  result, which the session appends to history — so loading is a cache *read*, never a
  frozen-prefix rewrite (`main.nim:25-29`, `main.nim:333-352`).
- Discovery merges four disk sources into **one winner per name** (first match in the
  ordered list wins), plus a compile-time fallback for binary-only deployments
  (`main.nim:198-240`).
- Install/remove copy SKILL.md trees from git into one of two managed roots; the component
  owns no database, no state file and no `var/` write outside the install clone
  (`main.nim:477-495`, `main.nim:524`).
- Only cross-component consumer in-tree: `expert` calls `skill_load` for its knowledge
  prefix and refuses any copy whose `source != "bundled"` (`components/expert/main.nim:68-71`,
  `components/expert/main.nim:296-316`).

## 2. Tools

All eight are `x-harness.onDemand` (`onDemand: true` in the schema: `main.nim:256,285,333,
354,368,423,497-499,577`) — none is direct, none is `hidden`, so the first reach is
`discover` + `invoke`. Confirmed against MANUAL:729 ("All eight tools are **on-demand**")
and MANUAL:1474-1478 (shipped policy lists `skill_list`/`skill_load` under the on-demand
long tail).

| Tool | Purpose (schema `description`, main.nim) | Other `x-harness` flags | Exposure |
|---|---|---|---|
| `skill_list {query="", source=""}` | available skills: name/description/version/license/tags/allowedTools/source/dir; `query` is a lowercase substring match over **name, description and tags**, `source` filters `project`\|`bundled`\|`home`\|`config` (`main.nim:256-283`); unknown `source` → `count: 0`, not an error (`main.nim:279-280`) | — | discover-only |
| `skill_audit` | read-only, **unmerged** inventory of every on-disk SKILL.md + baked-only names: per entry `name/dir/source/status` with `status` ∈ `active`\|`shadowed`\|`invalid`, plus `shadowedCount`/`invalidCount` (`main.nim:285-332`) | — | discover-only |
| `skill_load {name}` | the load mechanism: frontmatter-stripped **body** in `content`, resource list, `truncated` (`main.nim:333-352`) | — | discover-only |
| `skill_resources {name}` | the skill's `references/`, `scripts/`, `assets/` files, by `relPath` (`main.nim:354-366`) | — | discover-only |
| `skill_resource {name, path}` | read one of those files; refuses absolute paths and any `..` segment, and anything not in the discovered list (`main.nim:368-400`) | — | discover-only |
| `skill_search {query, owner=""}` | online skills.sh search (`?q=&limit=20[&owner=]`, `main.nim:408-410`); `query` < 2 chars is rejected (`main.nim:433`); returns `{name, slug, source, installs, url}` (`main.nim:418-420`); HTTP failure → `errResult("skills.sh search failed: …")` (`main.nim:440`) | — (no approval, 30 s client timeout `main.nim:406`) | discover-only |
| `skill_install {repo, skill="", global=true}` | `git clone --depth 1` into `$NIF_ROOT/var/skills-tmp/<name>`, pick a SKILL.md tree, `copyDir` into `~/.niffler/skills` (default) or `$NIF_ROOT/.opencode/skills`, delete the clone (`main.nim:497-576`) | **approval always**, `timeoutMs 600000` | discover-only |
| `skill_remove {name}` | delete a skill only from those two managed roots (`main.nim:577-597`, roots at `main.nim:477-487`) | **approval always**, `timeoutMs 300000` | discover-only |

**How the shipped skills under `<root>/skills/` are exposed.** They are ordinary discovery
entries of source `bundled` — no dedicated tool, no listing injected anywhere. Two paths:

1. Disk tree `<repo>/skills` (resolved by `bundledSkillsDir`, `main.nim:185-196`) — the
   four `skills/*/SKILL.md` files (name + description frontmatter only; `todo-markdown`,
   `niffler-tools`, `niffler-fabric`, `niffler-harness`).
2. Compile-time fallback: `bakedSkillFiles` `staticRead`s all four files (`main.nim:156-170`)
   and `bakedSkills()` serves any name no disk tree provided, with `source: "bundled"`,
   `dir: "(baked)"`, no resources (`main.nim:171-183`, `main.nim:236-237`, `main.nim:325-329`).

Both are covered by MANUAL:757-771 and verified in `tests/t_skills.nim:95-104` (load of
`niffler-harness` asserts the docs map) and `tests/t_skills.nim:238-280` (baked phase).

## 3. Configuration

**Env vars.** Exactly one knob exists; `grep` over `main.nim` finds no other `getEnv`
call: `NIF_SKILLS_BUNDLED_DIR` (`main.nim:191`, default `""`) — non-empty path replaces both
`<repo>/skills` and the `$NIF_ROOT/skills` fallback; pointed at a missing path it forces the
baked set (`main.nim:191-196`). Indirect inputs: `NIF_ROOT` via `rootDir()` for project dirs
+ install target (`sdk/subjects.nim:34-36`), `HOME`/`XDG_CONFIG_HOME` via `getHomeDir()`/
`getConfigDir()` (`main.nim:221-222`). Documented at MANUAL:296 — accurate.

**Search paths, in order (first name match wins; `main.nim:205-213`):**

| # | Source | Path | Removable |
|---|---|---|---|
| 1-3 | `project` | `$NIF_ROOT/.agents/skills`, `.claude/skills`, `.opencode/skills` | only `.opencode/skills` |
| 4 | `bundled` | `NIF_SKILLS_BUNDLED_DIR` → `<build-checkout>/skills` → `$NIF_ROOT/skills` | never |
| 5-8 | `home` | `~/.agents/skills`, `~/.claude/skills`, `~/.opencode/skills`, `~/.niffler/skills` | only `.niffler/skills` |
| 9 | `config` | `~/.config/opencode/skills` | never |
| — | `bundled` (baked) | compiled-in text, only for names no disk tree served | never |

Within a source the sub-dirs are tried in that order; a skill is one directory containing
`SKILL.md` (`main.nim:131-153`); the walk is `walkDirRec` (any depth).

**SKILL.md front-matter fields** (`parseSkillMarkdown`, `main.nim:105-129`):

| Key | Effect |
|---|---|
| `name` | **identity**: dedup/shadowing key, the value `skill_load`/`skill_resource`/`skill_remove` take. Missing → the directory basename is used (`main.nim:118`, fallback at `main.nim:137`) |
| `description` | what `skill_list` shows the model; the only selection signal besides `name` and `tags`. Never required |
| `tags` (list) | matched by `skill_list {query}` (`main.nim:276-278`); not otherwise used |
| `version`, `license` | echoed in `skillJson` (`main.nim:249-251`); never enforced |
| `allowed-tools` (list) | parsed into `allowedTools` and echoed (`main.nim:125`, `main.nim:250`); **not enforced anywhere** — no gating of tools |

Missing frontmatter (`main.nim:107-108`), unparsable YAML (`main.nim:113-117`) or a
directory without `SKILL.md` (`main.nim:134-136`) ⇒ the skill is skipped / reported
`invalid` by `skill_audit` (`main.nim:313-316`).

**Adding a project skill.** Create `<root>/.agents/skills/<name>/SKILL.md` (or `.claude/`,
`.opencode/`), or `skill_install {repo, skill, global: false}` for `$NIF_ROOT/.opencode/skills`
(`main.nim:522-523`, `main.nim:572-576`); resources go in sibling `references/`, `scripts/`,
`assets/` dirs (`main.nim:143-152`). No registration step, no restart.

**Caching / reload.** None: every tool call re-walks the disk (`discoverSkills()` at
`main.nim:272`, `main.nim:299`, and per name in `findSkill` `main.nim:242-246`), so installs,
deletes and other agents' `npx skills add` are visible on the next call; there is no refresh
op and nothing is persisted (MANUAL:748-750 — accurate). The walk does **not** follow
symlinks: Nim's `walkDirRec` defaults to `followFilter = {pcDir}` / `yieldFilter = {pcFile}`
(`~/.choosenim/toolchains/nim-2.2.12/lib/std/private/osdirs.nim:268-271`), so symlinked
directories are not descended **and a symlinked `SKILL.md` file is not yielded either**
(MANUAL:751-755 says only the directory half).

## 4. MANUAL placement

**Existing, keep:** `## Skills` — MANUAL:721 (Contents link MANUAL:17); shipped-components
row MANUAL:63; minimal-profile exclusion MANUAL:98; env row MANUAL:296; approval list
MANUAL:459-461; shipped-policy MANUAL:1474-1478.

**Proposed changes** (all inside 721-796, plus two fixes elsewhere):

- Fix MANUAL:250 `project skills shadow home skills shadow bundled skills` → `project >
  bundled > home > config` (contradicts MANUAL:737-741 and `main.nim:205-213`).
- Fix MANUAL:251-253: the "repo *markers* (`config.nims`, `tsconfig.json`, `package.json`,
  `go.mod`)" sentence must not name `skills` — the component reads none of those files.
- Add `### SKILL.md format` after MANUAL:771 (frontmatter table from §3, incl. "`name` is
  the identity key; a missing `name` falls back to the directory name; `allowed-tools` is
  metadata, never enforced").
- Add `### Adding your own skill` before the tools table: the three-line recipe (project
  dir vs `global: false`, resources in `references/|scripts/|assets/`, no restart).
- Extend MANUAL:737-745 with the build-path caveat and MANUAL:751-755 with the symlinked
  `SKILL.md` case and the non-recursive resource scan.
- Extend MANUAL:773-780/782-796 with: install/remove `timeoutMs`, `git` requirement,
  `var/skills-tmp`, "already installed → `skill_remove` first", no `NIF_GIT_MIRROR` here,
  `_search` limits/errors, `skill_load` body-truncation semantics.
- Add one sentence to the `expert` section (after MANUAL:2107) that its knowledge prefix is
  loaded through `skill_load` and refuses shadowed (non-`bundled`) copies.

**Content split.** `skills/*/SKILL.md` (492 lines total: `niffler-harness` 158,
`niffler-tools` 149, `niffler-fabric` 104, `todo-markdown` 81; frontmatter = `name` +
`description` only) are **model-facing operating guidance**, loaded on demand — not part of
the MANUAL. The MANUAL stays the human-facing reference for *what the component is, how it is
configured and which tools exist*; `niffler-harness/SKILL.md:22-28` carries the docs map and
points back at MANUAL/WIRE/ARCHITECTURE, so the two must not restate each other's tables.

## 5. DELTA list

1. **D1 — MANUAL:250 precedence is wrong.** `project skills shadow home skills shadow
   bundled skills` | CODE: `main.nim:205-213` puts `bundled` third, before all four `home`
   dirs (and MANUAL:737-741 says the same) | FIX: `project > bundled > home > config`.
2. **D2 — MANUAL:251-253 wrong component named.** "The repomap, lsp and skills components
   additionally treat `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo
   *markers*" | CODE: no such read exists in `main.nim`; roots come from `NIF_ROOT` only
   (`main.nim:220`, `sdk/subjects.nim:34-36`) | FIX: drop `skills` from that sentence.
3. **D3 — no frontmatter documentation at all.** MANUAL mentions "frontmatter" only at 725
   and 778 | CODE: six keys parsed, only `name`/`description`/`tags` have any effect
   (`main.nim:118-125`, `main.nim:276-278`) | FIX: add the table from §3.
4. **D4 — MANUAL:778 "invalid = …or no `name`" is wrong.** | CODE: `name` falls back to the
   directory basename (`main.nim:118`, `main.nim:137`), so it is empty only for an
   unreadable file; `invalid` really means "no frontmatter block / unparsable YAML / no
   readable SKILL.md" (`main.nim:107-108`, `113-117`, `134-136`) | FIX: reword.
5. **D5 — the audit's own `detail` string is wrong.** `main.nim:316` says "missing
   name/description" | CODE: `description` is never required (`main.nim:119`) | FIX (code,
   not MANUAL): "SKILL.md exists but is unreadable or has no parseable frontmatter with a
   name".
6. **D6 — resources are top-level only and non-recursive.** | CODE: `walkDir(subDir)` with
   `kind == pcFile` over `references/|scripts/|assets/` (`main.nim:143-152`), and
   `skill_resource` refuses any path not in that list (`main.nim:380-388`) | FIX: add to
   MANUAL:776 → "one level deep: a file in `references/sub/x.md` (or a symlinked file) is
   not listed and cannot be read".
7. **D7 — MANUAL:751-755 covers half the symlink rule.** | CODE: `walkDirRec` defaults
   `followFilter = {pcDir}`, `yieldFilter = {pcFile}`
   (`…/nim-2.2.12/lib/std/private/osdirs.nim:268-271`) — a symlinked `SKILL.md` file is not
   yielded either | FIX: extend the sentence.
8. **D8 — `<repo>/skills` is a *build-time* path.** MANUAL:743/764 read as "next to the
   running binary" | CODE: `currentSourcePath().parentDir.parentDir.parentDir`
   (`main.nim:193`) resolves at compile time, so the path baked into the binary is the
   checkout the component was built in; it wins whenever it still exists on disk, and
   `$NIF_ROOT/skills` is only reached when it does not (`main.nim:194-196`) | FIX: say
   "the checkout the binary was built from".
9. **D9 — `skill_install` mechanics undocumented.** | CODE: requires `git` on PATH
   (`main.nim:514-515`); clones `--depth 1` from `https://github.com/<repo>.git` into
   `$NIF_ROOT/var/skills-tmp/<name>` and removes it afterwards (`main.nim:524-530`,
   `main.nim:536-538`); matches `skill` against the skill name **or** the directory
   basename (`main.nim:546`); refuses when the destination exists ("already installed …
   skill_remove first", `main.nim:567-570`); `copyDir` copies the whole skill dir incl.
   resources (`main.nim:572`); result carries `source: home|project` (`main.nim:573-575`) |
   FIX: add 3-4 bullets at MANUAL:786-796.
10. **D10 — `NIF_GIT_MIRROR` does not apply to `skill_install`.** MANUAL:288 advertises it
    as the mirror for package clones; a firewall user will assume it covers skills | CODE:
    the GitHub host is hardcoded (`main.nim:528-529`) | FIX: one clause in the Skills
    section.
11. **D11 — timeouts undocumented.** | CODE: install `timeoutMs 600000`
    (`main.nim:497-499`), remove `300000` (`main.nim:577`) — the two longest non-bash tool
    budgets | FIX: mention beside the approval note at MANUAL:795-796.
12. **D12 — MANUAL:775 "full SKILL.md instructions" overstates.** | CODE: `content` is the
    **body only** — frontmatter is split off and returned structured in `skill`
    (`main.nim:105-108`, `main.nim:126`, `main.nim:347-349`); truncation applies to that body
    at 200 000 bytes (`main.nim:50`, `main.nim:345-347`) | FIX: "the markdown body
    (frontmatter comes back as fields), truncated at 200 000 bytes with `truncated: true`".
13. **D13 — MANUAL:726 "It is read/load only over the bus" contradicts its own section.**
    | CODE: `skill_install`/`skill_remove` write to `~`/`$NIF_ROOT` under approval
    (`main.nim:497-499`, `main.nim:577`) | FIX: "read/load over the bus, plus git-based
    install/remove gated on approval".
14. **D14 — MANUAL:773 lists the wrong `skill_list` field set.** | CODE: `skillJson` returns
    `name, description, version, license, tags, allowedTools, source, dir`
    (`main.nim:248-252`) | FIX: add `license` and `allowedTools` (and note both are inert).
15. **D15 — `skill_search` limits and result shape are unstated.** MANUAL:774 says "name,
    repo source, install count" | CODE: also `slug` and `url` (`main.nim:418-420`); `limit=20`
    (`main.nim:408`); `query` < 2 chars rejected before any network call (`main.nim:433`);
    failure returns the HTTP error text (`main.nim:440`) | FIX: extend MANUAL:774/782.
16. **D16 — `skill_audit` semantics are undocumented beyond the table cell.** MANUAL:778 |
    CODE: `status` is computed by re-running `findSkill` per directory and comparing
    `rootDir` (`main.nim:318-320`); baked-only names are appended as `active` and are not
    counted in `shadowedCount`/`invalidCount` (`main.nim:325-329`, `main.nim:330-331`) |
    FIX: one clause — "counts cover on-disk copies only; baked-only names appear as
    `active`".
17. **D17 — no "add your own skill" recipe anywhere in the MANUAL.** | CODE: dir layout and
    resource sub-dirs as in §3 (`main.nim:131-153`, `main.nim:205-213`) | FIX: add the
    subsection (with the shadowing caveat: a project copy of a bundled name wins, which is
    how `expert`'s allowlist is defeated — it refuses such a copy,
    `components/expert/main.nim:298-316`; MANUAL:2107-2140 says nothing about that).

Verified-correct MANUAL claims (no delta): "All eight tools are on-demand" (729);
the source table (737-745); fresh walk per call / no refresh op (748-750); baked fallback
reporting `dir: "(baked)"` with no resources (763-771); approval on install/remove
(795-796); shipped-policy placement (1474-1478); env row (296).

## 6. Not user-facing

- `splitFrontmatter`, `yamlStr`/`yamlSeq`, `skillJson`, `parseSkillMarkdown`,
  `parseSkillDir`, `discoverSkills`, `findSkill`, `skillCandidates`, `repoSlug`,
  `normalizeRepo`, `searchRegistry` are internals (`main.nim:63-495`) — no MANUAL surface.
- `main.nim:318` `not winners.hasKey(s.get.name)` is dead: `winners` is filled from
  `discoverSkills()` (`main.nim:298-300`), so the activeness verdict is decided solely by
  the `findSkill(...).rootDir == s.rootDir` comparison. Harmless, but it means `skill_audit`
  trusts the same dedup it exists to expose. Worth a code comment, not documentation.
- `bakedSkillFiles` (`main.nim:156-170`) binds the shipped component to a repo-checkout
  build (`staticRead("../../skills/…")`, same constraint as `systemprompt`'s baseprompt.txt);
  a user editing `skills/*/SKILL.md` in a *relocated* deployment gets disk-wins behaviour
  only where the tree exists — MANUAL needs at most the D8 caveat, not the build detail.
- The component doc block calls itself "a bus service" (`main.nim:2`), but nothing
  subscribes `svc.skills.*`: `comp.run()` only publishes its catalog and polls the tool
  subject (`main.nim:598`). MANUAL should not introduce a service name.
