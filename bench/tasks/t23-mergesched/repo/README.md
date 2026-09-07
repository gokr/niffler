# mergesched — interval merge + minimum rooms

Time is half-open `[Start, End)` in int64 minutes. Input may be unsorted.

**Merge:**
- Intervals that OVERLAP (share at least one instant of positive length)
  merge into one: `Start` = min, `End` = max, `Priority` = **max** of members.
- `a.End == b.Start` (adjacent) does NOT overlap — stay separate.
- Zero-length intervals (`Start == End`) never overlap anything and pass
  through unchanged.
- Output sorted by `Start`, ties by `End`. Input must not be mutated.

**MinRooms:**
- Maximum number of positive-length intervals alive at the same instant
  (sweep line). Zero-length intervals contribute nothing.
