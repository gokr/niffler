# lruttl — bounded LRU cache with per-key TTL

Semantics the implementation must satisfy exactly:

- **capacity <= 0** disables the cache: `Put` stores nothing, `Get`/`Peek` miss, `Len` stays 0.
- **Expiry**: an entry with `ttl > 0` expires when `now >= putTime + ttl`. `ttl == 0` never expires.
- `Get` on an expired entry removes it and returns a miss. `Peek` also respects expiry but never changes recency.
- `Get`/`Put` count as a use (recency bump); `Peek` does not.
- `Put` on an existing key updates value + ttl + recency (no eviction happens for updates).
- **Eviction** (only when inserting a NEW key into a full cache):
  1. first remove all expired entries,
  2. then, if the cache is still full, evict the least recently used entry (repeat until there is room).
- `Delete` removes a key even if it is expired, and reports whether an entry was present.
- `Len` counts entries present in the map, including expired ones not yet removed.
