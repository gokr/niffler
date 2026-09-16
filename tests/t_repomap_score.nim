## repomap scoring tests — graph weights, personalized PageRank, rank
## distribution, budget binary search, determinism. Tags are hand-built so
## the scoring core is tested independently of the taggers.

import std/[strutils, tables]
import helpers
import ../components/repomap/tags
import ../components/repomap/score
import ../components/repomap/repomap

proc tag(rel, name: string, line: int, kind: TagKind, symKind = "function"): Tag =
  Tag(relFname: rel, fname: rel, line: line, col: 0, name: name,
      kind: kind, symKind: symKind)

const files = [
  "app.nim", "core/config.nim", "core/engine.nim", "docs/readme.md",
  "orphan.nim", "util/logger.nim"]

proc makeTagsOf(focus: seq[string]): auto =
  var table = {
    "app.nim": @[
      tag("app.nim", "main", 4, kDef, "proc"),
      tag("app.nim", "runEngine", 8, kRef),
      tag("app.nim", "logLine", 12, kRef)],
    "core/config.nim": @[
      tag("core/config.nim", "parseConfig", 2, kDef, "proc"),
      tag("core/config.nim", "runEngine", 6, kRef),
      tag("core/config.nim", "logLine", 9, kRef)],
    "core/engine.nim": @[
      tag("core/engine.nim", "runEngine", 10, kDef, "proc"),
      tag("core/engine.nim", "parseConfig", 14, kRef),
      tag("core/engine.nim", "logLine", 20, kRef)],
    "util/logger.nim": @[
      tag("util/logger.nim", "logLine", 1, kDef, "proc")],
    "orphan.nim": @[tag("orphan.nim", "orphanFn", 0, kDef, "proc")],
    "docs/readme.md": @[],
  }.toTable
  result = proc(rel: string): seq[Tag] =
    if table.hasKey(rel): return table[rel]
    @[]

proc main() =
  let tagsOf = makeTagsOf(@[])

  # --- determinism ---------------------------------------------------------
  let opts = ScoreOptions(budgetTokens: 1024)
  let m1 = buildMap(@files, opts, tagsOf)
  let m2 = buildMap(@files, opts, tagsOf)
  check("map is deterministic for identical inputs", m1 == m2 and m1.len > 0, m1)

  # --- full-budget contents ------------------------------------------------
  check("defs from unfocused files appear",
        m1.contains("runEngine") and m1.contains("parseConfig") and
        m1.contains("logLine") and m1.contains("orphanFn"), m1)
  check("bare files render as paths", m1.contains("docs/readme.md") and
        m1.contains("util/logger.nim"), m1)
  check("render is one line per tag under a file heading",
        m1.contains("core/engine.nim:") and
        m1.contains("11:1  proc  runEngine"), m1)

  # --- focus excludes the conversation's own defs --------------------------
  let focused = buildMap(@files, ScoreOptions(budgetTokens: 1024,
      focus: @["app.nim"]), tagsOf)
  check("focus file's own defs are dropped",
        not focused.contains("main\n") and focused.contains("runEngine"),
        focused)

  # --- mentioned idents + focus edges move the ranking ---------------------
  # tight budget: only the top definition(s) survive. parseConfig is
  # boosted twice — mentionedIdents x10 and the focus-file referencer x50
  # (on top of the camelCase >=8ch x10) — so it outranks the self-edged
  # orphanFn and the x1-weight logLine.
  let tight = buildMap(@files, ScoreOptions(budgetTokens: 20,
      focus: @["app.nim"], mentionedIdents: @["parseConfig"]), tagsOf)
  check("boosted ident wins the tight budget",
        tight.contains("parseConfig"), tight)
  check("unboosted defs lose the tight budget",
        not tight.contains("orphanFn") and not tight.contains("logLine"), tight)
  check("tight budget respects the cap",
        tight.len > 0 and estTokens(tight) <= 23, $estTokens(tight) & "\n" & tight)

  # --- zero budget is an empty map -----------------------------------------
  check("zero budget maps nothing",
        buildMap(@files, ScoreOptions(budgetTokens: 0), tagsOf) == "")

  # --- countRendered (the append gates' input) ------------------------------
  # Counted from the rendered text the model would receive: symbol rows are
  # "  <line>:<col>  <kind>  <name>", file headings are unindented.
  block:
    let (syms, files) = countRendered(m1)
    check("countRendered counts symbol rows", syms == 5, $syms & "\n" & m1)
    check("countRendered counts symbol-bearing files", files == 5,
          $files & "\n" & m1)
    check("bare special-file entries are not symbol files",
          countRendered("docs/readme.md\n").files == 0,
          $countRendered("docs/readme.md\n"))
    check("empty text counts zero",
          countRendered("") == (0, 0))

  # --- buildMapStats matches buildMap --------------------------------------
  block:
    let st = buildMapStats(@files, opts, tagsOf)
    check("buildMapStats text is buildMap's", st.text == m1)
    check("buildMapStats carries the counts", st.symbols == 5 and st.files == 5,
          $st.symbols & "/" & $st.files)

  report("REPOMAP SCORE")

main()
