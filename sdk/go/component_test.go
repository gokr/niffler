package sdk

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

// startTestNATS lets NATS allocate its own loopback port (no
// bind-close-start race) and returns the published client URL.
func startTestNATS(t *testing.T) string {
	t.Helper()
	serverBin, err := exec.LookPath("nats-server")
	if err != nil {
		t.Skip("nats-server is not installed")
	}
	portsDir, err := os.MkdirTemp("", "niffler-sdk-test-*")
	if err != nil {
		t.Fatal(err)
	}
	server := exec.Command(serverBin, "-a", "127.0.0.1", "-p", "-1",
		"--ports_file_dir", portsDir)
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = server.Process.Kill()
		_ = server.Wait()
		_ = os.RemoveAll(portsDir)
	})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		entries, globErr := filepath.Glob(filepath.Join(portsDir, "*.ports"))
		if globErr == nil {
			for _, path := range entries {
				data, readErr := os.ReadFile(path)
				if readErr != nil {
					continue
				}
				var ports struct {
					Nats []string `json:"nats"`
				}
				if json.Unmarshal(data, &ports) == nil && len(ports.Nats) > 0 {
					return ports.Nats[0]
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("nats-server did not publish a client port")
	return ""
}

func TestShouldLog(t *testing.T) {
	tests := []struct {
		level     string
		threshold string
		want      bool
	}{
		{"debug", "debug", true},
		{"debug", "info", false},
		{"info", "info", true},
		{"warn", "info", true},
		{"error", "warn", true},
		{"info", "invalid", true},
		{"debug", "invalid", false},
	}
	for _, tt := range tests {
		got, err := shouldLog(tt.level, tt.threshold)
		if err != nil {
			t.Fatalf("shouldLog(%q, %q): %v", tt.level, tt.threshold, err)
		}
		if got != tt.want {
			t.Errorf("shouldLog(%q, %q) = %v, want %v",
				tt.level, tt.threshold, got, tt.want)
		}
	}
}

func TestShouldLogRejectsUnknownLevel(t *testing.T) {
	if _, err := shouldLog("notice", "info"); err == nil {
		t.Fatal("shouldLog accepted an unknown level")
	}
}

func TestSignalShutdownIsIdempotent(t *testing.T) {
	c := New("test", "0.1.0")
	c.signalShutdown()
	c.signalShutdown()
	select {
	case <-c.shutdown:
	default:
		t.Fatal("shutdown signal did not close the channel")
	}
}

func TestCloseWaitsForActiveHandler(t *testing.T) {
	url := startTestNATS(t)
	var client *nats.Conn
	var err error
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		client, err = nats.Connect(url, nats.Timeout(100*time.Millisecond))
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("connect to test server: %v", err)
	}
	defer client.Close()
	t.Setenv("NIF_NATS_URL", url)

	started := make(chan struct{})
	finished := make(chan struct{})
	c := New("slow-test", "0.1.0").Tool("slow", map[string]any{
		"type": "object", "properties": map[string]any{},
	}, func(c *Component, args json.RawMessage) (any, error) {
		close(started)
		time.Sleep(500 * time.Millisecond)
		close(finished)
		return map[string]bool{"ok": true}, nil
	})
	if err := c.Connect(); err != nil {
		t.Fatal(err)
	}

	request := Envelope{V: 1, ID: NewID(), Kind: KindCall,
		Tool: "slow", Args: json.RawMessage(`{}`)}
	data, _ := request.Marshal()
	replied := make(chan error, 1)
	go func() {
		_, requestErr := client.Request("svc.slow-test.call", data, 3*time.Second)
		replied <- requestErr
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("slow handler did not start")
	}

	c.Close()
	select {
	case <-finished:
	default:
		t.Fatal("Close returned before the active handler finished")
	}
	if err := <-replied; err != nil {
		t.Fatalf("active handler reply was lost during Close: %v", err)
	}

	closeFromHandler := New("handler-close-test", "0.1.0").Tool("close", map[string]any{
		"type": "object", "properties": map[string]any{},
	}, func(c *Component, args json.RawMessage) (any, error) {
		c.Close()
		return map[string]bool{"ok": true}, nil
	})
	if err := closeFromHandler.Connect(); err != nil {
		t.Fatal(err)
	}
	request = Envelope{V: 1, ID: NewID(), Kind: KindCall,
		Tool: "close", Args: json.RawMessage(`{}`)}
	data, _ = request.Marshal()
	startedAt := time.Now()
	if _, err := client.Request("svc.handler-close-test.call", data, 3*time.Second); err != nil {
		t.Fatalf("Close invoked by a handler lost its reply: %v", err)
	}
	closeFromHandler.Close()
	if elapsed := time.Since(startedAt); elapsed > 2*time.Second {
		t.Fatalf("Close invoked by a handler self-waited: %v", elapsed)
	}
}
