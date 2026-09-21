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
import ../components/plugins/versions

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
  # --- pure: version-tag selection (release-less repos) -----------------
  # resolveTag falls back to /tags when a repo publishes no GitHub
  # releases; this helper picks the pin from that list. Hermetic — no bus.
  check("latest tag: highest version wins",
        latestVersionTag(@["v0.2.0", "v0.3.0", "v0.1.9"]) == "v0.3.0")
  check("latest tag: non-version tags ignored",
        latestVersionTag(@["nightly", "release-2024", "v1.0.1"]) == "v1.0.1")
  check("latest tag: zero-extended comparison",
        latestVersionTag(@["v1.0", "v1.0.1", "v1.0.0"]) == "v1.0.1")
  check("latest tag: plain tag beats pre-release",
        latestVersionTag(@["v2.0.0-rc1", "v2.0.0"]) == "v2.0.0")
  check("latest tag: pre-release alone is still usable",
        latestVersionTag(@["v2.0.0-rc1"]) == "v2.0.0-rc1")
  check("latest tag: no version-looking tags → empty",
        latestVersionTag(@["nightly", "latest"]) == "" and
        latestVersionTag(@[]) == "")

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

  # A v2 package gives builder the complete project and its own argv recipes.
  # No language-specific dependency logic lives in plugins: both projects use
  # the same build_package seam and keep their source manifests untouched.
  let recipeRepo = pkgDir / "reciperepo"
  createDir(recipeRepo / "nimcomp")
  createDir(recipeRepo / "gocomp")
  writeFile(recipeRepo / "niffler.json", """
  {
    "manifestVersion": 2,
    "name": "testrecipes",
    "version": "1.0.0",
    "components": [
      {"name": "nimcomp", "lang": "nim", "project": "nimcomp",
       "build": {
         "steps": [["printf", "recipe preflight\\n"],
                   ["nim", "c", "--hints:off", "-d:release",
                    "--path:${NIF_SDK_ROOT}", "-o:${NIF_OUTPUT}", "main.nim"]],
         "artifact": {"path": "nimcomp-bin", "runner": "executable"}
       }},
      {"name": "gocomp", "lang": "go", "project": "gocomp",
       "build": {
         "steps": [["go", "build", "-o", "${NIF_OUTPUT}", "."]],
         "artifact": {"path": "gocomp-bin", "runner": "executable"}
       }}
    ]
  }
  """)
  writeFile(recipeRepo / "nimcomp" / "main.nim", """
    import niffler/sdk
    let comp = newComponent("nimcomp", "0.1.0")
    comp.tool:
      proc recipe_nim_ping(): JsonNode =
        ## Ping the v2 Nim recipe component
        %*{"pong": true, "lang": "nim"}
    comp.run()
    """.dedent())
  writeFile(recipeRepo / "gocomp" / "go.mod", """
    module gocomp

    go 1.24

    require niffler.dev/sdk v0.0.0
  """.dedent())
  writeFile(recipeRepo / "gocomp" / "main.go", """
    package main
    import (
      "encoding/json"
      sdk "niffler.dev/sdk"
    )
    func main() {
      comp := sdk.New("gocomp", "0.1.0")
      comp.Tool("recipe_go_ping", map[string]any{
        "type": "object", "description": "Ping the v2 Go recipe component",
        "properties": map[string]any{},
      }, func(_ *sdk.Component, _ json.RawMessage) (any, error) {
        return map[string]any{"pong": true, "lang": "go"}, nil
      })
      _ = comp.Run()
    }
  """.dedent())
  commitRepo(recipeRepo)

  # TS packages carry their real npm project and dependency declaration.
  # The builder receives the clone and recipe; it does not infer packages from
  # source imports.
  let tsRepo = pkgDir / "tsdepsrepo"
  createDir(tsRepo / "tsdep")
  writeFile(tsRepo / "niffler.json", """{
    "manifestVersion": 2,
    "name": "testtsdeps",
    "version": "1.0.0",
    "components": [
      {"name": "tsdep", "lang": "ts", "project": ".",
       "build": {
         "steps": [["npm", "install", "--no-audit", "--no-fund"],
                   ["npm", "run", "build"]],
         "artifact": {"path": "dist/main.js", "runner": "node"}
       }}
    ]
  }
  """)
  writeFile(tsRepo / "package.json", """
  {
    "name": "testtsdeps",
    "private": true,
    "version": "1.0.0",
    "scripts": {"build": "tsc"},
    "dependencies": {
      "niffler-sdk": "file:../sdk/ts",
      "nats": "^2.29.0",
      "left-pad": "^1.3.0"
    },
    "devDependencies": {
      "@types/node": "^22.0.0",
      "typescript": "^5.5.0"
    }
  }
  """)
  writeFile(tsRepo / "tsconfig.json", """
  {
    "compilerOptions": {
      "target": "ES2022", "module": "commonjs",
      "moduleResolution": "node", "outDir": "dist",
      "strict": true, "esModuleInterop": true, "skipLibCheck": true
    },
    "include": ["tsdep/main.ts"]
  }
  """)
  writeFile(tsRepo / "tsdep" / "main.ts", """
    import sdk from "niffler-sdk";
    const pad = require("left-pad") as (s: string, n: number) => string;
    const comp = sdk.newComponent("tsdep", "0.1.0");
    comp.tool("tsdep_pad", {
      type: "object",
      description: "Pads a string using the package's declared left-pad dependency",
      properties: { s: { type: "string" }, n: { type: "number" } },
      required: ["s", "n"],
    }, async (_c: unknown, args: any) =>
      ({ padded: pad(String(args?.s ?? ""), Number(args?.n ?? 0)) }));
    comp.run();
    """.dedent())
  commitRepo(tsRepo)

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
  # Records store no commit field; the listing derives provenance from the
  # clone at read time, so it must report the fixture's own HEAD.
  let (headRaw, _) = execCmdEx("git -C " & repoDir & " rev-parse HEAD")
  let head = headRaw.strip()
  check("plugin_installed reports checkout commit",
        head.len == 40 and
        list.output.contains("\"commit\":\"" & head & "\""), list.output)

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

  let rinst = runCli(cliBin, url, @["install", "file://" & recipeRepo],
                     600_000, root = root)
  check("manifest-v2 recipe package install ok",
        rinst.code == 0 and rinst.output.contains("INSTALL OK"), rinst.output)
  let rnim = runCli(cliBin, url,
                    @["call", "recipe_nim_ping", "{}"], 30_000, root = root)
  check("manifest-v2 Nim component callable",
        rnim.code == 0 and rnim.output.contains("\"lang\":\"nim\""), rnim.output)
  let rgo = runCli(cliBin, url,
                   @["call", "recipe_go_ping", "{}"], 30_000, root = root)
  check("manifest-v2 Go component callable",
        rgo.code == 0 and rgo.output.contains("\"lang\":\"go\""), rgo.output)
  let rremove = runCli(cliBin, url,
                       @["call", "plugin_remove", "{\"package\":\"testrecipes\"}"],
                       120_000, root = root)
  check("manifest-v2 recipe package removable",
        rremove.code == 0 and rremove.output.contains("\"ok\":true"),
        rremove.output)

  # TS packages carry their real npm project and dependency declaration.
  # the manifest reader never sees a dependency field.
  if getEnv("NIF_TEST_NETWORK") == "1":
    let tinst = runCli(cliBin, url, @["install", "file://" & tsRepo], 600_000,
                       root = root)
    check("ts plugin package install ok", tinst.code == 0 and
          tinst.output.contains("INSTALL OK"), tinst.output)
    let tcall = runCli(cliBin, url,
                       @["call", "tsdep_pad", """{"s":"ab","n":5}"""],
                       30_000, root = root)
    check("ts plugin resolves its own import",
          tcall.code == 0 and tcall.output.contains("\"padded\":\"   ab\""),
          tcall.output)
  else:
    echo "NOTE: set NIF_TEST_NETWORK=1 to run the TypeScript plugin package install test"

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
