## The tags seam — per-file definitions and references, the input the
## repo map's graph is built from (docs/research/REPOMAP.md). This is the
## provider side of the orientation contract: adding a language is a
## grammar + a tags query + one registry line here, never a core edit.
##
## Tiers (Reasonix-style, weakest last):
## - tree-sitter: go, python, typescript (vendored C in csrc/, queries in
##   queries/ — aider's Apache-2.0 queries for go/python, upstream's for
##   typescript; both capture conventions are classified below)
## - native Nim tagger: .nim/.nims defs are line-regular; the alaviss
##   grammar's generated parser.c is 40 MB — too heavy to vendor (the seam
##   exists precisely so a slimmer grammar can drop in later)
## - everything else: empty for now (regex floor is a later step)
##
## Rows are zero-based throughout; renderers convert at the model boundary.

import std/[os, sets, strutils, tables]
import ts

type
  TagKind* = enum kDef, kRef
  Tag* = object
    relFname*: string
    fname*: string
    line*: int          # zero-based; -1 for refs without a meaningful row
    col*: int           # zero-based column of the name; -1 when unknown
    name*: string
    kind*: TagKind
    symKind*: string    # def tags: function/method/class/type/const/proc/...

const LANGUAGE_VERSION_MAX = 15  # ts_parser_set_language rejects ABI mismatch

# ---------------------------------------------------------------------------
# tree-sitter tier

proc queriesDir*(): string =
  ## components/repomap/queries — found relative to the binary (var/bin is a
  ## child of the repo root), falling back to the current directory.
  for base in [getAppDir().parentDir(), getCurrentDir()]:
    let dir = base / "components" / "repomap" / "queries"
    if dirExists(dir): return dir
  raise newException(IOError, "repomap queries dir not found")

type Grammar = tuple[lang: ptr TsLanguage, query: string]

var grammarCache = initTable[string, Grammar]()

proc grammarFor(ext: string): Grammar =
  ## Lazy: the language pointer + query text, once per extension.
  if grammarCache.hasKey(ext): return grammarCache[ext]
  let lang = case ext
    of ".go": tree_sitter_go()
    of ".py": tree_sitter_python()
    of ".ts": tree_sitter_typescript()
    else: nil
  if lang == nil:
    grammarCache[ext] = ((ptr TsLanguage)(nil), "")
    return grammarCache[ext]
  let qname = case ext
    of ".go": "go-tags.scm"
    of ".py": "python-tags.scm"
    else: "typescript-tags.scm"
  let g: Grammar = (lang, readFile(queriesDir() / qname))
  grammarCache[ext] = g
  g

proc classify(q: ptr TsQuery, captures: seq[TsQueryCapture]):
    tuple[kind: TagKind, node: TsNode, symKind: string] =
  ## Both capture conventions:
  ## - aider/language-pack: "name.definition.function" / "name.reference.call"
  ##   carry the identifier node themselves
  ## - upstream tags.scm: "name" carries the identifier, a sibling
  ##   "definition.*" / "reference.*" capture marks the kind
  var nameNode: TsNode
  for c in captures:
    let cn = q.captureName(c.index)
    if cn.startsWith("name.definition."):
      return (kDef, c.node, cn["name.definition.".len ..< cn.len])
    if cn.startsWith("name.reference."):
      return (kRef, c.node, cn["name.reference.".len ..< cn.len])
    if cn == "name":
      nameNode = c.node
  for c in captures:
    let cn = q.captureName(c.index)
    if nameNode.id != nil and cn.startsWith("definition."):
      return (kDef, nameNode, cn["definition.".len ..< cn.len])
    if nameNode.id != nil and cn.startsWith("reference."):
      return (kRef, nameNode, cn["reference.".len ..< cn.len])
  (kDef, TsNode(), "")  # no recognizable pair — caller skips on null id

proc leadingIdent(s: string): string =
  for ch in s:
    if ch.isAlphaNumeric() or ch == '_': result.add(ch)
    else: break

proc extractTsTags(ext, source, fname, relFname: string): seq[Tag] =
  let (lang, qtext) = grammarFor(ext)
  if lang == nil or qtext.len == 0: return
  var parser = ts_parser_new()
  defer: parser.ts_parser_delete()
  if not parser.ts_parser_set_language(lang):
    raise newException(ValueError,
      "tree-sitter ABI mismatch for " & ext & " (runtime supports up to v" &
      $LANGUAGE_VERSION_MAX & ")")
  let tree = parser.ts_parser_parse_string(nil, source.cstring, source.len.uint32)
  if tree == nil: return
  defer: tree.ts_tree_delete()
  var q = tsQuery(lang, qtext)
  defer: q.ts_query_delete()
  var cursor = ts_query_cursor_new()
  defer: cursor.ts_query_cursor_delete()
  cursor.ts_query_cursor_exec(q, tree.ts_tree_root_node())
  var m: TsQueryMatch
  while cursor.ts_query_cursor_next_match(addr m):
    if m.captureCount == 0: continue
    var caps: seq[TsQueryCapture]
    for i in 0 ..< m.captureCount.int:
      caps.add(m.captures[i])
    let (kind, node, symKind) = classify(q, caps)
    if node.id == nil: continue
    let name = node.nodeText(source)
    if name.len == 0: continue
    result.add(Tag(relFname: relFname, fname: fname,
                   line: node.ts_node_start_point().row.int,
                   col: node.ts_node_start_point().column.int,
                   name: name, kind: kind, symKind: symKind))

# ---------------------------------------------------------------------------
# native Nim tier (.nim/.nims — the 40 MB grammar problem, regex'd instead)

const nimKeywords = toHashSet([
  "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept",
  "const", "continue", "converter", "defer", "discard", "distinct", "div",
  "do", "elif", "else", "end", "enum", "except", "export", "finally", "for",
  "from", "func", "if", "import", "include", "interface", "is", "isnot",
  "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
  "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
  "return", "shl", "shr", "static", "template", "try", "tuple", "type",
  "using", "var", "when", "while", "xor", "yield"])

proc extractNimTags(source, fname, relFname: string): seq[Tag] =
  ## Defs: routine declarations (any indent — methods matter), module-level
  ## type/const/let, type-section entries. Refs: every non-keyword
  ## identifier (the aider pygments-backfill equivalent — the graph
  ## intersects refs with defines, so over-emission is harmless,
  ## under-emission loses edges).
  let lines = source.splitLines()
  for i in 0 ..< lines.len:
    let line = lines[i]
    var indent = 0
    while indent < line.len and line[indent] == ' ': inc indent
    if indent == line.len: continue
    let body = line[indent ..< line.len]
    var name = ""
    var symKind = ""
    for kw in ["proc", "func", "method", "iterator", "macro", "template",
               "converter"]:
      if body.startsWith(kw & " "):
        let rest = body[(kw.len + 1) ..< body.len]
        symKind = kw
        name = if rest.startsWith("`"):
          let tick = rest.find('\x60', 1)
          (if tick > 1: rest[1 ..< tick] else: "")
        else: leadingIdent(rest)
        break
    if name.len == 0 and indent <= 2 and body.startsWith("type "):
      symKind = "type"
      name = leadingIdent(body[5 ..< body.len])
    if name.len == 0 and indent <= 8 and '=' in body:
      # "Name* = object" / "Name = enum" style inside a type section
      let eq = body.find('=')
      let lhs = strip(body[0 ..< eq])
      let rhs = strip(body[eq + 1 ..< body.len])
      if lhs.len > 0 and (lhs.endsWith("*") or lhs[0].isUpperAscii()) and
          (rhs.startsWith("object") or rhs.startsWith("ref") or
           rhs.startsWith("enum") or rhs.startsWith("distinct") or
           rhs.startsWith("tuple") or rhs.startsWith("concept")):
        symKind = "type"
        name = lhs.replace("*", "")
    if name.len == 0 and indent == 0 and
        (body.startsWith("const ") or body.startsWith("let ")):
      var rest = body[(if body.startsWith("const"): 6 else: 4) ..< body.len]
      if rest.startsWith("*"): rest = rest[1 ..< rest.len]
      symKind = if body.startsWith("const"): "const" else: "let"
      name = leadingIdent(strip(rest))
    if name.len > 0 and name notin nimKeywords:
      result.add(Tag(relFname: relFname, fname: fname, line: i,
                     col: indent + body.find(name), name: name,
                     kind: kDef, symKind: symKind))
  for i in 0 ..< lines.len:
    let line = lines[i]
    var j = 0
    while j < line.len:
      if line[j].isAlphaAscii() or line[j] == '_':
        let start = j
        while j < line.len and (line[j].isAlphaNumeric() or line[j] == '_'):
          inc j
        let ident = line[start ..< j]
        if ident notin nimKeywords:
          result.add(Tag(relFname: relFname, fname: fname, line: -1,
                         name: ident, kind: kRef))
      else:
        inc j

# ---------------------------------------------------------------------------

proc extractTags*(path, relFname: string, source: string): seq[Tag] =
  ## Per-file tags. The seam entry point a repomap (or any consumer) calls.
  let ext = splitFile(path).ext.toLowerAscii()
  case ext
  of ".go", ".py", ".ts":
    extractTsTags(ext, source, path, relFname)
  of ".nim", ".nims":
    extractNimTags(source, path, relFname)
  else:
    @[]
