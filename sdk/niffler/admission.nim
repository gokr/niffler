## Durable task admission — the worker-side idempotency key for one delegated
## turn (docs/FLEET.md §4, slice F1).
##
## A remote requester (the optional fleet component) cannot tell a lost reply
## from a turn that never started. Retrying blindly can run work twice; giving
## up leaves an unknown job forever. The fix is one durable record on the
## WORKER, keyed by a requester-chosen admission key, written before any turn
## starts and carrying the immutable normalized birth settings plus a digest
## of them:
##
## - an exact retry (same key, same digest) may return the existing acceptance
##   or terminal receipt, and NEVER runs another turn;
## - a different digest under the same key is refused (an accepted admission
##   is immutable);
## - the accepted → running transition is a compare-and-set: a crash before it
##   proves no turn ran (safe to resume), a crash after it is honestly unknown
##   instead of a silent second execution.
##
## Core owns admission (the runner writes the record); Fleet only holds the
## pointer. Nothing here knows about Fleet: the key, the version and the
## receipt shape are the generic seam, and an unsupported peer version refuses
## before dispatch. This module is pure (no store access, no bus) so both the
## runner (conversation.nim) and the system core (dispatch.nim) can share the
## record shape and validation.

import std/[algorithm, json, times]
import checksums/sha2
import canonicaljson

const
  admissionKind* = "admission"
    ## Store kind; id = "<sessionId>:<key>" (both bounded, so the id is too).
  admissionPolicyVersion* = 1
    ## Version of the normalized birth-settings schema below. A requester that
    ## needs a different policy refuses rather than guessing; the digest binds
    ## the version, so an admission recorded under another policy can never be
    ## mistaken for this one.
  admissionStateAccepted* = "accepted"
    ## Durably accepted, provably not started (the CAS to `running` has not
    ## committed). The only state a retry may start from.
  admissionStateRunning* = "running"
    ## A turn may have started. Never restarted; no terminal receipt yet.
  admissionStateSettled* = "settled"
    ## Terminal: `turnId`, `outcome` and usage are the activation's receipt.

type
  AdmissionStartOutcome* = enum
    asFresh         ## this call owns the activation and must run the turn
    asDuplicate     ## an identical admission exists; run nothing, report it
    asResumed       ## accepted but never started; this call starts it
    asRefused       ## no admission recorded, no turn started

  AdmissionStart* = object
    outcome*: AdmissionStartOutcome
    record*: JsonNode        ## durable record (nil when refused)
    rev*: int                ## its store revision (needed for the CS writes)
    error*: string           ## human refusal text when asRefused

proc validAdmissionKey*(key: string): bool =
  ## Store-id and bus-safe: the key is half of the record id, so it is bounded
  ## and restricted rather than escaped — an unspellable key is refused, never
  ## silently mangled (a mangled key would break exactly-once).
  if key.len < 1 or key.len > 128: return false
  for ch in key:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}: return false
  true

proc admissionDocId*(sessionId, key: string): string =
  sessionId & ":" & key

proc requestedAdmissionKey*(args: JsonNode): string =
  ## The admission key a session call carries, from
  ## `admission: {key, policyVersion?}` (or the bare string shorthand).
  ## "" means the call is an ordinary turn — admission is opt-in per call, so
  ## every existing driver keeps working unchanged.
  let a = args{"admission"}
  if a == nil: return ""
  if a.kind == JString: return a.getStr("")
  a{"key"}.getStr("")

proc requestedAdmissionPolicy*(args: JsonNode): int =
  let a = args{"admission"}
  if a == nil or a.kind != JObject: return admissionPolicyVersion
  let v = a{"policyVersion"}
  if v == nil or v.kind == JNull: return admissionPolicyVersion
  v.getInt(0)

proc hasAdmissionRequest*(args: JsonNode): bool =
  ## Whether the caller ASKED for durable admission at all — independent of
  ## whether its key is usable. A present-but-empty or garbled `admission` is
  ## REFUSED rather than quietly downgraded to an ordinary turn: the requester
  ## would believe its work was idempotently recorded when nothing was, and a
  ## retry after a lost reply could run it twice.
  args{"admission"} != nil

proc birthSettings*(args: JsonNode, workspace: string): JsonNode =
  ## The immutable, normalized birth settings of an admitted turn: everything
  ## that decides what the worker is allowed to do and how much it may spend.
  ## Deliberately normalized (sorted, deduped tools; integers defaulted to 0)
  ## so the same intent hashes the same whatever order or spelling the
  ## requester's JSON used. Deliberately NOT everything in the call: approval
  ## mode, wake/heartbeat markers and titles are not birth authority, and a
  ## retry that reformats them must not look like different work.
  var tools: seq[string] = @[]
  let listed = args{"tools"}
  if listed != nil and listed.kind == JArray:
    for entry in listed:
      let name = entry.getStr("")
      if name.len > 0 and name notin tools: tools.add(name)
  tools.sort()
  result = %*{
    "policyVersion": admissionPolicyVersion,
    "workspace": workspace,
    "content": args{"content"}.getStr(""),
    "tools": %tools,
    "maxRounds": args{"maxRounds"}.getInt(0),
    "maxCalls": args{"maxCalls"}.getInt(0),
    "maxTokens": args{"maxTokens"}.getInt(0)}
  # Birth identity fields: present only when the requester asked for them, so
  # "" and absent hash alike (an empty value never widens authority).
  for key in ["agent", "model", "provider", "thinking", "toolset"]:
    let value = args{key}.getStr("")
    if value.len > 0: result[key] = %value
  # A task grant is authority-bearing input, not retry metadata. Bind the
  # complete requested grant so the same key cannot name a different profile,
  # workspace, tool set or budget. Legacy non-task digests remain unchanged.
  if args{"task"} != nil: result["task"] = args["task"].copy()

proc admissionDigest*(settings: JsonNode): string =
  ## SHA-256 over canonical JSON: identity of the admitted work, not a
  ## security primitive (a requester that can write the store can write
  ## anything; the digest only has to make "same key, different work"
  ## impossible to confuse).
  var st = initSha_256()
  st.update(canonicalJson(settings))
  "sha256:" & $st.digest()

proc newAdmission*(sessionId, key, digest: string, settings: JsonNode): JsonNode =
  ## The `accepted` record, written before any turn can run. Kept small: it is
  ## read on every retry and by the requester's reconciliation, so the report
  ## text lives in the conversation transcript, never here.
  %*{"id": admissionDocId(sessionId, key), "sessionId": sessionId,
     "key": key, "activation": 1, "digest": digest,
     "policyVersion": admissionPolicyVersion, "settings": settings,
     "state": admissionStateAccepted, "acceptedAt": epochTime()}

proc admissionMatches*(record: JsonNode, digest: string): bool =
  record != nil and record.kind == JObject and
    record{"digest"}.getStr("") == digest

proc settledOutcome*(turnOutcome: string): string =
  ## Turn accounting → the admission/activity outcome vocabulary. The same
  ## mapping the human completion receipt uses, so a requester reading either
  ## record sees one vocabulary: done | cancelled | budget-exhausted |
  ## needs-attention | failed. Deliberately not "success": a settled activation
  ## is not a verified task.
  case turnOutcome
  of "success": "done"
  of "cancelled": "cancelled"
  of "budget-exhausted", "limit-exhausted": "needs-attention"
  else: "failed"

proc settleAdmission*(record: JsonNode, turnId, turnOutcome: string,
                      usage: JsonNode, reply: string, replyDigest: string,
                      transcriptCommitted: bool): JsonNode =
  ## The terminal receipt of ONE activation. `transcriptCommitted` is the
  ## runner's own statement that this turn's transcript writes all landed: a
  ## receipt for a turn whose history was partially lost would let a requester
  ## believe in a report that is not durably there, so a failed transcript
  ## leaves the record `running` (unknown) instead.
  result = record.copy()
  result["state"] = %admissionStateSettled
  result["turnId"] = %turnId
  result["outcome"] = %settledOutcome(turnOutcome)
  result["turnOutcome"] = %turnOutcome
  result["usage"] = usage
  result["replyChars"] = %reply.len
  result["replyDigest"] = %replyDigest
  result["transcriptCommitted"] = %transcriptCommitted
  result["settledAt"] = %epochTime()

proc publicAdmission*(record: JsonNode): JsonNode =
  ## The receipt as a requester sees it: no key internals beyond what it sent,
  ## no settings echo (it already holds those), bounded fields only.
  if record == nil: return nil
  result = newJObject()
  # `taskPolicy` is included on purpose: a requester (and any human) must be
  # able to see the AUTHORITY the work ran under, not just its outcome. It is
  # the intersected public policy — the operator's private note was already
  # stripped when it was written.
  #
  # `artifact` likewise, and for the same reason: the change a task produced IS
  # its result. A receipt that reports a summary but withholds the commit makes
  # the summary unfalsifiable (docs/FLEET.md §6).
  for key in ["id", "sessionId", "key", "activation", "state", "digest",
              "policyVersion", "acceptedAt", "startedAt", "turnId", "outcome",
              "turnOutcome", "usage", "replyChars", "replyDigest",
              "transcriptCommitted", "settledAt", "taskPolicy", "workspace",
              "confinement", "artifact"]:
    if record{key} != nil: result[key] = record[key]
