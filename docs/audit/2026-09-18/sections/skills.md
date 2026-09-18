# Worklist slice: Skills

From `worklist.tsv` (25 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A224 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (front-matter keys are never listed)
- CODE: parsed keys are `name`, `description`, `version`, `license`, `tags`, `allowed-tools` (`components/skills/main.nim:64–67,120–125`), and `skill_list` returns name/description/version/**license**/tags/**allowedTools**/source/dir (`:249–251`)
- FIX: add the contract to the section: "A SKILL.md is YAML frontmatter + markdown: `name`, `description`, `version`, `license`, `tags` (list) and `allowed-tools` (list) are the keys Niffler reads; `skill_list` surfaces license and allowedTools too — `allowed-tools` is metadata the model reads, not an enforced restriction."

## A225 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 771–772 "marks the active winner per name and every shadowed/invalid copy (invalid = unreadable SKILL.md, unparseable frontmatter, **or no `name`**)"
- CODE: `name` falls back to the skill's *directory name* (`components/skills/main.nim:120`, called as `parseSkillMarkdown(readFile(path), skillDir.splitFile.name)` at `:137`), and the entry is only rejected when the name is empty *after* that fallback (`:127–128`)
- FIX: correct the definition — "invalid = unreadable SKILL.md, unparseable frontmatter, or no name **even after falling back to the directory name**; a SKILL.md that omits `name:` is accepted under the name of its directory."

## A226 (verified)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 764 "`skill_load {name}` … a body over 200 000 bytes is truncated with `truncated: true`"
- CODE: `const MaxContentBytes = 200_000` (`components/skills/main.nim:50`)
- FIX: none.

## A227 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 762 "`skill_search {query, owner?}` — online search of the skills.sh registry"
- CODE: the call is `https://skills.sh/api/search?q=…&limit=20` with `owner` as a query refinement (`components/skills/main.nim:404–420`)
- FIX: add "(20 results per call; `owner` narrows the query, it is not a separate namespace)".

## A228 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (nothing says whether skills keep state)
- CODE: `components/skills/main.nim` never calls the store — no `storePut`/`storeGet` in the file; installs are plain file copies (`:503–522`)
- FIX: add one sentence to the intro: "The component keeps no store records and no cached registry — an install is a file copy into a scanned directory, which is why a fresh walk sees it immediately and why `--recover` cannot lose it."

## A229 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 788–797 install/remove table rows and the `global` flag
- CODE: `global: bool = true` → `~/.niffler/skills`, `false` → `$NIF_ROOT/.opencode/skills` (`components/skills/main.nim:501,513,522`); `skill_remove` refuses anything outside those two dirs (`:577–581`)
- FIX: none (accurate).

## A467 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:806-820 table gives no **exposure/flags** column and never says every admin tool is `onDemand` (or hidden).
- CODE: main.go:344,454,547,587,614,635,658,687,710,756,816,851; oauth.go:145,168,185; `tests/t_provider.nim:474-485`.
- FIX: add a column or one line before 806: "None of these tools is in a conversation's frozen direct set: `provider_add`/`remove`/`list`/`switch`/`models`/`export`/`import` are `x-harness.onDemand` (reachable only through `discover` + `invoke`), and `provider_update/status/active/get/use_environment` plus the three OAuth tools are `x-harness.hidden` (components/core only, refused by `invoke`)."

## A497 (doc-edit)
source: `components/skills.md`

- MANUAL: Disk tree `<repo>/skills` (resolved by `bundledSkillsDir`, `main.nim:185-196`) — the four `skills/*/SKILL.md` files (name + description frontmatter only; `todo-markdown`, `niffler-tools`, `niffler-fabric`, `niffler-harness`).

## A498 (doc-edit)
source: `components/skills.md`

- MANUAL: Compile-time fallback: `bakedSkillFiles` `staticRead`s all four files (`main.nim:156-170`) and `bakedSkills()` serves any name no disk tree provided, with `source: "bundled"`, `dir: "(baked)"`, no resources (`main.nim:171-183`, `main.nim:236-237`, `main.nim:325-329`).

## A500 (doc-edit)
source: `components/skills.md`

- MANUAL: **D2 — MANUAL:251-253 wrong component named.** "The repomap, lsp and skills components additionally treat `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo *markers*"
- CODE: no such read exists in `main.nim`; roots come from `NIF_ROOT` only (`main.nim:220`, `sdk/subjects.nim:34-36`)
- FIX: drop `skills` from that sentence.

## A501 (doc-edit)
source: `components/skills.md`

- MANUAL: **D3 — no frontmatter documentation at all.** MANUAL mentions "frontmatter" only at 725 and 778
- CODE: six keys parsed, only `name`/`description`/`tags` have any effect (`main.nim:118-125`, `main.nim:276-278`)
- FIX: add the table from §3.

## A502 (doc-edit)
source: `components/skills.md`

- MANUAL: **D4 — MANUAL:778 "invalid = …or no `name`" is wrong.**
- CODE: `name` falls back to the directory basename (`main.nim:118`, `main.nim:137`), so it is empty only for an unreadable file; `invalid` really means "no frontmatter block / unparsable YAML / no readable SKILL.md" (`main.nim:107-108`, `113-117`, `134-136`)
- FIX: reword.

## A503 (doc-edit)
source: `components/skills.md`

- MANUAL: **D5 — the audit's own `detail` string is wrong.** `main.nim:316` says "missing name/description"
- CODE: CODE: `description` is never required (`main.nim:119`)
- FIX: FIX (code, not MANUAL): "SKILL.md exists but is unreadable or has no parseable frontmatter with a name".

## A504 (doc-edit)
source: `components/skills.md`

- MANUAL: **D6 — resources are top-level only and non-recursive.**
- CODE: `walkDir(subDir)` with `kind == pcFile` over `references/|scripts/|assets/` (`main.nim:143-152`), and `skill_resource` refuses any path not in that list (`main.nim:380-388`)
- FIX: add to MANUAL:776 → "one level deep: a file in `references/sub/x.md` (or a symlinked file) is not listed and cannot be read".

## A505 (doc-edit)
source: `components/skills.md`

- MANUAL: **D7 — MANUAL:751-755 covers half the symlink rule.**
- CODE: `walkDirRec` defaults `followFilter = {pcDir}`, `yieldFilter = {pcFile}` (`…/nim-2.2.12/lib/std/private/osdirs.nim:268-271`) — a symlinked `SKILL.md` file is not yielded either
- FIX: extend the sentence.

## A506 (doc-edit)
source: `components/skills.md`

- MANUAL: **D8 — `<repo>/skills` is a *build-time* path.** MANUAL:743/764 read as "next to the running binary"
- CODE: `currentSourcePath().parentDir.parentDir.parentDir` (`main.nim:193`) resolves at compile time, so the path baked into the binary is the checkout the component was built in; it wins whenever it still exists on disk, and `$NIF_ROOT/skills` is only reached when it does not (`main.nim:194-196`)
- FIX: say "the checkout the binary was built from".

## A507 (doc-edit)
source: `components/skills.md`

- MANUAL: **D9 — `skill_install` mechanics undocumented.**
- CODE: requires `git` on PATH (`main.nim:514-515`); clones `--depth 1` from `https://github.com/<repo>.git` into `$NIF_ROOT/var/skills-tmp/<name>` and removes it afterwards (`main.nim:524-530`, `main.nim:536-538`); matches `skill` against the skill name **or** the directory basename (`main.nim:546`); refuses when the destination exists ("already installed … skill_remove first", `main.nim:567-570`); `copyDir` copies the whole skill dir incl. resources (`main.nim:572`); result carries `source: home|project` (`main.nim:573-575`)
- FIX: add 3-4 bullets at MANUAL:786-796.

## A508 (doc-edit)
source: `components/skills.md`

- MANUAL: **D10 — `NIF_GIT_MIRROR` does not apply to `skill_install`.** MANUAL:288 advertises it as the mirror for package clones; a firewall user will assume it covers skills
- CODE: the GitHub host is hardcoded (`main.nim:528-529`)
- FIX: one clause in the Skills section.

## A509 (doc-edit)
source: `components/skills.md`

- MANUAL: **D11 — timeouts undocumented.**
- CODE: install `timeoutMs 600000` (`main.nim:497-499`), remove `300000` (`main.nim:577`) — the two longest non-bash tool budgets
- FIX: mention beside the approval note at MANUAL:795-796.

## A510 (doc-edit)
source: `components/skills.md`

- MANUAL: **D12 — MANUAL:775 "full SKILL.md instructions" overstates.**
- CODE: `content` is the **body only** — frontmatter is split off and returned structured in `skill` (`main.nim:105-108`, `main.nim:126`, `main.nim:347-349`); truncation applies to that body at 200 000 bytes (`main.nim:50`, `main.nim:345-347`)
- FIX: "the markdown body (frontmatter comes back as fields), truncated at 200 000 bytes with `truncated: true`".

## A511 (doc-edit)
source: `components/skills.md`

- MANUAL: **D13 — MANUAL:726 "It is read/load only over the bus" contradicts its own section.**
- CODE: `skill_install`/`skill_remove` write to `~`/`$NIF_ROOT` under approval (`main.nim:497-499`, `main.nim:577`)
- FIX: "read/load over the bus, plus git-based install/remove gated on approval".

## A512 (doc-edit)
source: `components/skills.md`

- MANUAL: **D14 — MANUAL:773 lists the wrong `skill_list` field set.**
- CODE: `skillJson` returns `name, description, version, license, tags, allowedTools, source, dir` (`main.nim:248-252`)
- FIX: add `license` and `allowedTools` (and note both are inert).

## A513 (doc-edit)
source: `components/skills.md`

- MANUAL: **D15 — `skill_search` limits and result shape are unstated.** MANUAL:774 says "name, repo source, install count"
- CODE: also `slug` and `url` (`main.nim:418-420`); `limit=20` (`main.nim:408`); `query` < 2 chars rejected before any network call (`main.nim:433`); failure returns the HTTP error text (`main.nim:440`)
- FIX: extend MANUAL:774/782.

## A514 (doc-edit)
source: `components/skills.md`

- MANUAL: **D16 — `skill_audit` semantics are undocumented beyond the table cell.** MANUAL:778
- CODE: `status` is computed by re-running `findSkill` per directory and comparing `rootDir` (`main.nim:318-320`); baked-only names are appended as `active` and are not counted in `shadowedCount`/`invalidCount` (`main.nim:325-329`, `main.nim:330-331`)
- FIX: one clause — "counts cover on-disk copies only; baked-only names appear as `active`".

## A515 (doc-edit)
source: `components/skills.md`

- MANUAL: **D17 — no "add your own skill" recipe anywhere in the MANUAL.**
- CODE: dir layout and resource sub-dirs as in §3 (`main.nim:131-153`, `main.nim:205-213`)
- FIX: add the subsection (with the shadowing caveat: a project copy of a bundled name wins, which is how `expert`'s allowlist is defeated — it refuses such a copy, `components/expert/main.nim:298-316`; MANUAL:2107-2140 says nothing about that).

