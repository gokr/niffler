## skills component — Agent Skills (SKILL.md) discovery, load and install,
## as a bus service.
##
## Skills are reusable instruction modules (the open Agent Skills
## spec: YAML frontmatter + markdown body) that guide how the agent
## approaches a class of work — they do not add tools, they add strategy.
## This component discovers them from the standard agent skill
## directories and exposes load/install/remove over the bus:
##
##   project (NIF_ROOT):  .agents/skills, .claude/skills, .opencode/skills
##   home:                .agents/skills, .claude/skills, .opencode/skills,
##                        .niffler/skills
##   config (XDG):        opencode/skills
##
## First match wins per skill name (project beats home beats config), so a
## repo's own skills shadow global ones. Discovery is a fresh scan per
## call — skills change under us (installs, `npx skills add` from other
## agents), so there is no cached registry and no refresh op.
##
## "Loading" a skill is progressive disclosure via the tool result: the
## component does not mutate any prompt; skill_load returns the full
## SKILL.md content into the conversation (the same mechanism opencode's
## skill tool uses). Resources (references/, scripts/, assets/) are pulled
## on demand through skill_resource.
##
## Install clones a git repo (owner/name, URL, or file:// for local
## mirrors), finds its SKILL.md files and copies the chosen skill into a
## Niffler-managed directory: ~/.niffler/skills (global, default) or
## $NIF_ROOT/.opencode/skills (project, shared with opencode). Only those
## two roots are removable through skill_remove. Skills that other agents
## installed into shared dirs are discovered but never deleted.
## Install/remove run no code — only SKILL.md trees are copied — but they
## do write outside var/, so both carry x-harness.approval.

import std/[algorithm, httpclient, json, os, sequtils, streams, strutils,
            tables, uri]
import niffler/sdk
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
    source: string    # project | home | config
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

proc parseSkillDir(skillDir: string): Option[Skill] =
  ## Parse <skillDir>/SKILL.md into a Skill, or none on any failure.
  let path = skillDir / "SKILL.md"
  if not fileExists(path):
    return none(Skill)
  try:
    let content = readFile(path)
    let (fm, body) = splitFrontmatter(content)
    if fm.len == 0:
      return none(Skill)
    var stream = newStringStream(fm)
    var node: YamlNode
    load(stream, node)
    stream.close()
    var s: Skill
    s.name = yamlStr(node, "name", skillDir.splitFile.name)
    s.description = yamlStr(node, "description")
    s.version = yamlStr(node, "version")
    s.license = yamlStr(node, "license")
    s.tags = yamlSeq(node, "tags")
    s.allowedTools = yamlSeq(node, "allowed-tools")
    s.rootDir = skillDir
    s.content = body
    if s.name.len == 0:
      return none(Skill)
    for (subName, kindLabel) in [("references", "reference"),
                                 ("scripts", "script"),
                                 ("assets", "asset")]:
      let subDir = skillDir / subName
      if dirExists(subDir):
        for kind, f in walkDir(subDir):
          if kind == pcFile:
            s.resources.add(SkillResource(kind: kindLabel,
                                          name: f.extractFilename,
                                          relPath: subName / f.extractFilename))
    return some(s)
  except CatchableError:
    return none(Skill)

proc bundledSkillsDir(root: string): string =
  ## Where the bundled (shipped-with-Niffler) skills live. Normally
  ## <repo>/skills next to this component's checkout; NIF_ROOT/skills
  ## is the fallback for relocated deployments.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let repoSkills = repoRoot / "skills"
  if dirExists(repoSkills): return repoSkills
  root / "skills"

proc skillSearchPaths(root, home, config: string): seq[(string, string)] =
  ## Ordered (source, dir) pairs; the first dir holding a skill name wins.
  ## "bundled" is the NIF_ROOT/skills tree shipped with the repo — always
  ## discovered (even when NIF_ROOT differs from the repo, e.g. a harness
  ## started elsewhere), shadowable by project/home dirs, and never
  ## removable via skill_remove (outside the managed roots).
  result = @[
    ("project", root / ".agents" / "skills"),
    ("project", root / ".claude" / "skills"),
    ("project", root / ".opencode" / "skills"),
    ("bundled", bundledSkillsDir(root)),
    ("home", home / ".agents" / "skills"),
    ("home", home / ".claude" / "skills"),
    ("home", home / ".opencode" / "skills"),
    ("home", home / ".niffler" / "skills"),
    ("config", config / "opencode" / "skills"),
  ]

proc discoverSkills(): seq[Skill] =
  ## Fresh full scan: recursive walk for SKILL.md, dedup by name, first
  ## match wins. Sorted by name.
  let root = rootDir()
  let home = getHomeDir()
  let config = getConfigDir()
  var seen = initTable[string, bool]()
  for (source, dir) in skillSearchPaths(root, home, config):
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

comp.tool:
  proc skill_list(query: string = "", source: string = ""): JsonNode =
    ## List the skills available on this harness. Skills are reusable
    ## strategy/workflow guides (SKILL.md files) discovered from the
    ## standard agent directories (.agents/skills, .claude/skills,
    ## .opencode/skills — project and home) plus ~/.niffler/skills and
    ## the XDG opencode/skills dir. Call this when the user asks for help
    ## with a class of work (code review, refactoring, a language, a
    ## workflow) to find a relevant skill, then skill_load it.
    ## - query: substring filter over name, description and tags
    ## - source: "project", "home" or "config"; empty = all
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

comp.tool:
  proc skill_load(name: string): JsonNode =
    ## Load a skill's instructions into this conversation. Returns the
    ## full SKILL.md content plus its resource list; the content becomes
    ## part of this conversation — follow it for the current task. Skills
    ## add workflow strategy, not tools. Find the right one with
    ## skill_list first.
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
  result = @[getHomeDir() / ".niffler" / "skills",
             rootDir() / ".opencode" / "skills"]

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
    ## SKILL.md files and copies the chosen skill into ~/.niffler/skills
    ## (global, default) or $NIF_ROOT/.opencode/skills (project, shared
    ## with opencode). Repos with a single skill install directly; with
    ## several, pass skill. The repo/skill pair comes straight from a
    ## skill_search result. Only SKILL.md trees are copied — no code runs
    ## — but the write is still approved. Discover what is available with
    ## skill_list; skills installed via `npx skills add` into the standard
    ## agent dirs are discovered automatically and need no reinstall.
    ## - repo: "owner/name", a github.com URL, or a file:// URL
    ## - skill: skill name or directory inside the repo (empty = the only skill)
    ## - global: install under ~/.niffler/skills (default); false = project .opencode/skills
    if findExe("git").len == 0:
      return errResult("git not found on PATH")
    var cleanRepo: string
    try:
      cleanRepo = normalizeRepo(repo)
    except ValueError as e:
      return errResult(e.msg)
    let target =
      if global: getHomeDir() / ".niffler" / "skills"
      else: rootDir() / ".opencode" / "skills"
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
    ## under ~/.niffler/skills or $NIF_ROOT/.opencode/skills. Skills that
    ## live in shared agent directories (.claude/skills etc.) are never
    ## deleted from here — remove those with their own agent tooling.
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

comp.run()
