## Fleet policy and bus contract, with fake transports only.
import std/[json, os, strutils, posix]
import natsnim
import helpers
import ../components/fleet/provision

proc rejected(body: proc()): bool =
  try: body()
  except CatchableError: return true

proc firstCommand(cs: seq[seq[string]], head: string): seq[string] =
  for c in cs:
    if c.len > 0 and c[0] == head: return c
  @[]

proc firstScript(ss: seq[string], needle: string): string =
  for s in ss:
    if s.contains(needle): return s
  ""

proc main() =
  let repo = getCurrentDir()
  let tmp = repo / "var" / ("fleet-test-" & $getCurrentProcessId())
  createDir(tmp)
  defer: removeDir(tmp)
  let oldRoot = getEnv("NIF_ROOT")
  putEnv("NIF_ROOT", tmp)
  defer:
    if oldRoot.len > 0: putEnv("NIF_ROOT", oldRoot)
    else: delEnv("NIF_ROOT")
  let identity = %*{"instanceId": repeat('a', 32), "name": "fake", "root": "/srv/niffler", "gitHash": repeat('b', 40)}
  let profile = tmp / "receipt.json"
  let args = %*{"profile": profile, "transport": "ssh", "target": "user@fake", "root": "/srv/niffler", "revision": repeat('b', 40)}
  var commands: seq[seq[string]]
  var scripts: seq[string]
  var drift = false
  var missingVm = false
  # Update fixtures: `currentHash` models the remote checkout's HEAD, which an
  # update script moves; `resolvedSha` is what `git ls-remote` answers.
  let resolvedSha = repeat('d', 40)
  var currentHash = repeat('b', 40)
  var shortCatalog = false
  let runner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    commands.add(argv); scripts.add(input)
    if argv == @["limactl", "list", "--json", "--all-fields"]:
      return CommandResult(output: (if missingVm: "" else: $(%*{"name": "fake-vm", "status": "Running", "config": limaConfig(2, "4G", "20G")})))
    if argv.len > 1 and argv[0] == "limactl" and argv[1] == "create": missingVm = false
    if argv.len > 3 and argv[0] == "git" and argv[1] == "ls-remote":
      # Only the refs this fixture knows about resolve; anything else is empty,
      # which is how a bogus ref reaches the refusal.
      for pattern in argv[3 .. ^1]:
        if pattern in ["main", "refs/heads/main"]:
          return CommandResult(output: resolvedSha & "\trefs/heads/main")
      return CommandResult(output: "")
    if input.contains("call catalog"):
      let id = identity.copy()
      if argv.len > 0 and argv[0] == "limactl": id["root"] = %"/home/ubuntu/niffler"
      id["gitHash"] = %(if shortCatalog: currentHash[0..6] else: currentHash)
      if drift: id["instanceId"] = %repeat('c', 32)
      return CommandResult(output: $id)
    if input.contains(" rev-parse HEAD") and not input.contains("checkout --detach"):
      return CommandResult(output: currentHash & "\n")
    # Whatever the script checks out is what the instance reports afterwards —
    # this is how an install, an adoption or an update moves the visible build.
    if input.contains("checkout --detach"):
      for raw in input.split({' ', '\n', '\t', '"'}):
        let tok = if raw.startsWith("revision="): raw["revision=".len .. ^1] else: raw
        if tok.len == 40 and tok.allCharsInSet({'0'..'9', 'a'..'f'}):
          currentHash = tok
    CommandResult()
  let installed = install(runner, args)
  check("verified version-1 receipt", installed["receipt"]["expect"] == identity and loadReceipt(profile)["version"].getInt() == 1)
  # An install by ref must pin what it resolved: the receipt is the proof, so a
  # moving ref must never reach it.
  let refArgs = args.copy()
  refArgs["revision"] = %"main"
  refArgs["profile"] = %(tmp / "byref.json")
  commands.setLen(0); scripts.setLen(0)
  let refInstalled = install(runner, refArgs)
  # Pinning is the property that matters: the moving ref must never reach the
  # host or the receipt, only the commit it resolved to — and resolution must
  # happen BEFORE any remote write.
  let written = firstScript(scripts, "checkout --detach")
  var lsRemote = -1
  var sshCall = -1
  for i, c in commands:
    if lsRemote < 0 and c.len > 1 and c[0] == "git" and c[1] == "ls-remote": lsRemote = i
    if sshCall < 0 and c.len > 0 and c[0] == "ssh": sshCall = i
  check("install resolves a ref before writing anything",
        written.contains(resolvedSha) and not written.contains("--detach main") and
        lsRemote >= 0 and sshCall >= 0 and lsRemote < sshCall,
        written[0 .. min(400, written.len - 1)])
  check("install pins the resolved commit in the receipt",
        refInstalled["receipt"]["expect"]["gitHash"].getStr() == resolvedSha and
        loadReceipt(tmp / "byref.json")["expect"]["gitHash"].getStr() == resolvedSha,
        $refInstalled)
  check("private receipt", getFilePermissions(profile) == {fpUserRead, fpUserWrite})
  check("fixed SSH argv preserves known_hosts defaults", firstCommand(commands, "ssh") == @["ssh", "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15", "--", "user@fake", "bash -s"])
  check("new install pins commit and adopts without updates", block:
    let s = firstScript(scripts, "git clone")
    s.contains("checkout --detach") and
      s.contains("Adopting existing installation without updating") and
      not s.contains("git pull"))
  drift = true
  commands.setLen(0); scripts.setLen(0)
  check("drift refuses before install write", rejected(proc() = discard install(runner, args)) and not scripts.join("").contains("git clone"))
  drift = false
  let foreign = args.copy(); foreign["target"] = %"other"
  check("existing receipt target mismatch", rejected(proc() = discard install(runner, foreign)))
  check("durable identity guard generated", guard(installed["receipt"]).contains("/var/instance-id") and guard(installed["receipt"]).contains(repeat('a', 32)))
  for (key, value) in [("root", "/"), ("root", "/srv/../x"), ("root", "/srv/x;bad"), ("target", "-bad"), ("transport", "other"), ("revision", "no-such-ref"), ("memory", "0G"), ("disk", "20G;bad")]:
    let invalid = args.copy(); invalid[key] = %value; invalid["profile"] = %(tmp / "unused.json")
    check("invalid " & key & " refuses", rejected(proc() = discard install(runner, invalid)))
  let badCpus = args.copy(); badCpus["profile"] = %(tmp / "unused.json"); badCpus["cpus"] = %65
  check("invalid CPU count refuses", rejected(proc() = discard install(runner, badCpus)))
  let wrongRoot: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    let id = identity.copy(); id["root"] = %"/wrong"
    CommandResult(output: $id)
  check("wrong catalog root refuses", rejected(proc() = discard probe(wrongRoot, installed["receipt"])))
  let malformed = tmp / "bad.json"
  for data in ["null", "[]", "{}", "{", "{\"version\":2}"]:
    writeFile(malformed, data)
    check("malformed receipt refuses " & data, rejected(proc() = discard loadReceipt(malformed)))
  let link = tmp / "link.json"
  createSymlink(profile, link)
  check("symlink load and save refuse", rejected(proc() = discard loadReceipt(link)) and rejected(proc() = saveReceipt(link, installed["receipt"])))
  let vmArgs = args.copy()
  vmArgs["root"] = %"/home/ubuntu/niffler"
  vmArgs["transport"] = %"lima"; vmArgs["target"] = %"fake-vm"; vmArgs["profile"] = %(tmp / "vm.json")
  missingVm = true
  let vmInstalled = install(runner, vmArgs)
  check("VM provenance recorded without mounts", vmInstalled["receipt"]["createdVm"].getBool() and ($commands).find("mount") < 0)
  missingVm = true
  commands.setLen(0)
  check("missing pinned VM refuses recreation", rejected(proc() = discard install(runner, vmArgs)) and commands.len == 1)
  missingVm = false
  commands.setLen(0); scripts.setLen(0)
  discard install(runner, vmArgs)
  check("running VM adoption never creates", not ($commands).contains("create"))
  let multipleInventory: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    if argv == @["limactl", "list", "--json", "--all-fields"]:
      return CommandResult(output: "{\"name\":\"unrelated\"}\n" & $(%*{"name": "fake-vm", "status": "Running", "config": limaConfig(2, "4G", "20G")}))
    runner(argv, input, timeoutMs)
  discard action(multipleInventory, "probe", vmArgs["profile"].getStr())
  check("Lima newline-delimited inventory handles unrelated guests", true)
  let stoppedInventory: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    if argv == @["limactl", "list", "--json", "--all-fields"]:
      return CommandResult(output: $(%*{"name": "fake-vm", "status": "Stopped", "config": limaConfig(2, "4G", "20G")}))
    runner(argv, input, timeoutMs)
  commands.setLen(0)
  check("stopped pinned Lima update requires administrator", rejected(proc() = discard update(stoppedInventory, %*{"profile": vmArgs["profile"], "revision": resolvedSha})) and commands.len == 0)
  commands.setLen(0); scripts.setLen(0)
  discard action(runner, "stop", profile)
  check("service stop distinct from VM stop", commands.len == 1 and scripts[0].contains("server.sh stop") and not scripts[0].contains("lima"))
  commands.setLen(0)
  discard action(runner, "vm_stop", vmArgs["profile"].getStr())
  check("VM stop never delete", commands[^1] == @["limactl", "stop", "--tty=false", "fake-vm"])
  let legacy = vmInstalled["receipt"].copy()
  legacy["transport"] = %"multipass"
  try:
    validateProfile(legacy)
    check("legacy Multipass receipt refuses", false)
  except Refusal as e:
    check("legacy Multipass migration error", e.msg.contains("never rename"))
  for unsafe in ["mounts", "ssh", "images", "portForwards", "propagateProxyEnv"]:
    let unsafeKey = unsafe
    let badConfig = limaConfig(2, "4G", "20G")
    case unsafeKey
    of "mounts": badConfig["mounts"] = %*[{"location": "~"}]
    of "ssh": badConfig["ssh"]["forwardAgent"] = %true
    of "images": badConfig["images"][0]["digest"] = %"sha256:bad"
    of "portForwards": badConfig["portForwards"] = %*[]
    else: badConfig["propagateProxyEnv"] = %true
    let unsafeRunner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
      CommandResult(output: $(%*{"name": "fake-vm", "status": "Running", "config": badConfig}))
    check("unsafe Lima policy refuses " & unsafeKey, rejected(proc() = discard install(unsafeRunner, vmArgs)))
  for key in ["mounts", "additionalDisks", "copyToHost", "networks", "provision", "probes", "base"]:
    for badValue in [%false, %0, %"", newJObject(), newJNull()]:
      let config = limaConfig(2, "4G", "20G")
      config[key] = badValue
      check("Lima typed empty policy refuses " & key & " " & $badValue.kind, rejected(proc() = validateLimaConfig(config)))
  for key in ["kernel", "initrd", "variant", "archive", "format", "unknown"]:
    let config = limaConfig(2, "4G", "20G")
    config["images"][0][key] = %"injected"
    check("Lima extra image field refuses " & key, rejected(proc() = validateLimaConfig(config)))
  for badValue in [%"false", %0, newJNull()]:
    let config = limaConfig(2, "4G", "20G")
    config["ssh"]["forwardAgent"] = badValue
    check("Lima typed boolean refuses " & $badValue.kind, rejected(proc() = validateLimaConfig(config)))
  for key in ["system", "user"]:
    let config = limaConfig(2, "4G", "20G")
    config["containerd"][key] = %true
    check("Lima containerd enabled refuses " & key, rejected(proc() = validateLimaConfig(config)))
  let timeoutRunner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult = CommandResult(code: 124)
  check("timeout refuses", rejected(proc() = discard probe(timeoutRunner, installed["receipt"])))

  let separated = nativeRunner(@["bash", "-c", "read -r line; printf '%s' \"$line\"; echo private-diagnostic >&2"], "stdin-ok\n", 1000)
  check("native stdin stdout and stderr separate", separated.code == 0 and separated.output == "stdin-ok" and readFile(separated.logPath).contains("private-diagnostic"))
  check("native private workspace logs", separated.logPath.startsWith(tmp) and getFilePermissions(separated.logPath) == {fpUserRead, fpUserWrite})
  let failed = nativeRunner(@["bash", "-c", "echo secret >&2; exit 7"], "", 1000)
  check("native failure retains private log not stdout", failed.code == 7 and failed.output.len == 0 and fileExists(failed.logPath))
  check("install script valid shell syntax", nativeRunner(@["bash", "-n"], installScript("/srv/niffler", repeat('b', 40)), 1000).code == 0)
  let unrelated = tmp / "unrelated"
  createDir(unrelated)
  check("unrelated root refuses without mutation", nativeRunner(@["bash", "-s"], "set -euo pipefail\n" & installScript(unrelated, repeat('b', 40)), 1000).code != 0 and not dirExists(unrelated / ".git"))
  check("native timeout", nativeRunner(@["bash", "-c", "sleep 20"], "", 40).code == 124)
  check("catalog-sized output untruncated", nativeRunner(@["bash", "-c", "printf '%070000d' 0"], "", 1000).output.len == 70000)
  check("oversized output refused", nativeRunner(@["bash", "-c", "head -c 8388609 /dev/zero"], "", 2000).code == 125)

  # --- update: ref resolution, script safety, and the receipt contract -------
  # The receipt's installation is the one the original install left behind.
  currentHash = repeat('b', 40)
  commands.setLen(0)
  check("a full SHA resolves without touching the network",
        resolveRevision(runner, resolvedSha) == resolvedSha and commands.len == 0)
  check("a ref resolves to a pinned commit",
        resolveRevision(runner, "main") == resolvedSha)
  for bogus0 in ["no-such-ref", "-main", "", "main;rm -rf /"]:
    let bogus = bogus0
    check("bogus revision refuses: " & (if bogus.len == 0: "<empty>" else: bogus),
          rejected(proc() = discard resolveRevision(runner, bogus)))
  check("update script valid shell syntax",
        nativeRunner(@["bash", "-n"], updateScript("/srv/niffler", resolvedSha),
                     1000).code == 0)
  check("update never clones, bootstraps or discards local work", block:
    let s = updateScript("/srv/niffler", resolvedSha)
    s.contains("status --porcelain") and s.contains("make build") and
      not s.contains("git clone") and not s.contains("bootstrap.sh"))
  check("update requires a verified receipt",
        rejected(proc() = discard update(runner,
          %*{"profile": tmp / "absent.json", "revision": resolvedSha})))
  commands.setLen(0); scripts.setLen(0)
  let updated = update(runner, %*{"profile": profile, "revision": "main"})
  check("update resolves the ref, moves the checkout and reports the transition",
        updated{"changed"}.getBool() and
        updated{"from"}.getStr() == repeat('b', 40) and
        updated{"to"}.getStr() == resolvedSha, $updated)
  check("the receipt pins the revision that actually verified",
        loadReceipt(profile){"expect"}{"gitHash"}.getStr() == resolvedSha,
        $loadReceipt(profile))
  check("update at the current revision changes nothing",
        not update(runner, %*{"profile": profile,
                              "revision": resolvedSha}){"changed"}.getBool())
  shortCatalog = true
  commands.setLen(0); scripts.setLen(0)
  check("short catalog hash and exact checkout identify a no-op update",
    not update(runner, %*{"profile": profile, "revision": resolvedSha}){"changed"}.getBool() and
    not scripts.join("").contains("make build"))
  let shortUpdate = update(runner, %*{"profile": profile, "revision": repeat('e', 40)})
  check("short catalog hash verifies a real update", shortUpdate{"changed"}.getBool() and
    loadReceipt(profile){"expect"}{"gitHash"}.getStr() == repeat('e', 7))
  shortCatalog = false
  currentHash = resolvedSha
  discard install(runner, args)
  drift = true
  commands.setLen(0); scripts.setLen(0)
  check("identity drift refuses an update before any write",
        rejected(proc() = discard update(runner,
          %*{"profile": profile, "revision": repeat('e', 40)})) and
        not scripts.join("").contains("make build") and
        not scripts.join("").contains("checkout --detach") and
        not loadReceipt(profile)["expect"]["gitHash"].getStr().startsWith("ee"),
        "scripts=" & $scripts)
  drift = false

  # Execute the exact grant creation/EXIT block in a workspace-only sandbox.
  # No sudo, Incus, user creation or host configuration is reachable here.
  let incusShell = incusInstallScript("/home/ubuntu/niffler", resolvedSha)
  let grantStart = incusShell.find("  (umask 077;")
  let grantEnd = incusShell.find("\nfi\nrunuser", grantStart)
  let grantBlock = incusShell[grantStart..<grantEnd]
  for failValidation in [false, true]:
    let grantFile = tmp / "test-grant"
    let fixture = "set -euo pipefail\ngrant=" & quoteShell(grantFile) & "\nvisudo() { return " & (if failValidation: "1" else: "0") & "; }\n" & grantBlock
    let r = nativeRunner(@["bash", "-s"], fixture, 1000)
    check("temporary guest grant cleaned on " & (if failValidation: "failure" else: "success"),
      r.code == (if failValidation: 1 else: 0) and not fileExists(grantFile))
  # Guest transports, local and SSH-hosted: no real transport can run here.
  var guestMissing = true
  var guestStopped = false
  var unsafeGuest = false
  var nicType = "bridged"
  var managedNic = false
  var networkType = "bridge"
  var guestHash = repeat('b', 40)
  var dirNoQuota = false
  # An adopted container provisioned before boot.autostart was part of the
  # contract; install must repair it instead of leaving a host reboot to strand
  # the instance.
  var bootAutostart = false
  let guestIdentity = identity.copy()
  guestIdentity["root"] = %"/home/ubuntu/niffler"
  let guestRunner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    commands.add(argv); scripts.add(input)
    let cmd = argv.join(" ")
    if "network" in cmd and "list" in cmd:
      return CommandResult(output: $(%*[{"name": "incusbr0", "type": networkType, "managed": true}]))
    if "profile" in cmd and "device" in cmd and "root" in cmd:
      return CommandResult(output: "default\n")
    if "storage" in cmd and "list" in cmd:
      return CommandResult(output: $(%*[{"name": "default", "driver": (if dirNoQuota: "dir" else: "btrfs"),
        "config": {"source": (if dirNoQuota: "/var/lib/incus/storage-pools/default" else: "/var/lib/incus/disks/default.img")}}]))
    if "findmnt" in cmd:
      return CommandResult(output: "ext4 rw,relatime\n")
    if ("list" in cmd):
      if "incus" in cmd:
        if guestMissing: return CommandResult(output: "[]")
        let vm = %*{"name": "fake-ct", "type": "container", "status": (if guestStopped: "Stopped" else: "Running"),
          "expanded_config": {"security.privileged": (if unsafeGuest: "true" else: "false"), "security.nesting": "false",
            "boot.autostart": (if bootAutostart: "true" else: "false")},
          "expanded_devices": {"eth0": {"type": "nic", "nictype": nicType}, "root": {"type": "disk", "path": "/", "pool": "default"}}}
        if managedNic: vm["expanded_devices"]["eth0"] = %*{"type": "nic", "network": "incusbr0"}
        return CommandResult(output: $(%*[vm]))
      return CommandResult(output: $(%*{"name": "fake-vm", "status": "Running", "config": limaConfig(2, "4G", "20G")}))
    if "launch" in cmd:
      guestMissing = false
      if "boot.autostart=true" in cmd: bootAutostart = true
    if "config" in cmd and "set" in cmd and "boot.autostart" in cmd: bootAutostart = true
    if "start" in cmd: guestStopped = false
    if input.contains("make build"): guestHash = resolvedSha
    if input.contains(" rev-parse HEAD"): return CommandResult(output: guestHash & "\n")
    if input.contains("call catalog"):
      let id = guestIdentity.copy(); id["gitHash"] = %guestHash

      if drift: id["instanceId"] = %repeat('c', 32)
      return CommandResult(output: $id)
    CommandResult()
  for hosted in [false, true]:
    let ct = %*{"profile": tmp / ("ct-" & $hosted & ".json"), "transport": "incus", "target": "fake-ct", "root": "/home/ubuntu/niffler", "revision": repeat('b', 40)}
    if hosted: ct["host"] = %"operator@hypervisor"
    guestMissing = true; guestHash = repeat('b', 40)
    commands.setLen(0); scripts.setLen(0)
    let installedCt = install(guestRunner, ct)
    check("Incus created with fixed image and limits " & $hosted,
      ($commands).contains("images:ubuntu/24.04") and ($commands).contains("limits.cpu=2") and ($commands).contains("security.privileged=false") and ($commands).contains("root,size=20GB"))
    check("created container starts with the host " & $hosted,
      ($commands).contains("--config") and ($commands).contains("boot.autostart=true") and bootAutostart)
    let bootstrap = firstScript(scripts, "loginctl enable-linger")
    check("Incus bootstrap valid shell " & $hosted, nativeRunner(@["bash", "-n"], bootstrap, 1000).code == 0)
    check("guest-only bootstrap and temporary grant cleanup " & $hosted,
      bootstrap.contains("trap 'rm -f") and bootstrap.contains("noclobber") and bootstrap.contains("visudo -cf") and bootstrap.contains("runuser -u ubuntu") and bootstrap.contains("apt-get install -y git sudo ca-certificates make curl"))
    if hosted:
      check("host persisted and every management command routed via SSH", block:
        var ok = installedCt["receipt"]["host"] == ct["host"] and commands.len > 0
        for c in commands:
          if c[0] != "ssh" or c[^2] != "operator@hypervisor" or not c[^1].startsWith("'incus' '"): ok = false
        ok)
    commands.setLen(0); scripts.setLen(0)
    bootAutostart = false  # an adopted container predates the contract
    discard install(guestRunner, ct)
    check("pinned Incus adoption no launch or root bootstrap " & $hosted,
      not ($commands).contains("launch") and not scripts.join("").contains("loginctl enable-linger"))
    check("adoption sets the container boot policy " & $hosted,
      bootAutostart and ($commands).contains("boot.autostart") and ($commands).contains("config") and ($commands).contains("set"))
    commands.setLen(0)
    discard install(guestRunner, ct)
    check("boot policy already set is left alone " & $hosted,
      not ($commands).contains("boot.autostart"))
    guestStopped = true
    commands.setLen(0)
    check("stopped pinned Incus update refuses before start", rejected(proc() = discard update(guestRunner, %*{"profile": ct["profile"], "revision": resolvedSha})) and commands.len == 1)
    guestStopped = false
    discard update(guestRunner, %*{"profile": ct["profile"], "revision": resolvedSha})
    let rebuild = firstScript(scripts, "make build")
    check("Incus update rebuilds as ubuntu " & $hosted, guestHash == resolvedSha and rebuild.len > 0)
    # A new revision may render a different unit contract, so update refreshes
    # the unit instead of calling install (which would refuse the old one).
    check("Incus update refreshes the unit contract " & $hosted,
      rebuild.contains("server.sh\" refresh") and not rebuild.contains("server.sh\" install"))
    commands.setLen(0); scripts.setLen(0)
    for actionName in ["probe", "status", "logs", "start", "stop", "vm_stop"]:
      discard action(guestRunner, actionName, ct["profile"].getStr())
    check("all Incus execution paths ordinary ubuntu " & $hosted, block:
      var ok = true
      for c in commands:
        let cmd = c.join(" ")
        if "exec" in cmd and (not cmd.contains("runuser") or not cmd.contains("ubuntu") or not cmd.contains("HOME=/home/ubuntu")): ok = false
      ok)
    drift = true
    scripts.setLen(0)
    check("Incus drift blocks update", rejected(proc() = discard update(guestRunner, %*{"profile": ct["profile"], "revision": repeat('e', 40)})) and not scripts.join("").contains("make build"))
    drift = false
    guestMissing = true
    commands.setLen(0)
    check("Incus missing pinned install refuses", rejected(proc() = discard install(guestRunner, ct)) and not ($commands).contains("launch"))
    check("Incus missing pinned update refuses", rejected(proc() = discard update(guestRunner, %*{"profile": ct["profile"], "revision": resolvedSha})))
    check("Incus missing pinned action refuses", rejected(proc() = discard action(guestRunner, "stop", ct["profile"].getStr())))
    guestMissing = false; unsafeGuest = true
    check("unsafe Incus adoption refuses", rejected(proc() = discard install(guestRunner, ct)))
    unsafeGuest = false
    for unsafeNic in ["physical", "sriov", "macvlan"]:
      nicType = unsafeNic
      check("passthrough Incus NIC refuses " & unsafeNic, rejected(proc() = discard install(guestRunner, ct)))
    nicType = "bridged"
    managedNic = true
    discard install(guestRunner, ct)
    networkType = "physical"
    check("managed physical network refuses", rejected(proc() = discard install(guestRunner, ct)))
    networkType = "bridge"; managedNic = false
    # A pool that cannot enforce `root,size=` must refuse BEFORE launch, never
    # hand back a receipt that claims a bounded disk nobody applies.
    let freshCt = %*{"profile": tmp / ("quota-" & $hosted & ".json"), "transport": "incus", "target": "fake-ct", "root": "/home/ubuntu/niffler", "revision": repeat('b', 40)}
    guestMissing = true; dirNoQuota = true
    commands.setLen(0); scripts.setLen(0)
    check("Incus dir pool without project quotas refuses before launch " & $hosted,
      rejected(proc() = discard install(guestRunner, freshCt)) and not ($commands).contains("launch") and not scripts.join("").contains("loginctl enable-linger"))
    dirNoQuota = false
    commands.setLen(0)
    discard install(guestRunner, freshCt)
    check("quota-capable Incus pool proceeds to launch " & $hosted, ($commands).contains("launch") and ($commands).contains("root,size=20GB"))
    guestMissing = false
    let rerouted = ct.copy(); rerouted["host"] = %"other"
    commands.setLen(0)
    check("host drift refuses before any transport", rejected(proc() = discard install(guestRunner, rerouted)) and commands.len == 0)
  let hostedVm = vmArgs.copy(); hostedVm["host"] = %"operator@hypervisor"; hostedVm["profile"] = %(tmp / "hosted-vm.json")
  commands.setLen(0)
  discard install(guestRunner, hostedVm)
  discard action(guestRunner, "vm_stop", hostedVm["profile"].getStr())
  check("Lima host routes list exec and stop with quoted argv", block:
    var ok = true
    for c in commands:
      if c[0] != "ssh" or not c[^1].startsWith("'limactl' '"): ok = false
    ok)
  for host in ["", "-bad", "host;touch evil", "host$(id)", "host\nreboot", "host'quote"]:
    let bad = vmArgs.copy(); bad["host"] = %host; bad["profile"] = %(tmp / "invalid-host.json")
    check("invalid host refuses " & host, rejected(proc() = discard install(guestRunner, bad)))
  let sshHost = args.copy(); sshHost["host"] = %"host"
  check("direct SSH cannot have management host", rejected(proc() = discard install(guestRunner, sshHost)))

  # Actual component registration and tool calls. PATH cannot reach real transports.
  let fakeBin = tmp / "bin"
  createDir(fakeBin)
  let fake = "#!/bin/bash\ninput=$(/bin/cat)\nprintf '%s\\n' \"$*\" >> \"$FLEET_TRACE\"\nif [[ $input == *'call catalog'* ]]; then\n/bin/cat \"$FLEET_IDENTITY\"\nfi\n"
  for executable in ["ssh", "limactl", "incus"]:
    writeFile(fakeBin / executable, fake)
    setFilePermissions(fakeBin / executable, {fpUserRead, fpUserWrite, fpUserExec})
  let idFile = tmp / "identity.json"
  writeFile(idFile, $identity)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var sub: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr sub, nc.conn, "reg.publish")
  defer: natsSubscription_Destroy(sub)
  discard natsConnection_FlushTimeout(nc.conn, 1000)
  let component = startComponent(repo / "var/bin/fleet", url, root = tmp,
    extra = [("PATH", fakeBin & ":/usr/bin:/bin"), ("FLEET_TRACE", tmp / "trace"), ("FLEET_IDENTITY", idFile)])
  defer: stopProcess(component)
  var msg: ptr natsMsg
  let registered = natsSubscription_NextMsg(addr msg, sub, 10000) == NATS_OK
  check("fleet registers", registered)
  if registered:
    let registration = parseJson($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    # SDK announces envelope payload.
    let data = if registration.hasKey("args"): registration["args"] elif registration.hasKey("payload"): registration["payload"] else: registration
    let expected = ["fleet_install", "fleet_probe", "fleet_status",
                    "fleet_logs", "fleet_start", "fleet_stop",
                    "fleet_vm_stop", "fleet_update", "fleet_task_submit",
                    "fleet_task_status", "fleet_task_result",
                    "fleet_task_receipt", "fleet_task_cancel", "fleet_notices"]
    var seen: seq[string]
    if data{"tools"} != nil:
      for tool in data["tools"]: seen.add(tool["name"].getStr())
    var missing: seq[string]
    for want in expected:
      if want notin seen: missing.add(want)
    check("the full fleet tool set registers",
          seen.len == expected.len and missing.len == 0,
          "missing=" & $missing & " seen=" & $seen)
    if data{"tools"} != nil:
      for tool in data["tools"]:
        let name = tool["name"].getStr()
        let ext = tool["schema"]["x-harness"]
        if name == "fleet_notices":
          check("fleet inbox hidden runner machinery", ext{"hidden"}.getBool() and ext{"runner"}.getBool())
          continue
        check(name & " on demand", ext["onDemand"].getBool())
        if name in ["fleet_probe", "fleet_status", "fleet_logs", "fleet_task_status", "fleet_task_result", "fleet_task_receipt"]:
          check(name & " read effect", ext["effect"].getStr() == "read")
        else:
          check(name & " enforced approval", ext["approval"].getStr() == "always")
  let busArgs = args.copy(); busArgs["profile"] = %(tmp / "bus.json")
  let reply = call(nc, "fleet", "fleet_install", busArgs)
  check("bus fake install", reply{"receipt", "expect"} == identity, $reply)
  let busProfile = %*{"profile": tmp / "bus.json"}
  let busProbe = call(nc, "fleet", "fleet_probe", busProfile)
  check("bus fake probe", busProbe{"instanceId"} == identity["instanceId"] and busProbe{"privateLogs"}.len > 0)
  for tool in ["fleet_status", "fleet_logs", "fleet_start", "fleet_stop"]:
    let r = call(nc, "fleet", tool, busProfile)
    check(tool & " bus dispatch", r{"ok"}.getBool(), $r)
  let changed = identity.copy(); changed["instanceId"] = %repeat('c', 32)
  writeFile(idFile, $changed)
  check("bus drift refuses", call(nc, "fleet", "fleet_probe", busProfile).hasKey("error"))
  report("FLEET TEST")

main()
