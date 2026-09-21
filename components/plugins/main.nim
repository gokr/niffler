## plugins component — ecosystem discovery and install, as a bus service.
##
## Third-party components are distributed as plain git repos: one repo = one
## package = N components, described by a niffler.json manifest at the root
## ({"name", "version", "manifestVersion"?, "components":
##   [{"name", "lang", "main"?, "project"?, "build"?, "sources"?,
##     "env"?, "interactive"?}]}).
## Manifest v1 keeps the compact source form for backwards compatibility.
## Manifest v2 points builder at a real project: package.json/package-lock.json,
## go.mod/go.sum and .nimble/lockfiles remain the package's own dependency
## declaration, while the recipe only describes reproducible argv steps.
## Discovery is GitHub topic search (topic:niffler-component) — no registry.
## GitHub ANDs query words, so plugin_search retries a zero-hit multi-word
## query with fewer words (see the plugin_search docstring).
##
## Install: shallow clone into var/plugins/<repo>@<ref>/, then build every
## component from source through the builder component (the same path the
## agent uses for its own components — the harness already ships Nim/Go and
## builds its own extensions). Service components are core.spawned;
## interactive components are built for the user to start in a terminal.
## Go clones get an untracked go.work redirecting the SDK replace to this
## harness, so a manual `make` in var/plugins/<pkg>@<ref>/ builds too.
## Installed packages are
## recorded in the store (kind "plugin") so plugin_update and plugin_remove
## know their shape. var/ is disposable runtime state; the store record is
## what survives (docs/MANUAL.md).
##
## Requires: git and network access. The GitHub API is used unauthenticated
## (60 req/h/IP — plenty for discovery). Installs run arbitrary third-party
## code: install/update/remove carry x-harness.approval, and core's own
## spawn/remove gate fires per component on top.

import std/[httpclient, json, os, sequtils, strutils, times, uri]
import niffler/sdk
import versions

let comp = newComponent("plugins", "0.1.0")

const githubApi = "https://api.github.com"
const topic = "niffler-component"

proc root(): string = rootDir()

proc ghClient(): HttpClient =
  result = newHttpClient("niffler-plugins/0.1", timeout = 30_000)
  result.headers = newHttpHeaders({"Accept": "application/vnd.github+json"})

# --------------------------------------------------------------------------
# repo/ref plumbing

proc normalizeRepo(repoArg: string): string =
  ## Accepts "owner/name", github.com URLs (https or ssh) → "owner/name",
  ## or a "file:///path/to/repo" URL (local git repos — tests, mirrors).
  if repoArg.strip().startsWith("file://"):
    let r = repoArg.strip()
    for ch in r:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/', ':', '~'}:
        raise newException(ValueError, "malformed repo URL: " & repoArg)
    return r
  var r = repoArg.strip()
  r.removeSuffix(".git")
  for pre in ["https://github.com/", "http://github.com/", "git@github.com:"]:
    if r.startsWith(pre):
      r = r[pre.len .. ^1]
  result = r.strip(true, true, {'/'})
  let parts = result.split('/')
  if parts.len != 2:
    raise newException(ValueError,
      "repo must be 'owner/name' or a github.com URL, got: " & repoArg)
  for p in parts:
    if p.len == 0:
      raise newException(ValueError, "malformed repo: " & repoArg)
    for ch in p:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
        raise newException(ValueError, "malformed repo name: " & repoArg)

proc repoSlug(repo: string): string =
  ## Directory slug for a repo: basename for file:// URLs, owner/name's
  ## name part for GitHub repos.
  if repo.startsWith("file://"):
    result = repo.rsplit('/', 1)[^1]
  else:
    result = repo.split('/')[1]

proc checkRef(r: string): string =
  result = r.strip()
  for ch in result:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/'}:
      raise newException(ValueError, "malformed ref: " & r)

proc resolveTag(repo: string): string =
  ## Latest release tag; else the highest version tag — many component
  ## packages tag without publishing GitHub releases (gokr/niffler-tui),
  ## and without this fallback a tag-pinned install on such a repo could
  ## never move forward; else "" when the repo has neither (or the API is
  ## rate-limited).
  ##
  ## A fresh client per probe: a stale pooled connection (e.g. a 404 the
  ## server already closed — the normal answer for a release-less repo)
  ## would hang the next read on the same client.
  block releases:
    let client = ghClient()
    defer: client.close()
    try:
      let rel = client.getContent(githubApi & "/repos/" & repo &
                                  "/releases/latest").parseJson()
      result = rel{"tag_name"}.getStr("")
    except CatchableError:
      result = ""
  if result.len > 0: return
  block tags:
    let client = ghClient()
    defer: client.close()
    try:
      let list = client.getContent(githubApi & "/repos/" & repo &
                                   "/tags?per_page=100").parseJson()
      var names: seq[string]
      if list != nil and list.kind == JArray:
        for t in list:
          names.add(t{"name"}.getStr(""))
      result = latestVersionTag(names)
    except CatchableError:
      result = ""

proc defaultBranch(repo: string): string =
  let client = ghClient()
  defer: client.close()
  try:
    let info = client.getContent(githubApi & "/repos/" & repo).parseJson()
    result = info{"default_branch"}.getStr("main")
  except CatchableError:
    result = "main"

# --------------------------------------------------------------------------
# store records (kind "plugin": id = package name)

proc pluginRecord(pkg: string): JsonNode =
  ## The stored install record, or nil when not installed or the store is
  ## unreachable (callers treat nil as "not installed" — fail closed).
  try:
    return comp.storeGet("plugin", pkg).value
  except CatchableError:
    discard
  return nil

proc saveRecord(pkg: string, value: JsonNode) =
  ## A refused put is exceptional (never silently dropped) — the raise
  ## surfaces as an error envelope to the install tool.
  discard comp.storePut("plugin", pkg, value)

proc dropRecord(pkg: string) =
  comp.storeDel("plugin", pkg)

# --------------------------------------------------------------------------
# install / update / remove internals

type
  ManifestComp = tuple[name, lang, main, project: string,
                       sources, env, defines: seq[string],
                       steps, artifact: JsonNode,
                       interactive: bool, manifestVersion: int]
  Manifest = tuple[name, version: string, manifestVersion: int,
                   comps: seq[ManifestComp]]

proc validManifestSourcePath(path: string): bool =
  if path.len == 0 or path.isAbsolute(): return false
  let parts = path.replace('\\', '/').split('/')
  not parts.anyIt(it.len == 0 or it == "." or it == "..")

proc validManifestProjectPath(path: string): bool =
  if path == ".": return true
  validManifestSourcePath(path)

proc readManifest(dir: string): Manifest =
  let path = dir / "niffler.json"
  if not fileExists(path):
    raise newException(ValueError,
      "no niffler.json in the repo root — is this a component package?")
  let m = readFile(path).parseJson()
  result.name = m{"name"}.getStr("")
  result.version = m{"version"}.getStr("")
  result.manifestVersion = m{"manifestVersion"}.getInt(1)
  if result.manifestVersion notin [1, 2]:
    raise newException(ValueError, "niffler.json: manifestVersion must be 1 or 2")
  if result.name.len == 0:
    raise newException(ValueError, "niffler.json has no 'name'")
  let comps = m{"components"}
  if comps == nil:
    raise newException(ValueError, "niffler.json has no 'components' array")
  for e in comps:
    var mc: ManifestComp
    mc.name = e{"name"}.getStr("")
    mc.lang = e{"lang"}.getStr(e{"language"}.getStr("")).toLowerAscii()
    if mc.lang == "typescript": mc.lang = "ts"
    mc.main = e{"main"}.getStr("")
    mc.project = e{"project"}.getStr(".")
    mc.steps = nil
    mc.artifact = nil
    mc.manifestVersion = result.manifestVersion
    if result.manifestVersion == 1:
      if not validManifestSourcePath(mc.main):
        raise newException(ValueError,
          "niffler.json: invalid component main path '" & mc.main & "'")
    else:
      if mc.main.len > 0 or not validManifestProjectPath(mc.project):
        raise newException(ValueError,
          "niffler.json: v2 components use a safe project path, not main")
      let build = e{"build"}
      if build == nil or build.kind != JObject or
         build{"steps"} == nil or build{"artifact"} == nil or
         build{"steps"}.kind != JArray or build{"artifact"}.kind != JObject:
        raise newException(ValueError,
          "niffler.json: v2 component needs build.steps and build.artifact")
      mc.steps = build{"steps"}
      mc.artifact = build{"artifact"}
      let runner = mc.artifact{"runner"}.getStr("").toLowerAscii()
      let artifactPath = mc.artifact{"path"}.getStr("")
      if not validManifestSourcePath(artifactPath) or
         runner notin ["executable", "node"]:
        raise newException(ValueError,
          "niffler.json: v2 artifact needs a safe path and runner")
    mc.interactive = e{"interactive"}.getBool(false)
    mc.sources = @[]
    let sourcesArr = e{"sources"}
    if sourcesArr != nil:
      if result.manifestVersion != 1 or mc.lang != "go" or
         sourcesArr.kind != JArray:
        raise newException(ValueError,
          "niffler.json: sources must be an array on a Go component")
      let mainDir = mc.main.splitFile().dir
      for sourceNode in sourcesArr:
        let source = sourceNode.getStr("")
        if not validManifestSourcePath(source) or
           source.splitFile().dir != mainDir or
           not source.endsWith(".go") or source.endsWith("_test.go"):
          raise newException(ValueError,
            "niffler.json: invalid same-package Go source '" & source & "'")
        if source == mc.main or source in mc.sources:
          raise newException(ValueError,
            "niffler.json: duplicate Go source '" & source & "'")
        mc.sources.add(source)
    mc.env = @[]
    let envArr = e{"env"}
    if envArr != nil:
      for en in envArr:
        mc.env.add(en.getStr(""))
    mc.defines = @[]
    let definesArr = e{"defines"}
    if definesArr != nil:
      if result.manifestVersion != 1 or definesArr.kind != JArray:
        raise newException(ValueError,
          "niffler.json: defines must be an array on " & mc.name)
      for dn in definesArr:
        mc.defines.add(dn.getStr(""))
    if mc.name.len == 0 or
       (result.manifestVersion == 1 and mc.main.len == 0):
      raise newException(ValueError,
        "niffler.json component entry needs name and (for v1) main")
    if mc.lang notin ["nim", "go", "ts"]:
      raise newException(ValueError,
        "niffler.json: unsupported lang '" & mc.lang & "' for " & mc.name)
    if result.manifestVersion == 1:
      if not fileExists(dir / mc.main) or symlinkExists(dir / mc.main):
        raise newException(ValueError,
          "niffler.json: " & mc.main & " not found or is a symlink for component " & mc.name)
    elif not dirExists(dir / mc.project) or symlinkExists(dir / mc.project):
      raise newException(ValueError,
        "niffler.json: project " & mc.project &
        " not found or is a symlink for component " & mc.name)
    for source in mc.sources:
      if not fileExists(dir / source) or symlinkExists(dir / source):
        raise newException(ValueError,
          "niffler.json: " & source & " not found or is a symlink for component " & mc.name)
    result.comps.add(mc)
  if result.comps.len == 0:
    raise newException(ValueError, "niffler.json lists no components")

proc spawnComponent(mc: ManifestComp, binary: string): JsonNode =
  try:
    discard comp.request("core", "spawn",
                         %*{"name": mc.name, "binary": binary}, 360_000)
    return %*{"name": mc.name, "binary": binary, "spawned": true}
  except CatchableError as e:
    return %*{"name": mc.name, "binary": binary, "spawned": false,
              "error": e.msg}

proc buildComp(mc: ManifestComp, dest, binDir: string): JsonNode =
  ## Build only. Spawning is deliberately a second phase so an update can
  ## compile every replacement before it stops the currently running package.
  createDir(binDir)
  try:
    var r: JsonNode
    if mc.manifestVersion == 2:
      let buildArgs = %*{"lang": mc.lang, "name": mc.name,
                         "sourceRoot": absolutePath(dest),
                         "project": mc.project, "steps": mc.steps,
                         "artifact": mc.artifact, "publish": false}
      r = comp.request("builder", "build_package", buildArgs, 600_000)
    else:
      var buildArgs = %*{"lang": mc.lang, "name": mc.name,
                         "source": readFile(dest / mc.main)}
      if mc.defines.len > 0:
        buildArgs["defines"] = %mc.defines
      if mc.sources.len > 0:
        var files = newJObject()
        for source in mc.sources:
          files[source.extractFilename()] = %readFile(dest / source)
        buildArgs["files"] = files
      r = comp.request("builder", "build", buildArgs, 320_000)
    if not r{"ok"}.getBool(false):
      result = %*{"ok": false, "name": mc.name, "spawned": false,
                  "error": "build failed: " & tailBytes(r{"error"}.getStr("?"), 400)}
      if r{"log"} != nil: result["log"] = r{"log"}
      return
    result = %*{"ok": true, "name": mc.name, "binary":
                absolutePath(r{"binary"}.getStr(binDir / mc.name)),
                "built": "source", "spawned": false}
    if r{"runtime"} != nil: result["runtime"] = r{"runtime"}
    if r{"runner"} != nil: result["runner"] = r{"runner"}
    if r{"staged"} != nil: result["staged"] = r{"staged"}
    if mc.env.len > 0: result["env"] = %mc.env
    if r{"log"} != nil: result["log"] = r{"log"}
  except CatchableError as e:
    result = %*{"ok": false, "name": mc.name, "spawned": false,
                "error": "build failed: " & e.msg}

proc spawnBuilt(mc: ManifestComp, built: JsonNode): JsonNode =
  result = built
  if not built{"ok"}.getBool(false): return
  if mc.interactive:
    result["interactive"] = %true
    result["spawned"] = %false
    return
  let spawned = spawnComponent(mc, built{"binary"}.getStr(""))
  result["spawned"] = %spawned{"spawned"}.getBool(false)
  if spawned{"error"} != nil: result["error"] = spawned{"error"}

proc buildComponents(mf: Manifest, dest, binDir: string):
    tuple[items: JsonNode, ok: bool] =
  result.items = newJArray()
  result.ok = true
  for mc in mf.comps:
    let built = buildComp(mc, dest, binDir)
    result.items.add(built)
    if not built{"ok"}.getBool(false): result.ok = false

proc spawnComponents(mf: Manifest, built: JsonNode): JsonNode =
  result = newJArray()
  for i, mc in mf.comps:
    result.add(spawnBuilt(mc, built[i]))

proc cleanupBuilt(items: JsonNode) =
  ## Remove v2 candidates and runtime bundles when a later package component
  ## fails to build. Published v1 binaries and an installed package's live
  ## artifacts are never touched here.
  if items == nil: return
  for item in items:
    if not item{"ok"}.getBool(false): continue
    if item{"staged"}.getBool(false):
      let binary = item{"binary"}.getStr("")
      let runtime = item{"runtime"}.getStr("")
      try:
        if binary.len > 0 and fileExists(binary): removeFile(binary)
        if runtime.len > 0 and dirExists(runtime): removeDir(runtime)
      except CatchableError:
        discard

proc publishBuilt(mf: Manifest, built: JsonNode): bool =
  ## Publish all v2 candidates only after every recipe in the package passed.
  ## The candidate and final binary live on the same filesystem, so each
  ## replacement is one rename and the old running process keeps its mapped
  ## executable. Node bundles are already versioned and need no rename.
  try:
    for item in built:
      if item{"staged"}.getBool(false) and
         not fileExists(item{"binary"}.getStr("")):
        return false
    for i, mc in mf.comps:
      let item = built[i]
      if not item{"staged"}.getBool(false): continue
      let candidate = item{"binary"}.getStr("")
      let final = absolutePath(root() / "var" / "bin" / mc.name)
      if fileExists(final): removeFile(final)
      moveFile(candidate, final)
      item["binary"] = %final
      item["staged"] = %false
    true
  except CatchableError:
    false

proc writeGoWork(dest: string, mf: Manifest) =
  ## Untracked go.work in a clone that redirects the repo's sibling-checkout
  ## SDK replace (`replace niffler.dev/sdk => ../niffler/sdk/go`) to this
  ## harness's sdk/go, so a manual `make` in the plugin directory builds
  ## out of the box. go.mod itself is left untouched — a dirty tracked file
  ## would break the next `git pull --ff-only` in plugin_update. Repos with
  ## their own committed go.work are left alone.
  let work = dest / "go.work"
  if fileExists(work): return
  var modDirs: seq[string]
  for path in walkDirRec(dest):
    if "/.git/" in path: continue
    if path.endsWith("/go.mod"):
      modDirs.add(path.parentDir())
  if modDirs.len == 0: return  # no Go modules — nothing to redirect
  # Use-list = the modules this package's manifest actually builds, so a
  # broken/unrelated nested module cannot poison workspace builds. Fall
  # back to the root module when no Go source matches.
  var use: seq[string]
  for d in modDirs:
    for mc in mf.comps:
      if mc.lang != "go": continue
      var inModule = false
      for src in mc.sources & @[mc.main]:
        let p = dest / src
        if p == d or p.startsWith(d & "/"): inModule = true
      if inModule:
        use.add(d)
        break
  if use.len == 0 and (dest / "go.mod") in modDirs:
    use.add(dest)
  if use.len == 0: return
  # Mirror the module's own go directive (patch versions included) so the
  # workspace never out-requires the installed toolchain.
  var goLine = ""
  for d in use:
    for line in lines(d / "go.mod"):
      let l = line.strip()
      if l.startsWith("go "):
        goLine = l
        break
    if goLine.len > 0: break
  if goLine.len == 0: goLine = "go 1.24"
  var content = goLine & "\n\n"
  for d in use:
    let rel = relativePath(d, dest).replace('\\', '/')
    content.add("use " & (if rel == ".": "." else: "./" & rel) & "\n")
  content.add("\nreplace niffler.dev/sdk => \"" & root() / "sdk" / "go" & "\"\n")
  writeFile(work, content)

proc cleanupRuntimes(rec: JsonNode)
proc removeComps(rec: JsonNode): JsonNode

proc doInstall(repo, refArg: string, replacing: JsonNode = nil): JsonNode =
  ## Resolve ref (latest release tag, else default branch — skipped for
  ## local file:// repos, which clone HEAD), clone, then build each
  ## component, spawn service components and persist the record. Interactive
  ## components are installed binaries that the user starts in a terminal.
  let local = repo.startsWith("file://")
  var refTag = checkRef(refArg)
  if refTag.len == 0 and not local:
    refTag = resolveTag(repo)
  if refTag.len == 0 and not local:
    refTag = defaultBranch(repo)
  let slug = repoSlug(repo)
  let pkgSlug = slug & "@" & (if refTag.len > 0: refTag else: "head")
  let dest = root() / "var" / "plugins" / pkgSlug
  if dirExists(dest):
    # a leftover clone from a failed/aborted install is stale when no
    # record exists for its manifest name — clear it and start fresh
    var oldName = ""
    try:
      let oldMf = readManifest(dest)
      oldName = oldMf.name
    except CatchableError:
      discard
    if oldName.len > 0 and pluginRecord(oldName) != nil:
      return errResult("already installed: " & oldName &
                       " — use plugin_update, or plugin_remove first")
    removeDir(dest)
  createDir(dest.parentDir())
  # NIF_GIT_MIRROR rewrites the clone host (e.g. a CNB/Gitee mirror) for
  # networks where github.com cloning is throttled; API/search stay on
  # GitHub, which is usually still reachable.
  let mirror = getEnv("NIF_GIT_MIRROR").strip(chars = {'/', ' '})
  let url =
    if local: repo
    elif mirror.len > 0: mirror & "/" & repo & ".git"
    else: "https://github.com/" & repo & ".git"
  let (ccode, cout) = if refTag.len > 0:
    runCmd("git clone --depth 1 --branch " & refTag & " " & url & " " & dest)
  else:
    runCmd("git clone --depth 1 " & url & " " & dest)
  if ccode != 0:
    if dirExists(dest): removeDir(dest)
    return errResult("git clone failed", extra = %*{"output": tailBytes(cout, 800)})

  let mf = readManifest(dest)
  if mf.manifestVersion == 1: writeGoWork(dest, mf)
  let binDir = root() / "var" / "bin"
  let built = buildComponents(mf, dest, binDir)
  if not built.ok:
    cleanupBuilt(built.items)
    removeDir(dest)
    return errResult("package build failed; no components were stopped",
                     extra = %*{"components": built.items})
  if not publishBuilt(mf, built.items):
    cleanupBuilt(built.items)
    removeDir(dest)
    return errResult("package publish failed; no components were stopped",
                     extra = %*{"components": built.items})

  # An update has now proved that every replacement builds. Only this point
  # is allowed to stop the old package; a failed recipe leaves it running.
  var removed = newJArray()
  if replacing != nil:
    removed = removeComps(replacing)
    cleanupRuntimes(replacing)
  let components = spawnComponents(mf, built.items)
  var installed = 0
  for st in components:
    if st{"spawned"}.getBool(false) or st{"interactive"}.getBool(false):
      inc installed
  if installed == 0:
    removeDir(dest)
    return errResult("no component could be installed",
                     extra = %*{"components": components, "removed": removed})

  saveRecord(mf.name, %*{"name": mf.name, "repo": repo, "ref": refTag,
                         "dir": dest, "version": mf.version,
                         "manifestVersion": mf.manifestVersion,
                         "components": components, "addedAt": epochTime()})
  result = okResult(%*{"package": mf.name, "repo": repo, "ref": refTag,
                       "dir": dest, "components": components,
                       "removed": removed})

proc cleanupRuntimes(rec: JsonNode) =
  ## Runtime bundles are versioned, so an update can leave the old Node
  ## process alive while the new one is built and published. Remove the old
  ## bundle only after core.remove has drained that process.
  let comps = rec{"components"}
  if comps == nil: return
  for e in comps:
    let runtime = e{"runtime"}.getStr("")
    try:
      if runtime.len > 0 and dirExists(runtime): removeDir(runtime)
    except CatchableError:
      discard

proc cleanupArtifacts(rec: JsonNode) =
  ## The supervisor owns processes, while plugins owns the published build
  ## artifacts. Remove them only after core.remove.
  let comps = rec{"components"}
  if comps == nil: return
  cleanupRuntimes(rec)
  for e in comps:
    let binary = e{"binary"}.getStr("")
    try:
      if binary.len > 0 and fileExists(binary): removeFile(binary)
    except CatchableError:
      discard

proc removeComps(rec: JsonNode): JsonNode =
  ## core.remove every recorded component; tolerate individual failures.
  result = newJArray()
  let comps = rec{"components"}
  if comps == nil: return result
  for e in comps:
    let name = e{"name"}.getStr("")
    if name.len == 0: continue
    if e{"interactive"}.getBool(false):
      result.add(%*{"name": name, "removed": true, "interactive": true,
                    "note": "not supervised; stop any running terminal client manually"})
      continue
    try:
      discard comp.request("core", "remove", %*{"name": name}, 360_000)
      result.add(%*{"name": name, "removed": true})
    except CatchableError as err:
      result.add(%*{"name": name, "removed": false, "error": err.msg})

proc doUpdateBranch(pkg: string, rec: JsonNode): JsonNode =
  ## In-place update for a package pinned to a branch rather than a release
  ## tag (resolveTag found nothing to move to): `git pull --ff-only` the
  ## existing clone and rebuild only when the pull actually moved HEAD — no
  ## remove/reinstall round-trip, so a no-op pull costs nothing. Local
  ## file:// installs carry no recorded ref: the branch is read from the
  ## clone's own HEAD (and persisted, so later updates skip re-detection).
  let dest = rec{"dir"}.getStr("")
  var branch = rec{"ref"}.getStr("")
  if dest.len == 0 or not dirExists(dest):
    return errResult("package directory missing: " & dest)
  if branch.len == 0:
    # Refless install (file:// installs never record a ref): the clone's
    # checked-out branch is the tracked one.
    let (bcode, bout) = runCmd("git -C " & quoteShell(dest) &
                               " rev-parse --abbrev-ref HEAD")
    if bcode != 0:
      return errResult("git rev-parse failed", extra = %*{"output": tailBytes(bout, 800)})
    branch = bout.strip()
    if branch.len == 0 or branch == "HEAD":
      return errResult("clone is in detached-HEAD state — reinstall instead")
  let (hcode, hout) = runCmd("git -C " & quoteShell(dest) & " rev-parse HEAD")
  if hcode != 0:
    return errResult("git rev-parse failed", extra = %*{"output": tailBytes(hout, 800)})
  let before = hout.strip()
  let (pcode, pout) = runCmd(
    "git -C " & quoteShell(dest) & " pull --ff-only origin " & branch, 60_000)
  if pcode != 0:
    return errResult("git pull failed", extra = %*{"output": tailBytes(pout, 800)})
  let (h2code, h2out) = runCmd("git -C " & quoteShell(dest) & " rev-parse HEAD")
  let after = if h2code == 0: h2out.strip() else: before
  if after == before:
    # Nothing new, but persist a detected branch so a refless record becomes
    # honest about what it tracks (and later updates take the fast path).
    if branch != rec{"ref"}.getStr(""):
      try:
        let mf = readManifest(dest)
        if mf.manifestVersion == 1: writeGoWork(dest, mf)
        saveRecord(mf.name, %*{"name": mf.name, "repo": rec{"repo"}.getStr(""),
                               "ref": branch, "dir": dest, "version": mf.version,
                               "components": rec{"components"},
                               "addedAt": rec{"addedAt"}.getFloat(epochTime())})
      except CatchableError:
        discard
    else:
      try:
        let mf = readManifest(dest)
        if mf.manifestVersion == 1: writeGoWork(dest, mf)
      except CatchableError:
        discard
    return okResult(%*{"updated": false, "ref": branch, "commit": after})

  var mf: Manifest
  try:
    mf = readManifest(dest)
  except CatchableError as e:
    return errResult("manifest invalid after pull; old components remain running: " & e.msg,
                     extra = %*{"from": before, "to": after})
  if mf.manifestVersion == 1: writeGoWork(dest, mf)

  let binDir = root() / "var" / "bin"
  let built = buildComponents(mf, dest, binDir)
  if not built.ok:
    return errResult("pulled new commits but build failed; old components remain running",
                     extra = %*{"components": built.items, "from": before, "to": after})
  let removed = removeComps(rec)
  cleanupRuntimes(rec)
  let components = spawnComponents(mf, built.items)
  var installed = 0
  for st in components:
    if st{"spawned"}.getBool(false) or st{"interactive"}.getBool(false):
      inc installed
  if installed == 0:
    return errResult("pulled new commits but no component could be rebuilt",
                     extra = %*{"components": components, "removed": removed,
                                "from": before, "to": after})

  saveRecord(mf.name, %*{"name": mf.name, "repo": rec{"repo"}.getStr(""),
                         "ref": branch, "dir": dest, "version": mf.version,
                         "manifestVersion": mf.manifestVersion,
                         "components": components,
                         "addedAt": rec{"addedAt"}.getFloat(epochTime())})
  return okResult(%*{"updated": true, "ref": branch, "from": before, "to": after,
                     "removed": removed, "components": components})

proc pinsTag(rec: JsonNode): bool =
  ## Does the record's ref name a tag in the install's clone? "Move the pin
  ## to the newer release" only makes sense from tag to tag: a branch pin
  ## (the user asked to track main) must keep following that branch — main
  ## is routinely ahead of the newest release, so repointing it at a tag
  ## would silently *downgrade* the install.
  let dest = rec{"dir"}.getStr("")
  let refName = rec{"ref"}.getStr("")
  if dest.len == 0 or refName.len == 0 or not dirExists(dest): return false
  let (code, _) = runCmd("git -C " & quoteShell(dest) &
                         " rev-parse --verify -q " &
                         quoteShell("refs/tags/" & refName))
  code == 0

proc toPkgs(items: JsonNode): JsonNode =
  ## GitHub search "items" -> compact package list (repo, description,
  ## stars, url) for plugin_search.
  result = newJArray()
  if items == nil: return
  for item in items:
    result.add(%*{"repo": item{"full_name"}.getStr(""),
                  "description": item{"description"}.getStr(""),
                  "stars": item{"stargazers_count"}.getInt(0),
                  "url": item{"html_url"}.getStr("")})

# --------------------------------------------------------------------------
# tools

comp.tool(%*{"onDemand": true}):
  proc plugin_search(query: string = ""): JsonNode =
    ## Search GitHub for installable Niffler component packages. The
    ## community publishes them as repos tagged with the topic
    ## "niffler-component", so this needs no registry. Use this when the
    ## user asks what extra capabilities exist, then present the results
    ## and let the user pick before calling plugin_install.
    ## - query: Keywords to narrow the search (e.g. "weather"); empty lists all known packages
    ##
    ## Matching is GitHub's, not ours: space-separated words are ANDed
    ## against each repo's name, description and topics, so "stock price
    ## quote" matches only repos containing ALL three words — one fluffy
    ## word zeroes the result set. Prefer 1-3 broad keywords or synonyms
    ## ("stocks" beats "stock price quote"). A multi-word query with zero
    ## hits is retried automatically: last word dropped repeatedly, then
    ## each word alone (first query with hits wins). The response lists
    ## every query tried in "attempts", the winning one in "query", and
    ## sets "note" when results come from a relaxed query.
    const maxCalls = 6    # stay clear of GitHub's 10 searches/min (anon)
    let client = ghClient()
    defer: client.close()

    var calls = 0
    var tried: seq[JsonNode] = @[]  # one entry per query actually sent
    var items: JsonNode             # search "items" of the first query with hits
    var hitQuery = ""               # the query that produced them
    var apiErr = ""                 # first transport/API error, if any

    proc doSearch(terms: seq[string]): int =
      ## One GitHub call: returns its total_count (-1 on error), records
      ## the attempt, and captures the first query that returns hits.
      inc calls
      let q = "topic:" & topic &
              (if terms.len > 0: " " & terms.join(" ") else: "")
      try:
        let resp = client.getContent(
          githubApi & "/search/repositories?q=" & encodeUrl(q) &
          "&per_page=20&sort=stars").parseJson()
        let n = resp{"total_count"}.getInt(0)
        tried.add(%*{"query": q, "results": n})
        if n > 0 and items == nil:
          items = resp{"items"}
          hitQuery = q
        return n
      except CatchableError as e:
        apiErr = e.msg
        tried.add(%*{"query": q, "error": e.msg})
        return -1

    let words = query.strip().splitWhitespace()
    let fullQuery = "topic:" & topic &
                    (if words.len > 0: " " & words.join(" ") else: "")

    if words.len <= 1:
      discard doSearch(words)
    else:
      # AND semantics mean each extra word can only shrink the set: drop
      # the last word and retry until one word remains or something hits.
      var w = words
      var count = doSearch(w)
      while count == 0 and w.len > 1 and calls < maxCalls and apiErr.len == 0:
        w = w[0 ..< w.high]
        count = doSearch(w)
      # Still nothing: the key word may sit mid-sentence ("weather berlin"
      # would stop at generic "weather" matches above). Sweep single words,
      # skipping the one already tried alone as the final prefix.
      if count == 0 and apiErr.len == 0:
        for term in words:
          if calls >= maxCalls or apiErr.len > 0: break
          if w.len == 1 and w[0] == term: continue
          if doSearch(@[term]) > 0: break

    if items == nil:
      var err = "no packages found"
      if apiErr.len > 0:
        err = "GitHub search failed: " & apiErr
      return errResult(err, extra = %*{"attempts": tried})

    var res = okResult(%*{"packages": toPkgs(items),
                          "query": hitQuery, "attempts": tried,
                          "hint": "install with plugin_install {repo: \"owner/name\"}"})
    if hitQuery != fullQuery:
      res["note"] = %("GitHub ANDs all query words against name, description and topics; '" &
        fullQuery & "' matched 0 results, so these come from the relaxed query in 'query'")
    return res


comp.tool(%*{"onDemand": true}):
  proc plugin_installed(): JsonNode =
    ## List the third-party component packages installed on this harness
    ## (name, repo, pinned ref, current checkout commit, and the components
    ## each provides). Use this to answer "what plugins do we have?" and to
    ## find the package name for plugin_update / plugin_remove.
    var pkgs = newJArray()
    for item in comp.storeList("plugin", "", 100, 10_000):
      # Store records carry no commit field: derive it from the checkout
      # at read time so /status and other clients get truthful provenance
      # without requiring a reinstall or a store migration.
      var value = item.value
      let dir = value{"dir"}.getStr("")
      if dir.len > 0 and dirExists(dir):
        let rev = runCmd("git -C " & quoteShell(dir) & " rev-parse HEAD", 15_000)
        if rev.code == 0 and rev.output.strip().len > 0:
          value["commit"] = %rev.output.strip()
      pkgs.add(value)
    return okResult(%*{"packages": pkgs})


comp.tool(%*{"approval": "always", "timeoutMs": 600000, "onDemand": true}):
  proc plugin_install(repo: string, version: string = ""): JsonNode =
    ## Install a community component package from GitHub: clones the repo
    ## into var/plugins (pinned to version, else the latest release tag,
    ## else the highest version tag, else the default branch), compiles
    ## every component from source via the builder component, then spawns
    ## each service component — every spawn asks the human for separate
    ## approval. Manifest components with interactive:true are built but not
    ## spawned; the user starts their binary in a terminal. Discover packages
    ## with plugin_search first whenever possible; installs run third-party
    ## code on this machine (source builds, so exactly the published code).
    ## - repo: "owner/name" or a github.com URL, e.g. "gokr/niffler-weather"
    ## - version: Git tag or branch to install (empty = latest release, else default branch)
    if findExe("git").len == 0:
      return errResult("git not found on PATH")
    let cleanRepo = normalizeRepo(repo)
    if pluginRecord(repoSlug(cleanRepo)) != nil:
      return errResult("already installed: " & repoSlug(cleanRepo) &
                       " — use plugin_update for a newer version, or plugin_remove first")
    let r = doInstall(cleanRepo, version)
    if not r{"ok"}.getBool(false): return r
    r["note"] = %"service components restart on harness boot; interactive components must be started manually"
    return r


comp.tool(%*{"approval": "always", "timeoutMs": 600000, "onDemand": true}):
  proc plugin_update(package: string): JsonNode =
    ## Update an installed package. When a tag-pinned install has a newer
    ## release tag — or, on a repo that publishes no releases, a newer
    ## version tag — the pin moves to it: the current components are removed
    ## and reinstalled fresh at the new tag (each service removal and spawn
    ## asks the human for approval). A branch pin (or a refless file://
    ## install) instead follows its branch in place, in-place
    ## `git pull --ff-only` on the existing clone, and only rebuilds
    ## components when the pull actually moved HEAD; a no-op pull is
    ## reported without touching any component. Local file:// installs are
    ## the same branch case with the branch read from the clone itself (they
    ## never record a ref).
    ## Interactive components are rebuilt but not started.
    ## Reports updated:false when there was nothing new (latest release
    ## already pinned, or the branch pull was a no-op).
    ## - package: Installed package name (see plugin_installed)
    let rec = pluginRecord(package)
    if rec == nil:
      return errResult("package not installed: " & package &
                       " — see plugin_installed")
    let repo = rec{"repo"}.getStr("")
    # Local file:// repos have no GitHub releases; skip the API round-trip
    # (offline it would hang resolveTag's client for its full timeout).
    let latest = if repo.startsWith("file://"): "" else: resolveTag(repo)
    if latest.len == 0 or not pinsTag(rec):
      return doUpdateBranch(package, rec)
    if latest == rec{"ref"}.getStr(""):
      let dir = rec{"dir"}.getStr("")
      if dir.len > 0 and dirExists(dir):
        try:
          let mf = readManifest(dir)
          if mf.manifestVersion == 1: writeGoWork(dir, mf)
        except CatchableError:
          discard
      return okResult(%*{"updated": false, "ref": latest})
    # doInstall builds the new checkout before removing the old components.
    # If any recipe fails, the old record and live processes remain intact.
    let r = doInstall(repo, latest, replacing = rec)
    if not r{"ok"}.getBool(false):
      return errResult("update failed; old package remains installed",
                       extra = %*{"detail": r})
    if dirExists(rec{"dir"}.getStr("")):
      removeDir(rec{"dir"}.getStr(""))
    return okResult(%*{"updated": true, "from": rec{"ref"}.getStr(""),
                       "to": latest, "install": r})


comp.tool(%*{"approval": "always", "timeoutMs": 300000, "onDemand": true}):
  proc plugin_remove(package: string): JsonNode =
    ## Uninstall a package: core.remove each supervised component (they will
    ## not come back on the next boot), delete the local clone and drop the
    ## install record. Interactive clients are not supervised; stop any live
    ## terminal process manually. Each service removal asks for approval.
    ## - package: Installed package name (see plugin_installed)
    let rec = pluginRecord(package)
    if rec == nil:
      return errResult("package not installed: " & package)
    let removed = removeComps(rec)
    cleanupArtifacts(rec)
    let dir = rec{"dir"}.getStr("")
    if dir.len > 0 and dirExists(dir):
      removeDir(dir)
    try:
      dropRecord(package)
    except CatchableError as e:
      return okResult(%*{"removed": removed,
                         "warning": "record not deleted (store down?): " & e.msg})
    return okResult(%*{"package": package, "removed": removed})


# --------------------------------------------------------------------------
# slash commands (docs/WIRE.md — declarative UI surface)
#
# Names share ONE global namespace (core rejects duplicates), so every
# command is prefixed with the registering component's name — the same
# convention the MCP bridge uses (mcp-<server>-<prompt>). Generic words
# like /install would collide with another package's command and the loser
# would be silently unregistered.

discard comp.slashCommand("plugins", "List installed component packages",
  tool = "plugin_installed")

discard comp.slashCommand("plugins-search",
  "Search GitHub for installable component packages",
  parseJson("""
    [{"name": "query", "kind": "string", "default": "",
      "description": "search words, e.g. weather"}]
  """), tool = "plugin_search")

discard comp.slashCommand("plugins-install",
  "Install a package (built from source; asks approval)",
  parseJson("""
    [{"name": "repo", "kind": "string",
      "description": "owner/name, a github.com URL, or file://path"},
     {"name": "version", "kind": "string", "default": "",
      "description": "tag or branch (empty: latest release, else default branch)"}]
  """), tool = "plugin_install")

let packageParam = parseJson("""
  [{"name": "package", "kind": "string",
    "description": "installed package name (see /plugins)"}]
""")

discard comp.slashCommand("plugins-update",
  "Update an installed package in place (asks approval)",
  packageParam, tool = "plugin_update")

discard comp.slashCommand("plugins-remove",
  "Uninstall a package and delete its clone (asks approval)",
  packageParam, tool = "plugin_remove")

comp.run()
