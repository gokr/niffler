# fabric — LLM reference

Dense reference for writing fabric guest programs. Read this once before
writing a program: call the `fabric_help` tool (empty `topic`) to get this
text; call it with an example name to get that example's source. Every
example and every code block here is compiled and executed by `t_fabric` on
every build.

A guest is a **compiled Nim program** run in a private process. It is
approved as a whole before it compiles (Nim compile-time code runs too, so
approval covers both phases — this is the same trust class as `bash`, not a
sandbox; approved code may import any std module and touch the OS directly).

## Fabric tool arguments

| arg | type | notes |
| --- | --- | --- |
| `code` | string ≤256KB | complete Nim program importing `fabricguest` |
| `name` | string | run a stored program instead (store kind `fabricprog`; save via the store's put, list via `list`) — give `code` or `name`, never both |
| `tools` | string[] ≤16 | optional allowlist: pins schemas and generates typed wrappers (`tools.bash(command = ...)`) |
| `strings` | object | key/value payloads readable via `stringArg(key)` — pass big inputs here, not inside `code` |
| `maxCalls` | int | tool-call budget, default 200, max 1000 |
| `timeoutMs` | int | run deadline, default 240000, max 300000 |

## Program skeleton (the recommended style)

```nim
import fabricguest
import std/[json, strutils, sequtils, tables, algorithm, math]
# json: JsonNode/%*/getInt/getStr · strutils: split/strip/contains/join
# sequtils: mapIt/filterIt/toSeq · tables: initTable/counts · algorithm: sorted
# Unused imports are harmless — copy this whole line. Forgetting
# sequtils/algorithm and then calling mapIt/sorted is the most common
# compile error.

let run = stringArg("run")     # "" when the key was not passed

# bash calls already start in the conversation workspace — no cd or root arg
# is needed (read payloads with stringArg/inputs, never by guessing a path)
let r = call("bash", %*{"command": "./test.sh", "timeoutMs": 60_000})
if r{"exit_code"}.getInt(-1) != 0:
  finish(%*{"ok": false, "detail": r{"text"}.getStr("")})

# compute, distill, then return ONE value — exactly once
finish(%*{"ok": true, "cells": 12})
```

Guests are native Nim: ordinary stdlib works, and direct filesystem access
via `std/os` is allowed (same trust class as bash). Prefer the tool surface
(`call("bash", ...)`, `call("read", ...)`) when the call should be
visible/auditable in the conversation; direct `std/os` is fine for bulk
local work inside the program.

## Guest API (`import fabricguest`)

| proc | returns | notes |
| --- | --- | --- |
| `call(tool, args: JsonNode): JsonNode` | the tool's **parsed** result | every call crosses approval + budget + deadline; tool-level failures (invalid args, unknown tool) raise `FabricCallError` — wrap in `try/catch` when expected; **a bash nonzero exit is a normal result, not a raise** — check `exit_code` |
| `batch(calls: openArray[FabricCall]): seq[FabricOutcome]` | ordered outcomes, failures isolated | independent calls only; auto-chunked above 16; a failing item never aborts the others; each admitted call counts against `maxCalls` |
| `toolCall(tool, args): FabricCall` | one batch item | wrap a `call` to put it in a `batch` |
| `finish(value: JsonNode)` | — | end the program; call exactly once; a normal return without it is an error |
| `log(message)` / `logg(message)` | — | progress line to the activity stream (never the conversation) |
| `stringArg(key): string` / `inputs(): JsonNode` | — | read the `strings` payload |
| `callTool(tool, argsJson: string): string` | the tool's raw **JSON string** | legacy compat; parse it before probing |

### Structured values end to end

`call` returns a `JsonNode`, so probe it directly — no `parseJson` after
`call`, no `$` before `finish`:

```nim
let out = call("bash", %*{"command": "echo hi"})
if out{"exit_code"}.getInt(0) != 0: ...        # normal result
out{"text"}.getStr("")                         # the rendered output
finish(%*{"code": out{"exit_code"}.getInt(-1)})
```

`batch` returns typed `FabricOutcome`s:

```nim
import fabricguest, std/json
var jobs: seq[FabricCall]
for f in ["a", "b", "c"]:
  jobs.add(toolCall("bash", %*{"command": "wc -l " & f}))
for o in batch(jobs):
  echo o.ok, ": ", if o.ok: o.value else: o.error   # JsonNode / string
```

## Tool result envelopes (what `call`/`tools.X` return)

| tool | success result (a JsonNode) |
| --- | --- |
| `bash` | `{"exit_code": N, "cancelled": bool, "text": "(exit N)\n<output>"}` — nonzero exit is a normal result; huge output spills (`text` names the path) |
| `edit` | `{"text": "Successfully applied N edit(s) to <path>.", "first_changed_line", "last_changed_line", "added_lines", "removed_lines"}` |
| `grep` | `{"exit_code": N, "text": "path:line:match ..."}` — exit 1 with `"[no matches]"` means zero hits, not an error |
| `read` | the file content (a JSON string result) |
| `read_many` | `{"text", "items": [{"path","content"} or {"path","error"}], "count"}` — per-item errors never abort the batch |

Do not parse the human `text` `string` to decide success («edit applied»).
Use the structured fields (`exit_code`, `added_lines`, `ok`).

## Result flow

- Only `finish()`'s value reaches the conversation; `log`/`logg` goes to the
  activity stream. Oversized values spill to `var/fabric-artifacts/<run>.json`
  (mode 0600) and the result carries `artifactPath`.
- Every `call` crosses the session proxy: approval, budgets and the run
  deadline all apply inside the program. Recompiles of an identical program
  hit the built-in `var/fabric-cache` (the `ev.fabric.phase` event carries
  `cacheHit`).
- Guests cannot spawn subagents (`agent_run` is denied inside programs —
  hybrid work calls it from the model side, see `examples/hybrid.nim`).

## Common errors → cause → fix

| error | cause | fix |
| --- | --- | --- |
| `undeclared identifier: 'call'/'finish'/'logg'` | missing `import fabricguest` | add it |
| `undeclared identifier: '%*'/'JsonNode'` | missing `import std/json` | add it — guests are native, stdlib works |
| `undeclared identifier: 'round'` / `undeclared routine: 'mapIt'` / `'sorted'` | forgot the std module | import it — copy the skeleton's `std/[json, strutils, sequtils, tables, algorithm, math]` line (unused imports are harmless) |
| `type expected` on `JArray`/`JObject` | node *kinds*, not types | use `JsonNode`; build with `%*` or `newJArray()`/`newJObject()` |
| `type mismatch` on `contains(r, "...")` | `r` is a `JsonNode` but you used string ops on it | `call` returns a node — use `r{"field"}.getStr("")`; legacy `callTool` returns a string, `parseJson` it |
| `Guest compilation failed` with a real `guest.nim(N,C) Error:` | a Nim compile error | the reported line is your line (prelude line numbers are remapped); fix it |
| `fabric takes either code or name, not both` | both present | pass exactly one |
| `maxCalls budget exceeded` | program looped past the budget | raise `maxCalls` (≤1000), `batch` independent calls, or cap the loop |
| `fabric-exec timed out` | program ran past the deadline | raise `timeoutMs` (≤300000) or cap loops/`batch` size |

## Patterns (run-tested examples)

| example | shape |
| --- | --- |
| `examples/fanout.nim` | fan out over `stringArg` dirs with per-dir `tools.bash`, aggregate, one `finish` |
| `examples/pipeline.nim` | search-then-read distillation: `tools.grep` → read a window → `finish` a digest |
| `examples/retry-loop.nim` | mechanical retry until green with a hard cap; `call` returns the node so probe `exit_code` |
| `examples/hybrid.nim` | mechanical program + `agent_run` subagent for the judgment part |
| `examples/bench-selfreview.nim` | embedded walker script via bash heredoc; big intermediate data never enters the conversation |

Decision rule: if one command does it, use bash directly. If results feed
each other or the intermediate data is large, write a program. If every step
needs fresh judgment, use `agent_run`. A single shell one-liner (a bulk
rename, a `sed` across files) stays in bash — file count alone is not a
reason to reach for fabric.
