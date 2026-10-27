## Task policy — what a delegated task may do unattended on its worker
## (docs/FLEET.md §5, slice F2).
##
## Two independent decisions, intersected here:
##
## 1. the WORKER OPERATOR's profile (`taskprofile` store document) says which
##    tools, roots and budget ceilings may ever run unattended on this machine;
## 2. the REQUESTING HUMAN's grant for this exact task names a profile and its
##    budgets, and is approved at submission.
##
## The caller's arguments can only ever NARROW the peer's ceiling; anything
## wider is refused with the reason, never clamped silently. Unattended
## authority defaults to absent: no profile, or a profile that does not allow
## unattended runs, means an honest refusal — never "start in ask mode and wait
## for a human who is not attached".
##
## Pure module (std/json only): the runner resolves and enforces, the system
## core re-computes for `admission_get`, and the requester validates a peer's
## advertised capability the same way. Keeping the arithmetic in one place is
## what stops the three from disagreeing about what was authorized.

import std/[algorithm, json, os, strutils]
import checksums/sha2
import canonicaljson
import jsonx

proc normalizeTaskRoot(path: string): string =
  ## Canonical filesystem identity for policy comparisons; no bus/core state.
  if path.len == 0: return ""
  result = path
  try: result = expandFilename(absolutePath(result))
  except CatchableError:
    try: result = absolutePath(result)
    except CatchableError: discard
  while result.len > 1 and result[^1] == '/': result.setLen(result.len - 1)

const
  taskProfileKind* = "taskprofile"
    ## Store kind owned by the worker operator. A profile is written
    ## out-of-band (operator with bus access: store put), never by the model.
  taskPolicyVersion* = 1
    ## Version of the effective-policy schema. Peers advertise
    ## `taskPolicyVersion` in catalog components/snapshot; a requester that
    ## needs unattended authority refuses a peer without the matching version.
  delegationSettingsKind* = "delegation"
    ## Worker-owned settings for goal delegation (docs/FLEET-SIMPLIFICATION.md):
    ## ONE explicit trust decision by the operator, instead of a profile
    ## reconstructed per assignment. Same document shape as a task profile, so
    ## the same validation and confinement honesty apply.
  delegationSettingsId* = "settings"
  delegationPolicyVersion* = 1
    ## Advertised as `delegationPolicyVersion` in catalog components/snapshot.
    ## A requester that asks for goal delegation refuses an older peer rather
    ## than silently downgrading to `ask` (a task that starts and waits for an
    ## approval nobody will give).
  delegationProfileName* = "trusted-delegation"
    ## The name an effective policy carries when it came from the delegation
    ## settings rather than a named `taskProfile`.
  maxProfileNameBytes* = 64

  # The control plane is never reachable from an unattended task. This is an
  # authority boundary expressed as data in one place, checked on BOTH sides:
  #   - single-hop delegation must not become an indirect second hop
  #     (fleet_*, agent, invoke, fabric, session_prepare);
  #   - the harness must not be reconfigurable by a task (spawn/kill/remove,
  #     builder, plugins, mcp, toolset/profile, conversation_delete);
  #   - the record-keeping seam must not be forgeable by the task it records
  #     (admission_get, taskprofile, heartbeat, ui).
  # A tool-name deny list is not a sandbox — together with `bash` it is
  # documented as trusted/unconfined execution below, and the policy says so.
  controlPlaneTools* = [
    "fleet_install", "fleet_update", "fleet_probe", "fleet_status",
    "fleet_logs", "fleet_start", "fleet_stop", "fleet_vm_stop",
    "fleet_task_submit", "fleet_task_status", "fleet_task_result",
    "fleet_task_receipt", "fleet_task_cancel", "fleet_notices",
    "agent", "agent_spawn", "agent_run", "agent_status", "agent_kill",
    "agent_notices", "agent_mail",
    "invoke", "fabric", "session", "session_prepare", "session_info",
    "spawn", "kill", "remove", "builder", "build", "build_package",
    "task_profile_set", "task_profile_list", "task_profile_remove",
    "plugins", "plugin_install",
    "plugin_remove", "plugin_update", "mcp", "toolset", "profile",
    "conversation_delete", "admission_get", "taskprofile", "heartbeat_set",
    "heartbeat_list", "heartbeat_remove", "ui", "put", "del"]

type
  PolicyRefusal* = object
    ## A refused unattended request: `reason` is for the human, `code` is the
    ## stable machine name (docs/WIRE.md "Task policy").
    code*: string
    reason*: string

proc refusePolicy*(code, reason: string): PolicyRefusal =
  PolicyRefusal(code: code, reason: reason)

proc isControlPlane*(tool: string): bool =
  ## Callable names, not just component labels. Prefixes cover extensions to
  ## orchestration/profile families without silently granting new control tools.
  tool in controlPlaneTools or
    tool.startsWith("fleet_") or tool.startsWith("agent_") or
    tool.startsWith("session_") or tool.startsWith("heartbeat_") or
    tool.startsWith("task_profile_") or tool.startsWith("plugin_") or
    tool.startsWith("mcp_")

proc validProfileName*(name: string): bool =
  if name.len < 1 or name.len > maxProfileNameBytes: return false
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: return false
  true

proc normalizePolicyJson*(n: JsonNode): string =
  ## Canonical JSON with sorted keys — the digest material of an effective
  ## policy, so two spellings of the same authority cannot disagree.
  canonicalJson(n)

proc policyDigest*(policy: JsonNode): string =
  ## Binds a grant to the exact effective policy. The requester echoes it and
  ## the worker's admission receipt records it, so "this task ran under that
  ## authority" is checkable years later without trusting either transcript.
  ##
  ## The document's own `digest` field is excluded, so a policy and its
  ## published form (publicPolicy adds the digest it carries) hash the same —
  ## otherwise a stored copy could never be compared back to the policy it
  ## came from.
  var st = initSha_256()
  if policy != nil and policy.kind == JObject:
    var body = newJObject()
    for key, value in policy:
      if key != "digest": body[key] = value
    st.update(normalizePolicyJson(body))
  else:
    st.update(normalizePolicyJson(policy))
  "sha256:" & $st.digest()

proc taskProfileProblem*(doc: JsonNode): string =
  ## Operator-profile validation. The document is read from the store at
  ## admission time (never trusted from a caller), so this is the gate that
  ## keeps a malformed or over-broad profile from granting anything.
  if doc == nil or doc.kind != JObject: return "profile document must be an object"
  for key, value in doc:
    case key
    of "name", "description":
      if value.kind != JString: return key & " must be a string"
    of "unattended":
      if value.kind != JBool: return "unattended must be a boolean"
    of "tools":
      if value.kind != JArray: return "tools must be an array"
      if value.len == 0: return "tools must list at least one tool"
      if value.len > 32: return "tools lists more than 32 tools"
      for item in value:
        if item.kind != JString or item.getStr("").strip().len == 0:
          return "tools entries must be nonempty strings"
    of "roots":
      if value.kind != JArray: return "roots must be an array"
      for item in value:
        if item.kind != JString: return "roots entries must be strings"
        let raw = item.getStr("").strip()
        if raw.len == 0 or not raw.isAbsolute():
          return "roots entries must be absolute paths"
        if raw == "/":
          return "refusing the filesystem root as a task root"
    of "maxRounds":
      if value.kind != JInt: return "maxRounds must be an integer"
    of "maxCalls":
      if value.kind != JInt: return "maxCalls must be an integer"
    of "maxTokens":
      if value.kind != JInt: return "maxTokens must be an integer"
    of "confinement":
      if value.kind != JString: return "confinement must be a string"
      if value.getStr("") notin ["unconfined", "sandbox"]:
        return "confinement must be 'unconfined' or 'sandbox'"
    of "note":
      if value.kind != JString: return "note must be a string"
    else:
      return "unsupported profile field: " & key
  ""

proc profileToolList*(doc: JsonNode): seq[string] =
  var listed: seq[string] = @[]
  for item in doc{"tools"}.listOf:
    let name = item.getStr("").strip()
    if name.len > 0 and name notin listed: listed.add(name)
  listed.sort()
  listed

proc profileRoots*(doc: JsonNode): seq[string] =
  for item in doc{"roots"}.listOf:
    let norm = normalizeTaskRoot(item.getStr("").strip())
    if norm.len > 0 and norm notin result: result.add(norm)

proc rootAllowed*(roots: openArray[string], path: string): bool =
  ## A task may only touch a workspace that IS or lives UNDER an approved
  ## root. Symlinks are already resolved by the caller (normalizeRoot), so this
  ## compares real paths rather than spellings.
  let target = normalizeTaskRoot(path)
  if target.len == 0: return false
  for root in roots:
    if target == root or target.startsWith(root & "/"): return true

proc resolveTaskPolicy*(profile: JsonNode, requested: JsonNode,
                        workspace: string): tuple[policy: JsonNode,
                                                  refusal: PolicyRefusal] =
  ## The effective policy of one unattended task: the intersection of the
  ## operator's profile with the requesting human's grant. Every refusal is
  ## explicit and names what was asked versus what was allowed — a task never
  ## starts with less authority than the human approved and believes it has
  ## more.
  if requested == nil or requested.kind != JObject:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "an unattended task needs a `task` grant object"))
  if profile == nil:
    return (newJNull(), refusePolicy("task-policy-denied",
      "the worker has no task profile for this request; unattended authority" &
      " is off unless the operator configures it"))
  let problem = taskProfileProblem(profile)
  if problem.len > 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "the worker's task profile is invalid: " & problem))
  if not profile{"unattended"}.getBool(false):
    return (newJNull(), refusePolicy("task-policy-denied",
      "the worker's profile does not permit unattended execution"))
  let allowed = profileToolList(profile)
  # --- tools: the request must be a subset of the operator's ceiling ---------
  var wanted: seq[string] = @[]
  for item in requested{"tools"}.listOf:
    let name = item.getStr("").strip()
    if name.len > 0 and name notin wanted: wanted.add(name)
  wanted.sort()
  if wanted.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "an unattended task needs an explicit tool list"))
  for tool in wanted:
    if isControlPlane(tool):
      return (newJNull(), refusePolicy("task-policy-denied",
        "tool '" & tool & "' is control-plane machinery and is never granted" &
        " to a task: single-hop delegation, no indirect authority"))
    if tool notin allowed:
      return (newJNull(), refusePolicy("task-policy-widened",
        "tool '" & tool & "' is not permitted by the worker's profile" &
        " (allowed: " & allowed.join(", ") & ")"))
  # --- roots: the workspace must be inside an approved root -----------------
  let roots = profileRoots(profile)
  if roots.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "the worker's task profile lists no writable roots"))
  if workspace.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "an unattended task needs an explicit workspace"))
  if not rootAllowed(roots, workspace):
    return (newJNull(), refusePolicy("task-policy-refused-root",
      "workspace " & workspace & " is outside the worker's approved task" &
      " roots (" & roots.join(", ") & ")"))
  # --- budgets: caller values only narrow the profile's ceiling -------------
  var budget = newJObject()
  for key in ["maxRounds", "maxCalls", "maxTokens"]:
    let ceil = profile{key}.getInt(0)
    let asked = requested{key}.getInt(0)
    if ceil <= 0:
      # A profile that names no ceiling cannot authorize a budget: an unbounded
      # unattended task is exactly what this seam exists to prevent.
      return (newJNull(), refusePolicy("task-policy-invalid",
        "the worker's task profile sets no " & key & " ceiling"))
    if asked <= 0:
      return (newJNull(), refusePolicy("task-policy-invalid",
        "an unattended task must state " & key))
    if asked > ceil:
      return (newJNull(), refusePolicy("task-policy-widened",
        key & " " & $asked & " exceeds the worker ceiling of " & $ceil))
    budget[key] = %asked
  # --- the honest confinement statement ------------------------------------
  # Shell is broad machine access. This slice does not confine it, and saying
  # otherwise (a workspace label, a tool allowlist, an "effect" flag) would be
  # a lie a human could rely on. The policy carries the truth into the
  # admission receipt and the requester's notice.
  let confinement = profile{"confinement"}.getStr("unconfined")
  result.policy = %*{
    "version": taskPolicyVersion,
    "profile": profile{"name"}.getStr(""),
    "unattended": true,
    "tools": %wanted,
    "roots": %roots,
    "workspace": normalizeTaskRoot(workspace),
    "budget": budget,
    "confinement": confinement,
    "confined": confinement == "sandbox",
    "controlPlaneDenied": true}
  if confinement == "sandbox":
    # No sandbox enforcement is wired into task execution in this slice.
    # Claiming it from a profile field alone is the failure mode the plan names
    # ("do not call an approved unconfined builder, MCP server or native guest
    # sandboxed"), so a profile cannot assert it yet.
    return (newJNull(), refusePolicy("task-policy-unsupported",
      "confinement 'sandbox' is not enforced for delegated tasks in this" &
      " harness version; configure the profile as unconfined to proceed" &
      " honestly, or wait for a sandboxed task slice"))

proc resolveDelegationPolicy*(settings: JsonNode, requested: JsonNode,
                              workspace: string): tuple[policy: JsonNode,
                                                        refusal: PolicyRefusal] =
  ## The effective policy of one TRUSTED-WORKER delegation
  ## (docs/FLEET-SIMPLIFICATION.md): the worker's single operator setting is
  ## the ceiling, and the caller only narrows it. Same validation, same
  ## control-plane denial and same confinement honesty as a task profile —
  ## what changes is that tools and budgets are OPTIONAL (absent = the
  ## worker's own ceiling, then the runner's normal turn default), because
  ## this is delegation to a trusted machine, not a per-task permission
  ## negotiation.
  ##
  ## Refusals stay explicit: no setting, or a setting that does not permit
  ## unattended work, refuses rather than starting a turn that waits forever
  ## for an approval nobody will give.
  if requested == nil or requested.kind != JObject:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "goal delegation needs a `task` request object"))
  if settings == nil:
    return (newJNull(), refusePolicy("task-policy-denied",
      "this worker does not accept unattended delegation; its operator must" &
      " enable it (store kind " & delegationSettingsKind & ", id " &
      delegationSettingsId & ")"))
  let problem = taskProfileProblem(settings)
  if problem.len > 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "the worker's delegation setting is invalid: " & problem))
  if not settings{"unattended"}.getBool(false):
    return (newJNull(), refusePolicy("task-policy-denied",
      "the worker's delegation setting does not permit unattended execution"))
  let allowed = profileToolList(settings)
  # --- tools: requested names must be permitted; absent = the ceiling ------
  var wanted: seq[string] = @[]
  for item in requested{"tools"}.listOf:
    let name = item.getStr("").strip()
    if name.len > 0 and name notin wanted: wanted.add(name)
  if wanted.len == 0: wanted = allowed
  wanted.sort()
  if wanted.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "the worker's delegation setting lists no tools"))
  for tool in wanted:
    if isControlPlane(tool):
      return (newJNull(), refusePolicy("task-policy-denied",
        "tool '" & tool & "' is control-plane machinery and is never granted" &
        " to a delegated task: single-hop delegation, no indirect authority"))
    if tool notin allowed:
      return (newJNull(), refusePolicy("task-policy-widened",
        "tool '" & tool & "' is not permitted by the worker's delegation" &
        " setting (allowed: " & allowed.join(", ") & ")"))
  # --- workspace: must be inside an approved root --------------------------
  let roots = profileRoots(settings)
  if roots.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "the worker's delegation setting lists no writable roots"))
  if workspace.len == 0:
    return (newJNull(), refusePolicy("task-policy-invalid",
      "a delegated task needs an explicit workspace"))
  if not rootAllowed(roots, workspace):
    return (newJNull(), refusePolicy("task-policy-refused-root",
      "workspace " & workspace & " is outside the worker's approved roots (" &
      roots.join(", ") & ")"))
  # --- budgets: optional; a caller value only narrows the ceiling ----------
  var budget = newJObject()
  for key in ["maxRounds", "maxCalls", "maxTokens"]:
    let ceil = settings{key}.getInt(0)
    let asked = requested{key}.getInt(0)
    if asked <= 0:
      # Absent means "the worker's normal default": its own ceiling when one is
      # configured, else the runner's ordinary turn default (0 = none).
      budget[key] = %ceil
    elif ceil > 0 and asked > ceil:
      return (newJNull(), refusePolicy("task-policy-widened",
        key & " " & $asked & " exceeds the worker ceiling of " & $ceil))
    else:
      budget[key] = %asked
  let confinement = settings{"confinement"}.getStr("unconfined")
  if confinement == "sandbox":
    # Same honesty rule as a profile: nothing in this slice sandboxes delegated
    # work, so the setting cannot assert it.
    return (newJNull(), refusePolicy("task-policy-unsupported",
      "confinement 'sandbox' is not enforced for delegated tasks in this" &
      " harness version; configure the setting as unconfined to proceed honestly"))
  result.policy = %*{
    "version": taskPolicyVersion,
    "profile": delegationProfileName,
    "unattended": true,
    "tools": %wanted,
    "roots": %roots,
    "workspace": normalizeTaskRoot(workspace),
    "budget": budget,
    "confinement": confinement,
    "confined": false,
    "controlPlaneDenied": true}

proc taskToolSchemaProblem*(tool: string, schema: JsonNode): string =
  ## Shared admission check; the worker must not trust the requester's audit.
  ## Unknown plugin names still cannot opt into orchestration or runner access.
  if isControlPlane(tool): return "control-plane callable: " & tool
  if not schema.isObj: return "tool unavailable or missing schema: " & tool
  let contract = schema{"x-harness"}
  if not contract.isObj: return "tool declares no x-harness contract: " & tool
  for flag in ["hidden", "runner", "sessionContext", "noSpawn"]:
    let value = contract{flag}
    if value != nil:
      if value.kind != JBool or value.getBool(false):
        return "task tool is orchestrator or runner machinery: " & tool & " (" & flag & ")"
  ""

proc grantDigest*(grant: JsonNode): string =
  ## Identity of the authority a requester asks a worker to enforce: profile,
  ## tool set and budgets, in canonical form. The requester records it in its
  ## job BEFORE dispatch and the worker recomputes it from what actually
  ## arrived, so a grant mutated between approval and execution is refused
  ## (`task-policy-grant-mismatch`) instead of silently running under other
  ## authority.
  ##
  ## Workspace is deliberately excluded: the two peers name the same directory
  ## through different filesystems, so their canonical spellings legitimately
  ## differ, and `roots` already refuses a workspace outside the operator's
  ## approved set. This digest binds the authority dimensions that must be
  ## byte-identical across the wire.
  if not grant.isObj: return ""
  var tools: seq[string] = @[]
  for item in grant{"tools"}.listOf:
    let name = item.getStr("").strip()
    if name.len > 0 and name notin tools: tools.add(name)
  tools.sort()
  var body = newJObject()
  body["profile"] = %grant{"profile"}.getStr("").strip()
  body["tools"] = %tools
  for key in ["maxRounds", "maxCalls", "maxTokens"]:
    body[key] = %grant{key}.getInt(0)
  var st = initSha_256()
  st.update(canonicalJson(body))
  "sha256:" & $st.digest()

proc policyAllowsTool*(policy: JsonNode, tool: string): bool =
  ## The task-scoped auto-approval test the gate consults. Only the tools the
  ## effective policy granted, and never control-plane machinery (already
  ## excluded at resolution; re-checked because policy documents travel).
  if policy == nil or policy.kind != JObject: return false
  if not policy{"unattended"}.getBool(false): return false
  if isControlPlane(tool): return false
  for item in policy{"tools"}.listOf:
    if item.getStr("") == tool: return true
  false

proc publicPolicy*(policy: JsonNode): JsonNode =
  ## The effective policy as a requester/UI sees it: no operator-private note.
  if policy == nil: return newJNull()
  result = policy.copy()
  if result.hasKey("note"): result.delete("note")
  result["digest"] = %policyDigest(policy)
