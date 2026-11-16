## Opt-in shell guard. Policy comes from runner-owned workspace context or an
## operator-configured direct-call root, never from the command's cwd alone.
import std/[os, json, strutils]
import niffler/procutil

proc normalizePath*(path: string): string =
  ## Trailing-slash-insensitive comparison form. Deliberately does NOT resolve
  ## symlinks: the launcher canonicalizes for real, and doing it twice would
  ## mean this file could disagree with it.
  result = path.strip()
  while result.len > 1 and result.endsWith("/"): result.setLen(result.len - 1)

type GuardedCommand* = object
  command*: string
  enabled*: bool
  statusFile*: string

const MaxDenyScan = 200_000
  ## Bound on the deny-rule traversal. Past this the launch refuses: a walk we
  ## did not finish cannot be reported as "no denied file present".

proc policyDenyMasks*(workspace: string, roots: seq[string],
                      patterns: seq[string]): seq[string] =
  ## Resolve exact-basename deny patterns to the concrete files the launcher
  ## can mask. Only basename equality is supported: a glob or a path pattern
  ## refuses instead of masking nothing and reporting protection it does not
  ## provide. `.env` therefore does not widen to `.envrc` or `x.env`.
  for p in patterns:
    if p.len == 0 or p == "." or p == ".." or p.contains('/') or
        p.contains('\\'):
      raise newException(ValueError,
        "unsupported sandbox deny pattern (basename only): " & p)
    for c in p:
      if c in {'*', '?', '[', ']'}:
        raise newException(ValueError,
          "unsupported sandbox deny pattern (no globbing): " & p)
  var dirs: seq[string] = @[]
  for root in roots:
    if root.len > 0 and root.isAbsolute() and root notin dirs: dirs.add root
  var scanned = 0
  for dir in dirs:
    if not dirExists(dir): continue
    try:
      for path in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile}):
        inc scanned
        if scanned > MaxDenyScan:
          raise newException(ValueError,
            "workspace too large to enumerate sandbox deny rules")
        if path.extractFilename in patterns and path notin result:
          result.add path
    except OSError as e:
      raise newException(ValueError,
        "cannot enumerate " & dir & " to apply sandbox deny rules: " & e.msg)

proc guardCommand*(args: JsonNode, command: string,
                   statusFile: string): GuardedCommand =
  ## Decide whether THIS command runs through the launcher, and with what reach.
  ##
  ## Two independent sources can ask for the guard, and they are not the same
  ## authority:
  ##
  ## - the operator's environment (`NIF_BASH_SANDBOX=on`) — applies to every
  ##   conversation on this harness, the pre-conversation behaviour;
  ## - the CONVERSATION's own policy (`__sandbox.enabled`, injected by core from
  ##   the human's `session {sandbox}` decision) — applies to this
  ##   conversation only.
  ##
  ## The conversation policy widens nothing: it can turn the guard ON for itself
  ## and name its approved writable roots, and it can never turn off an operator
  ## who asked for it. Reach is decided per launch below (a policy-driven launch
  ## takes the full promise; an env-driven one keeps compat unless the operator
  ## raises NIF_SANDBOX_STRICT).
  result.command = command
  result.statusFile = statusFile
  let geop = args{"__sandbox"}
  if geop != nil and (geop.kind != JObject or geop{"unreadable"}.getBool(false)):
    raise newException(ValueError, "sandbox policy is unreadable; refusing bash")
  let policyAsked = geop != nil and geop.kind == JObject and
                    geop{"enabled"}.getBool(false)
  var denyPatterns: seq[string] = @[]
  # Deny patterns are enforced as exact-path masks; read-only roots still have
  # no launcher vocabulary, so those refuse rather than run wider than asked.
  if policyAsked:
    if geop{"denyPatterns"} == nil or geop{"denyPatterns"}.kind != JArray:
      raise newException(ValueError, "sandbox deny patterns are unreadable")
    for p in geop{"denyPatterns"}:
      if p.kind != JString:
        raise newException(ValueError, "sandbox deny patterns must be strings")
      denyPatterns.add p.getStr("").strip()
    if geop{"readRoots"} == nil or geop{"readRoots"}.kind != JArray or
        geop{"writeRoots"} == nil or geop{"writeRoots"}.kind != JArray:
      raise newException(ValueError, "sandbox roots are unreadable")
    for readRoot in geop{"readRoots"}:
      var writable = false
      for writeRoot in geop{"writeRoots"}:
        if readRoot.kind == JString and writeRoot.kind == JString and
            normalizePath(readRoot.getStr()) == normalizePath(writeRoot.getStr()):
          writable = true
      if not writable:
        raise newException(ValueError,
          "read-only sandbox roots are not supported by the bash guard")
  let setting = getEnv("NIF_BASH_SANDBOX", "off")
  if setting == "off" and not policyAsked: return
  if setting != "off" and setting != "on":
    raise newException(ValueError, "NIF_BASH_SANDBOX must be off or on")
  result.enabled = true
  let workspace = args{"__workspace"}{"root"}.getStr(
    getEnv("NIF_BASH_SANDBOX_ROOT", ""))
  if workspace.len == 0:
    raise newException(ValueError, "guarded bash needs runner workspace context or NIF_BASH_SANDBOX_ROOT")
  if policyAsked:
    # The launcher always mounts workspace writable. Cwd/workspace context is
    # not itself a policy grant, so check the resolved path before launching.
    # realPathOf follows symlinks AND tolerates a tail that does not exist yet;
    # expandFilename raises on that, turning a policy check into an OS error.
    let resolvedWorkspace = realPathOf(workspace)
    var allowed = false
    for root in geop{"writeRoots"}:
      if root.kind != JString or not root.getStr().isAbsolute():
        raise newException(ValueError, "invalid sandbox write root")
      let resolvedRoot = realPathOf(root.getStr())
      if resolvedWorkspace == resolvedRoot or
          resolvedWorkspace.startsWith(resolvedRoot & DirSep):
        allowed = true
    if not allowed:
      raise newException(ValueError, "workspace is outside sandbox write roots")
  # Do not silently return an unrestricted background process before reporting
  # sandbox startup. Integrate its startup evidence with processes separately.
  if args{"run_in_background"}.getBool(false):
    raise newException(ValueError, "guarded background execution is not supported yet; run synchronously")
  if getEnv("NIF_BASH_SANDBOX_MAP", "").len > 0:
    raise newException(ValueError, "shell guard cannot be combined with the benchmark container map yet")
  let helper = getAppDir() / "niffler-sandbox"
  if not fileExists(helper):
    raise newException(ValueError, "sandbox launcher missing; run make build")
  var argv = @[helper, "run", "--workspace", workspace,
               "--cwd", args{"cwd"}.getStr(workspace)]
  if statusFile.len > 0: argv.add @["--status-file", statusFile]
  # A command the CONVERSATION's policy asked to confine gets the full promise
  # by default: the policy's whole point is that it can only see its own trees.
  # An operator's env-driven guard keeps the historical compat reach, because
  # changing that silently would break toolchains the operator already runs —
  # NIF_SANDBOX_STRICT is theirs to raise.
  if policyAsked:
    # The GUARD decides the reach, not the injected document: `__sandbox` is a
    # policy record and carries no launcher vocabulary, so reading a "reach"
    # field out of it produced an empty string and every launch refused. The
    # operator's NIF_SANDBOX_STRICT is honoured if set; otherwise a
    # conversation that asked to be confined gets the full promise, which is
    # the only reach that makes the policy's own roots meaningful.
    # Conversation policy explicitly requests confinement. An ambient compat
    # setting must not silently weaken it to a host-readable launch.
    argv.add @["--reach", "strict"]
  # Approved WRITABLE roots from the conversation's policy. Write roots only:
  # a read-only approval is not a write allowance, and handing it to the
  # launcher as --allow would silently grant write — the same conflation the
  # policy document refuses to make.
  if policyAsked and geop{"writeRoots"} != nil and
      geop{"writeRoots"}.kind == JArray:
    let wsNorm = normalizePath(workspace)
    for r in geop{"writeRoots"}:
      if r.kind != JString: continue
      let p = r.getStr("").strip()
      # The workspace is already bound; passing it again is harmless but noisy,
      # and a path outside the policy must never arrive here at all.
      if p.len == 0 or not p.isAbsolute() or normalizePath(p) == wsNorm: continue
      argv.add @["--allow", p]
  # Operator-owned exact paths, one per line. A missing configured secret
  # refuses rather than silently omitting protection. No filename heuristics.
  if policyAsked and denyPatterns.len > 0:
    var searchRoots: seq[string] = @[workspace]
    for r in geop{"writeRoots"}:
      if r.kind == JString: searchRoots.add r.getStr("")
    for path in policyDenyMasks(workspace, searchRoots, denyPatterns):
      argv.add @["--mask", path]
  for path in getEnv("NIF_BASH_SANDBOX_MASKS", "").splitLines():
    if path.strip().len > 0:
      let p = path.strip()
      argv.add @["--mask", (if p.isAbsolute(): p else: workspace / p)]
  argv.add @["--", "/bin/bash", "--noprofile", "--norc", "-c", command]
  result.command = "exec "
  for i, arg in argv:
    if i > 0: result.command.add " "
    result.command.add quoteShell(arg)
