## Unit tests for Fabric's persistent bounded stdout frame reader.

import std/strutils
import ../components/fabric/framing
import helpers

proc main() =
  var reader: FrameReader
  reader.feed("first\nsecond\npartial")

  let first = reader.takeFrame()
  check("first coalesced frame retained", first.available and first.line == "first")

  let second = reader.takeFrame()
  check("second coalesced frame retained", second.available and second.line == "second")

  let incomplete = reader.takeFrame()
  check("partial frame waits for more bytes", not incomplete.available)

  reader.feed("-done\n")
  let completed = reader.takeFrame()
  check("partial frame completes across reads",
        completed.available and completed.line == "partial-done")

  var oversized: FrameReader
  oversized.feed(repeat('x', maxFrameBytes + 1))
  var rejected = false
  try:
    discard oversized.takeFrame()
  except ValueError as e:
    rejected = e.msg.contains("frame exceeds")
  check("unterminated oversized frame rejected", rejected)

  var oversizedLine: FrameReader
  oversizedLine.feed(repeat('x', maxFrameBytes + 1) & "\n")
  rejected = false
  try:
    discard oversizedLine.takeFrame()
  except ValueError as e:
    rejected = e.msg.contains("frame exceeds")
  check("terminated oversized frame rejected", rejected)

  report("fabric frames")

main()
