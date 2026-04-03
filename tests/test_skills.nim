## Test skills parsing and registry

import unittest
import strutils
import options
import tables
import os
import sequtils
import ../src/types/skills
import ../src/core/skills_discovery
import ../src/tools/skill

type SkillThreadCheckArgs = object
  expectedName: string
  found: ptr bool
  count: ptr int

proc checkLoadedSkillVisibleAcrossThread(args: SkillThreadCheckArgs) {.thread.} =
  let skills = getSkillsForSystemPrompt()
  args.found[] = skills.anyIt(it.name == args.expectedName)
  args.count[] = skills.len

suite "Skill YAML Frontmatter Parsing":
  test "Parse minimal SKILL.md":
    let content = """
---
name: test-skill
description: A test skill for unit testing.
---

# Test Skill

This is the skill content.
"""
    let (frontmatter, body) = splitYamlFrontmatter(content)
    check frontmatter.len > 0
    check "Test Skill" in body
  
  test "Parse skill with metadata":
    let content = """
---
name: go-expert
description: Go language best practices
version: "1.0.0"
license: MIT
metadata:
  author: test-author
  tags:
    - golang
    - best-practices
  category: languages
compatibility:
  languages:
    - go
  agents:
    - claude-code
    - opencode
---

# Go Expert

Instructions here.
"""
    createDir("/tmp/test-skill")
    writeFile("/tmp/test-skill/SKILL.md", content)
    let parsed = parseSkillFile("/tmp/test-skill/SKILL.md")
    check parsed.success
    check parsed.skill.name == "go-expert"
    check parsed.skill.description == "Go language best practices"
    check parsed.skill.metadata.isSome
    check "golang" in parsed.skill.metadata.get.tags

  test "Parse skill with allowed-tools sequence":
    let content = """
---
name: shell-skill
description: Shell helpers
allowed-tools:
  - bash
  - read
---

Use bash and read.
"""
    createDir("/tmp/shell-skill")
    writeFile("/tmp/shell-skill/SKILL.md", content)
    let parsed = parseSkillFile("/tmp/shell-skill/SKILL.md")
    check parsed.success
    check parsed.skill.allowedTools == @["bash", "read"]

suite "Skill Validation":
  test "Valid skill name":
    check isValidSkillName("test-skill")
    check isValidSkillName("go-expert")
    check isValidSkillName("my-skill-123")
  
  test "Invalid skill names":
    check not isValidSkillName("")
    check not isValidSkillName("-starts-with-hyphen")
    check not isValidSkillName("ends-with-hyphen-")
    check not isValidSkillName("has--double-hyphen")
    check not isValidSkillName("UPPERCASE")
    check not isValidSkillName("has_underscore")
    check not isValidSkillName("a".repeat(65))

suite "Skill Registry":
  test "Create empty registry":
    let registry = createEmptyRegistry()
    check len(registry.skills) == 0
    check registry.loadedSkills.len == 0
  
  test "Add and load skill":
    var registry = createEmptyRegistry()
    let skill = Skill(
      name: "test-skill",
      description: "Test description",
      content: "Test content",
      filePath: "/tmp/test.md"
    )
    addSkillToRegistry(registry, skill)
    check registry.skills.len == 1
    check hasSkill(registry, "test-skill")
    check loadSkill(registry, "test-skill")
    check isSkillLoaded(registry, "test-skill")
    check unloadSkill(registry, "test-skill")
    check not isSkillLoaded(registry, "test-skill")

suite "Shared Skill State":
  test "Loaded skill is visible across threads":
    let originalDir = getCurrentDir()
    let tempDir = "/tmp/niffler-skill-thread-test"
    let skillDir = tempDir / ".agents" / "skills" / "thread-skill"

    try:
      if dirExists(tempDir):
        removeDir(tempDir)
      createDir(skillDir)
      writeFile(skillDir / "SKILL.md", """
---
name: thread-skill
description: Thread visibility skill
---

Visible in system prompt.
""")

      setCurrentDir(tempDir)
      refreshSkillRegistry()
      unloadAllSkillsGlobal()
      check loadSkillGlobal("thread-skill")

      var found = false
      var count = 0
      var worker: Thread[SkillThreadCheckArgs]
      createThread(worker, checkLoadedSkillVisibleAcrossThread,
        SkillThreadCheckArgs(expectedName: "thread-skill", found: addr found, count: addr count))
      joinThread(worker)

      check found
      check count == 1
    finally:
      unloadAllSkillsGlobal()
      refreshSkillRegistry()
      setCurrentDir(originalDir)
      if dirExists(tempDir):
        removeDir(tempDir)
