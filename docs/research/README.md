# Research

Design-history documents: the ideas, reviews and deep-dives behind what
shipped. Not operating documentation — for that, see
[../MANUAL.md](../MANUAL.md) and [../ARCHITECTURE.md](../ARCHITECTURE.md).

| Document | What it is |
|---|---|
| [REBOOT.md](REBOOT.md) | The original design rationale (2026-08): processes instead of plugins, NATS as the single backbone, the SDK as the real product, payload/serialization and contract decisions |
| [FABRIC.md](FABRIC.md) | Full design of the `fabric` programmable tool calling and `agent` subagents: architecture, threat model, shipped scope, tests, deferred work |
| [FABRIC_FEEDBACK.md](FABRIC_FEEDBACK.md) | Historical: the external review that reshaped the fabric design before it shipped (its findings are resolved in FABRIC.md) |
| [MCP.md](MCP.md) | Plan (not shipped): MCP client support — external MCP servers contribute tools as ordinary bus tools |
| [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md) | Findings: what pi (github.com/earendil-works/pi) does that Niffler lacks on token consumption and wall-clock execution, plus the concurrency deep-dive (NATS fan-out vs. Nim task pools) |
| [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) | Plan: ordered improvements (parallel tool fan-out → LLM compaction → retry/cache/accounting → session tree), with wire-spec implications and effort |
| [PI_EFFICIENCY_B1B_THREADS.md](PI_EFFICIENCY_B1B_THREADS.md) | Decision record: evaluated `threadpool`, `tasks`, `taskpools`, and raw threads for same-component concurrency; rejected SDK threads and shipped NATS process replicas |
