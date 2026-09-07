## Minimal ustar TAR reader. See README.md for the accepted format
## and the error rules. Only the Nim standard library may be used.

import std/[strutils]

type
  TarError* = object of CatchableError
  Entry* = object
    name*: string   ## full path (prefix joined with "/" when present)
    kind*: char     ## '0' regular file, '5' directory, anything else verbatim
    size*: int      ## payload size in bytes
    data*: string   ## file content for regular files, "" otherwise

proc parseTar*(data: string): seq[Entry] =
  ## Decodes a tar archive. Raises TarError on: missing ustar magic,
  ## checksum mismatch, truncated file data, or malformed octal fields.
  ## Two consecutive zero blocks (or a partial trailing block) end the archive.
  ## TODO
  result = @[]
