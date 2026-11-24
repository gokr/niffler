# niffler-tui 0.11.0 — release notes

**Release date:** 2026-11-24
**Range:** `v0.10.0` (2026-10-29) … this tag — 16 commits since the last release
**Paired harness:** Niffler **0.6.0** — cut in the same window; the harness release defines what this client can claim.

## In one paragraph

A client release about telling you what is actually true. `/worktree` grew from
a couple of commands into the loop a human actually types — add, status, merge,
rm, close — and stops reporting implementation state instead of your situation:
`add` no longer refuses, it decides between moving a pristine conversation and
forking one with history, and both `merge` and `close` say what they did and
where you land. The background badge now answers the question you have when you
are about to walk away — will this completion come back to me? — from core's own
readback rather than a client-side guess. Free-text session search reaches what
the agent *said*, not just conversation titles. And two daily annoyances are
gone: `/config` is navigable again, and the two-stage stop prompt disarms itself
when you do something else.

## Worktrees

- **`/worktree` commands with move-versus-fork routing.** `/worktree
  [status|add NAME [--fork]|merge|rm PATH|close]`, backed by the harness's git
  tools through the session-scoped control — never a direct component call,
  which would bypass approval and lose session attribution.
- **`add` never refuses.** An uncommitted tree used to be a refusal telling you
  to re-run with `--fork`, which read as if a dirty tree blocked creating one —
  it does not, because a tree is cut from your last commit. The decision now
  turns on the conversation: a pristine one moves into the new tree, one with
  history (or a chosen workspace) forks automatically and keeps its transcript
  and tree. `--fork` remains only to force a fork from a pristine conversation.
  The report says what follows from your uncommitted work — that it stayed
  behind, and that `merge` will refuse for the files it would touch until it is
  committed.
- **`status` reports what a human must choose between.** A bare `/worktree` used
  to print six labelled lines and then the raw JSON from `git_worktree_list` —
  complete and unreadable, listing only this repository's trees without saying
  anything about them.
- **`merge` and `close` say what happened.** `merge` prints
  `merged feat into main (2 commits)`, the files and the target's new short
  commit instead of the tool's receipt JSON, and refuses when the branch has
  nothing the target lacks rather than reporting a meaningless success. `close`
  says where you land in both cases: back at a fork's origin, or in a fresh
  primary conversation that keeps the old transcript as the record.

## Background jobs

- **The badge says whether a completion will wake you.** "bg 2" told you
  something was running and nothing about whether its exit would bring the
  conversation back. The segment now carries core's readback: `bg 2 · wake 1/3`
  while a wake is admissible, and an explicit
  `completion waits for your next message` once the budget is spent or wakes are
  disabled. A job owned by another conversation keeps its place in the count but
  adds no promise. Every `/processes` row gains the same answer per job.
  Nothing is derived client-side — `maxWakes`, `wake {max, used}` and
  `process_list.session` come from core, because a guess would promise a wake
  the runner then declines.

## Memory

- **Distinct ◇ Memory activity blocks** for compatible harnesses: saved/updated,
  forgotten, searched and applied recall, with expandable details and fallback
  warnings. Reconnect restores durable memory activity; stable IDs deduplicate
  live and replayed blocks, and idle memory events do not mark a turn busy.
- **Embedding providers are configurable without touching your chat selection**,
  so turning on semantic retrieval no longer means changing the model you talk
  to. Requires harness 0.6.0 or later for the `memory` domain.

## Sessions

- **Free-text search reaches message content, not just titles.** The `/session`
  browser searched `kind: conversation`, whose indexed fields are id and title
  only, so typing a phrase you remembered the agent *saying* found nothing even
  though the store indexes message content, tool-call arguments and reasoning
  for exactly this purpose.
- **Content search resolves hits by id** instead of paging the whole
  `conversation` kind: the first version walked up to ten pages of 1000
  documents behind a 250 ms debounce, on every keystroke.

## Configuration and controls

- **`/config` is navigable again.** It swallowed every key but enter — the
  browser's own enter handler ran before the shared selector forwarding and
  returned nil for anything else, so arrows, `j`/`k` and page keys did nothing.
- **A catalog refresh reaches an open `/model` picker**, whose cross-provider
  list had been cached for the process lifetime under a key built from the
  provider set alone.
- New conversations (`/new` and the session browser) retain the current
  provider/model selection instead of reverting to the global default.
- Reasoning effort labels display in full.
- The two-stage stop prompt disarms when you do something else: the armed flag
  no longer survives other keys, so a later ESC that only meant to arm cannot
  cancel a turn.

## Upgrading

Install over 0.10.0 as usual (`cli install gokr/niffler-tui`, or your package
recipe). No configuration changes are required.

**Pair this client with harness 0.6.0.** The wake readback, memory activity and
the `memory` config domain are harness-side facts; against an older harness the
client degrades rather than inventing an answer, but the new surfaces stay
empty.

## Known limitations

- The done-marker and lifetime of `/worktree` trees are the harness's rules, not
  the client's: `rm` refuses foreign trees, dirty work and unmerged changes, and
  the client reports that refusal rather than working around it.
- Background approvals for delegated/fleet work remain outside this client.

## Full changelog

See [`CHANGELOG.md`](CHANGELOG.md), section `[0.11.0]`.
