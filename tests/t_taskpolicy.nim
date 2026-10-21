## Unattended task policy (docs/FLEET.md §5, slice F2): the effective-authority
## arithmetic, in isolation. No bus, store or model — the same module the
## runner enforces and the system core re-computes, so a test here pins what
## both sides believe.
import std/[json, os, strutils]
import helpers
import ../core/taskpolicy

proc main() =
  # --- profile name shape ---------------------------------------------------
  for good in ["coding", "read-only", "a1", repeat('a', 64)]:
    check("profile name accepted: " & good[0 .. min(8, good.len - 1)],
          validProfileName(good))
  for bad in ["", repeat('a', 65), "has space", "a/b", "a.b"]:
    check("profile name refused: " & bad.escape, not validProfileName(bad))

  # --- control plane is never task authority -------------------------------
  for tool in ["fleet_task_submit", "agent_spawn", "invoke", "fabric", "spawn",
               "builder", "plugins", "mcp", "admission_get", "put", "del",
               "session_prepare", "heartbeat_set", "conversation_delete"]:
    check("control plane: " & tool, isControlPlane(tool))
  for tool in ["bash", "edit", "read", "grep", "git_status", "write"]:
    check("ordinary coding tool: " & tool, not isControlPlane(tool))

  # --- profile validation --------------------------------------------------
  let root = getCurrentDir()
  proc profile(tools: seq[string] = @["read", "edit"],
               unattended = true): JsonNode =
    %*{"name": "coding", "unattended": unattended,
       "tools": %tools, "roots": %[root],
       "maxRounds": 8, "maxCalls": 40, "maxTokens": 20000}
  check("a well-formed profile passes", taskProfileProblem(profile()) == "")
  for (key, value, why) in [
      ("attended", %true, "unknown field"),
      ("tools", %*[], "no tools"),
      ("tools", %*["read", 3], "non-string tool"),
      ("roots", %*["relative/path"], "relative root"),
      ("roots", %*["/"], "filesystem root"),
      ("maxRounds", %"8", "string budget"),
      ("confinement", %"sometimes", "bogus confinement"),
      ("unattended", %"yes", "string boolean")]:
    var doc = profile()
    doc[key] = value
    check("profile refused (" & why & ")", taskProfileProblem(doc).len > 0)

  # --- the intersection ----------------------------------------------------
  let grant = %*{"profile": "coding", "tools": ["read", "edit"],
    "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}
  let ok = resolveTaskPolicy(profile(), grant, root)
  check("a narrower grant is accepted", ok.refusal.code.len == 0, ok.refusal.reason)
  check("the effective policy names exactly the granted tools",
        ok.policy["tools"] == %*["edit", "read"] and  # sorted, deduped
        policyAllowsTool(ok.policy, "edit") and
        policyAllowsTool(ok.policy, "read") and
        not policyAllowsTool(ok.policy, "bash"))
  check("the effective budget is the caller's narrower one",
        ok.policy["budget"]["maxCalls"].getInt() == 10 and
        ok.policy["budget"]["maxRounds"].getInt() == 4)
  check("the policy is marked unattended and explicitly unconfined",
        ok.policy["unattended"].getBool() and
        ok.policy["confinement"].getStr() == "unconfined" and
        not ok.policy["confined"].getBool())
  check("the policy digest is stable for the same authority",
        policyDigest(ok.policy) == policyDigest(ok.policy.copy()) and
        policyDigest(ok.policy).startsWith("sha256:"))
  check("the operator note never reaches the requester",
        not publicPolicy(ok.policy).hasKey("note"))

  # The grant digest binds the authority a human approved, independent of how
  # the two peers spell the workspace path they share.
  let gd = grantDigest(grant)
  check("a grant digest is a stable sha256",
        gd.startsWith("sha256:") and gd == grantDigest(grant.copy()))
  check("tool order and duplicates do not change grant identity",
        grantDigest(%*{"profile": "coding", "tools": ["edit", "read", "read"],
          "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}) == gd)
  check("workspace is not part of grant identity (peers spell it differently)",
        grantDigest(%*{"profile": "coding", "tools": ["read", "edit"],
          "workspace": "/elsewhere",
          "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}) == gd)
  for (label, changed) in [
      ("profile", %*{"profile": "other", "tools": ["read", "edit"],
        "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}),
      ("tools", %*{"profile": "coding", "tools": ["read", "edit", "bash"],
        "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}),
      ("budget", %*{"profile": "coding", "tools": ["read", "edit"],
        "maxRounds": 4, "maxCalls": 11, "maxTokens": 5000})]:
    check("changing the " & label & " changes grant identity",
          grantDigest(changed) != gd)
  check("a non-object grant has no identity", grantDigest(newJNull()) == "")

  # Even an operator profile naming a dangerous callable is not permission
  # to reconfigure the harness or mint new grants from an unattended task.
  for tool in ["build", "build_package", "task_profile_set",
               "task_profile_remove", "task_profile_future", "agent_continue",
               "fleet_future", "mcp_connect", "plugin_future"]:
    let broad = profile(tools = @["read", tool])
    let request = %*{"profile": "coding", "tools": [tool],
      "maxRounds": 1, "maxCalls": 1, "maxTokens": 100}
    let refused = resolveTaskPolicy(broad, request, root)
    check("broad profiles cannot authorize control callable " & tool,
      refused.refusal.code == "task-policy-denied", refused.refusal.reason)
    check("approval refuses forged control grant " & tool,
      not policyAllowsTool(%*{"unattended": true, "tools": [tool]}, tool))

  # Worker-side schema audit: the worker verifies its OWN catalog, so an
  # unfamiliar plugin name cannot smuggle in machinery the name list misses.
  let ordinary = %*{"type": "object", "x-harness": {"effect": "read"}}
  check("an ordinary read tool passes the schema audit",
        taskToolSchemaProblem("some_plugin_read", ordinary) == "")
  check("a writer may pass the schema audit (mode decides effect)",
        taskToolSchemaProblem("some_plugin_write",
          %*{"type": "object", "x-harness": {"effect": "write"}}) == "")
  for (label, schema, mention) in [
      ("unavailable", newJNull(), "unavailable"),
      ("no x-harness", %*{"type": "object"}, "no x-harness"),
      ("hidden", %*{"x-harness": {"hidden": true}}, "hidden"),
      ("runner", %*{"x-harness": {"runner": true}}, "runner"),
      ("sessionContext", %*{"x-harness": {"sessionContext": true}}, "sessionContext"),
      ("noSpawn", %*{"x-harness": {"noSpawn": true}}, "noSpawn"),
      ("malformed flag", %*{"x-harness": {"hidden": "yes"}}, "hidden")]:
    let problem = taskToolSchemaProblem("odd_plugin_tool", schema)
    check("schema audit refuses " & label,
          problem.len > 0 and problem.contains(mention), problem)
  check("schema audit refuses a control callable by name",
        taskToolSchemaProblem("fleet_future_tool", ordinary).contains("control-plane"))

  # --- refusals: explicit, coded, and never a silent widening --------------
  block:
    let wide = %*{"profile": "coding", "tools": ["read", "edit", "bash"],
      "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}
    let r = resolveTaskPolicy(profile(), wide, root)
    check("a tool outside the profile is refused, not clamped",
          r.refusal.code == "task-policy-widened" and
          r.refusal.reason.contains("bash"), r.refusal.reason)
  block:
    let greedy = %*{"profile": "coding", "tools": ["read", "edit"],
      "maxRounds": 4, "maxCalls": 999, "maxTokens": 5000}
    let r = resolveTaskPolicy(profile(), greedy, root)
    check("a budget above the ceiling is refused",
          r.refusal.code == "task-policy-widened" and
          r.refusal.reason.contains("maxCalls"), r.refusal.reason)
  block:
    let indirect = %*{"profile": "coding", "tools": ["read", "fleet_task_submit"],
      "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}
    let r = resolveTaskPolicy(profile(), indirect, root)
    check("indirect delegation is refused even inside a broad profile",
          r.refusal.code == "task-policy-denied" and
          r.refusal.reason.contains("control-plane"), r.refusal.reason)
  block:
    # A profile that names a control-plane tool is not usable at all: that is
    # a standing grant of indirect authority.
    let bad = profile(tools = @["read", "builder"])
    check("control-plane tools never satisfy policyAllowsTool",
          not policyAllowsTool(%*{"unattended": true, "tools": %*["builder"]},
                              "builder"))
  block:
    let elsewhere = %*{"profile": "coding", "tools": ["read"],
      "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}
    let r = resolveTaskPolicy(profile(), elsewhere, "/etc")
    check("a workspace outside the approved roots is refused",
          r.refusal.code == "task-policy-refused-root", r.refusal.reason)
    let nested = resolveTaskPolicy(profile(), elsewhere, root / "core")
    check("a workspace under an approved root is allowed",
          nested.refusal.code.len == 0, nested.refusal.reason)
  block:
    let r = resolveTaskPolicy(profile(unattended = false), grant, root)
    check("a profile that does not allow unattended runs refuses",
          r.refusal.code == "task-policy-denied" and
          r.refusal.reason.contains("does not permit"), r.refusal.reason)
  block:
    let r = resolveTaskPolicy(nil, grant, root)
    check("no profile on the worker means no unattended authority",
          r.refusal.code == "task-policy-denied", r.refusal.reason)
    check("...and never a silent partial policy", r.policy.kind == JNull)
  block:
    var noCeiling = profile()
    noCeiling.delete("maxRounds")
    let r = resolveTaskPolicy(noCeiling, grant, root)
    check("a profile without a budget ceiling refuses",
          r.refusal.code == "task-policy-invalid" and
          r.refusal.reason.contains("maxRounds"), r.refusal.reason)
  block:
    let r = resolveTaskPolicy(profile(), nil, root)
    check("an unattended task needs an explicit grant",
          r.refusal.code == "task-policy-invalid")
    let empty = %*{"profile": "coding", "tools": %*[],
      "maxRounds": 4, "maxCalls": 10, "maxTokens": 5000}
    check("an empty tool list is not an unattended task",
          resolveTaskPolicy(profile(), empty, root).refusal.code ==
            "task-policy-invalid")
  block:
    # Honesty: this harness does not confine delegated work yet, so a profile
    # cannot claim it. Refusing beats shipping a policy that says "sandboxed"
    # over an unconfined shell.
    var sandboxed = profile()
    sandboxed["confinement"] = %"sandbox"
    let r = resolveTaskPolicy(sandboxed, grant, root)
    check("a confinement this harness cannot enforce is refused",
          r.refusal.code == "task-policy-unsupported", r.refusal.reason)
  block:
    let r = resolveTaskPolicy(profile(), grant, "")
    check("an unattended task needs an explicit workspace",
          r.refusal.code == "task-policy-invalid")
  report("TASK POLICY TEST")

main()
