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

proc nativeRunnerWithWait*(argv: seq[string], input: string, timeoutMs: int,
                           onWait: proc() {.closure.}): CommandResult =
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
  let expectedParent = getpid()
  let pid = fork()
  if pid == 0:
    when defined(linux):
      proc prctl(option: cint): cint {.varargs, importc, header: "<sys/prctl.h>".}
      discard prctl(1.cint, SIGTERM) # PR_SET_PDEATHSIG: transport cannot outlive its worker
      if getppid() != expectedParent: exitnow(127)
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
    # The Nim bus client has no reader thread. Keep protocol traffic moving
    # during long installs without dispatching another handler re-entrantly.
    if onWait != nil: onWait()
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

proc nativeRunner*(argv: seq[string], input: string, timeoutMs: int): CommandResult =
  nativeRunnerWithWait(argv, input, timeoutMs, nil)

proc checked(run: CommandRunner, argv: seq[string], input = "", timeoutMs = 60000): string =
  let r = run(argv, input, timeoutMs)
  if r.code != 0:
    let reason = if r.code == 124: "transport timeout"
      elif r.code == 125: "transport output exceeds 8 MiB"
      else: "command failed (" & argv[0] & "), exit " & $r.code
    refuse(reason & (if r.logPath.len > 0: "; private stderr log: " & r.logPath else: ""))
  r.output

proc hex(s: string, size: int): bool = s.len == size and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc resolveRevision*(run: CommandRunner, refspec: string): string =
  ## Accept either a full lowercase 40-character SHA (used verbatim, no network)
  ## or a git ref (`main`, `v0.4.0`) resolved to one through `git ls-remote`.
  ## Resolution is the operator's typing convenience ONLY: the resolved SHA is
  ## what the receipt records and what the remote checkout verifies, so pinning
  ## is preserved in fact — nothing downstream ever sees a moving ref.
  if hex(refspec, 40): return refspec
  if refspec.len == 0 or refspec[0] == '-' or
      not refspec.allCharsInSet({'a'..'z','A'..'Z','0'..'9','/','.','_','-','+'}):
    refuse("invalid revision")
  let patterns = @[refspec, "refs/heads/" & refspec, "refs/tags/" & refspec,
                   "refs/tags/" & refspec & "^{}"]
  let output = checked(run,
    @["git", "ls-remote", "https://github.com/gokr/niffler.git"] & patterns,
    timeoutMs = 60000)
  for line in output.splitLines():
    let parts = line.split(Whitespace)
    if parts.len == 2 and hex(parts[0], 40): return parts[0]
  refuse("cannot resolve revision '" & refspec & "' to a pinned commit")
proc validateRoot*(root: string) =
  if root.len < 2 or root[0] != '/' or not root.allCharsInSet({'a'..'z','A'..'Z','0'..'9','_','.','/','-'}): refuse("invalid root")
  for part in root[1..^1].split('/'):
    if part in ["", ".", ".."]: refuse("root must be a dedicated canonical installation path")

proc validateTarget(transport, target: string) =
  if transport == "multipass": refuse("Multipass profiles are no longer supported; provision a new Lima guest and import its new verified receipt; never rename the transport")
  if transport notin ["ssh", "lima", "incus"]: refuse("unsupported transport")
  if target.len == 0 or target[0] notin {'a'..'z','A'..'Z','0'..'9','_'} or
      not target.allCharsInSet({'a'..'z','A'..'Z','0'..'9','_','.','@','-'}): refuse("invalid target")
  if transport in ["lima", "incus"] and (target[0] notin {'a'..'z','A'..'Z'} or
      not target.allCharsInSet({'a'..'z','A'..'Z','0'..'9','-'})): refuse("invalid VM name")

proc validateRoute(p: JsonNode) =
  let transport = p{"transport"}.getStr()
  validateTarget(transport, p{"target"}.getStr())
  if p.hasKey("host"):
    if p["host"].kind != JString or p["host"].getStr().len == 0:
      refuse("host must be a nonempty SSH alias/user@host; omit for local")
    if transport notin ["lima", "incus"]: refuse("host is only allowed for guest transports")
    validateTarget("ssh", p["host"].getStr())
  if transport in ["incus", "lima"] and p{"root"}.getStr() != "/home/ubuntu/niffler":
    refuse("guest root must be /home/ubuntu/niffler")

proc validateProfile*(p: JsonNode) =
  try:
    if p.kind != JObject or p{"version"}.getInt() != 1: refuse("unsupported receipt version")
    validateRoot(p{"root"}.getStr())
    validateRoute(p)
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

proc sshArgs(target, command: string): seq[string] =
  @["ssh", "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15", "--", target, command]

proc management*(p: JsonNode, argv: seq[string]): seq[string] =
  ## SSH joins command arguments through a remote shell: quote EVERY word,
  ## including executable and fixed options, never interpolate user values.
  validateRoute(p)
  let routed = if argv.len > 0 and argv[0] == "incus":
      @["incus", "--force-local", "--project", "default"] & argv[1..^1]
    else: argv
  if not p.hasKey("host"): return routed
  var words: seq[string]
  for arg in routed: words.add("'" & arg.replace("'", "'\"'\"'") & "'")
  sshArgs(p["host"].getStr(), words.join(" "))

proc guestRoot(run: CommandRunner, p: JsonNode, script: string, timeoutMs = 60000): string =
  checked(run, management(p, @["incus", "exec", p["target"].getStr(), "--mode=non-interactive", "--", "bash", "-s"]),
          "set -euo pipefail\n" & script, timeoutMs)

const limaImages = """[
  {"location":"https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img","arch":"x86_64","digest":"sha256:6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"},
  {"location":"https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-arm64.img","arch":"aarch64","digest":"sha256:1d6bffe64b848468ac97f821d369a4846d983de1800ccf6b5ec8853e85cefc55"}
]"""

proc limaConfig*(cpus: int, memory, disk: string): JsonNode =
  ## Standalone JSON is YAML; never inherit Lima's host-mounting templates.
  result = %*{"minimumLimaVersion": "2.2.1", "os": "Linux", "images": parseJson(limaImages),
    "cpus": cpus, "memory": memory & "iB", "disk": disk & "iB", "mounts": [],
    "ssh": {"loadDotSSHPubKeys": false, "forwardAgent": false, "forwardX11": false},
    "user": {"name": "ubuntu", "home": "/home/ubuntu", "shell": "/bin/bash", "passwordlessSudo": true},
    "containerd": {"system": false, "user": false}, "copyToHost": [],
    "propagateProxyEnv": false, "portForwards": [{"guestIP": "0.0.0.0", "guestIPMustBeZero": false, "guestPortRange": [1,65535], "ignore": true}]}

proc validateLimaConfig*(config: JsonNode) =
  ## Inspect effective configuration, including operator default/override files.
  if config == nil or config.kind != JObject: refuse("missing effective Lima configuration")
  for key in ["ssh", "user", "containerd"]:
    if config{key} == nil or config[key].kind != JObject: refuse("missing or malformed Lima policy object: " & key)
  for key in ["firmware", "caCerts", "hostResolver"]:
    if config{key} != nil and config[key].kind != JObject: refuse("malformed Lima policy object: " & key)
  if config{"vmType"} != nil and config["vmType"].kind != JString: refuse("malformed Lima VM type")
  if config{"vmType"}.getStr() notin ["", "qemu", "vz"]: refuse("Lima requires a Linux qemu/vz VM")
  if config{"os"}.getStr() != "Linux" or config{"user", "name"}.getStr() != "ubuntu" or
      config{"user", "home"}.getStr() != "/home/ubuntu": refuse("Lima requires Linux ubuntu at /home/ubuntu")
  for key in ["mounts", "copyToHost", "additionalDisks", "networks", "provision", "probes", "base"]:
    if config{key} != nil and (config[key].kind != JArray or config[key].len > 0):
      refuse("Lima host mounts, extra devices/networks, copies and provisioning hooks are forbidden")
  if config{"env"} != nil and (config["env"].kind != JObject or config["env"].len > 0): refuse("Lima environment overrides forbidden")
  for key in ["loadDotSSHPubKeys", "forwardAgent", "forwardX11", "forwardX11Trusted"]:
    if config{"ssh", key} == nil:
      if key == "forwardX11Trusted": continue
      refuse("missing Lima SSH policy")
    if config["ssh"][key].kind != JBool or config["ssh"][key].getBool(): refuse("unsafe Lima SSH configuration")
  if config{"propagateProxyEnv"} == nil or config["propagateProxyEnv"].kind != JBool or config["propagateProxyEnv"].getBool(): refuse("Lima proxy credential propagation forbidden")
  for key in ["system", "user"]:
    if config{"containerd", key} == nil or config["containerd"][key].kind != JBool or config["containerd"][key].getBool(): refuse("Lima containerd must be disabled")
  # Disabled containerd's default archive registry is inert. Firmware, VM driver
  # overrides and certificate injection are different boot/trust inputs.
  if config{"firmware", "images"} != nil and (config["firmware"]["images"].kind != JArray or config["firmware"]["images"].len > 0): refuse("custom Lima firmware forbidden")
  for key in ["vmOpts", "osOpts"]:
    if config{key} != nil and (config[key].kind != JObject or config[key].len > 0): refuse("Lima driver/OS overrides forbidden")
  for key in ["files", "certs"]:
    if config{"caCerts", key} != nil and (config["caCerts"][key].kind != JArray or config["caCerts"][key].len > 0): refuse("Lima certificate injection forbidden")
  let images = config{"images"}
  let reviewed = parseJson(limaImages)
  if images == nil or images.kind != JArray or images.len != reviewed.len: refuse("Lima requires the reviewed digest-pinned Ubuntu images")
  for i in 0..<reviewed.len:
    if images[i] != reviewed[i]: refuse("Lima image entries must exactly match reviewed pins; no extra image/archive/boot fields")
  if config{"cpus"} == nil or config["cpus"].kind != JInt or config["cpus"].getInt() notin 1..64: refuse("Lima CPU limit required")
  for key in ["memory", "disk"]:
    let size = config{key}
    if size == nil or size.kind != JString: refuse("Lima resource size must be a string")
    let value = size.getStr()
    if value.len < 4 or value[^3..^1] notin ["GiB", "MiB"] or value[0] notin {'1'..'9'} or
        not value[0..^4].allCharsInSet({'0'..'9'}): refuse("invalid Lima resource size")
  let forwards = config{"portForwards"}
  if forwards == nil or forwards.kind != JArray or forwards.len != 1 or forwards[0].kind != JObject or
      forwards[0]{"ignore"} != %true or
      forwards[0]{"guestPortRange"} != %*[1,65535] or
      forwards[0]{"guestIP"}.getStr() != "0.0.0.0" or
      forwards[0]{"guestIPMustBeZero"} != %false: refuse("Lima automatic port forwarding forbidden")
  for key in ["reverse", "static"]:
    if forwards[0]{key} != nil and forwards[0][key] != %false: refuse("Lima reverse/static forwarding forbidden")
  for key in ["guestSocket", "hostSocket"]:
    if forwards[0]{key} != nil and forwards[0][key] != %"": refuse("Lima socket forwarding forbidden")
  if forwards[0]{"proto"} != nil and forwards[0]["proto"] != %"any": refuse("Lima ignore rule must cover every protocol")

proc vmInfo(run: CommandRunner, p: JsonNode): JsonNode

proc remote*(run: CommandRunner, p: JsonNode, script: string, timeoutMs = 60000): string =
  validateRoute(p)
  if p["transport"].getStr() in ["incus", "lima"] and vmInfo(run, p) == nil:
    refuse("pinned container missing; refusing execution or recreation")
  let target = p["target"].getStr()
  let transport = p["transport"].getStr()
  let argv = if transport == "ssh": sshArgs(target, "bash -s")
    elif transport == "incus": management(p, @["incus", "exec", target, "--mode=non-interactive", "--", "runuser", "-u", "ubuntu", "--", "env", "HOME=/home/ubuntu", "USER=ubuntu", "LOGNAME=ubuntu", "bash", "-s"])
    else: management(p, @["limactl", "shell", "--workdir=/home/ubuntu", target, "bash", "-s"])
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

proc updateScript*(root, revision: string): string =
  ## Refresh an EXISTING pinned installation to a new revision. Never clones and
  ## never adopts: a missing, unrelated, symlinked or locally-modified root is a
  ## refusal, and the caller has already verified durable identity before any
  ## write reaches the host.
  validateRoot(root)
  if not hex(revision, 40): refuse("full 40-character pinned revision required")
  result = "root=" & quoteShell(root) & "\nrevision=" & revision & "\n" & """
export PATH="$HOME/.nimble/bin:/usr/local/bin:$PATH"
[[ ! -L "$root" ]] || { echo 'symlinked root: refusing' >&2; exit 1; }
[[ -f "$root/niffler.nimble" && -x "$root/var/bin/niffler" && -f "$root/scripts/server.sh" ]] || { echo 'not a Niffler installation: refusing' >&2; exit 1; }
# Local modifications are the operator's work, not ours to discard.
[[ -z "$(git -C "$root" status --porcelain)" ]] || { echo 'installation has local changes: refusing to update' >&2; exit 1; }
git -C "$root" fetch --tags origin "$revision"
git -C "$root" checkout --detach "$revision"
[[ "$(git -C "$root" rev-parse HEAD)" == "$revision" ]] || { echo 'checkout did not reach the requested revision' >&2; exit 1; }
cd "$root"
# make build, never bootstrap: an update must not run prerequisite installation
# (a sudo prompt over a non-interactive SSH session would hang). A missing
# prerequisite fails loudly here instead.
make build
""" & serviceEnv & """
bash "$root/scripts/server.sh" install "$root"
# start alone would leave the old process serving the previous build.
bash "$root/scripts/server.sh" stop "$root"
bash "$root/scripts/server.sh" start "$root"
"""

proc vmInfo(run: CommandRunner, p: JsonNode): JsonNode =
  try:
    let incus = p["transport"].getStr() == "incus"
    let argv = if incus: @["incus", "list", "--format", "json"] else: @["limactl", "list", "--json", "--all-fields"]
    let output = checked(run, management(p, argv))
    let guests = if incus: parseJson(output) else: newJArray()
    if not incus:
      for line in output.splitLines():
        if line.strip().len > 0: guests.add(parseJson(line))
    if guests == nil or guests.kind != JArray: refuse("invalid guest list")
    for vm in guests:
      if vm{"name"}.getStr() == p["target"].getStr():
        if incus:
          if vm{"type"}.getStr() != "container": refuse("Incus requires a system container")
          let config = vm{"expanded_config"}
          if config == nil or config.kind != JObject: refuse("missing expanded container policy")
          for key, value in config:
            if key.startsWith("raw.") or (key.startsWith("security.") and value.getStr() notin ["false", "0"]):
              refuse("Incus requires unprivileged, non-nesting containers without raw configuration")
          let devices = vm{"expanded_devices"}
          if devices == nil or devices.kind != JObject: refuse("missing expanded container devices")
          for key, device in devices:
            if device{"type"}.getStr() == "nic":
              let network = device{"network"}.getStr()
              if network.len > 0:
                # Managed-network devices omit nictype; verify their network,
                # rather than treating a physical/SR-IOV network as a bridge.
                let networks = parseJson(checked(run, management(p, @["incus", "network", "list", "--format", "json"])))
                if networks.kind != JArray: refuse("invalid Incus network inventory")
                var safe = false
                for net in networks:
                  if net{"name"}.getStr() == network:
                    safe = net{"type"}.getStr() == "bridge" and net{"managed"}.getBool()
                if not safe: refuse("Incus requires a managed bridge network")
              elif device{"nictype"}.getStr() notin ["bridged", "p2p"]:
                refuse("Incus requires bridged or isolated p2p NICs; no physical/SR-IOV passthrough")
              continue
            if device{"type"}.getStr() != "disk" or device{"path"}.getStr() != "/" or device{"source"}.getStr().len > 0:
              refuse("host mounts and passthrough devices are forbidden")
        else:
          validateLimaConfig(vm{"config"})
        return vm
  except Refusal: raise
  except CatchableError: refuse("invalid guest list")

proc running(p, vm: JsonNode): bool =
  vm{"status"}.getStr() == "Running"

proc guestCommand(p: JsonNode, action: string): seq[string] =
  management(p, (if p["transport"].getStr() == "lima": @["limactl", action, "--tty=false", p["target"].getStr()] else: @["incus", action, p["target"].getStr()]))

proc requireEnforcedDisk*(run: CommandRunner, p: JsonNode, disk: string) =
  ## Incus records `root,size=` in the device configuration whatever the backend
  ## is, and the `dir` driver enforces it only where the filesystem carries
  ## project quotas. Without this check an unquoted dir pool would hand the guest
  ## the whole host filesystem while the receipt claims a bounded one, so refuse
  ## instead of reporting a limit nobody applies. Other drivers apply it themselves.
  var pool = ""
  try:
    pool = checked(run, management(p, @["incus", "profile", "device", "get", "default", "root", "pool"])).strip()
  except Refusal:
    refuse("cannot resolve the default profile's Incus storage pool to verify the " & disk & " root limit")
  if pool.len == 0: refuse("cannot resolve the default profile's Incus storage pool to verify the " & disk & " root limit")
  try:
    let pools = parseJson(checked(run, management(p, @["incus", "storage", "list", "--format", "json"])))
    if pools.kind != JArray: refuse("invalid Incus storage inventory")
    var entry: JsonNode = nil
    for item in pools:
      if item{"name"}.getStr() == pool: entry = item
    if entry == nil: refuse("invalid Incus storage inventory")
    if entry{"driver"}.getStr() != "dir": return
    let source = entry{"config"}{"source"}.getStr()
    if source.len == 0: refuse("Incus pool '" & pool & "' has no source to inspect for a root-disk quota")
    let shown = checked(run, management(p, @["findmnt", "-n", "-o", "FSTYPE,OPTIONS", "--target", source])).strip()
    let parts = shown.splitWhitespace()
    if parts.len >= 2 and ("prjquota" in parts[1] or "pquota" in parts[1]): return
    refuse("Incus storage pool '" & pool & "' (dir) cannot enforce the " & disk &
      " root limit: its filesystem is not mounted with project quotas. Create a zfs/btrfs/lvm pool or mount it with prjquota; Fleet never reports an unbounded guest as bounded")
  except Refusal: raise
  except CatchableError: refuse("invalid Incus storage inventory")

proc incusInstallScript*(root, revision: string): string =
  ## Only bootstrap is root. The temporary grant belongs to this invocation;
  ## noclobber plus EXIT cleanup protect existing grants and failure paths.
  result = "root=" & quoteShell(root) & "\n" & """
grant=/etc/sudoers.d/niffler-fleet-bootstrap
[[ ! -e "$grant" && ! -L "$grant" ]] || { echo 'existing bootstrap grant: inspect and clean up manually before retrying' >&2; exit 1; }
[[ ! -L /home/ubuntu && ! -L "$root" ]] || exit 1
if [[ -e "$root" ]]; then
  [[ -f "$root/niffler.nimble" && -x "$root/var/bin/niffler" && -f "$root/scripts/server.sh" ]] || { echo 'existing incomplete/unrelated root: refusing before guest setup' >&2; exit 1; }
fi
if ! id ubuntu >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash ubuntu
fi
[[ $(id -u ubuntu) != 0 && $(getent passwd ubuntu | cut -d: -f6) == /home/ubuntu ]] || exit 1
[[ ! -L "$root" ]] || exit 1
if [[ ! -e "$root" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git sudo ca-certificates make curl
fi
# Explicitly approved guest-only persistence; never changes host linger.
loginctl enable-linger ubuntu
systemctl start "user@$(id -u ubuntu).service"
if [[ ! -e "$root" ]]; then
  (umask 077; set -o noclobber; printf 'ubuntu ALL=(ALL) NOPASSWD: ALL\n' > "$grant")
  trap 'rm -f -- "$grant"' EXIT
  chmod 0440 "$grant"
  visudo -cf "$grant"
fi
runuser -u ubuntu -- env HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu bash -s <<'NIFFLER_USER_INSTALL'
set -euo pipefail
""" & installScript(root, revision) & "\nNIFFLER_USER_INSTALL\n"

proc install*(run: CommandRunner, args: JsonNode): JsonNode =
  let path = receiptPath(args{"profile"}.getStr())
  let previous = loadReceipt(path)
  let transport = args{"transport"}.getStr()
  let target = args{"target"}.getStr()
  let root = args{"root"}.getStr()
  # A ref resolves to a pinned commit BEFORE anything is written anywhere: the
  # receipt and the remote checkout both carry the resolved SHA, so "install
  # main" still produces a receipt that proves exactly what is installed.
  let revision = resolveRevision(run, args{"revision"}.getStr())
  validateTarget(transport, target); validateRoot(root)
  if not hex(revision, 40): refuse("full 40-character pinned revision required")
  let cpus = args{"cpus"}.getInt(2)
  let memory = args{"memory"}.getStr("4G")
  let disk = args{"disk"}.getStr("20G")
  if cpus < 1 or cpus > 64: refuse("CPUs must be 1..64")
  for size in [memory, disk]:
    if size.len < 2 or size[^1] notin {'M','G'} or size[0] notin {'1'..'9'} or not size[0..^2].allCharsInSet({'0'..'9'}): refuse("invalid VM resource size")
  var p = %*{"version": 1, "transport": transport, "target": target, "root": root}
  if args.hasKey("host"): p["host"] = args["host"]
  validateRoute(p)
  if previous != nil:
    if previous{"host"} != p{"host"}: refuse("profile already belongs to a different host route")
    for key in ["transport", "target", "root"]:
      if previous[key] != p[key]: refuse("profile already belongs to a different target")
    p = previous
  let vm = if transport in ["lima", "incus"]: vmInfo(run, p) else: nil
  if previous != nil and transport in ["lima", "incus"] and vm == nil: refuse("pinned VM is missing; refusing to recreate a different instance")
  # Never start a pinned VM before identity verification. A stopped pinned VM
  # must first be started explicitly by its administrator.
  if previous != nil:
    discard remote(run, p, guard(p))
    try: discard probe(run, p)
    except Refusal as e:
      if "mismatch" in e.msg or "invalid catalog" in e.msg: raise
  if transport in ["lima", "incus"]:
    if vm == nil:
      if transport == "incus": requireEnforcedDisk(run, p, disk)
      let create = if transport == "incus":
          @["incus", "launch", "images:ubuntu/24.04", target, "--config", "security.privileged=false", "--config", "security.nesting=false", "--config", "limits.cpu=" & $cpus, "--config", "limits.memory=" & memory & "B", "--device", "root,size=" & disk & "B"]
        else: @["limactl", "create", "--tty=false", "--name=" & target, "-"]
      discard checked(run, management(p, create), (if transport == "lima": $limaConfig(cpus, memory, disk) else: ""), timeoutMs = 600000)
      if transport == "lima":
        if vmInfo(run, p) == nil: refuse("created Lima guest missing")
        discard checked(run, guestCommand(p, "start"), timeoutMs = 600000)
      if transport == "incus" and vmInfo(run, p) == nil: refuse("created container missing")
      p["createdVm"] = %true
    elif not running(p, vm):
      discard checked(run, guestCommand(p, "start"), timeoutMs = 180000)
  if transport == "incus" and previous == nil:
    discard guestRoot(run, p, incusInstallScript(root, revision), 3600000)
  elif transport == "lima" and previous == nil:
    discard checked(run, management(p, @["limactl", "shell", "--workdir=/home/ubuntu", target, "sudo", "-n", "bash", "-s"]), "set -euo pipefail\n" & incusInstallScript(root, revision), 3600000)
  else:
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
  %*{"profile": path, "receipt": p, "text": (if transport in ["incus", "lima"]: "Verified receipt saved; enabled guest linger for ubuntu; temporary installer sudo grant removed. Provider configuration remains explicit." else: "Verified receipt saved; provider configuration and linger remain explicit.")}

proc revisionMatches(run: CommandRunner, p, identity: JsonNode, revision: string): bool =
  ## Catalogs advertise an abbreviated build hash. Verify the exact checkout
  ## separately; a short prefix alone is not proof of the requested revision.
  let advertised = identity{"gitHash"}.getStr()
  if advertised.len < 7 or advertised.len > 40 or
      not advertised.allCharsInSet({'0'..'9', 'a'..'f'}) or
      not revision.startsWith(advertised): return false
  let head = remote(run, p, guard(p) & "git -C " & quoteShell(p["root"].getStr()) & " rev-parse HEAD\n").strip()
  head == revision

proc update*(run: CommandRunner, args: JsonNode): JsonNode =
  ## Move ONE verified pinned installation to a new revision. The receipt is the
  ## authority: update never installs, never adopts an unrelated root and never
  ## touches provider credentials. Identity is proven over the live catalog
  ## BEFORE any remote write, and the receipt's pinned revision is advanced only
  ## after the UPDATED instance verifies — a botched update leaves the receipt
  ## describing what was actually proven, not what was attempted.
  let path = receiptPath(args{"profile"}.getStr())
  let p = loadReceipt(path)
  if p == nil: refuse("verified receipt required; install first")
  if p["transport"].getStr() in ["lima", "incus"]:
    # Identity must verify before any write: the administrator starts stopped
    # pinned guests. Creation belongs to install; missing guests never recreate.
    let vm = vmInfo(run, p)
    if vm == nil: refuse("pinned VM is missing; refusing to update")
    if not running(p, vm):
      refuse("stopped pinned guest: administrator must start it before identity verification/update")
  let revision = resolveRevision(run, args{"revision"}.getStr())
  let before = probe(run, p)
  let fromHash = before{"gitHash"}.getStr()
  if revisionMatches(run, p, before, revision):
    return %*{"profile": path, "receipt": p, "changed": false,
              "text": "Already at the requested revision; nothing to do."}
  discard remote(run, p, guard(p) & updateScript(p["root"].getStr(), revision),
                 3600000)
  var verified = false
  for attempt in 0..<30:
    try:
      let identity = probe(run, p)
      if revisionMatches(run, p, identity, revision):
        p["expect"] = identity
        verified = true
        break
    except Refusal as e:
      if "mismatch" in e.msg or "invalid catalog" in e.msg: raise
    if attempt < 29: sleep(1000)
  if not verified:
    refuse("updated service did not verify at " & revision &
           "; receipt left at " & fromHash)
  saveReceipt(path, p)
  %*{"profile": path, "receipt": p, "changed": true, "from": fromHash,
     "to": revision,
     "text": "Updated and verified; the receipt now pins " & revision & "."}

proc action*(run: CommandRunner, name, profile: string): JsonNode =
  let p = loadReceipt(receiptPath(profile))
  if p == nil: refuse("verified profile required")
  if name == "probe": return probe(run, p)
  if name == "vm_stop":
    if p["transport"].getStr() notin ["lima", "incus"]: refuse("not a guest profile")
    discard remote(run, p, guard(p))
    discard probe(run, p)
    discard checked(run, guestCommand(p, "stop"), timeoutMs = 180000)
    return %*{"ok": true, "text": "VM stopped; not deleted."}
  if name notin ["start", "stop", "status", "logs"]: refuse("unsupported Fleet action")
  let root = quoteShell(p["root"].getStr())
  let output = remote(run, p, guard(p) & serviceEnv & "bash " & root & "/scripts/server.sh " & name & " " & root & "\n")
  %*{"ok": true, "text": capBytes(output, 65536)}
