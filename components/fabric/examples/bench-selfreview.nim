## bench-selfreview.nim — self-review a bench run's cell transcripts and emit a
## distilled findings report. The big intermediate transcripts stay off the
## wire; only the compact report reaches the conversation.
##
## v2 (17-task bench, ~130 cells): per-cell read calls don't scale (2 calls
## per cell blows the default maxCalls budget), so an embedded python walker
## distills each chunk of ~16 cells in one bash call (~5KB, safely under the
## bash tool's ~12KB output cap). Per-cell derivation (classification
## included) lives in the walker verbatim; the guest keeps aggregation,
## flags and the report shape. Total calls: 2 discovery + ceil(cells/16)
## walker chunks — fits the default maxCalls for any current bench size.
##
## A bench run lives under var/bench/results/<run>/ with one cell directory
## per <harness>__<model>__<task> combo. Each cell carries:
##   transcript.json = {"sessionId", "items": [ {value:{role, content,
##                      tool_calls, usage}} ]}   (full per-round conversation)
##   result.json      = {"verdict","rounds","agentTimeS","tokens",
##                       "invalid","footprintOver","testTimeS", ...}
## Task kind comes from bench/tasks/<task>/meta.json (general | fabric |
## expert | selfextend).
##
## Per cell the walker derives: verdict, invalid/footprintOver marks, kind,
## agent/test seconds, LLM rounds (assistant messages carrying tool_calls),
## tool-call histogram, bash classes (read-ish cat/ls/find/pwd/head/tail/
## wc/file; test runs ./test*/go test/pytest/node --test; writes via tee,
## heredoc or bare >; priority test > write > read > other) and the
## first/last prompt-token mass. The guest then aggregates per
## harness+model and per kind, and flags:
##   * cells whose bash file-inspection share of bash calls is > 30%
##   * cells whose last-round prompt mass is > 2.5x the first round's
##   * the top 3 cells by LLM round count
##   * cells marked invalid or footprintOver
##   * expected cells that never ran (harness x task gaps)
##
## Run:  tools = ["bash"], strings = {"run": "<run-id>"}

import fabricguest
import std/[strutils, tables]

const runDirBase = "var/bench/results/"
const chunkSize = 16            # cells per walker call (~5KB output)

# ------------------------------------------------------------------ walker
# Prints one JSON line per distilled cell. Args: base, start, end (indices
# into the sorted cell-glob list). Kept terse so chunk output stays small.

const walker = r"""
import json, sys, glob, os
base, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
RI = ["cat", "ls", "find", "pwd", "head", "tail", "wc", "file"]
def has_write(cmd):
    if "tee" in cmd or "<<" in cmd: return True
    for i, c in enumerate(cmd):
        if c == ">" and (i == 0 or cmd[i-1] not in "12&>"): return True
    return False
def is_test(cmd):
    return "./test" in cmd or "go test" in cmd or "pytest" in cmd or "node --test" in cmd
def is_read(cmd):
    for tok in cmd.replace(";", " ").replace("|", " ").replace("&", " ") \
                  .replace("(", " ").replace(")", " ").replace("<", " ") \
                  .replace(">", " ").split():
        if tok in RI: return True
    return False
def cls(cmd):
    if is_test(cmd): return "test"
    if has_write(cmd): return "write"
    if is_read(cmd): return "read"
    return "other"
for d in sorted(glob.glob(os.path.join(base, "*__*__*")))[start:end]:
    cell = os.path.basename(d.rstrip("/"))
    out = {"cell": cell, "verdict": "?", "invalid": False, "fpOver": False,
           "kind": "?", "agentS": 0.0, "testS": 0.0}
    try:
        r = json.load(open(os.path.join(d, "result.json")))
        out["verdict"] = r.get("verdict", "?")
        out["invalid"] = bool(r.get("invalid", False))
        out["fpOver"] = bool(r.get("footprintOver", False))
        out["agentS"] = r.get("agentTimeS") or 0
        out["testS"] = r.get("testTimeS") or 0
    except Exception:
        pass
    parts = cell.split("__")
    task = "__".join(parts[2:]) if len(parts) > 2 else cell
    try:
        out["kind"] = json.load(open(os.path.join(
            "bench", "tasks", task, "meta.json"))).get("kind", "general")
    except Exception:
        pass
    rounds = 0; hist = {}; bash = {"read": 0, "test": 0, "write": 0, "other": 0}
    ptF = -1; ptL = -1
    try:
        t = json.load(open(os.path.join(d, "transcript.json")))
        for it in t.get("items", []):
            v = (it or {}).get("value") or {}
            if v.get("role") != "assistant": continue
            tcs = v.get("tool_calls") or []
            if not tcs: continue
            rounds += 1
            pt = ((v.get("usage") or {}).get("prompt_tokens") or 0)
            if pt > 0:
                if ptF < 0: ptF = pt
                ptL = pt
            for tc in tcs:
                fn = tc.get("function") or {}
                n = fn.get("name", "unknown")
                hist[n] = hist.get(n, 0) + 1
                if n == "bash":
                    try:
                        a = (json.loads(fn.get("arguments") or "{}") or {}) \
                             .get("command", "")
                    except Exception:
                        a = ""
                    bash[cls(a)] += 1
    except Exception:
        pass
    out["rounds"] = rounds; out["hist"] = hist; out["bash"] = bash
    out["ptF"] = ptF; out["ptL"] = ptL; out["calls"] = sum(hist.values())
    print(json.dumps(out, separators=(",", ":")))
"""

# ---------------------------------------------------------------- transport

proc textOf(n: JsonNode): string =
  ## LLM-facing rendering of a bash result (WIRE.md "Tool results"): the
  ## `text` field is what the transcript showed; tolerate a bare string
  ## result and older shapes too.
  if n == nil: return ""
  if n.kind == JString: return n.str
  let txt = n{"text"}
  if txt != nil and txt.kind == JString: return txt.getStr
  let outp = n{"output"}
  if outp != nil and outp.kind == JString: return outp.getStr
  let cont = n{"content"}
  if cont != nil:
    if cont.kind == JString: return cont.getStr
    return $cont
  ""

proc numOf(v: JsonNode): float =
  ## tolerant numeric read of a value node (walker emits ints or floats)
  if v == nil: return 0.0
  case v.kind
  of JInt: v.getFloat
  of JFloat: v.getFloat
  else: 0.0

proc numOf(n: JsonNode, key: string): float =
  ## tolerant numeric read of member `key`
  if n == nil: return 0.0
  numOf(n{key})

proc lineRows(text: string): seq[JsonNode] =
  ## one JSON object per walker output line; tolerate blanks/noise
  for ln in text.splitLines():
    let s = strip(ln)
    if s.len == 0 or not s.startsWith("{"): continue
    try: result.add(parseJson(s))
    except: discard

# ------------------------------------------------------------------ report

proc report(jid: string) =
  let base = runDirBase & jid
  logg("bench-selfreview: scanning run '" & jid & "' under " & base)

  # discovery call 1: enumerate cell directories; guard empties with `true`
  let listing = tools.bash(command = "cd " & base &
                           " 2>/dev/null && ls -d ./*__*__*/ 2>/dev/null; true")
  var cells: seq[string] = @[]
  var cur = ""
  for c in textOf(listing):
    if c == '\n':
      if cur.len > 0:
        # ls output lines start with "./"; the '/' is skipped by this
        # parser, so the surviving prefix is a lone '.'.
        if cur.startsWith("."): cur = cur[1 .. ^1]
        cells.add(cur)
      cur = ""
    elif c != '/':
      cur.add(c)
  if cur.len > 0:
    if cur.startsWith("."): cur = cur[1 .. ^1]
    cells.add(cur)
  logg("bench-selfreview: found " & $cells.len & " cells")

  # discovery call 2: the expected task list (for missing-cell flags)
  let taskListing = tools.bash(command = "ls bench/tasks 2>/dev/null; true")
  var expectedTasks: seq[string] = @[]
  for ln in textOf(taskListing).splitLines():
    let s = strip(ln)
    if s.startsWith("t"): expectedTasks.add(s)

  # walker chunks: distill all cells, chunkSize per bash call
  var rows: seq[JsonNode] = @[]
  var i = 0
  while i < cells.len:
    let hi = min(i + chunkSize, cells.len)
    let outp = tools.bash(command = "python3 - " & base & " " & $i & " " & $hi &
                          " <<'PYEOF'\n" & walker & "\nPYEOF")
    let chunk = lineRows(textOf(outp))
    rows.add(chunk)
    logg("  walker " & $i & ".." & $hi & ": " & $chunk.len & " cells distilled")
    i = hi

  # per-cell rows -> aggregates
  var aCells = initTable[string, int]()
  var aRounds = initTable[string, int]()
  var aCalls = initTable[string, int]()
  var aBash = initTable[string, int]()
  var aRead = initTable[string, int]()
  var aTest = initTable[string, int]()
  var aWrite = initTable[string, int]()
  var aPass = initTable[string, int]()
  var aAgentS = initTable[string, float]()

  var kCells = initTable[string, int]()
  var kPass = initTable[string, int]()
  var kRounds = initTable[string, int]()
  var kCalls = initTable[string, int]()
  var kAgentS = initTable[string, float]()

  var present = initTable[string, bool]()
  var fInspect = newJArray()
  var fDrift = newJArray()
  var fInvalid = newJArray()
  var fFpOver = newJArray()

  for row in rows:
    let cell = row{"cell"}.getStr
    let parts = cell.split("__")
    if parts.len < 3: continue
    let harness = parts[0]
    let model = parts[1]
    var task = parts[2]
    for p in 3 ..< parts.len: task &= "__" & parts[p]
    present[harness & "|" & model & "|" & task] = true

    let verdict = row{"verdict"}.getStr("?")
    let kind = row{"kind"}.getStr("?")
    let bashJ = row{"bash"}
    let bRead = int(bashJ{"read"}.numOf)
    let bTest = int(bashJ{"test"}.numOf)
    let bWrite = int(bashJ{"write"}.numOf)
    let bOther = int(bashJ{"other"}.numOf)
    let bashTotal = bRead + bTest + bWrite + bOther
    let rounds = int(row{"rounds"}.numOf)
    let totalCalls = int(row{"calls"}.numOf)
    let agentTime = row{"agentS"}.numOf
    let readIshShare = if bashTotal > 0: (bRead * 100) div bashTotal else: 0
    let key = harness & "|" & model

    aCells[key] = aCells.getOrDefault(key) + 1
    aRounds[key] = aRounds.getOrDefault(key) + rounds
    aCalls[key] = aCalls.getOrDefault(key) + totalCalls
    aBash[key] = aBash.getOrDefault(key) + bashTotal
    aRead[key] = aRead.getOrDefault(key) + bRead
    aTest[key] = aTest.getOrDefault(key) + bTest
    aWrite[key] = aWrite.getOrDefault(key) + bWrite
    if verdict == "pass": aPass[key] = aPass.getOrDefault(key) + 1
    aAgentS[key] = aAgentS.getOrDefault(key, 0.0) + agentTime

    kCells[kind] = kCells.getOrDefault(kind) + 1
    kRounds[kind] = kRounds.getOrDefault(kind) + rounds
    kCalls[kind] = kCalls.getOrDefault(kind) + totalCalls
    kAgentS[kind] = kAgentS.getOrDefault(kind, 0.0) + agentTime
    if verdict == "pass": kPass[kind] = kPass.getOrDefault(kind) + 1

    var histObj = newJObject()
    let hist = row{"hist"}
    if hist != nil and hist.kind == JObject:
      for hk, hv in hist: histObj[hk] = %int(numOf(hv))

    # per-cell flags
    if readIshShare > 30:
      fInspect.add(%*{"cell": cell, "readIshSharePct": readIshShare})
    let first = int(row{"ptF"}.numOf)
    let last = int(row{"ptL"}.numOf)
    if first > 0 and last * 2 > first * 5:      # last > 2.5x first
      fDrift.add(%*{"cell": cell,
                    "firstTokenMass": first,
                    "lastTokenMass": last,
                    "ratioX": last.float / first.float})
    if row{"invalid"}.getBool(false):
      fInvalid.add(%*{"cell": cell, "verdict": verdict})
    if row{"fpOver"}.getBool(false):
      fFpOver.add(%*{"cell": cell, "verdict": verdict})

    logg("  cell " & cell & ": " & $rounds & " rounds / " & $totalCalls &
         " calls / " & $readIshShare & "% read-ish bash; " & verdict &
         " (" & kind & ")")

  # --------------------------------------------------- missing-cell flags
  # combos (harness x model) actually present in the run; a combo with zero
  # cells can't be known here (the _combo-* dirs would tell, but they are
  # harness-internal bookkeeping).
  var combos: seq[string] = @[]
  for c in cells:
    let p = c.split("__")
    if p.len >= 2:
      let k = p[0] & "|" & p[1]
      if k notin combos: combos.add(k)
  var fMissing = newJArray()
  for k in combos:
    let sp = k.split("|")
    for t in expectedTasks:
      if not present.getOrDefault(k & "|" & t, false):
        fMissing.add(%*{"harness": sp[0], "model": sp[1], "task": t})

  # ------------------------------------------------- aggregates per h/m
  var aggRows = newJArray()
  for key in aCells.keys:
    let sp = key.split("|")
    let writeShare = if aBash[key] > 0: (aWrite[key] * 100) div aBash[key]
                     else: 0
    aggRows.add(%*{
      "harness": sp[0], "model": sp[1],
      "cells": aCells[key],
      "llmRounds": aRounds[key],
      "toolCalls": aCalls[key],
      "bashCalls": aBash[key],
      "bashReadIsh": aRead[key],
      "bashTestRuns": aTest[key],
      "bashWriteSharePct": writeShare,
      "passCount": aPass[key],
      "agentTimeS": aAgentS[key]
    })

  # ------------------------------------------------- aggregates per kind
  var kindRows = newJArray()
  for kind in kCells.keys:
    kindRows.add(%*{
      "kind": kind,
      "cells": kCells[kind],
      "passCount": kPass.getOrDefault(kind),
      "llmRounds": kRounds[kind],
      "toolCalls": kCalls[kind],
      "agentTimeS": kAgentS[kind]
    })

  # ------------------------------------------------------- top 3 by rounds
  var taken = initCountTable[string]()
  var top3 = newJArray()
  for _ in 0 ..< 3:
    var best = -1
    var bestN = -1
    for idx in 0 ..< rows.len:
      let r = rows[idx]
      if taken.getOrDefault(r{"cell"}.getStr, 0) > 0: continue
      let n = int(r{"rounds"}.numOf)
      if n > bestN:
        bestN = n
        best = idx
    if best >= 0:
      top3.add(%*{"cell": rows[best]{"cell"}.getStr,
                  "llmRounds": bestN})
      taken[rows[best]{"cell"}.getStr] = 1

  finish($(%*{
    "run": jid,
    "cellCount": rows.len,
    "expectedCellCount": combos.len * expectedTasks.len,
    "aggregatesByHarnessModel": aggRows,
    "aggregatesByKind": kindRows,
    "flags": {
      "bashInspectionGt30pct": fInspect,
      "lastRoundPromptGt2_5xFirst": fDrift,
      "top3CellsByLLMRounds": top3,
      "invalidCells": fInvalid,
      "footprintOverCells": fFpOver,
      "missingCells": fMissing
    }
  }))

report(stringArg("run"))
