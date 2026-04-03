## Skill Tool Implementation
##
## This module implements the skill tool for dynamic skill management.
## Operations: list, load, unload, show, search

import std/[json, strutils, strformat, osproc, options, tables, locks, sequtils]
import ../types/skills
import ../core/skills_discovery

var skillRegistryLock: Lock
var globalSkillRegistry: SkillRegistry
var registryInitialized: bool
var skillsInjectedAsDeveloper: seq[string]

initLock(skillRegistryLock)

proc ensureSkillRegistryInitialized() =
  if registryInitialized:
    return

  globalSkillRegistry = buildSkillRegistry()
  skillsInjectedAsDeveloper = @[]
  registryInitialized = true

proc tryLoadSkillState(skillName: string): tuple[loaded: bool, alreadyLoaded: bool, skill: Option[Skill], loadedCount: int, error: string] =
  withLock(skillRegistryLock):
    ensureSkillRegistryInitialized()

    if skillName notin globalSkillRegistry.skills:
      return (false, false, none(Skill), globalSkillRegistry.loadedSkills.len,
        fmt("Skill '{skillName}' not found. Use 'list' to see available skills."))

    if isSkillLoaded(globalSkillRegistry, skillName):
      return (false, true, some(globalSkillRegistry.skills[skillName]), globalSkillRegistry.loadedSkills.len, "")

    let loaded = loadSkill(globalSkillRegistry, skillName)
    if not loaded:
      return (false, false, none(Skill), globalSkillRegistry.loadedSkills.len, "Failed to load skill")

    return (true, false, some(globalSkillRegistry.skills[skillName]), globalSkillRegistry.loadedSkills.len, "")

proc tryUnloadSkillState(skillName: string, unloadAll: bool): tuple[success: bool, loadedCount: int, error: string] =
  withLock(skillRegistryLock):
    ensureSkillRegistryInitialized()

    if unloadAll:
      clearLoadedSkills(globalSkillRegistry)
      return (true, globalSkillRegistry.loadedSkills.len, "")

    if skillName.len == 0:
      return (false, globalSkillRegistry.loadedSkills.len, "Missing required parameter 'name' or 'all'")

    if not isSkillLoaded(globalSkillRegistry, skillName):
      return (false, globalSkillRegistry.loadedSkills.len, fmt("Skill '{skillName}' is not loaded."))

    if unloadSkill(globalSkillRegistry, skillName):
      return (true, globalSkillRegistry.loadedSkills.len, "")

    return (false, globalSkillRegistry.loadedSkills.len, "Failed to unload skill")

proc getGlobalSkillRegistry*(): SkillRegistry {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      return globalSkillRegistry

proc getLoadedSkillNames*(): seq[string] {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      return globalSkillRegistry.loadedSkills

proc getLoadedSkillsList*(): seq[Skill] {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      result = @[]
      for name in globalSkillRegistry.loadedSkills:
        if name in globalSkillRegistry.skills:
          result.add(globalSkillRegistry.skills[name])

proc refreshSkillRegistry*() {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      let loaded = globalSkillRegistry.loadedSkills
      globalSkillRegistry = buildSkillRegistry()
      globalSkillRegistry.loadedSkills = loaded.filterIt(it in globalSkillRegistry.skills)
      skillsInjectedAsDeveloper = skillsInjectedAsDeveloper.filterIt(it in globalSkillRegistry.loadedSkills)
      registryInitialized = true

proc markSkillInjectedAsDeveloper*(skillName: string) {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      if skillName notin skillsInjectedAsDeveloper:
        skillsInjectedAsDeveloper.add(skillName)

proc unmarkSkillInjectedAsDeveloper*(skillName: string) {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      let idx = skillsInjectedAsDeveloper.find(skillName)
      if idx >= 0:
        skillsInjectedAsDeveloper.delete(idx)

proc wasSkillInjectedAsDeveloper*(skillName: string): bool {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      return skillName in skillsInjectedAsDeveloper

proc getSkillsForSystemPrompt*(): seq[Skill] {.gcsafe.} =
  ## Get skills that should be included in system prompt (not injected as developer messages)
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      result = @[]
      for name in globalSkillRegistry.loadedSkills:
        if name notin skillsInjectedAsDeveloper and name in globalSkillRegistry.skills:
          result.add(globalSkillRegistry.skills[name])

proc loadSkillGlobal*(skillName: string): bool {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      result = loadSkill(globalSkillRegistry, skillName)

proc unloadSkillGlobal*(skillName: string): bool {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      result = unloadSkill(globalSkillRegistry, skillName)

proc unloadAllSkillsGlobal*() {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      clearLoadedSkills(globalSkillRegistry)

proc isSkillLoadedGlobal*(skillName: string): bool {.gcsafe.} =
  {.gcsafe.}:
    withLock(skillRegistryLock):
      ensureSkillRegistryInitialized()
      result = isSkillLoaded(globalSkillRegistry, skillName)

proc formatSkillList*(skills: seq[Skill], includeContent: bool = false): string =
  if skills.len == 0:
    return "No skills found."
  
  var lines: seq[string] = @[]
  for skill in skills:
    var line = fmt("• {skill.name}")
    if skill.version.isSome:
      line &= fmt(" (v{skill.version.get})")
    line &= fmt(" - {skill.description[0..min(80, skill.description.len-1)]}")
    lines.add(line)
  
  return lines.join("\n")

proc formatSkillDetail*(skill: Skill): string =
  var lines: seq[string] = @[]
  lines.add(fmt("# Skill: {skill.name}"))
  
  if skill.version.isSome:
    lines.add(fmt("**Version:** {skill.version.get}"))
  
  if skill.license.isSome:
    lines.add(fmt("**License:** {skill.license.get}"))
  
  lines.add("")
  lines.add(fmt("**Description:** {skill.description}"))
  
  if skill.compatibility.isSome:
    let compat = skill.compatibility.get
    if compat.languages.len > 0:
      lines.add(fmt("**Languages:** {compat.languages.join(\", \")}"))
    if compat.agents.len > 0:
      lines.add(fmt("**Compatible with:** {compat.agents.join(\", \")}"))
  
  if skill.metadata.isSome:
    let meta = skill.metadata.get
    if meta.author.isSome:
      lines.add(fmt("**Author:** {meta.author.get}"))
    if meta.tags.len > 0:
      lines.add(fmt("**Tags:** {meta.tags.join(\", \")}"))
  
  lines.add("")
  lines.add("## Instructions")
  lines.add("")
  lines.add(skill.content)
  
  return lines.join("\n")

proc executeSkillList*(args: JsonNode): string {.gcsafe.} =
  let registry = getGlobalSkillRegistry()
  let loadedOnly = args.hasKey("loaded_only") and args["loaded_only"].getBool()
  let language = if args.hasKey("language"): args["language"].getStr() else: ""
  let tag = if args.hasKey("tag"): args["tag"].getStr() else: ""
  
  var skills: seq[Skill] = @[]
  
  if loadedOnly:
    skills = getLoadedSkillsList()
  elif language.len > 0:
    skills = getSkillsByLanguage(registry, language)
  elif tag.len > 0:
    skills = getSkillsByTag(registry, tag)
  else:
    for name, skill in registry.skills.pairs:
      skills.add(skill)
  
  if skills.len == 0:
    return $ %*{"result": "No skills found.", "count": 0}
  
  let formatted = formatSkillList(skills)
  return $ %*{
    "result": formatted,
    "count": skills.len,
    "loaded": if loadedOnly: true else: false
  }

proc executeSkillLoad*(args: JsonNode): string {.gcsafe.} =
  let skillName = if args.hasKey("name"): args["name"].getStr() else: ""
  
  if skillName.len == 0:
    return $ %*{"error": "Missing required parameter 'name'"}
  
  {.gcsafe.}:
    let loadResult = tryLoadSkillState(skillName)
    if loadResult.error.len > 0:
      return $ %*{"error": loadResult.error}

    if loadResult.alreadyLoaded:
      return $ %*{"result": fmt("Skill '{skillName}' is already loaded."), "already_loaded": true}

    let skill = loadResult.skill.get()
    return $ %*{
      "result": fmt("Loaded skill: {skillName}"),
      "skill": {
        "name": skill.name,
        "description": skill.description
      },
      "loaded_count": loadResult.loadedCount
    }

proc executeSkillUnload*(args: JsonNode): string {.gcsafe.} =
  let skillName = if args.hasKey("name"): args["name"].getStr() else: ""
  let unloadAll = args.hasKey("all") and args["all"].getBool()
  
  {.gcsafe.}:
    let unloadResult = tryUnloadSkillState(skillName, unloadAll)
    if not unloadResult.success:
      return $ %*{"error": unloadResult.error}

    if unloadAll:
      return $ %*{"result": "All skills unloaded.", "loaded_count": unloadResult.loadedCount}

    return $ %*{"result": fmt("Unloaded skill: {skillName}"), "loaded_count": unloadResult.loadedCount}

proc executeSkillShow*(args: JsonNode): string {.gcsafe.} =
  let skillName = if args.hasKey("name"): args["name"].getStr() else: ""
  
  if skillName.len == 0:
    return $ %*{"error": "Missing required parameter 'name'"}
  
  let registry = getGlobalSkillRegistry()
  
  if skillName notin registry.skills:
    return $ %*{"error": fmt("Skill '{skillName}' not found.")}
  
  let skill = registry.skills[skillName]
  let detail = formatSkillDetail(skill)
  return $ %*{
    "result": detail,
    "loaded": isSkillLoaded(registry, skillName)
  }

proc executeSkillSearch*(args: JsonNode): string {.gcsafe.} =
  let query = if args.hasKey("query"): args["query"].getStr() else: ""
  
  if query.len == 0:
    return $ %*{"error": "Missing required parameter 'query'"}
  
  let registry = getGlobalSkillRegistry()
  let matches = findSkillInRegistry(registry, query)
  
  if matches.len == 0:
    return $ %*{
      "result": "No matching skills found.",
      "query": query,
      "count": 0
    }
  
  let formatted = formatSkillList(matches)
  return $ %*{
    "result": formatted,
    "query": query,
    "count": matches.len
  }

proc executeSkillRefresh*(args: JsonNode): string {.gcsafe.} =
  {.gcsafe.}:
    refreshSkillRegistry()
    let registry = getGlobalSkillRegistry()
    return $ %*{
      "result": fmt("Refreshed skill registry. Found {registry.skills.len} skills."),
      "count": registry.skills.len
    }

proc executeSkillDownload*(args: JsonNode): string {.gcsafe.} =
  let repo = if args.hasKey("repo"): args["repo"].getStr() else: ""
  let skillName = if args.hasKey("skill"): args["skill"].getStr() else: ""
  let global = args.hasKey("global") and args["global"].getBool()
  
  if repo.len == 0:
    return $ %*{"error": "Missing required parameter 'repo' (e.g., 'vercel-labs/agent-skills')"}
  
  var cmd = "npx skills add " & repo
  if skillName.len > 0:
    cmd &= " --skill " & skillName
  if global:
    cmd &= " -g"
  cmd &= " -a opencode -y"
  
  try:
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode == 0:
      {.gcsafe.}:
        refreshSkillRegistry()
      return $ %*{
        "result": "Skill installed successfully.",
        "output": output,
        "command": cmd
      }
    else:
      return $ %*{
        "error": "Failed to install skill",
        "output": output,
        "command": cmd
      }
  except Exception as e:
    return $ %*{"error": "Failed to run skills CLI: " & e.msg}

proc executeSkill*(args: JsonNode): string {.gcsafe.} =
  let operation = if args.hasKey("operation"): args["operation"].getStr() else: "list"
  
  case operation.toLowerAscii()
  of "list", "ls":
    return executeSkillList(args)
  of "load":
    return executeSkillLoad(args)
  of "unload":
    return executeSkillUnload(args)
  of "show":
    return executeSkillShow(args)
  of "search", "find":
    return executeSkillSearch(args)
  of "refresh":
    return executeSkillRefresh(args)
  of "download", "install", "add":
    return executeSkillDownload(args)
  else:
    let msg = "Unknown operation: " & operation & ". Valid: list, load, unload, show, search, refresh, download"
    return $ %*{"error": msg}
