## repomap tags-seam tests — tree-sitter tier (go/python/typescript) and the
## native Nim tier against known fixtures. Unit-level: no bus, no component.
## Asserts defs (name + zero-based row) and the refs the graph needs.

import std/[os, strutils]
import helpers
import ../components/repomap/tags

proc hasDef(t: seq[Tag], rowName: string): bool =
  ## rowName = "8 resolveBinIn" — zero-based row + name
  let sp = rowName.find(' ')
  let row = rowName[0 ..< sp].parseInt()
  let name = rowName[sp + 1 ..< rowName.len]
  for tag in t:
    if tag.kind == kDef and tag.name == name and tag.line == row:
      return true

proc hasRef(t: seq[Tag], name: string): bool =
  for tag in t:
    if tag.kind == kRef and tag.name == name: return true

proc defList(t: seq[Tag]): string =
  for tag in t:
    if tag.kind == kDef:
      result.add($tag.line & " " & tag.name & "\n")

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let fx = root / "tests" / "fixtures" / "repomap"

  # --- native Nim tier -----------------------------------------------------
  let nt = extractTags("sample.nim", "sample.nim", readFile(fx / "sample.nim"))
  check("nim: const def at its zero-based row", hasDef(nt, "2 maxRetries"),
        defList(nt))
  check("nim: let def", hasDef(nt, "3 cachePath"), defList(nt))
  check("nim: proc def", hasDef(nt, "8 resolveBinIn"), defList(nt))
  check("nim: type-section def", hasDef(nt, "15 ServerConf"), defList(nt))
  check("nim: proc at any indent", hasDef(nt, "18 handle"), defList(nt))
  check("nim: backticked proc", hasDef(nt, "21 +"), defList(nt))
  check("nim: refs include defined symbol", hasRef(nt, "resolveBinIn"))
  check("nim: refs include ordinary idents", hasRef(nt, "fileExists"))
  check("nim: keywords are not refs", not hasRef(nt, "proc") and
        not hasRef(nt, "iterator"))

  # --- tree-sitter: python (aider query, name.definition convention) -------
  let pt = extractTags("sample.py", "sample.py", readFile(fx / "sample.py"))
  check("py: class def", hasDef(pt, "0 ReportBuilder"), defList(pt))
  check("py: method def", hasDef(pt, "1 build"), defList(pt))
  check("py: function def", hasDef(pt, "4 parse_config"), defList(pt))
  check("py: call refs", hasRef(pt, "ReportBuilder") and
        hasRef(pt, "build") and hasRef(pt, "parse_config"))

  # --- tree-sitter: go (aider query) ----------------------------------------
  let gt = extractTags("sample.go", "sample.go", readFile(fx / "sample.go"))
  check("go: type def", hasDef(gt, "2 Server"), defList(gt))
  check("go: func def", hasDef(gt, "6 NewServer"), defList(gt))
  check("go: method def", hasDef(gt, "10 Start"), defList(gt))
  check("go: call refs incl selector field", hasRef(gt, "NewServer") and
        hasRef(gt, "Start"))

  # --- tree-sitter: typescript (upstream query + concrete additions) --------
  let st = extractTags("sample.ts", "sample.ts", readFile(fx / "sample.ts"))
  check("ts: function def", hasDef(st, "0 buildIndex"), defList(st))
  check("ts: variable def", hasDef(st, "4 defaultLimit"), defList(st))
  check("ts: interface def", hasDef(st, "6 Row"), defList(st))
  check("ts: class def", hasDef(st, "10 Indexer"), defList(st))
  check("ts: method defs", hasDef(st, "11 crawl") and
        hasDef(st, "12 fetchAll"), defList(st))
  check("ts: refs (new + call)", hasRef(st, "Indexer") and
        hasRef(st, "buildIndex"))

  report("REPOMAP TAGS")

main()
