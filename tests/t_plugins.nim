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

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let coreBin = root / "var" / "bin" / "niffler"
  let cliBin = root / "var" / "bin" / "cli"
  if not fileExists(coreBin) or not fileExists(cliBin):
    fail("missing binaries — run `make build` first")
    quit(1)

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

  let interactiveRepo = pkgDir / "ituirepo"
  createDir(interactiveRepo / "itui")
  writeFile(interactiveRepo / "niffler.json", """{
    "name": "testinteractive",
    "version": "1.0.0",
    "components": [
      {"name": "itui", "lang": "nim", "main": "itui/main.nim", "interactive": true}
    ]
  }
  """)
  writeFile(interactiveRepo / "itui" / "main.nim", """
    import niffler/sdk
    let comp = newComponent("itui", "0.1.0")
    comp.run()
    """.dedent())
  defer:
    removeDir(pkgDir)
    for name in ["tplug", "itui"]:
      let binary = root / "var" / "bin" / name
      if fileExists(binary): removeFile(binary)

  commitRepo(repoDir)
  commitRepo(interactiveRepo)

  # --- boot core ----------------------------------------------------------
  let (server, url) = startNats()
  var nc = waitConnect(url)
  let coreProc = startComponent(coreBin, url, extra = [("NIF_AUTO_APPROVE", "1")])
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
  let inst = runCli(cliBin, url, @["install", "file://" & repoDir], 300_000)
  check("cli install file:// ok", inst.code == 0 and
        inst.output.contains("INSTALL OK"), inst.output)
  check("install registers tplug",
        inst.output.contains("tplug registered"), inst.output)

  # tools registered when spawned — visible in catalog and callable
  let cat = runCli(cliBin, url, @["catalog"])
  check("catalog shows tplug_ping",
        cat.output.contains("tplug_ping"), cat.output)
  let ping = runCli(cliBin, url, @["call", "tplug_ping", "{}"], 30_000)
  check("tplug_ping callable", ping.code == 0 and
        ping.output.contains("\"pong\":true"), ping.output)

  # duplicate install is rejected
  let dup = runCli(cliBin, url, @["install", "file://" & repoDir], 60_000)
  check("duplicate install rejected", dup.code != 0 and
        dup.output.contains("already installed"), dup.output)

  # plugin_installed lists the package
  let list = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000)
  check("plugin_installed lists testpkg",
        list.output.contains("testpkg"), list.output)

  # An interactive-only package is installed by building its binary, but it
  # is not core.spawned and therefore never appears in the live catalog.
  let iinst = runCli(cliBin, url,
                     @["install", "file://" & interactiveRepo], 300_000)
  check("interactive plugin install ok", iinst.code == 0 and
        iinst.output.contains("INSTALL OK"), iinst.output)
  check("interactive component built, not spawned",
        iinst.output.contains("itui built at") and
        iinst.output.contains("interactive; start manually") and
        fileExists(root / "var" / "bin" / "itui"), iinst.output)
  let icat = runCli(cliBin, url, @["catalog"])
  check("interactive component not registered",
        not icat.output.contains("itui:"), icat.output)
  let ilist = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000)
  check("interactive install persisted",
        ilist.output.contains("testinteractive") and
        ilist.output.contains("\"interactive\":true"), ilist.output)

  # network-gated: real GitHub discovery
  if getEnv("NIF_TEST_NETWORK") == "1":
    let search = runCli(cliBin, url,
                        @["call", "plugin_search", """{"query":"weather"}"""], 60_000)
    check("plugin_search finds gokr/niffler-weather",
          search.output.contains("gokr/niffler-weather"), search.output)

  # --- teardown: remove leaves no traces -----------------------------------
  let irem = runCli(cliBin, url,
                    @["call", "plugin_remove", """{"package":"testinteractive"}"""],
                    60_000)
  check("interactive plugin_remove ok", irem.code == 0 and
        irem.output.contains("\"ok\":true") and
        irem.output.contains("\"interactive\":true"), irem.output)
  let igone = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000)
  check("interactive record gone after remove",
        not igone.output.contains("testinteractive"), igone.output)

  let rem = runCli(cliBin, url,
                   @["call", "plugin_remove", """{"package":"testpkg"}"""], 60_000)
  check("plugin_remove ok", rem.code == 0 and
        rem.output.contains("\"ok\":true"), rem.output)
  let gone = runCli(cliBin, url, @["call", "plugin_installed", "{}"], 30_000)
  check("plugin_installed empty after remove",
        not gone.output.contains("testpkg"), gone.output)
  let tgone = runCli(cliBin, url, @["call", "tplug_ping", "{}"], 5_000)
  check("tplug_ping no longer answers", tgone.code != 0, tgone.output)

  nc.close()
  server.terminate()
  server.close()
  report("PLUGINS TEST")

main()
