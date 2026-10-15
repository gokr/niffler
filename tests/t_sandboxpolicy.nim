## Pure policy snapshot contracts. No runtime enforcement is claimed.
import std/json
import helpers
import niffler/sandboxpolicy

let initial = initialSandboxPolicy("/project")
check("default off", not initial.enabled)
check("only explicit workspace roots", initial.readRoots == @["/project"] and
  initial.writeRoots == @["/project"])
check("deny rules are data", initial.denyPatterns == @[".env"])
var parent = initialSandboxPolicy("/project", true)
parent.grants["mcp:server-a"] = %*{"identity": "config-digest"}
var child = inheritSandboxPolicy(parent)
child.grants["mcp:server-a"]["identity"] = %"changed"
child.readRoots.add "/child"
check("child inherits enabled", child.enabled)
check("grant snapshots do not alias", parent.grants{"mcp:server-a"}{"identity"}.getStr() == "config-digest")
check("root snapshots do not alias", parent.readRoots == @["/project"])
let encoded = encodeSandboxPolicy(parent)
check("roundtrip byte stable", $encodeSandboxPolicy(decodeSandboxPolicy(encoded)) == $encoded)
let status = sandboxConfigurationStatus(parent)
check("configuration never attests enforcement", not status{"enforced"}.getBool(true) and
  status{"state"}.getStr() == "configured")
for field in ["version", "enabled", "readRoots", "writeRoots", "denyPatterns", "grants"]:
  var malformed = encoded.copy()
  malformed.delete(field)
  var refused = false
  try: discard decodeSandboxPolicy(malformed)
  except ValueError: refused = true
  check("missing field refuses: " & field, refused)
for value in [ %*{"version": 99}, %*{"enabled": "on"},
               %*{"readRoots": ["relative"]}, %*{"grants": []},
               %*{"unexpected": true} ]:
  var malformed = encoded.copy()
  for key, item in value: malformed[key] = item
  var refused = false
  try: discard decodeSandboxPolicy(malformed)
  except ValueError: refused = true
  check("malformed policy refuses: " & $value, refused)
report("SANDBOX POLICY TEST")
