## plugins component tests — bus contract: package install lifecycle.
##
## Boots full core headless (NIF_AUTO_APPROVE=1) and installs a package
## from a LOCAL git repo (file:// support) — no network needed. Covers
## the whole pipeline: clone → manifest → builder.build → core.spawn →
## registration → tool callable; interactive-only packages build without
## spawning; duplicate-install rejection; plugin_remove teardown. A Go
## package whose go.mod replace assumes a sibling checkout gets an
## untracked go.work at install so a manual `make` in the clone builds;
## plugin_update on a branch-tracked package (no release tags) pulls in
## place and rebuilds only when HEAD moved. Cleanup leaves no records
## behind.
##
## With NIF_TEST_NETWORK=1 the test additionally runs plugin_search
## against the real GitHub topic search.

import std/[json, os, osproc, strutils]
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

  # The plugins component's slash surface (docs/WIRE.md): UI-facing commands
  # bound to its tools, namespaced by component name (/plugins-*) like the
  # MCP bridge's mcp-<server>-<prompt> — slash names are one global
  # namespace, so generic verbs would collide across packages.
  let slash = runCli(cliBin, url,
                     @["call", "get", """{"kind":"slash","id":"slash"}"""],
                     30_000, root = root)
  for slashName in ["plugins-search", "plugins-install", "plugins-update",
                    "plugins-remove"]:
    check("slash /" & slashName & " registered",
          slash.output.contains("\"name\":\"" & slashName & "\""),
          slash.output)
  check("slash /plugins registered and targets plugin_installed",
        slash.output.contains("\"name\":\"plugins\"") and
        slash.output.contains("plugin_installed"), slash.output)

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

  # --- branch-tracked Go package: manual make + update without releases ---
  # go.mod's replace assumes a sibling checkout (like gokr/niffler-tui),
  # so a bare `make` in the clone would fail. Install must write an
  # untracked go.work that redirects the SDK to the harness root; then
  # plugin_update (no release tags) pulls the branch in place and rebuilds.
  let upRepo = pkgDir / "uprepo"
  createDir(upRepo / "itup")
  writeFile(upRepo / "niffler.json", """{
    "name": "updatepkg",
    "version": "1.0.0",
    "components": [
      {"name": "itup", "lang": "go", "main": "itup/main.go",
       "sources": ["itup/version.go"], "interactive": true}
    ]
  }
  """)
  writeFile(upRepo / "go.mod", """
    module itup

    go 1.24

    require niffler.dev/sdk v0.0.0

    replace niffler.dev/sdk => ../niffler/sdk/go
    """.dedent())
  writeFile(upRepo / "Makefile",
    "BIN := bin/itup\n\nbuild:\n\tmkdir -p bin\n\tgo build -o $(BIN) ./itup\n")
  writeFile(upRepo / "itup" / "main.go", """
    package main
    import sdk "niffler.dev/sdk"
    func main() {
      comp := sdk.New("itup", componentVersion())
      if err := comp.Run(); err != nil { panic(err) }
    }
    """.dedent())
  writeFile(upRepo / "itup" / "version.go", """
    package main
    func componentVersion() string { return "1.0.0" }
    """.dedent())
  commitRepo(upRepo)

  let upInstall = runCli(cliBin, url,
                         @["install", "file://" & upRepo & "@main"], 300_000,
                         root = root)
  check("branch-pinned plugin install ok", upInstall.code == 0 and
        upInstall.output.contains("INSTALL OK"), upInstall.output)

  let upClone = root / "var" / "plugins" / "uprepo@main"
  let work = upClone / "go.work"
  check("go.work written for manual builds", fileExists(work), $upClone)
  let workContent = if fileExists(work): readFile(work) else: ""
  check("go.work redirects SDK to harness root",
        workContent.contains("replace niffler.dev/sdk => \"" &
                             root & "/sdk/go\""), workContent)

  let manualMake = execCmdEx("make", options = {poUsePath}, workingDir = upClone)
  check("manual make in plugin clone builds",
        manualMake.exitCode == 0 and fileExists(upClone / "bin" / "itup"),
        manualMake.output)

  # a second commit: plugin_update must pull it in place and rebuild
  writeFile(upRepo / "niffler.json", readFile(upRepo / "niffler.json")
            .replace("\"version\": \"1.0.0\"", "\"version\": \"2.0.0\""))
  writeFile(upRepo / "itup" / "version.go",
    "package main\nfunc componentVersion() string { return \"2.0.0\" }\n")
  let gc2 = startProcess("bash", args = ["-c",
      "cd " & quoteShell(upRepo) & " && git add -A && git commit -qm v2"],
      options = {poUsePath})
  discard gc2.waitForExit()
  gc2.close()

  let upUpdate = runCli(cliBin, url,
                        @["call", "plugin_update", """{"package":"updatepkg"}"""],
                        600_000, root = root)
  check("branch plugin_update pulls and rebuilds", upUpdate.code == 0 and
        upUpdate.output.contains("\"updated\":true"), upUpdate.output)
  let upList = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 60_000,
                      root = root)
  check("updated record carries the new version",
        upList.output.contains("\"version\":\"2.0.0\""), upList.output)
  let upNoop = runCli(cliBin, url,
                      @["call", "plugin_update", """{"package":"updatepkg"}"""],
                      600_000, root = root)
  check("second update is a no-op", upNoop.code == 0 and
        upNoop.output.contains("\"updated\":false"), upNoop.output)
  let upRem = runCli(cliBin, url,
                     @["call", "plugin_remove", """{"package":"updatepkg"}"""],
                     120_000, root = root)
  check("updatepkg removed", upRem.code == 0 and
        upRem.output.contains("\"ok\":true"), upRem.output)
  let upGone = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000,
                      root = root)
  check("updatepkg record gone",
        not upGone.output.contains("updatepkg"), upGone.output)

  # --- refless file:// package: update reads the branch from the clone ------
  # Installing without an explicit ref records no branch (the clone lands at
  # var/plugins/<slug>@head). plugin_update must detect the clone's own
  # checked-out branch and pull in place instead of refusing with "no
  # tracked branch ref" — this is exactly how local dev plugin repos are
  # installed (file:// + no ref).
  let hdRepo = pkgDir / "headrepo"
  createDir(hdRepo / "ithd")
  writeFile(hdRepo / "niffler.json", """{
    "name": "updatehead",
    "version": "1.0.0",
    "components": [
      {"name": "ithd", "lang": "go", "main": "ithd/main.go",
       "sources": ["ithd/version.go"], "interactive": true}
    ]
  }
  """)
  writeFile(hdRepo / "go.mod", """
    module ithd

    go 1.24

    require niffler.dev/sdk v0.0.0

    replace niffler.dev/sdk => ../niffler/sdk/go
    """.dedent())
  writeFile(hdRepo / "Makefile",
    "BIN := bin/ithd\n\nbuild:\n\tmkdir -p bin\n\tgo build -o $(BIN) ./ithd\n")
  writeFile(hdRepo / "ithd" / "main.go", """
    package main
    import sdk "niffler.dev/sdk"
    func main() {
      comp := sdk.New("ithd", componentVersion())
      if err := comp.Run(); err != nil { panic(err) }
    }
    """.dedent())
  writeFile(hdRepo / "ithd" / "version.go", """
    package main
    func componentVersion() string { return "1.0.0" }
    """.dedent())
  commitRepo(hdRepo)

  let hdInstall = runCli(cliBin, url, @["install", "file://" & hdRepo], 300_000,
                         root = root)
  check("refless file:// install ok", hdInstall.code == 0 and
        hdInstall.output.contains("INSTALL OK"), hdInstall.output)

  writeFile(hdRepo / "ithd" / "version.go",
    "package main\nfunc componentVersion() string { return \"2.0.0\" }\n")
  commitRepo(hdRepo)

  let hdUpdate = runCli(cliBin, url,
                        @["call", "plugin_update", """{"package":"updatehead"}"""],
                        600_000, root = root)
  check("refless plugin_update pulls and rebuilds", hdUpdate.code == 0 and
        hdUpdate.output.contains("\"updated\":true"), hdUpdate.output)
  let hdList = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 60_000,
                      root = root)
  check("refless update persists the detected branch",
        hdList.output.contains("updatehead") and
        hdList.output.contains("\"ref\":\"main\""), hdList.output)
  let hdNoop = runCli(cliBin, url,
                      @["call", "plugin_update", """{"package":"updatehead"}"""],
                      600_000, root = root)
  check("refless second update is a no-op", hdNoop.code == 0 and
        hdNoop.output.contains("\"updated\":false"), hdNoop.output)
  let hdRem = runCli(cliBin, url,
                     @["call", "plugin_remove", """{"package":"updatehead"}"""],
                     120_000, root = root)
  check("updatehead removed", hdRem.code == 0 and
        hdRem.output.contains("\"ok\":true"), hdRem.output)

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
