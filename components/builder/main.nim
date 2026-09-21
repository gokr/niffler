## builder component — building is itself a tool call.
##
## build(lang, name, source, files?) → compiled binary under var/bin for
## agent-authored source. build_package(sourceRoot, project, steps, artifact)
## builds a cloned plugin project in an isolated workspace, preserving the
## package's own dependency files and lockfiles. The agent/plugin's next step
## is core.spawn {name, binary}.

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

type
  CopyBudget = object
    files: int
    bytes: int64

const
  maxPackageFiles = 4096
  maxPackageBytes = 64'i64 * 1024 * 1024
  maxBuildSteps = 32
  maxBuildArgs = 128
  maxBuildArgBytes = 16 * 1024

proc validRelativePath(path: string, allowDot = false): bool =
  ## Package paths are deliberately boring: no absolute paths, traversal or
  ## empty components. `.` is allowed only for a project root.
  if path.len == 0 or path.isAbsolute(): return false
  let p = path.replace('\\', '/')
  if allowDot and p == ".": return true
  for part in p.split('/'):
    if part.len == 0 or part == ".." or part == ".": return false
  true

proc inside(path, parent: string): bool =
  let p = absolutePath(path)
  let r = absolutePath(parent)
  p == r or p.startsWith(r & $DirSep)

proc copyTree(src, dst: string, budget: var CopyBudget,
              skipNodeModules = true): bool =
  ## Copy a package into a private build tree. Symlinks are rejected rather
  ## than followed: a package build must not smuggle files from outside its
  ## declared source root into the builder's workspace.
  if symlinkExists(src): return false
  createDir(dst)
  for kind, path in walkDir(src):
    let name = path.splitPath.tail
    if name == ".git" or (skipNodeModules and name == "node_modules"):
      continue
    let target = dst / name
    case kind
    of pcFile:
      if symlinkExists(path): return false
      inc budget.files
      inc budget.bytes, getFileSize(path)
      if budget.files > maxPackageFiles or budget.bytes > maxPackageBytes:
        return false
      copyFile(path, target)
    of pcDir:
      if symlinkExists(path) or not copyTree(path, target, budget, skipNodeModules):
        return false
    else:
      return false
  true

proc materializeExternalLinks(path, allowedRoot: string,
                               budget: var CopyBudget): bool =
  ## npm uses a relative symlink for local file dependencies. It is valid in
  ## the staged workspace but would point back to the temporary build parent
  ## after the Node bundle moves under var/bin, so copy only such external
  ## links into the bundle. Links that already stay inside the workspace are
  ## preserved (notably node_modules/.bin).
  for kind, child in walkDir(path):
    if symlinkExists(child):
      let target = absolutePath(expandSymlink(child), child.parentDir())
      if inside(target, path):
        continue
      if not inside(target, allowedRoot): return false
      removeFile(child)
      if dirExists(target):
        if not copyTree(target, child, budget, skipNodeModules = true): return false
      elif fileExists(target):
        inc budget.files
        inc budget.bytes, getFileSize(target)
        if budget.files > maxPackageFiles or budget.bytes > maxPackageBytes:
          return false
        copyFile(target, child)
      else:
        return false
    elif kind == pcDir:
      if not materializeExternalLinks(child, allowedRoot, budget): return false
  true

proc expandToken(token, root, workspace, project, output, name: string): string =
  ## These are the only host values exposed to a package recipe. Expansion is
  ## done before argv reaches runArgv; recipes never become shell strings.
  result = token
  result = result.replace("${NIF_ROOT}", root)
  result = result.replace("${NIF_WORKSPACE}", workspace)
  result = result.replace("${NIF_PROJECT}", project)
  result = result.replace("${NIF_OUTPUT}", output)
  result = result.replace("${NIF_SDK_ROOT}", root / "sdk")
  result = result.replace("${NIF_SDK_GO}", root / "sdk" / "go")
  result = result.replace("${NIF_SDK_TS}", root / "sdk" / "ts")
  result = result.replace("${NIF_COMPONENT}", name)

proc allowedBuildCommand(exe: string): bool =
  ## Recipes use argv, not `sh -c`. A package may combine toolchains — a
  ## Wails app, for example, needs npm followed by wails — so this is one
  ## language-neutral tool allowlist rather than a per-language dispatch.
  ## Package scripts remain the ecosystem's normal dependency/build seam; the
  ## outer protocol cannot hide an additional shell program in one step.
  let base = exe.splitPath.tail
  base in ["nim", "nimble", "go", "npm", "node", "npx", "tsc", "wails",
           "mkdir", "printf"]

proc writeSdkWorkspace(root, workspace, project: string) =
  ## A generated Go workspace keeps the package clone immutable and makes the
  ## platform SDK available without asking a plugin to commit a machine-local
  ## replace directive. A recipe may still use ${NIF_SDK_GO} explicitly.
  let modPath = workspace / project / "go.mod"
  if not fileExists(modPath): return
  var goLine = "go 1.24"
  for line in lines(modPath):
    if line.strip().startsWith("go "):
      goLine = line.strip()
      break
  writeFile(workspace / "go.work", goLine & "\n\nuse ./" &
    (if project == ".": "." else: project.replace('\\', '/')) &
    "\n\nreplace niffler.dev/sdk => \"" & root / "sdk" / "go" & "\"\n")

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
    ##
    ## TS source-only builds intentionally contain only the SDK/base project.
    ## Packaged plugins with dependencies must use build_package and keep their
    ## package.json/package-lock.json in the cloned project.
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
          "replace niffler.dev/sdk => " & $(%(root / "sdk" / "go")) & "\n")
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
      # Source-only TS builds have only the generated base dependencies.
      # Packaged projects use build_package and own package.json/lockfiles.
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
      let (ccx, cox) = runCmd("cd " & quoteShell(dir) &
                              " && ./node_modules/.bin/tsc",
                              120000)
      if ccx != 0:
        return %*{"ok": false, "lang": lang, "error": tailBytes(cox, 2000)}
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
                "binary": binary, "log": tailBytes(io & "\n" & cox, 500)}
    else:
      return %*{"ok": false, "error": "unsupported lang '" & lang &
                "' (supported: nim, go, ts)"}

comp.tool(%*{"approval": "always", "timeoutMs": 600000,
                  "onDemand": true}):
  proc build_package(name: string, lang: string, sourceRoot: string,
                     project: string, steps: JsonNode,
                     artifact: JsonNode, publish: bool = true): JsonNode =
    ## Build a checked-out plugin project from its own dependency files and
    ## argv recipe. The source clone is copied into var/build first, so npm,
    ## go and nimble may generate lock/cache files without dirtying the clone.
    ## - name: lowercase-hyphen component name and published binary name
    ## - lang: package metadata (nim, go, or ts/typescript)
    ## - sourceRoot: cloned package root under var/plugins
    ## - project: package-relative project directory, or "."
    ## - steps: array of argv arrays, executed in project
    ## - artifact: {path: package-relative output, runner: executable|node}
    ## - publish: publish as var/bin/<name>; plugins set false until every
    ##   component in a package has built successfully
    let root = absolutePath(rootDir())
    let packageRoot = absolutePath(sourceRoot)
    let pluginsRoot = rootVarDir("plugins")
    if not validComponentName(name):
      return %*{"ok": false, "error": "invalid component name"}
    if not inside(packageRoot, pluginsRoot) or symlinkExists(packageRoot) or
       not dirExists(packageRoot):
      return %*{"ok": false,
                "error": "sourceRoot must be a real directory under var/plugins"}
    if not validRelativePath(project, allowDot = true):
      return %*{"ok": false, "error": "project must be a relative package path"}
    let workspace = rootVarDir("build") /
      ("package-" & name & "-" & $getCurrentProcessId())
    let projectDir = workspace / project
    if not dirExists(packageRoot / project):
      return %*{"ok": false, "error": "project directory does not exist"}
    if steps == nil or steps.kind != JArray or steps.len == 0 or
       steps.len > maxBuildSteps:
      return %*{"ok": false,
                "error": "steps must be a non-empty array of at most " &
                         $maxBuildSteps & " argv arrays"}
    if artifact == nil or artifact.kind != JObject:
      return %*{"ok": false, "error": "artifact must be an object"}
    let artifactPath = artifact{"path"}.getStr("")
    let runner = artifact{"runner"}.getStr("").toLowerAscii()
    if not validRelativePath(artifactPath) or
       runner notin ["executable", "node"]:
      return %*{"ok": false,
                "error": "artifact needs a safe path and runner executable|node"}
    createDir(workspace.parentDir())
    var budget: CopyBudget
    if not copyTree(packageRoot, workspace, budget):
      if dirExists(workspace): removeDir(workspace)
      return %*{"ok": false,
                "error": "package contains a symlink or exceeds the build input cap"}
    # A TS package commonly declares the platform SDK as file:../sdk/ts.
    # Stage it both beside the project (project=cc) and beside a root-level
    # project (project=.), without rewriting package.json or its lockfile.
    if lang.toLowerAscii() in ["ts", "typescript"]:
      for sdkPath in [workspace / "sdk" / "ts",
                      workspace.parentDir() / "sdk" / "ts"]:
        if not dirExists(sdkPath):
          if not copyTree(root / "sdk" / "ts", sdkPath, budget,
                          skipNodeModules = true):
            removeDir(workspace)
            return %*{"ok": false, "error": "could not stage the TypeScript SDK"}
    if lang.toLowerAscii() == "go":
      writeSdkWorkspace(root, workspace, project)

    var log = ""
    var index = 0
    for step in steps:
      if step.kind != JArray or step.len == 0 or step.len > maxBuildArgs:
        removeDir(workspace)
        return %*{"ok": false, "error": "build step " & $index &
                  " must be a non-empty argv array"}
      var argv: seq[string] = @[]
      for value in step:
        if value.kind != JString:
          removeDir(workspace)
          return %*{"ok": false, "error": "build step arguments must be strings"}
        let expanded = expandToken(value.getStr(""), root, workspace,
                                   projectDir, projectDir / artifactPath, name)
        if expanded.len > maxBuildArgBytes or expanded.contains('\0'):
          removeDir(workspace)
          return %*{"ok": false, "error": "build step argument is too large or invalid"}
        argv.add(expanded)
      if not allowedBuildCommand(argv[0]):
        removeDir(workspace)
        return %*{"ok": false,
                  "error": "recipe command is not in the supported argv tool set"}
      var args: seq[string] = @[]
      if argv.len > 1: args = argv[1 .. ^1]
      let rr = runArgv(argv[0], args, 300_000, workingDir = projectDir)
      log.add("step " & $index & " exit " & $rr.code & "\n")
      log.add(tailBytes(rr.output, 1500))
      if rr.code != 0:
        removeDir(workspace)
        return %*{"ok": false, "lang": lang, "error":
                  "build step " & $index & " failed: " & tailBytes(log, 2000)}
      inc index

    let built = projectDir / artifactPath
    if not fileExists(built) or symlinkExists(built):
      removeDir(workspace)
      return %*{"ok": false, "error": "declared artifact was not produced: " &
                artifactPath, "log": tailBytes(log, 2000)}
    let binDir = root / "var" / "bin"
    createDir(binDir)
    let binary = binDir / (if publish: name else:
      name & ".candidate-" & $getCurrentProcessId())
    if runner == "executable":
      let tmpBinary = binDir / (name & ".tmp-" & $getCurrentProcessId())
      copyFile(built, tmpBinary)
      setFilePermissions(tmpBinary, {fpUserExec, fpUserRead, fpUserWrite,
                                     fpGroupExec, fpGroupRead,
                                     fpOthersExec, fpOthersRead})
      if fileExists(binary): removeFile(binary)
      moveFile(tmpBinary, binary)
      removeDir(workspace)
      return %*{"ok": true, "lang": lang, "name": name,
                "binary": binary, "staged": not publish, "runner": runner,
                "log": tailBytes(log, 2000)}

    # Node components need node_modules and relative package assets at runtime,
    # so the staged tree itself becomes the durable bundle. Materialize local
    # SDK links before moving it out of var/build. The wrapper is the
    # executable artifact supervised by core.
    if not materializeExternalLinks(workspace, workspace.parentDir(), budget):
      removeDir(workspace)
      return %*{"ok": false, "error": "runtime bundle contains an unsafe external symlink"}
    # Keep every published runtime bundle versioned. A running old Node
    # component may still resolve assets from its bundle while plugins builds
    # and swaps the replacement; lifecycle cleanup removes the old runtime
    # only after core.remove has drained it.
    let bundle = binDir / (name & ".bundle-" & $getCurrentProcessId())
    moveDir(workspace, bundle)
    let entry = absolutePath(bundle / project / artifactPath)
    let wrapper = binDir / (name & ".tmp-" & $getCurrentProcessId())
    writeFile(wrapper, "#!/usr/bin/env node\n" &
      "process.chdir(" & $ %absolutePath(bundle / project) & ");\n" &
      "require(" & $ %entry & ");\n")
    setFilePermissions(wrapper, {fpUserExec, fpUserRead, fpUserWrite,
                                 fpGroupExec, fpGroupRead,
                                 fpOthersExec, fpOthersRead})
    if fileExists(binary): removeFile(binary)
    moveFile(wrapper, binary)
    return %*{"ok": true, "lang": lang, "name": name,
              "binary": binary, "staged": not publish,
              "runtime": bundle, "runner": runner,
              "log": tailBytes(log, 2000)}

comp.tool(%*{"onDemand": true}):
  proc info(): JsonNode =
    ## Info about the builder and the exact component source patterns
    let root = rootDir()
    return %*{"langs": ["nim", "go", "ts"], "sdk": root / "sdk",
              "sdkGo": root / "sdk" / "go", "sdkTs": root / "sdk" / "ts",
              "naming": "tool names are globally unique — prefix plugin tools with the component name (stocks_quote); bare semantic names are reserved for shipped core components",
              "flow": "plugins clones a manifest-v2 package → builder.build_package {name, lang, sourceRoot, project, steps, artifact} → core.spawn {name, binary}; package.json/go.mod/.nimble and lockfiles remain the package's dependency declaration. Agent source still uses builder.build.",
              "nim": "import niffler/sdk\nlet comp = newComponent(\"greet\", \"0.1.0\")\ncomp.tool:\n  proc greet(name: string): JsonNode =\n    ## Greet someone\n    ## - name: the name to greet\n    %*{\"greeting\": \"Hello, \" & name}\ncomp.run()",
              "go": "package main\nimport \"encoding/json\"\nimport sdk \"niffler.dev/sdk\" // module path; import as `sdk`\nfunc main() {\n  comp := sdk.New(\"greet\", \"0.1.0\")\n  comp.Tool(\"greet\", map[string]any{\"type\": \"object\", \"properties\": map[string]any{\"name\": map[string]any{\"type\": \"string\"}}, \"required\": []string{\"name\"}},\n    func(c *sdk.Component, args json.RawMessage) (any, error) {\n      var a struct { Name string `json:\"name\"` }\n      json.Unmarshal(args, &a)\n      return map[string]any{\"greeting\": \"Hello, \" + a.Name}, nil\n    })\n  comp.Run()\n}",
              "ts": "import sdk from \"niffler-sdk\"; // source-only builder example; packaged plugins use their own package.json\nconst comp = sdk.newComponent(\"greet\", \"0.1.0\");\ncomp.tool(\"greet\", {\n  type: \"object\",\n  description: \"Greet someone\",\n  properties: { name: { type: \"string\" } },\n  required: [\"name\"],\n}, async (_c, args: any) => {\n  return { greeting: \"Hello, \" + (args?.name ?? \"world\") };\n});\ncomp.run();"}

comp.run()
