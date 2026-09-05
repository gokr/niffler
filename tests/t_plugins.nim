## plugins component tests — bus contract: package install lifecycle.
##
## Boots full core headless (NIF_AUTO_APPROVE=1) and installs a package
## from a LOCAL git repo (file:// support) — no network needed. Covers
## the whole pipeline: clone → manifest → builder.build → core.spawn →
## registration → tool callable; interactive-only packages build without
## spawning; duplicate-install rejection; plugin_remove teardown. Cleanup
## leaves no records behind.
##
## With NIF_TEST_NETWORK=1 the test additionally runs plugin_search
## against the real GitHub topic search.

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

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler") or
     not fileExists(repoRoot / "var" / "bin" / "cli"):
    fail("missing binaries — run `make build` first")
    quit(1)
  let sandbox = newCoreSandbox("plugins", ["store", "builder", "plugins"])
  let root = sandbox.root
  let coreBin = sandbox.sandboxBin("niffler")
  let cliBin = sandbox.sandboxBin("cli")
  defer: removeDir(root)

  # --- build a local package repo -----------------------------------------
  let pkgDir = tempRoot("pkg")
  let repoDir = pkgDir / "tplugrepo"
  createDir(repoDir / "tplug")
  writeFile(repoDir / "niffler.json", """{
    "name": "testpkg",
    "version": "1.0.0",
    "components": [
      {"name": "tplug", "lang": "nim", "main": "tplug/main.nim"}
    ]
  }
  """)
  writeFile(repoDir / "tplug" / "main.nim", """
    import niffler/sdk
    let comp = newComponent("tplug", "0.1.0")
    comp.tool:
      proc tplug_ping(): JsonNode =
        ## Ping the hermetic test package
        %*{"pong": true, "pkg": "testpkg"}
    comp.run()
    """.dedent())

  let conflictRepo = pkgDir / "conflictrepo"
  createDir(conflictRepo)
  writeFile(conflictRepo / "niffler.json", """{
    "name": "testconflict",
    "version": "1.0.0",
    "components": [
      {"name": "conflict", "lang": "nim", "main": "main.nim"}
    ]
  }
  """)
  writeFile(conflictRepo / "main.nim", """
    import niffler/sdk
    let comp = newComponent("conflict", "0.1.0")
    comp.tool:
      proc catalog(): JsonNode =
        ## Deliberately collide with core's catalog tool
        %*{"wrong": true}
    comp.run()
    """.dedent())
  commitRepo(conflictRepo)

  let interactiveRepo = pkgDir / "ituirepo"
  createDir(interactiveRepo / "itui")
  writeFile(interactiveRepo / "niffler.json", """{
    "name": "testinteractive",
    "version": "1.0.0",
    "components": [
      {"name": "itui", "lang": "go", "main": "itui/main.go",
       "sources": ["itui/version.go"], "interactive": true}
    ]
  }
  """)
  writeFile(interactiveRepo / "itui" / "main.go", """
    package main
    import sdk "niffler.dev/sdk"
    func main() {
      comp := sdk.New("itui", componentVersion())
      if err := comp.Run(); err != nil { panic(err) }
    }
    """.dedent())
  writeFile(interactiveRepo / "itui" / "version.go", """
    package main
    func componentVersion() string { return "0.1.0" }
    """.dedent())
  defer: removeDir(pkgDir)

  commitRepo(repoDir)
  commitRepo(interactiveRepo)

  # --- boot core ----------------------------------------------------------
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(coreBin, url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")])
  defer:
    if coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running():
        coreProc.kill()
        sleep(200)
    coreProc.close()

  # wait for core to serve
  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  # --- install from the local repo ----------------------------------------
  let inst = runCli(cliBin, url, @["install", "file://" & repoDir], 300_000,
                    root = root)
  check("cli install file:// ok", inst.code == 0 and
        inst.output.contains("INSTALL OK"), inst.output)
  check("install registers tplug",
        inst.output.contains("tplug registered"), inst.output)

  # tools registered when spawned — visible in catalog and callable
  let cat = runCli(cliBin, url, @["catalog"], root = root)
  check("catalog shows tplug_ping",
        cat.output.contains("tplug_ping"), cat.output)
  let ping = runCli(cliBin, url, @["call", "tplug_ping", "{}"], 30_000,
                    root = root)
  check("tplug_ping callable", ping.code == 0 and
        ping.output.contains("\"pong\":true"), ping.output)

  # A successful build/spawn is not a successful registration. This real
  # install broadcasts while CLI is running and must fail its verification.
  let conflict = runCli(cliBin, url, @["install", "file://" & conflictRepo],
                         300_000, root = root)
  check("cli install rejects a tool-name conflict", conflict.code != 0 and
        conflict.output.contains("INSTALL FAILED") and
        not conflict.output.contains("INSTALL OK"), conflict.output)
  let accepted = call(nc, "core", "catalog", %*{"op": "components"})
  check("conflicting plugin absent from core catalog",
        accepted{"components"} != nil and
        accepted{"components", "conflict"} == nil, $accepted)
  let conflictRemoval = runCli(cliBin, url,
    @["call", "plugin_remove", """{"package":"testconflict"}"""],
    60_000, root = root)
  check("conflicting plugin cleaned up", conflictRemoval.code == 0,
        conflictRemoval.output)

  # Keep an external same-name component accepted while installing a new
  # incompatible instance. Core permits spawn (it is not supervised), then
  # rejects its registration; the old name must not validate this install.
  let replacementRepo = pkgDir / "replacementrepo"
  createDir(replacementRepo)
  writeFile(replacementRepo / "niffler.json",
    readFile(conflictRepo / "niffler.json").replace("testconflict", "testreplacement")
      .replace("conflict", "replacement"))
  writeFile(replacementRepo / "main.nim",
    readFile(conflictRepo / "main.nim").replace("conflict", "replacement")
      .replace("catalog", "replacement_new"))
  commitRepo(replacementRepo)
  let externalBuild = call(nc, "builder", "build", %*{"lang": "nim",
    "name": "external-replacement", "source": """
    import niffler/sdk
    let comp = newComponent("replacement", "0.1.0")
    comp.tool:
      proc replacement_old(): JsonNode =
        ## Identify the external instance
        %*{"old": true}
    comp.run()
    """.dedent()}, 300_000)
  doAssert externalBuild{"ok"}.getBool(false), $externalBuild
  let external = startComponent(externalBuild{"binary"}.getStr(), url, root = root)
  defer: stopProcess(external)
  let ready = runCli(cliBin, url, @["wait", "replacement", "15"], root = root)
  doAssert ready.code == 0, ready.output
  let replacement = runCli(cliBin, url,
    @["install", "file://" & replacementRepo], 300_000, root = root)
  check("same-name rejected instance cannot produce INSTALL OK",
    replacement.code != 0 and replacement.output.contains("INSTALL FAILED") and
    not replacement.output.contains("INSTALL OK"), replacement.output)
  let snapshot = call(nc, "core", "catalog", %*{"op": "snapshot"})
  var oldOnly = false
  for entry in snapshot["components"]:
    if entry{"name"}.getStr() == "replacement":
      oldOnly = entry{"pids"} == %* [external.processID]
  check("old external instance remains the only accepted replacement", oldOnly, $snapshot)
  let cleanup = runCli(cliBin, url,
    @["call", "plugin_remove", """{"package":"testreplacement"}"""],
    60_000, root = root)
  check("same-name rejected plugin cleaned up", cleanup.code == 0, cleanup.output)

  let afterRemoval = call(nc, "core", "catalog", %*{"op": "snapshot"})
  var externalKept = false
  for entry in afterRemoval["components"]:
    if entry{"name"}.getStr() == "replacement":
      externalKept = entry{"pids"} == %* [external.processID]
  check("plugin removal preserves the unrelated external registration",
        external.running() and externalKept, $afterRemoval)
  let stillCallable = call(nc, "core", "invoke",
    %*{"tool": "replacement_old", "arguments": {}}, 3_000)
  check("external tool remains callable after plugin removal",
        stillCallable{"old"}.getBool(false), $stillCallable)

  # duplicate install is rejected
  let dup = runCli(cliBin, url, @["install", "file://" & repoDir], 60_000,
                   root = root)
  check("duplicate install rejected", dup.code != 0 and
        dup.output.contains("already installed"), dup.output)

  # plugin_installed lists the package
  let list = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000,
                    root = root)
  check("plugin_installed lists testpkg",
        list.output.contains("testpkg"), list.output)

  # An interactive-only package is installed by building its binary, but it
  # is not core.spawned and therefore never appears in the live catalog.
  let iinst = runCli(cliBin, url,
                     @["install", "file://" & interactiveRepo], 300_000,
                     root = root)
  check("interactive plugin install ok", iinst.code == 0 and
        iinst.output.contains("INSTALL OK"), iinst.output)
  check("interactive component built, not spawned",
        iinst.output.contains("itui built at") and
        iinst.output.contains("interactive; start manually") and
        fileExists(root / "var" / "bin" / "itui"), iinst.output)
  let icat = runCli(cliBin, url, @["catalog"], root = root)
  check("interactive component not registered",
        not icat.output.contains("itui:"), icat.output)
  let ilist = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000,
                     root = root)
  check("interactive install persisted",
        ilist.output.contains("testinteractive") and
        ilist.output.contains("\"interactive\":true"), ilist.output)

  # network-gated: real GitHub discovery
  if getEnv("NIF_TEST_NETWORK") == "1":
    let search = runCli(cliBin, url,
                        @["call", "plugin_search", """{"query":"weather"}"""],
                        60_000, root = root)
    check("plugin_search finds gokr/niffler-weather",
          search.output.contains("gokr/niffler-weather"), search.output)

    # Multi-word queries are ANDed by GitHub (name/description/topics), so a
    # zero-hit multi-word query must be retried with fewer words — gokr/
    # niffler-stocks has an empty description, only "stocks" in its name.
    let relaxed = runCli(cliBin, url,
                         @["call", "plugin_search",
                           """{"query":"stock price quote"}"""],
                         90_000, root = root)
    check("plugin_search falls back from zero-hit multi-word query",
          relaxed.output.contains("gokr/niffler-stocks"), relaxed.output)
    check("relaxed search reports attempts",
          relaxed.output.contains("attempts"), relaxed.output)

  # --- teardown: remove leaves no traces -----------------------------------
  let irem = runCli(cliBin, url,
                    @["call", "plugin_remove", """{"package":"testinteractive"}"""],
                    60_000, root = root)
  check("interactive plugin_remove ok", irem.code == 0 and
        irem.output.contains("\"ok\":true") and
        irem.output.contains("\"interactive\":true"), irem.output)
  let igone = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000,
                     root = root)
  check("interactive record gone after remove",
        not igone.output.contains("testinteractive"), igone.output)

  let rem = runCli(cliBin, url,
                   @["call", "plugin_remove", """{"package":"testpkg"}"""],
                   60_000, root = root)
  check("plugin_remove ok", rem.code == 0 and
        rem.output.contains("\"ok\":true"), rem.output)
  let gone = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000,
                    root = root)
  check("plugin_installed empty after remove",
        not gone.output.contains("testpkg"), gone.output)
  let tgone = runCli(cliBin, url, @["call", "tplug_ping", "{}"], 5_000,
                     root = root)
  check("tplug_ping no longer answers", tgone.code != 0, tgone.output)

  report("PLUGINS TEST")

main()
