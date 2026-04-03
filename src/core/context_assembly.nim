## Context Assembly Layer
##
## LLM-based assembly of system prompt, tool selection, and developer prompts.
## Adapts skills from other harnesses to Niffler's tool set.

import std/[strutils, tables, options]
import ../types/[skills, context_assembly]

var globalAssemblyCache {.threadvar.}: AssemblyCache
var cacheInitialized {.threadvar.}: bool

proc getAssemblyCache*(): ptr AssemblyCache {.gcsafe.} =
  {.gcsafe.}:
    if not cacheInitialized:
      globalAssemblyCache = createEmptyAssemblyCache()
      cacheInitialized = true
    return addr(globalAssemblyCache)

proc clearAssemblyCache*() {.gcsafe.} =
  {.gcsafe.}:
    globalAssemblyCache = createEmptyAssemblyCache()
    cacheInitialized = true

proc heuristicToolMap*(toolName: string): tuple[name: string, confidence: float] =
  let normalized = toolName.toLowerAscii().strip()
  
  case normalized
  of "bash":
    return ("bash", 1.0)
  of "read", "readfile", "read_file":
    return ("read", 1.0)
  of "edit", "editfile", "edit_file", "apply_patch":
    return ("edit", 1.0)
  of "create", "write", "writefile", "write_file":
    return ("create", 1.0)
  of "list", "ls", "listdir", "list_dir":
    return ("list", 1.0)
  of "glob", "globtool", "findfiles", "find_files":
    return ("list", 0.9)
  of "fetch", "http", "curl", "wget", "webfetch":
    return ("fetch", 1.0)
  of "todolist", "todo", "todos":
    return ("todolist", 1.0)
  of "task", "subagent", "sub_agent":
    return ("task", 1.0)
  of "skill", "skills":
    return ("skill", 1.0)
  else:
    if normalized.startsWith("bash("):
      return ("bash", 1.0)
    elif normalized.contains("git"):
      return ("bash", 0.95)
    elif normalized.contains("npm") or normalized.contains("yarn") or normalized.contains("pnpm"):
      return ("bash", 0.95)
    elif normalized.contains("docker"):
      return ("bash", 0.95)
    elif normalized.contains("go ") or normalized == "go":
      return ("bash", 0.9)
    elif normalized.contains("python") or normalized.contains("pip") or normalized.contains("uv"):
      return ("bash", 0.9)
    elif normalized.contains("cargo") or normalized.contains("rust"):
      return ("bash", 0.9)
    elif normalized.contains("make") or normalized.contains("cmake"):
      return ("bash", 0.85)
    elif normalized.contains("kubectl") or normalized.contains("helm"):
      return ("bash", 0.85)
    return (normalized, 0.3)

proc adaptSkillContent*(content: string, mappings: seq[ToolMapping]): string =
  result = content
  for mapping in mappings:
    if mapping.confidence > 0.5 and mapping.originalName != mapping.mappedName:
      result = result.replace(mapping.originalName, mapping.mappedName)

proc createAdaptedSkill*(skill: Skill): AdaptedSkill =
  result = AdaptedSkill(
    original: skill,
    adaptedContent: skill.content,
    toolMappings: @[],
    unavailableTools: @[],
    developerPrompt: none(string)
  )
  
  for toolName in skill.allowedTools:
    let (mapped, confidence) = heuristicToolMap(toolName)
    result.toolMappings.add(ToolMapping(
      originalName: toolName,
      mappedName: mapped,
      confidence: confidence,
      notes: ""
    ))
    if confidence < 0.3:
      result.unavailableTools.add(toolName)
  
  result.adaptedContent = adaptSkillContent(skill.content, result.toolMappings)
  
  {.gcsafe.}:
    let cache = getAssemblyCache()
    cache[].skillAdaptations[skill.name] = result

proc adaptSkill*(skill: Skill): AdaptedSkill =
  {.gcsafe.}:
    let cache = getAssemblyCache()
    if skill.name in cache[].skillAdaptations:
      return cache[].skillAdaptations[skill.name]
  
  result = createAdaptedSkill(skill)

proc buildContextPlan*(skills: seq[Skill], task: string = ""): ContextPlan =
  result = createEmptyContextPlan()
  
  for skill in skills:
    let adapted = adaptSkill(skill)
    result.adaptedSkills.add(adapted)
    
    for mapping in adapted.toolMappings:
      if mapping.confidence > 0.5 and mapping.mappedName notin result.toolWhitelist:
        result.toolWhitelist.add(mapping.mappedName)
  
  if task.len > 50:
    result.developerPrompt = some("## Task Context\n\n" & task)
  
  var notes: seq[string] = @[]
  for adapted in result.adaptedSkills:
    var note = "Skill '" & adapted.original.name & "' loaded"
    if adapted.unavailableTools.len > 0:
      note &= " (unavailable: " & adapted.unavailableTools.join(", ") & ")"
    notes.add(note)
  result.contextNotes = notes.join("\n")

proc getAdaptedSkillContent*(plan: ContextPlan): string =
  var parts: seq[string] = @[]
  for adapted in plan.adaptedSkills:
    parts.add("## Skill: " & adapted.original.name)
    parts.add("")
    parts.add(adapted.adaptedContent)
    parts.add("")
  result = parts.join("\n")

proc getToolWhitelistFromPlan*(plan: ContextPlan): seq[string] =
  result = @[]
  for mapping in plan.toolWhitelist:
    if mapping notin result:
      result.add(mapping)
