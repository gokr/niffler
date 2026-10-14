## Opt-in shell guard. Policy comes from runner-owned workspace context or an
## operator-configured direct-call root, never from the command's cwd alone.
import std/[os, json, strutils]

type GuardedCommand* = object
  command*: string
  enabled*: bool
  statusFile*: string

proc guardCommand*(args: JsonNode, command: string,
                   statusFile: string): GuardedCommand =
  result.command = command
  result.statusFile = statusFile
  let setting = getEnv("NIF_BASH_SANDBOX", "off")
  if setting == "off": return
  if setting != "on":
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
