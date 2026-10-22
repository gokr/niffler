## skills component — Agent Skills (SKILL.md) discovery, load and install,
## as a bus service.
##
## Skills are reusable instruction modules (the open Agent Skills
## spec: YAML frontmatter + markdown body) that guide how the agent
## approaches a class of work — they do not add tools, they add strategy.
## This component discovers them from the standard agent skill
## directories and exposes load/install/remove over the bus:
##
##   project: <conversation workspace>/.agents/skills
##   home:    ~/.agents/skills
##   bundled: shipped skills/ tree, with compiled-in fallback
##
## First match wins per name; discovery is a fresh scan per call. Foreign
## agent directories are not scanned implicitly. Direct bus calls without
## workspace context use NIF_ROOT as their project root.
##
## "Loading" a skill is progressive disclosure via the tool result: the
## component does not mutate any prompt; skill_load returns the full
## SKILL.md content into the conversation (the same mechanism opencode's
## skill tool uses). Resources (references/, scripts/, assets/) are pulled
## on demand through skill_resource.
##
## Install clones a git repo (owner/name, URL, or file:// for local
## mirrors), finds its SKILL.md files and copies the chosen skill into a
## Niffler-managed directory: ~/.agents/skills (global, default) or
## <workspace>/.agents/skills (project). Only those
## two roots are removable through skill_remove. This includes skills placed
## in ~/.agents/skills by other harnesses: removal is explicit and approved.
## Install/remove run no code — only SKILL.md trees are copied — but they
## do write outside var/, so both carry x-harness.approval.

import std/[algorithm, httpclient, json, os, sequtils, streams, strutils,
            tables, uri]
import niffler/sdk
import niffler/readscope
import yaml

let comp = newComponent("skills", "0.1.0")

const MaxContentBytes = 200_000

# --------------------------------------------------------------------------
# SKILL.md parsing (YAML frontmatter + markdown body)

type
  SkillResource = object
    kind: string      # reference | script | asset
    name: string
    relPath: string

  Skill = object
    name: string
    description: string
    version: string
    license: string
    tags: seq[string]
    allowedTools: seq[string]
    rootDir: string
    source: string    # project | home | bundled
    content: string
    resources: seq[SkillResource]

proc splitFrontmatter(content: string): tuple[frontmatter, body: string] =
  let lines = content.splitLines()
  if lines.len < 2 or lines[0] != "---":
    return ("", content)
  var endIdx = -1
  for i in 1 ..< lines.len:
    if lines[i] == "---":
      endIdx = i
      break
  if endIdx < 0:
    return ("", content)
  result.frontmatter = lines[1 ..< endIdx].join("\n")
  result.body = lines[(endIdx + 1) .. ^1].join("\n").strip()

proc yamlStr(node: YamlNode, key: string, default = ""): string =
  if node.kind != yMapping:
    return default
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == yScalar:
      return v.content
  default

proc yamlSeq(node: YamlNode, key: string): seq[string] =
  result = @[]
  if node.kind != yMapping:
    return
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == ySequence:
      for item in v.elems:
        if item.kind == yScalar:
          result.add(item.content)

proc parseSkillMarkdown(content: string, fallbackName: string): Option[Skill] =
  ## Parse SKILL.md text (YAML frontmatter + markdown body) into a Skill
  ## skeleton — no rootDir, no on-disk resources — or none on any failure.
  let (fm, body) = splitFrontmatter(content)
  if fm.len == 0:
    return none(Skill)
  var stream = newStringStream(fm)
  var node: YamlNode
  try:
    load(stream, node)
  except CatchableError:
    stream.close()
    return none(Skill)
  stream.close()
  var s: Skill
  s.name = yamlStr(node, "name", fallbackName)
  s.description = yamlStr(node, "description")
  s.version = yamlStr(node, "version")
  s.license = yamlStr(node, "license")
  s.tags = yamlSeq(node, "tags")
  s.allowedTools = yamlSeq(node, "allowed-tools")
  s.content = body
  if s.name.len == 0:
    return none(Skill)
  some(s)

proc parseSkillDir(skillDir: string): Option[Skill] =
  ## Parse <skillDir>/SKILL.md into a Skill, or none on any failure.
  let path = skillDir / "SKILL.md"
  if isMasked(path) or not fileExists(path):
    return none(Skill)
  try:
    let parsed = parseSkillMarkdown(readFile(path), skillDir.splitFile.name)
    if parsed.isNone:
      return none(Skill)
    var s = parsed.get
    s.rootDir = skillDir
    for (subName, kindLabel) in [("references", "reference"),
                                 ("scripts", "script"),
                                 ("assets", "asset")]:
      let subDir = skillDir / subName
      if dirExists(subDir):
        for kind, f in walkDir(subDir):
          if kind == pcFile and not isMasked(f):
            s.resources.add(SkillResource(kind: kindLabel,
                                          name: f.extractFilename,
                                          relPath: subName / f.extractFilename))
    return some(s)
  except CatchableError:
    return none(Skill)

const bakedSkillFiles = [
  # The bundled skills compiled into this binary. Keep in sync with the
  # repo's skills/ tree: the disk tree is authoritative when present (and
  # shadows these by name); this list is what binary-only deployments fall
  # back to. staticRead resolves relative to this source file, so building
  # the shipped component happens from the repo checkout, like
  # systemprompt's baseprompt.txt.
  ("niffler-harness", staticRead("../../skills/niffler-harness/SKILL.md")),
  ("niffler-tools", staticRead("../../skills/niffler-tools/SKILL.md")),
  ("niffler-fabric", staticRead("../../skills/niffler-fabric/SKILL.md")),
  ("todo-markdown", staticRead("../../skills/todo-markdown/SKILL.md")),
]

# The `dir` reported for a skill served from the compiled-in copies: it has
# no directory of its own (and no resources).
const bakedDir = "(baked)"

proc bakedSkills(): seq[Skill] =
  ## The bundled skills as parsed compile-time content. rootDir is the
  ## marker `(baked)`: resources are unavailable for baked entries (none
  ## of the bundled skills ship any).
  for (name, content) in bakedSkillFiles:
    let parsed = parseSkillMarkdown(content, name)
    if parsed.isSome:
      var s = parsed.get
      s.source = "bundled"
      s.rootDir = bakedDir
      result.add(s)

const skillsBundledDir {.strdefine.} = ""
  ## Compile-time fixture seam only; no runtime environment override.

var activeWorkspace = ""
  ## Handler-local context: the SDK serializes tools. Restored by the wrapper
  ## after every call, so conversations never inherit another's workspace.

proc projectRoot(): string =
  if activeWorkspace.len > 0: activeWorkspace else: rootDir()

proc bundledSkillsDir(root: string): string =
  ## Shipped tree, then relocated root tree, then baked fallback.
  when skillsBundledDir.len > 0:
    return skillsBundledDir
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let repoSkills = repoRoot / "skills"
  if dirExists(repoSkills): return repoSkills
  root / "skills"

proc skillSearchPaths(root, home: string): seq[(string, string)] =
  ## Ordered sources; names resolve workspace > user > bundled.
  @[("project", root / ".agents" / "skills"),
    ("home", home / ".agents" / "skills"),
    ("bundled", bundledSkillsDir(rootDir()))]

proc discoverSkills(): seq[Skill] =
  ## Fresh full scan: recursive walk for SKILL.md, dedup by name, first
  ## match wins; the compiled-in bundled skills fill any name no disk
  ## source provided. Sorted by name.
  let root = projectRoot()
  let home = getHomeDir()
  var seen = initTable[string, bool]()
  for (source, dir) in skillSearchPaths(root, home):
    if not dirExists(dir):
      continue
    for path in walkDirRec(dir):
      if path.extractFilename != "SKILL.md":
        continue
      let s = parseSkillDir(path.parentDir)
      if s.isSome and not seen.hasKey(s.get.name):
        seen[s.get.name] = true
        var skill = s.get
        skill.source = source
        result.add(skill)
  for s in bakedSkills():
    if s.name notin seen:
      seen[s.name] = true
      result.add(s)
  result.sort(proc(a, b: Skill): int = cmp(a.name, b.name))

proc findSkill(name: string): Option[Skill] =
  for s in discoverSkills():
    if s.name == name:
      return some(s)
  none(Skill)

proc skillJson(s: Skill): JsonNode =
  %*{"name": s.name, "description": s.description, "version": s.version,
     "license": s.license, "tags": s.tags, "allowedTools": s.allowedTools,
     "source": s.source, "dir": s.rootDir}

# --------------------------------------------------------------------------
# discovery tools

comp.tool(%*{"onDemand": true}):
  proc skill_list(query: string = "", source: string = ""): JsonNode =
    ## List workflow/strategy guides from the conversation workspace's
    ## .agents/skills, ~/.agents/skills, then bundled skills (compiled fallback
    ## when no disk tree exists). First matching name wins. Use before a class
    ## of work, then skill_load the match; for Niffler questions query "niffler".
    ## - query: substring filter over name, description and tags
    ## - source: "project", "home" or "bundled"; empty = all
    var skills = discoverSkills()
    if query.len > 0:
      let q = query.toLowerAscii()
      skills = skills.filterIt(it.name.toLowerAscii().contains(q) or
        it.description.toLowerAscii().contains(q) or
        it.tags.anyIt(it.toLowerAscii().contains(q)))
    if source.len > 0:
      skills = skills.filterIt(it.source == source)
    var items = newJArray()
    for s in skills:
      items.add(skillJson(s))
    %*{"ok": true, "count": items.len, "skills": items}

comp.tool(%*{"onDemand": true}):
  proc skill_audit(): JsonNode =
    ## Read-only audit of every SKILL.md on disk, WITHOUT merging (CodeWhale
    ## borrow, docs/research/CODEWHALE.md): discoverSkills dedups by name so
    ## shadowing is invisible there; this lists every on-disk copy, marks
    ## which one wins for the runtime, and flags the shadowed duplicates and
    ## invalid skill dirs. Names served only from the compiled-in baked
    ## fallback (no disk copy anywhere) are listed with dir "(baked)". Use
    ## it when a skill seems ignored or two copies disagree — the winner is
    ## always the first entry in skillSearchPaths.
    let root = projectRoot()
    let home = getHomeDir()
    var winners = initTable[string, bool]()
    for s in discoverSkills():
      winners[s.name] = true
    var entries = newJArray()
    var shadowed = 0
    var invalid = 0
    var diskNames = initTable[string, bool]()
    for (source, dir) in skillSearchPaths(root, home):
      if not dirExists(dir):
        continue
      for path in walkDirRec(dir):
        if path.extractFilename != "SKILL.md" or isMasked(path):
          continue
        let s = parseSkillDir(path.parentDir)
        if s.isNone:
          inc invalid
          entries.add(%*{"dir": path.parentDir, "source": source,
                          "status": "invalid",
                          "detail": "SKILL.md exists but is unreadable or has no usable name"})
          continue
        let active = not winners.hasKey(s.get.name) or
                     findSkill(s.get.name).get.rootDir == s.get.rootDir
        if not active: inc shadowed
        diskNames[s.get.name] = true
        entries.add(%*{"name": s.get.name, "dir": s.get.rootDir,
                        "source": source, "status": (if active: "active" else: "shadowed"),
                        "description": s.get.description})
    for s in bakedSkills():
      if not diskNames.hasKey(s.name):
        entries.add(%*{"name": s.name, "dir": bakedDir,
                        "source": "bundled", "status": "active",
                        "description": s.description})
    %*{"skills": entries, "shadowedCount": shadowed, "invalidCount": invalid,
        "note": "runtime discovery merges to one winner per name; this audit shows every on-disk copy plus baked-only entries"}

comp.tool(%*{"onDemand": true}):
  proc skill_load(name: string): JsonNode =
    ## Load a skill's instructions into this conversation and follow it
    ## for the current task. Skills add workflow strategy, not tools. Find
    ## the name with skill_list first.
    ## - name: skill name (see skill_list)
    let s = findSkill(name)
    if s.isNone:
      return errResult("skill not found: " & name &
                       " — see skill_list")
    var skill = s.get
    var truncated = false
    if skill.content.len > MaxContentBytes:
      skill.content = skill.content[0 ..< MaxContentBytes]
      truncated = true
    var res = newJArray()
    for r in skill.resources:
      res.add(%*{"kind": r.kind, "name": r.name, "path": r.relPath})
    %*{"ok": true, "skill": skillJson(skill), "content": skill.content,
       "resources": res, "resourceCount": res.len, "truncated": truncated}

comp.tool(%*{"onDemand": true}):
  proc skill_resources(name: string): JsonNode =
    ## List the resources of a skill (references/, scripts/, assets/
    ## files). Resources are loaded on demand — read them with
    ## skill_resource when the instructions ask for them.
    ## - name: skill name (see skill_list)
    let s = findSkill(name)
    if s.isNone:
      return errResult("skill not found: " & name)
    var res = newJArray()
    for r in s.get.resources:
      res.add(%*{"kind": r.kind, "name": r.name, "path": r.relPath})
    %*{"ok": true, "skill": name, "resources": res, "count": res.len}

comp.tool(%*{"onDemand": true}):
  proc skill_resource(name: string, path: string): JsonNode =
    ## Read one resource file of a skill (references/scripts/assets).
    ## Use for progressive disclosure: pull a reference or script only
    ## when the loaded skill's instructions say to.
    ## - name: skill name (see skill_list)
    ## - path: resource path relative to the skill dir, e.g. "references/schema.md"
    if path.len == 0 or path.startsWith("/") or ".." in path.split('/'):
      return errResult("resource path must be relative")
    let s = findSkill(name)
    if s.isNone:
      return errResult("skill not found: " & name)
    let skill = s.get
    var known = false
    for r in skill.resources:
      if r.relPath == path:
        known = true
        break
    if not known:
      return errResult("no such resource: " & path &
                       " — see skill_resources")
    try:
      let full = skill.rootDir / path
      if isMasked(full): return errResult(maskRefusal(full))
      if not fileExists(full):
        return errResult("resource not on disk: " & path)
      return %*{"ok": true, "skill": name, "path": path,
                "content": readFile(full)}
    except CatchableError as e:
      return errResult("failed to read resource: " & e.msg)


# --------------------------------------------------------------------------
# online search (skills.sh registry — the same API `npx skills find` uses)

proc searchRegistry(query, owner: string): JsonNode =
  ## Search skills.sh; nil on failure. Fresh client per call — a stale
  ## pooled connection (server closed it, e.g. after a 404) would hang
  ## the next read forever.
  let client = newHttpClient("niffler-skills/0.1", timeout = 30_000)
  defer: client.close()
  var url = "https://skills.sh/api/search?q=" & encodeUrl(query) & "&limit=20"
  if owner.len > 0:
    url &= "&owner=" & encodeUrl(owner)
  let data = client.getContent(url).parseJson()
  var items = newJArray()
  for s in data{"skills"}:
    let slug = s{"id"}.getStr("")
    let source = s{"source"}.getStr("")
    if slug.len == 0 or source.len == 0:
      continue
    items.add(%*{"name": s{"name"}.getStr(""), "slug": slug,
                 "source": source, "installs": s{"installs"}.getInt(0),
                 "url": "https://skills.sh/" & slug})
  items

comp.tool(%*{"onDemand": true}):
  proc skill_search(query: string, owner: string = ""): JsonNode =
    ## Search the skills.sh registry online for skills to install — the
    ## same registry `npx skills find` uses. Call this when the user asks
    ## for a skill by topic ("a SQL skill", "code review") or wants to see
    ## what the ecosystem offers; then skill_install {repo: result.source,
    ## skill: result.name}. Local discovery is skill_list.
    ## - query: keywords, at least 2 characters (e.g. "typescript", "web design")
    ## - owner: restrict to a GitHub owner or organization (e.g. "vercel-labs")
    if query.strip().len < 2:
      return errResult("query needs at least 2 characters")
    try:
      let items = searchRegistry(query.strip(), owner.strip())
      return %*{"ok": true, "count": items.len, "skills": items,
                "registry": "skills.sh",
                "hint": "install with skill_install {repo: \"<source>\", skill: \"<name>\"}"}
    except CatchableError as e:
      return errResult("skills.sh search failed: " & e.msg)


# --------------------------------------------------------------------------
# install / remove (managed dirs only)

proc normalizeRepo(repoArg: string): string =
  ## "owner/name", a github.com URL, or a file:// URL (local mirrors).
  if repoArg.strip().startsWith("file://"):
    let r = repoArg.strip()
    for ch in r:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/', ':', '~'}:
        raise newException(ValueError, "malformed repo URL: " & repoArg)
    return r
  var r = repoArg.strip()
  r.removeSuffix(".git")
  for pre in ["https://github.com/", "http://github.com/", "git@github.com:"]:
    if r.startsWith(pre):
      r = r[pre.len .. ^1]
  result = r.strip(true, true, {'/'})
  let parts = result.split('/')
  if parts.len != 2:
    raise newException(ValueError,
      "repo must be 'owner/name' or a github.com URL, got: " & repoArg)
  for p in parts:
    if p.len == 0:
      raise newException(ValueError, "malformed repo: " & repoArg)
    for ch in p:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
        raise newException(ValueError, "malformed repo name: " & repoArg)

proc repoSlug(repo: string): string =
  if repo.startsWith("file://"):
    repo.rsplit('/', 1)[^1]
  else:
    repo.split('/')[1]

proc managedInstallRoots(): seq[string] =
  ## The only directories skill_remove may delete from.
  result = @[getHomeDir() / ".agents" / "skills",
             projectRoot() / ".agents" / "skills"]

proc isManagedDir(dir: string): bool =
  for root in managedInstallRoots():
    if dir.startsWith(root & "/"):
      return true
  false

proc skillCandidates(repoDir: string): seq[Skill] =
  ## Every SKILL.md in the cloned repo, parsed (source stays "").
  for path in walkDirRec(repoDir):
    if path.extractFilename == "SKILL.md":
      let s = parseSkillDir(path.parentDir)
      if s.isSome:
        result.add(s.get)
  result.sort(proc(a, b: Skill): int = cmp(a.name, b.name))

comp.tool(%*{"approval": "always",
             "timeoutMs": 600000,
             "onDemand": true}):
  proc skill_install(repo: string, skill: string = "",
                     global: bool = true): JsonNode =
    ## Install a skill from a git repo: clones the repo, finds its
    ## SKILL.md files and copies the chosen skill into ~/.agents/skills
    ## (global, default) or <workspace>/.agents/skills (project). Repos with a single skill install directly; with
    ## several, pass skill. The repo/skill pair comes straight from a
    ## skill_search result. Only SKILL.md trees are copied — no code runs
    ## — but the write is still approved. Discover what is available with
    ## skill_list. Other agent directories require explicit import/install.
    ## - repo: "owner/name", a github.com URL, or a file:// URL
    ## - skill: skill name or directory inside the repo (empty = the only skill)
    ## - global: install under ~/.agents/skills (default); false = workspace .agents/skills
    if findExe("git").len == 0:
      return errResult("git not found on PATH")
    var cleanRepo: string
    try:
      cleanRepo = normalizeRepo(repo)
    except ValueError as e:
      return errResult(e.msg)
    let target =
      if global: getHomeDir() / ".agents" / "skills"
      else: projectRoot() / ".agents" / "skills"
    let tmp = rootVarDir("skills-tmp") / repoSlug(cleanRepo)
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp.parentDir())
    let url = if cleanRepo.startsWith("file://"): cleanRepo
              else: "https://github.com/" & cleanRepo & ".git"
    let (ccode, cout) = runCmd("git clone --depth 1 " & url & " " & tmp)
    if ccode != 0:
      if dirExists(tmp):
        removeDir(tmp)
      return errResult("git clone failed",
                       extra = %*{"output": tailBytes(cout, 800)})
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let candidates = skillCandidates(tmp)
    if candidates.len == 0:
      return errResult("no SKILL.md found in " & cleanRepo)
    var chosen: Option[Skill]
    if skill.len > 0:
      for c in candidates:
        if c.name == skill or c.rootDir.extractFilename == skill:
          chosen = some(c)
          break
      if chosen.isNone:
        var names = newJArray()
        for c in candidates:
          names.add(%*{"name": c.name,
                       "dir": c.rootDir.replace(tmp, "")})
        return errResult("no skill '" & skill & "' in " & cleanRepo,
                         extra = %*{"skills": names})
    elif candidates.len == 1:
      chosen = some(candidates[0])
    else:
      var names = newJArray()
      for c in candidates:
        names.add(%*{"name": c.name, "dir": c.rootDir.replace(tmp, "")})
      return errResult("repo " & cleanRepo & " contains " & $candidates.len &
                       " skills — pass the one you want",
                       extra = %*{"skills": names})

    let name = chosen.get.name
    let dest = target / name
    if dirExists(dest):
      return errResult("skill already installed at " & dest &
                       " — skill_remove first")
    createDir(target)
    copyDir(chosen.get.rootDir, dest)
    okResult(%*{"skill": name, "dir": dest, "repo": cleanRepo,
                "source": if global: "home" else: "project",
                "description": chosen.get.description})

comp.tool(%*{"approval": "always", "timeoutMs": 300000, "onDemand": true}):
  proc skill_remove(name: string): JsonNode =
    ## Remove a skill installed by skill_install: deletes its directory
    ## under ~/.agents/skills or the workspace .agents/skills. Bundled
    ## skills are never deleted.
    ## - name: skill name (see skill_list)
    let s = findSkill(name)
    if s.isNone:
      return errResult("skill not found: " & name &
                       " — see skill_list")
    let skill = s.get
    if not isManagedDir(skill.rootDir):
      return errResult(name & " lives in " & skill.rootDir &
                       " which is not Niffler-managed — removing it is refused")
    try:
      removeDir(skill.rootDir)
      return okResult(%*{"skill": name, "removed": skill.rootDir})
    except CatchableError as e:
      return errResult("failed to remove: " & e.msg)

# --------------------------------------------------------------------------
# slash commands (docs/WIRE.md — declarative UI surface)
#
# Namespaced by the registering component, the plugins component's
# convention: the command namespace is global and duplicate names are
# rejected, so a generic /skills would collide with another installed
# package's command and the later registration would be silently dropped.
# The plugins component's /plugins + /plugins-install + /plugins-remove
# trio is the model — same verbs, same slot.

discard comp.slashCommand("skills",
  "List skills on this harness (load one with the model's skill_load)",
  parseJson("""
    [{"name": "query", "kind": "string", "default": "",
      "description": "substring filter over name, description and tags"},
     {"name": "source", "kind": "enum",
      "values": ["", "project", "home", "bundled"],
      "description": "restrict to one discovery root (empty: all)"}]
  """), tool = "skill_list")

discard comp.slashCommand("skills-install",
  "Install a skill from a git repo (copies SKILL.md trees; asks approval)",
  parseJson("""
    [{"name": "repo", "kind": "string",
      "description": "owner/name, a github.com URL, or a file:// URL"},
     {"name": "skill", "kind": "string", "default": "",
      "description": "skill name or directory inside the repo (empty = the repo's only skill)"},
     {"name": "global", "kind": "bool", "default": true,
      "description": "true = ~/.agents/skills (default); false = this project's .agents/skills"}]
  """), tool = "skill_install")

discard comp.slashCommand("skills-remove",
  "Remove a skill installed from a repo (asks approval; shared dirs are refused)",
  parseJson("""
    [{"name": "name", "kind": "string",
      "description": "skill name (see /skills)"}]
  """), tool = "skill_remove")

proc workspaceHandler(handler: ToolHandler): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    let previous = activeWorkspace
    activeWorkspace = args{"__workspace"}{"root"}.getStr("")
    try:
      result = handler(c, args)
    finally:
      activeWorkspace = previous

for tool in comp.tools.mitems:
  if tool.name != "skill_search":
    tool.schema["x-harness"]["workspace"] = %*{"pathFields": []}
    tool.handler = workspaceHandler(tool.handler)

comp.run()
