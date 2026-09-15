## LLM-free contract-v1 fixture compactor.
##
## This is intentionally boring: read the runner's meta snapshot, select the
## first cut covering new canonical data, and return a bounded checkpoint. The
## conformance test uses it under a different tool name to prove that the
## runner, not the default component, owns safety and persistence.

import std/[json, os, strutils]
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
    let checkpointOnly = getEnv("NIF_FIXTURE_CHECKPOINT_ONLY") == "1"
    var cut = cuts[0]
    if not checkpointOnly:
      for candidate in cuts:
        var hasCanonical = false
        for idx in candidate{"fromIndex"}.getInt(1) ..< candidate{"index"}.getInt():
          if meta{"manifest"}[idx]{"source"}.getStr() == "canonical":
            hasCanonical = true
        if hasCanonical:
          cut = candidate
          break
    # The checkpoint-only mode first emits a longer (still reducing) summary,
    # then shortens it. This exercises a valid #ckN-only replacement rather
    # than relying on shorter synthetic ref text to fake token savings.
    let completed = "contract fixture selected a permitted cut" &
      (if checkpointOnly and snapshot{"generation"}.getInt() == 0:
        repeat("; earlier audit detail recorded", 10) else: "")
    # NIF_FIXTURE_LLM_CALLS simulates a component that ignored its granted
    # auxiliary budget: the candidate reports more LLM calls than the
    # snapshot allowed. The runner must reject it (compact:invalid).
    var claimedCalls = 0
    try: claimedCalls = parseInt(getEnv("NIF_FIXTURE_LLM_CALLS", "0"))
    except ValueError: discard
    return %*{
      "version": 1, "status": "candidate", "attemptId": attemptId,
      "baseGeneration": snapshot{"generation"}.getInt(0),
      "snapshotDigest": snapshot{"digest"}.getStr(""),
      "cutBefore": cut{"cutBefore"}, "covered": cut{"covered"},
      "checkpoint": {
        "objective": "fixture-compactor-installed",
        "constraints": ["canonical history remains immutable"],
        "decisions": ["runner owns validation and commit"],
        "completedWork": [completed],
        "currentBlocker": newJNull(),
        "nextSteps": ["continue from retained canonical history"]
      },
      "provenance": {"model": "none", "llmCalls": claimedCalls}
    })

comp.run()
