## plugins component — ecosystem discovery and install, as a bus service.
##
## Third-party components are distributed as plain git repos: one repo = one
## package = N components, described by a niffler.json manifest at the root
## ({"name", "version", "components":
##   [{"name", "lang", "main", "sources"?, "env"?, "interactive"?}]}).
## Discovery is GitHub topic search (topic:niffler-component) — no registry.
##
## Install: shallow clone into var/plugins/<repo>@<ref>/, then build every
## component from source through the builder component (the same path the
## agent uses for its own components — the harness already ships Nim/Go and
## builds its own extensions). Service components are core.spawned;
## interactive components are built for the user to start in a terminal.
## Installed packages are
## recorded in the store (kind "plugin") so plugin_update and plugin_remove
## know their shape. var/ is disposable runtime state; the store record is
## what survives (docs/MANUAL.md).
##
## Requires: git and network access. The GitHub API is used unauthenticated
## (60 req/h/IP — plenty for discovery). Installs run arbitrary third-party
## code: install/update/remove carry x-harness.approval, and core's own
## spawn/remove gate fires per component on top.

import std/[httpclient, json, os, osproc, sequtils, streams, strutils, times, uri]
import niffler/sdk

let comp = newComponent("plugins", "0.1.0")

const githubApi = "https://api.github.com"
const topic = "niffler-component"

proc root(): string = getEnv("NIF_ROOT", ".")

proc ghClient(): HttpClient =
  result = newHttpClient("niffler-plugins/0.1", timeout = 30_000)
  result.headers = newHttpHeaders({"Accept": "application/vnd.github+json"})

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
  ## Latest release tag, or "" when the repo has no releases (or the API
  ## is rate-limited). Fresh client per call: a stale pooled connection
  ## (e.g. a 404 the server already closed) would hang the next read.
  let client = ghClient()
  defer: client.close()
  try:
    let rel = client.getContent(githubApi & "/repos/" & repo &
                                "/releases/latest").parseJson()
    result = rel{"tag_name"}.getStr("")
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
  ## The stored install record, or nil when not installed.
  try:
    let r = comp.request("store", "get", %*{"kind": "plugin", "id": pkg})
    if r{"ok"}.getBool(false):
      return r{"value"}
  except CatchableError:
    discard
  return nil

proc saveRecord(pkg: string, value: JsonNode) =
  discard comp.request("store", "put",
    %*{"kind": "plugin", "id": pkg, "value": value})

proc dropRecord(pkg: string) =
  discard comp.request("store", "del", %*{"kind": "plugin", "id": pkg})

# --------------------------------------------------------------------------
# install / update / remove internals

type
  ManifestComp = tuple[name, lang, main: string, sources, env: seq[string],
                       interactive: bool]
  Manifest = tuple[name, version: string, comps: seq[ManifestComp]]

proc validManifestSourcePath(path: string): bool =
  if path.len == 0 or path.isAbsolute(): return false
  let parts = path.replace('\\', '/').split('/')
  not parts.anyIt(it.len == 0 or it == "." or it == "..")

proc readManifest(dir: string): Manifest =
  let path = dir / "niffler.json"
  if not fileExists(path):
    raise newException(ValueError,
      "no niffler.json in the repo root — is this a component package?")
  let m = readFile(path).parseJson()
  result.name = m{"name"}.getStr("")
  result.version = m{"version"}.getStr("")
  if result.name.len == 0:
    raise newException(ValueError, "niffler.json has no 'name'")
  let comps = m{"components"}
  if comps == nil:
    raise newException(ValueError, "niffler.json has no 'components' array")
  for e in comps:
    var mc: ManifestComp
    mc.name = e{"name"}.getStr("")
    mc.lang = e{"lang"}.getStr("").toLowerAscii()
    mc.main = e{"main"}.getStr("")
    if not validManifestSourcePath(mc.main):
      raise newException(ValueError,
        "niffler.json: invalid component main path '" & mc.main & "'")
    mc.interactive = e{"interactive"}.getBool(false)
    mc.sources = @[]
    let sourcesArr = e{"sources"}
    if sourcesArr != nil:
      if mc.lang != "go" or sourcesArr.kind != JArray:
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
    if mc.name.len == 0 or mc.main.len == 0:
      raise newException(ValueError,
        "niffler.json component entry needs name and main")
    if mc.lang notin ["nim", "go"]:
      raise newException(ValueError,
        "niffler.json: unsupported lang '" & mc.lang & "' for " & mc.name)
    if not fileExists(dir / mc.main) or symlinkExists(dir / mc.main):
      raise newException(ValueError,
        "niffler.json: " & mc.main & " not found or is a symlink for component " & mc.name)
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

proc installComp(mc: ManifestComp, dest, binDir: string): JsonNode =
  ## One component: build from source via the builder component.
  ## Returns a status record; "built" empty means it failed.
  createDir(binDir)
  let binary = binDir / mc.name
  try:
    var buildArgs = %*{"lang": mc.lang, "name": mc.name,
                       "source": readFile(dest / mc.main)}
    if mc.sources.len > 0:
      var files = newJObject()
      for source in mc.sources:
        files[source.extractFilename()] = %readFile(dest / source)
      buildArgs["files"] = files
    let r = comp.request("builder", "build", buildArgs, 320_000)
    if r{"ok"}.getBool(false):
      let absBinary = absolutePath(binary)
      if mc.interactive:
        result = %*{"name": mc.name, "binary": absBinary,
                    "interactive": true, "spawned": false}
      else:
        result = spawnComponent(mc, absBinary)
      result["built"] = %"source"
      if mc.env.len > 0:
        result["env"] = %mc.env
    else:
      result = %*{"name": mc.name, "spawned": false,
                  "error": "build failed: " & r{"error"}.getStr("?").tail(400)}
  except CatchableError as e:
    result = %*{"name": mc.name, "spawned": false,
                "error": "build failed: " & e.msg}

proc doInstall(repo, refArg: string): JsonNode =
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
      return %*{"ok": false, "error": "already installed: " & oldName &
                " — use plugin_update, or plugin_remove first"}
    removeDir(dest)
  createDir(dest.parentDir())
  let url = if local: repo else: "https://github.com/" & repo & ".git"
  let (cout, ccode) = if refTag.len > 0:
    runCmd("git clone --depth 1 --branch " & refTag & " " & url & " " & dest)
  else:
    runCmd("git clone --depth 1 " & url & " " & dest)
  if ccode != 0:
    if dirExists(dest): removeDir(dest)
    return %*{"ok": false, "error": "git clone failed", "output": tail(cout, 800)}

  let mf = readManifest(dest)
  let binDir = root() / "var" / "bin"
  var components = newJArray()
  var installed = 0
  for mc in mf.comps:
    let st = installComp(mc, dest, binDir)
    if st{"spawned"}.getBool(false) or
       (st{"interactive"}.getBool(false) and
        st{"built"}.getStr("").len > 0):
      inc installed
    components.add(st)

  if installed == 0:
    removeDir(dest)
    return %*{"ok": false, "error": "no component could be installed",
              "components": components}

  saveRecord(mf.name, %*{"name": mf.name, "repo": repo, "ref": refTag,
                         "dir": dest, "version": mf.version,
                         "components": components, "addedAt": epochTime()})
  result = %*{"ok": true, "package": mf.name, "repo": repo, "ref": refTag,
              "dir": dest, "components": components}

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

# --------------------------------------------------------------------------
# tools

comp.tool:
  proc plugin_search(query: string = ""): JsonNode =
    ## Search GitHub for installable Niffler component packages. The
    ## community publishes them as repos tagged with the topic
    ## "niffler-component", so this needs no registry. Use this when the
    ## user asks what extra capabilities exist, then present the results
    ## and let the user pick before calling plugin_install.
    ## - query: Keywords to narrow the search (e.g. "weather"); empty lists all known packages
    try:
      let client = ghClient()
      defer: client.close()
      let q = "topic:" & topic &
              (if query.strip().len > 0: " " & query.strip() else: "")
      let resp = client.getContent(
        githubApi & "/search/repositories?q=" & encodeUrl(q) &
        "&per_page=20&sort=stars").parseJson()
      var pkgs = newJArray()
      let items = resp{"items"}
      if items != nil:
        for item in items:
          pkgs.add(%*{"repo": item{"full_name"}.getStr(""),
                      "description": item{"description"}.getStr(""),
                      "stars": item{"stargazers_count"}.getInt(0),
                      "url": item{"html_url"}.getStr("")})
      return %*{"ok": true, "packages": pkgs,
                "hint": "install with plugin_install {repo: \"owner/name\"}"}
    except CatchableError as e:
      return %*{"ok": false, "error": "GitHub search failed: " & e.msg}

comp.tools[^1].schema["x-harness"] = %*{"onDemand": true}

comp.tool:
  proc plugin_installed(): JsonNode =
    ## List the third-party component packages installed on this harness
    ## (name, repo, pinned ref and the components each provides). Use this
    ## to answer "what plugins do we have?" and to find the package name
    ## for plugin_update / plugin_remove.
    let r = comp.request("store", "list", %*{"kind": "plugin"}, 10_000)
    var pkgs = newJArray()
    let items = r{"items"}
    if items != nil:
      for item in items:
        pkgs.add(item{"value"})
    return %*{"ok": true, "packages": pkgs}

comp.tools[^1].schema["x-harness"] = %*{"onDemand": true}

comp.tool:
  proc plugin_install(repo: string, version: string = ""): JsonNode =
    ## Install a community component package from GitHub: clones the repo
    ## into var/plugins (pinned to version, else the latest release tag,
    ## else the default branch), compiles every component from source via
    ## the builder component, then spawns each service component — every
    ## spawn asks the human for separate approval. Manifest components with
    ## interactive:true are built but not spawned; the user starts their
    ## binary in a terminal. Discover packages with plugin_search
    ## first whenever possible; installs run third-party code on this
    ## machine (source builds, so exactly the published code).
    ## - repo: "owner/name" or a github.com URL, e.g. "gokr/niffler-weather"
    ## - version: Git tag or branch to install (empty = latest release, else default branch)
    if findExe("git").len == 0:
      return %*{"ok": false, "error": "git not found on PATH"}
    let cleanRepo = normalizeRepo(repo)
    if pluginRecord(repoSlug(cleanRepo)) != nil:
      return %*{"ok": false, "error": "already installed: " &
                repoSlug(cleanRepo) &
                " — use plugin_update for a newer version, or plugin_remove first"}
    let r = doInstall(cleanRepo, version)
    if not r{"ok"}.getBool(false): return r
    r["note"] = %"service components restart on harness boot; interactive components must be started manually"
    return r

comp.tools[^1].schema["x-harness"] =
  %*{"approval": "always", "timeoutMs": 600000, "onDemand": true}

comp.tool:
  proc plugin_update(package: string): JsonNode =
    ## Update an installed package to its latest release tag: removes its
    ## current components and reinstalls at the new ref (each service removal
    ## and spawn asks the human for approval). Interactive components are
    ## rebuilt but not started. Reports updated:false when the
    ## pinned ref is already the latest release.
    ## - package: Installed package name (see plugin_installed)
    let rec = pluginRecord(package)
    if rec == nil:
      return %*{"ok": false, "error": "package not installed: " & package &
                " — see plugin_installed"}
    let repo = rec{"repo"}.getStr("")
    let latest = resolveTag(repo)
    if latest.len == 0:
      return %*{"ok": false, "error": "repo " & repo &
                " has no releases — cannot update beyond " &
                rec{"ref"}.getStr("")}
    if latest == rec{"ref"}.getStr(""):
      return %*{"ok": true, "updated": false, "ref": latest}
    let removed = removeComps(rec)
    if dirExists(rec{"dir"}.getStr("")):
      removeDir(rec{"dir"}.getStr(""))
    let r = doInstall(repo, latest)
    if not r{"ok"}.getBool(false):
      dropRecord(package)
      return %*{"ok": false, "error": "update failed; package removed",
                "removed": removed, "detail": r}
    return %*{"ok": true, "updated": true, "from": rec{"ref"}.getStr(""),
              "to": latest, "removed": removed, "install": r}

comp.tools[^1].schema["x-harness"] =
  %*{"approval": "always", "timeoutMs": 600000, "onDemand": true}

comp.tool:
  proc plugin_remove(package: string): JsonNode =
    ## Uninstall a package: core.remove each supervised component (they will
    ## not come back on the next boot), delete the local clone and drop the
    ## install record. Interactive clients are not supervised; stop any live
    ## terminal process manually. Each service removal asks for approval.
    ## - package: Installed package name (see plugin_installed)
    let rec = pluginRecord(package)
    if rec == nil:
      return %*{"ok": false, "error": "package not installed: " & package}
    let removed = removeComps(rec)
    let dir = rec{"dir"}.getStr("")
    if dir.len > 0 and dirExists(dir):
      removeDir(dir)
    try:
      dropRecord(package)
    except CatchableError as e:
      return %*{"ok": true, "removed": removed,
                "warning": "record not deleted (store down?): " & e.msg}
    return %*{"ok": true, "package": package, "removed": removed}

comp.tools[^1].schema["x-harness"] =
  %*{"approval": "always", "timeoutMs": 300000, "onDemand": true}

comp.run()
