## Opt-in Fleet provisioning, using the ordinary harness approval gate.
import std/[json, os]
import niffler/sdk
import provision
import delegation

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
      result["privateLogs"] = %logs
    except CatchableError as e:
      return errResult(e.msg, "fleet-refused")
let profile = %*{"type": "string", "description": "Local private version-1 receipt path; mutations require human approval."}
let installProps = %*{
  "service": {"type": "string", "enum": ["systemd", "process"], "description": "Default systemd. Explicit process mode for SSH Linux hosts without systemd: requires prepared build dependencies, survives logout but NOT host reboot; updates require operator maintenance."},
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
for name in ["probe", "status", "logs", "start", "stop", "vm_stop"]:
  let readOnly = name in ["probe", "status", "logs"]
  let description = case name
    of "probe": "Read and verify the live remote catalog against its receipt identity and root."
    of "status": "Read identity-guarded remote Niffler user-service status."
    of "logs": "Read the last 100 remote service journal lines. Application logs can contain sensitive output; do not share publicly."
    of "start": "Start the pinned service, checking durable identity before writes even when the bus is down."
    of "stop": "Stop the pinned Niffler service only, leaving the host and VM running."
    else: "Stop a verified Lima VM or Incus container separately from Niffler service stop. Requires reachable identity; never deletes VMs."
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
  "profile": profile, "requestId": {"type": "string"},
  "content": {"type": "string"}, "cwd": {"type": "string"},
  "tools": {"type": "array", "items": {"type": "string"}},
  "maxRounds": {"type": "integer", "minimum": 1, "maximum": 32},
  "maxCalls": {"type": "integer", "minimum": 1, "maximum": 100},
  "maxTokens": {"type": "integer", "minimum": 1, "maximum": 100000}}
discard comp.tool("fleet_task_submit", schema(taskProps,
  @["profile", "requestId", "content", "cwd", "tools", "maxRounds", "maxCalls", "maxTokens"],
  "Delegate a bounded read-only task to another machine using a private verified receipt. Explicit tools and round/call/token budgets required. Same requestId is idempotent; unknown outcomes are never replayed. Completion automatically notifies this conversation; do not poll to wait. No shell, orchestration, store tools or auto approvals. Results are claims by the worker, not proof of factual success."),
  proc(c: Component, args: JsonNode): JsonNode = createJob(c, args),
  %*{"onDemand": true, "approval": "always", "sessionContext": true, "noSpawn": true,
    "workspace": {"pathFields": ["profile"]}})
proc taskReader(verb: string): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    let j = authorized(c, args).value
    if verb == "result":
      %*{"jobId": j["id"], "state": j["state"], "completion": (if j{"completion"} == nil: newJNull() else: j["completion"]),
        "summary": j{"notice", "summary"}.getStr(""), "bounded": true,
        "remoteSession": j["sessionId"], "detail": "Full transcript remains on the pinned peer; open this remoteSession there."}
    else: publicJob(j)
for name in ["status", "result"]:
  discard comp.tool("fleet_task_" & name, schema(%*{
    "jobId": {"type": "string"}}, @["jobId"],
    "Read an owned remote task's durable status or cached bounded report. Unreachable and unknown do not mean failed or successful; no submission replay. Completion is pushed automatically."),
    taskReader(name),
    %*{"onDemand": true, "effect": "read", "sessionContext": true})
discard comp.tool("fleet_task_cancel", schema(%*{"jobId": {"type": "string"}}, @["jobId"],
  "Cancel a queued task before dispatch. An already attempted or unknown submission cannot be cancelled by this slice; inspect the pinned peer and cancel its remote session there. Never claims a remote cancellation succeeded."),
  proc(c: Component, args: JsonNode): JsonNode =
    var item = authorized(c, args)
    if item.value["state"].getStr() != "queued":
      return errResult("dispatch already attempted; cancel on peer explicitly", "unknown")
    item.value["state"] = %"settled"
    item.value["notice"] = %*{"kind": "fleet-settled", "jobId": item.id,
      "status": "cancelled-before-dispatch", "summary": "No remote turn was submitted."}
    item.value["delivered"] = %false
    discard c.storePut("fleetjob", item.id, item.value, item.rev)
    publicJob(item.value),
  %*{"onDemand": true, "sessionContext": true, "approval": "always"})
discard comp.tool("fleet_notices", schema(%*{
  "session": {"type": "string"}, "peek": {"type": "boolean"},
  "ack": {"type": "string"}}, @["session"],
  "Runner Fleet completion inbox. Read is non-consuming; acknowledge only after durable transcript append."),
  proc(c: Component, args: JsonNode): JsonNode = taskNotices(c, args),
  %*{"hidden": true, "runner": true, "effect": "read"})
discard comp.onIdle(500) do (c: Component):
  try: idleJobs(c)
  except CatchableError as e: stderr.writeLine("fleet idle: " & e.msg)
discard comp.onDrain do (c: Component): stopWorker()
comp.run()
