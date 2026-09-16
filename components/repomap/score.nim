## The repo map's scoring core — the direct port of aider's
## get_ranked_tags (docs/research/REPOMAP.md, Apache-2.0): per-identifier
## define/reference sets, a file→file reference graph with aider's weight
## heuristics, personalized PageRank (hand-rolled power iteration — the
## graph is small), and rank distribution onto definitions.
##
## Deterministic by construction: files sorted, ident iteration sorted,
## accumulation in edge order, stable tie-breaks. Same inputs →
## byte-identical output (the cache doctrine's requirement).
##
## Zero-based rows/columns; the caller supplies tags via a callback so this
## module never parses and never caches (the component owns both).

import std/[algorithm, sets, math, sequtils, strutils, tables]
import tags

type
  ScoreOptions* = object
    focus*: seq[string]         # rel paths "in the conversation" (aider's chat files)
    mentionedIdents*: seq[string]
    mentionedFiles*: seq[string]
    budgetTokens*: int          # map budget; the render binary-searches it

  RankedTag* = object
    rel*: string
    line*: int                  # -1 = bare file entry (no tags included)
    col*: int
    name*: string               # empty for bare entries
    symKind*: string

  RankFailure* = object of CatchableError

proc isSnakeish(ident: string): bool =
  ## snake_case / kebab-case / CamelCase idents of real length are
  ## intentional names, not noise — aider's x10 weight.
  if ident.len < 8: return false
  var hasAlpha = false
  for c in ident:
    if c.isAlphaAscii(): hasAlpha = true
  if not hasAlpha: return false
  if ('_' in ident) or ('-' in ident): return true
  var hasUpper, hasLower = false
  for c in ident:
    if c.isUpperAscii(): hasUpper = true
    if c.isLowerAscii(): hasLower = true
  hasUpper and hasLower

proc normalized(vec: var seq[float]): bool =
  ## normalize in place; false when all-zero (caller falls back to uniform)
  var sum = 0.0
  for v in vec: sum += v
  if sum <= 0.0: return false
  for i in 0 ..< vec.len: vec[i] = vec[i] / sum
  true

type Edge* = tuple[src, dst: int, w: float, ident: string]

proc pagerank(n: int, edges: seq[Edge], pers: seq[float]): seq[float] =
  ## Power iteration, networkx defaults: alpha 0.85, dangling mass
  ## distributed per the personalization vector. Edges iterated in build
  ## order; convergence 1e-8, capped at 100 iterations.
  const alpha = 0.85
  var outW = newSeq[float](n)
  for e in edges: outW[e.src] += e.w
  var persN = pers
  if not persN.normalized():
    persN = newSeq[float](n)
    for i in 0 ..< n: persN[i] = 1.0 / n.float
  var x = persN
  for iter in 0 ..< 100:
    var danglingSum = 0.0
    for v in 0 ..< n:
      if outW[v] == 0.0: danglingSum += x[v]
    var xNew = newSeq[float](n)
    for u in 0 ..< n:
      xNew[u] = (1.0 - alpha) * persN[u] + alpha * danglingSum * persN[u]
    for e in edges:
      xNew[e.dst] += alpha * x[e.src] * e.w / outW[e.src]
    var delta = 0.0
    for u in 0 ..< n:
      let d = abs(xNew[u] - x[u])
      if d > delta: delta = d
    x = xNew
    if delta < 1e-8: break
  return x

proc rankedTags*(files: seq[string], opts: ScoreOptions,
                 tagsOf: proc(rel: string): seq[Tag]): seq[RankedTag] =
  ## The ranked selection: def tags in rank order (focus files excluded —
  ## the conversation already has them), then high-rank files without
  ## included tags as bare entries, then files the graph never touched,
  ## then (caller-side) special files.
  let filesSorted = sorted(files)
  if filesSorted.len == 0: return
  let personalize = 100.0 / filesSorted.len.float

  var defines = initTable[string, seq[string]]()    # ident -> defining files
  var references = initTable[string, seq[string]]() # ident -> referencing files
  var definitions = initTable[tuple[rel, ident: string], seq[Tag]]()
  var focusSet = toHashSet(opts.focus)
  var mentionSet = toHashSet(opts.mentionedIdents)
  var mentionedFileSet = toHashSet(opts.mentionedFiles)
  var personalization = initTable[string, float]()

  for rel in filesSorted:
    var pers = 0.0
    if rel in focusSet: pers += personalize
    if rel in mentionedFileSet: pers = max(pers, personalize)
    # path components matching a mentioned ident add once more
    for part in rel.split({'/', '\\'}):
      if part.len > 0 and part in mentionSet:
        pers += personalize
        break
    if pers > 0: personalization[rel] = pers
    for tag in tagsOf(rel):
      if tag.kind == kDef:
        if not defines.hasKey(tag.name): defines[tag.name] = @[]
        if rel notin defines[tag.name]: defines[tag.name].add(rel)
        let key = (rel, tag.name)
        if not definitions.hasKey(key): definitions[key] = @[]
        definitions[key].add(tag)
      else:
        if not references.hasKey(tag.name): references[tag.name] = @[]
        references[tag.name].add(rel)

  if references.len == 0:
    # nothing references anything: let every definition stand on its own
    for ident, rels in defines:
      references[ident] = rels

  # node set: every file that ever appears as referencer or definer
  var nodeIdx = initTable[string, int]()
  var nodes: seq[string]
  proc nodeFor(rel: string): int =
    if nodeIdx.hasKey(rel): return nodeIdx[rel]
    let idx = nodes.len
    nodeIdx[rel] = idx
    nodes.add(rel)
    idx

  var edges: seq[Edge]

  # small self-edge so unreferenced definitions still enter the graph
  for ident in defines.keys:
    if references.hasKey(ident): continue
    for definer in defines[ident]:
      edges.add((nodeFor(definer), nodeFor(definer), 0.1, ident))

  let idents = sorted(toSeq(defines.keys).toHashSet().toSeq())
  for ident in idents:
    if not references.hasKey(ident): continue
    var mul = 1.0
    if ident in mentionSet: mul *= 10.0
    if isSnakeish(ident): mul *= 10.0
    if ident.startsWith("_"): mul *= 0.1
    if defines[ident].len > 5: mul *= 0.1
    # occurrences per referencing file
    var counts = initCountTable[string]()
    for rel in references[ident]: counts.inc(rel)
    counts.sort()
    for referencer, numRefs in counts:
      for definer in defines[ident]:
        var useMul = mul
        if referencer in focusSet: useMul *= 50.0
        edges.add((nodeFor(referencer), nodeFor(definer),
                   useMul * sqrt(numRefs.float), ident))

  if edges.len == 0: return

  var persVec = newSeq[float](nodes.len)
  for rel, p in personalization:
    if nodeIdx.hasKey(rel): persVec[nodeIdx[rel]] = p

  let rank = pagerank(nodes.len, edges, persVec)

  # distribute each node's rank across its out-edges, onto definitions
  var rankedDefinitions: seq[tuple[rel, ident: string, rank: float]]
  var outTotal = newSeq[float](nodes.len)
  for e in edges: outTotal[e.src] += e.w
  # distribute each node's rank across its out-edges, onto definitions.
  # One pass over the edges (O(E)): the per-node out-total is precomputed,
  # so no inner scan over the edge list is needed. The previous
  # O(nodes × edges) form was the multimillion-iteration hot spot on big
  # repos (rubocop: 1551 files, ~200k edges → 71s of pure loop).
  var accum = initTable[tuple[rel, ident: string], float]()
  for e in edges:
    let total = outTotal[e.src]
    if total == 0.0: continue
    let r = rank[e.src] * e.w / total
    let key = (nodes[e.dst], e.ident)
    if accum.hasKey(key): accum[key] += r
    else: accum[key] = r
  for key, r in accum:
    rankedDefinitions.add((key[0], key[1], r))
  rankedDefinitions.sort() do (a, b: tuple[rel, ident: string, rank: float]) -> int:
    # rank desc, then rel asc, then ident asc — stable and byte-identical
    if a.rank != b.rank: return cmp(b.rank, a.rank)
    if a.rel != b.rel: return cmp(a.rel, b.rel)
    cmp(a.ident, b.ident)

  var included = initHashSet[string]()
  for (rel, ident, _) in rankedDefinitions:
    if rel in focusSet: continue
    included.incl(rel)
    if definitions.hasKey((rel, ident)):
      for tag in definitions[(rel, ident)]:
        result.add(RankedTag(rel: rel, line: tag.line, col: tag.col,
                             name: tag.name, symKind: tag.symKind))

  # top-ranked files without included tags, then the untouched rest
  var byRank: seq[tuple[rank: float, rel: string]]
  for i, r in rank: byRank.add((r, nodes[i]))
  byRank.sort() do (a, b: tuple[rank: float, rel: string]) -> int:
    if a.rank != b.rank: return cmp(b.rank, a.rank)
    cmp(a.rel, b.rel)
  for (_, rel) in byRank:
    if rel notin included:
      included.incl(rel)
      result.add(RankedTag(rel: rel, line: -1, col: -1))
  for rel in filesSorted:
    if rel notin included:
      result.add(RankedTag(rel: rel, line: -1, col: -1))
