# Conversation sandbox — agreed contract and implementation sequence

Status: agreed design; implementation has started with the pure versioned
snapshot model (`sdk/niffler/sandboxpolicy.nim`) and its contract tests. It is
not yet connected to session persistence, controls, dispatch or enforcement.
Defaults, inheritance and configured/not-enforced status are model-level only.
This supersedes conflicting policy
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

## LSP tools — approved by the user

- Queries, automatic warmup and diagnostics are trusted infrastructure with no
  additional sandbox approval. Their internal project/dependency reads are
  trusted; direct filesystem tools remain subject to approved roots and denies.
- Server listing/status needs no additional sandbox approval.
- Registry changes retain existing approval requirements.
- Remove the experimental mask-triggered blanket server refusal. Do not replace
  it with a rule that disables the trusted server whenever any mask exists.

This is the agreed target, not a claim that the current experimental LSP
implementation has already been migrated.

## Fetch and extraction — approved by the user

HTTP retrieval and trafilatura extraction are trusted infrastructure, with no
additional sandbox approval. Restore trafilatura under sandboxing; the earlier
mask-triggered extractor suppression is not the agreed policy. Existing
protocol, SSRF and output-size restrictions remain unchanged. Generated files
belong in managed scratch storage, not arbitrary caller-selected output paths.
Fetch retains network access independently of bash's network-off default.
Implementation must provide scoped access to returned scratch artifacts without
implicitly granting access to other conversations' files or harness state.

This is the agreed target; restoration and per-conversation integration are not
yet implemented.

## Builder — approved by the user

- build and build_package require human approval on every sandboxed use.
  Ordinary conversation auto-approval does not bypass this conditional gate.
- Approval authorizes an unconfined build: compiler directives and build scripts
  may execute code, access files outside conversation-approved roots and use
  network access. The approval prompt must disclose this broader authority;
  the result must not claim the build was confined.
- info needs no additional sandbox approval.
- Sandbox off retains existing behavior and approval requirements.

This is the agreed target, not implemented conditional per-conversation gating.
The experimental blanket mask-triggered refusal is to be replaced, not treated
as the completed policy.

## Observe — approved by the user

- Reading bus payloads, traces or captures requires approval on every sandboxed
  use, including any management response that includes payloads.
- Sending service requests or publishing events requires approval on every
  sandboxed use.
- Payload-free status/counts and stopping an existing probe need no additional
  sandbox approval. Stop responses must not include captured payloads under
  this exemption.
- Approval permits access beyond conversation scope; it is not confinement or
  proof of secret redaction. Ordinary conversation auto-approval must not bypass
  the conditional gate. Existing approvals still apply when sandboxing is off.

This is agreed policy, not an implemented per-tool classification. Replace the
experimental blanket refusal with these per-tool decisions after auditing each
handler's outputs and effects.

## Repomap and skills — approved by the user

- repo_map enforces approved read roots and deny rules, with no additional
  sandbox approval. Automatic map construction uses the same policy.
- Skill listing, loading and resources have trusted read access to configured
  skill directories outside project roots, but still respect deny rules. They
  need no additional sandbox approval. Skill paths do not become general
  project read/write roots merely because a skill was loaded.
- Skill install/remove retain existing approval and managed-directory rules.
- Instructions do not grant script execution authority: executing skill scripts
  follows bash policy, including filesystem and network rules.

This is the agreed target; the existing global mask checks are only a partial
implementation and do not provide per-conversation approved-root enforcement.

## Git tools — approved by the user

git_status, git_diff, git_log, git_show, git_blame and review_receipt are
ordinary READS, treated the same as read/grep/files: scoped to approved roots,
with no additional sandbox approval and no separate git-specific gate. If the
repository is inside an approved root they work as they do today. A
caller-supplied repo path does not create approval.

Two implementation requirements follow, and neither is a policy difference:

- Repository/user gitconfig must not execute code during one of these reads.
  Disable external diff drivers and textconv filters rather than honoring them;
  git hooks are not part of a read. Otherwise a "read" inside an approved repo
  becomes an escape path, contradicting its treatment as an ordinary read.
- History bound, stated because it is a consequence that cannot be opted out of
  while keeping git reads: a commit, patch, blame range or deleted file can
  contain content that deny rules hide in the working tree. Confining git to an
  approved repository bounds WHERE it runs, not WHAT its output discloses. Be
  explicit in results rather than implying deny rules were applied to history.

Actual mutations remain bash's business and follow bash policy.

## Reaching outside the approved roots — approved by the user

The user asked how this behaves when a tool or a bash command wants something
outside the approved roots. Two tiers, because the two cases differ in what can
be known reliably.

**Default for both: refuse.** Clear message naming the policy and the path. No
automatic retry, no automatic widening, and the refusal must not hint at another
route to the same bytes.

**File tools (read, grep, files, edit, write, replace_across, repo_map, git):**
the refusal is precise because these tools check before acting — they know the
exact path denied. So a human MAY be offered a scoped grant, on the same terms
as the network grant:

- The request is explicit and carries a reason; never implied by a failure and
  never auto-issued after a refusal.
- The human chooses Deny, Allow for this call, or Add to this conversation's
  approved roots. One-call grants are consumed by that invocation, not reusable
  or inherited. Conversation-wide root grants are inherited by subagents.
- Filesystem tools can offer this choice before executing a known out-of-scope
  operation. No operation executes on a declined or unanswered request.
- The prompt shows the normalized path, requested read or read/write access,
  reason and scope. Only a conversation-wide grant widens what subsequent tools
  in that conversation can reach; a one-call grant does not change its roots.
- Deny rules still win: granting a root must not, by itself, unmask a denied path
  inside it. Unmasking a deny rule is a separate, operator-owned decision.
- An agent can never approve itself; ordinary conversation auto-approve mode and
  NIF_AUTO_APPROVE=1 must not satisfy it.
- Read and write are separate: granting read does not grant write.

**Bash:** no path-specific grant prompt derived from a failure. An EACCES/EPERM
or a stderr string is only a *possible* denial — the path is not reliably known,
so the design must not invent one, must not parse the error into a grant request
and must not rerun the command. Preserve the original outcome and require an
explicit new request (the earlier SANDBOX-PLAN wording on this is adopted here).
A bash command CAN still be launched with an explicit, human-approved extra root
or network grant as part of its request.

**Implicit widening is never allowed.** Discovering a sibling checkout or git
worktree does not add a root; only a human decision does. Repeated agent requests
must not accumulate roots by persistence — a refusal is not a negotiation channel
the agent drives.

## Escape-capable tools — approved by the user

processes, plugins, the MCP surface and native Fabric require approval on EVERY
sandboxed use. They can start, drive or inspect arbitrary commands and external
servers; nothing about them is confined by the conversation's filesystem policy.
Approval is authorization to act outside that policy, and neither the prompt nor
the result may describe the action as sandboxed.

The MCP server tool is the clearest case: an MCP server is an unconfined
external process. Approving one means trusting that server, not confining it.

## "Approve from now on" — approved by the user

The user wants to grant an approval for the rest of the conversation instead of
re-approving every call. The machinery partly exists: persisted per-conversation
auto-approve records (store kind `approval`, id `<session>:<key>`) are consulted
by `checkAuto` (core/niffler.nim), so an auto-approved tool shows no dialog at
all, and `autoKey` already keys program-shaped calls by digest rather than tool
name.

Grant granularity is per tool, except where the user chose a coarser unit:

- **MCP: per SERVER, per conversation** (user decision). One approval covers the
  tools of that server in this conversation; it does not cover another server,
  another conversation, or the same server in a child conversation beyond the
  inheritance rule below. This is deliberately not "approve all MCP".
- Everything else: per tool, as keyed today.

Required properties for the sandbox conditional gate:

- The conversation is one turn of a held approval, so the consequence is stated
  plainly to the human: after a grant, later matching calls in THIS conversation
  run without a prompt. The grant is recorded in append-only history and is
  revocable.
- Key the grant on everything that changes the risk in one step, not on the tool
  name alone. For MCP that is the server identity PLUS a digest of its
  configuration (command, args, url, env): otherwise `mcp_update` to a different
  command inherits the earlier approval for different code. Reuse the existing
  `tool:digest` keying idea rather than inventing a second scheme. A per-server
  grant with a per-server digest satisfies both this and the user's granularity
  choice.
- Changing or removing the thing approved invalidates its grant. A grant must
  never outlive the exact target the human saw.
- The blanket conversation `approvals: auto` mode and `NIF_AUTO_APPROVE=1` must
  NOT create, nor satisfy, a sandbox conditional grant. Those are the bypasses
  this gate exists to resist. The operator emergency bypass remains a separate
  documented decision (see the per-call network grant above).
- Grant scope is the conversation the human approved it in. It is not global, not
  persistent across conversations and not a default for new ones. Inheritance by
  subagents (below) is the one sanctioned way a grant reaches work the human did
  not personally approve.

## Subagent inheritance — approved by the user

Subagents inherit the parent's effective sandbox policy AND its active grants.
A child therefore runs under the same enablement, approved roots, deny rules and
per-tool grants as its parent, and cannot widen any of them.

Consequences to implement and test rather than assume:

- One human approval now covers child work the human did not individually see.
  That is the accepted trade: without it a headless child would fail closed and
  stall mid-task. Refusals and inherited grants are recorded as append-only
  history so the transcript shows what a child did under the parent's grant.
- Inheritance is a decision at child creation from the parent's EFFECTIVE
  policy, and continued children re-read it; the earlier open question about
  later human updates propagating to existing children still needs an explicit
  answer and tests (a stale child must not silently keep wider rights).
- A child cannot weaken or bypass the policy, and a child's own new approval
  request routes to a human through the existing approval UI rather than
  self-granting.

## Remaining per-tool review

The user requested individual review of tool treatments. The filesystem group,
bash network, LSP, fetch, builder, observe, repomap, skills, git and the
escape-capable group above are approved in detail. Review next:

1. bash: exact runtime roots, private scratch and background behavior.
2. Undeclared or newly added tools must not silently acquire sandbox authority.
   The proposed default is fail-closed with a recorded refusal until a human
   classifies the tool; it needs agreement because it can disable a brand-new
   capability an operator expects to work.

## User experience — what a sandboxed conversation feels like

Written from the human's seat, so the design is testable against intent. Nothing
below works yet; this is the target.

**Setting it up (operator, once).** A default for new conversations (off in the
initial release), plus approved roots and deny rules. Because the default is
resolved when a conversation starts, changing it never reaches back into
existing conversations.

**Turning it on.** The human enables it for a conversation and grants the roots
that conversation may reach. The agent cannot enable, disable or widen it. The
toggle is per conversation, so a sandboxed conversation and an ordinary one can
run at the same time on the same harness.

**Inside an approved root, almost nothing changes.** read, grep, files, edit,
write, replace_across, undo, repo_map and git keep working as they do today. The
visible differences are at the edges:

- A path outside the approved roots is refused with a clear reason, not a stack
trace, and the refusal says which policy decided. The agent should report that
and stop, not hunt for another route to the same file — and the message should
not advertise one.
- Deny rules apply even INSIDE approved roots: reading a repository's `.env` is
  refused while its source files are not.
- Defaults: `.env`-style deny rules start narrow and are reviewed, not an
  open-ended "secret-looking file" heuristic.

**Bash.** Commands run normally for ordinary work, with three differences the
human will actually notice:

- Writes are confined to the workspace and its writable roots. A command that
  writes elsewhere fails rather than silently succeeding.
- Reads are limited to approved roots plus a reviewed read-only runtime set
  (system executables and libraries). Reads of arbitrary host paths, including
  the home directory and the harness's own state outside the roots, no longer
  work.
- **Network is off by default.** A command that needs the network must say so and
  give a reason, and a human approves that exact command for one run. The prompt
  states plainly that approval grants full host network access for that command —
  not filtered, not domain-limited.

**Unconfined but approvable.** builder, observe, processes, plugins, MCP and
native Fabric still work, but each sandboxed use asks a human first, because
they act outside the conversation's filesystem policy. To avoid a prompt storm,
the prompt offers **"approve from now on"**: for this conversation, that tool
stops asking. For MCP the unit is the **server**, not all of MCP, and the grant
is tied to the server's configuration — so editing a server to run different
code asks again instead of inheriting the old approval.

The honest framing a human gets here: approving these does not sandbox them. It
is the human choosing to trust that tool, in that conversation.

**Trusted tools that keep working.** LSP queries, fetch and trafilatura need no
new ceremony. They are harness infrastructure, not agent shell commands, and
they should not degrade because someone enabled sandboxing.

**Subagents.** A child inherits the policy and the grants. So a headless child
keeps working instead of stalling on an approval nobody will answer — at the
cost that one human decision now covers work the human did not individually see.
The transcript records what a child did under an inherited grant.

**At the end of the turn.** Refusals and approvals are ordinary history entries.
The system prompt and tool schemas do not change when the toggle moves, so
turning sandboxing on mid-conversation does not invalidate the prompt cache.

**What a human should NOT expect.** This bounds what agent-driven tools reach;
it is not a security boundary against a hostile component on the same bus, and
it is not yet available on macOS. Git history can still reveal content that deny
rules hide in the working tree. A writable root that contains the harness's own
source remains a deployment risk the policy cannot fix.

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
