## The repo map renderer — budgeted, deterministic (docs/research/REPOMAP.md).
## Aider's shape: selection by rank, display grouped per file (sorted), token
## budget found by binary search over the number of included tags. v1 renders
## our one-line outline style (`rel:line:col  symKind  name`) instead of
## aider's TreeContext source snippets — 10x smaller, consistent with the
## lsp documentSymbol output. Token estimate is chars/4: deterministic and
## honest enough for a budget that is itself a heuristic.

import std/[algorithm, sets, strutils, tables]
import tags, score

const
  SPECIAL_FILES = [
    "README", "README.md", "README.txt", "README.rst",
    "CONTRIBUTING", "CONTRIBUTING.md", "LICENSE", "LICENSE.md",
    "CHANGELOG", "CHANGELOG.md", "SECURITY.md", "CODEOWNERS",
    "Makefile", "AGENTS.md", "CLAUDE.md",
    "package.json", "Cargo.toml", "go.mod", "go.sum",
    "pyproject.toml", "requirements.txt", "Gemfile",
    "nim.cfg", "config.nims"]

proc isSpecial(rel: string): bool =
  let base = rel.split({'/', '\\'})[^1]
  SPECIAL_FILES.contains(base)

proc estTokens*(s: string): int =
  (s.len + 3) div 4

proc renderMap*(ranked: seq[RankedTag]): string =
  ## Selection order is the rank order; display re-sorts per file (aider
  ## does the same — the map shows a repo's files alphabetically, the rank
  ## only decides what gets in). Focus-file tags are excluded by score;
  ## bare entries render as the path alone.
  var display = ranked
  display.sort() do (a, b: RankedTag) -> int:
    if a.rel != b.rel: return cmp(a.rel, b.rel)
    if a.line != b.line: return cmp(a.line, b.line)
    cmp(a.name, b.name)
  var outp = ""
  var curRel = ""
  var open = false
  var lastKey = ""
  for t in display:
    # the go query captures a struct twice (type_spec + the
    # struct-specific pattern) — identical (file,line,col,name) renders once
    let key = t.rel & ":" & $t.line & ":" & $t.col & ":" & t.name
    if key == lastKey: continue
    lastKey = key
    if t.rel != curRel:
      if open: outp.add("\n")
      outp.add(t.rel)
      open = true
      curRel = t.rel
      if t.line >= 0: outp.add(":")
    if t.line >= 0:
      outp.add("\n  " & $(t.line + 1) & ":" & $(t.col + 1) &
               "  " & t.symKind & "  " & t.name)
  if outp.len > 0: outp.add("\n")
  # truncate long lines (minified js and friends)
  var trimmed: seq[string]
  for line in outp.splitLines():
    trimmed.add(if line.len > 100: line[0 ..< 100] else: line)
  trimmed.join("\n") & "\n"

proc buildMap*(files: seq[string], opts: ScoreOptions,
               tagsOf: proc(rel: string): seq[Tag]): string =
  ## Ranked selection + special files + binary-searched budget.
  ## Returns "" when there is nothing to map.
  if files.len == 0 or opts.budgetTokens <= 0: return ""
  let ranked0 = rankedTags(files, opts, tagsOf)
  if ranked0.len == 0: return ""

  var ranked: seq[RankedTag]
  var seen = initHashSet[string]()
  for r in ranked0: seen.incl(r.rel)

  # special files first (they survive budget cuts longest)
  var specials: seq[RankedTag]
  for f in files:
    if isSpecial(f) and f notin seen:
      specials.add(RankedTag(rel: f, line: -1, col: -1))
      seen.incl(f)
  ranked = specials & ranked0

  let budget = opts.budgetTokens
  var lo, hi = 0
  hi = ranked.len
  var best = ""
  var bestTokens = 0
  var middle = min(budget div 25, ranked.len)
  while lo <= hi:
    let tree = renderMap(ranked[0 ..< middle])
    let toks = estTokens(tree)
    let pctErr = abs(toks - budget).float / budget.float
    if (toks <= budget and toks > bestTokens) or pctErr < 0.15:
      best = tree
      bestTokens = toks
      if pctErr < 0.15: break
    if toks < budget: lo = middle + 1
    else: hi = middle - 1
    if lo > hi: break
    middle = (lo + hi) div 2
  return best

type
  MapStats* = object
    ## A built map plus the counts the append's admission gates need
    ## (docs/research/REPOMAP-GATES.md). Counted from the rendered text —
    ## the artifact the model would receive — so dedup/trim are included.
    text*: string
    symbols*: int    # rendered symbol rows (defs+refs, post-dedup)
    files*: int      # files with at least one rendered symbol

proc isSymbolRow(row: string): bool =
  ## "<line>:<col>  <symKind>  <name>" — the renderer's symbol shape.
  ## The caller passes the line stripped of its two-space indent.
  var i = 0
  while i < row.len and row[i].isDigit: inc i
  if i == 0 or i >= row.len or row[i] != ':': return false
  inc i
  let d0 = i
  while i < row.len and row[i].isDigit: inc i
  i > d0 and i < row.len and row[i] == ' '

proc countRendered*(text: string): tuple[symbols, files: int] =
  ## Count symbol rows and symbol-bearing files in a rendered map. File
  ## headings are the lines not starting with a space; bare special-file
  ## entries (a heading with no rows under it) do not count as files.
  var curHas = false
  var inFile = false
  for raw in text.splitLines():
    if raw.len == 0: continue
    if raw[0] != ' ':
      if inFile and curHas: result.files.inc
      inFile = true
      curHas = false
    elif isSymbolRow(raw.strip()):
      result.symbols.inc
      curHas = true
  if inFile and curHas: result.files.inc

proc buildMapStats*(files: seq[string], opts: ScoreOptions,
                    tagsOf: proc(rel: string): seq[Tag]): MapStats =
  ## buildMap plus the gate counts.
  result.text = buildMap(files, opts, tagsOf)
  let (s, f) = countRendered(result.text)
  result.symbols = s
  result.files = f
