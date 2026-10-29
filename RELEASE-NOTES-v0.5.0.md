# Niffler 0.5.0 — release notes

**Release date:** 2026-10-29 (candidate)
**Range:** `v0.4.0` (2026-10-05) … `5f6d135` — 366 commits, 52 merges
**Size:** 354 files, +51 477 / −2 821; 82 test files touched (105 in tree), 45 new
**Synced client:** niffler-tui **0.10.0**

## In one paragraph

Fleet grew from "run a task on another machine" into a real distributed
surface — containers and SSH hosts with Lima replacing Multipass, durable
admission, an inbox the human can read, and goal-oriented delegation with an
operator-gated ceiling. Beside it, every component got one discoverable
configuration surface, the store learned which instance owns which document
(and how to search vectors), the context manager learned to elide what a later
write superseded, and the sandbox learned to earn the word "applied".

## Highlights

- **Fleet** — Lima and Incus guests, durable admission with receipts and
  settlement notices, a human inbox, `fleet_task_result` paging whole reports,
  task cancellation through a new `session {stop: true}`, and trusted
  goal delegation (`mode: "delegate"`).
- **Configuration surface** — a new optional `config` component: declarations
  with `application` timing, `humanOnly` properties, list/get/patch/reset,
  event-driven propagation, and seven migrated `NIF_*` domains.
- **Instance-scoped storage** — `NIF_INSTANCE_ID`, an `instances` registry in
  both engines, one-time legacy adoption, approval-gated `store_claim`, and
  kNN vector search on `sqlite-vec`.
- **Context health** — `context_status`, a tier-1 "superseded by a later write"
  stub, a tier-2 derivable stub, proportional trim rungs and honest loss
  attribution; `llm` now clamps against an *observed* provider ratio.
- **Safety** — an opt-in `bash` guard and a Landlock launcher with versioned
  policy snapshots; cooperative write arbitration that cannot deadlock on its
  own table size; `session {roots: …}` so the human can grant a sibling
  checkout.
- **Models and vision** — embeddings end to end (`llm.embed`, provider
  `embedModel`, `x-embed-source`), image-carrying tool results in all three
  SDKs, and provider pins that never reroute.
- **Tools** — `replace_across` and `read` select mode replace two shell idioms;
  in-turn pipelines (`save_as`/`resolve_vars`) feed one call from another; a
  slimmer prompt and bounded result routing.
- **Docs** — `docs/FLEET.md`, `docs/FLEET-INBOX.md`, the sandbox decision
  record, all three manuals, and a two-minute animated explainer at `/movie/`.

## Fleet

**Provisioning.** The `fleet` component provisions unprivileged **Incus**
containers and optional SSH management hosts, and now also digest-pinned
isolated Ubuntu guests through **Lima** — which *replaces* Multipass as the VM
transport. Old Multipass profiles refuse explicitly with migration guidance
instead of being silently reinterpreted; SSH and Incus are preserved. Lifetime
grew the two halves it was missing: `fleet_vm_start` powers a guest on (with
the same identity guard `vm_stop` had) and `fleet_remove` forgets a route.
Containers are launched with `boot.autostart=true`, and an update refreshes the
service unit so a changed unit contract actually reaches the host.

**Durable admission (F1).** `fleet_task_submit` produces an admission receipt
pinned to a workspace that cannot be repinned afterwards; activation receipts
record each start; results settle into durable notices with `ev.fleet.settled`
so a connected client alerts instead of polling. Verified routes live in the
store (kind `fleetinstance`) with `fleet_instances` and
`fleet_instance_import`, and the registry grants no authority — actions still
verify identity and take an explicit profile.

**Unattended coding (F2, experimental).** A bounded coding task runs under an
operator-gated profile, returns the change it produced — a commit link rather
than a pasted diff — and keeps the artifact in the inbox row and the settle
event, with off-base commits flagged.

**Goal delegation.** `fleet_task_submit {mode: "delegate"}` sends a *goal*, not
a per-assignment profile: the worker decides its own steps with its normal
capabilities, inside a ceiling its own operator sets once per machine with
`fleet_delegation_set {enabled, tools, roots, maxRounds?, maxCalls?,
maxTokens?}` (readable with `fleet_delegation_get`). The ceiling is off when
absent and refused **before any turn runs**; a requester may only narrow it,
and widening refuses with `task-policy-widened` rather than clamping.
`delegationPolicyVersion: 1` is advertised so an older peer is refused instead
of silently downgraded to `ask`. `fleet_task_continue {jobId, requestId,
content, close?}` appends an activation to a **settled** delegated goal in the
same worker conversation — only the instruction may change, because authority
was frozen at admission. Reconciliation reads the peer's transcript, activity
and admission by remote session, and an explicit peer refusal is preserved as
the job's `diagnostic`.

**The human's side.** `fleet_task_inbox {peer?, state?, after?, limit?}` is a
local read over the `fleetjob` kind, so a job whose peer is gone still shows
what it reported; `fleet_task_result {jobId, offset?, limit?}` now serves the
full final report (`report`, `nextOffset`, `hasMore`, `reportBytes`,
`reportComplete`) at UTF-8 byte offsets without contacting the peer.
`fleet_task_cancel` settles active remote work, and a running turn can be
stopped directly with the new `session {stop: true}` op.

## Configuration surface

A new optional `config` component is the one discoverable surface for settings:
`config_get`/`config_list`/`config_patch`/`config_reset`, approval-gated and
owner-routed. A declaration must state its `application` timing; properties can
be marked `x-config.humanOnly` (readable but not settable by a model); changes
propagate by **event** rather than by restart. `config_get` reports per-property
`timings`. Migrated owners: `repomap.gates`, `fetch.network`,
`logfile.retention`, `models.refresh`, `lsp.warm`, `observe.capture`, and the
processes/MCP limits — each keeping its `NIF_*` variables as the migration path.
Hooks were evaluated for the surface and are deliberately excluded.

## Store and persistence

- **Instance identity.** `NIF_INSTANCE_ID` (else `$NIF_ROOT/var/instance-id`)
  binds a store's owner once at startup, never from a tool argument. SQLite
  adopts its own pre-scoping rows exactly once and refuses a different identity;
  a shared TiDB dataset never adopts implicitly. Pre-scoping rows move by an
  explicit, approval-gated `store_claim` (dry run by default, bounded batches).
- **Vector search.** `store-sqlite` swapped `modernc.org/sqlite` for
  `mattn/go-sqlite3` + `sqlite-vec`, so `search` answers "which documents are
  close to this vector?" (kNN over embeddings held as documents). Instance
  identity threads through the query — a kNN result can no longer return
  another instance's vectors. `store-tidb` answers vector queries with
  `unsupported` rather than pretending with a text scan.
- Reasoning is indexed in the message FTS, so a past `thinking` block is
  searchable.

## Context management

- Read-only `context_status` reports one conversation's stored pressure,
  rungs and caps.
- **Tier-1 stub:** tool results superseded by a later `edit`/`write`/
  `replace_across` are elided before summarization — a read whose declared file
  changed is not merely reclaimable but *stale*. Opt-in tier-2 covers derivable
  results. Rules come from `x-harness.effect` and the declared paths, need no
  configuration, and never touch write results or the last few messages.
- Proportional trim rungs, compaction replay, and durable loss attribution; a
  transient compaction failure no longer costs history silently.
- `llm`'s output clamp now measures the prompt through an **observed ratio**
  (provider-reported tokens over its own estimate, per provider+model), which
  converges in one round trip and is sanity-bounded. Context recovery trusts the
  refusal's own count. Prior turns' reasoning is tombstoned in the projection and
  stripped at the request boundary.

## Safety: sandbox and write arbitration

- **Sandbox.** Landlock-backed launcher with versioned policy snapshots, an
  opt-in `bash` guard using system bwrap, and an "applied" verdict that is
  earned from the real launch rather than a parallel probe. Masked paths are
  enforced in `read`/`grep`/repomap/skills, secret masks are canonicalized, and
  hard-link aliases are refused. Probes are bounded and stay off user files.
- **Write arbitration.** `locks` owns a write-through lease index with cost
  independent of table size; a stopped write releases its claim (a timed-out one
  does not), terminal failures are released, recovery survives store outages,
  wildcard paths claim their base directory, and wave concurrency is kept even
  when arbitration is not installed.
- **Roots.** `session {roots: {add: [...], remove: [...]}}` lets the human grant
  a conversation a sibling checkout — one store document per grant, refusals for
  relative/nonexistent paths, `/` and the primary workspace, and the same
  `workspaceRootsFor` helper the fence and every path tool consult.

## Models, vision and embeddings

- A provider record may name a second model for embeddings; `llm.embed` makes
  the call, `models` exposes `x-embed-source`, and `llm_resolve` reports image
  and embedding capability so a tool can refuse instead of failing mid-turn.
- Tool results may carry images, gated on the resolved model's capability;
  `read` answers image paths; helpers in all three SDKs.
- Reasoning effort accepts `none`, `minimal` and `xhigh`, distinct from "ask the
  provider's default", and degrades instead of failing.
- Pinning is honest: a pinned provider is never answered from another table, a
  provider keeps its own model by exact id, and a pinned turn is refused rather
  than rerouted. Empty tool results are normalized for strict OpenAI-compatible
  providers.

## Tools and prompt

- **`replace_across`** — literal `s///g` over up to 12 files, rules in order,
  `word` for `\b` spans, counts everything before writing (`E_NO_MATCH` on a
  zero total), per-file undo and diff preview.
- **`read` select mode** — locate and fetch in one call: verbatim hit regions
  with merged context, ready to paste into `old_string`.
- **In-turn pipelines** — `save_as` captures a response field, `resolve_vars`
  substitutes `$name`; pipeline calls run serially in message order, keep raw
  arguments in history, and replace intermediate payloads with a receipt.
  Directives are never scanned in calls that do not ask for them.
- A slimmer prompt and tool descriptions, `after`/`limit` routing, workspace-
  relative results, an undo budget plus circuit breaker for `edit`, and a 20 s
  async-diagnostics budget. Clean diagnostics stay out of model history.

## Client SDKs

SDK changes in Nim, Go and TypeScript: tool-result image helpers, explicit
per-component buses for multi-instance clients, reconnect/reattach
notifications, safe connection snapshots across live reattachments, and
`NIF_NATS_DIAL_TIMEOUT` for the Go component SDK. Rebuilt binaries re-exec
through `/proc/self/exe`, so a component rebuilt in place can spawn children
again.

## Server, packaging and developer experience

Resident instances have a scoped user-service lifecycle with `Restart=always`,
`scripts/server.sh persist`/`refresh` reporting readiness and pushing a changed
unit contract, and identity registered at boot. A base install no longer needs
Node for the bus-contract gate. Builds work from a cold Go module cache; the
cgo `sqlite-vec` path ships its own header; `setpriv`/`flock` are chosen by
capability so BusyBox/Alpine works; macOS fixes cover `down-here` and a
`niffler-tui` wrapper that no longer depends on `setsid(1)`. `make
install-tools` installs the agent CLI toolkit (now including `gh` and
trafilatura), `make bootstrap` offers the optional extras one at a time,
`make clean` preserves runtime data, and LSP watchdog children are reaped.

## Benchmarks

A DeepSWE lane that runs the agent inside its task's prepared container, with
the OpenHands and Maki lanes joining the website's table, `full31` records for
each, and model-call timing seams (`NIF_TURN_TIMING`, `NIF_LLM_TIMING`,
`NIF_CORE_TIMING`) unified under `NIF_LOG_LEVEL=debug`. A fresh sweep updated
the published table, where Niffler's row is the average of two runs.

## Docs and website

`docs/FLEET.md`, `docs/FLEET-INBOX.md`, `docs/COMPACTION.md`, the sandbox
decision record and 55 new documents in total; the manual, its zh and zh-TW
translations, `docs/WIRE.md` (tool results, durable admission, delegation) and
the website all track the code. The two-minute animated explainer at `/movie/`
is mobile-ready with content-hashed assets, and its voice-over pipeline is
documented beside it.

## Upgrading

```bash
git pull && make build            # Nim harness
make bootstrap                    # or: fresh install, offers install-lsp / install-tools / install-jev
scripts/server.sh refresh <root>  # push a changed unit contract to a resident instance
```

The synced client is **niffler-tui 0.10.0**.

## Migration notes

1. **Multipass is gone** from Fleet — Lima is the VM transport. Re-provision an
   old Multipass receipt; SSH and Incus receipts keep working.
2. **`store-sqlite` is cgo** (`mattn` + `sqlite-vec`); the pure-Go driver was
   removed, so builds need `CGO_ENABLED=1 -tags sqlite_fts5`. The default store
   still builds without a system SQLite header.
3. **Configuration declarations must state `application` timing**; an
   unenforceable declaration is refused rather than ignored.
4. **Instruction discovery is AGENTS-only** — `CLAUDE.md`/`CLAUDE.MD` are no
   longer loaded automatically (existing frozen prompts are unchanged).
5. **Skills** resolve workspace `.agents/skills`, `~/.agents/skills`, then
   bundled ones; `NIF_SKILLS_BUNDLED_DIR` is removed and foreign-agent/XDG
   directories are no longer scanned.
6. **`NIF_INSTANCE_ID`** is required for every instance on a shared TiDB
   dataset, and pre-scoping rows move only through approval-gated
   `store_claim`.
7. `make install-jq` is folded into `make install-tools`; resident services now
   restart on clean exits too (`Restart=always`).
8. Fleet delegation is opt-in per worker and **refuses wider authority** from a
   requester: a peer older than `delegationPolicyVersion: 1` is refused, not
   downgraded.

## Known limitations

- Goal delegation is slices 1–3; **slice 4 is blocked on deployment**, so a
  hosted-worker flow is not part of this release.
- Unattended coding is experimental, and a delegated goal with `bash` has that
  machine's ordinary shell authority — including its GitHub credentials.
- The sandbox's isolation is per-backend: a policy that cannot be enforced where
  the harness runs reports `degraded` rather than claiming enforcement.
- Write arbitration is cooperative coordination between Niffler instances, not
  filesystem fencing.

## Thanks

Göran Krampe; Ian (@IANTHEREAL) for the Run9 Fleet work and the macOS
`down-here` fix; Jonas Öhrn; and the automated agents that filed, ran and
recorded much of this (`chetterbot`, `gokr-niffler1`).

## Full changelog

See [`CHANGELOG.md`](CHANGELOG.md), section `[Unreleased]` (to become `[0.5.0]`).
