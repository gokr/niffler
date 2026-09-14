## LLM-free contract-v1 fixture compactor.
##
## This is intentionally boring: read the runner's meta snapshot, select the
## first permitted cut, and return a bounded deterministic checkpoint. The
## conformance test uses it under a different tool name to prove that the
## runner, not the default component, owns safety and persistence.

import std/json
import niffler/sdk

let comp = newComponent("fixture-compaction", "contract-fixture-1")
let schema = toolSchema(%*{
  "version": {"type": "integer"},
  "sessionId": {"type": "string"},
  "attemptId": {"type": "string"},
  "snapshot": {"type": "object"},
  "budget": {"type": "object"}
}, required = @["version", "sessionId", "attemptId", "snapshot", "budget"],
  description = "Deterministic LLM-free contract-v1 compactor fixture.")
schema["x-harness"] = %*{"hidden": true, "runner": true,
                         "timeoutMs": 15_000, "effect": "read"}

discard comp.tool("fixture_compaction_propose", schema,
  proc(c: Component, args: JsonNode): JsonNode =
    if args{"version"}.getInt(0) != 1:
      return errResult("unsupported contract version", "bad-request")
    let attemptId = args{"attemptId"}.getStr("")
    let snapshot = args{"snapshot"}
    let refId = snapshot{"ref"}{"id"}.getStr("")
    let meta = c.storeGet("compaction_input", refId).value
    if meta == nil:
      return errResult("fixture snapshot missing", "not-found")
    let cuts = meta{"permittedCuts"}
    if cuts == nil or cuts.kind != JArray or cuts.len == 0:
      return %*{"version": 1, "status": "declined",
                 "attemptId": attemptId, "reason": "no-useful-cut"}
    let cut = cuts[0]
    return %*{
      "version": 1, "status": "candidate", "attemptId": attemptId,
      "baseGeneration": snapshot{"generation"}.getInt(0),
      "snapshotDigest": snapshot{"digest"}.getStr(""),
      "cutBefore": cut{"cutBefore"}, "covered": cut{"covered"},
      "checkpoint": {
        "objective": "fixture-compactor-installed",
        "constraints": ["canonical history remains immutable"],
        "decisions": ["runner owns validation and commit"],
        "completedWork": ["contract fixture selected a permitted cut"],
        "currentBlocker": newJNull(),
        "nextSteps": ["continue from retained canonical history"]
      },
      "provenance": {"model": "none", "llmCalls": 0}
    })

comp.run()
