# Documentation audit — release after 0.4.0

Compiled from `git log v0.4.0..HEAD` (**366 commits**, `v0.4.0` = 2026-10-17) to
answer one question: *what shipped since the last release that the manual, the
wire spec and the website do not yet describe?*

The **CHANGELOG is not the problem** — `[Unreleased]` already carries 126
entries and is current for every slice below. The gaps are in `MANUAL.md`
(user-facing), `WIRE.md` (contracts) and `website/`, and they are concentrated
in two places: the **sandbox subsystem** (research-only) and the **newest fleet
tools**.

## 1. What landed, by area

Counts are `feat`/`fix` commits in that scope since `v0.4.0`.

| area | feat/fix | what it is |
|---|---|---|
| **fleet** | 15 / 10 | trusted-worker delegation (slices 1–3), cancel ACTIVE remote work via the session `stop` op, `ev.fleet.settled`, `fleet_task_inbox` (the human inbox over `fleetjob`), `fleet_remove`/`fleet_vm_start`/`fleet_vm_stop`, commit linking instead of diff pasting, coding artifacts returned whole, F2 unattended coding tasks, durable admission + activation receipts, explicit process service for SSH hosts without systemd, verified instance routes in the store registry, pinned container boot policy |
| **sandbox** | 7 / 8 | **new**: versioned conversation policy snapshots, masked paths enforced in `read`/`grep`, repository maps and skills excluding masked files, launch attestation from the real launch, opt-in bash guard on system `bwrap` (synchronous), the launcher (policy + Landlock backend + probe + honest reporting) |
| **config** | 7 / 0 | the discoverable `config` surface, declaration `application` timing, `humanOnly` properties, event-driven propagation (`ev.config.updated`), owners publishing `logfile.retention`, `models.refresh`, `lsp.warm`, `repomap.gates`, `fetch.network`, `observe.capture`, `processes.limits`, `mcp.limits` |
| **store** | 5 / 1 | staged document instance ownership, bound owner at startup with one-time legacy adoption, `store_claim` migration, validated instance registry APIs |
| **locks** | 2 / 8 | cooperative write arbitration; recovery hardening; wildcard paths claim their base directory; stopped writes release their claim |
| **context** | 3 / 1 | read-only context health with runner introspection, tier-1/tier-2 stubs, proportional trim + compaction replay + durable loss attribution |
| **store-sqlite** | 3 / 0 | **vector search** — kNN over embeddings held as documents (mattn + sqlite-vec), reasoning indexed in FTS |
| **sdk** | 3 / 2 | tool-result image helpers in all three SDKs, reattach/reconnect notifications, per-component bus pinning, `/proc/self/exe` re-exec |
| **vision** | 2 / 0 | tool results may carry images; the image projection gates on the resolved model's capability |
| **skills** | 2 / 0 | workspace + shared user agent skill roots, `/skills*` slash commands |
| **tools** | 2 / 1 | `gh` installed + token docs, slim direct schemas with bounded results |
| **llm / provider / models** | 3 / 3 | `llm.embed`, `provider.embedModel`, `models.x-embed-source`, pinned providers never reroute |
| **core** | 2 / 4 | instance approval default, persistent instance metadata at boot, **tool-pair repair**, workspace not frozen at the harness root |
| **roots** | 1 / 0 | the human may grant extra conversation roots |
| **activity** | 1 / 0 | durable per-conversation completion feed for clients |
| **server** | 1 / 1 | report/refresh resident service units, restart after clean exits |
| **bench** | 2 / 0 | `kill-run` by exact run, persistent offline task container |
| misc fixes | — | `edit` undo in the store; cli honours a tool's declared budget; `grep`/`discover` declare read-only; agent children inherit explicit pins only; reasoning tombstoned in the projection; LSP diagnostics wait 20 s |

## 2. Documentation status

`●` documented `◐` partial (tool table only) `○` missing

| area | MANUAL | WIRE | website | verdict |
|---|---|---|---|---|
| config surface | ● | ● | ◐ | done (four sections translated this week) |
| fleet tasks/admission/delegation | ● | ● | ○ | manual OK, **website silent** |
| fleet inbox (`fleet_task_inbox`) | ◐ | ○ | ○ | one tool row; no prose on the human inbox |
| `fleet_notices` · `fleet_instances` | ○ | ◐ | ○ | **missing from MANUAL entirely** |
| sandbox launcher (bwrap/Landlock) | ○ | ○ | ○ | **research only** — see §3.1 |
| masked paths (`NIF_BASH_SANDBOX_MASKS`) | ○ | ○ | ○ | **missing** |
| conversation policy snapshots | ○ | ○ | ○ | **missing** |
| vector search / `llm.embed` | ● | ◐ | ◐ | manual has it; site has one line |
| extra conversation roots | ○ | ○ | ○ | **missing** |
| activity / completion feed | ◐ | ● | ○ | wire only |
| tool images (vision) | ● | ● | ○ | manual+wire OK |
| write arbitration (`locks`) | ● | ● | ○ | manual OK |
| tool-pair repair | ● | ● | ○ | CHANGELOG + WIRE |

## 3. Confirmed gaps

### 3.1 The sandbox subsystem has research docs but no user docs

`sandbox/` is a launcher binary (`main.nim`, `landlock.nim`, `policy.nim`, built
as `var/bin/niffler-sandbox`, deliberately **not** a manifest component), plus
`sdk/niffler/sandboxpolicy.nim` for versioned conversation policy. Four research
documents describe it (`SANDBOX-BASH-STATUS.md`, `SANDBOX-CONVERSATION-POLICY.md`,
`SANDBOX-IMPLEMENTATION.md`, `SANDBOX-MATRIX.md`).

`MANUAL.md` mentions **none** of:

| symbol | purpose |
|---|---|
| `NIF_BASH_SANDBOX_ROOT` | workspace root the guard grants |
| `NIF_BASH_SANDBOX_MASKS` | paths never readable through `read`/`grep` |
| `NIF_SANDBOX_BACKEND` | which enforcement backend (Landlock/bwrap) |
| `NIF_SANDBOX_ALLOW_DEGRADED` | permit running without enforcement |
| `NIF_BWRAP` | path to the bwrap binary |
| `bash_sandbox_status` | what the guard actually applied |

The existing MANUAL `sandbox` mentions (`NIF_BASH_SANDBOX_MAP`, docker image map,
`netScoped`) are a **different** feature — the hosted-benchmark container map —
so a reader following "sandbox" in the manual lands on the wrong thing. This is
also a security-shaped feature: `NIF_SANDBOX_ALLOW_DEGRADED` changes the
guarantee, and an operator currently cannot learn that from the manual.

### 3.2 Newest fleet tools are absent from the MANUAL

`fleet_notices` (0 mentions) and `fleet_instances` (0) are in the shipped tool
set but not in `MANUAL.md` or `WIRE.md`. `fleet_task_inbox` appears twice
(tool table only) with no explanation of what the inbox *is* — that it is a
local read over `fleetjob` records, that it lists completed work with its
artifact, and how a client acknowledges it.

### 3.3 `roots` (extra conversation roots) is undocumented

`feat(roots): let the human grant extra conversation roots` has no MANUAL, WIRE
or website text. A conversation's working set is now grantable at runtime, which
changes what `x-harness.workspace` and the write-arbitration lease cover.

### 3.4 The website predates the fleet and sandbox work

`website/index.html` contains **zero** occurrences of "fleet" and zero of
"sandbox"/"bwrap". Its component story is still "tools as processes plus the
config surface". Two of this release's three largest slices are invisible there.

### 3.5 Running harness is behind (not a docs issue, but it blocks testing)

The core started 2026-10-27 20:49; `processes.limits` and `mcp.limits` merged
later (#195, 2026-10-29). `config_list` therefore reports six domains
(`fetch.network`, `logfile.retention`, `lsp.warm`, `models.refresh`,
`observe.capture`, `repomap.gates`) and not the two new ones. Rebuild and
restart before testing those.

## 4. Test playbooks

### 4.1 Settings / config

```bash
# inventory — which domains exist, who owns them, is the owner alive
./var/bin/cli call config_list '{}'

# one domain in full. Verified live: keys are
#   ok, domain, title, description, owner, ownerAvailable, rev,
#   values, defaults, schema
# and logfile.retention's properties are
#   maxBytes, keep, maxFiles, scanBytes, directoryEntries
./var/bin/cli call config_get '{"domain":"logfile.retention"}'

# change one property (approval-gated); in a fresh store rev starts at 0 and
# the reply's "applies" says when the owner will honour it
./var/bin/cli call config_patch '{"domain":"logfile.retention",
  "patch":{"maxBytes": 4194304}, "expectRev": 0}'

# prove the OWNER acted, not just the store: re-read (values now non-empty)
./var/bin/cli call config_get '{"domain":"logfile.retention"}'

# compare-and-set: expectRev 0 is now stale and must be refused
./var/bin/cli call config_patch '{"domain":"logfile.retention",
  "patch":{"maxBytes": 1048576}, "expectRev": 0}'

# reset to declared defaults
./var/bin/cli call config_reset '{"domain":"logfile.retention"}'
```

Things worth deliberately trying to break: an unknown property; a read-only
property; a `humanOnly` property from a **subagent** (expect the refusal
"… is human-only: it cannot be changed from a subagent session, because the
approval would be answered by whoever delegated this task rather than by the
human who owns the setting" — it is a message, not an error code); an
unreadable lineage record (refused as unprovable, *not* treated as root);
`config_reset` with no properties (must check every writable property, not
bypass the guards); a stopped owner (must report unavailable, not defaults).

After rebuilding: `processes.limits` (`spoolCap`, `pollChunk`) and
`mcp.limits` should appear, and the bench test proves `pollChunk` on an
observable (`t_processes`).

### 4.2 Fleet

Argument names below are taken from the tool schemas in
`components/fleet/main.nim`, not from memory — `fleet_task_submit` requires
`requestId`, `content` (the goal) and `cwd`, plus exactly one target
(`name`/`identity`/`taskProfile`), and `mode` selects the flavour.

```bash
# 1. routes and hosts
./var/bin/cli call fleet_instances '{}'
./var/bin/cli call fleet_status '{"name":"<instance>"}'

# 2. submit a bounded read-only task (mode "ask": worker stops for approvals)
./var/bin/cli call fleet_task_submit '{"requestId":"t1","name":"<instance>",
  "content":"report what packages are installed","cwd":"/home/ubuntu",
  "mode":"ask"}'
./var/bin/cli call fleet_task_status '{"jobId":"<jobId>"}'
./var/bin/cli call fleet_task_receipt '{"jobId":"<jobId>"}'

# 3. the human inbox: settled work with its artifact, and the notice feed
./var/bin/cli call fleet_task_inbox '{}'
./var/bin/cli call fleet_task_inbox '{"state":"settled","limit":5}'
./var/bin/cli call fleet_notices '{"session":"<conversationId>"}'

# 4. ONE trusted-delegation decision (not a profile per assignment)
./var/bin/cli call fleet_delegation_get '{}'
./var/bin/cli call fleet_delegation_set '{"enabled":true,
  "tools":["bash","read","edit"], "roots":["/home/ubuntu/work"]}'
#   → now mode "delegate" needs no profile and omitted tools/budgets
#     take this ceiling; anything the caller names can only narrow it

# 5. F2: unattended coding task (needs a named taskProfile)
./var/bin/cli call fleet_task_submit '{"requestId":"t2","name":"<instance>",
  "content":"fix the failing test","cwd":"/home/ubuntu/work",
  "mode":"unattended","taskProfile":"coding"}'

# 6. continue a settled goal in the SAME worker conversation
./var/bin/cli call fleet_task_continue '{"jobId":"<jobId>","requestId":"t3",
  "content":"now run the full suite"}'

# 7. cancel ACTIVE remote work (reaches the remote session's stop op)
./var/bin/cli call fleet_task_cancel '{"jobId":"<jobId>"}'

# 8. lifecycle
./var/bin/cli call fleet_vm_start '{"name":"<instance>"}'
./var/bin/cli call fleet_remove '{"name":"<instance>"}'
```

Things worth deliberately trying to break: the same `requestId` twice (must be
idempotent, and an *unknown* outcome must never be replayed); naming `tools` or
`roots` on a continuation (must refuse — that needs a new conversation); a
control-plane tool in the delegation ceiling (must be refused); a pinned
workspace repinned by a later submit; `fleet_task_cancel` without `human` from
outside a session context.

## 5. Proposed order of work

1. **Rebuild + restart** so the harness matches `main` (unblocks §3.5 and the two
   new config domains).
2. **Test settings and fleet** (§4) and note what actually differs from the docs
   as written — a doc written from code is worth less than one corrected while
   using it.
3. **Write the sandbox section** (§3.1) — the largest gap, and the only one with
   a security consequence.
4. **Fill the fleet holes** (§3.2, §3.3, §4 inbox/notices prose).
5. **Update the website** (§3.4) — fleet and sandbox in the component story.
6. **Then** cut the release: version bump, freeze `[Unreleased]`, release
   pointers, translations last (per AGENTS.md).

Steps 3–5 are one PR each; each is verifiable by re-reading the manual against
the code, and step 3 wants the `sandbox` research docs as its source.
