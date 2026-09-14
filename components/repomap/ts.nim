## tree-sitter C ABI wrapper — importc over the vendored runtime
## (components/repomap/csrc). No existing Nim binding needed: the generated
## grammar parsers are C, and the runtime API is a small, stable C surface
## (the resolver for the open question in docs/research/AIDER.md §1).
##
## Only what the tags seam needs: parse a string, run a query, walk
## matches, read capture names and node spans. Zero-based rows/columns
## throughout — callers convert at the model boundary like everywhere else.
##
import std/os

## Compiled together with the vendored C via {.compile.} pragmas below
## (wasm excluded); the include dir rides in this module, so any consumer
## (test binary or future component) needs no special build flags.

const csrcDir = currentSourcePath().parentDir / "csrc"
{.passC: "-I\"" & csrcDir & "\" ".}

{.compile: "csrc/tree_sitter/lib/src/alloc.c".}
{.compile: "csrc/tree_sitter/lib/src/get_changed_ranges.c".}
{.compile: "csrc/tree_sitter/lib/src/language.c".}
{.compile: "csrc/tree_sitter/lib/src/lexer.c".}
{.compile: "csrc/tree_sitter/lib/src/node.c".}
{.compile: "csrc/tree_sitter/lib/src/parser.c".}
{.compile: "csrc/tree_sitter/lib/src/query.c".}
{.compile: "csrc/tree_sitter/lib/src/stack.c".}
{.compile: "csrc/tree_sitter/lib/src/subtree.c".}
{.compile: "csrc/tree_sitter/lib/src/tree.c".}
{.compile: "csrc/tree_sitter/lib/src/tree_cursor.c".}
{.compile: "csrc/tree_sitter/lib/src/wasm_store.c".}
{.compile: "csrc/go/parser.c".}
{.compile: "csrc/python/parser.c".}
{.compile: "csrc/python/scanner.c".}
{.compile: "csrc/typescript/parser.c".}
{.compile: "csrc/typescript/scanner.c".}

type
  TsLanguage* {.importc: "TSLanguage", header: "tree_sitter/api.h".} = object
  TsParser* {.importc: "TSParser", header: "tree_sitter/api.h".} = object
  TsTree* {.importc: "TSTree", header: "tree_sitter/api.h".} = object
  TsQuery* {.importc: "TSQuery", header: "tree_sitter/api.h".} = object
  TsQueryCursor* {.importc: "TSQueryCursor", header: "tree_sitter/api.h".} = object
  TsQueryError* {.importc: "TSQueryError", header: "tree_sitter/api.h".} = enum
    qeNone, qeSyntax, qeNodeType, qeField, qeCapture, qeStructure, qeLanguage

  TsPoint* {.importc: "TSPoint", header: "tree_sitter/api.h", bycopy.} = object
    row*: uint32
    column*: uint32

  # TSNode is passed and returned by value: mirror the C layout exactly
  # (uint32 context[4]; const void* id; const TSTree* tree).
  TsNode* {.importc: "TSNode", header: "tree_sitter/api.h", bycopy.} = object
    context*: array[4, uint32]
    id*: pointer
    tree*: pointer

  TsQueryCapture* {.importc: "TSQueryCapture", header: "tree_sitter/api.h",
                    bycopy.} = object
    index*: uint32
    node*: TsNode

  TsQueryMatch* {.importc: "TSQueryMatch", header: "tree_sitter/api.h",
                  bycopy.} = object
    id*: uint32
    patternIndex* {.importc: "pattern_index".}: uint16
    captureCount* {.importc: "capture_count".}: uint16
    captures* {.importc: "captures".}: ptr UncheckedArray[TsQueryCapture]

proc ts_parser_new*(): ptr TsParser {.importc: "ts_parser_new",
                                      header: "tree_sitter/api.h".}
proc ts_parser_delete*(p: ptr TsParser) {.importc: "ts_parser_delete",
                                          header: "tree_sitter/api.h".}
proc ts_parser_set_language*(p: ptr TsParser, lang: ptr TsLanguage): bool {.
    importc: "ts_parser_set_language", header: "tree_sitter/api.h".}
proc ts_parser_parse_string*(p: ptr TsParser, oldTree: ptr TsTree,
                             source: cstring, length: uint32): ptr TsTree {.
    importc: "ts_parser_parse_string", header: "tree_sitter/api.h".}
proc ts_tree_delete*(t: ptr TsTree) {.importc: "ts_tree_delete",
                                      header: "tree_sitter/api.h".}
proc ts_tree_root_node*(t: ptr TsTree): TsNode {.importc: "ts_tree_root_node",
                                                 header: "tree_sitter/api.h".}
proc ts_node_start_byte*(n: TsNode): uint32 {.importc: "ts_node_start_byte",
    header: "tree_sitter/api.h".}
proc ts_node_end_byte*(n: TsNode): uint32 {.importc: "ts_node_end_byte",
    header: "tree_sitter/api.h".}
proc ts_node_start_point*(n: TsNode): TsPoint {.importc: "ts_node_start_point",
    header: "tree_sitter/api.h".}
proc ts_node_is_null*(n: TsNode): bool {.importc: "ts_node_is_null",
    header: "tree_sitter/api.h".}

proc ts_query_new*(lang: ptr TsLanguage, source: cstring, sourceLen: uint32,
                   errorOffset: ptr uint32, errorType: ptr TsQueryError): ptr TsQuery {.
    importc: "ts_query_new", header: "tree_sitter/api.h".}
proc ts_query_delete*(q: ptr TsQuery) {.importc: "ts_query_delete",
                                        header: "tree_sitter/api.h".}
proc ts_query_capture_name_for_id*(q: ptr TsQuery, index: uint32,
                                   length: ptr uint32): cstring {.
    importc: "ts_query_capture_name_for_id", header: "tree_sitter/api.h".}
proc ts_query_cursor_new*(): ptr TsQueryCursor {.importc: "ts_query_cursor_new",
    header: "tree_sitter/api.h".}
proc ts_query_cursor_delete*(c: ptr TsQueryCursor) {.
    importc: "ts_query_cursor_delete", header: "tree_sitter/api.h".}
proc ts_query_cursor_exec*(c: ptr TsQueryCursor, q: ptr TsQuery, node: TsNode) {.
    importc: "ts_query_cursor_exec", header: "tree_sitter/api.h".}
proc ts_query_cursor_next_match*(c: ptr TsQueryCursor,
                                 m: ptr TsQueryMatch): bool {.
    importc: "ts_query_cursor_next_match", header: "tree_sitter/api.h".}

# per-grammar entry points (defined by the vendored parser.c objects)
proc tree_sitter_go*(): ptr TsLanguage {.importc: "tree_sitter_go".}
proc tree_sitter_python*(): ptr TsLanguage {.importc: "tree_sitter_python".}
proc tree_sitter_typescript*(): ptr TsLanguage {.importc: "tree_sitter_typescript".}

proc tsQuery*(lang: ptr TsLanguage, source: string): ptr TsQuery =
  ## Compile a tags query; raises on malformed queries (our .scm files are
  ## vendored — a failure is a build-time bug, not runtime input).
  var errOffset: uint32
  var errType: TsQueryError
  let q = ts_query_new(lang, source.cstring, source.len.uint32,
                       addr errOffset, addr errType)
  if q == nil:
    raise newException(ValueError,
      "tree-sitter query error " & $errType & " at byte " & $errOffset)
  return q

proc captureName*(q: ptr TsQuery, index: uint32): string =
  var length: uint32
  let name = ts_query_capture_name_for_id(q, index, addr length)
  if name != nil: return $name
  return ""

proc nodeText*(n: TsNode, source: string): string =
  ## Node text from the original source buffer (byte offsets).
  if n.ts_node_is_null(): return ""
  let a = n.ts_node_start_byte().int
  let b = n.ts_node_end_byte().int
  if a >= source.len or b > source.len or a >= b: return ""
  return source[a ..< b]
