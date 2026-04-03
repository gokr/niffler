## Context Assembly Types
##
## Types for LLM-based context assembly including skill adaptation,
## tool mapping, and developer prompt generation.

import std/[options, tables, strformat]
import ../types/skills

type
  ToolMapping* = object
    originalName*: string
    mappedName*: string
    confidence*: float  # 0.0 - 1.0
    notes*: string

  AdaptedSkill* = object
    original*: Skill
    adaptedContent*: string
    toolMappings*: seq[ToolMapping]
    unavailableTools*: seq[string]
    developerPrompt*: Option[string]

  ContextPlan* = object
    toolWhitelist*: seq[string]
    adaptedSkills*: seq[AdaptedSkill]
    developerPrompt*: Option[string]
    recommendedSubagents*: seq[string]
    contextNotes*: string

  AssemblyCache* = object
    skillAdaptations*: Table[string, AdaptedSkill]
    contextPlans*: Table[string, ContextPlan]

  AssemblyResult* = object
    success*: bool
    plan*: ContextPlan
    error*: string

proc createEmptyContextPlan*(): ContextPlan =
  result = ContextPlan(
    toolWhitelist: @[],
    adaptedSkills: @[],
    developerPrompt: none(string),
    recommendedSubagents: @[],
    contextNotes: ""
  )

proc createEmptyAssemblyCache*(): AssemblyCache =
  result = AssemblyCache(
    skillAdaptations: initTable[string, AdaptedSkill](),
    contextPlans: initTable[string, ContextPlan]()
  )

proc hasAdaptation*(cache: AssemblyCache, skillName: string): bool =
  skillName in cache.skillAdaptations

proc getAdaptation*(cache: AssemblyCache, skillName: string): Option[AdaptedSkill] =
  if skillName in cache.skillAdaptations:
    some(cache.skillAdaptations[skillName])
  else:
    none(AdaptedSkill)

proc storeAdaptation*(cache: var AssemblyCache, adapted: AdaptedSkill) =
  cache.skillAdaptations[adapted.original.name] = adapted

proc getAllMappedTools*(plan: ContextPlan): seq[string] =
  result = plan.toolWhitelist
  for adapted in plan.adaptedSkills:
    for mapping in adapted.toolMappings:
      if mapping.mappedName notin result and mapping.confidence > 0.5:
        result.add(mapping.mappedName)

proc hasAmbiguousMappings*(adapted: AdaptedSkill): bool =
  for mapping in adapted.toolMappings:
    if mapping.confidence < 0.7:
      return true
  return false

proc formatToolMapping*(mapping: ToolMapping): string =
  if mapping.confidence >= 0.9:
    fmt("{mapping.originalName} → {mapping.mappedName}")
  elif mapping.confidence >= 0.5:
    fmt("{mapping.originalName} → {mapping.mappedName} (?)")
  else:
    fmt("{mapping.originalName} → UNKNOWN")
