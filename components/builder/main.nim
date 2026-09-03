## builder component — building is itself a tool call.
##
## build(lang, name, source, files?) → compiled binary under var/bin. Nim
## sources get the SDK path automatically (--path:<root>/sdk); Go sources get
## a go.mod with a replace to the local SDK and may include additional
## same-package .go files.
## The agent's next step is core.spawn {name, binary}.

import std/[json, os, strutils]
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

proc validGoSourceName(name: string): bool =
  ## Additional builder files are deliberately flat: no path traversal,
  ## nested modules, tests, generated binaries or go.mod replacement.
  if name.len == 0 or name.len > 128 or name == "main.go" or
     not name.endsWith(".go") or name.endsWith("_test.go"):
    return false
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      return false
  true

proc validDefine(name: string): bool =
  ## Compile defines are whitelisted to Nim-identifier characters so they can
  ## never inject shell or arbitrary compiler flags: "ssl" -> -d:ssl, never
  ## "ssl --run:something". See validComponentName for the same approach.
  if name.len == 0 or name.len > 64:
    return false
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}:
      return false
  true

let comp = newComponent("builder", "0.1.0")

comp.tool(%*{"approval": "always", "timeoutMs": 300000, "onDemand": true}):
  proc build(lang: string, name: string, source: string,
             files: JsonNode = nil, defines: JsonNode = nil): JsonNode =
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
    ## Tool names are globally unique across the whole catalog (core rejects
    ## duplicates at registration), so prefix every tool with the component
    ## name — stocks_quote, not quote. Only shipped core components may claim
    ## bare semantic names (read, edit, bash, ...).
    ## - lang: Language of the component: nim, go or ts
    ## - name: Lowercase-hyphen component name (also the binary name)
    ## - source: Full entrypoint source code of the component
    ## - files: Optional object of additional same-package Go filenames to source strings
    ## - defines: Optional array of Nim compile defines, e.g. ["ssl"] for
    ##   HTTPS-capable httpclient — appended as -d:NAME (validated; Nim
    ##   identifier characters only)
    let root = rootDir()
    let srcDir = rootVarDir("build")
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
      var dflags = ""
      if defines != nil and defines.kind == JArray:
        for d in defines:
          let dn = d.getStr("")
          if not validDefine(dn):
            return %*{"ok": false, "lang": lang,
                      "error": "invalid define: " & tailBytes(dn, 64)}
          dflags.add(" -d:" & dn)
      let (code, output) = runCmd(
        "nim c --hints:off -d:release" & dflags & " --path:" &
        quoteShell(root / "sdk") &
        " -o:" & quoteShell(tmpBinary) & " " & quoteShell(srcPath))
      if code != 0:
        removeFile(tmpBinary)
        return %*{"ok": false, "lang": lang, "error": tailBytes(output, 2000)}
      moveFile(tmpBinary, binary)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary, "log": tailBytes(output, 500)}
    of "go":
      let dir = srcDir / name
      if dirExists(dir): removeDir(dir)
      createDir(dir)
      writeFile(dir / "main.go", source)
      if files != nil:
        if files.kind != JObject:
          return %*{"ok": false, "lang": lang,
                    "error": "files must be an object of .go filename to source"}
        if files.len > 64:
          return %*{"ok": false, "lang": lang,
                    "error": "files may contain at most 64 Go sources"}
        var extraBytes = 0
        for filename, fileSource in files:
          if not validGoSourceName(filename):
            return %*{"ok": false, "lang": lang,
                      "error": "invalid additional Go source filename: " & filename}
          if fileSource.kind != JString:
            return %*{"ok": false, "lang": lang,
                      "error": "Go source " & filename & " must be a string"}
          inc extraBytes, fileSource.getStr().len
          if extraBytes > 2_000_000:
            return %*{"ok": false, "lang": lang,
                      "error": "additional Go sources exceed 2 MB"}
          writeFile(dir / filename, fileSource.getStr())
      if not fileExists(dir / "go.mod"):
        writeFile(dir / "go.mod",
          "module " & name & "\n\ngo 1.24\n\n" &
          "require niffler.dev/sdk v0.0.0\n\n" &
          "replace niffler.dev/sdk => " & root & "/sdk/go\n")
      let binary = binDir / name
      let tmpBinary = binDir / (name & ".tmp-" & $getCurrentProcessId())
      let (code, output) = runCmd(
        "cd " & quoteShell(dir) & " && go mod tidy && go build -o " &
        quoteShell(tmpBinary) & " .",
        300000)
      if code != 0:
        removeFile(tmpBinary)
        return %*{"ok": false, "lang": lang, "error": tailBytes(output, 2000)}
      moveFile(tmpBinary, binary)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary, "log": tailBytes(output, 500)}
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
      # NIF_NPM_REGISTRY (e.g. https://registry.npmmirror.com) overrides
      # the default registry for ts component installs — GitHub-hostile
      # networks usually reach npm mirrors fine.
      let registry = getEnv("NIF_NPM_REGISTRY")
      let registryFlag = if registry.len > 0: " --registry " & quoteShell(registry) else: ""
      let (ic, io) = runCmd(
        "cd " & quoteShell(dir) &
        " && npm install" & registryFlag & " --no-audit --no-fund --loglevel=error",
        300000)
      if ic != 0:
        return %*{"ok": false, "lang": lang, "error": tailBytes(io, 2000)}
      let (cc, co) = runCmd("cd " & quoteShell(dir) &
                            " && ./node_modules/.bin/tsc",
                            120000)
      if cc != 0:
        return %*{"ok": false, "lang": lang, "error": tailBytes(co, 2000)}
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
                "log": tailBytes(io & "\n" & co, 500)}
    else:
      return %*{"ok": false, "error": "unsupported lang '" & lang &
                "' (supported: nim, go, ts)"}

comp.tool(%*{"onDemand": true}):
  proc info(): JsonNode =
    ## Info about the builder and the exact component source patterns
    let root = rootDir()
    return %*{"langs": ["nim", "go", "ts"], "sdk": root / "sdk",
              "sdkGo": root / "sdk" / "go", "sdkTs": root / "sdk" / "ts",
              "naming": "tool names are globally unique — prefix plugin tools with the component name (stocks_quote); bare semantic names are reserved for shipped core components",
              "flow": "builder.build {lang, name, source} → core.spawn {name, binary} → discover the new component → invoke its tools. The conversation's direct toolset stays fixed; new tools are always reached via discover + invoke.",
              "nim": "import niffler/sdk\nlet comp = newComponent(\"greet\", \"0.1.0\")\ncomp.tool:\n  proc greet(name: string): JsonNode =\n    ## Greet someone\n    ## - name: the name to greet\n    %*{\"greeting\": \"Hello, \" & name}\ncomp.run()",
              "go": "package main\nimport sdk \"niffler.dev/sdk\" // module path; import as `sdk`\nfunc main() {\n  comp := sdk.New(\"greet\", \"0.1.0\")\n  comp.Tool(\"greet\", map[string]any{\"type\": \"object\", \"properties\": map[string]any{\"name\": map[string]any{\"type\": \"string\"}}, \"required\": []string{\"name\"}},\n    func(c *sdk.Component, args json.RawMessage) (any, error) {\n      var a struct { Name string `json:\"name\"` }\n      json.Unmarshal(args, &a)\n      return map[string]any{\"greeting\": \"Hello, \" + a.Name}, nil\n    })\n  comp.Run()\n}",
              "ts": "import sdk from \"niffler-sdk\"; // file: dependency wired by the builder\nconst comp = sdk.newComponent(\"greet\", \"0.1.0\");\ncomp.tool(\"greet\", {\n  type: \"object\",\n  description: \"Greet someone\",\n  properties: { name: { type: \"string\" } },\n  required: [\"name\"],\n}, async (_c, args: any) => {\n  return { greeting: \"Hello, \" + (args?.name ?? \"world\") };\n});\ncomp.run();"}

comp.run()
