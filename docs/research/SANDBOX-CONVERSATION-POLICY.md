# Conversation sandbox — agreed contract and implementation sequence

Status: agreed design, not implemented. This supersedes conflicting policy
choices in SANDBOX-PLAN.md and the experimental sandbox branch. The existing
implementation status is recorded in SANDBOX-BASH-STATUS.md; it must not be
mistaken for this contract.

## Authority and lifetime

- Operator-configurable default, initially off. Resolve it once when a new
  conversation starts; changing the default does not silently change existing
  conversations.
- Persist enabled/off, approved read/write roots and deny rules per conversation.
  Human policy updates apply between tool calls, never retroactively to a
  running command. Disabling during an in-flight action must wait for settlement
  or cancel that action before the change takes effect.
- Subagents inherit the parent's effective policy on creation. Agents cannot
  disable sandboxing or enlarge roots. Continued children retain their stored
  policy; propagation of later human updates to existing children needs an
  explicit lifecycle decision and tests, not an accidental mutable alias.
- Runner-owned private context carries the effective policy to shared component
  processes. Tool arguments, cwd and automatically discovered sibling worktrees
  do not grant authority. Every serial, parallel, invoke and nested dispatch
  must use the same policy decision.
- This remains the trusted-local bus model, not authentication against malicious
  peers. Control-plane source inside a writable root remains a deployment risk.

## Filesystem tools — approved by the user

Tools: read, grep, files, write, edit, replace_across and undo.

When enabled:

- Enforce approved roots and deny rules before reading, disclosing, changing or
  creating filesystem content. Read roots and writable roots are explicit data;
  no writes are implied by a read allowance.
- Validate every argument shape and every selected/traversed file, including
  glob, batch, symlink and hard-link cases. For new paths validate the existing
  parent chain, not just a lexical prefix. Do not claim race safety from a
  check-then-open design.
- Check cached results, lazy project instructions, diff previews and undo data
  before disclosure too. A guard only on readFile is insufficient.
- Deny rules are operator policy data, with a default .env exclusion. The exact
  default pattern set is still to be reviewed: do not silently broaden '.env'
  into all dotted files or an unreviewed list of 'similar' filenames.
- Preserve existing tool approval requirements. No additional sandbox approval
  for this group; ordinary approval never authorizes an out-of-scope path.
- Refuse out-of-scope requests clearly; do not suggest bypassing via another
  filesystem tool. Approved-root grants are a separate human policy action.

When disabled: preserve pre-sandbox tool behavior. A leftover mask environment
variable must not independently switch on this conversation policy.

## Per-tool conditional approval

Proposed metadata: x-harness.sandbox.approval = "always". This is declarative
per-tool data, not a component-name switch in core. Enforce before execution,
including parallel and nested dispatch. Existing conversation auto-approval
must not silently bypass the sandbox-specific every-use human gate. Headless
calls fail closed. The exact operator emergency-bypass semantics need review.

This metadata controls approval, not filesystem authority. Approved use of an
escape-capable tool must clearly show that the action is trusted/unconfined;
never label it as sandboxed merely because it was approved.

## Trusted infrastructure and decisions still pending per tool

LSP servers and trafilatura are trusted infrastructure, not hostile agent shell
commands. Do not disable them merely because a mask is configured. Trust does
not grant direct filesystem tools permission to read outside approved roots.

## Bash network — approved by the user

Sandboxed bash has network off by default. A call may explicitly request full
network access and provide a reason. Human approval binds to the exact command,
cwd, effective filesystem policy and that invocation only; it grants no extra
filesystem rights and does not disable deny rules. Subagents inherit the
network-off policy and may request the same per-call approval. Ordinary
conversation auto-approval must not bypass this gate. Denial or an unreachable
human starts no requested network-enabled command.

Do not detect network need from an exit code and automatically rerun: the first
attempt may already have mutated files. A request is explicit, before execution.
On Linux, approval omits bwrap's network isolation for that launch: it exposes
the host network, not a domain allowlist, and the prompt must state that.
Seatbelt implementation and equivalent behavior still require Mac validation.
This is agreed design, not implemented per-call approval support.

## Remaining per-tool review

The user requested individual review of tool treatments. The filesystem group
and bash network policy above are approved in detail. Review next:

1. bash: exact runtime roots, private scratch and background behavior.
2. LSP query, registry and server-management tools individually.
3. fetch and extraction.
4. builder build/build_package/info individually.
5. observe inspection, request/publish and management tools individually.
6. repomap, skills, git, processes, plugins, MCP, native Fabric and remaining
   escape paths. Undeclared new tools must not silently acquire sandbox authority;
   the default treatment still needs agreement.

## Implementation slices

1. Persisted conversation policy, operator default and human update seam;
   inherited subagent policy; tests of off/on/off, resume and cross-session
   isolation. No tool enforcement claims yet.
2. Shared private policy propagation and filesystem enforcement for the approved
   group. Cover all result-producing paths and new-file parents. Restore the
   old global mask/refusal behavior only through a deliberate migration.
3. Bash namespace policy: no readable host-root mount; reviewed read-only runtime
   roots plus approved data roots. Seatbelt requires Mac validation.
4. Per-tool conditional approvals as each tool's classification is agreed.
5. Cross-path contracts: serial/parallel/nested calls, symlinks, traversal,
   cancellation, spills, policy updates, child inheritance and denied approvals.

Prompt-prefix effect: existing system/tool prefixes remain byte-stable. Live
policy changes and refusals enter append-only history. Private per-call context
is injected after provider-visible history is persisted; never splice changing
policy into the frozen system prompt. Schema changes affect new frozen toolsets
only, not existing conversations.
