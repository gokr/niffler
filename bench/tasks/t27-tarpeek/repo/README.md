# tarpeek — minimal ustar TAR reader

Header layout (512 bytes): name @0 (100), mode @100 (8), uid @108 (8),
gid @116 (8), size @124 (12, octal), mtime @136 (12), chksum @148 (8),
typeflag @156 (1), magic @257 ("ustar", 6 bytes), prefix @345 (155).

Rules:

- A block of 512 zero bytes ends the archive; a trailing partial block
  (< 512 bytes) also ends it silently.
- Every real header must contain "ustar" at offset 257 — else `TarError`.
- **Checksum**: the stored octal value in the chksum field must equal the
  sum of all 512 header bytes where the chksum field itself counts as
  8 spaces. Mismatch → `TarError`.
- **Octal fields**: skip leading spaces, then take digits `'0'..'7'`;
  anything else (before the field ends) → `TarError`. Empty → 0.
- `name` is the NUL-terminated part of the name field; when the prefix
  field is non-empty the full name is `prefix & "/" & name`.
- typeflag `'0'` or `'\0'` → regular file: `data` is the next `size`
  bytes (rounded up to a 512-block multiple afterwards). Missing/truncated
  data → `TarError`. `'5'` → directory, `data` empty. Any other flag is
  kept verbatim in `kind` with empty `data`.
- Only the Nim standard library may be used.
