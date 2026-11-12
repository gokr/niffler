package sdk

import (
	"encoding/json"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

func TestAdmissionRejectsBeforeServing(t *testing.T) {
	url := startTestNATS(t)
	t.Setenv("NIF_ROOT", t.TempDir())
	t.Setenv("NIF_NATS_URL", url)
	nc, err := nats.Connect(url)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	var allow atomic.Bool
	var requests atomic.Int32
	_, err = nc.Subscribe("reg.admit", func(m *nats.Msg) {
		requests.Add(1)
		var identity map[string]any
		_ = json.Unmarshal(m.Data, &identity)
		data, _ := json.Marshal(map[string]any{"ok": allow.Load(), "name": identity["name"], "pid": identity["pid"], "reason": "extra store refused"})
		_ = m.Respond(data)
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = nc.Flush(); err != nil {
		t.Fatal(err)
	}
	c := New("admission-store", "0.0.0").RequireAdmission()
	c.Tool("ping", map[string]any{"type": "object"}, func(*Component, json.RawMessage) (any, error) { return true, nil })
	err = c.Connect()
	if err == nil || !strings.Contains(err.Error(), "registration rejected") {
		t.Fatalf("rejection did not refuse Connect: %v", err)
	}
	if c.Connected() {
		t.Fatal("rejected component remained connected")
	}
	_, err = nc.Request("svc.admission-store.call", mustCallEnvelope("ping"), time.Second)
	if err != nats.ErrNoResponders {
		t.Fatalf("rejected component acquired call subscription: %v", err)
	}
	allow.Store(true)
	if err = c.Connect(); err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err = nc.Request("svc.admission-store.call", mustCallEnvelope("ping"), time.Second); err != nil {
		t.Fatal(err)
	}
	allow.Store(false)
	if err = c.reconnectNow(); err == nil {
		t.Fatal("recovery bypassed admission")
	}
	if c.Connected() {
		t.Fatal("rejected recovery remained connected")
	}
	_, err = nc.Request("svc.admission-store.call", mustCallEnvelope("ping"), time.Second)
	if err != nats.ErrNoResponders {
		t.Fatalf("rejected recovery retained subscription: %v", err)
	}
	allow.Store(true)
	if err = c.reconnectNow(); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 4 {
		t.Fatalf("admission requests=%d, want 4", requests.Load())
	}
}

func TestAdmissionBareBusAndMalformedVerdict(t *testing.T) {
	url := startTestNATS(t)
	t.Setenv("NIF_ROOT", t.TempDir())
	t.Setenv("NIF_NATS_URL", url)
	c := New("bare-admission", "0.0.0").RequireAdmission()
	if err := c.Connect(); err != nil {
		t.Fatalf("standalone bare-bus contract broken: %v", err)
	}
	defer c.Close()
	nc, err := nats.Connect(url)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	_, err = nc.Subscribe("reg.admit", func(m *nats.Msg) {
		data, _ := json.Marshal(map[string]any{"ok": true, "name": "wrong", "pid": os.Getpid()})
		_ = m.Respond(data)
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = nc.Flush(); err != nil {
		t.Fatal(err)
	}
	if err = c.reconnectNow(); err == nil {
		t.Fatal("uncorrelated admission accepted")
	}
	// Close must still stop workers after a failed re-attach (nc is nil).
}
