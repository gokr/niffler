package sdk

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

// Every bus here is private; never exercise the well-known production port.
func TestReattachChecksIdentityBeforeSubscriptions(t *testing.T) {
	for _, source := range []string{"environment", "discovery", "explicit"} {
		t.Run(source, func(t *testing.T) {
			home, foreign := startTestNATS(t), startTestNATS(t)
			root := t.TempDir()
			t.Setenv("NIF_ROOT", root)
			t.Setenv("NIF_NATS_URL", home)
			nc, err := nats.Connect(foreign)
			if err != nil {
				t.Fatal(err)
			}
			defer nc.Close()
			_, err = nc.Subscribe("svc.core.call", func(m *nats.Msg) {
				call := ParseEnvelope(m.Data)
				args, _ := json.Marshal(map[string]string{"root": root + "-foreign"})
				data, _ := json.Marshal(Envelope{V: 1, ID: call.ID, Kind: KindResult, Args: args})
				_ = m.Respond(data)
			})
			if err != nil {
				t.Fatal(err)
			}
			if err = nc.Flush(); err != nil {
				t.Fatal(err)
			}
			c := New("identity-probe", "0.0.0")
			if source == "explicit" {
				c = NewWithURL("identity-probe", "0.0.0", home)
			}
			c.Tool("ping", map[string]any{"type": "object"}, func(*Component, json.RawMessage) (any, error) { return true, nil })
			if err = c.Connect(); err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			switch source {
			case "environment":
				t.Setenv("NIF_NATS_URL", foreign)
			case "discovery":
				t.Setenv("NIF_NATS_URL", "")
				if err = os.MkdirAll(filepath.Join(root, "var"), 0700); err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(filepath.Join(root, "var", "nats-url"), []byte(foreign), 0600); err != nil {
					t.Fatal(err)
				}
			case "explicit":
				c.explicitURL = foreign
			}
			err = c.reconnectNow()
			if err == nil || !strings.Contains(err.Error(), "refusing bus") {
				t.Fatalf("foreign recovery accepted: %v", err)
			}
			if c.Connected() {
				t.Fatal("component connected to foreign bus")
			}
			// No call subscription may have existed, not merely a refused registration.
			_, err = nc.Request("svc.identity-probe.call", mustCallEnvelope("ping"), time.Second)
			if err != nats.ErrNoResponders {
				t.Fatalf("foreign call subject acquired a subscriber: %v", err)
			}
			if source == "explicit" {
				c.explicitURL = home
			} else {
				t.Setenv("NIF_NATS_URL", home)
			}
			if err = c.reconnectNow(); err != nil {
				t.Fatalf("correct bus recovery failed: %v", err)
			}
		})
	}
}

func TestReattachNeverGuessesBus(t *testing.T) {
	t.Setenv("NIF_NATS_URL", "")
	t.Setenv("NIF_ROOT", t.TempDir())
	c := New("no-bus", "0.0.0")
	if got := c.reattachCandidates(); len(got) != 0 {
		t.Fatalf("guessed bus: %v", got)
	}
	if err := c.reconnectNow(); err == nil {
		t.Fatal("empty recovery candidates reported success")
	}
	url := startTestNATS(t)
	t.Setenv("NIF_NATS_URL", url)
	if got := c.reattachCandidates(); !reflect.DeepEqual(got, []string{url}) {
		t.Fatalf("unexpected candidates: %v", got)
	}
}
