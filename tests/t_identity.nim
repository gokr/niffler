## Persisted instance identity: separate roots, restarts, renames, bad files.
import std/[os, strutils]
import ../core/identity
import helpers

proc main() =
  let root = tempRoot("identity")
  let other = tempRoot("identity-other")
  defer: removeDir(root)
  defer: removeDir(other)
  let oldName = getEnv("NIF_NAME")
  defer: putEnv("NIF_NAME", oldName)
  putEnv("NIF_NAME", "devbox")
  let first = loadInstanceIdentity(root)
  check("identity is 128-bit lowercase hex", validInstanceId(first.instanceId))
  check("configured instance name", first.name == "devbox")
  check("identity persisted", readFile(root / "var" / "instance-id").strip() == first.instanceId)
  check("restart retains identity", loadInstanceIdentity(root).instanceId == first.instanceId)
  putEnv("NIF_NAME", "renamed")
  let renamed = loadInstanceIdentity(root)
  check("rename changes only label", renamed.name == "renamed" and renamed.instanceId == first.instanceId)
  check("separate roots get separate identities", loadInstanceIdentity(other).instanceId != first.instanceId)
  writeFile(other / "var" / "instance-id", "broken\n")
  var refused = false
  try: discard loadInstanceIdentity(other)
  except ValueError: refused = true
  check("malformed identity refuses, never replaces", refused and readFile(other / "var" / "instance-id") == "broken\n")
  report("INSTANCE IDENTITY")

main()
