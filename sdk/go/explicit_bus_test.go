package sdk

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

func TestExplicitBusIsolationAndReattach(t *testing.T) {
	first, second := startTestNATS(t), startTestNATS(t)
	t.Setenv("NIF_NATS_URL", second)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "var"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "var", "nats-url"), []byte(second), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NIF_ROOT", root)
	const marker = "NIF_TEST_EXPLICIT_DOTENV"
	old, present := os.LookupEnv(marker)
	if err := os.Unsetenv(marker); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if present {
			_ = os.Setenv(marker, old)
		} else {
			_ = os.Unsetenv(marker)
		}
	})
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte(marker+"=must-not-load\n"), 0600); err != nil {
		t.Fatal(err)
	}
	a := NewWithURL("explicit-a", "0.0.0", first)
	b := NewWithURL("explicit-b", "0.0.0", second)
	if err := a.Connect(); err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if err := b.Connect(); err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if _, ok := os.LookupEnv(marker); ok {
		t.Fatal("explicit component loaded local dotenv")
	}
	// Same subject deliberately: the payload proves the addressed bus, not
	// merely that two different component names were registered.
	for i, url := range []string{first, second} {
		nc, err := nats.Connect(url)
		if err != nil {
			t.Fatal(err)
		}
		defer nc.Close()
		label := []string{"first", "second"}[i]
		_, err = nc.Subscribe("svc.marker.call", func(m *nats.Msg) {
			env := ParseEnvelope(m.Data)
			data, _ := json.Marshal(map[string]string{"bus": label})
			response, _ := json.Marshal(Envelope{V: 1, ID: env.ID, Kind: KindResult, Args: data})
			_ = m.Respond(response)
		})
		if err != nil {
			t.Fatal(err)
		}
		if err = nc.Flush(); err != nil {
			t.Fatal(err)
		}
	}
	check := func(c *Component, want string) {
		t.Helper()
		raw, err := c.Request("marker", "where", map[string]any{}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		var got struct {
			Bus string `json:"bus"`
		}
		if err = json.Unmarshal(raw, &got); err != nil || got.Bus != want {
			t.Fatalf("got %s, %v; want %s", raw, err, want)
		}
	}
	check(a, "first")
	check(b, "second")
	recovered := make(chan struct{}, 8)
	a.OnReconnected(func(c *Component) { _ = c.Connected(); recovered <- struct{}{} })
	// Force ordinary nats.go reconnect without killing the private test bus.
	if err := a.connection().ForceReconnect(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-recovered:
	case <-time.After(5 * time.Second):
		t.Fatal("short reconnect hook missing")
	}
	check(a, "first")
	if err := a.reattachNow(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-recovered:
	case <-time.After(time.Second):
		t.Fatal("full reattach hook missing")
	}
	check(a, "first")
	check(b, "second")
	if got := a.reattachCandidates(); !reflect.DeepEqual(got, []string{first}) {
		t.Fatalf("fallback leaked: %v", got)
	}
	if os.Getenv("NIF_NATS_URL") != second {
		t.Fatal("explicit connection changed process bus")
	}
	if !a.Connected() {
		t.Fatal("connected component reported offline")
	}
	// Requests and status observers remain live during re-attach/close.
	var work sync.WaitGroup
	work.Add(1)
	go func() {
		defer work.Done()
		for i := 0; i < 20; i++ {
			_ = a.Connected()
			_ = a.Emit("ev.explicit.test", map[string]int{"i": i})
			_, _ = a.Request("marker", "where", map[string]any{}, 100*time.Millisecond)
		}
	}()
	for i := 0; i < 3; i++ {
		if err := a.reattachNow(); err != nil {
			t.Fatal(err)
		}
	}
	a.Close()
	work.Wait()
	if err := a.Emit("ev.explicit.test", nil); err == nil {
		t.Fatal("closed publish succeeded")
	}
	if a.Connected() {
		t.Fatal("closed component reported online")
	}
}

func TestExplicitEmptyBusRefusesDiscovery(t *testing.T) {
	t.Setenv("NIF_NATS_URL", startTestNATS(t))
	c := NewWithURL("empty-bus", "0.0.0", " ")
	if err := c.Connect(); err == nil {
		c.Close()
		t.Fatal("empty explicit URL adopted environment bus")
	}
	if got := c.reattachCandidates(); len(got) != 0 {
		t.Fatalf("empty explicit URL fallback: %v", got)
	}
}
