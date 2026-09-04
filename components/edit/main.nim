## edit component — the file-tools component: read, exact-text edit, write.
##
## The primary way the model touches files:
## - read: pageable plain-text reading (no line numbers — content copies
##   verbatim into edit's old_string).
## - edit: each edit matches an old_string that must occur exactly once
##   (ambiguous matches are refused with the occurrence count — fuzziness
##   never rescues ambiguity), so edits land on text the model actually
##   reproduced rather than on copied anchors. When the exact text is not
##   found, a guarded fallback cascade rescues common transcription slips:
##   per-line trailing whitespace, indentation drift, unicode punctuation
##   (smart quotes/dashes), double-escaped text, and finally block anchors
##   with a Levenshtein similarity check on the middle lines. Only the
##   matched original bytes are replaced, and a match whose span is wildly
##   larger than old_string is refused. Several edits per call are matched
##   against the same original content and may not overlap.
## - write: atomic whole-file create/overwrite/truncate.
## Every mutation is approval-gated and revertible with undo_last_edit
## (single-level per file, persisted across restarts, refused when the file
## changed after the edit). For deleting or moving large blocks without
## retyping them, install the niffler-hashline plugin and discover its
## anchored replace.

import std/[algorithm, json, os, posix, sequtils, strutils, tables]
import niffler/sdk

proc posixStat(pathname: cstring, buf: var Stat): cint {.importc: "stat",
  header: "<sys/stat.h>".}
proc posixFchmod(fd: cint, mode: Mode): cint {.importc: "fchmod",
  header: "<sys/stat.h>".}
proc posixRename(oldpath, newpath: cstring): cint {.importc: "rename",
  header: "<stdio.h>".}

const
  MAX_BYTES = 100 * 1024 * 1024
  SNIFF_BYTES = 8192
  MAX_DIFF_LINES = 200
  FUZZY_SIMILARITY = 0.65   # block-anchor middle-line similarity threshold
  MAX_READ_LINES = 2000     # default read cap per call
  MAX_READ_BYTES = 256 * 1024
  MAX_READ_LINE_BYTES = 200 * 1024

# ---------------------------------------------------------------------------
# line helpers + normalization

proc splitLf(text: string): seq[string] =
  ## Split on \n; a trailing newline does not produce a trailing empty line.
  if text.len == 0: return @[""]
  result = text.split('\n')
  if text.endsWith("\n"): result.setLen(result.len - 1)

proc detectEnding(content: string): string =
  let lfIdx = content.find('\n')
  if lfIdx < 0: return "\n"
  let crlfIdx = content.find("\r\n")
  if crlfIdx < 0: return "\n"
  if crlfIdx < lfIdx: "\r\n" else: "\n"

proc toLf(text: string): string =
  text.replace("\r\n", "\n").replace("\r", "\n")

proc restoreEnding(text, ending: string): string =
  if ending == "\r\n": text.replace("\n", "\r\n") else: text

proc stripBom(content: string): tuple[bom: string, text: string] =
  if content.startsWith("\uFEFF"): ("\uFEFF", content[3 .. ^1])
  else: ("", content)

proc trimEnd(line: string): string =
  ## Trailing spaces/tabs only — indentation is never normalized away
  ## (leading whitespace must match exactly, Nim/Python depend on it).
  var i = line.len
  while i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t'): dec i
  line[0 ..< i]

proc expand(path: string): string =
  let home = getHomeDir()
  if path == "~": home
  elif path.startsWith("~/"): home & path[1 .. ^1]
  else: path

proc toCwd(filePath, cwd: string): string =
  let expanded = expand(filePath)
  if expanded.startsWith("/"): expanded
  else: absolutePath(expanded, cwd)

proc followSymlink(path: string): string =
  result = path
  try:
    if symlinkExists(result): result = expandSymlink(result)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# atomic write (write component's pattern)

proc writeAtomic(path: string, content: string) =
  ## Temp file + rename in the target directory; follows symlinks to the
  ## target, creates parent dirs, preserves permissions.
  var target = path
  if target.len == 0:
    raise newException(ValueError, "empty path")
  target = followSymlink(target)
  if dirExists(target):
    raise newException(ValueError, target & " is a directory")
  let dir = target.parentDir()
  if dir.len > 0: createDir(dir)
  var st: Stat
  let overwrote = posixStat(target.cstring, st) == 0
  let tmp = dir / (".tmp-" & newId())
  var f = open(tmp, fmWrite)
  try:
    f.write(content)
    if overwrote:
      discard posixFchmod(cint(f.getFileHandle()), st.st_mode and Mode(0o7777))
  finally:
    f.close()
  if posixRename(tmp.cstring, target.cstring) != 0:
    let err = $osLastError()
    if fileExists(tmp): removeFile(tmp)
    raise newException(IOError, "rename onto " & target & " failed: " & err)

# ---------------------------------------------------------------------------
# file loading

proc utfBom(sample: string): string =
  if sample.len >= 4 and sample[0 .. 3] == "\xFF\xFE\x00\x00": return "UTF-32LE"
  if sample.len >= 4 and sample[0 .. 3] == "\x00\x00\xFE\xFF": return "UTF-32BE"
  if sample.len >= 2 and sample[0 .. 1] == "\xFF\xFE": return "UTF-16LE"
  if sample.len >= 2 and sample[0 .. 1] == "\xFE\xFF": return "UTF-16BE"
  ""

type TextFile = object
  absPath: string
  bom: string
  ending: string
  normalized: string

proc loadText(displayPath: string): TextFile =
  ## Read a text file for editing: relative paths resolve against NIF_ROOT,
  ## symlinks are followed to the target, the BOM is stripped (restored on
  ## write) and line endings normalized to \n (restored on write). Binaries,
  ## UTF-16/32 text and oversized files are refused.
  let target = followSymlink(toCwd(displayPath, rootDir()))
  if dirExists(target):
    raise newException(ValueError,
      "[E_NOT_TEXT] " & displayPath & " is a directory — edit changes files; list it with bash")
  if not fileExists(target):
    raise newException(ValueError,
      "[E_NOT_FOUND] File not found: " & displayPath &
      " — edit only changes existing files; use write to create one")
  if getFileSize(target) > MAX_BYTES:
    raise newException(ValueError,
      "[E_FILE_TOO_LARGE] " & displayPath & " exceeds the 100MB edit limit; use bash")
  let raw = readFile(target)
  if raw.len == 0:
    raise newException(ValueError,
      "[E_EMPTY] " & displayPath & " is empty — use write to create content")
  let sampleLen = min(SNIFF_BYTES, raw.len)
  let sample = raw[0 ..< sampleLen]
  if '\0' in sample:
    raise newException(ValueError,
      "[E_NOT_TEXT] " & displayPath & " looks binary (NUL bytes) — edit only supports text")
  let bomEnc = utfBom(sample)
  if bomEnc.len > 0:
    raise newException(ValueError,
      "[E_NOT_TEXT] " & displayPath & " is " & bomEnc &
      " encoded — edit writes UTF-8; convert it with bash first")
  let (bom, body) = stripBom(raw)
  TextFile(absPath: target, bom: bom, ending: detectEnding(body),
           normalized: toLf(body))

# ---------------------------------------------------------------------------
# matching

proc countOccurrences(content, needle: string): tuple[count, first: int] =
  result.first = -1
  var i = 0
  while true:
    let idx = content.find(needle, i)
    if idx < 0: break
    if result.count == 0: result.first = idx
    inc result.count
    i = idx + needle.len

proc lineStarts(content: string): seq[int] =
  result = @[0]
  for i, ch in content:
    if ch == '\n': result.add(i + 1)

proc levenshtein(a, b: string): int =
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
    swap(prev, cur)
  prev[b.len]

proc unicodeFold(s: string): string =
  ## Smart punctuation → ASCII (pi's normalizeForFuzzyMatch, minus NFKC):
  ## the usual transcription slips when a model retypes quoted text.
  const pairs = [
    ("\u2018", "'"), ("\u2019", "'"), ("\u201A", "'"), ("\u201B", "'"),
    ("\u201C", "\""), ("\u201D", "\""), ("\u201E", "\""),
    ("\u2010", "-"), ("\u2011", "-"), ("\u2012", "-"), ("\u2013", "-"),
    ("\u2014", "-"), ("\u2015", "-"), ("\u2212", "-"),
    ("\u00A0", " "), ("\u2002", " "), ("\u2003", " "), ("\u2004", " "),
    ("\u2005", " "), ("\u2006", " "), ("\u2007", " "), ("\u2008", " "),
    ("\u2009", " "), ("\u200A", " "), ("\u202F", " "), ("\u205F", " "),
    ("\u3000", " "), ("\u2026", "...")
  ]
  result = s
  for p in pairs: result = result.replace(p[0], p[1])

proc unescapeText(s: string): string =
  ## Unescape a double-escaped old_string: models sometimes write literal
  ## \n / \t inside tool args where real newlines were intended.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add('\n'); inc i, 2
      of 't': result.add('\t'); inc i, 2
      of 'r': result.add('\r'); inc i, 2
      of '"': result.add('"'); inc i, 2
      of '\'': result.add('\''); inc i, 2
      of '\\': result.add('\\'); inc i, 2
      else:
        result.add(s[i]); inc i
    else:
      result.add(s[i]); inc i

proc disproportionate(matched, oldString: string): bool =
  ## Guard against runaway fuzzy matches (opencode's rule): a candidate span
  ## spanning far more lines — or vastly more bytes — than old_string asked
  ## for is a sign the fallback latched onto the wrong region.
  let oldN = splitLf(oldString).len
  let searchN = splitLf(matched).len
  if searchN >= max(oldN + 3, oldN * 2): return true
  if oldN == 1: return false
  result = matched.strip().len >
    max(oldString.strip().len + 500, oldString.strip().len * 4)

# --- fallback tiers: each finds whole-line windows matching oldLines with a
# progressive normalization. A tier succeeds only when exactly one window
# matches; ambiguity is an error, never a license to go fuzzier.

type Window = tuple[w, m: int]

proc trailingTrimWindows(lines, oldLines: seq[string]): seq[Window] =
  let m = oldLines.len
  if m == 0 or lines.len < m: return @[]
  let strippedOld = oldLines.mapIt(trimEnd(it))
  for i in 0 .. lines.len - m:
    var ok = true
    for j in 0 ..< m:
      if trimEnd(lines[i + j]) != strippedOld[j]:
        ok = false
        break
    if ok: result.add((i, m))

proc fullTrimWindows(lines, oldLines: seq[string]): seq[Window] =
  ## Indentation drift: leading AND trailing whitespace forgiven per line.
  let m = oldLines.len
  if m == 0 or lines.len < m: return @[]
  let strippedOld = oldLines.mapIt(it.strip())
  for i in 0 .. lines.len - m:
    var ok = true
    for j in 0 ..< m:
      if lines[i + j].strip() != strippedOld[j]:
        ok = false
        break
    if ok: result.add((i, m))

proc unicodeWindows(lines, oldLines: seq[string]): seq[Window] =
  ## Smart quotes/dashes/unicode spaces folded to ASCII, trailing whitespace
  ## forgiven; indentation must still match.
  let m = oldLines.len
  if m == 0 or lines.len < m: return @[]
  let foldedOld = oldLines.mapIt(trimEnd(unicodeFold(it)))
  for i in 0 .. lines.len - m:
    var ok = true
    for j in 0 ..< m:
      if trimEnd(unicodeFold(lines[i + j])) != foldedOld[j]:
        ok = false
        break
    if ok: result.add((i, m))

proc blockAnchorWindows(lines, oldLines: seq[string]): seq[Window] =
  ## opencode's block-anchor fallback (cline/gemini lineage): first and last
  ## lines anchor the block; the middle only needs Levenshtein similarity
  ## >= FUZZY_SIMILARITY. Rescues a slightly-paraphrased middle. Needs at
  ## least 3 lines so the anchors carry meaning.
  let m = oldLines.len
  if m < 3 or lines.len < m: return @[]
  let first = oldLines[0].strip()
  let last = oldLines[m - 1].strip()
  let maxDelta = max(1, m div 4)
  var candidates: seq[tuple[i, j: int]] = @[]
  for i in 0 ..< lines.len:
    if lines[i].strip() != first: continue
    for j in i + 2 ..< lines.len:
      if lines[j].strip() == last:
        if abs((j - i + 1) - m) <= maxDelta:
          candidates.add((i, j))
        break
  for c in candidates:
    let actual = c.j - c.i + 1
    let toCheck = min(m - 2, actual - 2)
    if toCheck <= 0:
      result.add((c.i, actual))
      continue
    var similarity = 0.0
    for k in 1 ..< m - 1:
      if k >= actual - 1: break
      let a = lines[c.i + k].strip()
      let b = oldLines[k].strip()
      let maxLen = max(a.len, b.len)
      if maxLen == 0: continue
      similarity += (1.0 - levenshtein(a, b).float / maxLen.float) /
        toCheck.float
      if similarity >= FUZZY_SIMILARITY: break
    if similarity >= FUZZY_SIMILARITY:
      result.add((c.i, actual))

# ---------------------------------------------------------------------------
# diff rendering

proc compactDiff(oldContent, newContent: string, context = 3):
    tuple[diff: string, firstLine, lastLine: int] =
  ## Trimmed common prefix/suffix with a bounded changed middle and context
  ## lines around it (no LCS — one changed region per response is enough to
  ## show the model what landed where).
  let a = splitLf(oldContent)
  let b = splitLf(newContent)
  var p = 0
  while p < a.len and p < b.len and a[p] == b[p]: inc p
  var sa = a.len - 1
  var sb = b.len - 1
  while sa >= p and sb >= p and a[sa] == b[sb]:
    dec sa
    dec sb
  let oldMid = a[p ..< sa + 1]
  let newMid = b[p ..< sb + 1]
  result.firstLine = p + 1
  result.lastLine = p + newMid.len
  var outp: seq[string] = @[]
  let preStart = max(0, p - context)
  if preStart > 0: outp.add("  ...")
  for i in preStart ..< p: outp.add("    " & a[i])
  var shown = 0
  for line in oldMid:
    if shown >= MAX_DIFF_LINES:
      outp.add("  ... (removed lines truncated)")
      break
    outp.add("- " & line)
    inc shown
  shown = 0
  for line in newMid:
    if shown >= MAX_DIFF_LINES:
      outp.add("  ... (added lines truncated)")
      break
    outp.add("+ " & line)
    inc shown
  let postEnd = min(a.len, sa + 1 + context)
  for i in sa + 1 ..< postEnd: outp.add("    " & a[i])
  if postEnd < a.len: outp.add("  ...")
  result.diff = outp.join("\n")

# ---------------------------------------------------------------------------
# undo store (single-level, per file, persisted across restarts)

const STORE_VERSION = 1

type UndoEntry = object
  content: string        # pre-edit content (LF-normalized)
  bom: string
  ending: string
  resultContent: string  # post-edit content, for staleness checks

var
  gStorePath = ""
  gUndo = initTable[string, UndoEntry]()

proc configDir(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: xdg / "niffler-edit"
  else: getHomeDir() / ".config" / "niffler-edit"

proc loadStore() =
  let dir = configDir()
  gStorePath = dir / "undo.json"
  createDir(dir)
  if not fileExists(gStorePath): return
  var doc: JsonNode
  try:
    doc = parseJson(readFile(gStorePath))
  except CatchableError:
    return
  if doc == nil or doc.kind != JObject: return
  let undo = doc{"undo"}
  if undo == nil or undo.kind != JObject: return
  for path, node in undo:
    if node == nil or node.kind != JObject: continue
    let ending = node{"ending"}.getStr("\n")
    if ending != "\n" and ending != "\r\n": continue
    gUndo[path] = UndoEntry(
      content: node{"content"}.getStr(""),
      bom: node{"bom"}.getStr(""),
      ending: ending,
      resultContent: node{"resultContent"}.getStr(""))

proc saveStore() =
  var doc = %*{"version": STORE_VERSION, "undo": newJObject()}
  for path, e in gUndo:
    doc["undo"][path] = %*{"content": e.content, "bom": e.bom,
                           "ending": e.ending,
                           "resultContent": e.resultContent}
  writeAtomic(gStorePath, $doc)

proc saveUndo(path: string, entry: UndoEntry): tuple[persisted: bool,
                                                      restore: proc()] =
  ## Persist the undo record BEFORE the edit is written; a failed persist
  ## refuses the edit (the file is never touched). restore() re-installs the
  ## previous record if the write itself fails.
  let hadPrevious = gUndo.hasKey(path)
  let previous = if hadPrevious: gUndo[path] else: UndoEntry(ending: "\n")
  gUndo[path] = entry
  try:
    saveStore()
    result.persisted = true
    result.restore = proc() =
      if hadPrevious: gUndo[path] = previous
      else: gUndo.del(path)
      try: saveStore()
      except CatchableError: discard
  except CatchableError:
    if hadPrevious: gUndo[path] = previous
    else: gUndo.del(path)
    result.persisted = false

proc clearUndo(path: string) =
  if gUndo.hasKey(path):
    gUndo.del(path)
    saveStore()

# ---------------------------------------------------------------------------
# edit resolution

type Span = tuple[start, length: int, replacement: string, added, removed: int]

proc allSpans(content, needle, replacement: string): seq[Span] =
  ## Every non-overlapping occurrence of needle (replace_all).
  var i = 0
  while true:
    let idx = content.find(needle, i)
    if idx < 0: break
    result.add((idx, needle.len, replacement,
                splitLf(replacement).len, splitLf(needle).len))
    i = idx + needle.len

proc windowSpan(content: string, lines: seq[string], starts: seq[int],
                win: Window, oldNorm, newNorm: string): Span =
  ## Convert a matched whole-line window to a char span of the ORIGINAL
  ## bytes; the span swallows the newline after the last matched line so the
  ## replacement keeps following lines whole.
  let s = starts[win.w]
  let e = if win.w + win.m < lines.len: starts[win.w + win.m] else: content.len
  let matched = content[s ..< e]
  if disproportionate(matched, oldNorm):
    raise newException(ValueError,
      "[E_SPAN_TOO_LARGE] Refusing the fuzzy match: the matched span is " &
      "much larger than old_string. Re-read the file and provide the full " &
      "exact old_string for the intended replacement.")
  var replacement = newNorm
  if e > 0 and content[e - 1] == '\n' and replacement.len > 0 and
      not replacement.endsWith("\n"):
    replacement.add('\n')
  (s, e - s, replacement, splitLf(replacement).len, splitLf(matched).len)

proc resolveSpans(content, path: string, lines: seq[string], starts: seq[int],
                  oldNorm, newNorm: string, replaceAll: bool): seq[Span] =
  ## Match one edit against the content: exact first (uniqueness enforced —
  ## ambiguity is refused, never fuzzied away), then the fallback cascade
  ## for not-found cases. Returns the char spans to splice.
  let exact = countOccurrences(content, oldNorm)
  if exact.count > 1 and not replaceAll:
    raise newException(ValueError,
      "[E_AMBIGUOUS] old_string occurs " & $exact.count & " times in " & path &
      " — include more surrounding lines so it matches exactly once.")
  if exact.count >= 1:
    return allSpans(content, oldNorm, newNorm)

  let oldLines = splitLf(oldNorm)
  let tiers = @[(trailingTrimWindows, "trailing whitespace"),
                (fullTrimWindows, "indentation"),
                (unicodeWindows, "unicode punctuation"),
                (blockAnchorWindows, "block anchors")]
  var wins: seq[Window] = @[]
  var tierName = ""
  for (finder, name) in tiers:
    wins = finder(lines, oldLines)
    tierName = name
    if wins.len > 0: break
  if wins.len > 1:
    raise newException(ValueError,
      "[E_AMBIGUOUS] old_string (after " & tierName &
      " normalization) occurs " & $wins.len & " times in " & path &
      " — include more surrounding lines so it matches exactly once.")
  if wins.len == 1:
    return @[windowSpan(content, lines, starts, wins[0], oldNorm, newNorm)]

  # double-escaped old_string: unescape, then exact and trailing-trim
  let oldUn = unescapeText(oldNorm)
  if oldUn != oldNorm:
    let (cnt, first) = countOccurrences(content, oldUn)
    if cnt > 1:
      raise newException(ValueError,
        "[E_AMBIGUOUS] old_string (unescaped) occurs " & $cnt & " times in " &
        path & " — include more surrounding lines so it matches exactly once.")
    if cnt == 1:
      return @[(first, oldUn.len, newNorm,
                splitLf(newNorm).len, splitLf(oldUn).len)]
    wins = trailingTrimWindows(lines, splitLf(oldUn))
    if wins.len > 1:
      raise newException(ValueError,
        "[E_AMBIGUOUS] old_string (after escaped-text normalization) occurs " &
        $wins.len & " times in " & path &
        " — include more surrounding lines so it matches exactly once.")
    if wins.len == 1:
      return @[windowSpan(content, lines, starts, wins[0], oldNorm, newNorm)]

  raise newException(ValueError,
    "[E_NOT_FOUND] old_string not found in " & path &
    ". It must match the file exactly, including whitespace, indentation " &
    "and newlines — the fallbacks (trailing whitespace, indentation, " &
    "unicode punctuation, block anchors, escaped text) all failed. Read " &
    "the file and copy the text verbatim.")

proc hEdit(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Edit request must be an object.")
  var path = ""
  for key in ["path", "filePath", "file_path"]:
    let n = args{key}
    if n != nil and n.kind == JString and n.getStr().len > 0:
      path = n.getStr()
      break
  if path.len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Edit request requires a non-empty \"path\" string.")
  var editsNode = args{"edits"}
  if editsNode != nil and editsNode.kind == JString:
    try: editsNode = parseJson(editsNode.getStr())
    except CatchableError:
      raise newException(ValueError,
        "[E_BAD_SHAPE] \"edits\" was a string but not valid JSON — pass an array of {old_string, new_string} objects.")
  if editsNode != nil and editsNode.kind == JObject:
    editsNode = %*[editsNode]
  if editsNode == nil or editsNode.kind != JArray or editsNode.len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] \"edits\" must be a non-empty array of {old_string, new_string} objects.")
  type PlannedEdit = object
    oldString: string
    newString: string
    replaceAll: bool
  var planned: seq[PlannedEdit] = @[]
  for ed in editsNode:
    if ed == nil or ed.kind != JObject:
      raise newException(ValueError,
        "[E_BAD_SHAPE] each element of \"edits\" must be an object with old_string and new_string.")
    var oldS = ""
    for key in ["old_string", "old_str", "oldText"]:
      let n = ed{key}
      if n != nil and n.kind == JString: oldS = n.getStr(); break
    var newS = ""
    var newFound = false
    for key in ["new_string", "new_str", "newText"]:
      let n = ed{key}
      if n != nil and n.kind == JString:
        newS = n.getStr()
        newFound = true
        break
    if oldS.len == 0:
      raise newException(ValueError,
        "[E_BAD_SHAPE] edits[].old_string must be a non-empty string (creating files is the write tool's job).")
    if not newFound:
      raise newException(ValueError,
        "[E_BAD_SHAPE] edits[].new_string must be a string (use \"\" to delete the matched text).")
    let ra = ed{"replace_all"}
    if ra != nil and ra.kind != JBool:
      raise newException(ValueError,
        "[E_BAD_SHAPE] edits[].replace_all must be a boolean.")
    let replaceAll = if ra != nil and ra.kind == JBool: ra.getBool() else: false
    planned.add(PlannedEdit(oldString: oldS, newString: newS,
                            replaceAll: replaceAll))

  let file = loadText(path)
  let content = file.normalized

  let starts = lineStarts(content)
  let lines = splitLf(content)
  var spans: seq[Span] = @[]
  for p in planned:
    spans.add(resolveSpans(content, path, lines, starts,
                           toLf(p.oldString), toLf(p.newString), p.replaceAll))

  var ordered = spans
  ordered.sort(proc(a, b: Span): int = cmp(a.start, b.start))
  for i in 1 ..< ordered.len:
    if ordered[i - 1].start + ordered[i - 1].length > ordered[i].start:
      raise newException(ValueError,
        "[E_OVERLAP] two edits touch overlapping text in " & path &
        " — merge them into one edit.")

  var applied = content
  var addedTotal = 0
  var removedTotal = 0
  for i in countdown(ordered.len - 1, 0):
    let sp = ordered[i]
    applied = applied[0 ..< sp.start] & sp.replacement &
      applied[sp.start + sp.length .. ^1]
    addedTotal += sp.added
    removedTotal += sp.removed

  if applied == content:
    raise newException(ValueError,
      "[E_NO_CHANGE] The edit produced identical content in " & path &
      " — check old_string against new_string.")

  let entry = UndoEntry(content: content, bom: file.bom, ending: file.ending,
                        resultContent: applied)
  let undo = saveUndo(file.absPath, entry)
  if not undo.persisted:
    raise newException(ValueError,
      "[E_UNDO_UNAVAILABLE] Could not persist undo history; " & path &
      " was NOT modified. Retry, or use bash if the store cannot be recovered.")
  try:
    writeAtomic(file.absPath, file.bom & restoreEnding(applied, file.ending))
  except CatchableError:
    undo.restore()
    raise
  let d = compactDiff(content, applied)
  let noun = if planned.len == 1: "edit" else: "edits"
  let lineSummary = if addedTotal > 0 or removedTotal > 0:
    " Added " & $addedTotal & " line(s), removed " & $removedTotal & " line(s)."
    else: ""
  result = %*{"summary": "Successfully applied " & $planned.len & " " & noun &
                       " to " & path & "." & lineSummary,
              "first_changed_line": d.firstLine,
              "last_changed_line": d.lastLine,
              "added_lines": addedTotal,
              "removed_lines": removedTotal,
              "edits_applied": planned.len}

# ---------------------------------------------------------------------------
# undo handler

proc hUndoLastEdit(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Undo request must be an object.")
  let pathNode = args{"path"}
  if pathNode == nil or pathNode.kind != JString or pathNode.getStr().len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Undo request requires a non-empty \"path\" string.")
  let path = pathNode.getStr()
  let target = followSymlink(toCwd(path, rootDir()))
  if not gUndo.hasKey(target):
    raise newException(ValueError,
      "No undo history for " & path & " — there is no previous edit to revert.")
  let entry = gUndo[target]
  if not fileExists(target):
    clearUndo(target)
    raise newException(ValueError,
      "[E_UNDO_STALE] Cannot undo " & path & ": the file no longer exists.")
  let currentRaw = readFile(target)
  let expected = entry.bom & restoreEnding(entry.resultContent, entry.ending)
  if currentRaw != expected:
    clearUndo(target)
    raise newException(ValueError,
      "[E_UNDO_STALE] Cannot undo " & path &
      ": the file was modified after the edit, so undoing would overwrite those changes.")
  writeAtomic(target, entry.bom & restoreEnding(entry.content, entry.ending))
  clearUndo(target)
  let d = compactDiff(entry.resultContent, entry.content)
  result = %*{"summary": "Undid the last edit on " & path &
              ". File reverted to its previous state; re-read it before further edits.",
              "first_changed_line": d.firstLine,
              "last_changed_line": d.lastLine}

# ---------------------------------------------------------------------------
# read handler

proc readPathArg(args: JsonNode, label: string): string =
  for key in ["path", "filePath", "file_path"]:
    let n = args{key}
    if n != nil and n.kind == JString and n.getStr().len > 0:
      return n.getStr()
  raise newException(ValueError,
    "[E_BAD_SHAPE] " & label & " requires a non-empty \"path\" string.")

proc hRead(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Read request must be an object.")
  let path = readPathArg(args, "Read request")
  let offN = args{"offset"}
  let limN = args{"limit"}
  if offN != nil and offN.kind != JNull and
      (offN.kind != JInt or offN.getInt() < 1):
    raise newException(ValueError,
      "[E_BAD_SHAPE] \"offset\" must be a positive integer (1-indexed line).")
  if limN != nil and limN.kind != JNull and
      (limN.kind != JInt or limN.getInt() < 1):
    raise newException(ValueError,
      "[E_BAD_SHAPE] \"limit\" must be a positive integer.")
  let offset = if offN != nil and offN.kind == JInt: offN.getInt() else: 1
  let limit = if limN != nil and limN.kind == JInt: limN.getInt() else: MAX_READ_LINES

  let target = followSymlink(toCwd(path, rootDir()))
  if dirExists(target):
    raise newException(ValueError,
      "[E_NOT_TEXT] " & path & " is a directory — list it with bash or grep files")
  if not fileExists(target):
    raise newException(ValueError,
      "[E_NOT_FOUND] File not found: " & path)
  if getFileSize(target) > MAX_BYTES:
    raise newException(ValueError,
      "[E_FILE_TOO_LARGE] " & path & " exceeds the 100MB read limit; use bash")
  let raw = readFile(target)
  if raw.len == 0:
    return %("[] " & path & " is empty (0 lines). Use write to create content.")
  let sampleLen = min(SNIFF_BYTES, raw.len)
  let sample = raw[0 ..< sampleLen]
  if '\0' in sample:
    raise newException(ValueError,
      "[E_NOT_TEXT] " & path & " looks binary (NUL bytes) — inspect with bash")
  let bomEnc = utfBom(sample)
  if bomEnc.len > 0:
    raise newException(ValueError,
      "[E_NOT_TEXT] " & path & " is " & bomEnc & " encoded — convert it with bash first")
  let (_, body) = stripBom(raw)
  let lines = splitLf(toLf(body))
  let total = lines.len
  if offset > total:
    return %("Offset " & $offset & " is beyond end of file (" & $total &
      " lines). Use offset=1 to read from the start.")
  let endIdx = min(offset - 1 + limit, total)
  var selected = lines[offset - 1 ..< endIdx]
  for i, line in selected:
    if line.len > MAX_READ_LINE_BYTES:
      selected[i] = "[line " & $(offset + i) & " exceeds " &
        $MAX_READ_LINE_BYTES & " bytes; content not shown. Use bash: sed -n '" &
        $(offset + i) & "p' <path> | head -c " & $MAX_READ_LINE_BYTES & "]"
  var text = selected.join("\n")
  if toLf(body).endsWith("\n") and selected.len > 0: text.add("\n")
  var shownCount = selected.len
  if text.len > MAX_READ_BYTES:
    var cut = MAX_READ_BYTES
    while cut > 0 and (uint8(text[cut - 1]) and 0xC0) == 0x80: dec cut
    text = text[0 ..< cut]
    shownCount = text.split('\n').len
    text.add("\n... [truncated at " & $MAX_READ_BYTES &
      " bytes — page with offset/limit]")
  let lastLine = offset + shownCount - 1
  if not text.endsWith("\n"): text.add("\n")
  if lastLine < total:
    text.add("\n[Showing lines " & $offset & "-" & $lastLine & " of " &
      $total & ". Use offset=" & $(lastLine + 1) & " to continue.]")
  elif offset > 1:
    text.add("\n[Showing lines " & $offset & "-" & $lastLine & " of " &
      $total & ".]")
  result = %text

proc hReadMany(c: Component, args: JsonNode): JsonNode =
  ## Read up to eight independent text files in one structured call. Each
  ## item reports its own error so one missing/binary file does not hide the
  ## others; the aggregate stays below the bus-friendly 512KB bound.
  if args == nil or args.kind != JObject or args{"paths"} == nil or
      args{"paths"}.kind != JArray:
    raise newException(ValueError,
      "[E_BAD_SHAPE] read_many requires a paths array.")
  let paths = args{"paths"}
  if paths.len == 0 or paths.len > 8:
    raise newException(ValueError,
      "[E_BAD_SHAPE] read_many paths must contain 1..8 files.")
  let limit = args{"limit"}.getInt(MAX_READ_LINES)
  if limit < 1:
    raise newException(ValueError, "[E_BAD_SHAPE] limit must be positive.")
  var items = newJArray()
  var used = 0
  for item in paths:
    if item.kind != JString or item.getStr("").len == 0:
      items.add(%*{"path": "", "error": "path must be a non-empty string"})
      continue
    let path = item.getStr()
    try:
      let content = hRead(c, %*{"path": path, "limit": limit})
      let encoded = $content
      if used + encoded.len > 512_000:
        items.add(%*{"path": path,
                     "error": "aggregate read_many output exceeds 512000 bytes; read remaining files separately"})
        break
      used += encoded.len
      items.add(%*{"path": path, "content": content})
    except CatchableError as e:
      items.add(%*{"path": path, "error": e.msg})
  %*{"items": items, "count": items.len}

# ---------------------------------------------------------------------------
# write handler

proc maxWriteBytes(): int =
  ## Content cap. Default sits just under NATS's 1MB payload limit so an
  ## oversized write gets a clear error from us instead of a bus-level
  ## rejection. NIF_WRITE_MAX_BYTES overrides (tests use a small value).
  result = parseInt(getEnv("NIF_WRITE_MAX_BYTES", "900000"))
  if result <= 0: result = 900000

proc hWrite(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Write request must be an object.")
  let path = readPathArg(args, "Write request")
  let contentN = args{"content"}
  if contentN == nil or contentN.kind != JString:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Write request requires a \"content\" string (empty truncates the file).")
  let content = contentN.getStr()
  if content.len > maxWriteBytes():
    raise newException(ValueError,
      "content is " & $content.len & " bytes, over the write cap of " &
      $maxWriteBytes() & " — use bash for large files")
  let target = followSymlink(toCwd(path, rootDir()))
  if dirExists(target):
    raise newException(ValueError,
      target & " is a directory — write needs a file path")
  let overwrote = fileExists(target)
  writeAtomic(target, content)
  result = %*{"path": target, "bytes_written": content.len,
              "overwrote": overwrote}

# ---------------------------------------------------------------------------
# component

let comp = newComponent("edit", "0.3.0")

loadStore()

discard comp.tool("read", toolSchema(%*{
  "path": {"type": "string",
           "description": "File to read, relative to the harness root or absolute"},
  "offset": {"type": "integer", "minimum": 1,
             "description": "Line number to start reading from (1-indexed)"},
  "limit": {"type": "integer", "minimum": 1,
            "description": "Maximum number of lines to read (default 2000)"}
}, @["path"],
  "Read a text file — the standard way to inspect content before editing. Verbatim lines, no line numbers: copy text exactly into edit's old_string. Pageable (offset/limit; the hint reports the range shown). Binary/UTF-16/32 and >100MB files are refused, empty files reported, huge lines elided with a bash hint. Use grep to search across files, read_many to survey several."), hRead,
  %*{"timeoutMs": 60000, "parallel": true,
     "workspace": {"pathFields": ["path"]}})

discard comp.tool("read_many", toolSchema(%*{
  "paths": {"type": "array", "minItems": 1, "maxItems": 8,
            "items": {"type": "string"},
            "description": "Text files to read in order"},
  "limit": {"type": "integer", "minimum": 1,
            "description": "Maximum lines per file (default 2000)"}
}, @["paths"],
  "Read up to 8 named text files in one call — an initial repository survey instead of bash cat or many read calls. Returns [{path, content}|{path, error}] in request order; one bad file doesn't hide the others. Max 512KB total."),
  hReadMany, %*{"timeoutMs": 60000, "parallel": true,
                "workspace": {"pathArrayFields": ["paths"]}})

discard comp.tool("edit", toolSchema(%*{
  "path": {"type": "string",
           "description": "File to edit, relative to the harness root or absolute"},
  "edits": {"type": "array",
    "description": "The replacements to apply, each {old_string, new_string}; all old_strings are matched against the same original file content",
    "items": {"type": "object",
      "properties": {
        "old_string": {"type": "string",
          "description": "Exact text to replace — must occur exactly once in the file; copy it verbatim including indentation and newlines"},
        "new_string": {"type": "string",
          "description": "Replacement text; \"\" deletes old_string"},
        "replace_all": {"type": "boolean",
          "description": "Replace every occurrence of old_string instead of requiring uniqueness (default false)"}
      },
      "required": ["old_string", "new_string"]}
  }
}, @["path", "edits"],
  "Surgically replace exact text in an existing file. Each edits[].old_string must occur EXACTLY ONCE (add surrounding lines to disambiguate; replace_all for every occurrence); whitespace matters — read the file first and copy verbatim. Several non-overlapping edits per call are fine; merge changes to the same block. new_string \"\" deletes. For NEW files or wholesale rewrites use write. Revertible with undo_last_edit."), hEdit,
  %*{"approval": "always", "timeoutMs": 300000,
     "workspace": {"pathFields": ["path"]}})

discard comp.tool("undo_last_edit", toolSchema(%*{
  "path": {"type": "string",
           "description": "File to undo the last edit on"}
}, @["path"],
  "Undo the last edit on a file, restoring its exact previous bytes " &
  "(content, BOM and line endings included). Use when an edit produced " &
  "wrong results. History is per-file and single-level, persisted across " &
  "restarts; the undo is refused with E_UNDO_STALE when the file was " &
  "modified or deleted after the edit — re-read and edit forward instead. " &
  "The result shows the diff of the revert."), hUndoLastEdit,
  %*{"approval": "always", "timeoutMs": 120000, "onDemand": true,
     "workspace": {"pathFields": ["path"]}})

discard comp.tool("write", toolSchema(%*{
  "path": {"type": "string",
           "description": "File to write, relative to the harness root or absolute"},
  "content": {"type": "string",
              "description": "The full new file content (\"\" truncates the file)"}
}, @["path", "content"],
  "Create a NEW file or replace a whole small file atomically (temp+rename; parent dirs created, permissions preserved). Use for new components, configs, scripts, generated artifacts. For surgical changes to existing files prefer edit. \"\" truncates. Cap 900KB — use bash for larger files."), hWrite,
  %*{"approval": "always", "timeoutMs": 60000,
     "workspace": {"pathFields": ["path"]}})

comp.run()
