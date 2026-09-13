## diagformat — pure formatting for the edit→lsp diagnostics push.
##
## edit's response appends a scoped diagnostics section after a successful
## edit: errors/warnings whose line falls in the changed range (± context),
## capped. Pure string logic lives here (unit-testable without the bus);
## the lsp query itself stays in edit's main.nim.

import std/strutils

const
  DIAG_CONTEXT_LINES* = 3    # diagnostics just outside the diff still matter
  DIAG_PUSH_MAX_LINES* = 8   # cap on in-range diagnostics per edit response

proc diagLinesInRange*(text: string, first, last: int): seq[string] =
  ## Filter lsp diagnostic lines ("path:LINE:COL  severity  message") down
  ## to errors/warnings whose line falls in the changed range (± context),
  ## capped. The header line ("path: N diagnostics") has no line number and
  ## is skipped by the parse.
  for raw in text.split('\n'):
    let line = raw.strip()
    if line.len == 0: continue
    let parts = line.split(':')
    if parts.len < 3: continue
    var ln = 0
    try: ln = parseInt(parts[1].strip())
    except ValueError: continue
    if ln < first - DIAG_CONTEXT_LINES or ln > last + DIAG_CONTEXT_LINES:
      continue
    let tail = parts[2 .. ^1].join(":")
    if "  error  " notin tail and "  warning  " notin tail: continue
    result.add(line)
    if result.len >= DIAG_PUSH_MAX_LINES: break

proc renderDiagSection*(text: string, count, first, last: int): string =
  ## Render the scoped diagnostics section for an edit response: the
  ## in-range errors/warnings, a one-line pointer when the file has
  ## diagnostics elsewhere, and nothing when the file is clean.
  if count == 0: return ""
  let inRange = diagLinesInRange(text, first, last)
  if inRange.len == 0:
    return "\n\n[LSP diagnostics: " & $count & " in this file, none in the changed range.]"
  var outp = "\n\n[LSP diagnostics in the changed range:\n" & inRange.join("\n")
  if inRange.len >= DIAG_PUSH_MAX_LINES:
    outp.add("\n  ... (capped — lsp diagnostics lists all)")
  outp.add("]")
  return outp
