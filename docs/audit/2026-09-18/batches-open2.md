# Consolidation batches — round `open2`

The still-open rows `status.py` reports, split into 8 balanced batches (one subagent each). Each child writes `edits/batch-open2-<N>.json` and validates every anchor itself; the parent applies them with `apply_edits.py` after simulating the whole round in id order.

Total open rows: 307

## batch-open2-1 (55 rows)

- `Layout of a running system` — 55 rows (doc-edit 44, code-bug? 6, verified 4, trim 1)

## batch-open2-2 (36 rows)

- `Environment variables` — 32 rows (doc-edit 31, code-bug? 1)
- `Component ecosystem (plugins)` — 3 rows (doc-edit 2, verified 1)
- `Background processes (processes)` — 1 rows (doc-edit 1)

## batch-open2-3 (36 rows)

- `Observation and logs` — 32 rows (doc-edit 31, verified 1)
- `Common tasks` — 3 rows (doc-edit 2, verified 1)
- `Model catalog (models)` — 1 rows (verified 1)

## batch-open2-4 (36 rows)

- `component: builder` — 28 rows (doc-edit 27, code-bug? 1)
- `component: recall` — 6 rows (doc-edit 4, code-bug? 1, trim 1)
- `Provider registry (provider)` — 2 rows (doc-edit 2)

## batch-open2-5 (36 rows)

- `The store` — 25 rows (doc-edit 19, code-bug? 4, verified 1, trim 1)
- `component: console` — 6 rows (doc-edit 4, code-bug? 2)
- `System prompt (systemprompt)` — 4 rows (doc-edit 3, trim 1)
- `Contents` — 1 rows (doc-edit 1)

## batch-open2-6 (36 rows)

- `component: infra-and-examples` — 22 rows (doc-edit 21, trim 1)
- `Testing` — 7 rows (code-bug? 4, verified 2, doc-edit 1)
- `component: cli` — 4 rows (verified 3, doc-edit 1)
- `Troubleshooting` — 3 rows (doc-edit 3)

## batch-open2-7 (36 rows)

- `Progressive tool discovery` — 14 rows (doc-edit 13, code-bug? 1)
- `Hooks` — 14 rows (doc-edit 10, code-bug? 3, trim 1)
- `Approvals` — 5 rows (doc-edit 5)
- `Starting and stopping` — 2 rows (doc-edit 2)
- `Recovery` — 1 rows (doc-edit 1)

## batch-open2-8 (36 rows)

- `Context window` — 14 rows (doc-edit 9, code-bug? 3, trim 2)
- `The bus in one screen` — 8 rows (doc-edit 6, code-bug? 2)
- `External MCP servers (mcp)` — 6 rows (doc-edit 6)
- `State and configuration` — 4 rows (doc-edit 4)
- `component: compaction` — 3 rows (doc-edit 2, trim 1)
- `Self-extension and component lifecycle` — 1 rows (doc-edit 1)

## Class census (all open rows)

- doc-edit: 256
- code-bug?: 28
- verified: 14
- trim: 9
