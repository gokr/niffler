# jsonpatch — minimal RFC 6902-style diff + apply

`diff(a, b)` produces a canonical, minimal patch:

- **Root** pointer is the empty string `""`.
- **Objects**: process the union of keys in **sorted** order. Missing in `b` →
  `remove`; missing in `a` → `add`; present in both → recurse (object into
  object, array into array); if the container TYPES differ or either side is
  not a container → `replace` with the whole `b` value.
- **Arrays**: align elements by longest-common-subsequence over deep
  equality. Unmatched `a` elements become `remove` ops — **emitted in
  descending a-index order** (so earlier removes stay valid). Unmatched `b`
  elements become `add` ops — **emitted in ascending b-index order, with
  `path` = the element's index in `b`** (removes land first, so b-indexes
  are valid insert positions).
- `apply(ops, doc)` returns a NEW document; the input must not be mutated.
  - `add` at an array index equal to length appends; a larger index is an error.
  - `remove`/`replace` on a missing path, `add` on an existing path, and
    malformed pointers (not starting with `/` for non-root, out-of-range)
    throw `Error`.
- `escapeToken`/`unescapeToken` implement RFC 6901: `~` → `~0`, `/` → `~1`.
