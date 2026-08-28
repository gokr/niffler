## hashline-edit component — hash-anchored read / replace / undo_last_replace.
##
## Nim port of pi-hashline-edit-pro (YuGiMob, MIT): every line of a file gets
## a unique 3-char anchor (xxHash32 over the canonicalized line, collisions
## resolved by probing a bitset with a stride coprime to the hash space), and
## edits target a range of anchors instead of line numbers, so edits land on
## the lines the model actually saw. Anchors of untouched lines stay valid
## across edits; a persistent per-file store (config-dir JSON, like the
## original's sqlite) keeps hashes stable across restarts, records which
## hashes were served to the model (E_RANGE_STALE protection) and keeps the
## single-level undo history.
##
## Tools: read (anchored lines, pageable), replace (one edit per call, anchored
## by remove_from/remove_to + replacement_lines), undo_last_replace. Replace
## and undo are x-harness.onDemand: exact-text editing (the edit component)
## is the default; the anchored replace remains reachable via discover +
## invoke for deleting or moving large blocks without retyping them.
##
## Deviations from the pi original, forced by the harness:
## - Images are rejected like other binaries (Niffler cannot attach them).
## - No `write` tool exists here; large files are handled with bash.

import std/[algorithm, json, os, posix, sequtils, sets, strutils, tables, times]
import niffler/sdk

proc posixStat(pathname: cstring, buf: var Stat): cint {.importc: "stat",
  header: "<sys/stat.h>".}
proc posixLstat(pathname: cstring, buf: var Stat): cint {.importc: "lstat",
  header: "<sys/stat.h>".}
proc posixFchmod(fd: cint, mode: Mode): cint {.importc: "fchmod",
  header: "<sys/stat.h>".}
proc posixRename(oldpath, newpath: cstring): cint {.importc: "rename",
  header: "<stdio.h>".}

# ---------------------------------------------------------------------------
# constants

const
  HASH_LEN = 3
  ALPH = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  HASH_SPACE = 62 * 62 * 62                  # 238328
  HASH_PROBE_STRIDE = 62 * 62 + 62 + 1       # 3907; coprime to HASH_SPACE
  MAX_HASH_LINES = HASH_SPACE
  HASH_SEP = "\u2502"                        # │

  MAX_BYTES = 100 * 1024 * 1024
  SNIFF_BYTES = 8192
  MAX_READ_LINE_BYTES = 200 * 1024
  MAX_RANGE_STALE_LINES = 100
  MAX_READ_LINES = 2000

  STORE_VERSION = 5

type
  RangeStaleError = object of ValueError
    rangeHashes: seq[string]
  AnchorMismatchError = object of ValueError
    feedbackHashes: seq[string]

# forward declarations (defined later; store/snapshot code depends on them)
proc writeAtomic(path: string, content: string)
proc lineHashes(content, path: string,
                previous: tuple[content: string, hashes: seq[string],
                                removedHashes: HashSet[string]] =
                  (content: "", hashes: @[], removedHashes: initHashSet[string]())): seq[string]

# ---------------------------------------------------------------------------
# xxHash32 / xxHash64 (pure Nim, seed 0 — mirrors xxhash-wasm used upstream)

proc rotl32(x: uint32, r: int): uint32 {.inline.} =
  (x shl r) or (x shr (32 - r))

proc rotl64(x: uint64, r: int): uint64 {.inline.} =
  (x shl r) or (x shr (64 - r))

proc rd32(s: string, i: int): uint32 =
  uint32(uint8(s[i])) or (uint32(uint8(s[i + 1])) shl 8) or
    (uint32(uint8(s[i + 2])) shl 16) or (uint32(uint8(s[i + 3])) shl 24)

proc rd64(s: string, i: int): uint64 =
  uint64(rd32(s, i)) or (uint64(rd32(s, i + 4)) shl 32)

proc xxh32(s: string, seed: uint32 = 0): uint32 =
  const P1 = 2654435761'u32
  const P2 = 2246822519'u32
  const P3 = 3266489917'u32
  const P4 = 668265263'u32
  const P5 = 374761393'u32
  let n = s.len
  let limit = n - (n mod 16)
  var h: uint32
  if n >= 16:
    var v1 = seed + P1 + P2
    var v2 = seed + P2
    var v3 = seed
    var v4 = seed - P1
    var i = 0
    while i < limit:
      v1 = rotl32(v1 + rd32(s, i) * P2, 13) * P1
      v2 = rotl32(v2 + rd32(s, i + 4) * P2, 13) * P1
      v3 = rotl32(v3 + rd32(s, i + 8) * P2, 13) * P1
      v4 = rotl32(v4 + rd32(s, i + 12) * P2, 13) * P1
      i += 16
    h = rotl32(v1, 1) + rotl32(v2, 7) + rotl32(v3, 12) + rotl32(v4, 18)
  else:
    h = seed + P5
  h += uint32(n)
  var i = limit
  while i + 4 <= n:
    h += rd32(s, i) * P3
    h = rotl32(h, 17) * P4
    i += 4
  while i < n:
    h += uint32(uint8(s[i])) * P5
    h = rotl32(h, 11) * P1
    inc i
  h = h xor (h shr 15)
  h *= P2
  h = h xor (h shr 13)
  h *= P3
  h = h xor (h shr 16)
  h

proc xxh64(s: string, seed: uint64 = 0): uint64 =
  const P1 = 11400714785074694791'u64
  const P2 = 14029467366897019727'u64
  const P3 = 1609587929392839161'u64
  const P4 = 9650029242287828579'u64
  const P5 = 2870177450012600261'u64
  proc round64(acc, input: uint64): uint64 =
    var a = acc + input * P2
    a = rotl64(a, 31)
    a * P1
  proc mergeRound(h, v: uint64): uint64 =
    var a = h xor round64(0'u64, v)
    a = a * P1 + P4
    a
  let n = s.len
  let limit = n - (n mod 32)
  var h: uint64
  if n >= 32:
    var v1 = seed + P1 + P2
    var v2 = seed + P2
    var v3 = seed
    var v4 = seed - P1
    var i = 0
    while i < limit:
      v1 = round64(v1, rd64(s, i))
      v2 = round64(v2, rd64(s, i + 8))
      v3 = round64(v3, rd64(s, i + 16))
      v4 = round64(v4, rd64(s, i + 24))
      i += 32
    h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18)
    h = mergeRound(h, v1)
    h = mergeRound(h, v2)
    h = mergeRound(h, v3)
    h = mergeRound(h, v4)
  else:
    h = seed + P5
  h += uint64(n)
  var i = limit
  while i + 8 <= n:
    let k1 = round64(0'u64, rd64(s, i))
    h = h xor k1
    h = rotl64(h, 27) * P1 + P4
    i += 8
  if i + 4 <= n:
    h = h xor (uint64(rd32(s, i)) * P1)
    h = rotl64(h, 23) * P2 + P3
    i += 4
  while i < n:
    h = h xor (uint64(uint8(s[i])) * P5)
    h = rotl64(h, 11) * P1
    inc i
  h = h xor (h shr 33)
  h *= P2
  h = h xor (h shr 29)
  h *= P3
  h = h xor (h shr 32)
  h

proc contentChecksum(content: string): string =
  xxh64(content).toHex(16).toLowerAscii()

# ---------------------------------------------------------------------------
# line helpers

proc splitLines(text: string): seq[string] =
  if text.len == 0: return @[""]
  result = text.split("\n")
  if text.endsWith("\n"): result.setLen(result.len - 1)

proc visLines(text: string): seq[string] =
  if text.len == 0: return @[]
  splitLines(text)

proc canon(line: string): string =
  ## CRs stripped, trailing whitespace trimmed — hash anchors stay stable
  ## across editor-save cycles that only touch trailing whitespace.
  var s = line.replace("\r", "")
  var i = s.len
  while i > 0:
    let b = s[i - 1]
    if b == ' ' or b == '\t' or b == '\v' or b == '\f' or b == '\r' or b == '\n':
      dec i
    elif i >= 2 and s[i - 2] == '\xC2' and b == '\xA0':
      dec i, 2                                    # U+00A0
    elif i >= 3 and s[i - 3] == '\xE1' and s[i - 2] == '\x9A' and b == '\x80':
      dec i, 3                                    # U+1680
    elif i >= 3 and s[i - 3] == '\xE2' and s[i - 2] == '\x80' and
        (b in {'\x80'..'\x8A', '\xA8', '\xA9', '\xAF'}):
      dec i, 3                                    # U+2000..U+200A, U+2028/29, U+202F
    elif i >= 3 and s[i - 3] == '\xE2' and s[i - 2] == '\x81' and b == '\x9F':
      dec i, 3                                    # U+205F
    elif i >= 3 and s[i - 3] == '\xE3' and s[i - 2] == '\x80' and b == '\x80':
      dec i, 3                                    # U+3000
    elif i >= 3 and s[i - 3] == '\xEF' and s[i - 2] == '\xBB' and b == '\xBF':
      dec i, 3                                    # U+FEFF
    else:
      break
  s.setLen(i)
  s

proc clipLine(line: string, maxLen = 200): string =
  let flat = line.replace("\n", "\\n")
  if flat.len > maxLen: flat[0 ..< maxLen] & "..."
  else: flat

proc formatSize(bytes: int): string =
  if bytes < 1024: $bytes & " B"
  elif bytes < 1024 * 1024: $(bytes div 1024) & " KB"
  elif bytes < 1024 * 1024 * 1024: $(bytes div (1024 * 1024)) & " MB"
  else: $(bytes div (1024 * 1024 * 1024)) & " GB"

# ---------------------------------------------------------------------------
# anchor alphabet / bitset

proc alphIndex(ch: char): int =
  case ch
  of 'A'..'Z': ord(ch) - ord('A')
  of 'a'..'z': 26 + ord(ch) - ord('a')
  of '0'..'9': 52 + ord(ch) - ord('0')
  else: -1

proc isAlph(ch: char): bool = alphIndex(ch) >= 0

proc idxToHash(idx: int): string =
  var idx = idx
  result = ""
  for j in 0 ..< HASH_LEN:
    result = ALPH[idx mod ALPH.len] & result
    idx = idx div ALPH.len

proc hashToIndex(hash: string): int =
  var idx = 0
  for j in 0 ..< HASH_LEN:
    let c = alphIndex(hash[j])
    if c < 0: return -1
    idx = idx * ALPH.len + c
  idx

type Bitset = seq[uint32]

proc newBitset(): Bitset = newSeq[uint32]((HASH_SPACE + 31) div 32)

proc getBit(bits: Bitset, idx: int): bool =
  (bits[idx shr 5] shr (idx and 31) and 1'u32) != 0

proc setBit(bits: var Bitset, idx: int) =
  bits[idx shr 5] = bits[idx shr 5] or (1'u32 shl (idx and 31))

proc nextZeroBit(bits: Bitset, start: int): int =
  var idx = start mod HASH_SPACE
  for i in 0 ..< HASH_SPACE:
    if not getBit(bits, idx): return idx
    idx += HASH_PROBE_STRIDE
    if idx >= HASH_SPACE: idx -= HASH_SPACE
  raise newException(ValueError,
    "[E_FILE_TOO_LARGE] Cannot allocate a unique hash anchor: the file " &
    "exceeds the " & $HASH_SPACE & "-line limit for " & $HASH_LEN &
    "-char hashline anchors. For very large files use bash or a " &
    "non-line-based approach.")

proc assignHash(used: var Bitset, baseIdx: int, hint: var int): string =
  if not getBit(used, baseIdx):
    setBit(used, baseIdx)
    hint = baseIdx + HASH_PROBE_STRIDE
    return idxToHash(baseIdx)
  let nextIdx = nextZeroBit(used, hint)
  setBit(used, nextIdx)
  hint = nextIdx + HASH_PROBE_STRIDE
  idxToHash(nextIdx)

proc lineHashesPure(content: string): seq[string] =
  let lines = splitLines(content)
  result = newSeq[string](lines.len)
  var used = newBitset()
  var hint = 0
  for i, line in lines:
    let c = canon(line)
    let baseIdx = int(xxh32(c) shr 14) mod HASH_SPACE
    result[i] = assignHash(used, baseIdx, hint)

# ---------------------------------------------------------------------------
# persistent store (config-dir JSON; the original used sqlite)

type
  SnapshotEntry = object
    checksum: string
    lineCount: int
    hashes: seq[string]
  UndoEntry = object
    content: string
    bom: string
    ending: string
    hashes: seq[string]
    resultContent: string

var
  gStorePath = ""
  gSnapshots = initTable[string, SnapshotEntry]()
  gUndo = initTable[string, UndoEntry]()
  gServed = initTable[string, seq[string]]()

proc configDir(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: xdg / "niffler-hashline-edit"
  else: getHomeDir() / ".config" / "niffler-hashline-edit"

proc storePath(): string =
  if gStorePath.len == 0: gStorePath = configDir() / "hash-store.json"
  gStorePath

proc validHashList(hashes: seq[string]): bool =
  for h in hashes:
    if h.len != HASH_LEN: return false
    for ch in h:
      if not isAlph(ch): return false
  var seen = initHashSet[string]()
  for h in hashes:
    if seen.contains(h): return false
    seen.incl(h)
  true

proc saveStore() =
  let doc = %*{
    "version": STORE_VERSION,
    "snapshots": newJObject(),
    "undo": newJObject(),
    "served": newJObject()
  }
  for path, e in gSnapshots:
    doc["snapshots"][path] = %*{"checksum": e.checksum,
                                "lineCount": e.lineCount, "hashes": e.hashes}
  for path, u in gUndo:
    doc["undo"][path] = %*{"content": u.content, "bom": u.bom,
                           "ending": u.ending, "hashes": u.hashes,
                           "resultContent": u.resultContent}
  for path, hashes in gServed:
    doc["served"][path] = %hashes
  writeAtomic(storePath(), $doc)

proc loadStore() =
  discard storePath()
  createDir(configDir())
  if not fileExists(storePath()): return
  var doc: JsonNode
  try:
    doc = parseJson(readFile(storePath()))
  except CatchableError:
    try: moveFile(storePath(), storePath() & ".corrupt-" & $epochTime().int64)
    except CatchableError: discard
    return
  if doc == nil or doc.kind != JObject:
    try: moveFile(storePath(), storePath() & ".corrupt-" & $epochTime().int64)
    except CatchableError: discard
    return
  let snaps = doc{"snapshots"}
  if snaps != nil and snaps.kind == JObject:
    for path, node in snaps:
      if node == nil or node.kind != JObject: continue
      let hnode = node{"hashes"}
      if hnode == nil or hnode.kind != JArray: continue
      var hashes: seq[string] = @[]
      var ok = true
      for h in hnode:
        if h.kind != JString:
          ok = false
          break
        hashes.add(h.getStr())
      if not ok or not validHashList(hashes): continue
      gSnapshots[path] = SnapshotEntry(
        checksum: node{"checksum"}.getStr(""),
        lineCount: node{"lineCount"}.getInt(0),
        hashes: hashes)
  let undos = doc{"undo"}
  if undos != nil and undos.kind == JObject:
    for path, node in undos:
      if node == nil or node.kind != JObject: continue
      let hnode = node{"hashes"}
      if hnode == nil or hnode.kind != JArray: continue
      var hashes: seq[string] = @[]
      var ok = true
      for h in hnode:
        if h.kind != JString:
          ok = false
          break
        hashes.add(h.getStr())
      if not ok or not validHashList(hashes): continue
      gUndo[path] = UndoEntry(
        content: node{"content"}.getStr(""),
        bom: node{"bom"}.getStr(""),
        ending: node{"ending"}.getStr(""),
        hashes: hashes,
        resultContent: node{"resultContent"}.getStr(""))
  let served = doc{"served"}
  if served != nil and served.kind == JObject:
    for path, node in served:
      if node == nil or node.kind != JArray: continue
      var hashes: seq[string] = @[]
      var ok = true
      for h in node:
        if h.kind != JString:
          ok = false
          break
        hashes.add(h.getStr())
      if not ok or not validHashList(hashes): continue
      gServed[path] = hashes

proc getSnapshot(path, content: string): seq[string] =
  let checksum = contentChecksum(content)
  let lineCount = splitLines(content).len
  if gSnapshots.hasKey(path):
    let e = gSnapshots[path]
    if e.checksum == checksum and e.lineCount == lineCount:
      return e.hashes
  @[]

proc upsertSnapshot(path, content: string, hashes: seq[string]) =
  gSnapshots[path] = SnapshotEntry(checksum: contentChecksum(content),
                                   lineCount: splitLines(content).len,
                                   hashes: hashes)
  saveStore()

proc getServed(path: string): tuple[present: bool, hashes: HashSet[string]] =
  if not gServed.hasKey(path): return (present: false, hashes: initHashSet[string]())
  var set = initHashSet[string]()
  for h in gServed[path]: set.incl(h)
  (present: true, hashes: set)

proc recordServed(path: string, hashes: seq[string]) =
  if hashes.len == 0: return
  var existing = if gServed.hasKey(path): gServed[path] else: newSeq[string]()
  for h in hashes:
    if existing.find(h) < 0: existing.add(h)
  existing.sort()
  gServed[path] = existing
  saveStore()

proc findSnapshotPaths(hashes: seq[string]): seq[string] =
  for path, e in gSnapshots:
    if hashes.allIt(e.hashes.contains(it)):
      result.add(path)

proc getUndoEntry(path: string): UndoEntry =
  if not gUndo.hasKey(path): UndoEntry(content: "", hashes: @[])
  else: gUndo[path]

proc deleteUndo(path: string) =
  if gUndo.hasKey(path):
    gUndo.del(path)
    saveStore()

proc saveUndo(path: string, entry: UndoEntry): tuple[persisted: bool,
                                                      restore: proc()] =
  ## Persist the undo record BEFORE the edit is written; a failed persist
  ## refuses the edit (the file is never touched). restore() re-installs
  ## the previous record if the write itself fails.
  let previous = if gUndo.hasKey(path): gUndo[path] else: UndoEntry(hashes: @[])
  let hadPrevious = gUndo.hasKey(path)
  gUndo[path] = entry
  try:
    saveStore()
    return (persisted: true, restore: proc() =
      if hadPrevious: gUndo[path] = previous
      else: gUndo.del(path)
      try: saveStore()
      except CatchableError: discard)
  except CatchableError:
    if hadPrevious: gUndo[path] = previous
    else: gUndo.del(path)
    return (persisted: false, restore: proc() = discard)

# ---------------------------------------------------------------------------
# path + atomic write

proc expand(path: string): string =
  let home = getHomeDir()
  if path == "~": home
  elif path.startsWith("~/"): home & path[1 .. ^1]
  else: path

proc toCwd(filePath, cwd: string): string =
  let expanded = expand(filePath)
  if expanded.startsWith("/"): expanded
  else: absolutePath(expanded, cwd)

proc readLink(p: string): string =
  var buf: array[0 .. 4095, char]
  let n = readlink(p.cstring, cast[cstring](addr buf[0]), 4096)
  if n < 0:
    raise newException(IOError, "readlink " & p)
  if n == 0: return ""
  result = newString(n)
  copyMem(cast[pointer](addr result[0]), cast[pointer](addr buf[0]), n)

proc isSymlink(p: string): bool =
  var st: Stat
  posixLstat(p.cstring, st) == 0 and (st.st_mode and Mode(S_IFMT)) == Mode(S_IFLNK)

proc resolveTarget(path: string): string =
  ## Follow symlinks component-by-component to the real target path.
  let absPath = absolutePath(path)
  let parts = absPath.split("/").filterIt(it.len > 0)
  var visited: seq[string] = @[]
  proc res(acc: string, rem: seq[string]): string =
    if rem.len == 0: return acc
    let candidate = acc / rem[0]
    let tail = rem[1 .. ^1]
    if not isSymlink(candidate):
      if not fileExists(candidate) and not dirExists(candidate):
        var rest = candidate
        for p in tail: rest = rest / p
        return rest
      return res(candidate, tail)
    if visited.contains(candidate):
      raise newException(IOError,
        "[E_ACCESS] Too many symbolic links while resolving: " & path)
    visited.add(candidate)
    let target = absolutePath(readLink(candidate), candidate.parentDir())
    let targetParts = target.split("/").filterIt(it.len > 0)
    res("/", targetParts & tail)
  res("/", parts)

proc sweepStaleTemps(dir: string) =
  if not dirExists(dir): return
  for f in walkFiles(dir / ".tmp-*"):
    try:
      let mt = getLastModificationTime(f)
      if epochTime() - mt.toUnixFloat() > 3600: removeFile(f)
    except CatchableError: discard

proc writeAtomic(path: string, content: string) =
  ## Temp file + rename in the same dir; preserves permissions and hard
  ## links (nlink > 1 files are rewritten in place, like the original).
  let target = resolveTarget(path)
  var st: Stat
  let rc = posixStat(target.cstring, st)
  if rc == 0 and st.st_nlink > 1:
    writeFile(target, content)
    return
  let dir = target.parentDir()
  sweepStaleTemps(dir)
  createDir(dir)
  let tmp = dir / (".tmp-" & newId())
  var f: File
  var opened = false
  try:
    f = open(tmp, fmWrite)
    opened = true
    f.write(content)
    if rc == 0:
      discard posixFchmod(cint(f.getFileHandle()), st.st_mode and Mode(0o7777))
    else:
      discard posixFchmod(cint(f.getFileHandle()), Mode(0o600))
    discard fsync(cint(f.getFileHandle()))
    f.close()
    opened = false
  except CatchableError:
    if opened: f.close()
    if fileExists(tmp): removeFile(tmp)
    raise
  if posixRename(tmp.cstring, target.cstring) != 0:
    let err = osLastError()
    if fileExists(tmp): removeFile(tmp)
    raise newException(IOError, "writeAtomic rename: " & osErrorMsg(err))
  var dfd = open(dir.cstring, O_RDONLY)
  if dfd >= 0:
    discard fsync(dfd)
    discard close(dfd)

# ---------------------------------------------------------------------------
# file kind detection + UTF-8 decode

proc decodeUtf8(data: string): tuple[text: string, hadErrors: bool] =
  ## Lenient UTF-8 decode: invalid bytes become U+FFFD (like JS TextDecoder
  ## with fatal:false). hadErrors also flags a literal U+FFFD in the source,
  ## matching the original's `decoded.includes("\uFFFD")` detection.
  proc cpToUtf8(cp: uint32): string =
    if cp < 0x80: return $char(cp)
    elif cp < 0x800:
      return char(0xC0 or (cp shr 6)) & char(0x80 or (cp and 0x3F))
    elif cp < 0x10000:
      return char(0xE0 or (cp shr 12)) &
        char(0x80 or ((cp shr 6) and 0x3F)) & char(0x80 or (cp and 0x3F))
    else:
      return char(0xF0 or (cp shr 18)) &
        char(0x80 or ((cp shr 12) and 0x3F)) &
        char(0x80 or ((cp shr 6) and 0x3F)) & char(0x80 or (cp and 0x3F))
  var i = 0
  let n = data.len
  while i < n:
    let b = uint8(data[i])
    var need = 0
    var cp: uint32
    if b < 0x80:
      result.text.add(char(b))
      inc i
      continue
    elif b >= 0xC2 and b <= 0xDF:
      need = 2
      cp = uint32(b and 0x1F)
    elif b >= 0xE0 and b <= 0xEF:
      need = 3
      cp = uint32(b and 0x0F)
      let b1 = if i + 1 < n: uint8(data[i + 1]) else: 0'u8
      if (b == 0xE0 and b1 < 0xA0) or (b == 0xED and b1 >= 0xA0):
        result.text.add("\uFFFD")
        result.hadErrors = true
        inc i
        continue
    elif b >= 0xF0 and b <= 0xF4:
      need = 4
      cp = uint32(b and 0x07)
      let b1 = if i + 1 < n: uint8(data[i + 1]) else: 0'u8
      if (b == 0xF0 and b1 < 0x90) or (b == 0xF4 and b1 >= 0x90):
        result.text.add("\uFFFD")
        result.hadErrors = true
        inc i
        continue
    else:
      result.text.add("\uFFFD")
      result.hadErrors = true
      inc i
      continue
    var j = i + 1
    var valid = true
    while j < n and j < i + need:
      let c = uint8(data[j])
      if (c and 0xC0) != 0x80:
        valid = false
        break
      cp = (cp shl 6) or uint32(c and 0x3F)
      inc j
    if not valid or j < i + need:
      result.text.add("\uFFFD")
      result.hadErrors = true
      inc i
      continue
    result.text.add(cpToUtf8(cp))
    i = j
  if result.text.contains("\uFFFD"): result.hadErrors = true

proc detectTextBom(sample: string): string =
  if sample.len >= 4 and uint8(sample[0]) == 0xFF and uint8(sample[1]) == 0xFE and
      uint8(sample[2]) == 0x00 and uint8(sample[3]) == 0x00:
    return "UTF-32LE"
  if sample.len >= 4 and uint8(sample[0]) == 0x00 and uint8(sample[1]) == 0x00 and
      uint8(sample[2]) == 0xFE and uint8(sample[3]) == 0xFF:
    return "UTF-32BE"
  if sample.len >= 2 and uint8(sample[0]) == 0xFF and uint8(sample[1]) == 0xFE:
    return "UTF-16LE"
  if sample.len >= 2 and uint8(sample[0]) == 0xFE and uint8(sample[1]) == 0xFF:
    return "UTF-16BE"
  ""

proc detectMime(sample: string): string =
  proc at(n: int): uint8 = uint8(sample[n])
  if sample.len >= 3 and at(0) == 0xFF and at(1) == 0xD8 and at(2) == 0xFF:
    return "image/jpeg"
  if sample.len >= 8 and at(0) == 0x89 and at(1) == 0x50 and at(2) == 0x4E and
      at(3) == 0x47 and at(4) == 0x0D and at(5) == 0x0A and at(6) == 0x1A and
      at(7) == 0x0A:
    return "image/png"
  if sample.startsWith("GIF87a") or sample.startsWith("GIF89a"):
    return "image/gif"
  if sample.len >= 12 and sample.startsWith("RIFF") and
      sample[8 .. 11] == "WEBP":
    return "image/webp"
  if sample.startsWith("BM"):
    return "image/bmp"
  if sample.len >= 4 and at(0) == 0x49 and at(1) == 0x49 and at(2) == 0x2A and
      at(3) == 0x00:
    return "image/tiff"
  if sample.len >= 4 and at(0) == 0x4D and at(1) == 0x4D and at(2) == 0x00 and
      at(3) == 0x2A:
    return "image/tiff"
  if sample.startsWith("{\\rtf"): return "application/rtf"
  if sample.startsWith("<?xml"): return "application/xml"
  if sample.startsWith("%PDF"): return "application/pdf"
  if sample.startsWith("%!PS"): return "application/postscript"
  if sample.startsWith("\x7FELF"): return "application/x-elf"
  if sample.len >= 4 and at(0) == 0xFE and at(1) == 0xED and at(2) == 0xFA and
      at(3) in {0xCE, 0xCF, 0xDE, 0xDF}:
    return "application/mach-binary"
  if sample.len >= 4 and at(0) == 0xCE and at(1) == 0xFA and at(2) == 0xED and
      at(3) == 0xFE:
    return "application/mach-binary"
  if sample.len >= 4 and at(0) == 0xCF and at(1) == 0xFA and at(2) == 0xED and
      at(3) == 0xFE:
    return "application/mach-binary"
  if sample.startsWith("\x1F\x8B"): return "application/gzip"
  if sample.len >= 4 and at(0) == 0x50 and at(1) == 0x4B and at(2) in {0x03, 0x05, 0x07}:
    return "application/zip"
  if sample.len >= 8 and at(0) == 0xD0 and at(1) == 0xCF and at(2) == 0x11 and
      at(3) == 0xE0 and at(4) == 0xA1 and at(5) == 0xB1 and at(6) == 0x1A and
      at(7) == 0xE1:
    return "application/x-ole-storage"
  if sample.startsWith("\x1A\x45\xDF\xA3"): return "video/x-matroska"
  if sample.startsWith("OggS"): return "audio/ogg"
  if sample.startsWith("Rar!\x1A\x07"): return "application/x-rar"
  if sample.startsWith("ID3"): return "audio/mpeg"
  if sample.startsWith("\x00asm"): return "application/wasm"
  ""

const
  IMG_TYPES = ["image/bmp", "image/gif", "image/jpeg", "image/png",
               "image/webp", "image/tiff"]
  TEXT_TYPES = ["application/rtf", "application/xml",
                "application/x-ms-regedit"]

proc isTextType(mime: string): bool =
  mime.startsWith("text/") or TEXT_TYPES.contains(mime)

proc looksLikeText(sample: string): bool =
  if '\0' in sample: return false
  not decodeUtf8(sample).hadErrors

type
  LFileKind = enum lfDir, lfImage, lfText, lfBinary, lfTooLarge
  LFile = object
    kind: LFileKind
    mime: string
    text: string
    hadUtf8Errors: bool

proc loadFileKindAndText(filePath, displayPath: string,
                         maxLines: int): LFile =
  let info = getFileInfo(filePath)
  if info.kind in {pcDir, pcLinkToDir}:
    return LFile(kind: lfDir)
  if info.kind != pcFile and info.kind != pcLinkToFile:
    return LFile(kind: lfBinary, mime: "unsupported file type")
  if info.size > MAX_BYTES:
    return LFile(kind: lfTooLarge,
                 mime: "exceeds the " & $(MAX_BYTES div (1024 * 1024)) &
                       "MB size limit")
  let data = readFile(filePath)
  let sampleLen = min(SNIFF_BYTES, data.len)
  let sample = data[0 ..< sampleLen]
  if sample.len == 0:
    return LFile(kind: lfText, text: "")
  let bom = detectTextBom(sample)
  if bom.len > 0:
    return LFile(kind: lfBinary, mime: bom & " encoded text")
  let mime = detectMime(sample)
  if mime.len > 0 and not isTextType(mime) and not looksLikeText(sample):
    if IMG_TYPES.contains(mime):
      return LFile(kind: lfImage, mime: mime)
    return LFile(kind: lfBinary, mime: mime)
  if mime.len == 0 and '\0' in sample:
    return LFile(kind: lfBinary, mime: "contains NUL bytes")
  let decoded = decodeUtf8(data)
  var newlineCount = 0
  for ch in decoded.text:
    if ch == '\n':
      inc newlineCount
      if newlineCount > maxLines:
        raise newException(ValueError,
          "[E_FILE_TOO_LARGE] " & displayPath & " has more than " & $maxLines &
          " lines, exceeding the " & $maxLines &
          "-line edit limit. Hashline editing targets source-sized files; " &
          "for very large files use bash or a non-line-based approach.")
  return LFile(kind: lfText, text: decoded.text, hadUtf8Errors: decoded.hadErrors)

proc valAccess(absPath, displayPath: string, writeAccess = false) =
  const
    R_OK = 4
    W_OK = 2
  let mode = if writeAccess: R_OK or W_OK else: R_OK
  if access(absPath.cstring, mode.cint) == 0: return
  if not fileExists(absPath) and not dirExists(absPath) and
      not symlinkExists(absPath):
    raise newException(ValueError, "[E_NOT_FOUND] File not found: " & displayPath)
  raise newException(ValueError,
    "[E_ACCESS] File is " & (if writeAccess: "not writable"
                             else: "not readable") & ": " & displayPath)

proc valKind(file: LFile, displayPath: string) =
  case file.kind
  of lfDir:
    raise newException(ValueError,
      "[E_NOT_TEXT] Path is a directory: " & displayPath &
      ". Use ls to inspect directories.")
  of lfBinary:
    raise newException(ValueError,
      "[E_NOT_TEXT] Path is a binary file: " & displayPath & " (" &
      file.mime & "). Hashline edit only supports text files.")
  of lfImage:
    raise newException(ValueError,
      "[E_NOT_TEXT] Path is an image file: " & displayPath &
      ". Hashline edit only supports text files.")
  of lfTooLarge:
    raise newException(ValueError,
      "[E_FILE_TOO_LARGE] File is too large: " & displayPath & " (" &
      file.mime & "). Hashline editing targets source-sized files; for very " &
      "large files use bash or a non-line-based approach.")
  of lfText: discard

# ---------------------------------------------------------------------------
# normalized file reading

proc detectEnding(content: string): string =
  let lfIdx = content.find("\n")
  if lfIdx < 0: return (if content.find("\r") >= 0: "\r" else: "\n")
  let crlfIdx = content.find("\r\n")
  if crlfIdx < 0: return "\n"
  return (if crlfIdx < lfIdx: "\r\n" else: "\n")

proc toLF(text: string): string =
  text.replace("\r\n", "\n").replace("\r", "\n")

proc restoreEndings(text, ending: string): string =
  if ending == "\r\n": text.replace("\n", "\r\n")
  elif ending == "\r": text.replace("\n", "\r")
  else: text

proc stripBOM(content: string): tuple[bom: string, text: string] =
  if content.startsWith("\uFEFF"):
    (bom: "\uFEFF", text: content[3 .. ^1])
  else:
    (bom: "", text: content)

type NormFile = object
  absolutePath: string
  normalized: string
  bom: string
  originalEnding: string
  fileHashes: seq[string]
  hadUtf8DecodeErrors: bool

proc readNormFile(path, cwd: string, writeAccess = false,
                  maxLines = MAX_HASH_LINES): NormFile =
  let absolutePath = toCwd(path, cwd)
  let resolvedPath = resolveTarget(absolutePath)
  valAccess(resolvedPath, path, writeAccess)
  let file = loadFileKindAndText(resolvedPath, path, maxLines)
  valKind(file, path)
  let (bom, rawContent) = stripBOM(file.text)
  let originalEnding = detectEnding(rawContent)
  let normalized = toLF(rawContent)
  let lineCount = visLines(normalized).len
  if lineCount > maxLines:
    raise newException(ValueError,
      "[E_FILE_TOO_LARGE] " & path & " has " & $lineCount & " lines, " &
      "exceeding the " & $maxLines & "-line edit limit. Hashline editing " &
      "targets source-sized files; for very large files use bash or a " &
      "non-line-based approach.")
  return NormFile(absolutePath: resolvedPath, normalized: normalized,
                  bom: bom, originalEnding: originalEnding,
                  fileHashes: lineHashes(normalized, resolvedPath),
                  hadUtf8DecodeErrors: file.hadUtf8Errors)

# ---------------------------------------------------------------------------
# stable hashing across edits

proc nearestNew(candidates: seq[int], target: int): int =
  var lo = 0
  var hi = candidates.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if candidates[mid] < target: lo = mid + 1
    else: hi = mid
  let left = lo - 1
  let right = lo
  if left >= 0 and (right >= candidates.len or
      target - candidates[left] <= candidates[right] - target):
    return left
  if right < candidates.len: right else: -1

proc mapStableHashes(oldContent: string, oldHashes: seq[string],
                     newContent: string,
                     removedHashes: HashSet[string]): seq[string] =
  let oldLines = splitLines(oldContent)
  let newLines = splitLines(newContent)
  result = newSeq[string](newLines.len)
  var used = newBitset()
  var hint = 0
  let removed = removedHashes

  var oldHashIndex = initTable[string, int]()
  for i in 0 ..< oldHashes.len:
    let hash = oldHashes[i]
    oldHashIndex[hash] = i
    let idx = hashToIndex(hash)
    if idx >= 0: setBit(used, idx)

  var removedIndexes = initHashSet[int]()
  for hash in removed:
    if oldHashIndex.hasKey(hash):
      removedIndexes.incl(oldHashIndex[hash])

  var spanStart = oldLines.len
  var spanEnd = -1
  for idx in removedIndexes:
    if idx < spanStart: spanStart = idx
    if idx > spanEnd: spanEnd = idx
  let spanLen = if spanEnd >= spanStart: spanEnd - spanStart + 1 else: 0
  let replacementLen = newLines.len - oldLines.len + spanLen
  let shiftAfterSpan = if spanEnd >= spanStart: replacementLen - spanLen else: 0

  var survivors: seq[int] = @[]
  var removedEntries: seq[int] = @[]
  for i in 0 ..< oldLines.len:
    if removedIndexes.contains(i): removedEntries.add(i)
    else: survivors.add(i)

  var newByContent = initTable[string, seq[int]]()
  for i in 0 ..< newLines.len:
    let key = canon(newLines[i])
    var list = newByContent.getOrDefault(key)
    list.add(i)
    newByContent[key] = list

  proc markUsed(hash: string) =
    let idx = hashToIndex(hash)
    if idx >= 0:
      setBit(used, idx)
      if idx + HASH_PROBE_STRIDE > hint: hint = idx + HASH_PROBE_STRIDE

  for entry in survivors:
    if not newByContent.hasKey(canon(oldLines[entry])): continue
    var candidates = newByContent[canon(oldLines[entry])]
    if candidates.len == 0: continue
    let target = if entry > spanEnd: entry + shiftAfterSpan else: entry
    let pos = nearestNew(candidates, target)
    if pos < 0: continue
    let newIdx = candidates[pos]
    candidates.delete(pos)
    newByContent[canon(oldLines[entry])] = candidates
    result[newIdx] = oldHashes[entry]
    markUsed(oldHashes[entry])

  var removedByContent = initTable[string, tuple[hashes: seq[string], pos: int]]()
  for entry in removedEntries:
    let key = oldLines[entry]
    var queue = removedByContent.getOrDefault(key)
    queue.hashes.add(oldHashes[entry])
    removedByContent[key] = queue

  for i in 0 ..< newLines.len:
    if result[i].len > 0: continue
    if not removedByContent.hasKey(newLines[i]): continue
    var queue = removedByContent[newLines[i]]
    if queue.pos >= queue.hashes.len: continue
    result[i] = queue.hashes[queue.pos]
    inc queue.pos
    removedByContent[newLines[i]] = queue

  for i in 0 ..< newLines.len:
    if result[i].len > 0: continue
    let c = canon(newLines[i])
    let baseIdx = int(xxh32(c) shr 14) mod HASH_SPACE
    result[i] = assignHash(used, baseIdx, hint)

proc lineHashes(content, path: string,
                previous: tuple[content: string, hashes: seq[string],
                                removedHashes: HashSet[string]]): seq[string] =
  if previous.hashes.len > 0:
    result = mapStableHashes(previous.content, previous.hashes, content,
                             previous.removedHashes)
    upsertSnapshot(path, content, result)
    return
  result = getSnapshot(path, content)
  if result.len == 0:
    result = lineHashesPure(content)
    upsertSnapshot(path, content, result)

# ---------------------------------------------------------------------------
# anchor parsing + edit resolution

proc parseHashRef(refArg: string): string =
  ## Returns the bare 3-char hash or raises [E_BAD_REF] with guidance.
  ## A valid 3-char alphanumeric hash is accepted even when it starts with
  ## a digit (digits are part of the anchor alphabet).
  let trimmed = refArg.strip()
  if trimmed.len == HASH_LEN and trimmed.allIt(isAlph(it)):
    return trimmed
  if trimmed.len == 0:
    raise newException(ValueError,
      "[E_BAD_REF] Invalid anchor. Expected a 3-char alphanumeric anchor (e.g. \"aB3\").")
  if trimmed[0] in {'0' .. '9'}:
    raise newException(ValueError,
      "[E_BAD_REF] Invalid anchor. Use the hash alone (e.g. \"aB3\") — no line numbers or trailing content.")
  if trimmed.contains(HASH_SEP):
    raise newException(ValueError,
      "[E_BAD_REF] Invalid anchor \"" & trimmed &
      "\". remove_from and remove_to must contain the 3-char hash only — remove everything from \"\u2502\" onward.")
  raise newException(ValueError,
    "[E_BAD_REF] Invalid anchor \"" & trimmed &
    "\". Expected a 3-char alphanumeric anchor (e.g. \"aB3\").")

proc parseText(edit: seq[string], warnings: var seq[string]): seq[string] =
  var splitFlag = false
  for line in edit:
    let normalized = line.replace("\r\n", "\n").replace("\r", "\n")
    if normalized != line: splitFlag = true
    for part in normalized.split("\n"): result.add(part)
  if splitFlag:
    warnings.add("[E_BAD_SHAPE] Autocorrected: split replacement_lines " &
      "element(s) containing embedded newlines into separate lines.")

type
  AnchorEdit = object
    contentLines: seq[string]
    startHash: string
    endHash: string
  RHEdit = object
    contentLines: seq[string]
    startLine: int          # 1-based
    endLine: int
    startHash: string
    endHash: string
  BDup = object
    kind: string            # trailing | leading | first-new-after | last-new-before
    replacementLineIndex: int
  AutoFix = object
    kind: string
    removedLine: string
    removedLineIndex: int

proc parseBound(refArg: string, warnings: var seq[string]): string =
  ## Strips a copied diff-preview marker (+/-) or HASH│ prefix from an
  ## anchor field, like the original's ANCHOR_ROW_RE autocorrect.
  let trimmed = refArg.strip()
  if trimmed.len == 0: return trimmed
  var idx = 0
  var marker = ""
  if trimmed[0] == '+' or trimmed[0] == '-':
    marker = $trimmed[0]
    inc idx
  if trimmed.len >= idx + 3 + 3 and
      isAlph(trimmed[idx]) and isAlph(trimmed[idx + 1]) and
      isAlph(trimmed[idx + 2]) and trimmed[idx + 3 .. idx + 5] == HASH_SEP:
    var message: string
    if marker == "+":
      message = "[E_BAD_REF] Autocorrected: stripped diff-preview marker " &
        "copied from the diff preview in remove_from/remove_to entry \"" &
        trimmed & "\"."
    elif marker == "-":
      message = "[E_BAD_REF] Autocorrected: stripped leading \"-\" marker " &
        "in remove_from/remove_to entry \"" & trimmed & "\"."
    else:
      message = "[E_BAD_REF] Autocorrected: stripped \"HASH\u2502\" prefix " &
        "copied from read output in remove_from/remove_to entry \"" &
        trimmed & "\"."
    warnings.add(message)
    return trimmed[idx .. idx + 2]
  trimmed

proc resEdit(removeFrom, removeTo: string, replacementLines: seq[string],
             warnings: var seq[string]): AnchorEdit =
  let contentLines = parseText(replacementLines, warnings)
  let startHash = parseHashRef(parseBound(removeFrom, warnings))
  let endHash = parseHashRef(parseBound(removeTo, warnings))
  AnchorEdit(contentLines: contentLines, startHash: startHash,
             endHash: endHash)

proc stripBarePrefixes(edit: AnchorEdit, fileHashes: seq[string],
                       warnings: var seq[string]): AnchorEdit =
  var stripped: seq[tuple[lineIndex: int, matched: bool]] = @[]
  var contentLines: seq[string] = @[]
  for lineIndex, line in edit.contentLines:
    var i = 0
    while i < line.len and line[i] in {' ', '\t', '\v', '\f', '\r'}: inc i
    if line.len >= i + 6 and
        isAlph(line[i]) and isAlph(line[i + 1]) and isAlph(line[i + 2]) and
        line[i + 3 .. i + 5] == HASH_SEP:
      let hash = line[i .. i + 2]
      stripped.add((lineIndex: lineIndex, matched: fileHashes.contains(hash)))
      contentLines.add(line[i + 6 .. ^1])
    else:
      contentLines.add(line)
  if stripped.len == 0: return edit
  var locations: seq[string] = @[]
  for s in stripped:
    locations.add("replacement_lines line " & $(s.lineIndex + 1))
  let matchedCount = stripped.filterIt(it.matched).len
  let evidence = if matchedCount == 0:
    "none of the stripped hashes match current file lines"
  else:
    $matchedCount & " of " & $stripped.len &
    " stripped hash(es) match current file lines"
  let guidance = if matchedCount == 0:
    " Verify that these lines were pasted from read output; literal " &
    "content starting with 'HASH\u2502' would be altered by this strip."
  else:
    ""
  warnings.add("[E_BARE_HASH_PREFIX] Autocorrected: stripped \"HASH\u2502\" " &
    "prefix copied from read output in " & locations.join(", ") & " (" &
    evidence & ")." & guidance)
  AnchorEdit(contentLines: contentLines, startHash: edit.startHash,
             endHash: edit.endHash)

proc stripDiffPrefixes(edit: AnchorEdit, warnings: var seq[string]): AnchorEdit =
  var stripped: seq[int] = @[]
  var contentLines: seq[string] = @[]
  for lineIndex, line in edit.contentLines:
    var removed = 0
    if line.len >= 7 and line[0] == '+' and
        isAlph(line[1]) and isAlph(line[2]) and isAlph(line[3]) and
        line[4 .. 6] == HASH_SEP:
      removed = 7
    elif line.len >= 7 and line[0] == '-' and
        ((isAlph(line[1]) and isAlph(line[2]) and isAlph(line[3]) and
          line[4 .. 6] == HASH_SEP) or
         (line[1] == ' ' and line[2] == ' ' and line[3] == ' ' and
          line[4 .. 6] == HASH_SEP)):
      removed = 7
    if removed > 0:
      stripped.add(lineIndex)
      contentLines.add(line[removed .. ^1])
    else:
      contentLines.add(line)
  if stripped.len == 0: return edit
  var locations: seq[string] = @[]
  for i in stripped:
    locations.add("replacement_lines line " & $(i + 1))
  warnings.add("[E_INVALID_PATCH] Autocorrected: stripped diff-preview " &
    "marker copied from the diff preview in " & locations.join(", ") & ".")
  AnchorEdit(contentLines: contentLines, startHash: edit.startHash,
             endHash: edit.endHash)

proc swapReversedRanges(edit: AnchorEdit, fileHashes: seq[string],
                        warnings: var seq[string]): AnchorEdit =
  var lineByHash = initTable[string, int]()
  for i, hash in fileHashes:
    lineByHash[hash] = i + 1
  let startLine = if lineByHash.hasKey(edit.startHash): lineByHash[edit.startHash] else: -1
  let endLine = if lineByHash.hasKey(edit.endHash): lineByHash[edit.endHash] else: -1
  if startLine < 0 or endLine < 0 or startLine <= endLine: return edit
  warnings.add("[E_BAD_OP] Autocorrected: remove_from and remove_to were " &
    "reversed (remove_from " & edit.startHash & " is after remove_to " &
    edit.endHash & "); swapped the pair.")
  AnchorEdit(contentLines: edit.contentLines, startHash: edit.endHash,
             endHash: edit.startHash)

proc warnUnicodeEsc(edit: AnchorEdit, warnings: var seq[string]) =
  for line in edit.contentLines:
    if line.toLowerAscii().contains("\\udddd"):
      warnings.add("Detected literal \\uDDDD in edit content; no " &
        "autocorrection applied. Verify whether this should be a real " &
        "Unicode escape or plain text.")
      return

# --- boundary-duplicate detection (re-included unchanged blocks) ---

proc lastNonEmptyIndex(lines: seq[string]): int =
  for i in countdown(lines.len - 1, 0):
    if lines[i].len > 0: return i
  -1

proc firstNonEmptyIndex(lines: seq[string]): int =
  for i in 0 ..< lines.len:
    if lines[i].len > 0: return i
  -1

proc trailingDups(contentLines, fileLines: seq[string], endLine: int): seq[BDup] =
  let start = lastNonEmptyIndex(contentLines)
  if start < 0: return @[]
  var dups: seq[BDup] = @[]
  let maxK = min(start + 1, fileLines.len - endLine)
  var k = 0
  while k < maxK and contentLines[start - k] == fileLines[endLine + k]:
    dups.add(BDup(kind: "trailing", replacementLineIndex: start - k))
    inc k
  dups

proc leadingDups(contentLines, fileLines: seq[string], startLine: int): seq[BDup] =
  let start = firstNonEmptyIndex(contentLines)
  if start < 0: return @[]
  var dups: seq[BDup] = @[]
  let maxK = min(contentLines.len - start, startLine - 1)
  var k = 0
  while k < maxK and contentLines[start + k] == fileLines[startLine - 2 - k]:
    dups.add(BDup(kind: "leading", replacementLineIndex: start + k))
    inc k
  dups

proc sectionIsUnique(canonLines: seq[string], start, length: int): bool =
  var count = 0
  var i = 0
  while i + length <= canonLines.len:
    var k = 0
    while k < length and canonLines[i + k] == canonLines[start + k]: inc k
    if k < length:
      inc i
      continue
    inc count
    if count > 1: return false
    inc i
  true

proc canonCounts(lines: seq[string]): Table[string, int] =
  for line in lines:
    let key = canon(line)
    result[key] = result.getOrDefault(key) + 1

proc findNewEdge(contentLines, rangeLines: seq[string],
                 fromEnd: bool): tuple[index: int, line: string] =
  var multiset = canonCounts(rangeLines)
  if fromEnd:
    for i in countdown(contentLines.len - 1, 0):
      let line = contentLines[i]
      if line.len == 0: continue
      let key = canon(line)
      let count = multiset.getOrDefault(key)
      if count > 0:
        multiset[key] = count - 1
      else:
        return (index: i, line: line)
  else:
    for i in 0 ..< contentLines.len:
      let line = contentLines[i]
      if line.len == 0: continue
      let key = canon(line)
      let count = multiset.getOrDefault(key)
      if count > 0:
        multiset[key] = count - 1
      else:
        return (index: i, line: line)
  (index: -1, line: "")

proc firstNewAfterDups(contentLines, rangeLines, canonLines: seq[string],
                       endLine: int): seq[BDup] =
  let firstNew = findNewEdge(contentLines, rangeLines, false)
  if firstNew.index < 0: return @[]
  let maxK = min(contentLines.len - firstNew.index, canonLines.len - endLine)
  var runLen = 0
  while runLen < maxK and
      canon(contentLines[firstNew.index + runLen]) == canonLines[endLine + runLen]:
    inc runLen
  if runLen == 0 or not sectionIsUnique(canonLines, endLine, runLen): return @[]
  var dups: seq[BDup] = @[]
  for k in 0 ..< runLen:
    dups.add(BDup(kind: "first-new-after",
                  replacementLineIndex: firstNew.index + k))
  dups

proc lastNewBeforeDups(contentLines, rangeLines, canonLines: seq[string],
                       startLine: int): seq[BDup] =
  let lastNew = findNewEdge(contentLines, rangeLines, true)
  if lastNew.index < 0: return @[]
  let maxK = min(lastNew.index + 1, startLine - 1)
  var runLen = 0
  while runLen < maxK and
      canon(contentLines[lastNew.index - runLen]) ==
        canonLines[startLine - 2 - runLen]:
    inc runLen
  if runLen == 0: return @[]
  let sectionStart = startLine - 1 - runLen
  if not sectionIsUnique(canonLines, sectionStart, runLen): return @[]
  var dups: seq[BDup] = @[]
  for k in 0 ..< runLen:
    dups.add(BDup(kind: "last-new-before",
                  replacementLineIndex: lastNew.index - k))
  dups

# --- anchor resolution + mismatch feedback ---

type
  MismatchKind = enum mkNotFound, mkAmbiguous
  HMismatch = ref object
    hash: string
    kind: MismatchKind
    candidates: seq[int]        # 1-based lines (ambiguous only)
    ctxLine: int                # 1-based context anchor (not_found only)
    ctxHash: string

proc fmtMismatchWithHashes(mismatches: seq[HMismatch], fileLines,
                           fileHashes: seq[string],
                           filePath: string): tuple[text: string, hashes: seq[string]] =
  var lines: seq[string] = @[]
  var hashes: seq[string] = @[]
  var notFound: seq[HMismatch] = @[]
  var ambiguous: seq[HMismatch] = @[]
  for m in mismatches:
    if m.kind == mkNotFound: notFound.add(m)
    else: ambiguous.add(m)
  if notFound.len > 0:
    var refList: seq[string] = @[]
    for m in notFound: refList.add("\"" & m.hash & "\"")
    var line = "[E_STALE_ANCHOR] " & $notFound.len &
      " stale anchor" & (if notFound.len > 1: "s" else: "") &
      (if filePath.len > 0: " in " & filePath else: "") & ": " &
      refList.join(", ") &
      ". The file content has changed since those anchors were read. " &
      "Call read() to get fresh anchors, then copy the 3-char HASH of the " &
      "start and end of the range you are replacing into remove_from and " &
      "remove_to of your next replace call."
    lines.add(line)
    for m in notFound:
      if m.ctxLine <= 0: continue
      let fromLine = max(1, m.ctxLine - 1)
      let toLine = min(fileLines.len, m.ctxLine + 1)
      var rows: seq[string] = @[]
      for ln in fromLine .. toLine:
        hashes.add(fileHashes[ln - 1])
        rows.add("    " & $ln & ": " & fileHashes[ln - 1] & HASH_SEP &
                 clipLine(fileLines[ln - 1]))
      lines.add("")
      lines.add("  Current context around resolved anchor \"" & m.ctxHash &
        "\" (line " & $m.ctxLine & "):\n" & rows.join("\n"))
  if ambiguous.len > 0:
    if lines.len > 0: lines.add("")
    lines.add("[E_AMBIGUOUS_ANCHOR] " & $ambiguous.len & " ambiguous anchor" &
      (if ambiguous.len > 1: "s" else: "") &
      (if filePath.len > 0: " in " & filePath else: "") &
      ". Call read() to get fresh anchors, then copy the 3-char HASH of the " &
      "start and end of the range you are replacing into remove_from and " &
      "remove_to of your next replace call.")
    for m in ambiguous:
      let sample = m.candidates[0 ..< min(5, m.candidates.len)]
      let more = if m.candidates.len > sample.len:
        ", ... (+" & $(m.candidates.len - sample.len) & " more)"
      else: ""
      var linesOut: seq[string] = @[]
      for line in sample:
        hashes.add(fileHashes[line - 1])
        linesOut.add("    " & $line & ": " & fileHashes[line - 1] & HASH_SEP &
                     clipLine(fileLines[line - 1]))
      lines.add("  Hash \"" & m.hash & "\" matches lines " &
        sample.join(", ") & more & ".\n" & linesOut.join("\n"))
  (text: lines.join("\n"), hashes: hashes)

type
  ValEditResult = object
    resolved: RHEdit
    hasResolved: bool
    mismatches: seq[HMismatch]
    boundaryDups: seq[BDup]

proc valEdit(edit: AnchorEdit, fileLines, fileHashes: seq[string],
             warnings: var seq[string]): ValEditResult =
  if fileHashes.len != fileLines.len:
    raise newException(ValueError,
      "valEdit: fileHashes.length (" & $fileHashes.len &
      ") must match fileLines.length (" & $fileLines.len & ").")
  var hashIndex = initTable[string, seq[int]]()
  for i, h in fileHashes:
    var list = hashIndex.getOrDefault(h)
    list.add(i + 1)
    hashIndex[h] = list

  proc tryResolve(refHash: string): tuple[line: int, hash: string,
                                          mismatch: HMismatch] =
    if not hashIndex.hasKey(refHash) or hashIndex[refHash].len == 0:
      return (line: -1, hash: "",
              mismatch: HMismatch(hash: refHash, kind: mkNotFound))
    let matches = hashIndex[refHash]
    if matches.len > 1:
      return (line: -1, hash: "",
              mismatch: HMismatch(hash: refHash, kind: mkAmbiguous,
                                  candidates: matches))
    (line: matches[0], hash: refHash, mismatch: nil)

  let startRes = tryResolve(edit.startHash)
  let endRes = tryResolve(edit.endHash)
  if startRes.line < 0 or endRes.line < 0:
    if startRes.line < 0 and endRes.line >= 0 and
        startRes.mismatch != nil and startRes.mismatch.kind == mkNotFound:
      startRes.mismatch.ctxLine = endRes.line
      startRes.mismatch.ctxHash = endRes.hash
    elif endRes.line < 0 and startRes.line >= 0 and
        endRes.mismatch != nil and endRes.mismatch.kind == mkNotFound:
      endRes.mismatch.ctxLine = startRes.line
      endRes.mismatch.ctxHash = startRes.hash
    var mismatches: seq[HMismatch] = @[]
    if startRes.mismatch != nil: mismatches.add(startRes.mismatch)
    if endRes.mismatch != nil: mismatches.add(endRes.mismatch)
    return ValEditResult(hasResolved: false, mismatches: mismatches)

  let endLine = endRes.line
  let rangeLines = fileLines[startRes.line - 1 ..< endLine]
  var canonLines: seq[string] = @[]
  for line in fileLines: canonLines.add(canon(line))
  result.boundaryDups.add(trailingDups(edit.contentLines, fileLines, endLine))
  result.boundaryDups.add(leadingDups(edit.contentLines, fileLines,
                                      startRes.line))
  result.boundaryDups.add(firstNewAfterDups(edit.contentLines, rangeLines,
                                            canonLines, endLine))
  result.boundaryDups.add(lastNewBeforeDups(edit.contentLines, rangeLines,
                                            canonLines, startRes.line))
  result.resolved = RHEdit(contentLines: edit.contentLines,
                           startLine: startRes.line, endLine: endRes.line,
                           startHash: startRes.hash, endHash: endRes.hash)
  result.hasResolved = true

proc raiseAnchorMismatch(mismatches: seq[HMismatch], fileLines,
                         fileHashes: seq[string], filePath: string) =
  let feedback = fmtMismatchWithHashes(mismatches, fileLines, fileHashes,
                                       filePath)
  var e = newException(AnchorMismatchError, feedback.text)
  e.feedbackHashes = feedback.hashes
  raise e

proc assertRangeServed(resolved: RHEdit, fileLines, fileHashes: seq[string],
                       served: HashSet[string], filePath: string) =
  if fileHashes.len != fileLines.len:
    raise newException(ValueError,
      "assertRangeServed: fileHashes.length (" & $fileHashes.len &
      ") must match fileLines.length (" & $fileLines.len & ").")
  let startLine = resolved.startLine
  let endLine = resolved.endLine
  var mismatchLines: seq[int] = @[]
  for line in startLine .. endLine:
    if not served.contains(fileHashes[line - 1]): mismatchLines.add(line)
  if mismatchLines.len == 0: return

  let rangeLength = endLine - startLine + 1
  let shownLength = min(rangeLength, MAX_RANGE_STALE_LINES)
  var rows: seq[string] = @[]
  var shownHashes: seq[string] = @[]
  for line in startLine ..< startLine + shownLength:
    let hash = fileHashes[line - 1]
    shownHashes.add(hash)
    rows.add(hash & HASH_SEP & fileLines[line - 1])
  let location = if filePath.len > 0: " in " & filePath else: ""
  let first = mismatchLines[0]
  let mismatchText = if mismatchLines.len == 1:
    "Line " & $first & " of the replaced range (lines " & $startLine & "-" &
    $endLine & ")" & location & " does not match"
  else:
    $mismatchLines.len & " of " & $rangeLength & " line(s) in the replaced " &
    "range (lines " & $startLine & "-" & $endLine & ")" & location &
    " do not match"
  let capHint = if rangeLength > shownLength:
    "\n\n[The range has " & $rangeLength & " lines; showing the first " &
    $shownLength & ". Call read() with offset=" & $(startLine + shownLength) &
    " to see the rest.]"
  else: ""
  var e = newException(RangeStaleError,
    "[E_RANGE_STALE] " & mismatchText &
    " what was previously shown: the file changed on disk after the " &
    "anchors were read, or the line(s) were never shown. Nothing was " &
    "modified. Current range with fresh anchors:\n\n" & rows.join("\n") &
    capHint)
  e.rangeHashes = shownHashes
  raise e

# ---------------------------------------------------------------------------
# applying the edit

proc buildIdx(content: string): tuple[fileLines: seq[string],
                                      lineStarts: seq[int]] =
  result.fileLines = splitLines(content)
  var offset = 0
  for index in 0 ..< result.fileLines.len:
    result.lineStarts.add(offset)
    offset += result.fileLines[index].len
    if index < result.fileLines.len - 1: inc offset

proc fmtRegion(hashes, lines: seq[string]): string =
  if hashes.len != lines.len:
    raise newException(ValueError,
      "fmtRegion: hashes.length (" & $hashes.len & ") must match lines.length (" &
      $lines.len & ").")
  var rows: seq[string] = @[]
  for i in 0 ..< lines.len:
    rows.add(hashes[i] & HASH_SEP & lines[i])
  rows.join("\n")

proc changedRange(original, newContent: string): tuple[firstChangedLine,
                                                       lastChangedLine: int] =
  if original == newContent: return (-1, -1)
  if original.len == 0:
    return (1, splitLines(newContent).len)
  let originalLines = splitLines(original)
  let resultLines = splitLines(newContent)
  if originalLines.len == resultLines.len:
    var same = true
    for i in 0 ..< originalLines.len:
      if originalLines[i] != resultLines[i]:
        same = false
        break
    if same: return (-1, -1)
  let minLen = min(originalLines.len, resultLines.len)
  var first = 0
  while first < minLen and originalLines[first] == resultLines[first]:
    inc first
  var lastOrig = originalLines.len - 1
  var lastRes = resultLines.len - 1
  while lastOrig >= first and lastRes >= first and
      originalLines[lastOrig] == resultLines[lastRes]:
    dec lastOrig
    dec lastRes
  (first + 1, max(first, lastRes) + 1)

proc resToSpan(edit: RHEdit, content: string,
               lineIndex: tuple[fileLines: seq[string],
                                lineStarts: seq[int]]): tuple[kind: string,
                                                              start, len: int,
                                                              replacement: string] =
  let fileLines = lineIndex.fileLines
  let lineStarts = lineIndex.lineStarts
  let startLine = edit.startLine
  let endLine = edit.endLine
  let originalLines = fileLines[startLine - 1 ..< endLine]
  if originalLines.len == edit.contentLines.len:
    var same = true
    for i in 0 ..< originalLines.len:
      if originalLines[i] != edit.contentLines[i]:
        same = false
        break
    if same:
      return (kind: "noop", start: 0, len: 0,
              replacement: originalLines.join("\n"))
  if edit.contentLines.len > 0:
    let start = lineStarts[startLine - 1]
    let len = lineStarts[endLine - 1] + fileLines[endLine - 1].len - start
    return (kind: "replace", start: start, len: len,
            replacement: edit.contentLines.join("\n"))
  if startLine == 1 and endLine == fileLines.len:
    return (kind: "replace", start: 0, len: content.len, replacement: "")
  if endLine < fileLines.len:
    let start = lineStarts[startLine - 1]
    let len = lineStarts[endLine] - start
    return (kind: "replace", start: start, len: len, replacement: "")
  if content.endsWith("\n"):
    let start = lineStarts[startLine - 1]
    let len = content.len - start
    return (kind: "replace", start: start, len: len, replacement: "")
  let prevLine = if startLine >= 2: fileLines[startLine - 2] else: ""
  let start = if prevLine.len == 0:
    lineStarts[startLine - 1]
  else:
    max(0, lineStarts[startLine - 1] - 1)
  (kind: "replace", start: start, len: content.len - start, replacement: "")

type ApplyResult = object
  content: string
  firstChangedLine: int      # -1 = none
  lastChangedLine: int
  warnings: seq[string]
  noopLoc: string
  noopContent: string
  autoFixes: seq[AutoFix]

proc applyEdit(content: string, edit: AnchorEdit, fileHashes: seq[string],
               filePath: string, served: HashSet[string],
               hasServed: bool): ApplyResult =
  let lineIndex = buildIdx(content)
  var warnings: seq[string] = @[]

  let rangeFixed = swapReversedRanges(edit, fileHashes, warnings)
  var prefixFixed = stripBarePrefixes(rangeFixed, fileHashes, warnings)
  prefixFixed = stripDiffPrefixes(prefixFixed, warnings)

  var initial = valEdit(prefixFixed, lineIndex.fileLines, fileHashes, warnings)
  if not initial.hasResolved:
    raiseAnchorMismatch(initial.mismatches, lineIndex.fileLines, fileHashes,
                        filePath)

  warnUnicodeEsc(prefixFixed, warnings)

  var resolved = initial.resolved
  var autoFixes: seq[AutoFix] = @[]
  if initial.boundaryDups.len > 0:
    var corrected = prefixFixed
    var seen = initHashSet[int]()
    var uniqueDups: seq[BDup] = @[]
    for dup in initial.boundaryDups:
      if seen.contains(dup.replacementLineIndex): continue
      seen.incl(dup.replacementLineIndex)
      uniqueDups.add(dup)
    uniqueDups.sort(proc(a, b: BDup): int = b.replacementLineIndex - a.replacementLineIndex)
    for dup in uniqueDups:
      let idx = dup.replacementLineIndex
      if idx < 0 or idx >= corrected.contentLines.len: continue
      let removed = corrected.contentLines[idx]
      corrected.contentLines.delete(idx)
      autoFixes.add(AutoFix(kind: dup.kind, removedLine: removed,
                            removedLineIndex: idx))
    var correctedResult = valEdit(corrected, lineIndex.fileLines, fileHashes,
                                  warnings)
    if not correctedResult.hasResolved:
      raiseAnchorMismatch(correctedResult.mismatches, lineIndex.fileLines,
                          fileHashes, filePath)
    resolved = correctedResult.resolved

  if hasServed:
    assertRangeServed(resolved, lineIndex.fileLines, fileHashes, served,
                      filePath)

  let span = resToSpan(resolved, content, lineIndex)
  if span.kind == "noop":
    return ApplyResult(content: content, firstChangedLine: -1,
                       lastChangedLine: -1, warnings: warnings,
                       noopLoc: resolved.startHash, noopContent: span.replacement)

  let edited = content[0 ..< span.start] & span.replacement &
    content[span.start + span.len .. ^1]
  if content.len > 0 and edited.len == 0:
    raise newException(ValueError,
      "[E_WOULD_EMPTY] Cannot empty a non-empty file via edit. Use bash " &
      "(printf '' > file) if you need to clear the file.")
  let range = changedRange(content, edited)
  ApplyResult(content: edited, firstChangedLine: range.firstChangedLine,
              lastChangedLine: range.lastChangedLine, warnings: warnings,
              autoFixes: autoFixes)

# ---------------------------------------------------------------------------
# diff rendering (anchored, context-aware)

type
  DiffPart = object
    kind: string        # "added" | "removed" | "unchanged"
    lines: seq[string]

proc pushPart(parts: var seq[DiffPart], kind, line: string) =
  if parts.len > 0 and parts[^1].kind == kind:
    parts[^1].lines.add(line)
  else:
    parts.add(DiffPart(kind: kind, lines: @[line]))

proc lcsParts(a, b: seq[string]): seq[DiffPart] =
  if a.len * b.len > 1_000_000:
    result.add(DiffPart(kind: "removed", lines: a))
    result.add(DiffPart(kind: "added", lines: b))
    return
  let n = a.len
  let m = b.len
  let w = m + 1
  var dp = newSeq[int]((n + 1) * w)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      let idx = i * w + j
      if a[i] == b[j]:
        dp[idx] = dp[(i + 1) * w + (j + 1)] + 1
      else:
        dp[idx] = max(dp[(i + 1) * w + j], dp[i * w + (j + 1)])
  var i = 0
  var j = 0
  while i < n and j < m:
    if a[i] == b[j]:
      pushPart(result, "unchanged", a[i])
      inc i
      inc j
    elif dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]:
      pushPart(result, "removed", a[i])
      inc i
    else:
      pushPart(result, "added", b[j])
      inc j
  while i < n:
    pushPart(result, "removed", a[i])
    inc i
  while j < m:
    pushPart(result, "added", b[j])
    inc j

proc diffLines(a, b: seq[string]): seq[DiffPart] =
  ## Line diff with LCS on the trimmed middle; identical content yields a
  ## single unchanged part.
  var i = 0
  while i < a.len and i < b.len and a[i] == b[i]: inc i
  var ja = a.len - 1
  var jb = b.len - 1
  while ja >= i and jb >= i and a[ja] == b[jb]:
    dec ja
    dec jb
  var parts: seq[DiffPart] = @[]
  if i > 0: parts.add(DiffPart(kind: "unchanged", lines: a[0 ..< i]))
  if i <= ja:
    parts.add(lcsParts(a[i .. ja], b[i .. jb]))
  elif i <= jb:
    parts.add(DiffPart(kind: "added", lines: b[i .. jb]))
  if ja + 1 < a.len:
    parts.add(DiffPart(kind: "unchanged", lines: a[ja + 1 .. ^1]))
  result = parts

proc fmtDiffLine(prefix, line, hash: string): string =
  if hash.len == 0:
    return prefix & "   " & HASH_SEP & line
  prefix & hash & HASH_SEP & line

proc genDiff(oldContent, newContent: string, contextLines: int,
             newContentHashes, oldContentHashes: seq[string]): tuple[diff: string,
                                                                     firstChangedLine: int] =
  let effectiveNewHashes = if newContentHashes.len > 0: newContentHashes
                           else: lineHashesPure(newContent)
  let parts = diffLines(splitLines(oldContent), splitLines(newContent))
  var output: seq[string] = @[]
  var newLineNum = 1
  var oldLineNum = 1
  var lastWasChange = false
  result.firstChangedLine = -1
  for i, part in parts:
    var displayLines = part.lines
    if part.kind == "added" or part.kind == "removed":
      if result.firstChangedLine < 0: result.firstChangedLine = newLineNum
      for line in displayLines:
        if part.kind == "added":
          output.add(fmtDiffLine("+", line, effectiveNewHashes[newLineNum - 1]))
          inc newLineNum
        else:
          let hash = if oldContentHashes.len > 0: oldContentHashes[oldLineNum - 1]
                     else: ""
          output.add(fmtDiffLine("-", line, hash))
          inc oldLineNum
      lastWasChange = true
      continue
    # unchanged part
    let nextPartIsChange = i < parts.len - 1 and
      (parts[i + 1].kind == "added" or parts[i + 1].kind == "removed")
    if lastWasChange or nextPartIsChange:
      var linesToShow = displayLines
      var skipStart = 0
      var skipMiddle = 0
      var skipTail = 0
      if not lastWasChange:
        skipStart = max(0, displayLines.len - contextLines)
        linesToShow = displayLines[skipStart .. ^1]
      elif nextPartIsChange and displayLines.len > contextLines * 2:
        var shown: seq[string] = @[]
        for line in displayLines[0 ..< contextLines]: shown.add(line)
        shown.add("\x00ELLIPSIS")
        for line in displayLines[displayLines.len - contextLines .. ^1]:
          shown.add(line)
        linesToShow = shown
        skipMiddle = displayLines.len - contextLines * 2
      elif not nextPartIsChange and linesToShow.len > contextLines:
        linesToShow = linesToShow[0 ..< contextLines]
        skipTail = displayLines.len - contextLines
      if skipStart > 0:
        output.add(" ...")
        newLineNum += skipStart
        oldLineNum += skipStart
      for line in linesToShow:
        if line == "\x00ELLIPSIS":
          output.add(" ...")
          newLineNum += skipMiddle
          oldLineNum += skipMiddle
          continue
        output.add(fmtDiffLine(" ", line, effectiveNewHashes[newLineNum - 1]))
        inc newLineNum
        inc oldLineNum
      if skipTail > 0:
        output.add(" ...")
    else:
      newLineNum += displayLines.len
      oldLineNum += displayLines.len
    lastWasChange = false
  result.diff = output.join("\n")

proc servedHashesFromDiff(diff: string): seq[string] =
  for line in diff.split("\n"):
    if line.len >= 7 and (line[0] == '+' or line[0] == ' ') and
        isAlph(line[1]) and isAlph(line[2]) and isAlph(line[3]) and
        line[4 .. 6] == HASH_SEP:
      result.add(line[1 .. 3])

proc cntDiff(diff, marker: string): int =
  if diff.len == 0: return 0
  for line in diff.split("\n"):
    if line.startsWith(marker) and not line.startsWith(marker & marker & marker):
      inc result

# ---------------------------------------------------------------------------
# read tool

proc truncateHead(content: string, maxBytes, maxLines: int): tuple[content: string,
                                                                  truncated: bool,
                                                                  truncatedBy: string,
                                                                  outputLines: int,
                                                                  maxBytes: int] =
  result.content = content
  result.maxBytes = maxBytes
  var lines = content.split("\n")
  if lines.len > maxLines:
    lines.setLen(maxLines)
    result.truncated = true
    result.truncatedBy = "lines"
    result.content = lines.join("\n")
  if result.content.len > maxBytes:
    var cut = maxBytes
    while cut > 0 and (uint8(result.content[cut - 1]) and 0xC0) == 0x80:
      dec cut
    result.content = result.content[0 ..< cut]
    result.truncated = true
    result.truncatedBy = "bytes"
  result.outputLines = if result.content.len == 0: 0
                       else: result.content.split("\n").len

proc formatPaginationHint(startLine, endLine, totalLines, nextOffset: int,
                          byteLimit: int): string =
  let sizeSuffix = if byteLimit > 0: " (" & formatSize(byteLimit) & " limit)"
                   else: ""
  "[Showing lines " & $startLine & "-" & $endLine & " of " & $totalLines &
    sizeSuffix & ". Use offset=" & $nextOffset & " to continue.]"

proc normPosInt(args: JsonNode, name: string): int =
  ## 0 = absent; raises [E_BAD_SHAPE] on non-positive integers.
  let v = args{name}
  if v == nil or v.kind == JNull: return 0
  if v.kind != JInt or v.getInt() < 1:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Read request field \"" & name &
      "\" must be a positive integer.")
  v.getInt()

proc fmtReadPreview(text: string, offset, limit: int,
                    fileHashes: seq[string],
                    path: string): tuple[text: string, servedHashes: seq[string]] =
  let allLines = visLines(text)
  let totalLines = allLines.len
  let startLine = if offset > 0: offset else: 1
  if totalLines == 0:
    if startLine == 1:
      let allHashes = if fileHashes.len > 0: fileHashes
                      else: lineHashes(text, path)
      let emptyLineHash = if allHashes.len > 0: allHashes[0] else: ""
      return (text: emptyLineHash & HASH_SEP &
                "\n[File is empty. Use replace to insert content.]",
              servedHashes: if emptyLineHash.len > 0: @[emptyLineHash] else: @[])
    return (text: "Offset " & $startLine &
      " is beyond end of file (0 lines total). The file is empty. Use " &
      "replace to insert content.", servedHashes: @[])
  if startLine > totalLines:
    return (text: "Offset " & $startLine & " is beyond end of file (" &
      $totalLines & " lines total). Use offset=1 to read from the start, or " &
      "offset=" & $totalLines & " to read the last line.", servedHashes: @[])
  let endIdx = if limit > 0: min(startLine - 1 + limit, totalLines)
               else: totalLines
  let selected = allLines[startLine - 1 ..< endIdx]
  let allHashes = if fileHashes.len > 0: fileHashes
                  else: lineHashes(text, path)
  let selectedHashes = allHashes[startLine - 1 ..< endIdx]
  let formatted = fmtRegion(selectedHashes, selected)

  var rowSizes: seq[int] = @[]
  for i in 0 ..< selected.len:
    rowSizes.add((selectedHashes[i] & HASH_SEP & selected[i]).len)

  if rowSizes.anyIt(it > MAX_READ_LINE_BYTES):
    var oversized: seq[tuple[lineNumber: int, bytes: int]] = @[]
    var rows: seq[string] = @[]
    for i in 0 ..< rowSizes.len:
      if rowSizes[i] > MAX_READ_LINE_BYTES:
        oversized.add((lineNumber: startLine + i, bytes: rowSizes[i]))
        rows.add("[Line " & $(startLine + i) & " is " &
          formatSize(rowSizes[i]) & ", exceeds " &
          formatSize(MAX_READ_LINE_BYTES) &
          "; content not shown. Use bash: sed -n '" & $(startLine + i) &
          "p' <path> | head -c " & $MAX_READ_LINE_BYTES & "]")
      else:
        rows.add(fmtRegion(@[selectedHashes[i]], @[selected[i]]))
    let skipped = truncateHead(rows.join("\n"), MAX_READ_LINE_BYTES,
                               MAX_READ_LINES)
    let shownRowCount = if skipped.content.len == 0: 0
                        else: skipped.content.split("\n").len
    let lastShownLine = if shownRowCount > 0:
      startLine + shownRowCount - 1
    else:
      startLine - 1
    var oversizedIndexes = initHashSet[int]()
    for i in 0 ..< rowSizes.len:
      if rowSizes[i] > MAX_READ_LINE_BYTES: oversizedIndexes.incl(i)
    var servedHashes: seq[string] = @[]
    for index in 0 ..< min(shownRowCount, rows.len):
      if not oversizedIndexes.contains(index):
        servedHashes.add(selectedHashes[index])
    let lineLabel = if oversized.len == 1:
      "Line " & $oversized[0].lineNumber
    else:
      var ns: seq[string] = @[]
      for o in oversized: ns.add($o.lineNumber)
      "Lines " & ns.join(", ")
    let verb = if oversized.len == 1: "exceeds" else: "exceed"
    var addresses: seq[string] = @[]
    for o in oversized: addresses.add($o.lineNumber & "p")
    let warning = "[" & lineLabel & " " & verb & " " &
      formatSize(MAX_READ_LINE_BYTES) &
      "; content not shown because hashline anchors require full lines. " &
      "Inspect with bash: sed -n '" & addresses.join(";") & "' <path> | " &
      "head -c " & $MAX_READ_LINE_BYTES & "]"
    var preview = skipped.content
    if shownRowCount > 0 and
        (skipped.truncated or lastShownLine < totalLines):
      let nextOffset = lastShownLine + 1
      preview = preview & "\n\n" & warning & "\n" &
        formatPaginationHint(startLine, lastShownLine, totalLines, nextOffset,
                             if skipped.truncated: skipped.maxBytes else: 0)
    else:
      preview = preview & "\n\n" & warning
    return (text: preview, servedHashes: servedHashes)

  let truncation = truncateHead(formatted, MAX_READ_LINE_BYTES, MAX_READ_LINES)
  var preview = truncation.content
  let shownCount = if truncation.content.len == 0: 0
                   else: truncation.content.split("\n").len
  let servedHashes = selectedHashes[0 ..< shownCount]
  if truncation.truncated:
    let endLineDisplay = startLine + truncation.outputLines - 1
    let nextOffset = endLineDisplay + 1
    if truncation.truncatedBy == "lines":
      preview = preview & "\n\n" &
        formatPaginationHint(startLine, endLineDisplay, totalLines,
                             nextOffset, 0)
    else:
      preview = preview & "\n\n" &
        formatPaginationHint(startLine, endLineDisplay, totalLines,
                             nextOffset, truncation.maxBytes)
  elif endIdx < totalLines:
    preview = preview & "\n\n" &
      formatPaginationHint(startLine, endIdx, totalLines, endIdx + 1, 0)
  (text: preview, servedHashes: servedHashes)

# ---------------------------------------------------------------------------
# replace pipeline

proc rejectUnknownFields(args: JsonNode, allowed: openArray[string],
                         label: string, hint = "") =
  var unknown: seq[string] = @[]
  for key in args.keys:
    if allowed.find(key) < 0: unknown.add(key)
  if unknown.len > 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] " & label & " contains unknown or unsupported fields: " &
      unknown.join(", ") & "." & (if hint.len > 0: " " & hint else: ""))

proc normalizeFilePath(args: var JsonNode) =
  if args{"path"} == nil and args{"file_path"} != nil and
      args{"file_path"}.kind == JString:
    args["path"] = args{"file_path"}
    args.delete("file_path")

proc resolveMissingPath(args: JsonNode): tuple[path: string, warning: string] =
  if args{"path"} != nil and args{"path"}.kind == JString:
    return (path: "", warning: "")
  let fromNode = args{"remove_from"}
  let toNode = args{"remove_to"}
  if fromNode == nil or toNode == nil or fromNode.kind != JString or
      toNode.kind != JString:
    return (path: "", warning: "")
  var hashes: seq[string] = @[]
  try:
    hashes.add(parseHashRef(fromNode.getStr()))
    hashes.add(parseHashRef(toNode.getStr()))
  except CatchableError:
    return (path: "", warning: "")
  let matches = findSnapshotPaths(hashes)
  if matches.len == 1:
    return (path: matches[0],
            warning: "[E_BAD_SHAPE] Autocorrected: missing \"path\" resolved " &
              "to " & matches[0] &
              " — the only file whose stored hashes contain both anchors.")
  if matches.len > 1:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Edit request requires a non-empty \"path\" string; the " &
      "anchors match multiple known files: " & matches.join(", ") &
      ". Include the intended path.")
  (path: "", warning: "")

proc collectRemovedHashes(edit: AnchorEdit, originalHashes: seq[string]): HashSet[string] =
  let startLine = originalHashes.find(edit.startHash)
  let endLine = originalHashes.find(edit.endHash)
  if startLine >= 0 and endLine >= 0:
    let firstLine = min(startLine, endLine)
    let lastLine = max(startLine, endLine)
    for i in firstLine .. lastLine:
      result.incl(originalHashes[i])

proc countLineChanges(edit: AnchorEdit, originalHashes: seq[string],
                      isNoop: bool,
                      removedAutoFixes: int): tuple[totalAddedLines,
                                                    totalRemovedLines: int] =
  if isNoop: return (0, 0)
  let startLine = originalHashes.find(edit.startHash)
  let endLine = originalHashes.find(edit.endHash)
  var totalRemovedLines = 0
  if startLine >= 0 and endLine >= 0:
    totalRemovedLines = abs(endLine - startLine) + 1
  (max(0, edit.contentLines.len - removedAutoFixes), totalRemovedLines)

type PipelineResult = object
  path: string
  originalNormalized: string
  result: string
  bom: string
  originalEnding: string
  hadUtf8DecodeErrors: bool
  warnings: seq[string]
  noopLoc: string
  noopContent: string
  firstChangedLine: int
  lastChangedLine: int
  resultHashes: seq[string]
  originalHashes: seq[string]
  totalAddedLines: int
  totalRemovedLines: int

proc execPipeline(path, cwd: string, removeFrom, removeTo: string,
                  replacementLines: seq[string]): PipelineResult =
  var editWarnings: seq[string] = @[]
  let edit = resEdit(removeFrom, removeTo, replacementLines, editWarnings)
  let file = readNormFile(path, cwd, writeAccess = true,
                          maxLines = MAX_HASH_LINES)
  let served = getServed(file.absolutePath)
  var anchorResult: ApplyResult
  try:
    anchorResult = applyEdit(file.normalized, edit, file.fileHashes, path,
                             served.hashes, served.present)
  except RangeStaleError as e:
    recordServed(file.absolutePath, e.rangeHashes)
    raise
  except AnchorMismatchError as e:
    recordServed(file.absolutePath, e.feedbackHashes)
    raise

  let isNoop = anchorResult.content == file.normalized
  var removedHashes: HashSet[string]
  if isNoop:
    removedHashes = initHashSet[string]()
  else:
    removedHashes = collectRemovedHashes(edit, file.fileHashes)
  let resultHashes = if isNoop: file.fileHashes
    else: lineHashes(anchorResult.content, file.absolutePath,
                     (content: file.normalized, hashes: file.fileHashes,
                      removedHashes: removedHashes))
  var warnings = editWarnings
  for w in anchorResult.warnings: warnings.add(w)
  let counts = countLineChanges(edit, file.fileHashes, isNoop,
                                anchorResult.autoFixes.len)
  PipelineResult(path: path, originalNormalized: file.normalized,
                 result: anchorResult.content, bom: file.bom,
                 originalEnding: file.originalEnding,
                 hadUtf8DecodeErrors: file.hadUtf8DecodeErrors,
                 warnings: warnings, noopLoc: anchorResult.noopLoc,
                 noopContent: anchorResult.noopContent,
                 firstChangedLine: anchorResult.firstChangedLine,
                 lastChangedLine: anchorResult.lastChangedLine,
                 resultHashes: resultHashes, originalHashes: file.fileHashes,
                 totalAddedLines: counts.totalAddedLines,
                 totalRemovedLines: counts.totalRemovedLines)

proc buildNoop(p: PipelineResult): JsonNode =
  var text: string
  if p.noopLoc.len > 0:
    text = "No changes made to " & p.path & "\nClassification: noop\n" &
      "Replacement for " & p.noopLoc & " is identical to current content:\n  " &
      p.noopLoc & ": " & clipLine(p.noopContent)
  else:
    text = "No changes made to " & p.path &
      "\nClassification: noop\nThe edit produced identical content."
  if p.warnings.len > 0:
    text = text & "\n\nWarnings:\n" & p.warnings.join("\n")
  var res = %*{"summary": text, "classification": "noop"}
  if p.warnings.len > 0: res["warnings"] = %p.warnings
  res

proc buildChanged(p: PipelineResult): JsonNode =
  let resultLines = visLines(p.result)
  let diffResult = genDiff(p.originalNormalized, p.result, 1,
                           p.resultHashes, p.originalHashes)
  let lineSummary = if p.totalAddedLines > 0 or p.totalRemovedLines > 0:
    " Added " & $p.totalAddedLines & " line(s), removed " &
    $p.totalRemovedLines & " line(s)."
  else: ""
  let warningsBlock = if p.warnings.len > 0:
    "\n\nWarnings:\n" & p.warnings.join("\n")
  else: ""
  var text: string
  if resultLines.len == 0:
    text = "File is empty. Use replace to insert content."
  elif warningsBlock.len > 0:
    text = "Successfully replaced in " & p.path & "." & lineSummary &
      warningsBlock
  else:
    text = "Successfully replaced in " & p.path & "." & lineSummary
  result = %*{"summary": text, "diff": diffResult.diff,
              "first_changed_line": (if p.firstChangedLine > 0: p.firstChangedLine else: diffResult.firstChangedLine),
              "last_changed_line": p.lastChangedLine,
              "added_lines": p.totalAddedLines,
              "removed_lines": p.totalRemovedLines}
  if p.warnings.len > 0: result["warnings"] = %p.warnings
  return result

# ---------------------------------------------------------------------------
# undo tool

proc getUndo(path: string): tuple[present: bool, entry: UndoEntry] =
  let entry = getUndoEntry(path)
  if entry.hashes.len == 0:
    return (present: false, entry: entry)
  if entry.ending != "\r\n" and entry.ending != "\n" and entry.ending != "\r":
    deleteUndo(path)
    return (present: false, entry: entry)
  (present: true, entry: entry)

proc clearUndo(path: string) =
  deleteUndo(path)

proc hUndoLastReplace(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Undo request must be an object.")
  var req = copy(args)
  normalizeFilePath(req)
  let path = req{"path"}
  if path == nil or path.kind != JString or path.getStr().len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Undo request requires a non-empty \"path\" string.")
  let rawPath = path.getStr()
  let cwd = getEnv("NIF_ROOT", ".")
  let absolutePath = toCwd(rawPath, cwd)
  let mutationTargetPath = resolveTarget(absolutePath)

  let undo = getUndo(mutationTargetPath)
  if not undo.present:
    raise newException(ValueError,
      "No undo history for " & rawPath &
      ". There is no previous replace to revert.")

  var currentRaw: string
  if not fileExists(mutationTargetPath):
    clearUndo(mutationTargetPath)
    raise newException(ValueError,
      "[E_UNDO_STALE] Cannot undo last replace on " & rawPath &
      ": the file no longer exists. Call read() to inspect the current state.")
  try:
    currentRaw = readFile(mutationTargetPath)
  except CatchableError as e:
    raise newException(ValueError,
      "[E_UNDO_STALE] Cannot undo last replace on " & rawPath & ": " & e.msg)

  let expected = undo.entry.bom &
    restoreEndings(undo.entry.resultContent, undo.entry.ending)
  if currentRaw != expected:
    clearUndo(mutationTargetPath)
    raise newException(ValueError,
      "[E_UNDO_STALE] Cannot undo last replace on " & rawPath &
      ": the file was modified after the replace, so undoing would overwrite " &
      "those changes. Call read() to inspect the current state.")

  let (_, currentStripped) = stripBOM(currentRaw)
  let currentNormalized = toLF(currentStripped)
  let currentHashes = lineHashes(currentNormalized, mutationTargetPath)
  let diffResult = genDiff(undo.entry.content, currentNormalized, 0,
                           @[], undo.entry.hashes)
  let linesAddedByReplace = cntDiff(diffResult.diff, "+")
  let linesRemovedByReplace = cntDiff(diffResult.diff, "-")
  let restoredRange = changedRange(currentNormalized, undo.entry.content)
  let undoDiff = genDiff(currentNormalized, undo.entry.content, 1,
                         undo.entry.hashes, currentHashes).diff

  writeAtomic(mutationTargetPath,
              undo.entry.bom & restoreEndings(undo.entry.content,
                                              undo.entry.ending))
  try:
    upsertSnapshot(mutationTargetPath, undo.entry.content, undo.entry.hashes)
    recordServed(mutationTargetPath, servedHashesFromDiff(undoDiff))
  except CatchableError:
    discard
  clearUndo(mutationTargetPath)

  var parts: seq[string] = @["Undone last replace on " & rawPath & "."]
  if linesAddedByReplace > 0 or linesRemovedByReplace > 0:
    parts.add("Removed " & $linesAddedByReplace &
      " line(s) that were added and restored " & $linesRemovedByReplace &
      " line(s) that were removed.")
  parts.add("File reverted to previous state. Call `read` to get fresh " &
    "anchors for follow-up edits.")
  result = %*{"summary": parts.join("\n"), "diff": undoDiff,
              "first_changed_line": restoredRange.firstChangedLine,
              "last_changed_line": restoredRange.lastChangedLine,
              "added_lines": linesRemovedByReplace,
              "removed_lines": linesAddedByReplace}

# ---------------------------------------------------------------------------
# read tool handler

proc hRead(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Read request must be an object.")
  var req = copy(args)
  normalizeFilePath(req)
  let path = req{"path"}
  if path == nil or path.kind != JString or path.getStr().len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Read request requires a non-empty \"path\" string.")
  let rawPath = path.getStr()
  let offset = normPosInt(req, "offset")
  let limit = normPosInt(req, "limit")
  let cwd = getEnv("NIF_ROOT", ".")
  let absolutePath = toCwd(rawPath, cwd)
  let resolvedPath = resolveTarget(absolutePath)
  valAccess(resolvedPath, rawPath)
  let file = loadFileKindAndText(resolvedPath, rawPath, MAX_HASH_LINES)
  valKind(file, rawPath)
  let (_, rawContent) = stripBOM(file.text)
  let normalized = toLF(rawContent)
  let preview = fmtReadPreview(normalized, offset, limit, @[], resolvedPath)
  try:
    recordServed(resolvedPath, preview.servedHashes)
  except CatchableError:
    discard
  let previewText = if file.hadUtf8Errors:
    preview.text & "\n\n[Non-UTF-8 bytes shown as U+FFFD; editing rewrites " &
      "the file as UTF-8.]"
  else:
    preview.text
  %previewText

# ---------------------------------------------------------------------------
# replace tool handler

proc hReplace(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] Edit request must be an object.")
  var req = copy(args)
  normalizeFilePath(req)
  rejectUnknownFields(req, ["path", "remove_from", "remove_to",
                            "replacement_lines"], "Edit request")
  var resolutionWarnings: seq[string] = @[]
  if req{"path"} == nil or req{"path"}.kind != JString or
      req{"path"}.getStr().len == 0:
    let resolution = resolveMissingPath(req)
    if resolution.path.len > 0:
      req["path"] = %resolution.path
      resolutionWarnings.add(resolution.warning)
    elif req{"path"} == nil or req{"path"}.kind != JString or
        req{"path"}.getStr().len == 0:
      raise newException(ValueError,
        "[E_BAD_SHAPE] Edit request requires a non-empty \"path\" string.")

  let pathNode = req{"path"}
  let fromNode = req{"remove_from"}
  let toNode = req{"remove_to"}
  let replNode = req{"replacement_lines"}
  if pathNode == nil or pathNode.kind != JString or pathNode.getStr().len == 0:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Edit request requires a non-empty \"path\" string.")
  if fromNode == nil or fromNode.kind != JString:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Field \"remove_from\" must be an anchor string " &
      "(3-char hash).")
  if toNode == nil or toNode.kind != JString:
    raise newException(ValueError,
      "[E_BAD_SHAPE] Field \"remove_to\" must be an anchor string " &
      "(3-char hash).")
  if replNode == nil or replNode.kind != JArray:
    raise newException(ValueError,
      "[E_BAD_SHAPE] \"replacement_lines\" must be an array of strings, one " &
      "element per line, not a single string. Do not pass one string with " &
      "\\n separators — pass an array of lines: [\"line1\", \"line2\"]. Use " &
      "[] to delete a range.")
  var replacementLines: seq[string] = @[]
  for item in replNode:
    if item.kind != JString:
      raise newException(ValueError,
        "[E_BAD_SHAPE] \"replacement_lines\" must be an array of strings, " &
        "one element per line (use [] to delete).")
    replacementLines.add(item.getStr())

  let path = pathNode.getStr()
  let cwd = getEnv("NIF_ROOT", ".")
  let p = execPipeline(path, cwd, fromNode.getStr(), toNode.getStr(),
                       replacementLines)
  var warnings = resolutionWarnings
  for w in p.warnings: warnings.add(w)

  if p.originalNormalized == p.result:
    var noop = p
    noop.warnings = warnings
    return buildNoop(noop)

  var changed = p
  changed.warnings = warnings
  if changed.hadUtf8DecodeErrors:
    changed.warnings.add("Non-UTF-8 bytes were shown as U+FFFD; this edit " &
      "rewrote the file as UTF-8.")

  let absolutePath = toCwd(path, cwd)
  let mutationTargetPath = resolveTarget(absolutePath)
  let entry = UndoEntry(content: changed.originalNormalized, bom: changed.bom,
                        ending: changed.originalEnding,
                        hashes: changed.originalHashes,
                        resultContent: changed.result)
  let undo = saveUndo(mutationTargetPath, entry)
  if not undo.persisted:
    raise newException(ValueError,
      "[E_UNDO_UNAVAILABLE] Cannot persist undo history to the hash store; " &
      "the edit was NOT applied and " & path &
      " is unchanged. Retry the replace, or use bash if the store cannot be " &
      "recovered.")
  try:
    writeAtomic(mutationTargetPath,
                changed.bom & restoreEndings(changed.result,
                                             changed.originalEnding))
  except CatchableError:
    undo.restore()
    raise
  let response = buildChanged(changed)
  try:
    recordServed(mutationTargetPath,
                 servedHashesFromDiff(response{"diff"}.getStr("")))
  except CatchableError:
    discard
  response

# ---------------------------------------------------------------------------
# component

let comp = newComponent("hashline-edit", "0.1.0")

loadStore()

proc desc(description: string, props: JsonNode,
          required: seq[string]): JsonNode =
  var schema = toolSchema(props, required, description)
  schema

discard comp.tool("read", desc(
  "Read a text file; each line returned as HASH\u2502content with a 3-char " &
  "alphanumeric hash. No line numbers — use the HASH as the anchor in " &
  "replace calls. Binary/directory/images are rejected (the harness cannot " &
  "attach images); UTF-16/UTF-32 (BOM) is rejected; an empty file comes " &
  "back as HASH\u2502 (use replace to insert content); pageable with " &
  "offset/limit; BOM stripped; non-UTF-8 bytes shown as U+FFFD (editing " &
  "rewrites the file as UTF-8). Lines up to 200KB are shown in full; " &
  "longer lines are replaced by a marker with a bash inspection hint.",
  %*{
    "path": {"type": "string",
             "description": "Path to the file to read (relative or absolute)"},
    "offset": {"type": "integer", "minimum": 1,
               "description": "Line number to start reading from (1-indexed)"},
    "limit": {"type": "integer", "minimum": 1,
              "description": "Maximum number of lines to read"}
  }, @["path"]),
  hRead)

discard comp.tool("replace", desc(
  "Replace a range of lines in a text file, targeted by the 3-char HASH " &
  "anchors from read output. remove_from and remove_to must each be a BARE " &
  "3-character hash: copy only the hash from the leftmost column of a read " &
  "row (row `ve7\u2502function hello() {` means \"remove_from\": \"ve7\"). " &
  "Never pass the line content, a code line, or a paragraph into these " &
  "fields. One edit per call; the post-edit diff carries fresh anchors, so " &
  "you can keep editing without re-reading. Common copy-paste slips are " &
  "fixed automatically and reported as warnings (HASH\u2502 prefixes, " &
  "diff-preview rows, reversed ranges, re-included adjacent blocks). An " &
  "edit that produces identical content reports \"No changes made\". " &
  "Every line of the removed range must have been shown to you; otherwise " &
  "the edit is refused with [E_RANGE_STALE] and the current range with " &
  "fresh anchors is returned. Do not issue multiple replace calls on the " &
  "same file in one message.",
  %*{
    "path": {"type": "string",
             "description": "Path to edit. Required — always provide it " &
               "explicitly; it is only auto-resolved from the anchors as a " &
               "fallback when omitted by mistake."},
    "remove_from": {"type": "string",
      "description": "Bare 3-char HASH only (e.g. \"aB3\") — copy just the " &
        "hash from the leftmost column of a read row like `aB3\u2502content`; " &
        "never the line content. Marks the FIRST line to remove (inclusive)"},
    "remove_to": {"type": "string",
      "description": "Bare 3-char HASH only (e.g. \"aB3\") — copy just the " &
        "hash from the leftmost column of a read row like `aB3\u2502content`; " &
        "never the line content. Marks the LAST line to remove (inclusive)"},
    "replacement_lines": {"type": "array",
      "items": {"type": "string",
                "description": "One replacement line. Each element is " &
                  "exactly one line; do not embed \\n inside an element — " &
                  "use separate elements."},
      "description": "Replacement lines as an array of strings, one element " &
        "per line. Mirror the removed lines exactly, blank lines included: " &
        "use [] to delete the range, [\"\"] for a single blank line, " &
        "[\"a\", \"\"] for a line followed by a blank line, and [\"\", \"\"] " &
        "for two blank lines. Do not embed \\n inside an element."}
  }, @["remove_from", "remove_to", "replacement_lines"]),
  hReplace)

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 300000,
                                         "onDemand": true}

discard comp.tool("undo_last_replace", desc(
  "Undo the last replace on a file, reverting it to its previous state " &
  "(content, BOM and line endings included). Use when a replace produced " &
  "incorrect results (e.g., wrong content, duplicated lines, broken " &
  "syntax). History is per-file and single-level, persisted across " &
  "restarts; the undo is refused if the file was modified or deleted after " &
  "the replace. The result shows the post-edit diff with fresh anchors.",
  %*{
    "path": {"type": "string",
             "description": "Path to the file to undo"}
  }, @["path"]),
  hUndoLastReplace)

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 120000,
                                         "onDemand": true}

comp.run()
