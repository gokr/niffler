## builder component — building is itself a tool call.
##
## build(lang, name, source) → compiled binary under var/bin. Nim sources
## get the SDK path automatically (--path:<root>/sdk); Go sources get a
## go.mod with a replace to the local SDK if they don't have one.
## The agent's next step is core.spawn {name, binary}.

import std/[json, os, osproc, streams, strutils, times]
import niffler/sdk

proc validComponentName(name: string): bool =
  if name.len == 0 or name.len > 64 or name[0] == '-' or name[^1] == '-':
    return false
  var previousHyphen = false
  for ch in name:
    if ch in {'a'..'z'} or ch in {'0'..'9'}:
      previousHyphen = false
    elif ch == '-' and not previousHyphen:
      previousHyphen = true
    else:
      return false
  true

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
    ## with the comp.tool: pattern; Go: import sdk "niffler.dev/sdk";
    ## TypeScript: import sdk from "niffler-sdk" with the comp.tool(...)
    ## pattern), then invoke core.spawn with the returned binary — the
    ## component registers itself and becomes available through discover.
    ## Call the info tool first to see the SDK locations and the exact code
    ## pattern. Returns ok, the binary path and a log
    ## tail (compile errors are truncated to 2000 chars).
    ## - lang: Language of the component: nim, go or ts
    ## - name: Lowercase-hyphen component name (also the binary name)
    ## - source: Full source code of the component
    let root = getEnv("NIF_ROOT", ".")
    let srcDir = root / "var" / "build"
    let binDir = root / "var" / "bin"
    if not validComponentName(name):
      return %*{"ok": false,
                "error": "name must be 1-64 lowercase letters, digits, and single hyphens"}
    createDir(srcDir)
    createDir(binDir)
    case lang
    of "nim":
      # Nim module filenames are identifiers; the output keeps the component name.
      let srcPath = srcDir / (name.replace("-", "_") & ".nim")
      writeFile(srcPath, source)
      let binary = binDir / name
      let tmpBinary = binDir / (name & ".tmp-" & $getCurrentProcessId())
      let (output, code) = runCmd(
        "nim c --hints:off -d:release --path:" & quoteShell(root / "sdk") &
        " -o:" & quoteShell(tmpBinary) & " " & quoteShell(srcPath))
      if code != 0:
        removeFile(tmpBinary)
        return %*{"ok": false, "lang": lang, "error": tail(output, 2000)}
      moveFile(tmpBinary, binary)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary, "log": tail(output, 500)}
    of "go":
      let dir = srcDir / name
      createDir(dir)
      writeFile(dir / "main.go", source)
      if not fileExists(dir / "go.mod"):
        writeFile(dir / "go.mod",
          "module " & name & "\n\ngo 1.24\n\n" &
          "require niffler.dev/sdk v0.0.0\n\n" &
          "replace niffler.dev/sdk => " & root & "/sdk/go\n")
      let binary = binDir / name
      let tmpBinary = binDir / (name & ".tmp-" & $getCurrentProcessId())
      let (output, code) = runCmd(
        "cd " & quoteShell(dir) & " && go mod tidy && go build -o " &
        quoteShell(tmpBinary) & " .",
        300000)
      if code != 0:
        removeFile(tmpBinary)
        return %*{"ok": false, "lang": lang, "error": tail(output, 2000)}
      moveFile(tmpBinary, binary)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary, "log": tail(output, 500)}
    of "ts":
      if findExe("node").len == 0 or findExe("npm").len == 0:
        return %*{"ok": false, "lang": lang,
                  "error": "node and npm are required on PATH for ts components"}
      let dir = srcDir / name
      createDir(dir)
      writeFile(dir / "main.ts", source)
      writeFile(dir / "package.json",
        "{\n  \"name\": \"" & name & "\",\n  \"private\": true,\n" &
        "  \"dependencies\": {\n    \"nats\": \"^2.29.0\",\n" &
        "    \"niffler-sdk\": \"file:" & root / "sdk" / "ts" & "\"\n  },\n" &
        "  \"devDependencies\": {\n    \"typescript\": \"^5.5.0\",\n" &
        "    \"@types/node\": \"^22.0.0\"\n  }\n}\n")
      writeFile(dir / "tsconfig.json",
        "{\n  \"compilerOptions\": {\n    \"target\": \"ES2022\",\n" &
        "    \"module\": \"commonjs\",\n    \"moduleResolution\": \"node\",\n" &
        "    \"outDir\": \"dist\",\n    \"strict\": true,\n" &
        "    \"esModuleInterop\": true,\n    \"skipLibCheck\": true\n  },\n" &
        "  \"include\": [\"main.ts\"]\n}\n")
      let (io, ic) = runCmd(
        "cd " & quoteShell(dir) &
        " && npm install --no-audit --no-fund --loglevel=error",
        300000)
      if ic != 0:
        return %*{"ok": false, "lang": lang, "error": tail(io, 2000)}
      let (co, cc) = runCmd("cd " & quoteShell(dir) &
                            " && ./node_modules/.bin/tsc",
                            120000)
      if cc != 0:
        return %*{"ok": false, "lang": lang, "error": tail(co, 2000)}
      if not fileExists(dir / "dist" / "main.js"):
        return %*{"ok": false, "lang": lang,
                  "error": "tsc produced no dist/main.js"}
      # the "binary" is a node wrapper around the compiled entry
      let binary = binDir / name
      let tmpBinary = binDir / (name & ".tmp-" & $getCurrentProcessId())
      writeFile(tmpBinary,
        "#!/usr/bin/env node\n" &
        "require(" & $ %absolutePath(dir / "dist" / "main.js") & ");\n")
      setFilePermissions(tmpBinary, {fpUserExec, fpUserRead, fpUserWrite,
                                     fpGroupExec, fpGroupRead,
                                     fpOthersExec, fpOthersRead})
      moveFile(tmpBinary, binary)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary,
                "log": tail(io & "\n" & co, 500)}
    else:
      return %*{"ok": false, "error": "unsupported lang '" & lang &
                "' (supported: nim, go, ts)"}

comp.tools[^1].schema["x-harness"] =
  %*{"approval": "always", "timeoutMs": 300000, "onDemand": true}

comp.tool:
  proc info(): JsonNode =
    ## Info about the builder and SDK locations
    let root = getEnv("NIF_ROOT", ".")
    return %*{"langs": ["nim", "go", "ts"], "sdk": root / "sdk",
              "sdkGo": root / "sdk" / "go", "sdkTs": root / "sdk" / "ts",
              "note": "Nim: import niffler/sdk; Go: import sdk \"niffler.dev/sdk\"; TS: import sdk from \"niffler-sdk\" — then discover and invoke core.spawn {name, binary}"}

comp.tools[^1].schema["x-harness"] = %*{"onDemand": true}

comp.run()
