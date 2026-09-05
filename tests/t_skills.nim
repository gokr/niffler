## skills component tests — bus contract: discovery, load, install lifecycle.
##
## Boots the skills component alone against a private NATS server with a
## fake HOME (so global paths are hermetic) and a scratch NIF_ROOT holding
## fixture skill dirs. Covers: discovery across project/home/config
## sources with first-wins dedup; skill_load progressive disclosure;
## skill_resource reads; install from a LOCAL git repo (file:// support,
## no network) — single-skill repos install directly, multi-skill repos
## need a skill name, duplicates are rejected; skill_remove only touches
## Niffler-managed dirs. Cleanup leaves no files behind.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc commitRepo(repoDir: string) =
  let g = startProcess("git", args = ["-C", repoDir, "init", "-q", "-b", "main"],
                       options = {poUsePath})
  discard g.waitForExit()
  g.close()
  let gc = startProcess("bash", args = ["-c",
      "cd " & repoDir & " && git config user.email t@t && git config user.name t && " &
      "git add -A && git commit -qm init"], options = {poUsePath})
  discard gc.waitForExit()
  gc.close()

proc writeSkill(dir, name, desc, body: string, tags = "test") =
  createDir(dir)
  writeFile(dir / "SKILL.md",
    "---\n" &
    "name: " & name & "\n" &
    "description: " & desc & "\n" &
    "version: 1.0.0\n" &
    "license: MIT\n" &
    "tags: [" & tags & "]\n" &
    "---\n\n" & body)

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "skills"):
    fail("missing binary — run `make build` first")
    quit(1)

  # --- hermetic fixture world: scratch NIF_ROOT + fake HOME ----------------
  let root = tempRoot("skills")
  let fakeHome = tempRoot("skills-home")
  defer:
    removeDir(root)
    removeDir(fakeHome)
  writeSkill(root / ".agents" / "skills" / "projskill",
             "projskill", "Project fixture skill for testing",
             "# Project Skill\n\nDo the project thing.\n")
  createDir(root / ".agents" / "skills" / "projskill" / "references")
  writeFile(root / ".agents" / "skills" / "projskill" / "references" /
            "notes.md", "proj notes")
  writeSkill(fakeHome / ".niffler" / "skills" / "homeskill",
             "homeskill", "Home fixture skill for testing",
             "# Home Skill\n\nDo the home thing.\n", tags = "test, home")
  writeSkill(root / "var" / "xdg-config" / "opencode" / "skills" /
             "configskill", "configskill", "Config fixture skill",
             "# Config Skill\n\nFrom XDG.\n")

  # a local git repo with two skills for install
  let pkgDir = tempRoot("skpkg")
  let repoDir = pkgDir / "reposkills"
  defer: removeDir(pkgDir)
  writeSkill(repoDir / "reposkill", "reposkill", "Skill from a repo",
             "# Repo Skill\n\nDo the repo thing.\n")
  writeSkill(repoDir / "otherskill", "otherskill", "Second repo skill",
             "# Other Skill\n\nDo the other thing.\n")
  commitRepo(repoDir)

  # --- boot bus + component ------------------------------------------------
  let (server, url) = startNats(routed = true)
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let compProc = startComponent(repoRoot / "var" / "bin" / "skills", url,
                                root = root, extra = [("HOME", fakeHome)])
  defer: stopProcess(compProc)
  check("skills registers", waitRegistered(nc, "skills"))

  # --- discovery -----------------------------------------------------------
  let l = call(nc, "skills", "skill_list", %*{})
  check("skill_list returns ok", l{"ok"}.getBool(false), $l)
  var names = newSeq[string]()
  for item in l{"skills"}:
    names.add(item{"name"}.getStr(""))
  check("list finds project skill", "projskill" in names, names.join(","))
  check("list finds home skill", "homeskill" in names, names.join(","))
  check("list finds config skill", "configskill" in names, names.join(","))

  let lsrc = call(nc, "skills", "skill_list", %*{"source": "home"})
  var homeNames = newSeq[string]()
  for item in lsrc{"skills"}:
    homeNames.add(item{"name"}.getStr(""))
  check("source filter home", "homeskill" in homeNames and
        "projskill" notin homeNames, homeNames.join(","))

  let lq = call(nc, "skills", "skill_list", %*{"query": "project"})
  var qNames = newSeq[string]()
  for item in lq{"skills"}:
    qNames.add(item{"name"}.getStr(""))
  # Bundled repo skills (shipped in <repo>/skills) may legitimately match
  # too, so assert on the fixture skills: projskill's description contains
  # "project"; homeskill's and configskill's must not match the query.
  check("query filter matches name+desc",
        "projskill" in qNames and "homeskill" notin qNames and
        "configskill" notin qNames, qNames.join(","))

  # first-wins: a home skill shadowed by the same name in the project
  writeSkill(root / ".agents" / "skills" / "homeskill",
             "homeskill", "Shadowing project skill",
             "# Shadow\n\nProject wins.\n")
  let l2 = call(nc, "skills", "skill_list", %*{"query": "homeskill"})
  var first = ""
  for item in l2{"skills"}:
    first = item{"name"}.getStr("")
  let shadow = call(nc, "skills", "skill_load", %*{"name": "homeskill"})
  check("project skill shadows home one",
        shadow{"skill"}{"source"}.getStr("") == "project" and
        shadow{"skill"}{"dir"}.getStr("").contains(root),
        $shadow)
  removeDir(root / ".agents" / "skills" / "homeskill")

  # --- loading / resources -------------------------------------------------
  let ld = call(nc, "skills", "skill_load", %*{"name": "projskill"})
  check("skill_load returns content", ld{"ok"}.getBool(false) and
        ld{"content"}.getStr("").contains("Do the project thing.") and
        ld{"skill"}{"version"}.getStr("") == "1.0.0", $ld)
  check("skill_load lists resources",
        ld{"resourceCount"}.getInt(0) == 1 and
        ld{"resources"}[0]{"path"}.getStr("") == "references/notes.md", $ld)
  let missing = call(nc, "skills", "skill_load", %*{"name": "nope"})
  check("skill_load unknown skill errors",
        not missing{"ok"}.getBool(false) and
        missing{"error"}.getStr("").contains("not found"), $missing)

  let rr = call(nc, "skills", "skill_resource",
                %*{"name": "projskill", "path": "references/notes.md"})
  check("skill_resource reads file",
        rr{"ok"}.getBool(false) and
        rr{"content"}.getStr("") == "proj notes", $rr)
  let rb = call(nc, "skills", "skill_resource",
                %*{"name": "projskill", "path": "../../etc/passwd"})
  check("skill_resource refuses traversal",
        not rb{"ok"}.getBool(false), $rb)

  # --- install from a local git repo ----------------------------------------
  let many = call(nc, "skills", "skill_install",
                  %*{"repo": "file://" & repoDir})
  check("multi-skill repo lists candidates",
        not many{"ok"}.getBool(false) and
        many{"error"}.getStr().contains("2 skills") and
        many{"skills"}.len == 2, $many)

  let inst = call(nc, "skills", "skill_install",
                  %*{"repo": "file://" & repoDir, "skill": "reposkill"})
  check("skill_install ok", inst{"ok"}.getBool(false) and
        inst{"skill"}.getStr("") == "reposkill" and
        inst{"source"}.getStr("") == "home" and
        fileExists(fakeHome / ".niffler" / "skills" / "reposkill" / "SKILL.md"),
        $inst)

  let la = call(nc, "skills", "skill_list", %*{})
  var afterNames = newSeq[string]()
  for item in la{"skills"}:
    afterNames.add(item{"name"}.getStr(""))
  check("installed skill discovered", "reposkill" in afterNames,
        afterNames.join(","))
  let la2 = call(nc, "skills", "skill_load", %*{"name": "reposkill"})
  check("installed skill loadable",
        la2{"content"}.getStr("").contains("Do the repo thing."), $la2)

  let dup = call(nc, "skills", "skill_install",
                 %*{"repo": "file://" & repoDir, "skill": "reposkill"})
  check("duplicate install rejected",
        not dup{"ok"}.getBool(false) and
        dup{"error"}.getStr().contains("already installed"), $dup)

  let proj = call(nc, "skills", "skill_install",
                  %*{"repo": "file://" & repoDir, "skill": "otherskill",
                     "global": false})
  check("project install lands in .opencode/skills",
        proj{"ok"}.getBool(false) and
        fileExists(root / ".opencode" / "skills" / "otherskill" / "SKILL.md"),
        $proj)

  # --- online search (network-gated: real skills.sh registry) ---------------
  let sq = call(nc, "skills", "skill_search", %*{"query": "x"})
  check("skill_search rejects short query",
        not sq{"ok"}.getBool(false), $sq)
  if getEnv("NIF_TEST_NETWORK") == "1":
    let s = call(nc, "skills", "skill_search", %*{"query": "typescript"},
                 30_000)
    check("skill_search hits skills.sh",
          s{"ok"}.getBool(false) and s{"count"}.getInt(0) > 0 and
          s{"skills"}[0]{"name"}.getStr("").len > 0 and
          s{"skills"}[0]{"source"}.getStr("").contains("/"), $s)
    let so = call(nc, "skills", "skill_search",
                  %*{"query": "svelte", "owner": "vercel-labs"}, 30_000)
    check("skill_search owner filter",
          so{"ok"}.getBool(false) and
          so{"skills"}[0]{"source"}.getStr("").startsWith("vercel-labs/"),
          $so)

  # --- removal (managed dirs only) -----------------------------------------
  let wrong = call(nc, "skills", "skill_remove", %*{"name": "projskill"})
  check("remove refuses shared/project fixture dir",
        not wrong{"ok"}.getBool(false) and
        wrong{"error"}.getStr().contains("not Niffler-managed"), $wrong)

  let rem = call(nc, "skills", "skill_remove", %*{"name": "reposkill"})
  check("skill_remove ok", rem{"ok"}.getBool(false) and
        not dirExists(fakeHome / ".niffler" / "skills" / "reposkill"), $rem)
  let lr = call(nc, "skills", "skill_list", %*{})
  var afterRemove = newSeq[string]()
  for item in lr{"skills"}:
    afterRemove.add(item{"name"}.getStr(""))
  check("removed skill gone", "reposkill" notin afterRemove,
        afterRemove.join(","))
  let rem2 = call(nc, "skills", "skill_remove", %*{"name": "otherskill"})
  check("project-installed skill removable",
        rem2{"ok"}.getBool(false), $rem2)

  report("SKILLS TEST")

main()
