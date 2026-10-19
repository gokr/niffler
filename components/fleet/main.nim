## Opt-in Fleet provisioning, using the ordinary harness approval gate.
import std/json
import niffler/sdk
import provision

let comp = newComponent("fleet", "0.1.0")
proc schema(properties: JsonNode, required: seq[string], description: string): JsonNode =
  %*{"type": "object", "properties": properties, "required": required,
    "additionalProperties": false, "description": description}
proc handler(name: string): ToolHandler =
  result = proc(c: Component, args: JsonNode): JsonNode =
    var logs: seq[string]
    let runner: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
      result = nativeRunner(argv, input, timeoutMs)
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
  "profile": profile, "transport": {"type": "string", "enum": ["ssh", "multipass", "incus"]},
  "target": {"type": "string", "description": "SSH alias/user@host, Multipass VM name or Incus container name"},
  "host": {"type": "string", "description": "Optional SSH management host alias/user@host for Incus or Multipass only; omit for local. Bound in private receipt; no passwords or agent forwarding."},
  "root": {"type": "string", "description": "Dedicated canonical absolute installation root; Incus requires /home/ubuntu/niffler"},
  "revision": {"type": "string", "description": "Full lowercase 40-character SHA, or a ref (main, v0.4.0) resolved to one before any remote write and recorded as the receipt's pinned revision; existing installs never update"},
  "cpus": {"type": "integer", "minimum": 1, "maximum": 64},
  "memory": {"type": "string", "description": "VM memory, default 4G"},
  "disk": {"type": "string", "description": "VM disk, default 20G"}}
discard comp.tool("fleet_install", schema(installProps,
  @["profile", "transport", "target", "root", "revision"],
  "Install a pinned new Niffler server or adopt an existing installation without updating it; optionally create Ubuntu 24.04 in Multipass or an unprivileged Incus system container. Incus runs as ubuntu at /home/ubuntu/niffler, explicitly enables guest linger, and removes its temporary installer sudo rule on normal success/failure; forced interruption may require manual cleanup. No host sudo, forwarding, credentials, host mounts, privileged/nesting configuration or guest deletion. Save a verified private receipt; provider setup remains explicit."),
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
    else: "Stop a verified Multipass VM or Incus container separately from Niffler service stop. Requires reachable identity; never deletes VMs."
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
comp.run()
