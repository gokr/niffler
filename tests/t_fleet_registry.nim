## Fleet instance registry — routes are store documents, not a local file.
##
## Boots a real store + fleet pair on a private bus and proves the contract:
## an explicitly imported verified receipt becomes the authoritative registry
## entry; a corrupted document refuses at load instead of becoming a route;
## listing reports it visibly rather than hiding it; and re-importing the same
## instance updates in place (no duplicate identity). Fake transports only — no
## remote host is contacted and no real credentials are used.

import std/[json, os, strutils]
import natsnim
import helpers

proc writeReceipt(path: string, identity: string, target = "user@fake") =
  let p = %*{"version": 1, "transport": "ssh", "target": target,
             "root": "/srv/niffler", "expect": {
               "instanceId": identity, "name": "fake", "root": "/srv/niffler",
               "gitHash": repeat('b', 40)}}
  writeFile(path, p.pretty() & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["store-sqlite", "fleet"]:
    if not fileExists(repo / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let tmp = tempRoot("fleetreg")
  defer: removeDir(tmp)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let store = startComponent(repo / "var" / "bin" / "store-sqlite", url, root = tmp)
  defer: stopProcess(store)
  check("store registers", waitRegistered(nc, "store"))

  # A fake SSH that answers the catalog with our pinned identity (import never
  # calls it, but the fleet component must not need one for a registry write).
  let fakeBin = tmp / "bin"
  createDir(fakeBin)
  writeFile(fakeBin / "ssh", "#!/bin/bash\n/bin/cat \"$FLEET_IDENTITY\"\n")
  setFilePermissions(fakeBin / "ssh", {fpUserRead, fpUserWrite, fpUserExec})
  let idFile = tmp / "identity.json"
  writeFile(idFile, $ %*{"instanceId": repeat('a', 32), "name": "fake",
                         "root": "/srv/niffler", "gitHash": repeat('b', 40)})
  createDir(tmp / "logs")
  let fleet = startComponent(repo / "var" / "bin" / "fleet", url, root = tmp,
    logFile = tmp / "logs" / "fleet.log",
    extra = [("PATH", fakeBin & ":/usr/bin:/bin"), ("FLEET_IDENTITY", idFile)])
  defer: stopProcess(fleet)
  check("fleet registers", waitRegistered(nc, "fleet"))

  let identity = repeat('a', 32)
  let other = repeat('c', 32)
  let receipt = tmp / "peer.json"
  writeReceipt(receipt, identity)

  let empty = call(nc, "fleet", "fleet_instances", %*{})
  check("an empty registry lists nothing", empty{"ok"}.getBool(false) and
        empty{"count"}.getInt(-1) == 0, $empty)

  let imported = call(nc, "fleet", "fleet_instance_import", %*{"profile": receipt})
  check("a verified receipt imports into the registry",
        imported{"ok"}.getBool(false) and imported{"instanceId"}.getStr() == identity,
        $imported)
  check("import leaves the receipt file alone and readable",
        fileExists(receipt))

  let listed = call(nc, "fleet", "fleet_instances", %*{})
  check("registry lists the imported instance by stable identity",
        listed{"count"}.getInt(0) == 1 and
        listed{"instances"}[0]{"instanceId"}.getStr() == identity and
        listed{"instances"}[0]{"transport"}.getStr() == "ssh", $listed)

  # Re-import is an update, not a duplicate entry.
  writeReceipt(receipt, identity, target = "user@renamed")
  discard call(nc, "fleet", "fleet_instance_import", %*{"profile": receipt})
  let again = call(nc, "fleet", "fleet_instances", %*{})
  check("re-import updates in place", again{"count"}.getInt(0) == 1 and
        again{"instances"}[0]{"target"}.getStr() == "user@renamed", $again)

  # The registry stores the receipt's identity, so a second instance coexists.
  let second = tmp / "second.json"
  writeReceipt(second, other)
  discard call(nc, "fleet", "fleet_instance_import", %*{"profile": second})
  check("two instances coexist in one registry",
        call(nc, "fleet", "fleet_instances", %*{}){"count"}.getInt(0) == 2)

  # A corrupted document refuses at load: no route is invented from it.
  let put = call(nc, "store", "put", %*{"kind": "fleetinstance", "id": other,
    "value": {"version": 1, "transport": "ssh", "target": "-oProxyCommand=bad"}})
  check("corrupt registry document stored for the test", put{"ok"}.getBool(false), $put)
  let after = call(nc, "fleet", "fleet_instances", %*{})
  var sawInvalid = false
  for item in after{"instances"}:
    if item{"instanceId"}.getStr() == other and item{"invalid"}.getBool(false):
      sawInvalid = true
  check("a corrupt entry is reported, not silently dropped", sawInvalid, $after)
  let used = call(nc, "fleet", "fleet_probe", %*{"profile": receipt})
  check("registry documents are not used as routes implicitly",
        used{"ok"}.getBool(false) == false or used{"error"} != nil, $used)

  report("FLEET REGISTRY TEST")

main()
