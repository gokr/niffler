# Docs audit — `components/cli/` (Nim, 279 LOC, one file)

Read-only audit of the current tree (`docs/MANUAL.md` at **3082 lines**), 2026-09-19.
No component source and no MANUAL file was edited; the reports are the deliverable.
Every claim cites `file:line`; claims marked **verified live** were reproduced against a
running bus (see §5).

`docs/MANUAL.md` is being edited concurrently by the consolidation pass, so the line
numbers below are a snapshot of the 3072-line revision — the **quotes** are the durable
anchor (that is also what `normalize.py` re-anchors on).

## 1. What it offers

A **standalone bus client for scripts and CI** — the non-interactive twin of the tty admin
shell, and the only one of the three terminal clients that is a *pure client*:

- It reads core's **accepted** catalog (`catalog {op: components}`, `main.nim:34-72`) and
  dispatches tool calls request/reply to `svc.<component>.call` (`main.nim:112-114`). It
  touches `svc.core.call` exactly once per command (that catalog read), so it is not a bus
  service, registers nothing, and has no tools of its own (`main.nim:1-15`).
- **It never announces itself**: `grep -n publish components/cli/main.nim` finds only a
  comment (`:83`), no `reg.publish` — unlike `console`
  (`components/console/main.nim:74`) and `dialog`
  (`components/dialog/dialog.sh:103`). Consequence: `cli` never appears in
  `catalog {op: components}` and `cli wait cli` can never succeed.
- **It is in no manifest**: `manifest.yaml` lists 25 components (`store`, `bash`,
  `builder`, `plugins`, `skills`, `systemprompt`, `recall`, `compaction`, `fetch`,
  `models`, `provider`, `llm`, `grep`, `mcp`, `edit`, `lsp`, `repomap`, `processes`,
  `git`, `observe`, `logfile`, `hooks`, `agent`, `expert`, `fabric`) — `cli` is not among
  them. Core therefore never spawns it, no `core.spawn` record exists for it, and there is
  nothing to restore at boot: a user runs `./var/bin/cli` by hand (that is what "Manifest
  `—`" means in the shipped-components table). It *is* built by `make build`
  (`Makefile:256-257`, `Makefile:308-310`, `nimble:all_internal`) and linked onto `PATH` as
  `niffler-cli` by `make install` (`scripts/install.sh:101,110,84`).
- **It requires a live core even to call a component**: the tool→component mapping comes
  only from core's catalog (`main.nim:103-124`, `:149`). **Verified live**: on an isolated
  bus carrying only the `bash` component, `cli call bash …` printed
  `cli: no component provides tool 'bash' (within 60s)` and `cli catalog` printed
  `cli: cannot read core catalog — is a harness up?` (exit 1).
- **Its calls bypass core completely** — no approval gate, no session/workspace injection,
  no `x-harness.timeoutMs`, no `sessionId` cancellation, no hidden/onDemand filtering. Its
  own header notes it has "no attach-time identity check (it trusts the discovery file)"
  (`main.nim:52-56`), which is why `catalog` prints the answering harness's
  `root`/`gitHash`.
- `tests/t_cli.nim` (163 lines; boots core headless) and `tests/t_cli_catalog.nim` (136)
  pin the contract; `Makefile:521-523` (`test-cli`) runs both. `tests/cli.nim` is an
  older, unreferenced duplicate of the same script.

## 2. Commands (no tools — the four subcommands are `argv`, not schema)

| Command | Where | Purpose / contract | Exit |
|---|---|---|---|
| `catalog` | `main.nim:126-138` | one line per accepted component: `name: tool, tool` (or `name: (no tools)`); a leading `# harness: <root> @ <gitHash>` line when core carries a root; **unsorted** (Nim `Table` iteration, `:134`) | 0; 1 if core does not answer or the catalog is empty |
| `call <tool> '<json args>'` | `main.nim:140-158` | wait up to **60 s** for core to accept the tool (`:149`), then request `svc.<component>.call` and print the result JSON verbatim (`:153-155`) | 0; 1 (unknown tool, component error, timeout); 2 (bad JSON args) |
| `wait <component> [<secs>]` | `main.nim:261-268` | poll the authoritative snapshot until the *component* name is accepted; default **60 s**; `0` means one bounded snapshot read, not a cache lookup (`:74-95`) | 0 / 1 |
| `install <repo>[@<ref>]` | `main.nim:160-211` | wait ≤60 s for `plugins` (`:170`), `plugin_install` with a **600 s** budget (`:175-176`), then verify each returned component: `interactive` → built; else `spawned` + registered within 60 s (`:180-207`); prints `INSTALL OK` / `INSTALL FAILED` | 0 / 1 |
| `--timeout <secs>` / `-t` | `main.nim:223,231-236` | the *cli's own* reply budget for `call` (default 30 000 ms). **Only the `--timeout=N` form parses** — see D1 | 2 on a bad value |

**No `x-harness` flags exist**: the cli declares no tool schema at all, so nothing about
approval/onDemand/hidden/timeout can apply to it. The relevant fact is the reverse — because
it dispatches straight to `svc.<component>.call`, the *target* tool's
`x-harness.approval: "always"` is never consulted (D3/D4).

## 3. Configuration

Two `NIF_*` variables, both read through the SDK; none of its own:

| Var | Effect here | Where |
|---|---|---|
| `NIF_NATS_URL` | bus address; wins over everything | `sdk/subjects.nim:25-26`, called from `main.nim:28-32` |
| `NIF_ROOT` | selects the harness root for (a) `var/nats-url` discovery and (b) `.env`; unset → **the binary's own clone** (`getAppDir().parentDir().parentDir()`), never the cwd | `sdk/subjects.nim:8-14`, `:19-32`; the `.env` half via `main.nim:244` (`rootDir()` = `NIF_ROOT` else `"."`) |

Resolution order, both halves verified live:

```
NIF_NATS_URL  →  <harness root>/var/nats-url  →  nats://127.0.0.1:4222
.env          ←  cwd/.env and $NIF_ROOT/.env (existing env always wins)      main.nim:244
```

- Clone-relative discovery: invoked through a symlink from `/` with nothing set,
  `cli catalog` still answered `# harness: /home/gokr/git/nifflerprod @ 6bc4f6d`.
- `.env` from the **cwd**: with `/tmp/cli-envtest/.env` holding
  `NIF_NATS_URL=nats://127.0.0.1:1`, `cli catalog` printed
  `cli: cannot connect to nats://127.0.0.1:1 — is the harness running?` (exit 1) — the cwd
  `.env` overrode the clone's discovery file. That asymmetry (env file from the cwd,
  discovery file from the clone) is documented for no client.
- `dotenv` refuses symlinked/multiply-linked/oversized `.env` files
  (`sdk/dotenv.nim:28-44`) — irrelevant to the cli but it is the loader in play.

## 4. How the MANUAL covers it (now)

**Shipped-components row** — `## Layout of a running system` (`### Shipped components`), MANUAL line 80:

> | `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |

Correct, including the empty Manifest cell. The table never explains what `—` means for a
user (nothing spawns it; you start it yourself) — the same gap exists for `console`, while
the section text at MANUAL:604-605 spells the rule out for `console` only ("not in the
manifest — start it yourself in a second terminal").

**The scripting section** — `## The bus in one screen`, MANUAL:614-632:

> **The cli component** (`./var/bin/cli`) drives the same bus from a
> script or pipeline — non-interactive, CI-friendly (exit 0 on success);
> it is the scripting face, the tty admin shell is the interactive one:
>
> ```bash
> ./var/bin/cli catalog                        # components + their tools
> ./var/bin/cli wait <component> [secs]        # wait for registration
> ./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
> ./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
> ```
>
> `cli install` clones, builds via the builder, spawns every component and
> waits for each service name to appear in core's accepted catalog; interactive
> components are verified by their build. CLI catalog and tool lookup also use core's
> authoritative directory, never raw registration broadcasts. A plugin repo's CI
> proves a package by running the harness itself through this one command. `file://` repo URLs
> install from local git repos (hermetic tests, mirrors). Name-based verification
> does not distinguish an existing accepted component from a newly started
> process with the same name.

Accurate as far as it goes: the four commands, core-authoritative lookup, the `INSTALL OK`
contract, `file://` repos and the name-based-verification caveat all match
`main.nim:160-211`. Missing: the `--timeout` flag, the `# harness:` line, exit codes 1/2,
the 60 s/600 s budgets, and the bypass (D3/D4).

**Other mentions (all checked):**

- `MANUAL:70` — "Session-less callers (`cli`, other components) are not tracked and skip the
  gate" (`edit`'s staleness gate) — correct (`main.nim:112-114` sends no session context).
- `MANUAL:1705-1706` — "Direct callers (CLI scripts) get `""` — they cannot spoof a
  session" (MCP `x-harness.sessionId`) — correct, and the closest the MANUAL comes to
  stating the bypass.
- `MANUAL:2179` — "Components and `cli call` address them directly by name." — correct.
- `MANUAL:2883` — "Direct bus callers (cli, tests, core) keep full access." — correct.
- `MANUAL:1582` — "the internal `process_start` goes straight over NATS and never passes
  core's approval gate, while a direct `process_start` (e.g. from `cli`) is gated" —
  **wrong**: `cli` *is* a direct bus caller; see D3.
- `make install`'s PATH block (MANUAL:3025) lists `niffler-cli` — matches
  `scripts/install.sh:110`.
- `## Testing` (MANUAL:2921) no longer hand-lists targets ("`make help` lists every
  target"); `test-cli` exists (`Makefile:521-523`) — nothing to fix.
- `## Environment variables` documents `NIF_NATS_URL` and `NIF_ROOT`; there is **no**
  cli-specific variable to document.

## 5. DELTA list

- **D1 — `--timeout` is unusable in the form the cli advertises (code bug).** `usage()`
  prints `cli [--timeout <secs>] …` (`main.nim:214`) and the flag has no MANUAL entry;
  Nim's `parseopt` yields `--timeout 5` as `(cmdLongOption "timeout")` plus a separate
  `(cmdArgument "5")`, so `p.val` is empty and `parseInt` throws → `cli: bad --timeout
  value:` + exit 2. **Verified live**: `./var/bin/cli --timeout 5 wait plugins 0` →
  `cli: bad --timeout value:` (exit 2); `./var/bin/cli --timeout=5 wait plugins 0` →
  `cli: plugins registered` (exit 0); `-t 5` fails like the long form.
- **D2 — a non-numeric `wait` budget crashes with a stack trace (code bug).**
  `main.nim:263` `parseInt(positional[2])` is unguarded (unlike `--timeout`, caught at
  `:232-236`). **Verified live**: `cli wait plugins abc` printed the Nim trace
  `components/cli/main.nim(279) main … Error: unhandled exception: invalid integer: abc
  [ValueError]`, exit 1. Related: `cli --help`/`-h` prints `cli: unknown option --help`
  (exit 2) — there is no help flag, only `usage()` on a missing command.
- **D3 — MANUAL:1582 is wrong about the cli being gated (verified live, isolated).**
  The approval gate lives only in core's dispatch (`core/dispatch.nim:1630-1633`, the single
  `x-harness.approval` site), while `cli` publishes to `svc.<component>.call`
  (`main.nim:112-114`). Sandbox proof (`--minimal` core + `store`/`bash`/`llm` in a
  throwaway `NIF_ROOT`, `NIF_AUTO_APPROVE` unset): the core-mediated control call returned
  `{"kind":"error","error":{"code":"boom","message":"approval denied for spawn"}}`, and
  moments later `cli call bash '{"command":"echo BYPASS-PROOF; whoami"}'` **executed**,
  returning `{"exit_code":0,…,"text":"(exit 0)\nBYPASS-PROOF\ngokr\n"}` — `bash` carries
  `approval: "always"` (`components/bash/main.nim:130`).
- **D4 — the bypass is nowhere stated as such.** The MANUAL calls the cli a "direct bus
  caller" twice, but only about unrelated flags (`:1695`, `:2873`); it never says the cli
  skips the approval gate, the workspace/session injection, the tool's own
  `x-harness.timeoutMs` and the hidden/onDemand filter (it can call `del`, `chat`,
  `spawn` — `cli catalog` shows every accepted tool, `main.nim:34-72`). A reader can
  reasonably assume `cli call` is the same path as `invoke`.
- **D5 — `cli call` uses its own 30 s budget, not the tool's.** `main.nim:223` defaults
  `timeoutMs = 30_000`; `main.nim:114` passes it straight to the request. Tools whose
  schemas allow minutes (`builder.build` 300 s, `plugin_install` 600 s, `agent_run`
  900 s) therefore fail from the cli unless `--timeout=N` is raised — and per D1 the
  working spelling is `--timeout=N`.
- **D6 — `catalog`'s output contract is undocumented**: leading `# harness: <root> @
  <hash>`, unordered lines, `(no tools)` for zero-tool components, exit 1 on an empty or
  unreachable catalog (`main.nim:126-138`; **verified live**).
- **D7 — `cli` never registers**, so it is invisible in `catalog` and `cli wait cli` can
  never succeed; neither fact is in the MANUAL (the `console`/`dialog` rows make the
  "not in the manifest" point but never the registration one).
- **D8 — budgets and exit codes are unstated**: `wait` defaults to 60 s and `call` waits up
  to 60 s for core acceptance before failing (`main.nim:149`, `:263`); exit codes are 0/1/2
  with 2 reserved for usage errors (`:146`, `:236`, `:239`, `:242`), while the MANUAL only
  promises "exit 0 on success".
- **D9 — the `.env`-from-cwd / `var/nats-url`-from-clone asymmetry is undocumented** (same
  gap for `console`): `main.nim:244-245`, `sdk/subjects.nim:8-32`; both halves verified
  live (§3).
- **D10 — `install`'s verifications are documented, its timings are not** (60 s for
  `plugins` to register, 600 s for `plugin_install`, 60 s per spawned component):
  `main.nim:170,176,201`.
- Verified, no change needed: MANUAL:80 (row + `—`), MANUAL:70, MANUAL:1705, MANUAL:2179,
  MANUAL:2883, the `cli install` prose (MANUAL:625-632), `make install`'s `niffler-cli`,
  and the `## Testing` pointer to `make help`.

## 6. Findings — row format (`normalize.py`)

Row legend: rows are grouped under the **exact current MANUAL heading**; the class is the
trailing `[class]` tag (`FIX: fix: none` = `verified`, `trim …` = `trim`, "code bug" in the FIX
text = `code-bug?`, which the parser detects; `wrong`/`missing` need the tag because a
`components/*.md` report keeps the parser's `group` at `component: cli`). **Every group heading below is one of the current MANUAL's `## ` headings, verbatim**; `FIX: fix: none` is the literal token `normalize.py` classifies as `verified`. `FIX:` wording is
the text I propose to insert/replace, verbatim.

## Layout of a running system

- MANUAL: "| `cli` | Nim | — | on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`) |" | CODE: components/cli/main.nim:1-15 (no `reg.publish` in the file at all); manifest.yaml (no `cli` entry); Makefile:256-257, 308-310; scripts/install.sh:110 | FIX: fix: none — the row is right, including the empty Manifest cell [verified]
- MANUAL: "on-demand bus driver for scripts/CI (`catalog`/`wait`/`call`/`install`)" | CODE: components/cli/main.nim:76-95 (only the catalog read; no `reg.publish` anyway) | FIX: add "(`cli` is a pure client — it never publishes `reg.publish`, so it never shows up in `catalog` and `cli wait cli` can never succeed)" [missing]
- MANUAL: "the inventory is the [Shipped components](#shipped-components) table below, which is the part that has to stay current" | CODE: manifest.yaml (25 entries), Makefile:308-310 (`cli`, `console`, `dialog` built but not spawned) | FIX: fix: none — keeping `cli`/`console`/`dialog` out of the manifest and listing them as `—` is correct [verified]

## The bus in one screen

- MANUAL: "**The cli component** (`./var/bin/cli`) drives the same bus from a script or pipeline — non-interactive, CI-friendly (exit 0 on success); it is the scripting face, the tty admin shell is the interactive one:" | CODE: components/cli/main.nim:103-124 (dispatch target is `svc.<component>.call`), core/dispatch.nim:1630-1633 (the only approval site) | FIX: add "Every command is a plain bus client: `cli` never goes through `svc.core.call`, so its calls bypass the approval gate, the workspace/session injection, a tool's `x-harness.timeoutMs` and the hidden/on-demand filter — `cli call del …` and `cli call chat …` work. It is an operator tool: give it the trust you give the shell you started the harness from." [missing]
- MANUAL: "non-interactive, CI-friendly (exit 0 on success);" | CODE: components/cli/main.nim:146, 236, 239, 242 (exit 2 = usage or bad JSON), :126-138, :151-158 (exit 1 = failure) | FIX: update to "non-interactive, CI-friendly (exit 0 on success, 1 on failure, 2 on usage errors or bad JSON)" [doc-edit]
- MANUAL: "./var/bin/cli catalog                        # components + their tools" | CODE: components/cli/main.nim:126-138 | FIX: add "`catalog` prints a leading `# harness: <root> @ <gitHash>` line naming which clone's core answered, then one `component: tool, tool` line per component (unordered); it exits 1 when core does not answer or the catalog is empty." [doc-edit]
- MANUAL: "./var/bin/cli wait <component> [secs]        # wait for registration" | CODE: components/cli/main.nim:261-268 (`secs` defaults to 60), :74-95 (each poll is a bounded snapshot read; `0` = one read) | FIX: update to "`wait <component> [secs]` polls core's accepted catalog (default 60 s; `0` performs a single read)" [doc-edit]
- MANUAL: "./var/bin/cli call <tool> '<json args>'      # dispatch, print the result" | CODE: components/cli/main.nim:140-158 (waits ≤60 s for acceptance, then its own 30 s reply budget), :223, :231-236 | FIX: add "`call` first waits up to 60 s for core to have accepted the tool, then waits `--timeout=<secs>` (default 30 s) for the reply — the cli's own budget, not the tool's `x-harness.timeoutMs`, so extend it for slow tools (`--timeout=600 call build …`)." [doc-edit]
- MANUAL: "./var/bin/cli call <tool> '<json args>'      # dispatch, print the result" | CODE: components/cli/main.nim:220-241 (Nim `parseopt` does not consume the next argument, so `p.val` is empty for `--timeout 5`) | FIX: code bug — accept the space-separated form (`--timeout 5`) or refuse it with a message pointing at `--timeout=<secs>`; the usage string `cli [--timeout <secs>]` promises the broken one [code-bug?]
- MANUAL: "./var/bin/cli wait <component> [secs]        # wait for registration" | CODE: components/cli/main.nim:263 (`parseInt(positional[2])`, unguarded — the `--timeout` path at :232-236 is guarded) | FIX: code bug — guard the parse and exit 2 with the usage block, as the option path does [code-bug?]
- MANUAL: "`cli install` clones, builds via the builder, spawns every component and waits for each service name to appear in core's accepted catalog; interactive components are verified by their build." | CODE: components/cli/main.nim:160-211 (60 s wait for `plugins`, 600 s `plugin_install`, 60 s per spawned component, `INSTALL OK`/`INSTALL FAILED`) | FIX: fix: none — the prose matches the code; only the three budgets are unstated [verified]
- MANUAL: "CLI catalog and tool lookup also use core's authoritative directory, never raw registration broadcasts." | CODE: components/cli/main.nim:34-72 (both indexes replaced on every read), :149 (`call` refuses a tool core has not accepted) | FIX: fix: none — verified, and it is why a component core rejected is unreachable through `cli` even while it answers on the bus [verified]

## Approvals

- MANUAL: "Tools whose schema carries `x-harness.approval: "always"` — currently `bash`, `build` (the `builder` component), core's `spawn`, `kill` and `remove`," | CODE: core/dispatch.nim:1630-1633 (the only gate), components/cli/main.nim:112-114 (the cli never enters core's dispatch) | FIX: add "The gate sits in core's dispatch, so it protects core-mediated callers only (the model, and anything reached through `svc.core.call`). A bus client — `./var/bin/cli call bash …`, `dialog`, a test calling `svc.<component>.call` directly — runs an `approval: "always"` tool unasked; treat such a component as the trust level of the shell that started the harness." [missing]

## Background processes (`processes`)

- MANUAL: "the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` (e.g. from `cli`) is gated" | CODE: components/cli/main.nim:112-114 (target `svc.processes.call`), core/dispatch.nim:1630-1633 (gate location), components/processes/main.nim:498-521 (schemas only, no gate) | FIX: update to "the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` issued by a core-mediated caller (the model, or a tool reached through `svc.core.call`) is gated. A bus client like `cli` addresses `svc.processes.call` directly and is not gated at all — verified: with `NIF_AUTO_APPROVE` unset, `cli call bash '{\"command\": \"echo x\"}'` executes while the same harness denies a core-mediated `spawn`" [wrong]

## External MCP servers (`mcp`)

- MANUAL: "they cannot spoof a session, and unattributed calls are only bounded by `timeoutMs`." | CODE: components/cli/main.nim:103-124 (no `__session`, no `sessionId`, no `x-harness.timeoutMs` applied) | FIX: fix: none — verified; this sentence is the best existing hint of the bypass and D4's addition should reference it [verified]

## The store

- MANUAL: "Direct bus callers (cli, tests, core) keep full access." | CODE: components/cli/main.nim:112-114 (direct `svc.store.call`), components/store-sqlite/main.go:498 (`del` hidden from the LLM) | FIX: fix: none — verified [verified]

## Model catalog (`models`)

- MANUAL: "Components and `cli call` address them directly by name." | CODE: components/cli/main.nim:107-114 (the index is built from every accepted tool, onDemand or not) | FIX: fix: none — verified; the same mechanism reaches `hidden` tools, which is D4's missing sentence [verified]

## Testing

- MANUAL: "make test-bash      # ... or just one — `make help` lists every target" | CODE: Makefile:521-523 (`test-cli` → `t_cli` + `t_cli_catalog`), tests/t_cli.nim, tests/t_cli_catalog.nim | FIX: fix: none — verified; the hand-list is gone and the target exists [verified]

## 7. Not user-facing

- `refreshCatalog`, `waitForRegistration`, `waitForComponent`, `waitForTool`, `callTool`
  (`main.nim:34-124`) are internals; the MANUAL should never name them.
- `servingRoot`/`servingHash` (`main.nim:25-26`, `:52-56`) exist only for the `catalog`
  header line — worth the one sentence in D6, not a section.
- `install` splits `<repo>[@<ref>]` with `rfind('@') > 0` (`main.nim:161-168`), which
  mis-splits an `ssh://user@host/…` URL — no MANUAL surface (document
  `<repo>[@<ref>]` only, as today); a curiosity for the code, not docs.
- `tests/cli.nim` (legacy, not referenced by the Makefile) duplicates `t_cli.nim`; not a
  docs matter.
