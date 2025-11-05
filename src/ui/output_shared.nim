## Shared Output Functions
##
## This module contains output functions that are shared between
## the main CLI and the output handler thread. This avoids circular imports.

import std/strutils
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
  ## Converts LF to CRLF for proper terminal display
  let normalizedText = text.replace("\n", "\r\n")
  streamingBuffer.add(normalizedText)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeStreamingChunkStyled*(text: string, style: ThemeStyle) =
  ## Write styled streaming content chunk - buffers and flushes on word boundaries
  ## Converts LF to CRLF for proper terminal display
  let normalizedText = text.replace("\n", "\r\n")
  let styledText = formatWithStyle(normalizedText, style)
  streamingBuffer.add(styledText)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeCompleteLine*(text: string) =
  ## Write complete line - flushes buffer first, then writes with newline and redraws prompt
  flushStreamingBuffer(redraw = false)
  # Use writeOutputRaw with redraw=true to ensure prompt is redrawn after the line
  writeOutputRaw(text, addNewline = true, redraw = true)

proc finishStreaming*() =
  ## Call after streaming chunks are done to flush remaining content
  flushStreamingBuffer()

proc writeUserInput*(text: string) =
  ## Add visual separation before assistant response
  ## Note: User input is already visible in the readline prompt,
  ## so we just add a blank line for visual separation and redraw prompt
  writeOutputRaw("", addNewline = true, redraw = true)
