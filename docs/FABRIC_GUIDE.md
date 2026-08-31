# Fabric — a user's guide

This is the *user's* guide: what Fabric is for, how to ask Niffler for it,
and what a run looks like from your side of the conversation. For the
design and threat model see [research/FABRIC.md](research/FABRIC.md); for
the roadmap see [FABRIC_NEXT.md](FABRIC_NEXT.md).

## What Fabric is

`fabric` is one tool with one unusual property: instead of the model calling
tools one at a time — each result landing in your conversation — the model
writes a small Nim program that does the legwork itself. The program runs in
a disposable guest process, calls Niffler tools through a bridge, and returns
**one value**. Only that value enters your chat.

```
your ask → model writes a program → one approval → program runs
        → tools are called silently → one compact result in chat
```

The point is **context economy and determinism**: intermediate results (big
grep output, per-file numbers, build logs) are computed, filtered and
distilled inside the program, and never reach the model's context — or yours.

## When Fabric wins

| Situation | Mechanism |
| --- | --- |
| One tool call, or each result changes the plan | direct tools (normal loop) |
| Known sequence of steps: fan-out, search-then-read, big data, polling | **fabric** |
| Intermediate data too big for the conversation | **fabric** |
| Edit then verify (compile/test) as one unit | **fabric** |
| Exploratory work needing judgment at every step | `agent_run` (subagent) |
| Mechanical collection **plus** a judgment call | **fabric** + `agent_run` hybrid |

## How to nudge Niffler towards Fabric

The model cannot see your intent directly — it chooses Fabric from the tool's
description, which lists exactly these triggers: *mechanical known-shape work,
sequential fan-out, search-then-read distillation, big intermediate data that
must never enter the conversation, edit-then-verify, polling loops*. Your job
is to phrase the ask so it matches a trigger. You rarely need to mention
Fabric at all — but you always can.

**Nudges that work (no Fabric mention needed):**

| What you say | Why it triggers Fabric |
| --- | --- |
| "Count TODOs per file in core/ and give me just the summary — don't dump the matches into our chat." | "don't dump into chat" = big intermediate data |
| "Check every module under components/ and report only the ones that fail to build." | sequential fan-out + aggregation |
| "Grep for `sessionContext`, then read only the functions around the hits, and summarize the pattern." | search-then-read distillation |
| "Rename `fooBar` to `fooBaz` across the repo, then run `make test` before reporting back." | edit-then-verify as one unit |
| "Wait until `make build` succeeds (check every few seconds), then tell me the last line." | polling loop |
| "Collect the timings for all three variants yourself, then have a subagent judge which one we should keep." | hybrid |

**Explicit nudges** (when you want to be sure):

> "Use a fabric program for this."
> "Do this inside one fabric program so the intermediate output stays out of context."
> "discover the fabric tool and drive this through it."

The word "fabric" plus a known-shape task is unambiguous; the model will
discover the tool and use it.

**What happens after you nudge:**

1. `fabric` is an on-demand tool — on the model's first use in a conversation
   it may cost one extra round trip (`discover` then `invoke`). That's normal.
2. You get **one approval dialog** before anything runs (see below).
3. While the program runs you may see progress lines (`logg` output) in the
   activity stream — not in the chat.
4. The chat receives exactly one tool result: the program's final value.

## What the approval looks like

Because a program can do a lot, the approval shows a **manifest**, not a
truncated argument blob:

- a **digest** of the program,
- the **full source**, readable at the path shown
  (`var/approval-sources/<digest>.nim`),
- the **selected tools** (when the model pins them) and the **budgets**
  (call count, time).

If you click "always allow", that decision is stored **per digest**: the same
program runs freely again, but a *different* program asks again. A blanket
"approve everything called fabric" is deliberately impossible.

You can also write the program yourself (or paste one from below) and ask the
model to run it verbatim — then you are the author and already know what you
approved.

## A tour of examples

You never write these — the model does, from your ask. They're here so you
know what to expect, and so you can paste one yourself if you want exact
control. All examples use **typed mode** (`tools: [...]`), which is what the
model will usually produce; the raw `callTool` fallback is described after.

### 1. Search-then-distill

Ask: *"Grep for `ensureRunner` in core/ and summarize where it's defined and
called — don't put the matches in our chat."*

The model calls fabric with `tools: ["grep", "read"]` and roughly:

```nim
import fabricguest
import std/strutils   # allowed in guests; std/os, std/net etc. are lint-banned

# typed wrappers: arguments are compile-checked against the pinned schema
let hits = tools.grep(pattern = stringArg("symbol"), path = "core",
                      glob = "*.nim", max_results = 50)

# inspect results as JSON inside the program — the model only
# sees what `finish` returns
var files: seq[string] = @[]
for line in hits{"output"}.getStr().splitLines():
  let path = line.split(':')[0]
  if path.len > 0 and path notin files: files.add(path)

logg("found " & $files.len & " files")

finish($(%*{"files": files, "matchCount": hits{"output"}.getStr().len}))
```

What enters the chat: a few file names and a count — not 50 grep lines.

### 2. Fan-out and aggregate

Ask: *"Run `wc -l` over every directory in components/ and give me a per-directory
table."*

```nim
import fabricguest

var parts = %*[]
for d in @["core", "components", "sdk", "tests"]:
  let r = tools.bash(
    command = "find " & d & " -name '*.nim' | xargs wc -l | tail -1")
  logg("counted " & d)
  parts.add(%*{"dir": d, "result": r})

finish($(%*{"count": 4, "dirs": parts}))
```

N tool calls, one turn, one result. The model never sees the intermediate
`wc` output.

### 3. Big data that must never enter the conversation

Ask: *"Find the slowest tests in var/logs — just the top 3 names."*

The program greps logs, sorts, and returns three strings. Whatever the log
volume, the chat receives one line. This is Fabric's core value: the data
volume is unbounded, the answer is small.

### 4. Poll until ready

Ask: *"Wait until the build finishes, then report the last build line."*

```nim
import fabricguest

# guests may not import std/os (lint), so waiting is just a bash sleep
var attempt = 0
var done = false
while not done and attempt < 30:
  discard tools.bash(command = "sleep 2")
  attempt += 1
  let r = tools.bash(command = "make build 2>&1 | tail -1")
  if r{"exit_code"}.getInt(0) == 0:
    done = true
  else:
    logg("attempt " & $attempt & " still building")

finish($(%*{"done": done, "attempts": attempt}))
```

The chat sees one result after (in this case up to) a minute of silent
polling — not thirty round trips.

### 5. Edit-then-verify in one program

Ask: *"Replace all `fooBar` with `fooBaz` in core/niffler.nim and run the
test suite; only report if something breaks."*

```nim
import fabricguest

let edit = tools.edit(path = "core/niffler.nim", edits = %*[
  {"old_string": "fooBar", "new_string": "fooBaz", "replace_all": true}])

let t = tools.bash(command = "make test-core 2>&1 | tail -5")

finish($(%*{"edit": edit, "tests": t,
            "ok": t{"exit_code"}.getInt(0) == 0}))
```

The edit and its verification are atomic from your perspective: one approval,
one result. If the tests fail, the program can even call `edit` again to
revert before finishing — the chat only learns the outcome.

### 6. Hybrid: mechanical program + judgment subagent

Ask: *"Collect the public procs in every core/*.nim, then have a subagent
decide which module is most in need of a refactor."*

```nim
import fabricguest

# mechanical part: deterministic collection
let files = tools.files(path = "core", glob = "*.nim")

# judgment part: a fresh subagent with its own context; only its
# final reply comes back into this program
let verdict = tools.agent_run(
  task = "Here are the core modules:\n" & $files &
         "\n\nRead the two largest and judge which needs refactoring most, " &
         "with reasons.",
  timeoutMs = 300000)

# the outer program's own tool lease survives the nested agent call
let stamp = tools.bash(command = "date +%s")

finish($(%*{"files": $files, "verdict": verdict{"reply"}, "at": $stamp}))
```

`agent_run` inside a Fabric program is the escape hatch for "this part needs
per-step judgment". The subagent's whole working context stays out of your
chat; you get its verdict in the program's final value.

### 7. Big payloads go through `strings`

If the model needs a large input (a file, a long prompt) it passes it via the
`strings` argument instead of pasting it into the program source, and reads it
with `stringArg("key")`:

```nim
import fabricguest
let payload = stringArg("document")   # possibly megabytes, never in chat
finish($(%*{"length": payload.len}))
```

## Typed mode: what `tools: [...]` means

When the model passes a tool list, three things change:

1. **Allowlist** — the program may only call the selected tools. Anything
   else is rejected with `tool 'x' is not selected for this Fabric run`.
2. **Catalog pinning** — the schemas of the selected tools are fingerprinted
   at start; every call re-checks the live catalog. If a component is
   replaced mid-run, the program fails with a `catalog-changed` error instead
   of calling a component that no longer matches what it was compiled for.
3. **Typed wrappers** — the guest gets `tools.<name>(...)` procedures
   generated from the pinned schemas: required arguments are Nim-typed,
   optional arguments may be omitted, results are JSON. Wrong argument types
   are **compile errors** with normal Nim diagnostics, not runtime surprises.

Raw access stays available inside the allowlist:

```nim
let r = callTool("bash", jobj(jpair("command", jesc("echo hi"))))
```

## Budgets and limits

| Limit | Default | Hard cap |
| --- | --- | --- |
| Calls (`maxCalls`) | 200 | 1 000 |
| Run time (`timeoutMs`) | 240 s | 300 s |
| Program source | — | 256 KB |
| `strings` payload | — | 128 entries / 2 MB |
| Log lines (`logg`) | — | 1 000 lines / 1 MB |
| Final result | — | 50 KB (larger spills to an artifact) |
| Artifacts | — | 100 files / 100 MB / 7-day expiry |

Every nested tool call also inherits
`min(target tool timeout, remaining program time)` — one deadline governs the
whole run, and a call cannot outlive it.

## What to expect — honestly

- **Sequential.** Tool calls inside a program run one after another; a
  fan-out over N items takes the sum of the calls. (Concurrency is a planned
  milestone, not current behavior.)
- **One approval per program** (per digest for repeat runs). Nested calls
  that need their own approval — e.g. `agent_run` — still ask.
- **Progress is not chat.** `logg()` lines surface in the activity stream
  (and `./var/bin/console`), never as messages. If nothing logs, a long
  Fabric run looks quiet until it finishes.
- **Only the final value is visible.** Everything else — compile
  diagnostics, per-call results, big intermediates — stays in the program.
  Results over 50 KB are truncated with a pointer to a mode-0600 artifact
  under `var/fabric-artifacts/`.
- **Failures are verbose where it helps.** A bad program returns real Nim
  compiler diagnostics; budget exhaustion and timeouts return actionable
  messages. All of these land in the chat as the tool result so the model can
  self-correct.
- **No mid-run cancellation.** There is no per-program cancel; a runaway
  program runs until its deadline kills it. Stopping the turn abandons the
  result, but the guest still runs out its deadline.
- **The guest is trusted, not sandboxed.** It is in `bash`'s trust class —
  approved once, by you, with its source readable at approval time. It has no
  NATS connection and no credentials; every effect crosses the audited
  bridge. But it shares your filesystem and user — that is governance, not a
  security boundary.

## After a run: where to look

| What | Where |
| --- | --- |
| Live activity (logg lines, all bus traffic) | `./var/bin/console` |
| Progress events | `ev.fabric.log` on the bus |
| Oversized results | `var/fabric-artifacts/<run>.json` |
| Approved program source | `var/approval-sources/<digest>.nim` |
| What the chat saw | the one tool result in the transcript |

## Shipped examples and tests

- Worked programs (kept executable by the test suite):
  `components/fabric/examples/` — `pipeline.nim`, `fanout.nim`, `hybrid.nim`.
- The guest API: `components/fabric/fabricguest/fabricguest.nim` (raw bridge
  + JSON helpers) and `fabricmeta.nim` (typed wrappers).
- End-to-end coverage: `tests/t_fabric.nim` (typed runs, budgets, catalog
  pinning, artifacts), `tests/t_nested.nim` (proxy admission), and
  `tests/t_approval_manifest.nim` (approval manifests).
