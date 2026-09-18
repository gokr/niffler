# Component audit: `fabric` (Nim, `components/fabric/`, 1115 lines)

Scope: `fabric.nim` (838), `executor.nim` (181), `framing.nim` (96) plus the guest
modules `fabricguest/fabricguest.nim`, `fabricguest/fabricmeta.nim`; built as
`var/bin/fabric` + `var/bin/fabric-exec` (niffler.nimble:44-45, Makefile:277-281).
Docs owned elsewhere: `docs/FABRIC_GUIDE.md` (user guide), `docs/research/FABRIC.md`
(design/threat model), `components/fabric/docs/REFERENCE.md` (LLM reference served
by `fabric_help`).

## 1. What it offers

`fabric` is the programmable tool-calling surface: the model writes one Nim program
instead of calling tools step by step, `fabric-exec` compiles it in a private process
and the host serves its bridge calls over framed stdio (fabric.nim:1-13). Every nested
call is re-dispatched through the session nested-call proxy, so approval, schema
validation and deadlines apply exactly as for a direct tool call (fabric.nim:6-10).
Intermediate results stay in the guest — only the program's `finish()` value enters the
conversation (fabric.nim:4-5, 811-829). Compiled guests are content-addressed and
cached (`var/fabric-cache`, fabric.nim:117, 779). It is governance, not a sandbox:
approved native code is bash's trust class (fabric.nim:622, executor.nim:1-4).

## 2. Tools

| Tool | Purpose (from the schema doc comment) | `x-harness` flags | Exposure |
|---|---|---|---|
| `fabric` | "Write and run a Nim program that drives Niffler tools itself" — `code` (inline Nim, ≤256 KB) or `name` (stored program), optional `tools` allowlist, `strings` payloads, `timeoutMs`, `maxCalls` (fabric.nim:601-621) | `approval: "always"`, `timeoutMs: 300_000`, `sessionContext: true`, `onDemand: true` (fabric.nim:622-623) | discover-only (on demand); listed as on-demand orchestration in MANUAL:1476, approval-gated in MANUAL:459 |
| `fabric_help` | "Read the Fabric guest reference and worked examples without locating component files" — empty `topic` = REFERENCE.md + example index, a topic = that example's source (fabric.nim:649-656) | `onDemand: true` only — no approval (fabric.nim:653) | discover-only |

How a user-authored tool gets declared/compiled: there is no separate declaration
step — the LLM (or a stored program) hands complete Nim source to `fabric`; the
component spawns `var/bin/fabric-exec` per run (fabric.nim:108), which writes
`guest.nim`, prepends `import fabricmeta` + `fabricTools(<pinned schemas>)` when
`tools` is given, writes a driver that imports the guest and calls
`fabricMissingFinish()`, then `nim c --skipCfg…--mm:orc` compiles it and replaces
itself with the binary (executor.nim:56-80, 32-96). Pinned `tools: [...]` gives the
guest compile-time-checked `tools.<name>(...)` wrappers (executor.nim:60-70,
fabricguest/fabricmeta.nim), while raw `callTool` stays allowlisted inside the same
set (fabric.nim:257-260). A guest is therefore "declared" as `code` or as a stored
`fabricprog` doc (`{code: ...}`, fetched at fabric.nim:682) — the store is the only
registry.

Guest-side API (in-program, not bus tools): `call`, `batch`, `callTool`, `finish`,
`log`/`logg`, `stringArg`/`inputs`, `j*` helpers (fabricguest/fabricguest.nim:61-180;
enumerated in MANUAL:2096-2100).

## 3. Configuration

- **Env vars: none.** No `NIF_FABRIC_*` exists anywhere in the tree. Every limit is a
  compile-time constant (fabric.nim:22-38) and the guest environment is deliberately
  scrubbed to `PATH`, `FABRIC_CACHE_DIR`, `HOME`, `TMPDIR` — "deliberately no NIF_*
  vars: the child has no bus and no credentials" (fabric.nim:120-126). The `FABRIC_*`
  vars seen in code (`FABRIC_CACHE_DIR` executor.nim:97; `FABRIC_PROTOCOL_FD`/
  `FABRIC_INPUT_FILE` executor.nim:170-171, fabricguest.nim:32-35) are internal
  host→child protocol, not user settings — the host always sets them itself, so an
  external value is ignored.
- **Where definitions live:** the program library is store kind `fabricprog`
  (`fabric {name}` → `storeGet`/`storeList`, fabric.nim:682-692; kind documented at
  MANUAL:2188). Runtime state is under `NIF_ROOT/var/`: `fabric-cache/` for compiled
  guests (fabric.nim:117, 779) and `fabric-artifacts/<run>.json` (mode 0600) for
  oversized `finish()` values (fabric.nim:586-598). Per-run build dirs are private
  0700 temp dirs (`createTempDir`, fabric.nim:110-111) and removed on exit
  (fabric.nim:112-114). Approved source copies live at `var/approval-sources/
  <digest>.nim` (core/approval.nim:90; MANUAL:2088).
- **JS/TS execution path:** none. The guest language is Nim only — `executor.nim`
  invokes the Nim compiler (executor.nim:56-80) and the component has no ts/js
  executor. Sandboxing/limits are resource bounds, not isolation: `RLIMIT_CPU` 300 s,
  `RLIMIT_FSIZE` 32 MB, `RLIMIT_AS` 2 GB, `RLIMIT_NOFILE` 128, own session
  (`setsid`) and fds 3..255 closed (executor.nim:35-52), with the explicit comment
  that these "are not sandbox guarantees" (executor.nim:33-34). The spawn env has no
  NATS/credentials (fabric.nim:120-126), and the host kills the whole process group
  on timeout/cancel (fabric.nim:134-149).
- **`x-harness.effect` batching:** the guest's `batch()` (≤16 calls, maxBatchBytes
  8 MB, fabricguest.nim:19-22) is scheduled by the host with an explicit cap of
  **4 in flight** (fabric.nim:205). Each tool is classified read/write from the
  pinned schema's `x-harness.effect`, defaulting to `write` for anything
  unclassified or unresolvable (fabric.nim:217-241); reads fill the cap together and
  may overlap a write, while writes are mutually exclusive **globally**, not per
  target, because a universal writer like `bash` can race the same files across
  components (fabric.nim:314-345). Tools without the flag (e.g. `fabric` itself)
  therefore count as writes.
- **Timeouts/budgets:** `fabric` tool schema advertises `timeoutMs` ≤ 300 000 and
  `maxCalls` ≤ 1000 (fabric.nim:614-620); runtime defaults are 240 000 ms and 200
  calls (fabric.nim:704-708), clamped to the caller's remaining session deadline
  (`min(requestedTimeoutMs, outerRemainingMs)`, fabric.nim:713) and to the SDK-side
  `x-harness.timeoutMs` of 300 000 (fabric.nim:622). Every nested call gets only the
  run's remaining slice (fabric.nim:275-280), so one deadline governs the run.
  Further caps: result 50 000 chars before spilling to an artifact (fabric.nim:24-25,
  811-829), `code` 256 KB (fabric.nim:27, 696-697), `strings` 128 entries / 2 MB
  (fabric.nim:28-29, 722-731), logs 1000 events / 1 MB (fabric.nim:32-33, 360-362),
  artifacts 100 files / 100 MB / 7-day expiry (fabric.nim:34-37, 502-528), cache 64
  entries / 128 MB (fabric.nim:535-536, 538-560), ≤16 selected tools with a
  forbidden set `fabric, agent, chat, session, invoke, session_prepare`
  (fabric.nim:30-38, 745-750).

## 4. MANUAL placement

Existing MANUAL surface (all inside the single `## Fabric and subagents` section,
**MANUAL:1974**, with the fabric guide pointer at MANUAL:1980-1983):

- MANUAL:1987 — the `fabric` row of the tool table (the only place the tool's
  arguments are enumerated).
- MANUAL:2074-2106 — nine unheaded `- **…**` bullets (Governance, approval manifests,
  guards, context economy, guest API, when-to-use) that **sit inside
  `### Fork (a child that has read the discussion)` (MANUAL:2051)** and are therefore
  not addressable: no `### Fabric` heading exists between MANUAL:2051 and the next H2
  at MANUAL:2107.
- MANUAL:241, 2188 — fabric persistence mentioned in the store section;
  MANUAL:455-465, 1476 — approval and on-demand exposure lists; MANUAL:759 — the
  `niffler-fabric` skill.

Recommended placement (concise, pointer-first): keep the tool row at MANUAL:1987,
insert `### Fabric (programmable tool calling)` immediately before MANUAL:2080 so the
existing bullets gain an anchor, and let that subsection carry at most: what it is
(2 lines), the tool table rows for `fabric` + `fabric_help`, the trust/approval and
artifact/cache locations (already written), one sentence on effect-based batching, and
**one link to `docs/FABRIC_GUIDE.md` for budgets, nudges, worked examples and event
names**. `docs/FABRIC_GUIDE.md` already owns: "What Fabric is"/"When Fabric wins"
(guide:8-34), nudge phrasing (guide:36-73), approval walkthrough (guide:74-95), the
worked-example tour (guide:96-270), typed mode (guide:271-292), the full
budgets/limits table (guide:294-308), concurrency expectation "4 on the bus at once"
(guide:314), honest expectations incl. cancellation (guide:310-345), the
after-a-run/locations table and `ev.fabric.*` names (guide:346-357), examples/tests
list (guide:358-367) — MANUAL must not duplicate any of that. The LLM-facing program
API stays in `components/fabric/docs/REFERENCE.md` (served by `fabric_help`);
`docs/research/FABRIC.md` keeps the design/threat model. MANUAL:1987's summary of
arguments is accurate and can stay as the one-line index.

## 5. DELTA list

- MANUAL:1987 (table rows list only `fabric`) | CODE: components/fabric/fabric.nim:649-656 registers `fabric_help` (`onDemand`, no approval) | FIX: add a second table row — "`fabric_help {topic?}` | Read the Fabric guest reference and worked-example sources from inside the component; empty `topic` returns the reference plus the example index, a topic returns that program. Discover-only; read the reference before writing a program, so the model never has to locate component files."
- MANUAL:2080 (bullets start unheaded inside `### Fork`, MANUAL:2051) | CODE: n/a (structural; fabric and agent are peers sharing one H2) | FIX: add `### Fabric (programmable tool calling)` before MANUAL:2080 — the fabric material is currently nested under the Fork subsection that ends at MANUAL:2078, so nothing can link to it.
- MANUAL:1987-1988 (`fabric` arguments only, no budgets) | CODE: components/fabric/fabric.nim:24-38 (limits), 704-714 (defaults/cap), 713 (outer-deadline clamp), 275-280 (nested slice) | FIX: append one sentence to the `fabric` row — "Budgets: `maxCalls` defaults to 200 (max 1000) and `timeoutMs` to 240 s (hard cap 300 s, also clamped to the caller's remaining session deadline); every nested call inherits the run's remaining time, and results over 50 KB spill to `var/fabric-artifacts/<run>.json`." Do not copy the full limits table — link docs/FABRIC_GUIDE.md §Budgets and limits (guide:294-308).
- MANUAL:2090 (guards bullet; effect undocumented for fabric) | CODE: components/fabric/fabric.nim:205 (cap 4), 217-241 (classification, default write), 314-345 (reads share the cap and may overlap a write; writes globally exclusive) | FIX: add one bullet — "**Effect-aware batching**: `batch()` runs at most 4 calls on the bus at once. Each tool is classified by `x-harness.effect` (anything undeclared counts as a write); reads may fill the cap together, writes are mutually exclusive globally, not per target." MANUAL currently explains `x-harness.effect` only for MCP servers (MANUAL:1193).
- MANUAL:2084 ("The executor child holds no NATS connection and no credentials") | CODE: components/fabric/fabric.nim:120-126 | FIX: extend the clause — "…no NATS connection, no credentials and no inherited `NIF_*` environment: the child gets only `PATH`, `HOME`, `TMPDIR` and the cache path."
- MANUAL:1987 ("an identical program is cached in `var/fabric-cache`") | CODE: components/fabric/fabric.nim:535-536, 538-560 (64 entries / 128 MB LRU eviction) | FIX: add "cache is self-bounded (64 entries / 128 MB, evicted least-recently-stored)" — otherwise a user reading the MANUAL expects unbounded growth.
- MANUAL:2090 ("a per-turn lease expires stale requests") | CODE: core/dispatch.nim:1221-1222 (`catalog-changed` on fingerprint mismatch), components/fabric/fabric.nim:283-286 (pins component/version/fingerprint per selected tool) | FIX: extend to "…a per-turn lease expires stale requests, and in typed mode each call is checked against the pinned component fingerprint, so a component replaced mid-run fails with `catalog-changed` instead of calling a drifted tool."
- MANUAL:638-672 (Self-extension and component lifecycle) mentions no fabric path | CODE: components/fabric/fabric.nim:606 (stored programs "should graduate into a real component via builder + core spawn"), docs/FABRIC_GUIDE.md:91-93 | FIX: add one cross-ref line in step 1-4 list — "A fabric program that stabilizes takes the same route: `fabricprog` is the scratchpad, `builder.build` + `core.spawn` is graduation (docs/FABRIC_GUIDE.md)."
- MANUAL:2202-2206 (per-target example list) omits `test-fabric` | CODE: Makefile:522 (`test-fabric`: t_fabric, frames, native, cancel) | FIX: add `test-fabric` to the examples (general staleness — the list also omits `test-grep`/`test-edit`/`test-mcp`/`test-agent*`; only worth fixing if the list is kept exhaustive).
- MANUAL:2188 (`fabricprog` store row is accurate) | CODE: components/fabric/fabric.nim:682-692 | FIX: none — no change needed; `fabric {name}` + "save with store `put`" is correct and MANUAL:1987 agrees.

No contradictory/stale statements were found in the existing MANUAL fabric text; the
defects are omissions plus the missing `### Fabric` anchor.

## 6. Not user-facing

`executor.nim` (compile-then-exec, content-addressed cache key at executor.nim:82-96,
rlimits at 35-42), `framing.nim` (bounded 1 MB stdout frames, framing.nim:6),
`fabricguest/*` (guest library), the `FABRIC_*` child-protocol env vars, and the
`ev.fabric.*` lifecycle/log events (emit sites fabric.nim:292, 354, 362, 368/432/479, 770, 794;
documented for users in guide:346-357) need no MANUAL coverage beyond what section 4
proposes. The absence of any `NIF_FABRIC_*` setting is intentional, so the MANUAL
environment table (MANUAL:261-356) correctly stays silent — a one-line "no
environment variables" note is optional, not required.
