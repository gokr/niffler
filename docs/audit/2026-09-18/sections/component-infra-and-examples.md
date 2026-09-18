# Worklist slice: component: infra-and-examples

From `worklist.tsv` (22 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A778 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the 8 MiB payload budget, the `--max_payload` extension and the boot warning for a smaller attached bus)
- CODE: `core/niffler.nim:46-49` (`const natsMaxPayload = 8388608`), `:92-93` (bundled binary gets `--max_payload`), `:63-72,:94-95` (a PATH nats-server gets a generated `max_payload` config file instead), `:400-414` (`natsConnection_GetMaxPayload` → `core: WARNING bus at … caps messages at N bytes …`)
- FIX: add — "A request carries a whole conversation, so the bundled bus is started with `max_payload: 8388608` (8 MiB — ≈2M tokens of JSON; above that nats-server only warns). The bundled `var/bin/nats-server` takes it as an extra flag, a PATH nats-server gets it in a generated config file instead. When core attaches to a bus it did not spawn it reads the server's real cap and warns at boot if it is below 8 MiB: such a bus rejects a large reply at publish time and the caller waits out its full timeout, which looks like a component hang rather than a bus limit."

## A779 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the port handshake: `--ports_file_dir` + `.ports` polling, and the home-port-then-random attempt order)
- CODE: `core/niffler.nim:78-116`
- FIX: add (one clause, §Monitoring) — "Ports are allocated by NATS itself: core passes `--ports_file_dir <tmp>` and reads the `*.ports` file it writes (bounded 4 s wait), so concurrent harnesses cannot win a bind-close-start race. The attempt order is the home port first, then a random one."

## A784 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the test-only fixture components and stub LLMs: what they are, that they are compiled by the tests and never by `make build`, and that they are deliberately not in the manifest)
- CODE: `components/ctxtest/main.nim:1-8` ("Not in the manifest; compiled and started by the test itself"), `components/ctxtest/sink.nim:1-15` (component `ctxsink`), `tests/t_nested.nim:26-46`, `tests/mock_llm.nim:1`, `tests/mock_parallel_llm.nim:1`, `Makefile:305-313` + `niffler.nimble:26-53` (neither builds `ctxtest`)
- FIX: add — one paragraph after MANUAL:2936: "Several tests carry their own fixtures instead of a real model: `components/ctxtest/` is a **stub-LLM component** (tool `chat`, `x-harness.hidden`) that plays a scripted turn per session id, plus the contract fixtures the real tools cannot produce on demand (parameter-name mangling, a schema collision, catalog republish churn, an `effect: "read"` item for the fabric batch host, a scalar `outputSchema`, and `ctxecho` — the `sessionContext` probe that exercises the nested-call proxy and proves harness-private context is stripped). Its neighbour `components/ctxtest/sink.nim` registers a second component `ctxsink` for the same check (`sawSession`). `tests/mock_llm.nim` and `tests/mock_parallel_llm.nim` are the equivalent stand-ins for the `llm` binary. None of them is in `manifest.yaml`, none is built by `make build` — each test compiles the one it needs into its private sandbox `NIF_ROOT` and spawns it there."

## A785 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2934-2936 `Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches.`
- CODE: `tests/helpers.nim:316-329` (`newCoreSandbox`: symlinked `sdk`, generated `config.nims` with `switch("nimcache", thisDir() / "var" / "nimcache")`, copied `niffler.nimble`), `tests/t_nested.nim:31-46` (two `nim c` compiles into `sandboxBin`)
- FIX: update (optional, one clause) — "…while test-only components (and agent-built ones) are compiled with a sandbox-local `nimcache` by the test that needs them."

## A790 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2337-2339 (per-directory candidate list, no `AGENTS.local.md`)
- CODE: `components/systemprompt/main.nim:46` (`const localCandidate = "AGENTS.local.md"`), `:62-72` (`loadLocalContextFileFromDir` — additive, explicitly *not* a shadowing candidate), `:212-218` (called for **every** directory of the walk, after that directory's primary file)
- FIX: update — append to the bullet: " plus `AGENTS.local.md` additively (it never shadows the primary file, and it is loaded for every directory of the walk, not only lazily)."

## A791 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (`prompt_hint` and the prompt slots)
- CODE: `components/systemprompt/main.nim:122-158` (tool + validation), `:86-110` (`PromptHint` table, `renderPromptSlot`, deterministic sort by `source\x1fkey`), `:241-245` (the three slots rendered as `<prompt_slot name="…">`); exercised by `tests/t_systemprompt.nim:154-176`; already described for users in `website/components.html:53` and `CHANGELOG.md:337-341`
- FIX: add — a fourth bullet to `### How it works` and a sentence to the closing paragraph: "- **Prompt slots (extension seam).** Components and plugins contribute fragments through the hidden `prompt_hint {slot, content, source?, key?, mode?}` tool: named slots (`tool_usage`, `efficient_tools`, `after_instructions`) are rendered into `<prompt_slot name="…">` blocks in deterministic order (sorted by source then key); `mode: aggregate` (default) keeps every contribution and `mode: singleton` keeps only the last one registered for that slot; a slot with no contributions renders nothing. Registration is component-local state and affects only prompts composed **after** it — a frozen conversation is never rewritten. Both `systemprompt` and `prompt_hint` are `x-harness.hidden`; they never appear in an LLM toolset."

## A792 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the two caps are constants with no env knob: 16 context files, 200 000 bytes on both sides)
- CODE: `components/systemprompt/main.nim:29` (`maxPromptLen = 200_000`), `:33` (`maxFiles = 16`), `:223-224` (the loop stops at the file cap), `:268-270` (truncation marker `[systemprompt: truncated at 200000 bytes]`), `core/conversation.nim:96-98` (core's own truncation marker)
- FIX: add — one sentence after MANUAL:2322: "Two more numbers are compile-time constants with no env knob: at most 16 context files are collected, and the component truncates at 200 000 bytes itself (marker `[systemprompt: truncated at 200000 bytes]`) before core applies its own cap — a different cap means rebuilding the component."

## A793 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2307-2310 `Replacing the constitution is a normal Niffler operation: write a component that answers on the same subject, `build` it, `kill` the old one, `spawn` yours.`
- CODE: `core/catalog.nim:79-95` (`spawn` refuses a name that is already supervised), `core/dispatch.nim:347-355` (`kill` → `removeChild`, works for manifest children too), `core/niffler.nim:471-506` (boot adds every manifest component unconditionally), `core/niffler.nim:600-604` (`if alreadyManifest: continue  # shipped manifest definition wins` — a stored spawn record whose name is in `manifest.yaml` is **silently skipped** on every later boot)
- FIX: update — "Replacing the constitution is a normal Niffler operation: write a component that answers on the same subject, `build` it, `kill` the old one, `spawn` yours **under the same name** (`systemprompt` — that is the subject). Two cautions: the swap lasts only until the next boot, because a component declared in `manifest.yaml` is always restored first and a stored duplicate for the same name is skipped (`core/niffler.nim`), so a *permanent* replacement means editing `manifest.yaml`; and registering a differently-named second component that also answers `svc.systemprompt.call` does **not** replace the shipped one — both answer and the first reply wins."

## A794 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2323-2326 (agent pre-fetch)
- CODE: `components/agent/main.nim:867-885` (requests `systemprompt` with `{cwd}`, passes the answer as the session call's `systemPrompt`)
- FIX: none — verified accurate.

## A796 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2319-2321 (fallback: 500 ms probe, then 8 s when registered)
- CODE: `core/conversation.nim:90-101` (`askSystemPrompt(ct, 500, …)`, then `systemPromptTimeoutMs = 8_000` only `if ct.cat.components.hasKey("systemprompt")`, else the baked-in `systemPromptFmt`)
- FIX: none — verified accurate.

## A797 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2343-2345 (worktree shadow rule)
- CODE: `components/systemprompt/main.nim:183-204` (reads `<root>/.git` for a `gitdir:` pointer, matches `/.git/worktrees/`, shadows only the same candidate filename in the main root)
- FIX: none — verified accurate; note the rule requires `cwd` to be **inside** the harness root (`:185`), which the MANUAL does not state (optional clarification).

## A798 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (nothing in the MANUAL covers the component's own I/O — a MANUAL-neutral intra-component defect)
- CODE: `components/systemprompt/main.nim:210` (`let f = loadContextFileFromDir(dir)` — a dead call: the same directory is re-read as `primary` at `:212` and the outer `f` is shadowed by the loop variable at `:216`)
- FIX: (code) — delete line 210; it costs one redundant `readFile` per directory of the ancestor walk (and a duplicated `systemprompt: unreadable context file …` stderr line for an unreadable file), and `--hints:off` is what hides the unused-symbol warning.

## A799 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (no statement that the component's caps, candidate list, slot list and timeouts are constants with no env knob)
- CODE: `components/systemprompt/main.nim:29,33,44-46,129,164,240-245`; the only `getEnv` in the file is `:120` (`NIF_ROOT`)
- FIX: add — the cap sentence proposed above, which doubles as the "no env knob, rebuild it" statement.

## A801 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the silent skip of a manifest-shadowed spawn record)
- CODE: `core/niffler.nim:600-604` (`continue` with no echo, unlike the sibling `WARNING stored component … has missing binary` at `:620-621`)
- FIX: (code) — echo one `core: WARNING stored component <name> skipped: the manifest declares it` when a stored record is skipped, so a replaced-and-forgotten component is diagnosable instead of invisible.

## A805 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the example's other three `NIF_OPENAI_*` reads and its hardcoded `max_tokens`, and its unguarded request-body echo)
- CODE: `components/llm-openai/main.go:79-81` (required key), `:75-77` (base URL), `:70-73` (model, default `deepseek-chat`), `:91` (`max_tokens: 32768`, no knob), `:103` (300 s HTTP client), `:113-115` (`fmt.Errorf("llm HTTP %d: %s\nreq: %s", …)` — the error text embeds up to 500 bytes of the response **and the entire request body**, i.e. the whole conversation)
- FIX: add — a line in the swap paragraph: "It reads only `NIF_OPENAI_API_KEY`, `NIF_OPENAI_BASE_URL`, `NIF_OPENAI_MODEL`, `NIF_OPENAI_CONTEXT` (no `NIF_OPENAI_PROVIDER`), and always sends `max_tokens: 32768` — the one cap spelling DeepSeek honors (see [Output caps and `finish_reason`](#output-caps-and-finish_reason)); there is no knob for it." (Code, separately: drop `req: %s` from the error — `code-bug?`, see the row below.)

## A808 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1703-1713 `stdio servers inherit a fixed environment allowlist (PATH, HOME, TMPDIR, USER, SHELL, LANG, TERM) — `NIF_*` variables and secrets in the harness environment never reach them.`
- CODE: `components/mcp-bridge/transport.go:157-179` — the allowlist is **PATH, HOME, USER, LOGNAME, TMPDIR, TMP, TEMP, LANG, LC_ALL, SYSTEMROOT, SSL_CERT_FILE, SSL_CERT_DIR, XDG_CACHE_HOME, XDG_CONFIG_HOME, UV_CACHE_DIR, NPM_CONFIG_CACHE**. `SHELL` and `TERM` are **not** in it; the locale/TLS/cache variables are (`npx`/`uvx` need `XDG_*`/`UV_CACHE_DIR`/`NPM_CONFIG_CACHE`, and TLS needs the cert paths)
- FIX: update — "stdio servers inherit a fixed environment allowlist — `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`/`TMP`/`TEMP`, `LANG`/`LC_ALL`, `SYSTEMROOT`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, `XDG_CACHE_HOME`/`XDG_CONFIG_HOME`, `UV_CACHE_DIR`, `NPM_CONFIG_CACHE` — plus whatever the record's `env` adds; `SHELL` and `TERM` are *not* passed, and `NIF_*` variables and secrets in the harness environment never reach them."

## A809 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1758-1760 `The manager owns every field except `tools` — the bridge rewrites only that cache when the server drifts.`
- CODE: `components/mcp-bridge/main.go:275-313` (`persistContract` writes `record.Tools` **and** `record.Prompts`), `components/mcp/types.go:14-31` (both are caches in the record)
- FIX: update — "The manager owns every field except the caches: the bridge rewrites `tools` **and** `prompts` when the server drifts." (The `### Prompts` bullet at MANUAL:1818-1821 already says prompts are refreshed, so the two statements currently disagree.)

## A810 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (`mcp_<server>_bridge_status`, the manager's hidden helper)
- CODE: `components/mcp-bridge/operations.go:411` (registered `hidden`), `main.go:390-433` (`status`/`refresh`), called by the manager at `components/mcp/main.go:775-779`
- FIX: add (one clause in `### Shape`) — "Each bridge also registers one hidden helper, `mcp_<server>_bridge_status {op: status|refresh}` (invisible to the LLM); the manager uses it for the live state in `mcp_servers` and for `mcp_refresh`. Its `status` carries `connected`, `tools`, `prompts`, `retiring`, `activeCalls`, `lastError`, `startedAt`, `lastUsed`, `idleMs`."

## A811 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1718-1722 (`- **Drift**: … it persists the fresh listing (best effort, rev-retried) and exits 3, so the supervisor restarts it … If that refresh cannot be persisted the bridge fails closed in a *retiring* state`)
- CODE: `components/mcp-bridge/main.go:22` (`driftExitCode = 3`), `:257-272` (`acceptContract`: equal caches ⇒ no-op, else `retiring = true` then persist), `:275-313` (3 attempts, refuses a concurrently edited config, `store conflict after three attempts`), `:314-350` (the 1 s watch ticker drives the re-list), `:520-526` (exit 3 only once no call is active — `maybeRestartLocked`)
- FIX: none — verified accurate. Optional one-clause addition: "the exit is deferred until in-flight calls finish, so a drift never truncates a call."

## A815 (trim)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:1714-1717 (`- **Result size**: MCP results ≤64 KiB are returned inline; larger results are spilled to `$NIF_ROOT/var/mcp-results/result-*.json` and the tool returns a short preview plus the file path (readable with `read`, `grep` or bash) …`)
- CODE: `components/mcp-bridge/operations.go:19` (`inlineLimit = 64 * 1024`), `:140-190` (`bound`: `$NIF_ROOT/var/mcp-results/result-<rand>.json`, preview = `truncateUTF8(preview, 16*1024)` + `[Full MCP result: N bytes saved to <path>; use read to inspect the JSON file.]`, result `{text, spill: {path, bytes}, truncated: true}`), `:112-138` (`projectResult`: text parts joined, non-text parts JSON-serialized, structured content appended)
- FIX: update — "…the tool returns a machine-readable pointer instead: `{text: <first 16 KiB of the text> + a pointer line, spill: {path, bytes}, truncated: true}` (readable with `read`, `grep` or `bash`). Non-text content parts and structured content are JSON-serialized into `text` rather than dropped."

## A818 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL: absent (the bridge's repo copy of the shared config types)
- CODE: `components/mcp-bridge/types.go:1-3` (`// Config and namespace contract shared (duplicated) with mcp-bridge/types.go. Keep these files identical; the components remain independent Go modules.`)
- FIX: none — an internal invariant, correctly kept out of the MANUAL; noted so a future editor of one file knows the other must follow.

## A822 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:absent (no row names the bridge as an additional reader of `NIF_MCP_PROBE_TIMEOUT_MS`)
- CODE: `components/mcp-bridge/main.go:437-443` (the bridge's own `--probe` mode reads it too, so a hand-run probe honours it)
- FIX: add — extend the `NIF_MCP_PROBE_TIMEOUT_MS` row (MANUAL:469): "…read by both the manager (`mcp_add`/`mcp_edit`) **and** the bridge's own `--probe` mode (so a hand-run probe honours it too)."

