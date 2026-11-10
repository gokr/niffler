## Pure policy snapshot contracts. No runtime enforcement is claimed.
import std/[json, strutils, sequtils]
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
# --- grant edits: the parts a root change must NOT disturb -----------------
var edit = initialSandboxPolicy("/project", true)
edit.addGrant("/data")
check("a grant widens both directions", "/data" in edit.readRoots and
  "/data" in edit.writeRoots)
edit.addGrant("/data")
check("a repeated grant does not duplicate", edit.readRoots.count("/data") == 1)
check("a grant never touches enablement", edit.enabled)
check("a grant never drops a deny rule", edit.denyPatterns == @[".env"])
edit.removeGrant("/data")
check("a revoke removes both directions", "/data" notin edit.readRoots and
  "/data" notin edit.writeRoots)
check("a revoke keeps the workspace and the denies",
  "/project" in edit.readRoots and edit.denyPatterns == @[".env"])
var bad = initialSandboxPolicy("/project")
for rejected in ["relative/dir", "/tmp/with\0nul"]:
  var refused = false
  try: bad.addGrant(rejected)
  except ValueError: refused = true
  check("a grant refuses " & rejected, refused)
# A child born in a DIFFERENT tree must be able to work there, or an inherited
# policy names only the parent's checkout and the child can write nowhere.
var inherited = inheritSandboxPolicy(edit)
inherited.ensureWorkspace("/child-tree")
check("ensureWorkspace adds the child's own tree",
  "/child-tree" in inherited.readRoots and "/child-tree" in inherited.writeRoots)
check("ensureWorkspace keeps the parent's roots",
  "/project" in inherited.readRoots)
check("ensureWorkspace leaves enablement alone", inherited.enabled)

report("SANDBOX POLICY TEST")
