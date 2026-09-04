# todosweep

The repository contains source files with `TODO` and `FIXME` comments.
Produce `todos-report.md` listing every one of them in the exact format
below, and nothing else:

    # TODO report

    <relative path> (<count>)
      - TODO: <text> (line <n>)
      - FIXME: <text> (line <n>)

Files are sorted by relative path; within a file, entries appear in line
order. `<text>` is the comment text after the `TODO`/`FIXME` marker (a
following `:` is stripped, whitespace trimmed). For `.py`/`.nim` files a
comment starts at `#`; for `.go`/`.js` at `//`; for `.txt` the whole line.

The test suite checks the report byte for byte. There are many files —
use whatever your harness provides for mechanical, repetitive work.
