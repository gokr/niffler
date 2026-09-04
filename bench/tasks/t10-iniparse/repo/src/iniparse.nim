## INI-subset parser. The test suite fails — fix the bugs below.

import std/[strutils, tables]

type ParseError* = object of CatchableError

proc parseIni*(text: string): Table[string, Table[string, string]] =
  var section = ""
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    let line = raw.strip()
    if line.len == 0:
      continue
    if line[0] == '[':
      section = line[1 .. ^1].strip(chars = {']', ' '})
      continue
    let eq = line.rfind('=')  # BUG: splits on the LAST =
    if eq < 0:
      raise newException(ParseError, "malformed line " & $lineNo)
    let key = line[0 ..< eq]
    let value = line[eq + 1 .. ^1]
    if not result.hasKey(section):
      result[section] = initTable[string, string]()
    if not result[section].hasKey(key):  # BUG: first wins instead of last
      result[section][key] = value
