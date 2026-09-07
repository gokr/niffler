// Package lruttl implements a bounded LRU cache with per-key TTL.
//
// See README.md for the exact semantics this implementation must satisfy.
package lruttl

import "time"

// Entry is one cached value.
type Entry struct {
	Key   string
	Value any
}

// Cache is a bounded LRU cache with optional per-key expiry.
type Cache struct {
	capacity int
	now      func() time.Time
	// TODO: internal state (map + recency order).
}

// New returns a cache with the given capacity. capacity <= 0 disables it:
// Put stores nothing and Get always misses. now supplies the current time
// (inject a fake clock in tests).
func New(capacity int, now func() time.Time) *Cache {
	return &Cache{capacity: capacity, now: now}
}

// Get returns the value for key and marks it most recently used.
// Expired entries are removed and reported as misses.
func (c *Cache) Get(key string) (any, bool) {
	// TODO
	return nil, false
}

// Peek behaves like Get but does NOT change recency order.
func (c *Cache) Peek(key string) (any, bool) {
	// TODO
	return nil, false
}

// Put inserts or updates key. Updates always count as a use (recency bump).
// See README.md for the eviction rule when the cache is full.
func (c *Cache) Put(key string, value any, ttl time.Duration) {
	// TODO
}

// Delete removes key if present (even if expired) and reports whether it was.
func (c *Cache) Delete(key string) bool {
	// TODO
	return false
}

// Len is the number of entries currently stored (including expired ones
// that have not been evicted yet).
func (c *Cache) Len() int {
	// TODO
	return 0
}
