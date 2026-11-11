## Opt-in shell guard. Policy comes from runner-owned workspace context or an
## operator-configured direct-call root, never from the command's cwd alone.
import std/[os, json, strutils]

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
  let policyAsked = geop != nil and geop.kind == JObject and
                    geop{"enabled"}.getBool(false)
  let setting = getEnv("NIF_BASH_SANDBOX", "off")
  if setting == "off" and not policyAsked: return
  if setting != "off" and setting != "on":
    raise newException(ValueError, "NIF_BASH_SANDBOX must be off or on")
  result.enabled = true
  let workspace = args{"__workspace"}{"root"}.getStr(
    getEnv("NIF_BASH_SANDBOX_ROOT", ""))
  if workspace.len == 0:
    raise newException(ValueError, "guarded bash needs runner workspace context or NIF_BASH_SANDBOX_ROOT")
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
    let requested = getEnv("NIF_SANDBOX_STRICT", "").strip()
    argv.add @["--reach", (if requested in ["strict", "compat"]: requested
                           else: "strict")]
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
  for path in getEnv("NIF_BASH_SANDBOX_MASKS", "").splitLines():
    if path.strip().len > 0:
      let p = path.strip()
      argv.add @["--mask", (if p.isAbsolute(): p else: workspace / p)]
  argv.add @["--", "/bin/bash", "--noprofile", "--norc", "-c", command]
  result.command = "exec "
  for i, arg in argv:
    if i > 0: result.command.add " "
    result.command.add quoteShell(arg)
