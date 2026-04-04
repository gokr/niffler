## Skill type definitions for Agent Skills support
##
## This module defines types for the Agent Skills specification (agentskills.io).
## Skills are reusable instruction modules that can be loaded dynamically.

import std/[options, tables]

type
  SkillValidation* = enum
    svValid = "Valid"
    svMissingName = "Missing required 'name' field"
    svMissingDescription = "Missing required 'description' field"
    svInvalidName = "Invalid skill name (must be lowercase, hyphens, 1-64 chars)"
    svNameMismatch = "Skill name must match parent directory name"

  SkillStatus* = object
    valid*: bool
    error*: SkillValidation

  SkillCompatibility* = object
    agents*: seq[string]
    platforms*: seq[string]
    languages*: seq[string]

  SkillMetadata* = object
    author*: Option[string]
    version*: Option[string]
    tags*: seq[string]
    category*: Option[string]
    internal*: bool

  SkillRelationKind* = enum
    srkChildSkill
    srkReference
    srkScript
    srkAsset
    srkExternalSkill

  SkillResource* = object
    kind*: SkillRelationKind
    name*: string
    relativePath*: string
    description*: string
    gitUrl*: Option[string]

  SkillSummary* = object
    name*: string
    description*: string
    relativePath*: string

  Skill* = object
    name*: string
    description*: string
    content*: string
    filePath*: string
    version*: Option[string]
    license*: Option[string]
    compatibility*: Option[SkillCompatibility]
    metadata*: Option[SkillMetadata]
    allowedTools*: seq[string]
    rootDir*: string
    parentSkill*: Option[string]
    childSkills*: seq[SkillSummary]
    resources*: seq[SkillResource]

  SkillRegistry* = object
    skills*: Table[string, Skill]
    byLanguage*: Table[string, seq[string]]
    byTag*: Table[string, seq[string]]
    loadedSkills*: seq[string]

  RequestContext* = object
    basePrompt*: string
    activeSkills*: seq[Skill]
    toolWhitelist*: Option[seq[string]]
    mode*: int
    sessionId*: int64

proc createEmptySkill*(): Skill =
  result = Skill(
    name: "",
    description: "",
    content: "",
    filePath: "",
    rootDir: "",
    childSkills: @[],
    resources: @[]
  )

proc isValidSkillName*(name: string): bool =
  if name.len == 0 or name.len > 64:
    return false
  if name[0] == '-' or name[^1] == '-':
    return false
  for i, c in name:
    if c == '-':
      if i > 0 and name[i-1] == '-':
        return false
    elif c notin {'a'..'z', '0'..'9'}:
      return false
  result = true

proc validateSkill*(skill: Skill): SkillStatus =
  result = SkillStatus(valid: true, error: svValid)
  
  if skill.name.len == 0:
    return SkillStatus(valid: false, error: svMissingName)
  
  if not isValidSkillName(skill.name):
    return SkillStatus(valid: false, error: svInvalidName)
  
  if skill.description.len == 0:
    return SkillStatus(valid: false, error: svMissingDescription)

proc hasSkill*(registry: SkillRegistry, name: string): bool =
  name in registry.skills

proc getSkill*(registry: SkillRegistry, name: string): Option[Skill] =
  if name in registry.skills:
    some(registry.skills[name])
  else:
    none(Skill)

proc getSkillsByLanguage*(registry: SkillRegistry, language: string): seq[Skill] =
  if language in registry.byLanguage:
    for name in registry.byLanguage[language]:
      if name in registry.skills:
        result.add(registry.skills[name])

proc getSkillsByTag*(registry: SkillRegistry, tag: string): seq[Skill] =
  if tag in registry.byTag:
    for name in registry.byTag[tag]:
      if name in registry.skills:
        result.add(registry.skills[name])

proc getLoadedSkills*(registry: SkillRegistry): seq[Skill] =
  for name in registry.loadedSkills:
    if name in registry.skills:
      result.add(registry.skills[name])

proc isSkillLoaded*(registry: SkillRegistry, name: string): bool =
  name in registry.loadedSkills

proc createEmptyRegistry*(): SkillRegistry =
  result = SkillRegistry(
    skills: initTable[string, Skill](),
    byLanguage: initTable[string, seq[string]](),
    byTag: initTable[string, seq[string]](),
    loadedSkills: @[]
  )

proc addSkillToRegistry*(registry: var SkillRegistry, skill: Skill) =
  registry.skills[skill.name] = skill
  
  if skill.compatibility.isSome:
    for lang in skill.compatibility.get.languages:
      if lang notin registry.byLanguage:
        registry.byLanguage[lang] = @[]
      if skill.name notin registry.byLanguage[lang]:
        registry.byLanguage[lang].add(skill.name)
  
  if skill.metadata.isSome:
    let meta = skill.metadata.get
    for tag in meta.tags:
      if tag notin registry.byTag:
        registry.byTag[tag] = @[]
      if skill.name notin registry.byTag[tag]:
        registry.byTag[tag].add(skill.name)

proc loadSkill*(registry: var SkillRegistry, name: string): bool =
  if name in registry.skills and name notin registry.loadedSkills:
    registry.loadedSkills.add(name)
    return true
  return false

proc unloadSkill*(registry: var SkillRegistry, name: string): bool =
  let idx = registry.loadedSkills.find(name)
  if idx >= 0:
    registry.loadedSkills.delete(idx)
    return true
  return false

proc clearLoadedSkills*(registry: var SkillRegistry) =
  registry.loadedSkills = @[]
