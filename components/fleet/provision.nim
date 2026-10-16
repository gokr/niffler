## Fleet policy and command generation. The runner seam allows transport-free tests.
import std/[json, os, strutils, posix, tempfiles, times]
import niffler/procutil

type
  Refusal* = object of CatchableError
  CommandResult* = object
    code*: int
    output*, logPath*: string
  CommandRunner* = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult {.closure.}

proc refuse(message: string) {.noreturn.} = raise newException(Refusal, message)

proc nativeRunner*(argv: seq[string], input: string, timeoutMs: int): CommandResult =
  ## No shell joining; stderr is private and never mixed into catalog JSON.
  let scratch = getEnv("NIF_ROOT", getCurrentDir()) / "var" / "fleet" / "transport"
  createDir(scratch)
  setFilePermissions(scratch, {fpUserRead, fpUserWrite, fpUserExec})
  let (inf, inp) = createTempFile("in-", "", scratch)
  let (outf, outp) = createTempFile("out-", ".log", scratch)
  let (errf, errp) = createTempFile("err-", ".log", scratch)
  result.logPath = errp
  defer:
    inf.close(); outf.close(); errf.close()
    removeFile(inp)
    # Private stdout/stderr logs survive for debugging, never inserted into errors.
  for f in [inf, outf, errf]:
    if fchmod(cint(getFileHandle(f)), Mode(0o600)) != 0: refuse("cannot secure transport files")
  inf.write(input); inf.flushFile(); setFilePos(inf, 0)
  let args = allocCStringArray(argv)
  defer: deallocCStringArray(args)
  cloexecInheritedFds()
  let pid = fork()
  if pid == 0:
    discard setpgid(0, 0)
    discard dup2(cint(getFileHandle(inf)), 0)
    discard dup2(cint(getFileHandle(outf)), 1)
    discard dup2(cint(getFileHandle(errf)), 2)
    discard execvp(args[0], args)
    exitnow(127)
  if pid < 0: refuse("cannot launch transport")
  let deadline = epochTime() + timeoutMs.float / 1000
  var status: cint
  var reaped = false
  while epochTime() < deadline:
    if waitpid(pid, status, WNOHANG) == pid:
      reaped = true
      break
    sleep(20)
  if not reaped:
    killGroup(pid, SIGKILL)
    discard waitpid(pid, status, 0)
    result.code = 124
    return
  result.code = if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128 + int(WTERMSIG(status))
  const maxOutput = 8 * 1024 * 1024
  if getFileSize(outp) > maxOutput:
    result.code = 125
    return
  result.output = readFile(outp)

proc checked(run: CommandRunner, argv: seq[string], input = "", timeoutMs = 60000): string =
  let r = run(argv, input, timeoutMs)
  if r.code != 0:
    let reason = if r.code == 124: "transport timeout"
      elif r.code == 125: "transport output exceeds 8 MiB"
      else: "command failed (" & argv[0] & "), exit " & $r.code
    refuse(reason & (if r.logPath.len > 0: "; private stderr log: " & r.logPath else: ""))
  r.output

proc hex(s: string, size: int): bool = s.len == size and s.allCharsInSet({'0'..'9', 'a'..'f'})
proc validateRoot*(root: string) =
  if root.len < 2 or root[0] != '/' or not root.allCharsInSet({'a'..'z','A'..'Z','0'..'9','_','.','/','-'}): refuse("invalid root")
  for part in root[1..^1].split('/'):
    if part in ["", ".", ".."]: refuse("root must be a dedicated canonical installation path")

proc validateTarget(transport, target: string) =
  if transport notin ["ssh", "multipass"]: refuse("unsupported transport")
  if target.len == 0 or target[0] notin {'a'..'z','A'..'Z','0'..'9','_'} or
      not target.allCharsInSet({'a'..'z','A'..'Z','0'..'9','_','.','@','-'}): refuse("invalid target")
  if transport == "multipass" and (target[0] notin {'a'..'z','A'..'Z'} or
      not target.allCharsInSet({'a'..'z','A'..'Z','0'..'9','-'})): refuse("invalid VM name")

proc validateProfile*(p: JsonNode) =
  try:
    if p.kind != JObject or p{"version"}.getInt() != 1: refuse("unsupported receipt version")
    validateRoot(p{"root"}.getStr())
    validateTarget(p{"transport"}.getStr(), p{"target"}.getStr())
    let e = p{"expect"}
    if e == nil or e.kind != JObject or not hex(e{"instanceId"}.getStr(), 32): refuse("invalid receipt identity")
    for key in ["name", "root", "gitHash"]:
      if e{key} == nil or e{key}.kind != JString: refuse("malformed receipt expectation")
    if e{"root"}.getStr() != p{"root"}.getStr(): refuse("receipt root mismatch")
    if p.hasKey("createdVm") and p["createdVm"].kind != JBool: refuse("invalid VM provenance")
  except Refusal: raise
  except CatchableError: refuse("malformed receipt")

proc receiptPath*(path: string): string =
  if path.len == 0: refuse("profile path required")
  absolutePath(expandTilde(path))

proc loadReceipt*(path: string): JsonNode =
  if symlinkExists(path): refuse("profile must not be a symlink")
  if not fileExists(path):
    if dirExists(path): refuse("profile is a directory")
    return nil
  try:
    result = parseFile(path)
    validateProfile(result)
  except Refusal: raise
  except CatchableError: refuse("malformed receipt")

proc saveReceipt*(path: string, p: JsonNode) =
  validateProfile(p)
  if symlinkExists(path): refuse("profile must not be a symlink")
  createDir(path.parentDir)
  let (f, staged) = createTempFile(".fleet-", "", path.parentDir)
  var closed = false
  try:
    if fchmod(cint(getFileHandle(f)), Mode(0o600)) != 0: refuse("cannot secure receipt")
    f.write(p.pretty() & "\n"); f.flushFile()
    if fsync(cint(getFileHandle(f))) != 0: refuse("cannot flush receipt")
    f.close(); closed = true
    if symlinkExists(path): refuse("profile must not be a symlink")
    moveFile(staged, path)
  finally:
    if not closed: f.close()
    if fileExists(staged): removeFile(staged)

proc remote*(run: CommandRunner, p: JsonNode, script: string, timeoutMs = 60000): string =
  let target = p["target"].getStr()
  let argv = if p["transport"].getStr() == "ssh":
      @["ssh", "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15", "--", target, "bash -s"]
    else: @["multipass", "exec", target, "--", "bash", "-s"]
  checked(run, argv, "set -euo pipefail\n" & script, timeoutMs)

proc probe*(run: CommandRunner, p: JsonNode): JsonNode =
  let output = remote(run, p, "root=" & quoteShell(p["root"].getStr()) & "\n" & """
url=$(< "$root/var/nats-url")
[[ "$url" =~ ^nats://127\.0\.0\.1:[0-9]+$ ]] || { echo 'not a loopback endpoint' >&2; exit 1; }
"$root/var/bin/cli" --bus "$url" call catalog '{"op":"components"}'
""")
  try:
    var identity = parseJson(output)
    if identity.hasKey("args"): identity = identity["args"]
    if not hex(identity{"instanceId"}.getStr(), 32): refuse("invalid catalog identity")
    if identity{"root"}.getStr() != p["root"].getStr(): refuse("catalog root mismatch; refusing remote writes")
    if p.hasKey("expect") and identity{"instanceId"}.getStr() != p["expect"]["instanceId"].getStr(): refuse("instance identity mismatch; refusing remote writes")
    result = newJObject()
    for key in ["instanceId", "name", "root", "gitHash"]:
      if identity{key} == nil or identity{key}.kind != JString: refuse("invalid catalog response")
      result[key] = identity[key]
  except Refusal: raise
  except CatchableError: refuse("invalid catalog response; profile not saved")

proc guard*(p: JsonNode): string =
  "[[ \"$(< " & quoteShell(p["root"].getStr()) & "/var/instance-id)\" == \"" & p["expect"]["instanceId"].getStr() & "\" ]] || { echo 'identity mismatch' >&2; exit 1; }\n"

const serviceEnv = """
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
"""

proc installScript*(root, revision: string): string =
  validateRoot(root)
  if not hex(revision, 40): refuse("full 40-character pinned revision required")
  result = "root=" & quoteShell(root) & "\nrevision=" & revision & "\n" & """
export PATH="$HOME/.nimble/bin:/usr/local/bin:$PATH"
[[ ! -L "$root" ]] || { echo 'symlinked root: refusing' >&2; exit 1; }
if [[ -e "$root" ]]; then
  [[ -f "$root/niffler.nimble" && -x "$root/var/bin/niffler" && -f "$root/scripts/server.sh" ]] || { echo 'existing incomplete/unrelated root: refusing overwrite' >&2; exit 1; }
  echo 'Adopting existing installation without updating' >&2
else
  command -v git >/dev/null || { echo 'Install git on target first' >&2; exit 1; }
  git clone --no-checkout https://github.com/gokr/niffler.git "$root"
  git -C "$root" fetch origin "$revision"
  git -C "$root" checkout --detach "$revision"
  [[ "$(git -C "$root" rev-parse HEAD)" == "$revision" ]] || exit 1
  cd "$(dirname "$root")"
  bash "$root/scripts/bootstrap.sh" --server "$root"
fi
""" & serviceEnv & """
bash "$root/scripts/server.sh" install "$root"
bash "$root/scripts/server.sh" start "$root"
"""

proc vmInfo(run: CommandRunner, target: string): JsonNode =
  try:
    let data = parseJson(checked(run, @["multipass", "list", "--format", "json"]))
    if data{"list"} == nil or data["list"].kind != JArray: refuse("invalid VM list")
    for vm in data["list"]:
      if vm{"name"}.getStr() == target: return vm
  except Refusal: raise
  except CatchableError: refuse("invalid VM list")

proc install*(run: CommandRunner, args: JsonNode): JsonNode =
  let path = receiptPath(args{"profile"}.getStr())
  let previous = loadReceipt(path)
  let transport = args{"transport"}.getStr()
  let target = args{"target"}.getStr()
  let root = args{"root"}.getStr()
  let revision = args{"revision"}.getStr()
  validateTarget(transport, target); validateRoot(root)
  if not hex(revision, 40): refuse("full 40-character pinned revision required")
  let cpus = args{"cpus"}.getInt(2)
  let memory = args{"memory"}.getStr("4G")
  let disk = args{"disk"}.getStr("20G")
  if cpus < 1 or cpus > 64: refuse("CPUs must be 1..64")
  for size in [memory, disk]:
    if size.len < 2 or size[^1] notin {'M','G'} or size[0] notin {'1'..'9'} or not size[0..^2].allCharsInSet({'0'..'9'}): refuse("invalid VM resource size")
  var p = %*{"version": 1, "transport": transport, "target": target, "root": root}
  if previous != nil:
    for key in ["transport", "target", "root"]:
      if previous[key] != p[key]: refuse("profile already belongs to a different target")
    p = previous
  let vm = if transport == "multipass": vmInfo(run, target) else: nil
  if previous != nil and transport == "multipass" and vm == nil: refuse("pinned VM is missing; refusing to recreate a different instance")
  # Never start a pinned VM before identity verification. A stopped pinned VM
  # must first be started explicitly by its administrator.
  if previous != nil:
    discard remote(run, p, guard(p))
    try: discard probe(run, p)
    except Refusal as e:
      if "mismatch" in e.msg or "invalid catalog" in e.msg: raise
  if transport == "multipass":
    if vm == nil:
      discard checked(run, @["multipass", "launch", "24.04", "--name", target, "--cpus", $cpus, "--memory", memory, "--disk", disk], timeoutMs = 600000)
      p["createdVm"] = %true
    elif vm{"state"}.getStr() != "Running":
      discard checked(run, @["multipass", "start", target], timeoutMs = 180000)
  discard remote(run, p, (if previous != nil: guard(p) else: "") & installScript(root, revision), 3600000)
  var verified = false
  for attempt in 0..<30:
    try:
      p["expect"] = probe(run, p)
      verified = true
      break
    except Refusal as e:
      if "mismatch" in e.msg or "invalid catalog" in e.msg: raise
      if attempt < 29: sleep(1000)
  if not verified: refuse("service did not verify; profile not saved")
  saveReceipt(path, p)
  %*{"profile": path, "receipt": p, "text": "Verified receipt saved; provider configuration and linger remain explicit."}

proc action*(run: CommandRunner, name, profile: string): JsonNode =
  let p = loadReceipt(receiptPath(profile))
  if p == nil: refuse("verified profile required")
  if name == "probe": return probe(run, p)
  if name == "vm_stop":
    if p["transport"].getStr() != "multipass": refuse("not a Multipass profile")
    discard remote(run, p, guard(p))
    discard probe(run, p)
    discard checked(run, @["multipass", "stop", p["target"].getStr()], timeoutMs = 180000)
    return %*{"ok": true, "text": "VM stopped; not deleted."}
  if name notin ["start", "stop", "status", "logs"]: refuse("unsupported Fleet action")
  let root = quoteShell(p["root"].getStr())
  let output = remote(run, p, guard(p) & serviceEnv & "bash " & root & "/scripts/server.sh " & name & " " & root & "\n")
  %*{"ok": true, "text": capBytes(output, 65536)}
