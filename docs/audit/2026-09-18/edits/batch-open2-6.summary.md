# batch-open2-6 — component-cli, Testing, Troubleshooting, infra-and-examples (36 rows)

Verified against `docs/MANUAL.md` at `c6884160` (3082 lines) and the tree as it
stands now; `evidence` cites the file:line read *now*, not the wave-2 report's
stale numbers.

| status | n | ids |
|---|---|---|
| apply | 16 | A562, A625, A778, A779, A784, A790, A791, A792, A793, A805, A808, A809, A810, A811, A815, A822 |
| already | 12 | A569, A570, A573, A576, A590, A770, A771, A783, A785, A794, A796, A797 |
| code | 6 | A659, A678, A698, A729, A798, A801 |
| skip | 2 | A799, A818 |
| unclear | 0 | — |

`python3 simulate_round.py 'batch-open2-*.json'`: 142/142 rows of the whole
round land cleanly. Every anchor is checked to occur exactly once in the current
MANUAL *and* to survive the earlier rows of the round — three rows share a
region with another batch and were re-anchored for it (see below).

## Cross-batch collisions (fixed in this set)

- **A784 vs A547** (`batch-open2-4`) — A547 rewrites the very sentence A784
  anchored on and does not keep its old wording. A784 now anchors on the
  sentence's tail (`use sandbox-local Nim caches.`), which A547 keeps verbatim;
  the fixture paragraph lands after the rewritten sentence in either order.
- **A805 vs A802** (`batch-open2-1`) — A802 appends a clause right after
  `swap it in via \`manifest.yaml\``. A805 now inserts its parenthetical before
  that phrase, so the two compose instead of interleaving.
- **A562 vs A566** (`batch-open2-8`) — A566 inserts a sentence before
  `Name-based verification`; A562 keeps that sentence, both orders read through.

## The apply set

- **component-cli** — A562: `cli` is a plain bus client (direct
  `svc.<component>.call`), so its calls skip the approval gate, the
  workspace/session injection, per-tool `x-harness.timeoutMs` and the
  hidden/on-demand filter.
- **Testing** — A625: the compaction verification lane (`make test-compaction`,
  `make test-conformance --bin: --tool:`, opt-in `make live-smoke`).
- **infra-and-examples** — A778/A779 (bus payload budget and the
  `--ports_file_dir` port handshake), A784 (test-only fixture components and
  stub LLMs), A790 (`AGENTS.local.md` is additive), A791 (`prompt_hint` and the
  prompt slots), A792 (16 context files / 200 000 bytes, no env knob), A793
  (same-name replacement; the manifest wins at the next boot), A805 (what the
  `llm-openai` example reads and its hardcoded `max_tokens`), A808 (the real
  stdio environment allowlist), A809 (`tools` **and** `prompts` are bridge
  caches), A810 (`mcp_<server>_bridge_status`, the hidden manager helper), A811
  (exit 3 is deferred until calls finish), A815 (the spilled MCP result is a
  structured pointer), A822 (`NIF_MCP_PROBE_TIMEOUT_MS` also drives the
  bridge's own `--probe`).

## Not doc edits

1. **A798 (code)** — `components/systemprompt/main.nim:210` has a dead
   `let f = loadContextFileFromDir(dir)`; the directory is re-read one line
   later as `primary`. Delete it: one redundant `readFile` per ancestor-walk
   directory, plus a duplicated "unreadable context file" stderr line.
2. **A801 (code)** — `core/niffler.nim:596-604` silently `continue`s when a
   stored `component` record's name is already supervised (declared in
   `manifest.yaml`), unlike the sibling missing-binary warning at :618-620.
   Echo `core: WARNING stored component <name> skipped: the manifest declares
   it`.
3. **A659/A678/A698/A729 (code)** — `grep`, `hooks`, `logfile` and `observe`
   register no `selftest`, so `/doctor deep` never probes them. The prose fix
   those rows propose ("reports it as not implementing one") is **false**:
   core only probes components that register one and reports the count
   (`core/dispatch.nim:844-877`). Register a hidden `selftest`
   (`Component.selfTest`, docs/WIRE.md "Self tests").
4. **A805, code side** — `components/llm-openai/main.go:113-115` formats its
   HTTP error with `req: %s`, embedding the *entire request body* (the whole
   conversation) in the error text that lands in logs and the transcript.
   Drop `req: %s` (or hash/bound it).
5. **A785 (rejected premise)** — the row proposes rewording "agent-built test
   components use sandbox-local Nim caches" to include test-only components.
   That would be false: a test compiling its own fixture runs `nim c
   <repo>/components/ctxtest/main.nim` from the repo root, so it reads the
   *repo* `config.nims`/nimcache (the sandbox config only applies to compiles
   that run inside the sandbox — the builder's). No edit; the MANUAL stands.

## Notes for the parent

- A799 is subsumed by A792 (same statement: compile-time constants, no env
  knob); A818 is an internal two-module invariant the MANUAL should not carry.
- The Testing section's `/doctor deep` sentence spells the seam `comp.selfTest`
  while WIRE.md documents the tool as `selftest` (SDK API `selfTest()`). No row
  of this batch owns it — flagged, not edited.
