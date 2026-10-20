## Durable worker admission (docs/FLEET.md §4, slice F1): the pure record and
## idempotency contracts. No bus, store or model.
import std/[json, strutils]
import helpers
import ../core/admission
import ../sdk/envelope

proc rejected(body: proc()): bool =
  try: body()
  except CatchableError: return true

proc main() =
  # --- key shape: bounded, id-safe, never silently mangled ------------------
  for good in ["abc", "fleet-1234", "a.b_c:d", repeat('a', 128)]:
    check("key accepted: " & good[0 .. min(9, good.len - 1)], validAdmissionKey(good))
  for bad in ["", repeat('a', 129), "has space", "a/b", "a\nb", "a$b", "k%2F"]:
    check("key refused: " & bad.escape, not validAdmissionKey(bad))
  check("doc id binds session and key",
        admissionDocId("conv-1", "k") == "conv-1:k")

  # --- request shape: opt-in per call --------------------------------------
  check("no admission argument is an ordinary turn",
        requestedAdmissionKey(%*{"sessionId": "s"}) == "")
  check("object form", requestedAdmissionKey(
        %*{"admission": {"key": "k1", "policyVersion": 1}}) == "k1")
  check("string shorthand", requestedAdmissionKey(%*{"admission": "k1"}) == "k1")
  check("policy defaults to this harness's version",
        requestedAdmissionPolicy(%*{"admission": {"key": "k"}}) ==
        admissionPolicyVersion)
  check("explicit other policy is readable and refused downstream",
        requestedAdmissionPolicy(
          %*{"admission": {"key": "k", "policyVersion": 99}}) == 99)

  # --- birth settings: normalized, immutable identity of the WORK ----------
  let args = %*{"content": "fix the bug", "tools": ["grep", "read", "read"],
    "maxRounds": 4, "maxCalls": 9, "maxTokens": 1000, "approvals": "auto",
    "model": "m1"}
  let reordered = %*{"content": "fix the bug", "tools": ["read", "grep"],
    "maxRounds": 4, "maxCalls": 9, "maxTokens": 1000, "model": "m1"}
  let settings = birthSettings(args, "/work")
  let digest = admissionDigest(settings)
  check("tools are normalized (order/duplicates do not change identity)",
        admissionDigest(birthSettings(reordered, "/work")) == digest and
        settings["tools"].len == 2)
  check("approval mode is not birth authority",
        birthSettings(%*{"content": "x", "tools": ["read"], "approvals": "auto"},
                      "/work").hasKey("approvals") == false)
  check("policy version is bound into the digest",
        settings["policyVersion"].getInt(-1) == admissionPolicyVersion)
  let otherWorkspace = admissionDigest(birthSettings(reordered, "/elsewhere"))
  check("workspace is birth identity", otherWorkspace != digest)
  let wider = reordered.copy(); wider["tools"] = %*["read", "grep", "bash"]
  check("a wider tool grant is different work",
        admissionDigest(birthSettings(wider, "/work")) != digest)
  let richer = reordered.copy(); richer["maxCalls"] = %10
  check("a larger budget is different work",
        admissionDigest(birthSettings(richer, "/work")) != digest)
  let omitted = %*{"content": "fix the bug", "tools": ["read", "grep"],
    "maxRounds": 4, "maxCalls": 9}
  check("an unset budget and an explicit 0 are the same absence",
        admissionDigest(birthSettings(omitted, "/work")) ==
        admissionDigest(birthSettings(%*{"content": "fix the bug",
          "tools": ["read", "grep"], "maxRounds": 4, "maxCalls": 9,
          "maxTokens": 0}, "/work")))

  # --- record lifecycle ----------------------------------------------------
  let rec = newAdmission("conv-1", "k1", digest, settings)
  check("a fresh admission is accepted and activation 1",
        rec["state"].getStr() == admissionStateAccepted and
        rec["activation"].getInt() == 1)
  check("exact retry matches", admissionMatches(rec, digest))
  check("same key, different work does not match",
        not admissionMatches(rec, otherWorkspace))
  check("a missing record never matches", not admissionMatches(nil, digest))
  let settled = settleAdmission(rec, "turn-9", "success",
    %*{"promptTokens": 10, "outcome": "done"}, "the report", "sha256:abc", true)
  check("terminal receipt binds turn, outcome, usage and transcript state",
        settled["state"].getStr() == admissionStateSettled and
        settled["turnId"].getStr() == "turn-9" and
        settled["outcome"].getStr() == "done" and
        settled["usage"]["promptTokens"].getInt() == 10 and
        settled["transcriptCommitted"].getBool() and
        settled["replyDigest"].getStr() == "sha256:abc" and
        settled["replyChars"].getInt() == "the report".len)
  check("settlement does not mutate the accepted record",
        rec["state"].getStr() == admissionStateAccepted and not rec.hasKey("turnId"))
  check("turn accounting maps onto the receipt vocabulary",
        settledOutcome("success") == "done" and
        settledOutcome("cancelled") == "cancelled" and
        settledOutcome("budget-exhausted") == "needs-attention" and
        settledOutcome("limit-exhausted") == "needs-attention" and
        settledOutcome("aborted") == "failed" and
        settledOutcome("error") == "failed")
  let failedTranscript = settleAdmission(rec, "turn-9", "success", newJObject(),
    "report", "", false)
  check("a lost transcript is recorded, not hidden",
        not failedTranscript["transcriptCommitted"].getBool())
  let public = publicAdmission(settled)
  check("the public receipt keeps the terminal accountability fields",
        public["state"].getStr() == admissionStateSettled and
        public["outcome"].getStr() == "done" and public.hasKey("settledAt"))
  check("the public receipt omits the birth-settings echo",
        not public.hasKey("settings") and public.hasKey("key") and
        public.hasKey("turnId") and public.hasKey("digest"))

  # --- envelope carriage: the key survives the wire, the runner sees it ----
  let env = callEnvelope("session", %*{"sessionId": "conv-1",
    "content": "do it", "admission": {"key": "k1", "policyVersion": 1}})
  let back = decode(env.encode())
  check("admission rides the call envelope as ordinary JSON",
        requestedAdmissionKey(back.args) == "k1" and
        requestedAdmissionPolicy(back.args) == 1)
  report("FLEET ADMISSION TEST")

main()
