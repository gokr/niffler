## Test context assembly

import unittest
import strutils
import options
import tables
import sequtils
import os
import ../src/types/skills
import ../src/types/context_assembly
import ../src/core/skills_discovery
import ../src/core/context_assembly

suite "Heuristic Tool Mapping":
  test "Direct matches":
    let (name, conf) = heuristicToolMap("bash")
    check name == "bash"
    check conf == 1.0
    
    let (name2, conf2) = heuristicToolMap("read")
    check name2 == "read"
    check conf2 == 1.0
  
  test "Variant matches":
    let (name, conf) = heuristicToolMap("GlobTool")
    check name == "list"
    check conf == 0.9
    
    let (name2, conf2) = heuristicToolMap("apply_patch")
    check name2 == "edit"
    check conf2 == 1.0
  
  test "Command-based mapping":
    let (name, conf) = heuristicToolMap("Bash(git:*)")
    check name == "bash"
    check conf == 1.0
  
  test "Unknown tools":
    let (name, conf) = heuristicToolMap("random_unknown_tool")
    check conf < 0.5

suite "Skill Adaptation":
  test "Adapt skill with mapped tools":
    let skill = Skill(
      name: "test-skill",
      description: "Test skill",
      content: "Use Bash and GlobTool for this task",
      filePath: "/tmp/test.md",
      allowedTools: @["Bash", "GlobTool", "Read"]
    )
    
    let adapted = adaptSkill(skill)
    check adapted.toolMappings.len == 3
    check adapted.unavailableTools.len == 0
    
    let bashMapping = adapted.toolMappings.filterIt(it.originalName == "Bash")[0]
    check bashMapping.mappedName == "bash"
    check bashMapping.confidence == 1.0
  
  test "Content adaptation":
    let skill = Skill(
      name: "content-test",
      description: "Test",
      content: "Use GlobTool to find files",
      filePath: "/tmp/test.md",
      allowedTools: @["GlobTool"]
    )
    
    let adapted = adaptSkill(skill)
    check "list" in adapted.adaptedContent

suite "Context Plan":
  test "Build context plan from skills":
    let skills = @[
      Skill(name: "go", description: "Go skill", content: "Go content", filePath: "/tmp/a.md"),
      Skill(name: "python", description: "Python skill", content: "Python content", filePath: "/tmp/b.md")
    ]
    
    let plan = buildContextPlan(skills)
    check plan.adaptedSkills.len == 2
    check plan.contextNotes.contains("go")
    check plan.contextNotes.contains("python")
  
  test "Developer prompt for complex tasks":
    let complexTask = "This is a very complex task that requires multiple steps and careful planning"
    let plan = buildContextPlan(@[], complexTask)
    check plan.developerPrompt.isSome
    check plan.developerPrompt.get.contains("complex task")

suite "Adaptation Cache":
  test "Cache stores adaptation":
    clearAssemblyCache()
    let skill = Skill(
      name: "cached-skill",
      description: "Cached",
      content: "Content",
      filePath: "/tmp/cached.md"
    )
    
    discard adaptSkill(skill)
    let cache = getAssemblyCache()
    check "cached-skill" in cache[].skillAdaptations
  
  test "Cache returns same adaptation":
    clearAssemblyCache()
    let skill = Skill(
      name: "same-skill",
      description: "Same",
      content: "Same content",
      filePath: "/tmp/same.md"
    )
    
    let adapted1 = adaptSkill(skill)
    let adapted2 = adaptSkill(skill)
    check adapted1.original.name == adapted2.original.name
