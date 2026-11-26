# Niffler 0.6.0 — release notes

**Release date:** 2026-11-24
**Range:** `v0.5.0` (2026-10-29) … this tag — 157 commits, 33 merges
**Size:** 173 files, +22 588 / −1 149; 55 `tests/t_*.nim` touched (23 new, 128 in tree)
**Synced client:** niffler-tui **0.11.0**

## In one paragraph

This cycle is mostly about not wasting a conversation. Four failure modes that
silently burned a turn, a budget or the whole session are now bounded and
named: a denied approval stops costing 300 seconds per retry, a conversation
whose workspace directory was deleted repairs itself instead of becoming
unreachable, a turn that stops making progress ends `stuck` instead of
spending the round budget, and a tool call to a component that dies fails in
about two seconds instead of stalling until the tool cap. Beside those, the
last two SDK gaps closed (the TypeScript SDK now re-attaches to a moved bus),
and two more environment-only knob families moved into the declared settings
surface — core now owns a `core` domain, `heartbeat` owns its own — while
memory's settings finally speak the config owner protocol instead of accepting
a `config_patch` and ignoring it.

## Reliability: the turns that used to be lost

- **A denied approval no longer costs a turn.** When `bash` or any gated tool
  needed approval and the prompt went unanswered, the model retried, and every
  retry waited out another full approval timeout (300 s). Measured on four
  audit subagents: every one burned its entire tool-call budget on repeat
  denials and returned no findings, while `budget-exhausted` named the wrong
  cause. The gate now memoizes a denial for the rest of the turn, so a repeat
  refuses in milliseconds with "already denied in this turn"; the memo clears
  at every turn start and before a client `invoke`, which is still asked. A
  denial deliberately does not end the turn. Six denials now complete in 1.9 s (measured)
  where six timeouts cost 30 minutes (`tests/t_approval_breaker.nim`).
- **A conversation whose workspace was deleted is recoverable.** Removing a
  merged branch's worktree while its conversation kept going used to wedge
  that conversation permanently: every call answered `cwd is not a directory`,
  and the control calls that would have repointed it failed the same way. A
  vanished directory now falls back to the harness root, recorded as *unchosen*
  so it stays repinnable, announces `ev.workspace.opened`, resets worktree
  isolation to `shared`, and appends a `workspace-lost` notice to the
  transcript (history only — no prompt-cache rebuild). `session_info` reports
  `workspace {root, missing: true, fallback}`.
- **A looping turn ends `stuck` instead of burning the round budget.** Core
  tracks dispatch fingerprints — tool, canonicalized arguments and a digest of
  the *result* — so a poll whose answer changes, or a re-read of a changed
  file, is progress however repetitive the call looks.
- **A component that dies mid-call fails its call in ~2 s.** Only a reap
  counts: a slow-but-registered component keeps its full cap, a replica group
  with a survivor is never failed, and a process that died and was *restarted*
  counts as dead for that call.
- **A spawned nats-server is supervised.** Core respawns it on the same client
  port and rewrites `var/nats-url`, so children re-attach instead of going
  deaf; three failed attempts end core with a legible non-zero exit.
- **A lost tool result reports an unknown outcome** instead of inviting a retry
  of a write that may already have landed.
- **A truncated tool-call batch is refused** before dispatch rather than
  executed as if complete.

## Settings: two more domains, and a lie withdrawn

`config` routes an owner request to `svc.<owner>.call`, and core answers
`svc.core.call`, so `owner: "core"` was always possible — nobody had wired the
owner tool. The consequence was three knobs core itself *enforces* that an
operator could only discover by reading core's source.

- **`core` owns a declared domain.** `config_patch core` sets `attachBudget`,
  `emptyReplyRetries` and `stubDerivable`, with schema validation,
  compare-and-set revisions and `next turn` application timing.
- **`heartbeat` owns one** (`enabled`, `tickMs`, `maxPerDay`).
- **Memory's settings now speak the owner protocol.** Previously a
  `config_patch memory` changed the component's stored mirror while its readers
  kept using env — accepted and ignored, the worst shape of failure. Settings
  load on first use, never from the idle pump.

Every domain keeps the historical `NIF_*` spelling as the migration fallback,
so an existing deployment is unchanged.

## Memory, sandbox and worktrees in development

The cycle also carries the long-term-memory and worktree work that was in
flight at 0.5.0 and has since landed in more complete form — durable facts
scoped per repository, opt-in semantic retrieval with an honest `ranker` and a
text fallback, a local embedder without Ollama, and the sibling-worktree
workflow with a durable ownership ledger, merge preview and peer-fork
provenance. See `CHANGELOG.md` for the full detail.

**The conversation sandbox is a foundation, not a boundary.** A revisioned,
human-only policy record exists, dispatch propagates the same snapshot on every
path, and a policy-enabled *foreground* Linux `bash` launch runs at strict
reach with deny patterns masked and the host root absent. **The filesystem
tools remain ungoverned** and every readback says `enforced: false`. Do not
read this release as a sandboxed conversation.

## Client SDKs

The TypeScript SDK re-attaches after a bus outage, closing the last SDK gap: a
connection unhealthy past `NIF_RECONNECT_GRACE_S` re-resolves the bus (so a
harness restarted on a new port is found), redials, rebuilds every
subscription and re-publishes `reg.publish` without a process restart, with
`onReattached` for components that defer their own announce.

## Upgrading

`make build` and a restart is the normal path; no new prerequisites.

**Upgrade core and the store together.** Both shipped store engines now request
core admission before taking calls, and a second store PID is refused even from
the same root. An older core cannot acknowledge admission, and old components
cannot be fenced by registration rejection — mixed versions around a release
boundary will not work, so stop the harness, rebuild, and start it again.

## Migration notes

- **`NIF_ATTACH_BUDGET`, `NIF_EMPTY_REPLY_RETRIES`, `NIF_STUB_DERIVABLE` and the
  `NIF_HEARTBEAT*` family remain honoured** as fallbacks. Moving them into
  `config` does not require any action; the env values still apply until a
  store value exists.
- **The `memory` domain's knobs have no env spelling at all** — including
  `embedProvider` and `maxDistance`, which are configured through `config`
  only. There is no `NIF_MEMORY_*` fallback for them to migrate from.
- A home that has never run now starts only the core-owned bootstrap set
  (`store`, `bash`, `builder`, `llm`, `systemprompt`) unless it is trusted via
  `NIF_TRUST` or a recorded `var/home-trust` marker. Existing homes are
  unaffected.

## Known limitations

- The conversation sandbox does not confine the filesystem tools, and there is
  no network permission yet. Linux only for the strict reach; macOS reports
  `n/a`.
- TiDB vector retrieval is unsupported and falls back to text ranking.
- Write arbitration is cooperative, not OS fencing.
- The bench comparison table on the website still reports Niffler 0.4.0 numbers;
  re-measuring against this release is separate work.

## Thanks

Everyone who reported a wedged conversation, a runaway retry loop or an empty
`/fav` list — each of those symptoms turned into a contract test in this cycle.

## Full changelog

See [`CHANGELOG.md`](CHANGELOG.md), section `[0.6.0]`.
