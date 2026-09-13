## diagformat unit tests — scoped diagnostics filtering/rendering for the
## edit→lsp push. Pure string logic; no bus, no components.

import std/strutils
import helpers
import ../components/edit/diagformat

proc main() =
  let lspText = """
src/greeter.py: 2 diagnostics (1 errors)
src/greeter.py:12:5  error  Undefined name 'temp' [pyright]
src/greeter.py:40:1  warning  unused import os [pyright]
src/greeter.py:99:3  info  hint only
"""

  # In-range errors/warnings kept; info dropped; header skipped.
  let sec = renderDiagSection(lspText, 2, 10, 14)
  check("in-range error kept", sec.contains("Undefined name 'temp'"), sec)
  check("out-of-range dropped", not sec.contains("unused import"), sec)
  check("info severity dropped", not sec.contains("hint only"), sec)
  check("header line skipped", not sec.contains("2 diagnostics (1 errors)"), sec)
  check("section marker present", sec.contains("[LSP diagnostics in the changed range:"), sec)

  # Context window: a diagnostic 3 lines past the edit still counts.
  let secWide = renderDiagSection(lspText, 2, 38, 38)
  check("context window reaches +3 lines", secWide.contains("unused import"), secWide)

  # Diagnostics elsewhere in the file produce a pointer, not the list.
  let secElsewhere = renderDiagSection(lspText, 2, 200, 210)
  check("elsewhere pointer", secElsewhere.contains("none in the changed range") and secElsewhere.contains("lsp tool") and
        secElsewhere.contains("2 elsewhere in this file"), secElsewhere)

  # Clean file says nothing.
  check("clean file renders empty", renderDiagSection("", 0, 10, 20) == "")

  # Cap at DIAG_PUSH_MAX_LINES lines.
  var many = "src/x.py: 9 diagnostics (9 errors)\n"
  for i in 1 .. 12:
    many.add("src/x.py:" & $i & ":1  error  boom " & $i & "\n")
  let secCap = renderDiagSection(many, 12, 1, 12)
  check("capped at max lines", secCap.contains("capped") and
        secCap.count("boom") == 8, secCap)

  # Lines that do not parse as path:LINE:COL diagnostics are skipped.
  let secWeird = renderDiagSection("not a diagnostic line\nsrc/a.py:abc:1  error  nope\n", 0, 10, 12)
  check("unparseable lines skipped", not secWeird.contains("nope"), secWeird)

  report("DIAGFORMAT")

main()
