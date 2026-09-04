---
name: niffler-fabric
description: How to construct fabric programs — the guest-program shape, bridge helpers, worked patterns, budgets and pitfalls. Load when about to write or advise a fabric program (mechanical known-shape work, fan-out, search-then-distill, edit-then-verify, polling), or when choosing between the direct loop, fabric and agent_run. The expert advisory peer embeds this skill verbatim in its knowledge prefix.
---

# Fabric — constructing the program

`fabric` is one tool with one property: instead of calling tools one round at
a time, the model writes a small Nim program that drives Niffler tools
itself. The program runs in a disposable guest process, calls tools through
the bridge, and returns ONE value via `finish()`. Only that value enters the
conversation — intermediate results are computed, filtered and distilled
inside the program. The program is human-approved once, as a whole (bash's
trust class); every nested call still crosses the approval/audit gate and
counts against the budgets.

## When fabric (vs alternatives)

| Situation | Mechanism |
| --- | --- |
| One step, or each result changes the plan | direct loop |
| Known-shape fan-out; search-then-read; big intermediates | fabric |
| Edit then verify (compile/test) as one unit | fabric |
| Polling until ready | fabric |
| Exploratory work needing per-step judgment | agent_run |
| Mechanical collection + one judgment call | fabric calling agent_run |

The tool description lists the triggers: mechanical known-shape work,
sequential fan-out, search-then-read distillation, big intermediate data that
must never enter the conversation, edit-then-verify, polling loops.

## Program anatomy

```nim
import fabricguest   # the ONLY required import; provides the bridge procs
# std/strutils, std/json, std/tables … are allowed; std/os, std/net,
# std/osproc are lint-banned — guests must not touch the host directly

# Typed mode: pass tools: [...] to pin an execution allowlist + schemas,
# then call typed wrappers tools.<name>(...) — arguments compile-checked,
# results are JsonNode:
let hits = tools.grep(pattern = "symbol", path = "core", glob = "*.nim")

# Raw fallback (still inside the allowlist):
#   callTool("bash", jobj(jpair("command", jesc("echo hi"))))

# Fan-out: batch(...) runs up to 16 independent calls, 4 on the bus at
# once; a failing item lands in its slot as {"ok": false, "error": ...}
# without aborting the others:
let outcomes = parseJson(batch(jarr(jobj(...), jobj(...))))

logg("progress note")            # activity stream only, never the chat
finish($(%*{"answer": ...}))     # the ONLY thing that reaches the conversation
```

## Patterns

1. **Search-then-distill** — grep inside the program, collect just the file
   names (or a count), `finish` the distilled summary. The chat gets a few
   names and a count, not fifty grep lines.
2. **Fan-out + aggregate** — `batch()` N independent calls, fold each outcome
   into its slot of a result array, `finish` the array. Cost is roughly the
   slowest call, not the sum.
3. **Big data** — the program holds the volume (logs, large outputs); the
   chat sees only the final value. Data volume unbounded, answer small.
4. **Poll until ready** — a while loop of `tools.bash(command = "sleep 2")`
   plus the real check; `finish` the last status. Guests may not import
   std/os, so waiting is a bash sleep.
5. **Edit-then-verify** — `tools.edit(...)` then `tools.bash("make test …")`;
   if broken, edit again to revert before finishing. `finish` only the
   outcome.
6. **Hybrid** — `tools.agent_run(task = …, timeoutMs = 300000)` inside the
   program: a subagent with its own context; only its final reply comes back
   into the program. Subagents take per-job budgets (maxRounds/maxCalls/
   maxTokens); exhaustion ends the child as a failure, never a silent reply.
7. **Big payloads** — pass via the `strings` argument and read with
   `stringArg("key")` instead of pasting megabytes into the source.

## Budgets (defaults)

| Limit | Default | Hard cap |
| --- | --- | --- |
| Calls (`maxCalls`) | 200 | 1 000 |
| Run time (`timeoutMs`) | 240 s | 300 s |
| Program source | — | 256 KB |
| `strings` payload | — | 128 entries / 2 MB |
| Log lines (`logg`) | — | 1 000 lines / 1 MB |
| Final result | — | 50 KB (larger spills to a var/fabric-artifacts/ artifact) |

## Pitfalls

- Only `finish()`'s value reaches the chat — everything else is invisible to
  the model. Distill deliberately; logg progress.
- No mid-run cancellation: a runaway program runs until its deadline kills
  it. Stopping the turn abandons the result, not the guest.
- A bad program returns real Nim compiler diagnostics — self-correct from
  them.
- Typed mode pins the catalog: if a component changes mid-run the program
  fails with `catalog-changed` rather than calling the wrong thing.
- The guest is in bash's trust class (governance, not a sandbox) — never
  write programs that try to reach past the bridge.
- Plain `callTool` is sequential; only `batch(...)` overlaps independent
  calls. fabric is not a parallel-speed mechanism by itself.
