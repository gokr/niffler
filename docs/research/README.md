# Research

Design-history documents: the ideas, reviews and deep-dives behind what
shipped. Not operating documentation — for that, see
[../MANUAL.md](../MANUAL.md) and [../ARCHITECTURE.md](../ARCHITECTURE.md).

| Document | What it is |
|---|---|
| [REBOOT.md](REBOOT.md) | The original design rationale (2026-08): processes instead of plugins, NATS as the single backbone, the SDK as the real product, payload/serialization and contract decisions |
| [EXPERT.md](EXPERT.md) | Design of the `expert` advisory peer: bounded current-turn observation, the stateless LLM judge over a cache-stable knowledge prefix, and the turn-bound `svc.session.<id>.advise` surface |
| [FABRIC.md](FABRIC.md) | Full design of the `fabric` programmable tool calling and `agent` subagents: architecture, threat model, shipped scope, tests, deferred work |
| [FABRIC_FEEDBACK.md](FABRIC_FEEDBACK.md) | Historical: the external review that reshaped the fabric design before it shipped (its findings are resolved in FABRIC.md) |
| [MCP.md](MCP.md) | Plan (not shipped): MCP client support — external MCP servers contribute tools as ordinary bus tools |
| [CODEWHALE.md](CODEWHALE.md) | Prior-art analysis of the CodeWhale coding agent (`../CodeWhale`): what to borrow, mapped to Niffler components — pinned prompt-cache prefix, user memory, subagent postures, typed permission rules, shell sandboxing, replay aliases; plus a 2026-09 delta re-sweep (worktree write-claims, eval-harness contract, external-memory cutline, RLM sessions, aux-model policy, modes) |
| [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md) | Findings: what pi (github.com/earendil-works/pi) does that Niffler lacks on token consumption and wall-clock execution, plus the concurrency deep-dive (NATS fan-out vs. Nim task pools) |
| [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) | Plan: ordered improvements (parallel tool fan-out → LLM compaction → retry/cache/accounting → session tree), with wire-spec implications and effort |
| [PI_EFFICIENCY_B1B_THREADS.md](PI_EFFICIENCY_B1B_THREADS.md) | Decision record: same-component bottleneck, Nim mechanism evaluation (`std/threads` + `std/locks` preferred), deferred worker-aware pump, process replicas, and concurrent-safe Go tools |
| [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md) | Feature-level scan of pi (basis `6aedd1066`): durable tool lifecycle (replay + checkpoints), deferred tool loading, project trust, session tree/lanes, prompt templates, model policy, evals, export — tiered with Niffler-shaped mappings and an effort order |
| [STORE_V2.md](STORE_V2.md) | Plan (in progress, `feat/code-hygiene`): three interchangeable stores (barrel default, Go SQLite + TiDB with goose), DuckDB as a bus observer, SDK expansion + duplication ledger |
