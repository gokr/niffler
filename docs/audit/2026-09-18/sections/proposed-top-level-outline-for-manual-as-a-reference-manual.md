# Worklist slice: Proposed top-level outline for MANUAL as a reference manual

From `worklist.tsv` (16 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A125 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Layout of a running system (paths, `var/` map, shipped-component inventory with flags).

## A126 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: State and configuration: where everything lives (the five lifetime buckets + precedence).

## A127 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Environment variables (runtime table, `.env` contract, build/script knobs).

## A128 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Starting and stopping (autostart, home bus, service/admin modes) + Clients & the UI registry.

## A129 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Recovery, `make` targets and Common tasks.

## A130 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Troubleshooting (symptom → mechanism → fix, one row per real failure mode).

## A131 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Turns and sessions (runner lifecycle, controls `/approvals` `/limit`, budgets, `busy`, cancellation).

## A132 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Context window: admission ladder, calibration, compaction/recall, prompt-cache discipline.

## A133 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Tools and exposure: catalog vs frozen direct set, `discover`/`invoke`, profiles, hidden/onDemand/runner/approval/sessionId flags, `effect`.

## A134 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Models, providers and effort (selection, `llm_resolve` provenance, provider registry, OAuth, effort states, DeepSeek lane).

## A135 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: System prompt assembly (component seam, context files, workspace tail).

## A136 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Subagents, fabric and the expert peer (spawn/run/continuation/fork, depth, settlement notices).

## A137 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Storage: the bus contract, engines, kinds, write rules, paging, migration.

## A138 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Self-extension: `spawn`/`kill`/`remove`, restart policies, plugins/skills/MCP as capability sources.

## A139 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Observability: `ev.*` + observe/logfile/hooks/console, and what is deliberately *not* an audit trail.

## A140 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Appendices: A. Test suite and verification; B. Schema extensions reference; C. Env-var index; D. Pointer index (WIRE/ARCHITECTURE/FABRIC_GUIDE/research).

