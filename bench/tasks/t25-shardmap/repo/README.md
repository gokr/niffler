# shardmap — concurrent sharded map

- Sharding is fixed at `New(shards)`; `shards < 1` panics.
- `ShardOf(key)` = FNV-1a (32-bit: offset 2166136261, prime 16777619,
  per-byte XOR then multiply) of the key, modulo the shard count.
- All operations must be safe under concurrent use (the test suite runs
  under `-race`): per-shard locking, no data races, `Len` exact,
  `Snapshot` returning a fresh copy whose (key, value) pairs are never torn.
- `Keys()` is sorted lexicographically; `Len()` must equal `len(Keys())`.
- `Snapshot` copies must not alias internal shard maps, and later writes
  must not leak into an earlier snapshot.
