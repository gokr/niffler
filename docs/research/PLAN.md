# Plan — open work

This is the short list of deliberately deferred work. Shipped behavior belongs
in the [manual](../MANUAL.md); design history and proposals belong in
[research/](README.md).

## Current priorities

- **Level 1 UI dynamism** — add `x-ui` schema hints and a generic renderer
  registry so components can describe how their tool results render.
- **Session branching / navigation** — provide a user-facing session tree,
  labels and derivation on top of the shipped continuation and fork contracts.
- **Settings** — implement the human/model settings surface described in
  [SETTINGS.md](SETTINGS.md), including precedence and persistence.
- **Optional sandboxing** — add an explicit OS/VM isolation component if
  running untrusted generated code becomes a requirement. Fabric guests are
  currently approved native code in bash's trust class, not a sandbox.

## Shipped foundations

These were previously tracked here as plans and are now part of `main`:

- Context ledger, deterministic prune/trim, replaceable compaction, durable
  projections and recall, plus bounded provider-overflow recovery; see
  [research/COMPACTION.md](COMPACTION.md).
- Continuable and forked subagents, settlement notices (including the bounded
  autonomous wake that tells an idle parent its children finished) and
  `agent_list`; see
  [MANUAL.md](../MANUAL.md#fabric-and-subagents) and the historical runbook
  [research/SUBAGENTS-PLAN.md](SUBAGENTS-PLAN.md).
- Compiled-Nim Fabric guests, structured APIs, caching, cancellation and
  bounded execution; see [FABRIC_GUIDE.md](../FABRIC_GUIDE.md).
- SQLite (default), Barrel and TiDB store engines behind one contract; see
  [MANUAL.md](../MANUAL.md#store-engines) and [research/STORE_V2.md](STORE_V2.md).
- Pure-Nim NATS client, the configurable LSP registry and semantic operations,
  background processes, MCP bridges, self-documenting skills and repomap
  discovery.

## Possible follow-ups

- **Resource-scoped batch effects** — relax Fabric's global write exclusion
  only after resource ownership can be declared safely.
- **Durable Fabric/agent traces** — store-backed retention for diagnostic
  lifecycle events; current logs are intentionally bounded and non-authoritative.
- **Component package template** — publish a reusable community-component
  template and release workflow.
- **JavaScript without compilation** — `sdk/ts` and `builder` support TypeScript;
  direct execution via a runtime such as `tsx` remains optional.
- **Pipewrap** — an NDJSON/stdio adapter for plain scripts that do not use an
  SDK.

A plan item is not an implementation promise. Update this file when work lands,
and record user-visible changes in [CHANGELOG.md](../../CHANGELOG.md).
