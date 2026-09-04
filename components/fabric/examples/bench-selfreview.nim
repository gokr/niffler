## bench-selfreview.nim — self-review a bench run's cell transcripts and emit a
## distilled findings report. The big intermediate transcripts stay off the
## wire; only the compact report reaches the conversation.
##
## A bench run lives under var/bench/results/<run>/ with one cell directory per
## <harness>__<model>__<task> combo. Each cell carries:
##   transcript.json = {"sessionId", "items": [ {value:{role, content,
##                      tool_calls, usage}} ]}   (full per-round conversation)
##   result.json      = {"verdict","rounds","agentTimeS","tokens",
##                       "firstPromptTokens", ...}
##
## Per cell this program derives:
##   - LLM rounds   = assistant messages whose value carried tool_calls
##   - tool-call histogram (by tool function name)
##   - bash-command classes: read-ish (cat/ls/find/pwd/head/tail/wc/file),
##     test runs (./test.* | go test | pytest | node --test), writes
##     (heredoc / > / tee). Decision priority: test > write > read > other.
##   - prompt-token mass of the first and last LLM round (usage.prompt_tokens)
##   - the result verdict (from result.json)
## Then it aggregates per harness+model and emits flags:
##   * cells whose bash file-inspection share of tool calls is > 30%
##   * cells whose last-round prompt mass is > 2.5x the first round's
##   * the top 3 cells by LLM round count
##
## Read tool results carry a "content" field; bash results carry "exit_code"
## and "output". Both tools' file text is fetched verbatim here.
##
## Run:  tools = ["bash", "read"], code = <this file>,
##       strings = {"run": "<run-id>"}

import fabricguest
import std/[strutils, tables]

const runDirBase = "var/bench/results/"
const readIshWords = ["cat", "ls", "find", "pwd", "head", "tail", "wc", "file"]

# ------------------------------------------------------------- classification

proc hasWriteCmd(cmd: string): bool =
  ## heredoc / > / tee create files; stderr redirects 2> &> 1> are noise here.
  if cmd.contains("tee") or cmd.contains("<<"): return true
  var i = 0
  while i < cmd.len:
    if cmd[i] == '>' and (i == 0 or cmd[i-1] notin {'1', '2', '&', '>'}):
      return true
    inc i
  false

proc isTestRun(cmd: string): bool =
  cmd.contains("./test") or cmd.contains("go test") or
    cmd.contains("pytest") or cmd.contains("node --test")

proc isReadCommand(cmd: string): bool =
  ## tokenized match on the classic shell inspection commands
  var cur = ""
  for c in cmd:
    if c in Whitespace or c in {';', '|', '&', '(', ')', '<', '>'}:
      if cur.len > 0:
        for w in readIshWords:
          if cur == w: return true
        cur = ""
    else:
      cur.add(c)
  if cur.len > 0:
    for w in readIshWords:
      if cur == w: return true
  false

proc classifyBash(args: JsonNode): string =
  if args == nil: return "other"
  let cnode = args{"command"}
  if cnode == nil or cnode.kind != JString: return "other"
  let cmd = cnode.getStr
  if isTestRun(cmd): "test"
  elif hasWriteCmd(cmd): "write"
  elif isReadCommand(cmd): "read"
  else: "other"

# ---------------------------------------------------------------- transport

proc textOf(n: JsonNode): string =
  ## read results come back as a JSON string (verbatim file body); bash results
  ## carry an "output" member. Tolerantly recover the raw text either way.
  if n == nil: return ""
  if n.kind == JString: return n.str
  let outp = n{"output"}
  if outp != nil and outp.kind == JString: return outp.getStr
  let cont = n{"content"}
  if cont != nil:
    if cont.kind == JString: return cont.getStr
    return $cont
  ""

proc intAt(n: JsonNode, key: string): int =
  if n == nil: return 0
  let v = n{key}
  if v == nil or v.kind != JInt: return 0
  v.getInt

proc cellId(h, m, t: string): string = h & "__" & m & "__" & t

# ------------------------------------------------------------------ report

proc report(jid: string) =
  let base = runDirBase & jid
  logg("bench-selfreview: scanning run '" & jid & "' under " & base)

  # enumerate cell directories with one bash call; guard empties with `true`
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

  var rows = newJArray()
  # per harness|model aggregate accumulators
  var aCells = initTable[string, int]()
  var aRounds = initTable[string, int]()
  var aCalls = initTable[string, int]()
  var aBash = initTable[string, int]()
  var aRead = initTable[string, int]()
  var aTest = initTable[string, int]()
  var aWrite = initTable[string, int]()
  var aPass = initTable[string, int]()
  var aAgentS = initTable[string, float]()

  for cell in cells:
    let parts = cell.split("__")
    if parts.len < 3: continue
    let harness = parts[0]
    let model = parts[1]
    var task = parts[2]
    for p in 3 ..< parts.len: task &= "__" & parts[p]

    let transText = textOf(tools.read(path = base & "/" & cell & "/transcript.json"))
    let resText   = textOf(tools.read(path = base & "/" & cell & "/result.json"))
    var trans, res: JsonNode
    try: trans = parseJson(transText)
    except: continue            # not a usable bench cell -> skip
    try: res = parseJson(resText)
    except: continue

    let verdict = res{"verdict"}.getStr("?")
    let agentTime = res{"agentTimeS"}.getFloat

    var rounds = 0
    var totalCalls = 0
    var hist = initCountTable[string]()
    var bRead, bTest, bWrite, bOther = 0
    var firstPrompt = -1
    var lastPrompt = -1

    let items = trans{"items"}
    if items != nil and items.kind == JArray:
      for item in items:
        let value = item{"value"}
        if value == nil: continue
        if value{"role"} == nil or value{"role"}.getStr != "assistant": continue
        let tcs = value{"tool_calls"}
        if tcs == nil or tcs.kind != JArray or tcs.len == 0: continue
        inc rounds                       # one LLM round per tool-call message
        let usage = value{"usage"}
        if usage != nil:
          let pt = intAt(usage, "prompt_tokens")
          if pt > 0:
            if firstPrompt < 0: firstPrompt = pt
            lastPrompt = pt
        for tc in tcs:
          let fnMeta = tc{"function"}
          if fnMeta == nil: continue
          let tname = fnMeta{"name"}.getStr("unknown")
          hist.inc(tname)
          inc totalCalls
          if tname == "bash":
            let a = fnMeta{"arguments"}
            var args: JsonNode = nil
            if a != nil and a.kind == JString:
              try: args = parseJson(a.getStr)
              except: discard
            case classifyBash(args)
            of "read":  inc bRead
            of "test":  inc bTest
            of "write": inc bWrite
            else:       inc bOther

    let bashTotal = bRead + bTest + bWrite + bOther
    let readIshShare = if totalCalls > 0: (bRead * 100) div totalCalls else: 0
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

    var histObj = newJObject()
    for k, v in hist: histObj[$k] = %v
    var bashObj = newJObject()
    bashObj["read"] = %bRead
    bashObj["test"] = %bTest
    bashObj["write"] = %bWrite
    bashObj["other"] = %bOther

    rows.add(%*{
      "cell": cellId(harness, model, task),
      "verdict": verdict,
      "llmRounds": rounds,
      "toolCalls": totalCalls,
      "bashCalls": bashTotal,
      "bashClasses": bashObj,
      "readIshSharePct": readIshShare,
      "firstPromptTokens": firstPrompt,
      "lastPromptTokens": lastPrompt,
      "toolHistogram": histObj
    })
    logg("  cell " & cell & ": " & $rounds & " rounds / " & $totalCalls &
         " calls / " & $readIshShare & "% read-ish bash; " & verdict)

  # ----------------------------------------------------------- flags (cells)
  var fInspect = newJArray()
  var fDrift = newJArray()
  for r in rows:
    let id = r{"cell"}.getStr
    if r{"readIshSharePct"}.getInt > 30:
      fInspect.add(%*{"cell": id,
                      "readIshSharePct": r{"readIshSharePct"}.getInt})
    let first = r{"firstPromptTokens"}.getInt
    let last = r{"lastPromptTokens"}.getInt
    if first > 0 and last * 2 > first * 5:      # last > 2.5x first
      fDrift.add(%*{"cell": id,
                    "firstTokenMass": first,
                    "lastTokenMass": last,
                    "ratioX": last.float / first.float})

  # top 3 cells by LLM round count (simple linear selection)
  var taken = initCountTable[string]()
  var top3 = newJArray()
  for _ in 0 ..< 3:
    var best = -1
    var bestN = -1
    for i in 0 ..< rows.len:
      let r = rows[i]
      if taken.getOrDefault(r{"cell"}.getStr, 0) > 0: continue
      let n = r{"llmRounds"}.getInt
      if n > bestN:
        bestN = n
        best = i
    if best >= 0:
      top3.add(%*{"cell": rows[best]{"cell"}.getStr,
                  "llmRounds": rows[best]{"llmRounds"}.getInt})
      taken[rows[best]{"cell"}.getStr] = 1

  # --------------------------------------------------- aggregates per h/m
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

  finish($(%*{
    "run": jid,
    "cellCount": rows.len,
    "aggregatesByHarnessModel": aggRows,
    "flags": {
      "bashInspectionGt30pct": fInspect,
      "lastRoundPromptGt2_5xFirst": fDrift,
      "top3CellsByLLMRounds": top3
    }
  }))

report(stringArg("run"))
