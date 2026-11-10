## Versioned conversation policy data. No enforcement or environment reads.
## Callers persist a validated snapshot before activating it. Tool arguments
## must never be treated as authority to construct or widen this policy.
import std/[json, os, sequtils]

const SandboxPolicyVersion* = 1

type SandboxPolicy* = object
  enabled*: bool
  readRoots*, writeRoots*, denyPatterns*: seq[string]
  grants*: JsonNode

proc validateRoots(node: JsonNode, field: string): seq[string] =
  if node == nil or node.kind != JArray:
    raise newException(ValueError, field & " must be an array")
  for item in node:
    if item.kind != JString or item.getStr().len == 0:
      raise newException(ValueError, field & " entries must be nonempty absolute paths")
    let path = item.getStr()
    if not path.isAbsolute() or '\0' in path:
      raise newException(ValueError, field & " entries must be absolute paths without NUL")
    if path notin result: result.add path

proc decodeSandboxPolicy*(node: JsonNode): SandboxPolicy =
  ## Strict decoding: unsupported versions or malformed policy never become off.
  ## Path canonicalization and safe-open enforcement belong to the authority and
  ## filesystem layers; this decoder deliberately does not touch the filesystem.
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "sandbox policy must be an object")
  for key, value in node:
    if key notin ["version", "enabled", "readRoots", "writeRoots", "denyPatterns", "grants"]:
      raise newException(ValueError, "unknown sandbox policy field: " & key)
  if node{"version"} == nil or node{"version"}.kind != JInt or
      node{"version"}.getInt() != SandboxPolicyVersion:
    raise newException(ValueError, "unsupported sandbox policy version")
  if node{"enabled"} == nil or node{"enabled"}.kind != JBool:
    raise newException(ValueError, "sandbox enabled must be boolean")
  result.enabled = node{"enabled"}.getBool()
  result.readRoots = validateRoots(node{"readRoots"}, "readRoots")
  result.writeRoots = validateRoots(node{"writeRoots"}, "writeRoots")
  let denies = node{"denyPatterns"}
  if denies == nil or denies.kind != JArray:
    raise newException(ValueError, "denyPatterns must be an array")
  for item in denies:
    if item.kind != JString or item.getStr().len == 0 or '\0' in item.getStr():
      raise newException(ValueError, "denyPatterns entries must be nonempty strings without NUL")
    if item.getStr() notin result.denyPatterns: result.denyPatterns.add item.getStr()
  let grants = node{"grants"}
  if grants == nil or grants.kind != JObject:
    raise newException(ValueError, "sandbox grants must be an object")
  # Grants remain opaque versioned authority records until the grant seam lands.
  # Do not interpret arbitrary values here as an authorization decision.
  result.grants = grants.copy()

proc encodeSandboxPolicy*(policy: SandboxPolicy): JsonNode =
  ## Fresh JSON on each call, including an owned copy of grant data.
  %*{"version": SandboxPolicyVersion, "enabled": policy.enabled,
     "readRoots": policy.readRoots, "writeRoots": policy.writeRoots,
     "denyPatterns": policy.denyPatterns,
     "grants": (if policy.grants == nil: newJObject() else: policy.grants.copy())}

proc initialSandboxPolicy*(workspace: string, enabled = false): SandboxPolicy =
  ## Proposed initial snapshot: only the explicit workspace, never siblings.
  ## Exact '.env' basename denial is data, not a secret-name heuristic.
  if not workspace.isAbsolute() or '\0' in workspace:
    raise newException(ValueError, "workspace must be an absolute path without NUL")
  result.enabled = enabled
  result.readRoots = @[workspace]
  result.writeRoots = @[workspace]
  result.denyPatterns = @[".env"]
  result.grants = newJObject()

proc inheritSandboxPolicy*(parent: SandboxPolicy): SandboxPolicy =
  ## Snapshot inheritance, including active grants; no mutable JSON aliases.
  ## Existing-child update/revocation propagation is a separate lifecycle seam.
  decodeSandboxPolicy(encodeSandboxPolicy(parent))

proc addGrant*(policy: var SandboxPolicy, path: string) =
  ## A human grant widens BOTH read and write reach for this conversation. A
  ## write allowance without the matching read one is not a usable root: every
  ## write path reads first (an edit reads the old bytes). It never touches
  ## enablement or deny rules — granting a root must not un-mask a denied file
  ## inside it, which is the operator's separate decision.
  if not path.isAbsolute() or '\0' in path:
    raise newException(ValueError, "grant must be an absolute path without NUL")
  if path notin policy.readRoots: policy.readRoots.add path
  if path notin policy.writeRoots: policy.writeRoots.add path

proc removeGrant*(policy: var SandboxPolicy, path: string) =
  ## Revoking removes the allowance from BOTH sets. Deny rules stay: a path
  ## can be re-granted, but a denial is never silently dropped by a root edit.
  policy.readRoots = policy.readRoots.filterIt(it != path)
  policy.writeRoots = policy.writeRoots.filterIt(it != path)

proc ensureWorkspace*(policy: var SandboxPolicy, workspace: string) =
  ## The conversation's own workspace is always inside its own policy. Used
  ## when a policy is inherited into a DIFFERENT tree (a fork, a worktree
  ## child): the parent's roots name the parent's checkout, so without this a
  ## child born elsewhere could write nowhere. Adding the child's workspace is
  ## not a widening beyond the parent's intent — it is the same project, and
  ## the child's cwd is where its runner already resolves relative paths.
  addGrant(policy, workspace)

proc sandboxConfigurationStatus*(policy: SandboxPolicy): JsonNode =
  ## Phase-one status is deliberately not an enforcement attestation.
  %*{"enabled": policy.enabled, "state": "configured", "enforced": false,
     "policyVersion": SandboxPolicyVersion}
