package shardmap

import (
	"sort"
	"sync"
	"testing"
)

func TestBasicOps(t *testing.T) {
	m := New(4)
	m.Put("a", 1)
	if v, ok := m.Get("a"); !ok || v != 1 {
		t.Fatalf("Get(a) = %v %v", v, ok)
	}
	m.Put("a", 2)
	if v, _ := m.Get("a"); v != 2 {
		t.Fatal("Put must overwrite")
	}
	if !m.Delete("a") || m.Delete("a") {
		t.Fatal("Delete semantics wrong")
	}
	if _, ok := m.Get("a"); ok {
		t.Fatal("deleted key must miss")
	}
	if m.Len() != 0 {
		t.Fatalf("Len = %d", m.Len())
	}
}

func TestShardOfMatchesFNV1a(t *testing.T) {
	m := New(8)
	const (
		offset32 = 2166136261
		prime32  = 16777619
	)
	fnv := func(s string) uint32 {
		h := uint32(offset32)
		for i := 0; i < len(s); i++ {
			h ^= uint32(s[i])
			h *= prime32
		}
		return h
	}
	for _, k := range []string{"", "a", "hello", "world", "niffler", "zzzz"} {
		if got := m.ShardOf(k); got != int(fnv(k)%8) {
			t.Fatalf("ShardOf(%q) = %d, want %d", k, got, fnv(k)%8)
		}
	}
}

func TestShardsAreActuallyUsed(t *testing.T) {
	m := New(4)
	seen := map[int]bool{}
	for i := 0; i < 64; i++ {
		seen[m.ShardOf(string(rune('a'+i)))] = true
	}
	if len(seen) < 3 {
		t.Fatalf("keys spread over only %d shards of 4", len(seen))
	}
}

func TestKeysSorted(t *testing.T) {
	m := New(2)
	for _, k := range []string{"delta", "alpha", "charlie", "bravo"} {
		m.Put(k, 1)
	}
	got := m.Keys()
	want := []string{"alpha", "bravo", "charlie", "delta"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Keys = %v", got)
		}
	}
}

func TestSnapshotIsolated(t *testing.T) {
	m := New(2)
	m.Put("a", map[string]int{"x": 1})
	snap := m.Snapshot()
	snap["injected"] = true
	if _, ok := m.Get("injected"); ok {
		t.Fatal("mutating the snapshot leaked into the map")
	}
	m.Put("b", 2)
	if _, ok := snap["b"]; ok {
		t.Fatal("snapshot must be a copy")
	}
}

func TestInvalidShardCount(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("New(0) must panic")
		}
	}()
	New(0)
}

func TestConcurrentRaceAndConsistency(t *testing.T) {
	m := New(8)
	const writers = 8
	var wg sync.WaitGroup
	stop := make(chan struct{})
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; ; i++ {
				select {
				case <-stop:
					return
				default:
				}
				k := string(rune('a' + (i+ writers)%26))
				m.Put(k, w*1000+i)
				if i%7 == 0 {
					m.Delete(k)
				}
				_ = m.Len()
				_ = m.Snapshot()
				m.Get(k)
			}
		}(w)
	}
	for i := 0; i < 200; i++ {
		m.Put("anchor", i)
	}
	close(stop)
	wg.Wait()

	// Final state must be exactly the serial replay.
	want := map[string]int{"anchor": 199}
	for k, v := range m.Snapshot() {
		if vv, ok := v.(int); ok && k == "anchor" {
			if vv != want[k] {
				t.Fatalf("anchor = %d, want %d", vv, want[k])
			}
		}
	}
	keys := m.Keys()
	if !sort.StringsAreSorted(keys) {
		t.Fatal("Keys not sorted")
	}
	if m.Len() != len(keys) {
		t.Fatalf("Len %d != len(Keys) %d", m.Len(), len(keys))
	}
}
