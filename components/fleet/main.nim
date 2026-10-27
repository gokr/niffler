## Opt-in Fleet provisioning, using the ordinary harness approval gate.
import std/[json, os, strutils, times]
import niffler/sdk
import provision
import registry
import delegation
import niffler/taskpolicy

if paramCount() == 2 and paramStr(1) == "--fleet-worker":
  workerMain()
  quit(0)

let comp = newComponent("fleet", "0.1.0")
proc schema(properties: JsonNode, required: seq[string], description: string): JsonNode =
  %*{"type": "object", "properties": properties, "required": required,
    "additionalProperties": false, "description": description}
proc handler(name: string): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    var logs: seq[string]
    let transport = connectedRunner(c)
    let runner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
      result = transport(argv, input, timeoutMs)
      logs.add(result.logPath)
    try:
      result = if name == "install": install(runner, args)
        elif name == "update": update(runner, args)
        else: action(runner, name, args{"profile"}.getStr())
      # Install/update already verified the live identity before returning.
      # Record the verified receipt in the registry (best effort: the local
      # file just written stays authoritative for this operation, and a store
      # outage must not turn a successful remote install into a failure).
      if name in ["install", "update"] and result{"receipt"} != nil:
        try:
          discard saveInstance(c, result["receipt"], name)
        except CatchableError as e:
          stderr.writeLine("fleet: registry write failed (" & name & "): " & e.msg)
      result["privateLogs"] = %logs
    except CatchableError as e:
      return errResult(e.msg, "fleet-refused")
let profile = %*{"type": "string", "description": "Local private version-1 receipt path; mutations require human approval."}
let installProps = %*{
  "service": {"type": "string", "enum": ["systemd", "process"], "description": "Default systemd. Explicit process mode for SSH Linux hosts without systemd: requires prepared build dependencies plus flock, setsid and a util-linux setpriv with --pdeathsig (BusyBox setpriv is refused; Alpine: apk add setpriv); survives logout but NOT host reboot; updates require operator maintenance."},
  "profile": profile, "transport": {"type": "string", "enum": ["ssh", "lima", "incus"]},
  "target": {"type": "string", "description": "SSH alias/user@host, Lima VM name or Incus container name"},
  "host": {"type": "string", "description": "Optional SSH management host alias/user@host for Incus or Lima only; omit for local. Bound in private receipt; no passwords or agent forwarding."},
  "root": {"type": "string", "description": "Dedicated canonical absolute installation root; Lima/Incus require /home/ubuntu/niffler"},
  "revision": {"type": "string", "description": "Full lowercase 40-character SHA, or a ref (main, v0.4.0) resolved to one before any remote write and recorded as the receipt's pinned revision; existing installs never update"},
  "cpus": {"type": "integer", "minimum": 1, "maximum": 64},
  "memory": {"type": "string", "description": "VM memory, default 4G"},
  "disk": {"type": "string", "description": "VM disk, default 20G"}}
discard comp.tool("fleet_install", schema(installProps,
  @["profile", "transport", "target", "root", "revision"],
  "Install a pinned new Niffler server or adopt an existing installation without updating it; optionally create Ubuntu 24.04 in Lima or an unprivileged Incus system container. Lima and Incus run as ubuntu at /home/ubuntu/niffler, explicitly enables guest linger, and removes its temporary installer sudo rule on normal success/failure; forced interruption may require manual cleanup. No host sudo, agent forwarding, credential copying, host mounts, privileged/nesting configuration or guest deletion. Save a verified private receipt; provider setup remains explicit."),
  handler("install"), %*{"onDemand": true, "approval": "always", "effect": "write",
    "timeoutMs": 4400000, "writes": {"paths": ["profile"]}, "workspace": {"pathFields": ["profile"]}})
for name in ["probe", "status", "logs", "start", "stop", "vm_stop", "vm_start"]:
  let readOnly = name in ["probe", "status", "logs"]
  let description = case name
    of "probe": "Read and verify the live remote catalog against its receipt identity and root."
    of "status": "Read identity-guarded remote Niffler user-service status."
    of "logs": "Read the last 100 remote service journal lines. Application logs can contain sensitive output; do not share publicly."
    of "start": "Start the pinned service, checking durable identity before writes even when the bus is down."
    of "stop": "Stop the pinned Niffler service only, leaving the host and VM running."
    of "vm_stop": "Stop a verified Lima VM or Incus container separately from Niffler service stop. Requires reachable identity; never deletes VMs."
    else: "Start a verified Lima VM or Incus container and wait until its Niffler service verifies. Requires the same identity guard as stopping; never creates or adopts a guest."
  var extensions = %*{"onDemand": true, "effect": (if readOnly: "read" else: "write"),
    "timeoutMs": 250000, "workspace": {"pathFields": ["profile"]}}
  if not readOnly:
    extensions["approval"] = %"always"
    extensions["writes"] = %*{"none": true}
  discard comp.tool("fleet_" & name, schema(%*{"profile": profile}, @["profile"], description), handler(name), extensions)
# A new capability, not a new approval surface: like every other mutating
# fleet tool this carries approval: "always", and the runner-side resolution
# happens only after the receipt proven to belong to this exact instance has
# been verified over the live catalog, with the durable guard on the host.
discard comp.tool("fleet_update", schema(%*{
  "profile": profile,
  "revision": {"type": "string", "description": "Full lowercase 40-character SHA, or a ref (main, latest, v0.4.0) resolved to one before any remote write and recorded as the new pinned revision"}},
  @["profile", "revision"],
  "Update one verified pinned installation to a new revision in the background-safe order: verify instance identity over the live catalog, refuse if the checkout has local changes, fetch and check out the resolved revision, rebuild in place, reinstall and restart the user service, then refresh the receipt's pinned revision only after the updated instance verifies. Never clones, never adopts an unrelated root, never touches provider credentials."),
  handler("update"), %*{"onDemand": true, "approval": "always",
    "effect": "write", "timeoutMs": 4400000,
    "writes": {"paths": ["profile"]}, "workspace": {"pathFields": ["profile"]}})
let taskProps = %*{
  "profile": profile, "instance": {"type": "string", "description": "Registered worker name or identity; use instead of profile"},
  "requestId": {"type": "string"},
  "mode": {"type": "string", "enum": ["ask", "unattended", "delegate"],
           "description": "ask (default): the original read-only slice, where the worker stops for human approvals. unattended: run coding tools under a NAMED worker task profile (taskProfile). delegate: send a goal to a trusted worker whose operator enabled delegation once (fleet_delegation_set on that machine) — no profile name, tools and budgets optional. Omit for read-only work."},
  "taskProfile": {"type": "string",
                  "description": "Unattended mode only: name of the WORKER operator's task profile. Its ceilings (tools, roots, budgets) bound this grant; the intersection is the effective policy and the worker refuses anything wider."},
  "content": {"type": "string"}, "cwd": {"type": "string"},
  "tools": {"type": "array", "items": {"type": "string"},
            "description": "Optional in mode 'delegate' (omitted = the worker's configured ceiling); required in ask/unattended. Naming fewer tools only narrows authority."},
  "maxRounds": {"type": "integer", "minimum": 1, "maximum": 32},
  "maxCalls": {"type": "integer", "minimum": 1, "maximum": 500},
  "maxTokens": {"type": "integer", "minimum": 1, "maximum": 2000000}}
discard comp.tool("fleet_task_submit", schema(taskProps,
  @["requestId", "content", "cwd"],
  "Delegate a goal to another machine: a registered instance (name or identity) or a private verified profile receipt, exactly one. mode 'delegate' sends a goal to a trusted worker (no taskProfile; tools and budgets optional, omitted ones take the worker's configured ceiling, and any value you name can only narrow it) — use it when you want the worker to decide its steps and report back. mode 'ask' is the bounded read-only slice (worker stops for human approvals); mode 'unattended' requires a named taskProfile and explicit tools/budgets. Same requestId is idempotent; unknown outcomes are never replayed. Completion automatically notifies this conversation; do not poll to wait. Control-plane and indirect-delegation tools are never granted, and results are the worker's claims, not independently verified facts."),
  proc(c: Component, args: JsonNode): JsonNode = createJob(c, args),
  %*{"onDemand": true, "approval": "always", "sessionContext": true, "noSpawn": true,
    "workspace": {"pathFields": ["profile"]}})
# --- trusted delegation setting (the simplification) -----------------------
# ONE operator decision, instead of a profile per assignment
# (docs/FLEET-SIMPLIFICATION.md). Same document shape as a task profile, so the
# same validation, control-plane denial and confinement honesty apply; what
# changes is that a requester needs no profile name and may omit tools/budgets.
# Off unless stored. Human-gated: enabling unattended authority is never a model
# decision, and it is never reachable from a task (controlPlaneTools).
discard comp.tool("fleet_delegation_set", schema(%*{
  "enabled": {"type": "boolean",
              "description": "true accepts unattended goal delegation from trusted requesters on this machine; false revokes it for FUTURE delegations (a running task keeps the policy it was admitted under)"},
  "tools": {"type": "array", "items": {"type": "string"},
            "description": "The ceiling: every tool a delegated goal may ever run here. Omit to keep the current list; control-plane machinery is refused."},
  "roots": {"type": "array", "items": {"type": "string"},
            "description": "Workspace roots a delegated goal may run in. Omit to keep the current list; the filesystem root is refused."},
  "maxRounds": {"type": "integer", "minimum": 0, "maximum": 32,
               "description": "Optional ceiling; 0/omitted means the runner's normal turn default rather than a new mandatory cap"},
  "maxCalls": {"type": "integer", "minimum": 0, "maximum": 500},
  "maxTokens": {"type": "integer", "minimum": 0, "maximum": 2000000},
  "note": {"type": "string", "description": "Operator note (never sent to a requester)"}},
  @["enabled"],
  "Configure this machine's ONE trusted-delegation decision: whether a verified remote Niffler may send a goal here that runs ordinary tools without per-task approval prompts. Enabling is a human decision (approval-gated) and is off by default; a requester can only narrow what is configured here, never widen it, and quoting this setting by name grants nothing. Note the honest limit: the bus caller identity is self-declared, so this trusts bus/SSH access to the machine, not a per-requester credential."),
  proc(c: Component, args: JsonNode): JsonNode =
    var doc = newJObject()
    # Merge: omitted keys keep their current value, so an operator can revoke
    # without restating (or accidentally narrowing) the tool/root lists.
    var current: JsonNode = nil
    try: current = c.storeGet(delegationSettingsKind, delegationSettingsId).value
    except CatchableError: discard
    if current != nil and current.kind == JObject:
      for key, value in current: doc[key] = value.copy()
    doc["name"] = %delegationProfileName
    doc["unattended"] = %args{"enabled"}.getBool(false)
    if args{"confinement"} != nil: doc["confinement"] = args["confinement"]
    elif doc{"confinement"} == nil: doc["confinement"] = %"unconfined"
    for key in ["tools", "roots", "maxRounds", "maxCalls", "maxTokens", "note"]:
      if args{key} != nil: doc[key] = args[key].copy()
    let problem = taskProfileProblem(doc)
    if problem.len > 0:
      return errResult(problem, "task-policy-invalid")
    for t in profileToolList(doc):
      if isControlPlane(t):
        return errResult("tool '" & t & "' is control-plane machinery and cannot" &
                         " be granted to delegated goals", "task-policy-denied")
    discard c.storePut(delegationSettingsKind, delegationSettingsId, doc)
    %*{"ok": true, "settings": publicPolicy(doc),
      "text": (if doc{"unattended"}.getBool(false):
                 "this machine accepts unattended goal delegation within these limits"
               else:
                 "unattended goal delegation is disabled; future requests refuse")},
  %*{"onDemand": true, "approval": "always", "effect": "write",
    "writes": {"none": true}})
discard comp.tool("fleet_delegation_get", schema(newJObject(), @[],
  "Read this machine's trusted-delegation setting (docs/FLEET-SIMPLIFICATION.md): whether unattended goal delegation is enabled, the tool/root/budget ceiling, and the honest note that bus caller identity is self-declared. Read-only."),
  proc(c: Component, args: JsonNode): JsonNode =
    var doc: JsonNode = nil
    try: doc = c.storeGet(delegationSettingsKind, delegationSettingsId).value
    except CatchableError: discard
    if doc == nil:
      return %*{"ok": true, "configured": false, "enabled": false,
        "text": "no trusted-delegation setting: unattended goal delegation is off"}
    %*{"ok": true, "configured": true,
      "enabled": doc{"unattended"}.getBool(false),
      "settings": publicPolicy(doc)},
  %*{"onDemand": true, "effect": "read"})
# --- operator-side task profiles (F2) -------------------------------------
# The worker operator writes a `taskprofile` document; a requester may only
# name it. Set/remove are separate so a profile can be inspected and revoked
# without editing a store document by hand. Neither is reachable from a task
# (taskpolicy.controlPlaneTools), and both are approval-gated.
let profileProps = %*{
  "name": {"type": "string", "description": "Profile name a requester will name in fleet_task_submit {taskProfile}. Letters, digits, '-' and '_', up to 64 bytes."},
  "tools": {"type": "array", "items": {"type": "string"},
            "description": "The tools an unattended task may ever run here. Must list at least one; control-plane and indirect-delegation tools are refused. Anything a requester asks for outside this list is refused, not clamped."},
  "roots": {"type": "array", "items": {"type": "string"},
            "description": "Absolute workspace roots a task may run in. A task's workspace must be one of these or live under one; the filesystem root is refused."},
  "maxRounds": {"type": "integer", "minimum": 1, "maximum": 32},
  "maxCalls": {"type": "integer", "minimum": 1, "maximum": 100},
  "maxTokens": {"type": "integer", "minimum": 1, "maximum": 100000},
  "note": {"type": "string", "description": "Operator note (never sent to a requester)."}}
discard comp.tool("task_profile_set", schema(profileProps,
  @["name", "tools", "roots", "maxRounds", "maxCalls", "maxTokens"],
  "Define or replace the worker operator's unattended task profile: the ceiling for tools, workspace roots and budgets that a delegated coding task may use on THIS machine without approval prompts. This profile is one half of the decision; the requesting human's grant is the other, and the effective policy is the intersection. Unattended authority is off by default: no profile, or a profile whose tools/roots/budgets do not cover the request, means the task is refused explicitly. Written to this harness's store; an already-running task keeps the policy it was admitted under."),
  proc(c: Component, args: JsonNode): JsonNode =
    let name = args{"name"}.getStr("").strip()
    if not validProfileName(name):
      return errResult("profile name must be 1..64 of [A-Za-z0-9_-]", "task-policy-invalid")
    var doc = newJObject()
    doc["name"] = %name
    doc["unattended"] = %true
    doc["confinement"] = %args{"confinement"}.getStr("unconfined")
    for key in ["tools", "roots", "maxRounds", "maxCalls", "maxTokens", "note"]:
      if args{key} != nil: doc[key] = args[key]
    let problem = taskProfileProblem(doc)
    if problem.len > 0:
      return errResult(problem, "task-policy-invalid")
    # A profile naming control-plane machinery would be a standing grant of
    # indirect authority; refuse it here as well as at resolution time.
    for t in profileToolList(doc):
      if isControlPlane(t):
        return errResult("tool '" & t & "' is control-plane machinery and cannot" &
                         " be granted to tasks", "task-policy-denied")
    discard c.storePut("taskprofile", name, doc)
    %*{"ok": true, "profile": name, "stored": doc},
  %*{"onDemand": true, "approval": "always", "effect": "write", "writes": {"none": true}})
discard comp.tool("task_profile_list", schema(newJObject(), @[],
  "List this worker's unattended task profiles and the effective ceiling each one sets. Read-only: shows what a requester could ask for here, never any other machine's policy."),
  proc(c: Component, args: JsonNode): JsonNode =
    var items = newJArray()
    for entry in c.storeListAll("taskprofile"):
      items.add(%*{"name": entry.id, "profile": entry.value})
    %*{"ok": true, "profiles": items},
  %*{"onDemand": true, "effect": "read"})
discard comp.tool("task_profile_remove", schema(%*{
  "name": {"type": "string"}}, @["name"],
  "Remove one unattended task profile: no further task may be admitted under it. Tasks already running keep the policy they were admitted under, and their receipts still name it."),
  proc(c: Component, args: JsonNode): JsonNode =
    let name = args{"name"}.getStr("").strip()
    if not validProfileName(name):
      return errResult("invalid profile name", "task-policy-invalid")
    c.storeDel("taskprofile", name)
    %*{"ok": true, "removed": name},
  %*{"onDemand": true, "approval": "always", "effect": "write", "writes": {"none": true}})
proc taskReader(verb: string): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    let j = authorized(c, args).value
    if verb == "result":
      reportPage(j, args)
    else: publicJob(j)
for name in ["status", "result"]:
  # `human` is the one way to read a job without a conversation: the owner
  # check keeps CONVERSATIONS apart, and a person at a keyboard is not one. The
  # same argument gates fleet_task_inbox's sibling reads; without it a client
  # could list every job and then be unable to open any of them.
  discard comp.tool("fleet_task_" & name, schema(%*{
    "jobId": {"type": "string"},
    "offset": {"type": "integer", "minimum": 0, "description": "Report cursor from nextOffset; result only"},
    "limit": {"type": "integer", "minimum": 4, "maximum": 32768, "description": "Report page bytes (default 8192); result only"},
    "human": {"type": "boolean", "description": "Human-scope read: a person may read any job this harness submitted, without session context (the inbox needs this to open what it lists)"}}, @["jobId"],
    "Read an owned task's status or locally cached final prose report. Use nextOffset as offset while hasMore. Legacy reports explicitly mark summary-only data incomplete. No peer contacted or submission replay."),
    taskReader(name),
    %*{"onDemand": true, "effect": "read", "sessionContext": true})
discard comp.tool("fleet_task_receipt", schema(%*{
  "jobId": {"type": "string"}}, @["jobId"],
  "Read the worker's own durable admission receipt for an owned task: the activation it admitted, the birth-policy digest, the lifecycle state (accepted = provably not started, running = a turn may have started, settled = that activation's terminal turnId/outcome/usage) and whether its transcript was durably committed. A read only — it never starts, resumes or replays a turn. Unknown, unreachable and receipt-less are not interruption or success."),
  proc(c: Component, args: JsonNode): JsonNode =
    let j = authorized(c, args).value
    %*{"jobId": j["id"], "state": j{"state"}.getStr("unknown"),
      "remoteSession": j["sessionId"],
      "admission": (if j{"admissionReceipt"} == nil: newJNull() else: j["admissionReceipt"]),
      "completion": (if j{"completion"} == nil: newJNull() else: j["completion"]),
      "checkedAt": j{"checkedAt"}.getFloat(0)},
  %*{"onDemand": true, "effect": "read", "sessionContext": true})
discard comp.tool("fleet_task_cancel", schema(%*{"jobId": {"type": "string"},
  "human": {"type": "boolean", "description": "Human-scope: cancel any job this harness submitted, without session context"}}, @["jobId"],
  "Cancel a fleet task. A QUEUED task is cancelled locally and never dispatched. A task already carrying a remote session is stopped ON THE PEER, and the reply reports what the peer said — never a bare 'cancelled', because a local claim about remote work may be wrong. Cancellation is cooperative: an in-flight tool runs to completion, the turn ends after it. Re-calling is harmless."),
  proc(c: Component, args: JsonNode): JsonNode =
    var item = authorized(c, args)
    let state = item.value["state"].getStr("")
    if state == "settled" or state == "failed":
      return errResult("task already finished (" & state & ")", "not-active")
    if state == "queued":
      item.value["state"] = %"settled"
      item.value["notice"] = %*{"kind": "fleet-settled", "jobId": item.id,
        "status": "cancelled-before-dispatch", "summary": "No remote turn was submitted."}
      item.value["delivered"] = %false
      discard c.storePut("fleetjob", item.id, item.value, item.rev)
      return publicJob(item.value)
    # Already dispatched: ask the PEER. The reply is its own account of what
    # happened, and the local record only follows it — never the reverse.
    # The remote session id is the job's admission key, not something the
    # settle notice stores: one job is one activation, so the job id IS the
    # worker-side identity (delegation.nim:admissionKey). Reading the notice
    # here was wrong — it exists only AFTER settling, and a running job has
    # none, so a cancel of active work could never have found its target.
    let remoteSession = admissionKey(item.id)
    let transport = connectedRunner(c)
    let run: CommandRunner = proc(argv: seq[string], input: string,
                                  timeoutMs: int): CommandResult =
      transport(argv, input, timeoutMs)
    discard probe(run, item.value{"receipt"})
    let reply = remoteCancel(run, item.value{"receipt"}, remoteSession)
    let peerStatus = reply{"status"}.getStr("")
    let now = epochTime()
    item.value["checkedAt"] = %now
    item.value["cancel"] = %*{"requestedAt": now, "remoteSession": remoteSession,
                              "peerStatus": peerStatus}
    if peerStatus in ["stopped", "done", "failed"]:
      # The peer confirms it is terminal. Record that, and let the depression
      # of the job follow its own settle path rather than assuming it here.
      item.value["notice"]["status"] = %"cancelled-on-peer"
      item.value["notice"]["summary"] = %("Peer reports the session as " & peerStatus & ".")
    discard c.storePut("fleetjob", item.id, item.value, item.rev)
    # Merge the cancel report into the public job rather than crossing a
    # JObject with `&` (which json.nim does not do for objects).
    var report = publicJob(item.value)
    report["cancelRequested"] = %true
    report["peerStatus"] = %peerStatus
    report,
  %*{"onDemand": true, "sessionContext": true, "approval": "always"})
discard comp.tool("fleet_notices", schema(%*{
  "session": {"type": "string"}, "peek": {"type": "boolean"},
  "ack": {"type": "string"}}, @["session"],
  "Runner Fleet completion inbox. Read is non-consuming; acknowledge only after durable transcript append."),
  proc(c: Component, args: JsonNode): JsonNode = taskNotices(c, args),
  %*{"hidden": true, "runner": true, "effect": "read"})
# Registry surface. These describe routes; they never grant authority — every
# action above still proves the live identity before it writes. Import is the
# explicit one-time migration from the receipt-file era, and list is what a
# client reads instead of a local instances.json.
discard comp.tool("fleet_instances", schema(%*{}, @[],
  "List registered fleet instances (stable identity, name, root, transport and pinned revision). Read-only: entries are routes for selection, never proof that the peer is reachable or authorized now."),
  proc(c: Component, args: JsonNode): JsonNode = listInstances(c),
  %*{"onDemand": true, "effect": "read"})
discard comp.tool("fleet_task_inbox", schema(%*{
  "peer": {"type": "string", "description": "Only jobs submitted to this instance (registry name or 32-hex identity); omitted = all peers"},
  "state": {"type": "string", "enum": ["queued", "submitting", "running", "settled", "failed", "uncertain"],
            "description": "Only jobs in this lifecycle state"},
  "after": {"type": "string", "description": "Stable job-id cursor from a previous page's nextAfter (not a timestamp: reconnect must walk the whole kind)"},
  "limit": {"type": "integer", "description": "Max rows per page (default 20, cap 100)"}},
  @[],
  "List the human inbox: every task this harness submitted to a remote Niffler, with its lifecycle state and — once settled — a self-contained verdict (status + bounded summary + artifact descriptor). Local read: no peer is contacted, so a job whose instance is down or gone still shows what it reported. Detail is a separate on-demand pull (fleet_task_result), which needs the peer to answer. Reading this list acknowledges nothing: seen/unread state is client-local by design (docs/FLEET-INBOX.md)."),
  proc(c: Component, args: JsonNode): JsonNode = taskInbox(c, args),
  %*{"onDemand": true, "effect": "read", "timeoutMs": 30000})
discard comp.tool("fleet_remove", schema(%*{
  "instanceId": {"type": "string", "description": "32-hex instance identity (preferred)"},
  "name": {"type": "string", "description": "Registered instance name; refused if ambiguous"},
  "expectRevision": {"type": "string", "description": "Optional guard: only remove when the entry is pinned to this revision"}},
  @[],
  "Forget a registered fleet instance. Deletes the REGISTRY ENTRY ONLY: the peer keeps running, keeps its receipt file and is never contacted. Use fleet_vm_stop to stop a guest; nothing in this harness deletes a guest."),
  proc(c: Component, args: JsonNode): JsonNode = removeInstance(c, args),
  %*{"onDemand": true, "approval": "always", "effect": "write",
    "writes": {"none": true}})
discard comp.tool("fleet_instance_import", schema(
  %*{"profile": profile}, @["profile"],
  "Import one existing private version-1 receipt file into the fleet registry (explicit migration; the file is left untouched and remains valid as an export). Validates the receipt and requires approval."),
  proc(c: Component, args: JsonNode): JsonNode = importReceipt(c, args{"profile"}.getStr()),
  %*{"onDemand": true, "approval": "always", "effect": "write",
    "writes": {"none": true}, "workspace": {"pathFields": ["profile"]}})

discard comp.onIdle(500) do (c: Component):
  try: idleJobs(c)
  except CatchableError as e: stderr.writeLine("fleet idle: " & e.msg)
discard comp.onDrain do (c: Component): stopWorker()
comp.run()
