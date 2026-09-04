# iniparse

A tiny INI-subset parser in `src/iniparse.nim`:

    proc parseIni(text: string): Table[string, Table[string, string]]

Spec:
- Sections are `[name]` lines. Key/value pairs before any section belong to
  the global section (empty name).
- A line whose first non-whitespace character is `;` or `#` is a comment and
  is ignored. Inline comments are NOT supported: a `;` or `#` after the
  start of a line is part of the value.
- Keys and values are trimmed of surrounding whitespace. Values may contain
  `=` — split on the FIRST `=`. An empty value (`key=`) is allowed.
- A duplicate key in the same section: the last one wins. A repeated
  section header merges into the existing section.
- Any other non-empty line is malformed: raise `ParseError` with the
  1-based line number in `msg`.
- Empty lines are ignored.

The test suite fails — find and fix the bug(s). Run `./test.sh` to test.
