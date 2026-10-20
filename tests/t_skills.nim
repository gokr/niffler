## skills component tests — bus contract: discovery, load, install lifecycle.
##
## Boots the skills component alone against a private NATS server with a
## fake HOME (so global paths are hermetic) and a scratch NIF_ROOT holding
## fixture skill dirs. Covers: workspace/home/bundled discovery and ignored legacy
## sources with first-wins dedup; skill_load progressive disclosure;
## skill_resource reads; install from a LOCAL git repo (file:// support,
## no network) — single-skill repos install directly, multi-skill repos
## need a skill name, duplicates are rejected; skill_remove only touches
## Niffler-managed dirs; the baked (compiled-in) fallback serves discovery
## when no bundled tree is reachable. Cleanup leaves no files behind.

import std/[json, os, osproc, strutils, tables, times]
import natsnim
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
  writeSkill(fakeHome / ".agents" / "skills" / "homeskill",
             "homeskill", "Home fixture skill for testing",
             "# Home Skill\n\nDo the home thing.\n", tags = "test, home")
  writeSkill(root / "var" / "xdg-config" / "opencode" / "skills" /
             "configskill", "configskill", "Config fixture skill",
             "# Config Skill\n\nFrom XDG.\n")

  for legacy in [".claude", ".opencode"]:
    writeSkill(root / legacy / "skills" / "legacy-project",
      "legacy-project", "Foreign project skill", "Must not load.")
    writeSkill(fakeHome / legacy / "skills" / "legacy-home",
      "legacy-home", "Foreign home skill", "Must not load.")
  writeSkill(fakeHome / ".niffler" / "skills" / "legacy-agents",
    "legacy-agents", "Legacy Niffler skill", "Must not load implicitly.")
  let workspace = root / "workspace"
  writeSkill(workspace / ".agents" / "skills" / "projskill",
    "projskill", "Workspace-specific fixture", "WORKSPACE-ONLY-CONTENT")
  createDir(workspace / ".agents" / "skills" / "projskill" / "references")
  writeFile(workspace / ".agents" / "skills" / "projskill" / "references" / "notes.md",
    "workspace resource")
  writeSkill(fakeHome / ".agents" / "skills" / "niffler-harness",
    "niffler-harness", "User overrides bundled", "USER-WINS-OVER-BUNDLED")

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
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var compProc = startComponent(repoRoot / "var" / "bin" / "skills", url,
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
  check("legacy XDG skills are not scanned", "configskill" notin names, names.join(","))
  # Bundled skills (repo skills/ tree; compiled into the binary as a
  # last-resort source when no disk tree exists) must always surface and
  # load — whatever the deployment ships.
  check("bundled harness skill discovered", "niffler-harness" in names,
        names.join(","))
  check("foreign agent directories are not scanned",
    "legacy-project" notin names and "legacy-home" notin names and
    "legacy-agents" notin names, names.join(","))
  let userOverride = call(nc, "skills", "skill_load", %*{"name": "niffler-harness"})
  check("user skills shadow bundled skills",
    userOverride{"skill"}{"source"}.getStr() == "home" and
    userOverride{"content"}.getStr() == "USER-WINS-OVER-BUNDLED", $userOverride)
  let audit = call(nc, "skills", "skill_audit", %*{})
  check("audit exposes shadowed bundled skill", audit{"shadowedCount"}.getInt() >= 1, $audit)
  removeDir(fakeHome / ".agents" / "skills" / "niffler-harness")
  let bh = call(nc, "skills", "skill_load", %*{"name": "niffler-harness"})
  check("bundled harness skill loadable, docs map present",
        bh{"ok"}.getBool(false) and
        bh{"content"}.getStr("").contains("docs/MANUAL.md"), $bh)

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

  let ws = %*{"root": workspace, "roots": [workspace]}
  let wsLoad = call(nc, "skills", "skill_load", %*{"name": "projskill", "__workspace": ws})
  check("workspace context selects conversation skills, not harness skills",
    wsLoad{"content"}.getStr() == "WORKSPACE-ONLY-CONTENT", $wsLoad)
  let wsResource = call(nc, "skills", "skill_resource", %*{
    "name": "projskill", "path": "references/notes.md", "__workspace": ws})
  check("workspace context also applies to resources",
    wsResource{"content"}.getStr() == "workspace resource", $wsResource)
  let rootLoad = call(nc, "skills", "skill_load", %*{"name": "projskill"})
  check("workspace does not leak between calls",
    rootLoad{"content"}.getStr().contains("Do the project thing."), $rootLoad)

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
        fileExists(fakeHome / ".agents" / "skills" / "reposkill" / "SKILL.md"),
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
  check("project install lands in .agents/skills",
        proj{"ok"}.getBool(false) and
        fileExists(root / ".agents" / "skills" / "otherskill" / "SKILL.md"),
        $proj)

  let wsInstall = call(nc, "skills", "skill_install", %*{
    "repo": "file://" & repoDir, "skill": "otherskill", "global": false,
    "__workspace": ws})
  check("project install uses the conversation workspace",
    wsInstall{"ok"}.getBool(false) and
    fileExists(workspace / ".agents" / "skills" / "otherskill" / "SKILL.md"), $wsInstall)
  let wsRemove = call(nc, "skills", "skill_remove", %*{
    "name": "otherskill", "__workspace": ws})
  check("project removal uses the same conversation workspace",
    wsRemove{"ok"}.getBool(false) and
    not dirExists(workspace / ".agents" / "skills" / "otherskill") and
    dirExists(root / ".agents" / "skills" / "otherskill"), $wsRemove)

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
  let wrong = call(nc, "skills", "skill_remove", %*{"name": "niffler-tools"})
  check("remove refuses bundled dir",
        not wrong{"ok"}.getBool(false) and
        wrong{"error"}.getStr().contains("not Niffler-managed"), $wrong)

  let rem = call(nc, "skills", "skill_remove", %*{"name": "reposkill"})
  check("skill_remove ok", rem{"ok"}.getBool(false) and
        not dirExists(fakeHome / ".agents" / "skills" / "reposkill"), $rem)
  let lr = call(nc, "skills", "skill_list", %*{})
  var afterRemove = newSeq[string]()
  for item in lr{"skills"}:
    afterRemove.add(item{"name"}.getStr(""))
  check("removed skill gone", "reposkill" notin afterRemove,
        afterRemove.join(","))
  let rem2 = call(nc, "skills", "skill_remove", %*{"name": "otherskill"})
  check("project-installed skill removable",
        rem2{"ok"}.getBool(false), $rem2)

  # --- baked fallback: a binary with no reachable bundled tree -------------
  # A deployment that ships var/bin without the repo checkout has no
  # <repo>/skills tree, and NIF_ROOT/skills may be missing too. Discovery
  # must still serve the SKILL.md copies compiled into the binary (source
  # "bundled", dir "(baked)") so the self-knowledge set survives. Point the
  # compile-time bundled-tree fixture at a missing path to exercise fallback.
  stopProcess(compProc)
  compProc = nil
  var regSub: ptr natsSubscription
  let subSt = natsConnection_SubscribeSync(addr regSub, nc.conn,
                                           "reg.publish".cstring)
  check("subscribe reg.publish for the baked phase", checkStatus(subSt))
  discard natsConnection_Flush(nc.conn)
  let bakedProc = startComponent(repoRoot / "var" / "bin" / "fixture-skills-baked", url,
                                 root = root,
                                 extra = [("HOME", fakeHome)])
  defer: stopProcess(bakedProc)
  check("baked phase component registers",
        waitRegisteredOn(regSub, "skills"))
  natsSubscription_Destroy(regSub)

  let bl = call(nc, "skills", "skill_list", %*{"source": "bundled"})
  var bakedNames = newSeq[string]()
  var bakedShape = bl{"skills"}.len >= 4
  for item in bl{"skills"}:
    bakedNames.add(item{"name"}.getStr(""))
    if item{"dir"}.getStr("") != "(baked)" or
       item{"source"}.getStr("") != "bundled":
      bakedShape = false
  check("baked: bundled skills discovered as source bundled, dir (baked)",
        bakedShape and "niffler-harness" in bakedNames and
        "niffler-tools" in bakedNames and "niffler-fabric" in bakedNames and
        "todo-markdown" in bakedNames, $bl)

  let bload = call(nc, "skills", "skill_load", %*{"name": "niffler-harness"})
  check("baked: skill_load serves the compiled-in content (docs map)",
        bload{"ok"}.getBool(false) and
        bload{"content"}.getStr("").contains("docs/MANUAL.md") and
        bload{"skill"}{"dir"}.getStr("") == "(baked)" and
        bload{"resourceCount"}.getInt(-1) == 0, $bload)

  let bfixtures = call(nc, "skills", "skill_list", %*{})
  var fixtureNames = newSeq[string]()
  for item in bfixtures{"skills"}:
    fixtureNames.add(item{"name"}.getStr(""))
  check("baked: workspace/user discovery works; legacy XDG stays ignored",
        "projskill" in fixtureNames and "homeskill" in fixtureNames and
        "configskill" notin fixtureNames, fixtureNames.join(","))

  let ba = call(nc, "skills", "skill_audit", %*{})
  var bakedRows = 0
  var diskRows = 0
  var invalidRows = 0
  for e in ba{"skills"}:
    if e{"dir"}.getStr("") == "(baked)":
      inc bakedRows
    else:
      inc diskRows
      if e{"status"}.getStr("") == "invalid": inc invalidRows
  check("baked: skill_audit reports baked-only rows beside the disk copies",
        bakedRows >= 4 and diskRows >= 2 and invalidRows == 0 and
        ba{"shadowedCount"}.getInt(-1) == 0, $ba)

  let brem = call(nc, "skills", "skill_remove", %*{"name": "niffler-harness"})
  check("baked: compiled-in skills are not removable",
        not brem{"ok"}.getBool(false) and
        brem{"error"}.getStr("").contains("not Niffler-managed"), $brem)

  # --- slash surface (docs/WIRE.md, declarative UI surface) ---------------
  # The component's UI-facing commands, namespaced by component name
  # (/skills*) like /plugins* and the MCP bridge's mcp-<server>-<prompt>: the
  # slash namespace is global and duplicates are dropped, so a generic
  # /install would lose to whichever package registered first. This test boots
  # no core and no store, so the check reads the component's own reg.publish
  # (the shape a catalog ingests: name, description, tool, params) — declared
  # but rejected registrations are the reason both halves matter.
  stopProcess(bakedProc)
  var slashSub: ptr natsSubscription
  let slashSt = natsConnection_SubscribeSync(addr slashSub, nc.conn,
                                             "reg.publish".cstring)
  check("subscribe reg.publish for the slash phase", checkStatus(slashSt))
  discard natsConnection_Flush(nc.conn)
  let slashProc = startComponent(repoRoot / "var" / "bin" / "skills", url,
                                 root = root,
                                 extra = [("HOME", fakeHome)])
  defer: stopProcess(slashProc)
  var slashDoc = newJObject()
  let slashDeadline = epochTime() + 15.0
  while epochTime() < slashDeadline and slashDoc.len == 0:
    var msg: ptr natsMsg
    if natsSubscription_NextMsg(addr msg, slashSub, 200) == NATS_OK:
      let payload = parseJson($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if payload{"name"}.getStr("") == "skills" and payload.hasKey("slash"):
        slashDoc = payload
  natsSubscription_Destroy(slashSub)
  check("skills announces its slash surface on reg.publish", slashDoc.len > 0,
        $slashDoc)
  var byName = initTable[string, JsonNode]()
  # {} on a missing key is nil and iterating nil crashes (json.nim items), so
  # absent slash/params arrays are handled as empty lists, never iterated.
  if slashDoc{"slash"} != nil and slashDoc{"slash"}.kind == JArray:
    for c in slashDoc{"slash"}:
      byName[c{"name"}.getStr("")] = c
  check("slash /skills declared and targets skill_list",
        byName.hasKey("skills") and
        byName["skills"]{"tool"}.getStr("") == "skill_list", $slashDoc)
  check("slash /skills-install declared and targets skill_install",
        byName.hasKey("skills-install") and
        byName["skills-install"]{"tool"}.getStr("") == "skill_install",
        $slashDoc)
  check("slash /skills-remove declared and targets skill_remove",
        byName.hasKey("skills-remove") and
        byName["skills-remove"]{"tool"}.getStr("") == "skill_remove", $slashDoc)
  # The declared command-line surface a UI renders: /skills takes skill_list's
  # filters, /skills-install the install switches — global as a bool, so a UI
  # draws a toggle rather than a text field.
  var skillParams = newSeq[string]()
  if byName.hasKey("skills") and byName["skills"]{"params"} != nil:
    for p in byName["skills"]{"params"}:
      skillParams.add(p{"name"}.getStr("") & ":" & p{"kind"}.getStr(""))
  check("/skills carries query and source params",
        skillParams == @["query:string", "source:enum"], skillParams.join(","))
  var installParams = newSeq[string]()
  if byName.hasKey("skills-install") and byName["skills-install"]{"params"} != nil:
    for p in byName["skills-install"]{"params"}:
      installParams.add(p{"name"}.getStr("") & ":" & p{"kind"}.getStr(""))
  check("/skills-install carries repo, skill, global",
        installParams == @["repo:string", "skill:string", "global:bool"],
        installParams.join(","))
  # Every declared target must be a tool this component really registers, or a
  # catalog drops the command silently. Pair each with the reg.publish tool
  # list so a rename on one side cannot pass unnoticed here.
  var toolNames = newSeq[string]()
  if slashDoc{"tools"} != nil and slashDoc{"tools"}.kind == JArray:
    for t in slashDoc{"tools"}:
      toolNames.add(t{"name"}.getStr(""))
  for cmdName in ["skills", "skills-install", "skills-remove"]:
    check("slash /" & cmdName & " targets a registered tool",
          byName.hasKey(cmdName) and
          byName[cmdName]{"tool"}.getStr("") in toolNames, toolNames.join(","))

  # The declared command must be invocable the way a UI drives it: build the
  # target's arguments from the command line and call it. /skills runs the
  # real discovery path, so a declaration that drifted from its tool's
  # signature fails here rather than in a UI.
  let target =
    if byName.hasKey("skills"): byName["skills"]{"tool"}.getStr("skill_list")
    else: "skill_list"
  let invoked = call(nc, "skills", target,
                     %*{"query": "projskill", "source": ""})
  var invokedNames = newSeq[string]()
  if invoked{"skills"} != nil and invoked{"skills"}.kind == JArray:
    for item in invoked{"skills"}:
      invokedNames.add(item{"name"}.getStr(""))
  check("/skills' target tool answers with the declared filters",
        invoked{"ok"}.getBool(false) and "projskill" in invokedNames,
        $invoked)

  report("SKILLS TEST")

main()
