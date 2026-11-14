# Memory milestone: policy and visible activity

Implemented on the memory-validation branch; not yet merged or client-certified.

## Collection policy

The main agent curates verified, reusable, non-obvious and actionable findings.
Include evidence and a freshness window; correct the same subject. Do not save
speculation, TODOs, temporary failures, secrets or a transcript copy. Children
report candidate findings to their parent rather than writing shared memory.
The static prompt hint teaches this policy; it is not an extraction pipeline
and does not guarantee a model will curate well. Evaluate actual model choices
separately from deterministic integration tests.

## Consultation policy

Standing facts are bounded at birth and after compaction. The runner also makes
one best-effort query-focused recall at task entry (three facts), without editing
the frozen prefix. Existing recalled history prevents re-injection on ordinary
resume. Explicit searches remain available for surprising failures or decisions;
there is no automatic topic detector or every-tool-call lookup.

`memory.maxDistance` excludes semantic hits beyond a cosine distance ceiling
(default 0.5). This is a conservative starting value, not a calibrated universal
threshold. Calibrate against the chosen embedding model with positive and
unrelated queries before claiming retrieval quality.

## Display contract

`ev.session.<id>.memory` is a distinct activity family, not generic prose:

- Tool operations persist `memory-activity` documents keyed by session prefix,
  then emit the activity. Fields include operation, phase, subject, scope,
  result, createdAt and `injected:false`. Successful writes say saved/updated;
  refusals do not. Searches are not presented as applied context.
- Applied automatic recall persists `memory` metadata on its canonical message,
  then emits operation=recall, phase=applied, injected=true, text, id and the
  live turnId. Reconnecting clients reconstruct it from the message.
- An event without turnId is not evidence of a running turn. Do not latch busy
  merely because memory activity arrived.

## Client visualization

Implemented in the authorized separate niffler-tui checkout: distinct ◇ Memory
blocks using the theme link accent, warning styling for refusals/fallback,
saved/updated/forgotten/search/applied-recall labels, expandable details via
ctrl+e, durable activity loading and ID-based live/replay deduplication. Memory
keeps a compact attribution row even with tools hidden. Tests prove replay/live
parity and that idle memory events do not latch the client busy. The plugin
manifest includes the new sources; `make build test vet` passed.

No interactive terminal smoke has been performed for this renderer yet. Client
and harness changes are not yet released; use compatible builds together.

## Evidence

The earlier vector/local-runtime slice passed the full 118-test server gate.
The policy/activity slice subsequently passed its narrow tests and the full
119-test server gate. The subsequent activity-ID addition passed test-memory-feed.
The local CPU nomic smoke confirms
768-dimensional inference, not curation quality, threshold calibration or Mac
support. TiDB remains deferred.
