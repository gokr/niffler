# Heartbeat — scheduled conversation turns

Built by `make build`, but not autostarted. Enable with an approved
`spawn {name:"heartbeat", binary:"var/bin/heartbeat", policy:"on-failure"}`.
Do not use replicas: this component owns process-local live-turn hints.

Create a schedule with `heartbeat_set`:

```json
{"id":"morning","session":"review","prompt":"Check the open PRs and report.","intervalSec":86400}
```

The first attempt is within 60 seconds (plus tick granularity); following
attempts use the interval. `enabled:false` parks a record. `heartbeat_list`
shows schedules; `heartbeat_remove` removes one, never its conversation.
Creation/removal are approval-gated and tools are on demand.

Settings are a declared `heartbeat` config domain (`enabled`, `tickMs`,
`maxPerDay`), so `config_patch heartbeat` edits them when the `config`
component is present. `tickMs` is the polling interval (default 30000, minimum
100); `maxPerDay` is the attempts per record in a rolling 24-hour window
(default 4); `enabled:false` pauses ticking. The component falls back to the
historical spellings when no explicit value is stored:

- `NIF_HEARTBEAT_TICK_MS` and `NIF_HEARTBEAT_MAX_PER_DAY` mirror `tickMs` and
  `maxPerDay`.
- `NIF_HEARTBEAT=0` pauses ticking; on the runner, refuses heartbeat turns.

The runner independently re-checks `NIF_HEARTBEAT` and
`NIF_HEARTBEAT_MAX_PER_DAY` before admitting a turn, so those env bounds apply
even after a `config_patch`.

Busy conversations are skipped, never queued. Events are best-effort hints;
the runner's busy refusal is authoritative. Attempt reservations are stored
before publication, so a crash can lose a tick rather than duplicate work.
Dispatch is fire-and-forget: `lastResult` reports an attempt, not completed
work. Read the conversation transcript for actual results.

The runner checks that an enabled record matches the session and prompt,
then writes a unique `heartbeatmark` before inference. Admission counts survive
runner restarts and schedule edits. Marks are retained; retention/compaction
of this ledger is future work. The transcript appends a user-role message
with `notice:{kind:"heartbeat",id}`—runtime machinery, not human input.
Frozen prompts and schemas are unchanged; only history grows.

A heartbeat does not keep a server alive. Run the harness without
`NIF_AUTOSTART=1` for resident work. It never grants approvals: unattended
approval-requiring actions remain denied unless a human explicitly selected
auto mode for that conversation. No cron expressions or daily token-budget
accounting are implemented; normal per-turn conversation limits still apply.
