import unittest
import strformat
import strutils
import options
import tables
import ../src/core/skills_discovery
import ../src/tools/skill
import ../src/types/skills

suite "Nested Skill Discovery":
  test "Discover all skills including nested":
    let skills = discoverAllSkills()
    echo fmt"Found {skills.len} skills"
    check skills.len > 0
    
    var hasGolang = false
    var hasGoErrorHandling = false
    
    for s in skills:
      if s.name == "golang":
        hasGolang = true
        echo fmt"  golang skill has {s.childSkills.len} child skills"
        for child in s.childSkills:
          echo fmt"    - {child.name}"
      if s.name == "go-error-handling":
        hasGoErrorHandling = true
        check s.parentSkill.isSome
        check s.parentSkill.get == "golang"
    
    check hasGolang
    check hasGoErrorHandling

  test "Skill registry contains nested skills":
    let reg = getGlobalSkillRegistry()
    check reg.skills.len > 0
    
    if "golang" in reg.skills:
      let golang = reg.skills["golang"]
      echo fmt"golang: {golang.childSkills.len} children"
      check golang.childSkills.len == 8
    
    if "go-error-handling" in reg.skills:
      let goErr = reg.skills["go-error-handling"]
      check goErr.parentSkill.isSome
      check goErr.parentSkill.get == "golang"

  test "Load nested skill by path":
    let reg = getGlobalSkillRegistry()
    let pathSkill = findSkillByPath(reg, "golang/skills/go-error-handling")
    check pathSkill.isSome
    if pathSkill.isSome:
      check pathSkill.get.name == "go-error-handling"

  test "Show skill returns child skills":
    let reg = getGlobalSkillRegistry()
    if "golang" in reg.skills:
      let golang = reg.skills["golang"]
      let detail = formatSkillDetail(golang)
      check "Child Skills" in detail
