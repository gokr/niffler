# The Fleet inbox — the experience

This is the user-facing contract for delegating work to a remote Niffler and
finding out what happened. It describes what you see and why, not the wire
(docs/WIRE.md) or the delivery ladder (docs/FLEET.md §6). Where the two
disagree, this document is wrong and should be fixed.

Status: **the local half is implemented** (`fleet_task_inbox`); the TUI surface
and the settle event are the remaining slices, marked ▢ below.

## The shape of the thing

You ask a remote Niffler to do something:

> *"on worker, fix the failing test in niffler-tui and report back"*

You then close the laptop, or keep working, or walk away. The work continues on
the worker. Two questions matter afterwards:

1. **Did it finish, and how did it go?** → the inbox answers from your own
   machine, even if the worker is unreachable, rebuilt, or gone.
2. **What exactly did it do?** → a separate drill-down that needs the worker to
   answer, because the transcript stays canonical on the worker.

Those are deliberately different guarantees. The inbox promises a **verdict**;
it never promises **evidence**. Evidence is fetched.

## What you see

### While a job runs

A job moves through `queued → submitting → running → settled`. (Failure states
are `failed` and `uncertain` — see "When things go wrong".)

### When it settles

A connected client learns immediately: the settle transition publishes
`ev.fleet.settled`, which carries enough to render a toast without a store read
(peer, objective, status, bounded summary, artifact descriptor). Disconnected
clients learn on their next inbox read — the event is a convenience, and the
job record is the durable truth. Re-reading a settled job never re-alerts.

The job's record gains a self-contained notice, and the row shows:

| Field | Meaning |
|---|---|
| **peer** | which instance ran it, by registry name |
| **objective** | your own words, bounded — what the row is *about* |
| **state** | `settled` (plus `failed`/`uncertain`) |
| **settled.status** | the worker's own outcome word |
| **settled.summary** | bounded report text (≤ 2048 bytes, ellipsized) |
| **settled.activation** | which run of that session this was |
| **artifact** | descriptor only — name, media type, size, digest, one-line summary |
| **notified** | whether the *runner* has appended the notice to a transcript |

The summary is a report, not a proof. It is what the remote agent said it did,
scoped to what it was allowed to do. Treat it as a claim to review, which is
exactly why artifacts and commits live on your GitHub repos rather than here.

### Drilling down

▢ *The TUI surface.* Opening a row calls `fleet_task_result {jobId}` — the
remote transcript, paged, `bounded: true` per line — and, when present, fetches
the artifact descriptor's bytes through the scoped artifact protocol. This
**does not work offline**: the worker's transcript is canonical there. A job
whose instance is gone keeps its verdict in the inbox and loses its detail.
That is the intended trade, not a bug.

## Unread, and why it is yours alone

Two different "delivered" notions exist, and conflating them would be a bug:

- **The model's notice.** When a background child settles, the parent
  *conversation* can be woken with a settlement notice — runner machinery
  (`fleet_notices`, hidden). `delivered: true` means *a runner appended it to a
  transcript*. That is model acknowledgment.
- **Your unread count.** Client state. ▢ The TUI keeps seen/dismissed markers
  keyed by `(instanceId, jobId, activation)` **locally**. Nothing writes them to
  the store, so no model can mark its own work as read by you, and reading the
  inbox acknowledges nothing.

Practically: `fleet_task_inbox` reports `notified` (the runner's flag) for
transparency and exposes **no** read/seen field of its own. A row you have
never looked at is unread because *your client* has not seen it yet.

### First connection baselines history

▢ Opening the TUI against a harness with a long job history must not light up
every past job as new. On first connect the client **baselines**: it records the
current set as already-seen, and only later settlements alert. (Implemented
client-side; the store has no opinion.)

### Reconnect reconciles by keys, not time

Paging is by a **stable job-id cursor** (`nextAfter` → `after`), never a
timestamp watermark. A reconnect walks the whole kind past any single 1000-item
page, so a job that settled while you were away cannot be hidden behind a
fuller page.

## When things go wrong

| Situation | What you see | What you can do |
|---|---|---|
| Worker unreachable mid-job | `state` stays `running`; the row goes stale | wait, or `fleet_task_cancel` |
| Outcome unprovable | `uncertain` — never invented success | inspect the worker by hand |
| Worker rebuilt/removed after settling | verdict intact, detail unavailable | read the summary/artifact, ask again |
| Job refused by the worker | `failed` with the worker's reason | fix the grant/task and resubmit |
| Registry entry removed | row stays, peer labelled by transport target | `fleet_instances` no longer lists it |

The rule behind all of these: **missing bytes or evidence are never fabricated.**
An `uncertain` job is honest; a `settled`-with-guess would not be.

## What the inbox deliberately cannot do

- **Grant authority.** Reading, or a notice arriving, never widens what a peer
  may do. Unattended coding is enabled by an operator profile and a per-job
  grant, never by asking for it (§5 of FLEET.md).
- **Acknowledge for you.** No write path from a read.
- **Guarantee the peer is alive.** A row proves what the worker *reported*, and
  `fleet_probe` is what proves it is reachable *now*.
- **Carry artifact bytes.** Descriptors only; bytes are a separate, scoped,
  on-demand fetch.

## Remaining slices

| ▢ | Slice |
|---|---|
| ✅ | `ev.fleet.settled` broadcast so a connected TUI can toast instead of polling |
| ▢ | TUI: `/tasks` list, toast, client-local seen markers, baseline-on-connect, drill-down |
| ▢ | Artifact retrieval for a settled activation |
