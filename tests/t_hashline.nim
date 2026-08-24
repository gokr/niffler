## hashline-edit component tests — bus contract.
##
## Scenarios ported from pi-hashline-edit-pro's test suite (test/integration/*
## and the hashline core tests), run against the component over the bus:
## read/replace/undo_last_replace semantics, anchor stability, boundary-dup
## auto-fix, served-state range verification, undo persistence.
##
## Uses a temp NIF_ROOT and a temp XDG_CONFIG_HOME so the real hash store is
## never touched. Hashes are deterministic per content (xxHash over the
## canonicalized line), so anchors can also be learned from a file with
## identical content — used to test the "never served" code path.

import std/[json, os, osproc, sequtils, sets, strutils]
import natswrapper
import helpers

const SEP = "\u2502"

proc readTool(nc: NatsConnection, path: string, offset = 0, limit = 0): string =
  ## read tool result text; fails hard on component errors.
  var args = %*{"path": path}
  if offset > 0: args["offset"] = %offset
  if limit > 0: args["limit"] = %limit
  let r = call(nc, "hashline-edit", "read", args)
  if r{"error"} != nil:
    fail("read " & path & " failed: " & r{"error"}.getStr(""))
    return ""
  r.getStr("")

proc replaceTool(nc: NatsConnection, path, fromH, toH: string,
                 lines: seq[string]): JsonNode =
  call(nc, "hashline-edit", "replace",
       %*{"path": path, "remove_from": fromH, "remove_to": toH,
          "replacement_lines": %lines})

proc undoTool(nc: NatsConnection, path: string): JsonNode =
  call(nc, "hashline-edit", "undo_last_replace", %*{"path": path})

proc hashOf(text, content: string): string =
  for line in text.split("\n"):
    if line.contains(SEP & content):
      return line.split(SEP)[0]
  ""

proc allHashes(text: string): seq[string] =
  for line in text.split("\n"):
    if line.len >= 4 and line[0 .. 2].allIt(it in {'A'..'Z', 'a'..'z', '0'..'9'}) and
        line[3] == SEP[0]:
      result.add(line[0 .. 2])

proc allCharsDiffer(a, b: string): bool =
  a.len == 3 and b.len == 3 and a[0] != b[0] and a[1] != b[1] and a[2] != b[2]

proc failUnlessNoError(r: JsonNode, label: string) =
  check(label, r{"error"} == nil, $r)

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "hashline-edit"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let tmp = tempRoot("hashline")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)

  var nc = waitConnect(url)
  defer: nc.close()
  var comp = startComponent(bin, url, root = tmp,
                            extra = [("XDG_CONFIG_HOME", tmp / "config"),
                                     ("HOME", tmp)])
  defer:
    if comp.running():
      comp.terminate()
      sleep(200)
    comp.close()
  check("hashline-edit registers", waitRegistered(nc, "hashline-edit"))
  if failures > 0:
    echo "hashline-edit never came up — aborting"
    report("t_hashline")

  proc restartComponent() =
    if comp.running():
      comp.terminate()
      sleep(300)
      comp.close()
    comp = startComponent(bin, url, root = tmp,
                          extra = [("XDG_CONFIG_HOME", tmp / "config"),
                                   ("HOME", tmp)])
    check("hashline-edit re-registers", waitRegistered(nc, "hashline-edit"))

  # ------------------------------------------------------------------
  # read tool: anchored output, empty file, hashing contract
  writeFile(tmp / "empty.txt", "")
  let emptyRead = readTool(nc, "empty.txt")
  check("empty file read shows single empty-line hash",
        emptyRead.len > 4 and allHashes(emptyRead).len == 1 and
        emptyRead.contains("[File is empty. Use replace to insert content.]"),
        emptyRead)
  let emptyHash = allHashes(emptyRead)[0]
  let seeded = replaceTool(nc, "empty.txt", emptyHash, emptyHash,
                           @["first", "second"])
  failUnlessNoError(seeded, "seed empty file")
  check("seeded empty file content", readFile(tmp / "empty.txt") == "first\nsecond")

  writeFile(tmp / "sample.txt", "alpha\nbeta\ngamma\n")
  let r1 = readTool(nc, "sample.txt")
  let alphaHash = hashOf(r1, "alpha")
  let betaHash = hashOf(r1, "beta")
  let gammaHash = hashOf(r1, "gamma")
  check("read returns 3-char anchors",
        alphaHash.len == 3 and betaHash.len == 3 and gammaHash.len == 3, r1)
  check("read anchors unique", allHashes(r1).len == 3 and
        allHashes(r1).toHashSet().len == 3)

  # hashing contract: internal spaces matter, trailing whitespace does not
  writeFile(tmp / "a.txt", "a b\n")
  writeFile(tmp / "b.txt", "ab\n")
  check("internal spaces preserved when hashing",
        hashOf(readTool(nc, "a.txt"), "a b") != hashOf(readTool(nc, "b.txt"), "ab"))
  writeFile(tmp / "c.txt", "value  \n")
  writeFile(tmp / "d.txt", "value\n")
  check("trailing spaces trimmed when hashing",
        hashOf(readTool(nc, "c.txt"), "value  ") ==
        hashOf(readTool(nc, "d.txt"), "value"))

  # hash spread: consecutive identical lines share no characters
  writeFile(tmp / "blanks.txt", "\n".repeat(19))
  let blanks = readTool(nc, "blanks.txt")
  let blankHashes = allHashes(blanks)
  check("many blank lines all get unique anchors",
        blankHashes.len >= 19 and blankHashes.toHashSet().len == blankHashes.len)
  var strideOk = true
  for i in 1 ..< blankHashes.len:
    if not allCharsDiffer(blankHashes[i - 1], blankHashes[i]):
      strideOk = false
      break
  check("consecutive blank anchors share no characters", strideOk, blanks)
  writeFile(tmp / "braces.txt", "}\n".repeat(20))
  let braceHashes = allHashes(readTool(nc, "braces.txt"))
  var braceOk = true
  for i in 1 ..< braceHashes.len:
    if not allCharsDiffer(braceHashes[i - 1], braceHashes[i]):
      braceOk = false
      break
  check("consecutive brace anchors share no characters", braceOk)

  # uniqueness across a larger file
  writeFile(tmp / "many.txt", "a\n".repeat(1000))
  let manyHashes = allHashes(readTool(nc, "many.txt"))
  check("1000 identical lines all get unique anchors",
        manyHashes.len == 1000 and manyHashes.toHashSet().len == 1000)

  # pagination
  writeFile(tmp / "page.txt", "l1\nl2\nl3\nl4\nl5\n")
  let page = readTool(nc, "page.txt", limit = 2)
  check("read limit paginates",
        page.contains("[Showing lines 1-2 of 5. Use offset=3 to continue.]"), page)
  let beyond = readTool(nc, "page.txt", offset = 99)
  check("read offset beyond end explains",
        beyond.contains("Offset 99 is beyond end of file (5 lines total)"), beyond)

  # binary rejection
  writeFile(tmp / "bin.dat", "\x00\x01\x02")
  let binRead = call(nc, "hashline-edit", "read", %*{"path": "bin.dat"})
  check("binary file rejected with E_NOT_TEXT",
        binRead{"error"}.getStr("").contains("[E_NOT_TEXT]"), $binRead)

  # ------------------------------------------------------------------
  # replace end-to-end: single line, range, delete, counts
  writeFile(tmp / "e2e.txt", "aaa\nbbb\nccc\n")
  let e2eRead = readTool(nc, "e2e.txt")
  let bHash = hashOf(e2eRead, "bbb")
  let single = replaceTool(nc, "e2e.txt", bHash, bHash, @["BBB"])
  failUnlessNoError(single, "single-line replace")
  check("single-line replace summary",
        single{"summary"}.getStr("").contains("Successfully replaced") and
        single{"summary"}.getStr("").contains("Added 1 line(s), removed 1 line(s)."),
        $single)
  check("single-line replace content", readFile(tmp / "e2e.txt") == "aaa\nBBB\nccc\n")

  let e2e2 = readTool(nc, "e2e.txt")
  let b2 = hashOf(e2e2, "BBB")
  let c2 = hashOf(e2e2, "ccc")
  let range = replaceTool(nc, "e2e.txt", b2, c2, @["B", "C"])
  failUnlessNoError(range, "range replace")
  check("range replace content", readFile(tmp / "e2e.txt") == "aaa\nB\nC\n")

  let e2e3 = readTool(nc, "e2e.txt")
  let b3 = hashOf(e2e3, "B")
  let c3 = hashOf(e2e3, "C")
  let del = replaceTool(nc, "e2e.txt", b3, c3, @[])
  failUnlessNoError(del, "delete range")
  check("delete range summary",
        del{"summary"}.getStr("").contains("Added 0 line(s), removed 2 line(s)."),
        $del)
  check("delete range content", readFile(tmp / "e2e.txt") == "aaa\n")

  # strict loop: edit -> stale anchor rejection -> re-read -> edit
  writeFile(tmp / "loop.txt", "alpha\nbeta\n")
  let loopRead = readTool(nc, "loop.txt")
  let loopBeta = hashOf(loopRead, "beta")
  failUnlessNoError(replaceTool(nc, "loop.txt", loopBeta, loopBeta, @["BETA"]),
                    "loop edit 1")
  let stale = replaceTool(nc, "loop.txt", loopBeta, loopBeta, @["BETA-AGAIN"])
  check("stale anchor rejected after edit",
        stale{"error"}.getStr("").contains("stale anchor") and
        stale{"error"}.getStr("").contains("loop.txt"), $stale)
  let loopRead2 = readTool(nc, "loop.txt")
  let freshBeta = hashOf(loopRead2, "BETA")
  failUnlessNoError(replaceTool(nc, "loop.txt", freshBeta, freshBeta,
                                @["BETA-AGAIN"]), "loop edit 3")
  check("loop edit 3 applied", readFile(tmp / "loop.txt") == "alpha\nBETA-AGAIN\n")

  # unchanged anchors stay valid across edits
  writeFile(tmp / "stale.txt", "alpha\nbeta\n")
  let staleRead = readTool(nc, "stale.txt")
  let staleBeta = hashOf(staleRead, "beta")
  let staleAlpha = hashOf(staleRead, "alpha")
  failUnlessNoError(replaceTool(nc, "stale.txt", staleBeta, staleBeta, @["BETA"]),
                    "stale.txt edit beta")
  let staleAgain = replaceTool(nc, "stale.txt", staleBeta, staleBeta, @["X"])
  check("edited-away anchor still stale",
        staleAgain{"error"}.getStr("").contains("stale anchor"), $staleAgain)
  failUnlessNoError(replaceTool(nc, "stale.txt", staleAlpha, staleAlpha,
                                @["ALPHA"]), "stale.txt edit alpha")
  check("unchanged anchor edits after chained edit",
        readFile(tmp / "stale.txt") == "ALPHA\nBETA\n")

  # reversed range: swapped with a warning, other anchors still valid
  writeFile(tmp / "rev.txt", "alpha\nbeta\ngamma\ndelta\n")
  let revRead = readTool(nc, "rev.txt")
  let revAlpha = hashOf(revRead, "alpha")
  let revBeta = hashOf(revRead, "beta")
  let revGamma = hashOf(revRead, "gamma")
  let rev = replaceTool(nc, "rev.txt", revGamma, revBeta, @["X"])
  failUnlessNoError(rev, "reversed range replace")
  check("reversed range warns",
        rev{"summary"}.getStr("").contains("Warnings:"), $rev)
  check("reversed range content", readFile(tmp / "rev.txt") == "alpha\nX\ndelta\n")
  failUnlessNoError(replaceTool(nc, "rev.txt", revAlpha, revAlpha, @["ALPHA"]),
                    "rev.txt edit alpha after swap")
  check("unchanged anchor valid after reversed-range replace",
        readFile(tmp / "rev.txt") == "ALPHA\nX\ndelta\n")

  # ------------------------------------------------------------------
  # line endings + BOM
  writeFile(tmp / "crlf.txt", "alpha\r\nbeta\r\ngamma\r\n")
  let crlfRead = readTool(nc, "crlf.txt")
  let crlfBeta = hashOf(crlfRead, "beta")
  failUnlessNoError(replaceTool(nc, "crlf.txt", crlfBeta, crlfBeta, @["BETA"]),
                    "crlf edit")
  check("CRLF preserved after edit",
        readFile(tmp / "crlf.txt") == "alpha\r\nBETA\r\ngamma\r\n")

  writeFile(tmp / "cr.txt", "alpha\rbeta\rgamma\r")
  let crRead = readTool(nc, "cr.txt")
  let crBeta = hashOf(crRead, "beta")
  failUnlessNoError(replaceTool(nc, "cr.txt", crBeta, crBeta, @["BETA"]),
                    "lone-CR edit")
  check("lone-CR preserved after edit",
        readFile(tmp / "cr.txt") == "alpha\rBETA\rgamma\r")

  # line-ending matrix: delete middle line preserves the ending
  for (name, content, expected) in [("lf.txt", "alpha\nbeta\ngamma\n", "alpha\ngamma\n"),
                                    ("crlf2.txt", "alpha\r\nbeta\r\ngamma\r\n",
                                     "alpha\r\ngamma\r\n"),
                                    ("cr2.txt", "alpha\rbeta\rgamma\r",
                                     "alpha\rgamma\r")]:
    writeFile(tmp / name, content)
    let mRead = readTool(nc, name)
    let mBeta = hashOf(mRead, "beta")
    failUnlessNoError(replaceTool(nc, name, mBeta, mBeta, @[]),
                      name & " delete middle")
    check(name & " delete middle preserves ending",
          readFile(tmp / name) == expected, readFile(tmp / name))
    # noop keeps the file byte-identical (fresh file with beta present)
    writeFile(tmp / ("noop-" & name), content)
    let nRead = readTool(nc, "noop-" & name)
    let nBeta = hashOf(nRead, "beta")
    let noop = replaceTool(nc, "noop-" & name, nBeta, nBeta, @["beta"])
    check(name & " noop reports no changes",
          noop{"summary"}.getStr("").contains("No changes made"), $noop)
    check(name & " noop keeps file byte-identical",
          readFile(tmp / ("noop-" & name)) == content)

  # BOM: stripped for display, restored on write
  writeFile(tmp / "bom.txt", "\uFEFFalpha\nbeta\n")
  let bomRead = readTool(nc, "bom.txt")
  check("BOM stripped for display", not bomRead.contains("\uFEFF"), bomRead)
  let bomBeta = hashOf(bomRead, "beta")
  failUnlessNoError(replaceTool(nc, "bom.txt", bomBeta, bomBeta, @["BETA"]),
                    "bom edit")
  check("BOM restored on write",
        readFile(tmp / "bom.txt") == "\uFEFFalpha\nBETA\n",
        readFile(tmp / "bom.txt"))

  # ------------------------------------------------------------------
  # noop hash stability
  writeFile(tmp / "noop.txt", "aaa\nbbb\nccc\n")
  let noopRead = readTool(nc, "noop.txt")
  let noopBbb = hashOf(noopRead, "bbb")
  for i in 0 ..< 3:
    let noop = replaceTool(nc, "noop.txt", noopBbb, noopBbb, @["bbb"])
    check("repeated noop #" & $i & " reports no changes",
          noop{"summary"}.getStr("").contains("No changes made"), $noop)
  let noopRead2 = readTool(nc, "noop.txt")
  check("noop keeps edited-line hash unchanged",
        hashOf(noopRead2, "bbb") == noopBbb)
  failUnlessNoError(replaceTool(nc, "noop.txt", noopBbb, noopBbb, @["BBB"]),
                    "noop-follow-up edit")
  check("noop anchors remain usable for a real edit",
        readFile(tmp / "noop.txt") == "aaa\nBBB\nccc\n")

  # ------------------------------------------------------------------
  # boundary-duplication auto-fix
  writeFile(tmp / "brace.txt",
            "function foo() {\n  const x = 1;\n  return x;\n}\n")
  let braceRead = readTool(nc, "brace.txt")
  let bLine2 = hashOf(braceRead, "  const x = 1;")
  let bLine3 = hashOf(braceRead, "  return x;")
  let bEdit = replaceTool(nc, "brace.txt", bLine2, bLine3,
                          @["  const y = 2;", "  return y;", "}"])
  failUnlessNoError(bEdit, "boundary-dup trailing }")
  check("boundary-dup strips duplicate }",
        readFile(tmp / "brace.txt") ==
          "function foo() {\n  const y = 2;\n  return y;\n}\n",
        readFile(tmp / "brace.txt"))
  check("boundary-dup counts stripped line as added",
        bEdit{"summary"}.getStr("").contains("Added 2 line(s), removed 2 line(s)."),
        $bEdit)

  writeFile(tmp / "leading.txt", "before();\nif (ok) {\n  run();\n}\nafter();\n")
  let leadRead = readTool(nc, "leading.txt")
  let lIf = hashOf(leadRead, "if (ok) {")
  let lRun = hashOf(leadRead, "  run();")
  failUnlessNoError(replaceTool(nc, "leading.txt", lIf, lRun,
                                @["before();", "if (ok) {", "  runSafe();"]),
                    "boundary-dup leading")
  check("boundary-dup strips duplicate leading block",
        readFile(tmp / "leading.txt") ==
          "before();\nif (ok) {\n  runSafe();\n}\nafter();\n",
        readFile(tmp / "leading.txt"))

  writeFile(tmp / "imports.txt",
            "import { A } from \"a\";\nimport { B } from \"b\";\n" &
            "import { C } from \"c\";\nimport { D } from \"d\";\n" &
            "export function main() {}\n")
  let impRead = readTool(nc, "imports.txt")
  let impA = hashOf(impRead, "import { A } from \"a\";")
  let impEdit = replaceTool(nc, "imports.txt", impA, impA, @[
    "import { B } from \"b\";", "import { C } from \"c\";",
    "import { D } from \"d\";", "type SessionEntry = { id: string };"])
  failUnlessNoError(impEdit, "boundary-dup import run")
  check("boundary-dup strips import run (added 1, removed 1)",
        impEdit{"summary"}.getStr("").contains("Added 1 line(s), removed 1 line(s)."),
        $impEdit)
  let impContent = readFile(tmp / "imports.txt")
  check("import run not duplicated",
        impContent.split("\n").filterIt(it.contains("import { B }")).len == 1 and
        impContent.contains("type SessionEntry = { id: string };"), impContent)

  writeFile(tmp / "prefix.txt", "a\nb\nc\ntarget\nafter\n")
  let prefRead = readTool(nc, "prefix.txt")
  let prefTarget = hashOf(prefRead, "target")
  let prefEdit = replaceTool(nc, "prefix.txt", prefTarget, prefTarget,
                             @["a", "b", "c", "X"])
  failUnlessNoError(prefEdit, "prefix copy not stripped")
  check("prefix copy kept (added 4, removed 1)",
        prefEdit{"summary"}.getStr("").contains("Added 4 line(s), removed 1 line(s)."),
        $prefEdit)
  check("prefix copy content",
        readFile(tmp / "prefix.txt") == "a\nb\nc\na\nb\nc\nX\nafter\n",
        readFile(tmp / "prefix.txt"))

  writeFile(tmp / "both.txt", "X\ntarget\nX\n")
  let bothRead = readTool(nc, "both.txt")
  let bothTarget = hashOf(bothRead, "target")
  let bothEdit = replaceTool(nc, "both.txt", bothTarget, bothTarget, @["X"])
  failUnlessNoError(bothEdit, "both-edges strip")
  check("both-edges line stripped exactly once (added 0, removed 1)",
        bothEdit{"summary"}.getStr("").contains("Added 0 line(s), removed 1 line(s)."),
        $bothEdit)
  check("both-edges content", readFile(tmp / "both.txt") == "X\nX\n")

  writeFile(tmp / "repeat.txt", "Y\nZ\nX\nY\nZ\n")
  let repRead = readTool(nc, "repeat.txt")
  let repX = hashOf(repRead, "X")
  failUnlessNoError(replaceTool(nc, "repeat.txt", repX, repX, @["X", "Y", "Z"]),
                    "repeat block not stripped")
  check("repeat block not stripped",
        readFile(tmp / "repeat.txt") == "Y\nZ\nX\nY\nZ\nY\nZ\n",
        readFile(tmp / "repeat.txt"))

  writeFile(tmp / "fourth.txt",
            "if (a) {\n  x();\n}\nif (b) {\n  y();\n}\nif (c) {\n  z();\n}\n" &
            "foo();\nbar();\n}\n")
  let fourRead = readTool(nc, "fourth.txt")
  let fourFoo = hashOf(fourRead, "foo();")
  let fourBar = hashOf(fourRead, "bar();")
  let fourEdit = replaceTool(nc, "fourth.txt", fourFoo, fourBar,
                             @["foo();", "bar();", "}"])
  failUnlessNoError(fourEdit, "4th } strip")
  check("4th } strip makes edit a noop",
        fourEdit{"summary"}.getStr("").contains("No changes made") and
        fourEdit{"summary"}.getStr("").contains("noop"), $fourEdit)
  check("4th } file unchanged",
        readFile(tmp / "fourth.txt") ==
          "if (a) {\n  x();\n}\nif (b) {\n  y();\n}\nif (c) {\n  z();\n}\n" &
          "foo();\nbar();\n}\n")

  # ------------------------------------------------------------------
  # served-state range verification
  writeFile(tmp / "served.txt", "a\nb\nc\nd\n")
  let sRead = readTool(nc, "served.txt")
  let sA = hashOf(sRead, "a")
  let sB = hashOf(sRead, "b")
  let sC = hashOf(sRead, "c")
  let sD = hashOf(sRead, "d")

  writeFile(tmp / "served.txt", "a\nB\nc\nd\n")
  let interior = replaceTool(nc, "served.txt", sA, sD, @["a", "x", "d"])
  check("interior modification refused with E_RANGE_STALE",
        interior{"error"}.getStr("").contains("[E_RANGE_STALE]") and
        interior{"error"}.getStr("").contains("Nothing was modified"),
        $interior)
  check("interior modification left file untouched",
        readFile(tmp / "served.txt") == "a\nB\nc\nd\n")
  let feedbackRows = allHashes(interior{"error"}.getStr(""))
  check("range-stale feedback carries 4 fresh anchors", feedbackRows.len == 4)
  check("range-stale feedback rows show current content",
        interior{"error"}.getStr("").contains("│B"))

  # retry with the fresh anchors from the feedback, no intervening read
  let retry = replaceTool(nc, "served.txt", feedbackRows[0], feedbackRows[3],
                          @["a", "x", "d"])
  failUnlessNoError(retry, "range-stale retry without read")
  check("range-stale retry applies", readFile(tmp / "served.txt") == "a\nx\nd\n")

  # stale-anchor feedback serves context rows; a copied context hash edits
  writeFile(tmp / "ctx.txt", "a\nb\nc\nd\n")
  let ctxRead = readTool(nc, "ctx.txt")
  let ctxA = hashOf(ctxRead, "a")
  let ctxD = hashOf(ctxRead, "d")
  writeFile(tmp / "ctx.txt", "A\nb\nC\nd\n")
  let ctxErr = replaceTool(nc, "ctx.txt", ctxA, ctxD, @["x"])
  check("stale anchor error with context",
        ctxErr{"error"}.getStr("").contains("[E_STALE_ANCHOR]") and
        ctxErr{"error"}.getStr("").contains("Current context around resolved anchor"),
        $ctxErr)
  var ctxC = ""
  for line in ctxErr{"error"}.getStr("").split("\n"):
    if line.contains("│C"):
      let parts = line.split(SEP)[0].strip().split(":")
      ctxC = parts[^1].strip()
      break
  check("context row carries the C hash", ctxC.len == 3, ctxErr{"error"}.getStr(""))
  let ctxEdit = replaceTool(nc, "ctx.txt", ctxC, ctxC, @["c"])
  failUnlessNoError(ctxEdit, "context hash edits immediately")
  check("context hash edit applied", readFile(tmp / "ctx.txt") == "A\nb\nc\nd\n")

  # out-of-range external modification tolerated
  writeFile(tmp / "out.txt", "a\nb\nc\nd\n")
  let outRead = readTool(nc, "out.txt")
  let outB = hashOf(outRead, "b")
  let outC = hashOf(outRead, "c")
  writeFile(tmp / "out.txt", "A\nb\nc\nd\n")
  failUnlessNoError(replaceTool(nc, "out.txt", outB, outC, @["x"]),
                    "out-of-range modification tolerated")
  check("out-of-range edit applied", readFile(tmp / "out.txt") == "A\nx\nd\n")

  # change-then-revert round-trip accepted
  writeFile(tmp / "revert.txt", "a\nb\nc\nd\n")
  let revRead2 = readTool(nc, "revert.txt")
  let rvA = hashOf(revRead2, "a")
  let rvD = hashOf(revRead2, "d")
  writeFile(tmp / "revert.txt", "a\nB\nc\nd\n")
  writeFile(tmp / "revert.txt", "a\nb\nc\nd\n")
  failUnlessNoError(replaceTool(nc, "revert.txt", rvA, rvD, @["a", "x", "d"]),
                    "change-then-revert accepted")
  check("change-then-revert applied", readFile(tmp / "revert.txt") == "a\nx\nd\n")

  # disjoint read windows: interior lines were never served
  writeFile(tmp / "disjoint.txt", "a\nb\nc\nd\ne\nf\n")
  let djW1 = readTool(nc, "disjoint.txt", offset = 1, limit = 2)
  let djW2 = readTool(nc, "disjoint.txt", offset = 5, limit = 2)
  let djA = hashOf(djW1, "a")
  let djF = hashOf(djW2, "f")
  let djErr = replaceTool(nc, "disjoint.txt", djA, djF, @["x"])
  check("disjoint windows refused with E_RANGE_STALE",
        djErr{"error"}.getStr("").contains("[E_RANGE_STALE]"), $djErr)
  check("disjoint windows left file untouched",
        readFile(tmp / "disjoint.txt") == "a\nb\nc\nd\ne\nf\n")

  # applies within a served window while others never served
  let winRead = readTool(nc, "disjoint.txt", offset = 1, limit = 2)
  let wA = hashOf(winRead, "a")
  let wB = hashOf(winRead, "b")
  failUnlessNoError(replaceTool(nc, "disjoint.txt", wA, wB, @["x"]),
                    "within-window edit applies")
  check("within-window edit applied",
        readFile(tmp / "disjoint.txt") == "x\nc\nd\ne\nf\n")

  # never-served file: applies without verification (hashes learned from a
  # file with identical content — anchors are content-deterministic)
  writeFile(tmp / "never.txt", "a\nb\nc\n")
  writeFile(tmp / "twin.txt", "a\nb\nc\n")
  let twinRead = readTool(nc, "twin.txt")
  let nA = hashOf(twinRead, "a")
  failUnlessNoError(replaceTool(nc, "never.txt", nA, nA, @["A"]),
                    "never-served file applies")
  check("never-served edit applied", readFile(tmp / "never.txt") == "A\nb\nc\n")

  # ------------------------------------------------------------------
  # undo_last_replace
  writeFile(tmp / "undo.txt", "aaa\nbbb\nccc\n")
  let noHistory = undoTool(nc, "undo.txt")
  check("undo without history errors",
        noHistory{"error"}.getStr("").toLowerAscii().contains("no undo history"),
        $noHistory)

  let uRead = readTool(nc, "undo.txt")
  let uBbb = hashOf(uRead, "bbb")
  failUnlessNoError(replaceTool(nc, "undo.txt", uBbb, uBbb, @["BBB"]),
                    "undo setup edit")
  check("undo setup content", readFile(tmp / "undo.txt") == "aaa\nBBB\nccc\n")
  let undone = undoTool(nc, "undo.txt")
  failUnlessNoError(undone, "undo restores content")
  check("undo restores content", readFile(tmp / "undo.txt") == "aaa\nbbb\nccc\n")
  check("undo summary", undone{"summary"}.getStr("").contains("Undone last replace"),
        $undone)
  check("undo diff carries restored anchors", undone{"diff"}.getStr("").contains("│bbb"),
        $undone)

  # undo with the file_path alias
  failUnlessNoError(replaceTool(nc, "undo.txt", uBbb, uBbb, @["BBB"]),
                    "alias setup edit")
  let aliasUndo = call(nc, "hashline-edit", "undo_last_replace",
                       %*{"file_path": "undo.txt"})
  failUnlessNoError(aliasUndo, "undo with file_path alias")
  check("alias undo applied", readFile(tmp / "undo.txt") == "aaa\nbbb\nccc\n")

  # undo line counts: addition, deletion, mixed
  writeFile(tmp / "counts.txt", "aaa\nccc\n")
  let cRead = readTool(nc, "counts.txt")
  let cCcc = hashOf(cRead, "ccc")
  failUnlessNoError(replaceTool(nc, "counts.txt", cCcc, cCcc,
                                @["BBB", "B2"]), "counts addition edit")
  let addUndo = undoTool(nc, "counts.txt")
  check("undo counts an addition",
        addUndo{"summary"}.getStr("").contains("Removed 2 line(s) that were added") and
        addUndo{"summary"}.getStr("").contains("restored 1 line(s) that were removed."),
        $addUndo)

  writeFile(tmp / "counts2.txt", "aaa\nbbb\nccc\n")
  let c2Read = readTool(nc, "counts2.txt")
  let c2Bbb = hashOf(c2Read, "bbb")
  failUnlessNoError(replaceTool(nc, "counts2.txt", c2Bbb, c2Bbb, @[]),
                    "counts deletion edit")
  let delUndo = undoTool(nc, "counts2.txt")
  check("undo counts a deletion",
        delUndo{"summary"}.getStr("").contains("Removed 0 line(s) that were added") and
        delUndo{"summary"}.getStr("").contains("restored 1 line(s) that were removed."),
        $delUndo)

  writeFile(tmp / "counts3.txt", "aaa\nbbb\nccc\n")
  let c3Read = readTool(nc, "counts3.txt")
  let c3Bbb = hashOf(c3Read, "bbb")
  let c3Ccc = hashOf(c3Read, "ccc")
  failUnlessNoError(replaceTool(nc, "counts3.txt", c3Bbb, c3Ccc,
                                @["XXX", "YYY", "ZZZ"]), "counts mixed edit")
  let mixUndo = undoTool(nc, "counts3.txt")
  check("undo counts a mixed replace",
        mixUndo{"summary"}.getStr("").contains("Removed 3 line(s) that were added") and
        mixUndo{"summary"}.getStr("").contains("restored 2 line(s) that were removed."),
        $mixUndo)

  # undo is refused when the file was modified after the replace
  writeFile(tmp / "staleundo.txt", "aaa\nbbb\nccc\n")
  let suRead = readTool(nc, "staleundo.txt")
  let suBbb = hashOf(suRead, "bbb")
  failUnlessNoError(replaceTool(nc, "staleundo.txt", suBbb, suBbb, @["BBB"]),
                    "stale-undo setup edit")
  writeFile(tmp / "staleundo.txt", "aaa\nBBB\nCHANGED\n")
  let suUndo = undoTool(nc, "staleundo.txt")
  check("undo refused when file modified",
        suUndo{"error"}.getStr("").contains("[E_UNDO_STALE]"), $suUndo)
  let suUndo2 = undoTool(nc, "staleundo.txt")
  check("refused undo clears history",
        suUndo2{"error"}.getStr("").toLowerAscii().contains("no undo history"),
        $suUndo2)

  # undo survives a component restart (persisted store)
  writeFile(tmp / "persist.txt", "aaa\nbbb\nccc\n")
  let pRead = readTool(nc, "persist.txt")
  let pBbb = hashOf(pRead, "bbb")
  failUnlessNoError(replaceTool(nc, "persist.txt", pBbb, pBbb, @["BBB"]),
                    "persist setup edit")
  let pReadPost = readTool(nc, "persist.txt")
  let pHashes = allHashes(pReadPost)
  restartComponent()
  let pRead2 = readTool(nc, "persist.txt")
  check("hashes stable across restart", allHashes(pRead2) == pHashes,
        $allHashes(pRead2))
  let pUndo = undoTool(nc, "persist.txt")
  failUnlessNoError(pUndo, "undo survives restart")
  check("undo after restart applied", readFile(tmp / "persist.txt") == "aaa\nbbb\nccc\n")

  # re-edit with original anchors after undo (undo diff rows are served)
  let pRead3 = readTool(nc, "persist.txt")
  let pBbb2 = hashOf(pRead3, "bbb")
  failUnlessNoError(replaceTool(nc, "persist.txt", pBbb2, pBbb2, @["BBB"]),
                    "re-edit after undo")
  check("re-edit after undo applied",
        readFile(tmp / "persist.txt") == "aaa\nBBB\nccc\n")

  report("t_hashline")

main()
