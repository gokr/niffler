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
| [STORE_V2.md](STORE_V2.md) | Plan (in progress, `feat/code-hygiene`): three interchangeable stores (barrel default, Go SQLite + TiDB with goose), DuckDB as a bus observer, SDK expansion + duplication ledger |
| [CODEWHALE.md](CODEWHALE.md) | Prior-art analysis of the CodeWhale coding agent (`../CodeWhale`): what to borrow, mapped to Niffler components — pinned prompt-cache prefix, user memory, subagent postures, typed permission rules, shell sandboxing, replay aliases |
