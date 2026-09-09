# fabric — LLM reference

Dense reference for writing fabric guest programs. Read this once before
writing a program; worked, **run-tested** examples live in
`components/fabric/examples/` (every example is compiled and executed by
`t_fabric` on every build).

## Fabric tool arguments

| arg | type | notes |
| --- | --- | --- |
| `code` | string ≤256KB | complete Nim program importing `fabricguest` |
| `name` | string | run a stored program instead (store kind `fabricprog`; save via the store's `put`, list via `list`) — give `code` or `name`, never both |
| `tools` | string[] ≤16 | optional allowlist: pins schemas and generates typed wrappers (`tools.bash(command = ...)`) |
| `strings` | object | key/value payloads readable via `stringArg(key)` — pass big inputs (file lists, prompts) here, not inside `code` |
| `maxCalls` | int | tool-call budget, default 200, max 1000 |
| `timeoutMs` | int | run deadline, default 240000, max 300000 |

## Program skeleton (verified preamble)

```nim
import fabricguest
import std/[json, math, strutils, sequtils, tables, algorithm]

let data = parseJson(...)        # std/json is VM-clean
# ... drive tools, compute, distill ...
finish($result)                  # exactly once
```

`import fabricguest` is required. VM-clean std modules (`json`, `math`,
`strutils`, `sequtils`, `tables`, `algorithm`, …) import explicitly and
compile fine; **unused imports are harmless** — copy the whole preamble.
`os`, `osproc`, `net` (and friends) are lint-rejected: they would bypass
the per-call approval gate. Filesystem/process/network work goes through
`callTool("bash", ...)` / `callTool("edit", ...)`.

## Guest API (`import fabricguest`)

| proc | returns | notes |
| --- | --- | --- |
| `callTool(tool, argsJson): string` | raw tool result as a **JSON string** — parse it before probing fields | every call crosses approval + budget + deadline; tool-level failures (invalid args, unknown tool, edit validation) raise `tool 'X' failed: <msg>` — wrap in `try/catch` when expected; **a bash nonzero exit is a normal result, not a raise** — check `exit_code` |
| `batch(callsJson): string` | JSON array of per-item outcomes | independent calls only; max 16 items, 4 on the bus at once; a failing item never aborts the others |
| `finish(valueJson)` | — | end the program; call exactly once; only this value reaches the conversation |
| `logg(message)` | — | progress line to the activity stream (never the conversation) |
| `stringArg(key): string` | — | read `strings[key]` big payloads |
| `jesc/jpair/jobj/jarr/jnum/jbool` | — | build tool-argument JSON without `std/json` |

**`callTool` returns a JSON string, not a node** — parse before probing. In
pinned mode (`tools` argument) the generated typed wrapper
(`tools.bash(command = ...)`) already parses for you and returns the result
**JsonNode** (or a typed scalar when the tool declares a scalar
`outputSchema`); probe it directly:

```nim
# raw mode: parse first
let r = parseJson(callTool("bash", jobj(jpair("command", jesc("./test.sh")))))
if r{"exit_code"}.getInt(0) != 0: ...

# pinned mode: wrapper returns the parsed node
let r2 = tools.bash(command = "./test.sh")
if r2{"exit_code"}.getInt(0) != 0: ...
```

## Tool result envelopes inside a guest

What each common tool returns on success (the exact JSON your program
probes — no need to read component sources):

| tool | success result |
| --- | --- |
| `bash` | `{"exit_code": N, "cancelled": bool, "text": "(exit N)\n<output>"}` — nonzero exit is a normal result; huge output spills and `text` names the spill path |
| `edit` | `{"text": "Successfully applied N edit(s) to <path>.", "first_changed_line", "last_changed_line", "added_lines", "removed_lines"}` |
| `grep` | `{"exit_code": N, "text": "path:line:match ..."}` — exit 1 with `"[no matches]"` means zero hits, not an error |
| `read` | the file content itself (a JSON string result) |
| `read_many` | `{"text", "items": [{"path", "content"} or {"path", "error"}], "count"}` — per-item errors never abort the batch |

## Result flow

- Only `finish()`'s value reaches the conversation; `logg` output goes to
  the activity stream. Oversized values spill to
  `var/fabric-artifacts/<run>.json` (mode 0600) and the result carries
  `artifactPath`.
- Every `callTool` crosses the session proxy: approval, budgets and the
  run deadline all apply inside the program.
- Guests cannot spawn subagents (`agent_run` is denied inside programs —
  hybrid work calls it from the model side instead, see
  `examples/hybrid.nim`).

## Common errors → cause → fix

| error | cause | fix |
| --- | --- | --- |
| `undeclared identifier: 'finish'/'logg'` | forgot `import fabricguest` (must be the first line) | add it |
| `undeclared identifier: 'round'` etc. | forgot the std module (`import std/math`) | import it — VM-clean modules work |
| `type mismatch` on `contains(r, "...")` | `callTool` returned a JSON **string** | `parseJson(r)` first — or use a pinned typed wrapper, which returns the node |
| `import of 'os' is not allowed` | banned module (fs/process/network bypasses approval) | drive `callTool("bash"/"edit", ...)` |
| `guest.nim(N,M) Error: closing " expected` or garbled expression | the program was mangled in transit | re-send; check JSON escaping of nested quotes |
| `fabric takes either code or name, not both` | both arguments present | pass exactly one |
| `maxCalls budget exceeded` | program looped past the budget | raise `maxCalls` (≤1000) or `batch` independent calls |
| `fabric-exec timed out` | program ran past `timeoutMs` | raise it (≤300000) or cap loops |

## Patterns (run-tested examples)

| example | shape |
| --- | --- |
| `examples/pipeline.nim` | search-then-read distillation: `tools.grep` → read windows → finish with a digest |
| `examples/fanout.nim` | fan-out over `stringArg` dirs with per-dir `tools.bash`, aggregate, one finish |
| `examples/retry-loop.nim` | mechanical retry until green, hard cap, only the last failure surfaces |
| `examples/hybrid.nim` | mechanical program + `agent_run` subagent for the judgment part |
| `examples/bench-selfreview.nim` | embedded walker script via bash heredoc; big intermediate data never enters the conversation |

Decision rule: if one command does it, use bash directly. If results feed
each other or intermediates are big, write a program. If every step needs
fresh judgment, use `agent_run`.
