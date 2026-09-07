// Package shardmap is a concurrent map sharded by an FNV-1a key hash.
// See README.md for the required behaviour under -race.
package shardmap

// ShardMap is a sharded concurrent map[string]any.
type ShardMap struct {
	// TODO: per-shard lock + map; the number of shards is fixed at New.
}

// New returns a sharded map. shards must be >= 1 (panic otherwise).
func New(shards int) *ShardMap {
	// TODO
	return nil
}

// ShardOf maps a key to its shard: FNV-1a (32-bit) of the key, modulo the
// shard count. Deterministic across processes.
func (m *ShardMap) ShardOf(key string) int {
	// TODO
	return 0
}

func (m *ShardMap) Put(key string, value any) { /* TODO */ }

func (m *ShardMap) Get(key string) (any, bool) { /* TODO */
	return nil, false
}

func (m *ShardMap) Delete(key string) bool { /* TODO */
	return false
}

// Len is the exact total number of live keys, safe under concurrency.
func (m *ShardMap) Len() int { /* TODO */
	return 0
}

// Keys returns all live keys sorted lexicographically.
func (m *ShardMap) Keys() []string { /* TODO */
	return nil
}

// Snapshot returns a fresh map containing every live key/value. Mutating
// the result must not affect the ShardMap, and no pair may be torn
// (value must belong to the returned key even while writers run).
func (m *ShardMap) Snapshot() map[string]any { /* TODO */
	return nil
}
