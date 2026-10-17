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
  let runner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    commands.add(argv); scripts.add(input)
    if argv == @["multipass", "list", "--format", "json"]:
      return CommandResult(output: (if missingVm: "{\"list\":[]}" else: "{\"list\":[{\"name\":\"fake-vm\",\"state\":\"Running\"}]}"))
    if argv.len > 3 and argv[0] == "git" and argv[1] == "ls-remote":
      # Only the refs this fixture knows about resolve; anything else is empty,
      # which is how a bogus ref reaches the refusal.
      for pattern in argv[3 .. ^1]:
        if pattern in ["main", "refs/heads/main"]:
          return CommandResult(output: resolvedSha & "\trefs/heads/main")
      return CommandResult(output: "")
    if input.contains("call catalog"):
      let id = identity.copy()
      id["gitHash"] = %currentHash
      if drift: id["instanceId"] = %repeat('c', 32)
      return CommandResult(output: $id)
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
  vmArgs["transport"] = %"multipass"; vmArgs["target"] = %"fake-vm"; vmArgs["profile"] = %(tmp / "vm.json")
  missingVm = true
  let vmInstalled = install(runner, vmArgs)
  check("VM provenance recorded without mounts", vmInstalled["receipt"]["createdVm"].getBool() and ($commands).find("mount") < 0)
  commands.setLen(0)
  check("missing pinned VM refuses recreation", rejected(proc() = discard install(runner, vmArgs)) and commands.len == 1)
  missingVm = false
  commands.setLen(0); scripts.setLen(0)
  discard install(runner, vmArgs)
  check("running VM adoption never launches", not ($commands).contains("launch"))
  commands.setLen(0); scripts.setLen(0)
  discard action(runner, "stop", profile)
  check("service stop distinct from VM stop", commands.len == 1 and scripts[0].contains("server.sh stop") and not scripts[0].contains("multipass"))
  commands.setLen(0)
  discard action(runner, "vm_stop", vmArgs["profile"].getStr())
  check("VM stop never delete", commands[^1] == @["multipass", "stop", "fake-vm"])
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

  # Actual component registration and tool calls. PATH cannot reach real transports.
  let fakeBin = tmp / "bin"
  createDir(fakeBin)
  let fake = "#!/bin/bash\ninput=$(/bin/cat)\nprintf '%s\\n' \"$*\" >> \"$FLEET_TRACE\"\nif [[ $input == *'call catalog'* ]]; then\n/bin/cat \"$FLEET_IDENTITY\"\nfi\n"
  for executable in ["ssh", "multipass"]:
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
                    "fleet_vm_stop", "fleet_update"]
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
        check(name & " on demand", ext["onDemand"].getBool())
        if name in ["fleet_probe", "fleet_status", "fleet_logs"]:
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
