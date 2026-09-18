# Worklist slice: component: fabric

From `worklist.tsv` (11 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A333 (delta)
source: `components/fabric.md`

- MANUAL: MANUAL:1987 — the `fabric` row of the tool table (the only place the tool's arguments are enumerated).

## A334 (delta)
source: `components/fabric.md`

- MANUAL: MANUAL:2074-2106 — nine unheaded `- **…**` bullets (Governance, approval manifests, guards, context economy, guest API, when-to-use) that **sit inside `### Fork (a child that has read the discussion)` (MANUAL:2051)** and are therefore not addressable: no `### Fabric` heading exists between MANUAL:2051 and the next H2 at MANUAL:2107.

## A335 (delta)
source: `components/fabric.md`

- MANUAL: MANUAL:241, 2188 — fabric persistence mentioned in the store section; MANUAL:455-465, 1476 — approval and on-demand exposure lists; MANUAL:759 — the `niffler-fabric` skill.

## A336 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:1987 (table rows list only `fabric`)
- CODE: components/fabric/fabric.nim:649-656 registers `fabric_help` (`onDemand`, no approval)
- FIX: add a second table row — "`fabric_help {topic?}` | Read the Fabric guest reference and worked-example sources from inside the component; empty `topic` returns the reference plus the example index, a topic returns that program. Discover-only; read the reference before writing a program, so the model never has to locate component files."

## A337 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2080 (bullets start unheaded inside `### Fork`, MANUAL:2051)
- CODE: n/a (structural; fabric and agent are peers sharing one H2)
- FIX: add `### Fabric (programmable tool calling)` before MANUAL:2080 — the fabric material is currently nested under the Fork subsection that ends at MANUAL:2078, so nothing can link to it.

## A339 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2090 (guards bullet; effect undocumented for fabric)
- CODE: components/fabric/fabric.nim:205 (cap 4), 217-241 (classification, default write), 314-345 (reads share the cap and may overlap a write; writes globally exclusive)
- FIX: add one bullet — "**Effect-aware batching**: `batch()` runs at most 4 calls on the bus at once. Each tool is classified by `x-harness.effect` (anything undeclared counts as a write); reads may fill the cap together, writes are mutually exclusive globally, not per target." MANUAL currently explains `x-harness.effect` only for MCP servers (MANUAL:1193).

## A340 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2084 ("The executor child holds no NATS connection and no credentials")
- CODE: components/fabric/fabric.nim:120-126
- FIX: extend the clause — "…no NATS connection, no credentials and no inherited `NIF_*` environment: the child gets only `PATH`, `HOME`, `TMPDIR` and the cache path."

## A342 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2090 ("a per-turn lease expires stale requests")
- CODE: core/dispatch.nim:1221-1222 (`catalog-changed` on fingerprint mismatch), components/fabric/fabric.nim:283-286 (pins component/version/fingerprint per selected tool)
- FIX: extend to "…a per-turn lease expires stale requests, and in typed mode each call is checked against the pinned component fingerprint, so a component replaced mid-run fails with `catalog-changed` instead of calling a drifted tool."

## A343 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:638-672 (Self-extension and component lifecycle) mentions no fabric path
- CODE: components/fabric/fabric.nim:606 (stored programs "should graduate into a real component via builder + core spawn"), docs/FABRIC_GUIDE.md:91-93
- FIX: add one cross-ref line in step 1-4 list — "A fabric program that stabilizes takes the same route: `fabricprog` is the scratchpad, `builder.build` + `core.spawn` is graduation (docs/FABRIC_GUIDE.md)."

## A344 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2202-2206 (per-target example list) omits `test-fabric`
- CODE: Makefile:522 (`test-fabric`: t_fabric, frames, native, cancel)
- FIX: add `test-fabric` to the examples (general staleness — the list also omits `test-grep`/`test-edit`/`test-mcp`/`test-agent*`; only worth fixing if the list is kept exhaustive).

## A345 (doc-edit)
source: `components/fabric.md`

- MANUAL: MANUAL:2188 (`fabricprog` store row is accurate)
- CODE: components/fabric/fabric.nim:682-692
- FIX: none — no change needed; `fabric {name}` + "save with store `put`" is correct and MANUAL:1987 agrees.

