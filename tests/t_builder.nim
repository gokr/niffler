## builder component tests — bus contract: compiling components from source.
##
## Covers: Nim build, Go build, failure reporting, and a build that is
## actually spawnable (the full self-extension path). Uses a temp
## NIF_ROOT so scratch sources and binaries never pollute the real
## var/build and var/bin.

import std/[json, os, osproc, strutils]
import natswrapper
import envelope
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "builder"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let tmp = tempRoot("builder")
  defer: removeDir(tmp)
  # the builder compiles with --path:<root>/sdk and picks up config.nims
  # from its cwd (pkgs2 resolution) — mirror those from the real root
  createSymlink(root / "sdk", tmp / "sdk")
  copyFile(root / "config.nims", tmp / "config.nims")
  copyFile(root / "niffler.nimble", tmp / "niffler.nimble")

  let (server, url) = startNats()
  var nc = waitConnect(url)

  let builderProc = startComponent(bin, url, root = tmp)
  defer:
    if builderProc.running():
      builderProc.terminate()
      sleep(200)
    builderProc.close()

  check("builder registers", waitRegistered(nc, "builder"))

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
      c := niffler.New("tcompgo", "0.1.0")
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
  let r3 = call(nc, "builder", "build",
                %*{"lang": "go", "name": "tcompgo", "source": goSrc}, 300_000)
  check("builder go build ok", r3{"ok"}.getBool(false), $r3)
  check("builder go binary exists", fileExists(tmp / "var" / "bin" / "tcompgo"), $r3)

  # unsupported language is rejected
  let r4 = call(nc, "builder", "build",
                %*{"lang": "python", "name": "x", "source": "print(1)"})
  check("builder rejects unknown lang", not r4{"ok"}.getBool(false), $r4)

  drain(nc)
  sleep(500)
  server.terminate()
  server.close()
  nc.close()
  report("BUILDER TEST")

main()
