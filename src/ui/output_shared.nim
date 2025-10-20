## Shared Output Functions
##
## This module contains output functions that are shared between
## the main CLI and the output handler thread. This avoids circular imports.

import std/[strformat]
import ../../../linecross/linecross
import theme

# Streaming buffer for batching output
var streamingBuffer: string = ""
const STREAMING_FLUSH_THRESHOLD = 200
const STREAMING_MAX_BUFFER = 500

proc shouldFlushBuffer(): bool =
  ## Determine if buffer should be flushed based on size and word boundaries
  if streamingBuffer.len >= STREAMING_MAX_BUFFER:
    return true

  if streamingBuffer.len >= STREAMING_FLUSH_THRESHOLD:
    if streamingBuffer.len > 0:
      let lastChar = streamingBuffer[^1]
      if lastChar in {' ', '\n', '\t', '.', ',', '!', '?', ':', ';'}:
        return true

  return false

proc flushStreamingBuffer*(redraw: bool = true) =
  ## Flush any buffered streaming content to output
  if streamingBuffer.len > 0:
    writeOutputRaw(streamingBuffer, addNewline = false, redraw = redraw)
    streamingBuffer = ""

proc writeStreamingChunk*(text: string) =
  ## Write streaming content chunk - buffers and flushes on word boundaries
  streamingBuffer.add(text)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeStreamingChunkStyled*(text: string, style: ThemeStyle) =
  ## Write styled streaming content chunk - buffers and flushes on word boundaries
  let styledText = formatWithStyle(text, style)
  streamingBuffer.add(styledText)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeCompleteLine*(text: string) =
  ## Write complete line - flushes buffer first, then writes with newline
  flushStreamingBuffer(redraw = false)
  # Use writeLine for proper CR+LF handling
  writeLine(text)

proc finishStreaming*() =
  ## Call after streaming chunks are done to flush remaining content
  flushStreamingBuffer()

proc writeUserInput*(text: string) =
  ## Write user input to scrollback with "> " prefix and theme styling
  let formattedInput = formatWithStyle(fmt"> {text}", currentTheme.userInput)
  # Write blank line then user input, using writeLine for proper CR+LF
  writeLine("")  # Blank line for separation
  writeLine(formattedInput)
