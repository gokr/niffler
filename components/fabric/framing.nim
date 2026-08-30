## Bounded newline framing for the fabric executor's stdout protocol.

import std/[monotimes, selectors, strutils, times]
import std/posix

const maxFrameBytes* = 1_000_000

type FrameReader* = object
  buffer: string

proc feed*(reader: var FrameReader, chunk: string) =
  ## Add bytes read from the executor. Exposed for deterministic framing tests.
  reader.buffer.add(chunk)

proc takeFrame*(reader: var FrameReader): tuple[available: bool, line: string] =
  ## Return one buffered frame while retaining any following frames.
  let idx = reader.buffer.find('\n')
  if idx < 0:
    if reader.buffer.len > maxFrameBytes:
      raise newException(ValueError, "fabric-exec frame exceeds " &
        $maxFrameBytes & " bytes")
    return
  if idx > maxFrameBytes:
    raise newException(ValueError, "fabric-exec frame exceeds " &
      $maxFrameBytes & " bytes")
  result = (true, reader.buffer[0 ..< idx])
  if idx + 1 < reader.buffer.len:
    reader.buffer = reader.buffer[idx + 1 .. ^1]
  else:
    reader.buffer.setLen(0)

proc readFrame*(reader: var FrameReader, fd: cint, deadline: MonoTime,
                selector: Selector[cint]): string =
  ## Read one newline-terminated frame without discarding bytes after it.
  while true:
    let buffered = reader.takeFrame()
    if buffered.available:
      return buffered.line
    let left = (deadline - getMonoTime()).inMilliseconds.int
    if left <= 0:
      raise newException(CatchableError, "fabric-exec timed out")
    if selector.select(min(left, 200)).len == 0:
      continue
    var chunk: array[4096, char]
    let count = posix.read(fd, addr chunk[0], chunk.len)
    if count <= 0:
      raise newException(CatchableError, "fabric-exec closed its output")
    for i in 0 ..< count:
      reader.buffer.add(chunk[i])
