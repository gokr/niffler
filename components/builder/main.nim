## builder component — building is itself a tool call.
##
## build(lang, name, source) → compiled binary under var/bin. Nim sources
## get the SDK path automatically (--path:<root>/sdk); Go sources get a
## go.mod with a replace to the local SDK if they don't have one.
## The agent's next step is core.spawn {name, binary}.

import std/[json, os, osproc, streams, times]
import niffler/sdk

proc runCmd(cmd: string, timeoutMs = 120000): tuple[output: string, code: int] =
  ## NOTE: osproc's waitForExit(timeout) SIGKILLs the child itself and
  ## returns 137, so the timeout branch would never fire — poll
  ## peekExitCode and own the kill (exit code 124 on timeout).
  var p = startProcess("bash", args = ["-c", cmd],
                       options = {poUsePath, poStdErrToStdOut})
  result.code = -1
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    result.code = p.peekExitCode()
    if result.code != -1: break
    sleep(50)
  if result.code == -1:
    p.terminate()
    sleep(200)
    if p.running(): p.kill()
    result.code = 124
  result.output = p.outputStream.readAll()
  p.close()

proc tail(s: string, n: int): string =
  if s.len <= n: return s
  return "…" & s[^n .. ^1]

let comp = newComponent("builder", "0.1.0")

comp.tool:
  proc build(lang: string, name: string, source: string): JsonNode =
    ## Compile a new component from source into a binary under var/bin.
    ## Use this when the harness lacks a capability that no existing tool
    ## covers: write the component source yourself (Nim: import niffler/sdk
    ## with the comp.tool: pattern; Go: import niffler "niffler.dev/sdk"),
    ## then call core.spawn with the returned binary — the component
    ## registers itself and its tools appear in your toolset on the next
    ## request. Call the info tool first to see the SDK locations and the
    ## exact code pattern. Returns ok, the binary path and a log tail
    ## (compile errors are truncated to 2000 chars).
    ## - lang: Language of the component: nim or go
    ## - name: Component name (also the binary name)
    ## - source: Full source code of the component
    let root = getEnv("NIF_ROOT", ".")
    let srcDir = root / "var" / "build"
    let binDir = root / "var" / "bin"
    createDir(srcDir)
    createDir(binDir)
    case lang
    of "nim":
      let srcPath = srcDir / (name & ".nim")
      writeFile(srcPath, source)
      let (output, code) = runCmd(
        "nim c --hints:off -d:release --path:" & root / "sdk" &
        " -o:" & binDir / name & " " & srcPath)
      if code != 0:
        return %*{"ok": false, "lang": lang, "error": tail(output, 2000)}
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binDir / name, "log": tail(output, 500)}
    of "go":
      let dir = srcDir / name
      createDir(dir)
      writeFile(dir / "main.go", source)
      if not fileExists(dir / "go.mod"):
        writeFile(dir / "go.mod",
          "module " & name & "\n\ngo 1.24\n\n" &
          "require niffler.dev/sdk v0.0.0\n\n" &
          "replace niffler.dev/sdk => " & root & "/sdk/go\n")
      let (output, code) = runCmd(
        "cd " & dir & " && go mod tidy && go build -o " & binDir / name & " .",
        300000)
      if code != 0:
        return %*{"ok": false, "lang": lang, "error": tail(output, 2000)}
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binDir / name, "log": tail(output, 500)}
    else:
      return %*{"ok": false, "error": "unsupported lang '" & lang &
                "' (supported: nim, go)"}

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 300000}

comp.tool:
  proc info(): JsonNode =
    ## Info about the builder and SDK locations
    let root = getEnv("NIF_ROOT", ".")
    return %*{"langs": ["nim", "go"], "sdk": root / "sdk",
              "sdkGo": root / "sdk" / "go",
              "note": "Nim: import niffler/sdk; Go: import niffler.dev/sdk; then core.spawn {name, binary}"}

comp.run()
