## builder component tests — bus contract: compiling components from source.
##
## Covers: Nim build, Go build, failure reporting, and a build that is
## actually spawnable (the full self-extension path). Uses a temp
## NIF_ROOT so scratch sources and binaries never pollute the real
## var/build and var/bin.

import std/[json, os, osproc, strutils]
import natsnim
import helpers

proc main() =
  when defined(macosx):
    # A desktop-launched harness does not inherit Makefile-only settings.
    # Exercise SDK and library discovery through the real runtime builder.
    delEnv("SDKROOT")
    delEnv("LIBRARY_PATH")

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "builder"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let tmp = tempRoot("builder with spaces")
  defer: removeDir(tmp)
  # the builder compiles with --path:<root>/sdk and picks up config.nims
  # from its cwd (pkgs2 resolution) — mirror those from the real root
  createSymlink(root / "sdk", tmp / "sdk")
  writeFile(tmp / "config.nims", readFile(root / "config.nims") &
    "\nswitch(\"nimcache\", thisDir() / \"var\" / \"nimcache\")\n")
  copyFile(root / "niffler.nimble", tmp / "niffler.nimble")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let builderProc = startComponent(bin, url, root = tmp)
  defer:
    if builderProc.running():
      builderProc.terminate()
      sleep(200)
    builderProc.close()

  check("builder registers", waitRegistered(nc, "builder"))

  let info = call(nc, "builder", "info", %*{})
  let example = call(nc, "builder", "build",
    %*{"lang": "go", "name": "documented-example", "source": info{"go"}}, 300_000)
  check("builder's advertised Go example compiles in a root with spaces",
    example{"ok"}.getBool(false), $example)

  const nimSrc = """
    import niffler/sdk
    let comp = newComponent("tcomp", "0.1.0")
    comp.tool:
      proc tping(echoIt: bool = false): JsonNode =
        ## Ping the test component
        %*{"pong": true}
    comp.run()
    """.dedent()

  # Nim build produces a runnable binary
  let r1 = call(nc, "builder", "build",
                %*{"lang": "nim", "name": "tcomp", "source": nimSrc}, 300_000)
  check("builder nim build ok", r1{"ok"}.getBool(false), $r1)
  let tcompBin = tmp / "var" / "bin" / "tcomp"
  check("builder nim binary exists", fileExists(tcompBin), $r1)

  let hyphenated = call(nc, "builder", "build",
                        %*{"lang": "nim", "name": "hyphen-comp",
                           "source": nimSrc}, 300_000)
  check("builder supports hyphenated Nim component names",
        hyphenated{"ok"}.getBool(false) and
        fileExists(tmp / "var" / "bin" / "hyphen-comp"), $hyphenated)

  let invalidName = call(nc, "builder", "build",
                         %*{"lang": "nim", "name": "../escape",
                            "source": nimSrc})
  check("builder rejects unsafe component names",
        not invalidName{"ok"}.getBool(false), $invalidName)

  # compile errors come back as ok:false with a useful tail
  let r2 = call(nc, "builder", "build",
                %*{"lang": "nim", "name": "broken",
                   "source": "import niffler/sdk\nthis is not nim\n"}, 300_000)
  check("builder reports compile errors", not r2{"ok"}.getBool(false) and
        r2{"error"}.getStr("").len > 0, $r2)

  # Go build produces a runnable binary (mirrors the Go SDK)
  const goSrc = """
    package main

  import (
      "encoding/json"
      "fmt"
      niffler "niffler.dev/sdk"
  )

  func main() {
      c := niffler.New("tcompgo", componentVersion())
      c.Tool("tpinggo", map[string]any{
          "type":        "object",
          "description": "Ping the Go test component",
          "properties":  map[string]any{"echoIt": map[string]any{"type": "boolean"}},
      }, func(c *niffler.Component, args json.RawMessage) (any, error) {
          return map[string]any{"pong": true}, nil
      })
      if err := c.Run(); err != nil {
          fmt.Println(err)
      }
  }
  """.dedent()
  let r3 = call(nc, "builder", "build", %*{
    "lang": "go", "name": "tcompgo", "source": goSrc,
    "files": {"version.go": "package main\nfunc componentVersion() string { return \"0.1.0\" }\n"}
  }, 300_000)
  check("builder multi-file go build ok", r3{"ok"}.getBool(false), $r3)
  check("builder go binary exists", fileExists(tmp / "var" / "bin" / "tcompgo"), $r3)

  let unsafeGoFile = call(nc, "builder", "build", %*{
    "lang": "go", "name": "unsafe-go-file", "source": "package main\nfunc main() {}\n",
    "files": {"../escape.go": "package main\n"}
  })
  check("builder rejects unsafe additional Go source paths",
        not unsafeGoFile{"ok"}.getBool(false), $unsafeGoFile)

  # unsupported language is rejected
  let r4 = call(nc, "builder", "build",
                %*{"lang": "python", "name": "x", "source": "print(1)"})
  check("builder rejects unknown lang", not r4{"ok"}.getBool(false), $r4)

  # Manifest-v2 package builds copy the project, execute its argv recipe and
  # publish the declared artifact without mutating the clone.
  let packageRoot = tmp / "var" / "plugins" / "v2nim"
  createDir(packageRoot)
  writeFile(packageRoot / "main.nim", nimSrc)
  let packageBuild = call(nc, "builder", "build_package", %*{
    "name": "v2nim", "lang": "nim", "sourceRoot": packageRoot,
    "project": ".",
    "steps": [["nim", "c", "--hints:off", "-d:release",
                "--path:${NIF_SDK_ROOT}", "-o:${NIF_OUTPUT}", "main.nim"]],
    "artifact": {"path": "v2nim", "runner": "executable"}
  }, 400_000)
  check("builder package recipe compiles", packageBuild{"ok"}.getBool(false),
        $packageBuild)
  check("builder package publishes declared artifact",
        fileExists(tmp / "var" / "bin" / "v2nim"), $packageBuild)
  let shellBuild = call(nc, "builder", "build_package", %*{
    "name": "shellrecipe", "lang": "go", "sourceRoot": packageRoot,
    "project": ".", "steps": [["sh", "-c", "echo hidden"]],
    "artifact": {"path": "v2nim", "runner": "executable"}
  })
  check("builder rejects shell recipe wrappers",
        not shellBuild{"ok"}.getBool(false), $shellBuild)
  let outsideBuild = call(nc, "builder", "build_package", %*{
    "name": "outside", "lang": "nim", "sourceRoot": tmp,
    "project": ".", "steps": [["nim", "c", "main.nim"]],
    "artifact": {"path": "v2nim", "runner": "executable"}
  })
  check("builder package rejects a source root outside plugins",
        not outsideBuild{"ok"}.getBool(false), $outsideBuild)

  # TypeScript build (npm registry — network-gated)
  if getEnv("NIF_TEST_NETWORK") == "1":
    const tsSrc = """
      import sdk from "niffler-sdk";
      const comp = sdk.newComponent("tcompts", "0.1.0");
      comp.tool("ts_ping", {
        type: "object",
        description: "Ping the TypeScript test component",
        properties: {},
      }, async () => ({ pong: true }));
      comp.run();
      """.dedent()
    let r5 = call(nc, "builder", "build",
                  %*{"lang": "ts", "name": "tcompts", "source": tsSrc},
                  400_000)
    check("builder ts build ok", r5{"ok"}.getBool(false), $r5)
    check("builder ts binary exists",
          fileExists(tmp / "var" / "bin" / "tcompts"), $r5)

    # Packaged dependencies are not inferred from source imports. They are
    # exercised below through build_package and the plugin manifest contract.
  else:
    echo "NOTE: set NIF_TEST_NETWORK=1 to run the TypeScript build test"

  drain(nc)
  sleep(500)
  report("BUILDER TEST")

main()
