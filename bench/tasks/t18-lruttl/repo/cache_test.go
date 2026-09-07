package lruttl

import (
	"testing"
	"time"
)

func newTestCache(t *testing.T, cap int) (*Cache, *time.Time) {
	t.Helper()
	cur := time.Unix(1000, 0)
	c := New(cap, func() time.Time { return cur })
	return c, &cur
}

func TestBasicGetPut(t *testing.T) {
	c, _ := newTestCache(t, 2)
	c.Put("a", 1, 0)
	if v, ok := c.Get("a"); !ok || v != 1 {
		t.Fatalf("Get(a) = %v, %v", v, ok)
	}
	if c.Len() != 1 {
		t.Fatalf("Len = %d", c.Len())
	}
}

func TestZeroCapacityDisabled(t *testing.T) {
	c, _ := newTestCache(t, 0)
	c.Put("a", 1, time.Second)
	if _, ok := c.Get("a"); ok {
		t.Fatal("disabled cache must miss")
	}
	if c.Len() != 0 {
		t.Fatal("disabled cache must stay empty")
	}
}

func TestTTLExpiry(t *testing.T) {
	c, cur := newTestCache(t, 2)
	c.Put("a", 1, 10*time.Second)
	*cur = cur.Add(10 * time.Second) // exactly at expiry -> expired
	if _, ok := c.Get("a"); ok {
		t.Fatal("entry must expire at now >= expireAt")
	}
	if c.Len() != 0 {
		t.Fatal("expired entry must be removed on access")
	}
}

func TestNoTTLNeverExpires(t *testing.T) {
	c, cur := newTestCache(t, 2)
	c.Put("a", 1, 0) // ttl 0 = no expiry
	*cur = cur.Add(100 * time.Hour)
	if _, ok := c.Get("a"); !ok {
		t.Fatal("ttl 0 must never expire")
	}
}

func TestPeekNoRecency(t *testing.T) {
	c, _ := newTestCache(t, 2)
	c.Put("a", 1, 0)
	c.Put("b", 2, 0)
	c.Peek("a") // must not refresh "a"
	c.Put("c", 3, 0)
	if _, ok := c.Peek("a"); ok {
		t.Fatal("a should have been evicted as LRU (Peek must not refresh)")
	}
	if _, ok := c.Peek("b"); !ok {
		t.Fatal("b must survive")
	}
}

func TestGetRefreshesRecency(t *testing.T) {
	c, _ := newTestCache(t, 2)
	c.Put("a", 1, 0)
	c.Put("b", 2, 0)
	c.Get("a") // refresh a
	c.Put("c", 3, 0)
	if _, ok := c.Peek("a"); !ok {
		t.Fatal("a was refreshed, b is LRU and must go")
	}
	if _, ok := c.Peek("b"); ok {
		t.Fatal("b must have been evicted")
	}
}

func TestExpiredArePurgedBeforeLRUEviction(t *testing.T) {
	c, cur := newTestCache(t, 2)
	c.Put("a", 1, 5*time.Second)
	c.Put("b", 2, 0)
	*cur = cur.Add(6 * time.Second) // a expired, b alive
	c.Put("c", 3, 0)                // must purge expired a, keep b, evict nothing else
	if c.Len() != 2 {
		t.Fatalf("Len = %d, want 2 (a purged, b+c kept)", c.Len())
	}
	if _, ok := c.Peek("b"); !ok {
		t.Fatal("b must survive: expired entries are purged before LRU eviction")
	}
}

func TestPutUpdatesValueTTLAndRecency(t *testing.T) {
	c, cur := newTestCache(t, 2)
	c.Put("a", 1, 0)
	c.Put("b", 2, 0)
	c.Put("a", 9, 10*time.Second) // update: recency bump + new ttl
	*cur = cur.Add(11 * time.Second)
	if _, ok := c.Get("a"); ok {
		t.Fatal("updated ttl must apply")
	}
}

func TestDeleteExpired(t *testing.T) {
	c, cur := newTestCache(t, 2)
	c.Put("a", 1, 5*time.Second)
	*cur = cur.Add(6 * time.Second)
	if !c.Delete("a") {
		t.Fatal("Delete must report true for expired-but-present entries")
	}
	if c.Delete("a") {
		t.Fatal("second Delete must be false")
	}
}

func TestEvictionOrder(t *testing.T) {
	c, _ := newTestCache(t, 3)
	for _, k := range []string{"a", "b", "c", "d", "e"} {
		c.Put(k, k, 0)
	}
	for _, k := range []string{"a", "b"} {
		if _, ok := c.Peek(k); ok {
			t.Fatalf("%s must have been evicted", k)
		}
	}
	for _, k := range []string{"c", "d", "e"} {
		if _, ok := c.Peek(k); !ok {
			t.Fatalf("%s must be present", k)
		}
	}
	if c.Len() != 3 {
		t.Fatalf("Len = %d, want 3", c.Len())
	}
}
