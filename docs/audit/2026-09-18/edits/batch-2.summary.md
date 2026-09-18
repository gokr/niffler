# batch-2 consolidation summary

59 rows from `batch-2.txt` (component-bash 22, y-capabilities 13, component-mcp 9,
testing 7, troubleshooting 5, minimal-boot-profile 2, contents 1).

| status | count |
|---|---|
| apply | 19 |
| already | 24 |
| skip | 15 |
| unclear | 1 |

Statuses follow the ledger legend: `skip` covers verified rows (`A097`, `A013`),
`code-bug?` rows whose fix belongs in code (`A124`, `A289`), and rows whose facts
are delivered by another edit in this batch (see "folded" below).

## applied edits (19)

| id | where | what |
|---|---|---|
| A276 | `docs/MANUAL.md:87` | new `### bash in detail` subsection (before `### Minimal boot profile`) — schema, both timeouts, the two caps, spill dir, exit-code contract, cancellation freshness, effect class. The batch's one structural addition; a level-3 heading, so `## Contents` is unchanged. |
| A286 | :1259 | `process_start` row: a `run_in_background` start is approved once, a direct call is gated |
| A114 | :1524 | `x-harness.runner` added to the exposure discussion |
| A118 | :293 | build/script-only knobs (`NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT`, `NIF_LSP_BIN`) distinguished from runtime vars |
| A122 | :611 | session `tools` allowlist cap (32 names) |
| A149 | :171 | new `### Clients and the UI registry` subsection (leases, claim/release, display numbers, restart handoff) |
| A419 | :1430 | mcp tools table column `Effect` -> `Purpose` (the `mcp_search` row was already there) |
| A420 | :1433 | `mcp_add`: parked `enabled: false` config, 15 s no-registration `warning` |
| A423 | :1383 | mcp drift: fail-closed *retiring* state instead of crash-looping |
| A426 | :1377 | `niffler_edit`/`niffler_grep` -> `read`/`grep` |
| A428 | :1330 | bridge re-reads its `mcp` record at startup; exits if disabled |
| A429 | :1475 | `mcp_search` failure modes, browsing never mutates |
| A430 | :1432 | `mcp_servers` 1 s status timeout, `live: false` fallback |
| A431 | :85 | `mcp_search` added to the shipped-component enumeration |
| A095 | :2443 | test-target hand-list -> `make help` pointer (names `test-uireg`, `test-autostart`, `make test-server`) |
| A164 | :2451 | "private NATS server whose loopback ports are allocated by NATS" -> each test starts its own nats-server |
| A104 | :2565 | `git restore ... manifest.yaml Makefile` |
| A195 | :2563 | orphaned-bus row reworded (PDEATHSIG on Linux; realistic causes; stale `var/nats-pid` ignored) |
| A014 | :114 | `NIF_OPENAI_CONTEXT` caveat for the retired built-in DeepSeek ids |

Every `old_string` was checked against the current `docs/MANUAL.md`: all 19 occur
exactly once.

## folded into another edit (10)

`A278`, `A280`, `A281`, `A282`, `A284`, `A287`, `A288` -> the A276 subsection
(caps, parse/start marker, truncation marker shape, 30 s cancel freshness +
stashed cancel, the two timeouts, being write-class for fabric, shell/env/stdin).
`A163`, `A205` -> A095 (same make-snippet block). `A151` -> A149 (restart handoff
sentence). These are recorded `skip` with the reason naming the edit that carries
them; a second edit would have needed the same anchor.

## already (24)

A267-A275, A283, A290, A292, A293 (bash), A115, A116, A117, A120, A121, A123
(y-capabilities), A432 (mcp), A096, A206 (testing), A101, A103 (troubleshooting).
The manual has grown well past the audited 2324-line revision, so most of these
were simply true already (e.g. `var/toolout/` at :48, `.env` hardening at :398,
OAuth lifetime at :907, `NIF_LSP_WARM_MAX` at :322).

## left for the parent / separate work

- **A124** (`skip`, code): session tool schema drift in `core/catalog.nim` vs
  `core/conversation.nim` — a code fix before any doc edit.
- **A289** (`skip`, code-bug?): `bash`'s `self_test` (and `deep`) is implemented
  but mentioned nowhere.
- **A153** (`unclear`): trimming the subject listing in `## The bus in one screen`
  would delete the ~35-line fenced subject table and cannot be anchored on a short
  unique `old_string`; needs an explicit decision.
- Remaining gaps inside otherwise-satisfied rows (no source reading was allowed in
  this pass, so the semantics could not be written): an `agent_ask` tool row, a
  `prompt_hint` row (A150), and the DeepSeek `finish_reason` / `max_tokens`
  specifics (A123).
