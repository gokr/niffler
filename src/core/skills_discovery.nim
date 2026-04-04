## Skill Discovery and Loading
##
## This module handles discovering, parsing, and loading skills from
## the filesystem. Skills are stored as SKILL.md files with YAML frontmatter.
## Supports nested skills with parent/child relationships and resource discovery.

import std/[os, strutils, tables, options, logging, streams]
import yaml
import ../types/skills

type
  SkillParseResult* = object
    success*: bool
    skill*: Skill
    error*: string

proc splitYamlFrontmatter*(content: string): tuple[frontmatter: string, body: string] =
  let lines = content.splitLines()
  if lines.len < 2 or lines[0] != "---":
    return ("", content)
  
  var endIndex = -1
  for i in 1..<lines.len:
    if lines[i] == "---":
      endIndex = i
      break
  
  if endIndex < 0:
    return ("", content)
  
  result.frontmatter = lines[1..<endIndex].join("\n")
  result.body = lines[(endIndex + 1)..<lines.len].join("\n").strip()

proc parseYamlFrontmatter*(frontmatter: string): YamlNode =
  var stream = newStringStream(frontmatter)
  var root: YamlNode
  load(stream, root)
  stream.close()
  result = root

proc getYamlString(node: YamlNode, key: string, default: string = ""): string =
  if node.kind != yMapping:
    return default
  for k, v in node.fields.pairs:
    if k.content == key:
      if v.kind == yScalar:
        return v.content
  return default

proc getYamlSeq(node: YamlNode, key: string): seq[string] =
  result = @[]
  if node.kind != yMapping:
    return
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == ySequence:
      for item in v.elems:
        if item.kind == yScalar:
          result.add(item.content)

proc getYamlStringList(node: YamlNode, key: string): seq[string] =
  let scalarValue = getYamlString(node, key)
  if scalarValue.len > 0:
    return scalarValue.splitWhitespace()
  return getYamlSeq(node, key)

proc getYamlBool(node: YamlNode, key: string, default: bool = false): bool =
  if node.kind != yMapping:
    return default
  for k, v in node.fields.pairs:
    if k.content == key and v.kind == yScalar:
      let content = v.content.toLowerAscii()
      return content == "true" or content == "yes" or content == "1"
  return default

proc getYamlNode(node: YamlNode, key: string): Option[YamlNode] =
  if node.kind != yMapping:
    return none(YamlNode)
  for k, v in node.fields.pairs:
    if k.content == key:
      return some(v)
  return none(YamlNode)

proc parseCompatibility(node: YamlNode): SkillCompatibility =
  result = SkillCompatibility(agents: @[], platforms: @[], languages: @[])
  if node.kind != yMapping:
    return
  
  result.agents = getYamlSeq(node, "agents")
  result.platforms = getYamlSeq(node, "platforms")
  result.languages = getYamlSeq(node, "languages")

proc parseMetadata(node: YamlNode): SkillMetadata =
  result = SkillMetadata(
    author: none(string),
    version: none(string),
    tags: @[],
    category: none(string),
    internal: false
  )
  if node.kind != yMapping:
    return
  
  let author = getYamlString(node, "author")
  if author.len > 0:
    result.author = some(author)
  
  let version = getYamlString(node, "version")
  if version.len > 0:
    result.version = some(version)
  
  result.tags = getYamlSeq(node, "tags")
  
  let category = getYamlString(node, "category")
  if category.len > 0:
    result.category = some(category)
  
  result.internal = getYamlBool(node, "internal", false)

proc discoverResourcesInDir(skillDir: string): seq[SkillResource] =
  result = @[]
  
  let refDir = skillDir / "references"
  if dirExists(refDir):
    for kind, path in walkDir(refDir):
      if kind == pcFile and path.endsWith(".md"):
        let name = path.splitFile.name
        result.add(SkillResource(
          kind: srkReference,
          name: name,
          relativePath: "references/" & path.extractFilename,
          description: "",
          gitUrl: none(string)
        ))
  
  let scriptDir = skillDir / "scripts"
  if dirExists(scriptDir):
    for kind, path in walkDir(scriptDir):
      if kind == pcFile:
        let name = path.splitFile.name
        result.add(SkillResource(
          kind: srkScript,
          name: name,
          relativePath: "scripts/" & path.extractFilename,
          description: "",
          gitUrl: none(string)
        ))
  
  let assetDir = skillDir / "assets"
  if dirExists(assetDir):
    for kind, path in walkDir(assetDir):
      if kind == pcFile:
        let name = path.splitFile.name
        result.add(SkillResource(
          kind: srkAsset,
          name: name,
          relativePath: "assets/" & path.extractFilename,
          description: "",
          gitUrl: none(string)
        ))

proc extractExternalSkillHints*(content: string): seq[SkillResource] =
  result = @[]
  let lines = content.splitLines()
  for line in lines:
    let lineLower = line.toLowerAscii().strip()
    var url = ""
    if lineLower.startsWith("skill:") or lineLower.startsWith("skills:"):
      let parts = line.split(":", 1)
      if parts.len > 1:
        url = parts[1].strip()
    elif lineLower.startsWith("subskill:") or lineLower.startsWith("sub-skill:"):
      let parts = line.split(":", 1)
      if parts.len > 1:
        url = parts[1].strip()
    
    if url.len > 0 and url.startsWith("http"):
      let cleanUrl = url.splitWhitespace()[0]
      result.add(SkillResource(
        kind: srkExternalSkill,
        name: cleanUrl.extractFilename,
        relativePath: "",
        description: "external skill suggestion",
        gitUrl: some(cleanUrl)
      ))

proc discoverChildSkillsInDir(skillDir: string): seq[SkillSummary] =
  result = @[]
  let skillsDir = skillDir / "skills"
  if not dirExists(skillsDir):
    return
  
  for kind, childDir in walkDir(skillsDir):
    if kind == pcDir:
      let childSkillFile = childDir / "SKILL.md"
      if fileExists(childSkillFile):
        try:
          let content = readFile(childSkillFile)
          let (frontmatter, _) = splitYamlFrontmatter(content)
          if frontmatter.len > 0:
            let yamlNode = parseYamlFrontmatter(frontmatter)
            if yamlNode.kind == yMapping:
              let name = getYamlString(yamlNode, "name", childDir.splitFile.name)
              let desc = getYamlString(yamlNode, "description", "")
              let relPath = "skills/" & childDir.extractFilename
              result.add(SkillSummary(
                name: name,
                description: desc,
                relativePath: relPath
              ))
        except:
          discard

proc parseSkillFile*(path: string, parentName: string = ""): SkillParseResult =
  let fileName = path.splitFile.name
  let parentDir = path.parentDir.splitFile.name
  
  var skillName = if fileName == "SKILL": parentDir else: fileName
  
  try:
    let content = readFile(path)
    let (frontmatter, body) = splitYamlFrontmatter(content)
    
    if frontmatter.len == 0:
      return SkillParseResult(
        success: false,
        error: "No YAML frontmatter found in " & path
      )
    
    let yamlNode = parseYamlFrontmatter(frontmatter)
    
    if yamlNode.kind != yMapping:
      return SkillParseResult(
        success: false,
        error: "Invalid YAML frontmatter in " & path
      )
    
    let name = getYamlString(yamlNode, "name", skillName)
    let description = getYamlString(yamlNode, "description")
    
    let skillDir = path.parentDir
    
    var skill = Skill(
      name: name,
      description: description,
      content: body,
      filePath: path,
      version: if getYamlString(yamlNode, "version").len > 0: some(getYamlString(yamlNode, "version")) else: none(string),
      license: if getYamlString(yamlNode, "license").len > 0: some(getYamlString(yamlNode, "license")) else: none(string),
      rootDir: skillDir,
      childSkills: discoverChildSkillsInDir(skillDir),
      resources: discoverResourcesInDir(skillDir)
    )
    
    if parentName.len > 0:
      skill.parentSkill = some(parentName)
    
    let externalHints = extractExternalSkillHints(body)
    for hint in externalHints:
      skill.resources.add(hint)
    
    let compatNode = getYamlNode(yamlNode, "compatibility")
    if compatNode.isSome:
      skill.compatibility = some(parseCompatibility(compatNode.get))
    
    let metaNode = getYamlNode(yamlNode, "metadata")
    if metaNode.isSome:
      skill.metadata = some(parseMetadata(metaNode.get))
    
    skill.allowedTools = getYamlStringList(yamlNode, "allowed-tools")
    
    let status = validateSkill(skill)
    if not status.valid:
      return SkillParseResult(
        success: false,
        error: "Validation error: " & $status.error
      )
    
    return SkillParseResult(success: true, skill: skill)
  
  except Exception as e:
    return SkillParseResult(
      success: false,
      error: "Failed to parse " & path & ": " & e.msg
    )

proc discoverSkillsRecursive*(basePath: string, parentName: string = ""): seq[Skill] =
  result = @[]
  
  if not dirExists(basePath):
    return
  
  for kind, path in walkDir(basePath):
    if kind == pcDir:
      let skillFile = path / "SKILL.md"
      if fileExists(skillFile):
        let parseResult = parseSkillFile(skillFile, parentName)
        if parseResult.success:
          result.add(parseResult.skill)
          
          let skillsDir = path / "skills"
          if dirExists(skillsDir):
            let childSkills = discoverSkillsRecursive(skillsDir, parseResult.skill.name)
            result.add(childSkills)
        else:
          debug("Failed to parse skill: " & parseResult.error)

proc discoverSkillsInPath*(basePath: string): seq[Skill] =
  result = @[]
  
  if not dirExists(basePath):
    return
  
  for kind, path in walkDir(basePath):
    if kind == pcDir:
      let skillFile = path / "SKILL.md"
      if fileExists(skillFile):
        let parseResult = parseSkillFile(skillFile)
        if parseResult.success:
          result.add(parseResult.skill)
        else:
          debug("Failed to parse skill: " & parseResult.error)

proc getSkillSearchPaths*(): seq[string] =
  result = @[]
  
  result.add(".agents/skills")
  result.add(".claude/skills")
  result.add(".opencode/skills")
  
  let home = getHomeDir()
  result.add(home / ".agents" / "skills")
  result.add(home / ".claude" / "skills")
  result.add(home / ".opencode" / "skills")
  result.add(home / ".niffler" / "skills")
  
  let configDir = getConfigDir()
  result.add(configDir / "opencode" / "skills")
  result.add(configDir / "claude" / "skills")
  result.add(configDir / "niffler" / "skills")

proc discoverAllSkills*(): seq[Skill] =
  result = @[]
  let searchPaths = getSkillSearchPaths()
  var seen = initTable[string, bool]()
  
  for searchPath in searchPaths:
    let skills = discoverSkillsRecursive(searchPath)
    for skill in skills:
      if skill.name notin seen:
        seen[skill.name] = true
        result.add(skill)

proc buildSkillRegistry*(): SkillRegistry =
  result = createEmptyRegistry()
  let skills = discoverAllSkills()
  for skill in skills:
    addSkillToRegistry(result, skill)

proc loadSkillFromFile*(path: string): Option[Skill] =
  let parseResult = parseSkillFile(path)
  if parseResult.success:
    some(parseResult.skill)
  else:
    debug("Failed to load skill: " & parseResult.error)
    none(Skill)

proc findSkillInRegistry*(registry: SkillRegistry, query: string): seq[Skill] =
  result = @[]
  let queryLower = query.toLowerAscii()
  var seen = initTable[string, bool]()
  
  if queryLower in registry.skills:
    result.add(registry.skills[queryLower])
    seen[queryLower] = true
    return
  
  for name, skill in registry.skills:
    if name notin seen and (name.contains(queryLower) or
       skill.description.toLowerAscii().contains(queryLower)):
      result.add(skill)
      seen[name] = true
  
  for tag, skillNames in registry.byTag:
    if tag.toLowerAscii().contains(queryLower):
      for name in skillNames:
        if name notin seen and name in registry.skills:
          result.add(registry.skills[name])
          seen[name] = true
  
  for lang, skillNames in registry.byLanguage:
    if lang.toLowerAscii().contains(queryLower):
      for name in skillNames:
        if name notin seen and name in registry.skills:
          result.add(registry.skills[name])
          seen[name] = true

proc findSkillByPath*(registry: SkillRegistry, path: string): Option[Skill] =
  let normalized = path.replace("\\", "/").strip(chars = {'/'})
  for name, skill in registry.skills:
    let skillPath = skill.filePath.replace("\\", "/").parentDir.strip(chars = {'/'})
    if skillPath == normalized or skillPath.endsWith("/" & normalized):
      return some(skill)
  none(Skill)

proc getChildSkills*(registry: SkillRegistry, parentName: string): seq[Skill] =
  result = @[]
  for name, skill in registry.skills:
    if skill.parentSkill.isSome and skill.parentSkill.get == parentName:
      result.add(skill)

proc loadResourceContent*(skill: Skill, relativePath: string): Option[string] =
  let fullPath = skill.rootDir / relativePath
  if fileExists(fullPath):
    try:
      return some(readFile(fullPath))
    except:
      return none(string)
  none(string)
