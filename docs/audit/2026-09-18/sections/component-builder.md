# Worklist slice: component: builder

From `worklist.tsv` (28 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A516 (doc-edit)
source: `components/builder.md`

- MANUAL: `build` writes source under `<NIF_ROOT>/var/build/`, compiles to `var/bin/<name>.tmp-<pid>`, `moveFile`s it to `var/bin/<name>` (`main.nim:74-75`, `86-87`, `103`) and returns the path.

## A517 (doc-edit)
source: `components/builder.md`

- MANUAL: `core.spawn {name, binary}` (`core/dispatch.nim:308-346`): refuses a name that is already supervised, resolves a relative binary against the root, requires the file to exist, clamps `replicas` to 1–16, starts the child, and persists a `component` record `{name, binary(abs), policy, replicas, args, addedAt}` (verified **live**: `cli call list '{"kind":"component"}'`). **The source is not in the record** — `var/build/` is the only copy.

## A518 (doc-edit)
source: `components/builder.md`

- MANUAL: The child publishes `reg.publish` (`sdk/niffler/sdk.nim:846`, payload `regPayload` `sdk/niffler/sdk.nim:530-540`) and core inserts its tools into the catalog (`core/catalog.nim:640-680`).

## A519 (doc-edit)
source: `components/builder.md`

- MANUAL: Exposure: `build`/`info` are `onDemand`, so they never sit in a conversation's frozen direct toolset; the *new* component's own tools are direct in a new conversation and reach existing ones through `discover` + `invoke` (`sdk/niffler/sdk.nim` `info.flow`, MANUAL.md:897-899).

## A520 (doc-edit)
source: `components/builder.md`

- MANUAL: Registration is **fire-and-forget**: `announce` only publishes (`sdk/niffler/sdk.nim:541-542`) and no reply is checked, while core refuses the *entire* registration on a duplicate/missing tool name (`core/catalog.nim:654-673`). Consequence: a component whose tool name collides keeps running, prints its own `<name> v<ver> online on <url> (<N> tools)` line (`sdk/niffler/sdk.nim:847-848`), is **absent from the catalog forever**, and the only trace is core's stdout `catalog: rejecting <name> — tool '<t>' already provided by <owner>`. `spawn` still returns `ok: true`.

## A521 (doc-edit)
source: `components/builder.md`

- MANUAL: **Type.** `defines` is declared `JsonNode` (`main.nim:51`), and the SDK maps every `JsonNode` parameter to `{"type": "object"}` (`sdk/niffler/sdk.nim:920-921`) — while the handler only honours a JArray (`main.nim:89`). The schema the model plans against therefore contradicts the only shape that works. Declaring `defines: seq[string]` would publish `{"type":"array","items":{"type":"string"}}` (`sdk/niffler/sdk.nim:924-926`, and the macro already unwraps `seq` into `argStrSeq`/`argStrSeqD`) (`sdk/niffler/sdk.nim:1109-1113`). Nothing validates arguments against the schema in core, so the failure is silent, not loud.

## A522 (doc-edit)
source: `components/builder.md`

- MANUAL: **Truncated description.** The doc line breaks after `- defines:` and the continuation is indented two extra spaces (`main.nim:70-72`). The SDK's doc extractor takes `- param: text` on one line as the parameter doc and appends every other prose line to the *tool* description (`sdk/niffler/sdk.nim:939-958`), so the parameter doc stops at "…e.g. `["ssl"] for`" and the sentence's tail — "HTTPS-capable httpclient — appended as -d:NAME (validated; Nim identifier characters only)" — lands at the end of the tool description, after "…bare semantic names (read, edit, bash, …)." The fix is one line of doc comment.

## A523 (doc-edit)
source: `components/builder.md`

- MANUAL: **The result shape.** No `ok`/`binary`/`log`/`error`, no "compile errors are

## A524 (doc-edit)
source: `components/builder.md`

- MANUAL: **Multi-file components beyond Go.** `files` is documented only as "adds

## A525 (doc-edit)
source: `components/builder.md`

- MANUAL: **The TypeScript flow.** Only two facts exist: `**NIF_NPM_REGISTRY**` (MANUAL.md:401)

## A526 (doc-edit)
source: `components/builder.md`

- MANUAL: **The lock, and what `make clean` does to agent-built components.** MANUAL.md:482

## A527 (doc-edit)
source: `components/builder.md`

- MANUAL: **The failure modes of self-extension.** A tool-name collision makes core

## A528 (doc-edit)
source: `components/builder.md`

- MANUAL: **The limits.** Name rules (the reason `../escape` is refused), the

## A536 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "`builder`, `plugins`, `skills`, `fetch`, `models`, `provider`, the dedicated file tools, and observation/logging do not start."
- CODE: `core/niffler.nim:25` (`minimalComponents = ["store", "bash", "llm"]`), `core/niffler.nim:473` (every manifest entry outside that list is skipped)
- FIX: none [verified] — in `--minimal` `builder` (and its tool schemas) really is left out; the records of previously spawned components stay in the store.

## A537 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: absent (the result shape of `build` anywhere in the MANUAL)
- CODE: `main.nim:104-105`, `146-147`, `196-198` (success `{ok, lang, name, binary, log}`), `main.nim:100-102`, `142-144`, `176-182` (failure `{ok:false, lang, error: <compiler output tail>}`, 2000 bytes), `sdk/niffler/procutil.nim:181-189` (UTF-8-safe tail with a `…` marker)
- FIX: add [missing] — "`build` returns `{ok, lang, name, binary, log}` on success and `{ok: false, lang, error}` on failure, where `error` is the compiler's own output tail (2000 bytes) — check the return instead of assuming `var/bin/<name>` exists. There is no exit code in the result, so a build killed at its internal budget (Nim 120 s, Go/`npm install` 300 s, `tsc` 120 s) looks like a compile error with whatever output it had produced."

## A539 (code-bug?)
source: `components/builder.md`

- MANUAL: MANUAL: absent (the schema the model actually plans against — the MANUAL names the arguments, never their published types)
- CODE: `main.nim:50-51` (`defines: JsonNode`), `sdk/niffler/sdk.nim:920-921` (`JsonNode` → `"type": "object"`), `main.nim:89` (handler requires `JArray`), `main.nim:70-72` (the doc comment's wrapped `- defines:` line), `sdk/niffler/sdk.nim:939-958` (doc extractor: only single-line `- param:` lines are parameter docs)
- FIX: code bug [code-bug?] — make the declaration match reality: `defines: seq[string]` (publishes `array` of `string`) and keep the `- defines:` doc line unbroken. Today the LLM is told "Optional array of Nim compile defines, e.g. `["ssl"] for`" in a field typed `object`, with the rest of the sentence glued to the end of the tool description.

## A540 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: absent (what a cancelled turn does to a build already running)
- CODE: `main.nim:49` (no `sessionId`), `docs/WIRE.md` "Cancellation" (components opt in by subscribing `cancel.<component>` and matching the injected `__session.session`), `components/bash/main.nim:55-94` (the reference implementation: kill the process group, exit 130), `core/dispatch.nim:1403-1421` (core publishes the cancel and waits briefly for a partial reply)
- FIX: add [missing] — "a cancelled turn does not stop a build: core publishes `cancel.build`, the builder has no subscription and no `x-harness.sessionId`, so the compiler keeps running to its own deadline and only the reply is abandoned. Wait for the tool result before cancelling, or kill the component (`core.kill {name: "builder"}`)."

## A547 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "Repository build writes are serialized, while agent-built test components use sandbox-local Nim caches."
- CODE: `Makefile:67-68` (`BUILD_LOCK`/`TEST_LOCK`), `tests/t_builder.nim:28-34` (the sandbox gets its own `config.nims` + `nimcache`), `components/builder/main.nim` (no lock)
- FIX: update [delta] — scope the claim: "Repository build writes (`make build`, `make clean`) are serialized by `scripts/with-build-lock.sh`; a runtime `builder.build` is not part of that lock, and agent-built components compile with the checkout's `var/nimcache/var_build_<name>` unless a sandbox overrides it."

## A548 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "`NIF_TEST_NETWORK=1` runs `plugin_search` against GitHub, `skill_search` against skills.sh, and the TypeScript builder build (npm registry)."
- CODE: `tests/t_builder.nim:136-154` (the TS case is skipped with a note unless `NIF_TEST_NETWORK=1`), `main.nim:149-151`, `172-180`
- FIX: none [verified] — accurate, and it explains why a `make test` run proves nothing about the TS path: `node`/`npm` presence, the `file:` SDK wiring and the wrapper are only exercised by that opt-in.

## A549 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: absent (nothing about a component that builds and spawns but never appears in the catalog)
- CODE: `core/catalog.nim:654-673` (a duplicate/missing tool name refuses the ENTIRE registration; core prints `catalog: rejecting <name> — tool '<t>' already provided by <owner> (refused; use component-prefixed tool names)`), `sdk/niffler/sdk.nim:541-542` + `846-848` (registration is a fire-and-forget publish; the component still prints `online`), `main.nim:62-65` (the tool's own advice: prefix every tool with the component name; bare semantic names belong to shipped components)
- FIX: add [missing] — a Troubleshooting entry: "**`spawn` said ok, but the component is not in the catalog.** Its registration was refused — almost always a tool name that already exists (names are globally unique; prefix yours with the component name). The component process is alive and logs `<name> v<ver> online`; core's stdout carries the reason (`catalog: rejecting …`). Fix the tool name, rebuild, `core.kill {name}`, `core.spawn` again."

## A550 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: absent (rebuilding a component that is already running)
- CODE: `core/dispatch.nim:330-332` (spawn refuses: `component already supervised: <name>`), `core/dispatch.nim:347-356` (`kill` removes the child and drops the catalog entry but keeps the record), `main.nim:103`/`145`/`195` (the rebuild renames a fresh binary over `var/bin/<name>`)
- FIX: add [missing] — "A rebuild does **not** reach the running process (the old inode keeps executing): to pick up new code, `core.kill {name}` (record kept) and then `core.spawn {name, binary}`; `spawn` refuses while the name is supervised."

## A551 (doc-edit)
source: `components/builder.md`

- MANUAL: a component that builds, spawns and logs `online` yet never appears in the catalog (refused registration, `core/catalog.nim:654-673`);

## A552 (doc-edit)
source: `components/builder.md`

- MANUAL: a TS component whose "binary" is an absolute-path `require` into `var/build/` (`main.nim:189-191`) — copying `var/bin/<name>` elsewhere, or wiping `var/`, breaks it in a way no error message explains;

## A553 (doc-edit)
source: `components/builder.md`

- MANUAL: the 2-minute internal Nim budget against an advertised 5 (`main.nim:96-99`).

## A554 (doc-edit)
source: `components/builder.md`

- MANUAL: **`make clean` permanently orphans agent-built components** (MANUAL:355-356 is false for them): their source exists only in `var/build/`, and the store record carries no source — the next boot warns `missing binary for <name>` and nothing can restore it (`core/dispatch.nim:340-343`, `core/niffler.nim:505-507`, `main.nim:74-75`).

## A555 (doc-edit)
source: `components/builder.md`

- MANUAL: **The `defines` parameter is broken on the wire**: typed `object` (from `JsonNode`) while only a JSON array works, and its description is cut mid-sentence with the rest glued to the tool description (`main.nim:51`, `70-72`, `89`; `sdk/niffler/sdk.nim:920-921`, `939-958`).

## A556 (doc-edit)
source: `components/builder.md`

- MANUAL: **A refused registration is invisible** — a colliding tool name makes core drop the whole registration while the component keeps running and `spawn` returned `ok` (`core/catalog.nim:654-673`, `sdk/niffler/sdk.nim:541-542`). This is the one failure a self-extending agent hits and cannot diagnose from its own tool output.

## A557 (doc-edit)
source: `components/builder.md`

- MANUAL: **The advertised 300 s build timeout is not the real one**: the Nim compile uses `runCmd`'s 120 000 ms default (`main.nim:96-99`, `sdk/niffler/procutil.nim:70`), and neither failure shape carries an exit code, so a timeout reads as a compile error.

