import std/[unittest, os, strutils]
import ../src/core/[session, system_prompt]
import ../src/tools/skill
import ../src/types/mode

suite "System Prompt Skills":
  test "loaded skill appears in generated system prompt":
    let originalDir = getCurrentDir()
    let tempDir = "/tmp/niffler-system-prompt-skill-test"
    let skillDir = tempDir / ".agents" / "skills" / "prompt-skill"

    try:
      if dirExists(tempDir):
        removeDir(tempDir)
      createDir(skillDir)
      writeFile(skillDir / "SKILL.md", """
---
name: prompt-skill
description: Prompt-visible skill
allowed-tools:
  - bash
---

PROMPT_SKILL_MARKER_123

Use bash carefully.
""")

      setCurrentDir(tempDir)
      refreshSkillRegistry()
      unloadAllSkillsGlobal()
      check loadSkillGlobal("prompt-skill")

      let sess = initSession()
      let prompt = generateSystemPromptWithTokens(amCode, sess, "default")

      check "## Skill: prompt-skill" in prompt.content
      check "PROMPT_SKILL_MARKER_123" in prompt.content
      check prompt.tokens.skills > 0
    finally:
      unloadAllSkillsGlobal()
      refreshSkillRegistry()
      setCurrentDir(originalDir)
      if dirExists(tempDir):
        removeDir(tempDir)
