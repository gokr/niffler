## Pure resolver contract: explicit overrides, validation and no approval grant.
import std/json
import niffler/agentdefs
import helpers

let doc = %*{"name": "reviewer", "persona": "reviewer", "toolset": "read",
            "model": "test-model", "maxCalls": 20}
let reader: DefinitionReader = proc(kind, id: string): JsonNode =
  if id == "reviewer": doc else: nil
let resolved = resolveAgentDefinition(%*{"agent": "reviewer", "model": "override"}, reader)
check("definition supplies missing defaults", resolved{"persona"}.getStr() == "reviewer" and
      resolved{"toolset"}.getStr() == "read" and resolved{"maxCalls"}.getInt() == 20)
check("explicit model wins", resolved{"model"}.getStr() == "override")
let empty = resolveAgentDefinition(%*{"agent": "reviewer", "persona": "", "profile": ""}, reader)
check("explicit empty values win", empty{"persona"}.getStr() == "" and empty{"toolset"} == nil)
check("input document is unchanged", doc{"model"}.getStr() == "test-model")
var refused = false
try: discard resolveAgentDefinition(%*{"agent": "absent"}, reader)
except ValueError: refused = true
check("missing agent fails closed", refused)
doc["approvals"] = %"auto"
refused = false
try: discard resolveAgentDefinition(%*{"agent": "reviewer"}, reader)
except ValueError: refused = true
check("definition cannot grant approvals", refused)
report("AGENT DEFINITIONS")
