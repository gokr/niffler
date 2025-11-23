## Shared Output Functions
##
## This module contains output functions that are shared between
## the main CLI and the output handler thread.
##
## Design: Simple bash-like output where everything flows down the terminal.
## After readline returns, output appears below the input line, then new prompt.

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

proc flushStreamingBuffer*(redraw: bool = false) =
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
    flushStreamingBuffer(redraw = false)

proc writeStreamingChunkStyled*(text: string, style: ThemeStyle) =
  ## Write styled streaming content chunk - buffers and flushes on word boundaries
  ## Converts LF to CRLF for proper terminal display
  let normalizedText = text.replace("\n", "\r\n")
  let styledText = formatWithStyle(normalizedText, style)
  streamingBuffer.add(styledText)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = false)

proc writeCompleteLine*(text: string) =
  ## Write complete line with newline - simple bash-like output
  flushStreamingBuffer(redraw = false)
  writeOutputRaw(text, addNewline = true, redraw = false)

proc finishStreaming*() =
  ## Call after async streaming is done to flush buffer and redraw prompt
  ## Use this for streaming responses that preserve the input area
  flushStreamingBuffer(redraw = false)
  # Redraw prompt at the end of streaming
  redraw()

proc finishCommandOutput*() =
  ## Call after synchronous command output to reset position tracking
  ## This allows the next readline() to start fresh without clearing our output
  resetOutputPosition()

proc writeUserInput*(text: string, prompt: string = "") =
  ## Move to next line after user input - the input line is already visible
  ## This just ensures we're on a new line before showing output
  # The prompt+input is already visible, just move to next line
  stdout.write("\n")
  stdout.flushFile()
