import std/strutils

type
  CompletionSignal* = enum
    csNone = "none"
    csPhrase = "completion_phrase"
    csMarkdownSummary = "markdown_summary"
    csBoth = "phrase_and_markdown"

const COMPLETION_PHRASES = [
  "task complete",
  "task completed",
  "successfully completed",
  "work is done",
  "work is complete",
  "everything is done",
  "all done",
  "finished successfully",
  "completed successfully"
]

const MARKDOWN_SUMMARY_HEADERS = [
  "## summary",
  "## results",
  "## conclusion",
  "## completed",
  "## done",
  "## final"
]

proc hasCompletionPhrase*(content: string): bool =
  ## Check if content contains completion phrases in last 500 chars
  let tail = if content.len > 500: content[^500..^1] else: content
  let lowerTail = tail.toLowerAscii()

  for phrase in COMPLETION_PHRASES:
    if phrase in lowerTail:
      return true
  return false

proc hasMarkdownSummary*(content: string): bool =
  ## Check if content contains markdown summary headers
  let lowerContent = content.toLowerAscii()

  for header in MARKDOWN_SUMMARY_HEADERS:
    if ("\n" & header & " ") in lowerContent or
       ("\n" & header & "\n") in lowerContent or
       lowerContent.startsWith(header & " ") or
       lowerContent.startsWith(header & "\n"):
      return true
  return false

proc detectCompletionSignal*(content: string): CompletionSignal =
  ## Detect completion signal in LLM response content
  let hasPhrase = hasCompletionPhrase(content)
  let hasSummary = hasMarkdownSummary(content)

  if hasPhrase and hasSummary:
    return csBoth
  elif hasPhrase:
    return csPhrase
  elif hasSummary:
    return csMarkdownSummary
  else:
    return csNone
