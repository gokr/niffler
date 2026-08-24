// Package sdk is the Niffler component SDK (Go).
//
// Harness discovery + ensure — for interactive clients (UIs, terminal
// frontends) that should "just work": attach to the running harness, or
// start one. Mirrors sdk/niffler/sdk.nim.
package sdk

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

const defaultNatsUrl = "nats://127.0.0.1:4222"

// ResolveNatsUrl returns the bus address: NIF_NATS_URL env →
// <root>/var/nats-url discovery file → the well-known local default.
func ResolveNatsUrl(root string) string {
	if u := os.Getenv("NIF_NATS_URL"); u != "" {
		return u
	}
	if root == "" {
		root = os.Getenv("NIF_ROOT")
	}
	data, err := os.ReadFile(filepath.Join(root, "var", "nats-url"))
	if err == nil {
		if u := strings.TrimSpace(string(data)); u != "" {
			return u
		}
	}
	return defaultNatsUrl
}

// CoreAnswers reports whether a live core is answering svc.core.call on
// this bus (a bare NATS server without Niffler does not count).
func CoreAnswers(url string, timeout time.Duration) bool {
	nc, err := nats.Connect(url, nats.Timeout(timeout))
	if err != nil {
		return false
	}
	defer nc.Close()
	args, _ := json.Marshal(map[string]any{"op": "list"})
	call := Envelope{V: 1, ID: NewID(), Kind: KindCall, Tool: "catalog", Args: args}
	data, err := call.Marshal()
	if err != nil {
		return false
	}
	msg, err := nc.Request("svc.core.call", data, timeout)
	if err != nil {
		return false
	}
	return ParseEnvelope(msg.Data).Kind == KindResult
}

func candidateUrls(root string) []string {
	// Discovery file first (core's actual bus), then the well-known port.
	var urls []string
	data, err := os.ReadFile(filepath.Join(root, "var", "nats-url"))
	if err == nil {
		if u := strings.TrimSpace(string(data)); u != "" {
			urls = append(urls, u)
		}
	}
	return append(urls, defaultNatsUrl)
}

// EnsureHarness attaches to the running harness, or starts one for root.
// Probe order: NIF_NATS_URL (explicit always wins — nothing is spawned),
// core's discovery file, the well-known port. If no core answers anywhere,
// it spawns <root>/var/bin/niffler detached with NIF_AUTOSTART=1; that core
// exits when the last interactive client (Component.Client) departs. The
// answering bus URL is returned and also exported as NIF_NATS_URL so
// Connect picks it up.
func EnsureHarness(root string) (string, error) {
	if explicit := os.Getenv("NIF_NATS_URL"); explicit != "" {
		return explicit, nil
	}
	if root == "" {
		root = os.Getenv("NIF_ROOT")
	}
	if root == "" {
		return "", fmt.Errorf("EnsureHarness: no harness root (pass it or set NIF_ROOT)")
	}
	// Probe for ~10s (NIF_ENSURE_ATTACH=0 skips attach entirely — tests):
	// covers an already-running core, a stale discovery file, and a sibling
	// UI that is spawning core right now.
	if os.Getenv("NIF_ENSURE_ATTACH") != "0" {
		probeUntil := time.Now().Add(10 * time.Second)
		for {
			for _, url := range candidateUrls(root) {
				if CoreAnswers(url, 500*time.Millisecond) {
					os.Setenv("NIF_NATS_URL", url)
					return url, nil
				}
			}
			if time.Now().After(probeUntil) {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
	coreBin := filepath.Join(root, "var", "bin", "niffler")
	if _, err := os.Stat(coreBin); err != nil {
		return "", fmt.Errorf("no harness running and core binary missing: %s — run `make build`", coreBin)
	}
	cmd := exec.Command(coreBin)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "NIF_ROOT="+root, "NIF_AUTOSTART=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("spawn core: %w", err)
	}
	// Reap the child whenever it exits (never wait ourselves).
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	// Trust only OUR core now: another harness may be live on the well-known
	// port — attaching to it would orphan the child we just spawned.
	spawnUntil := time.Now().Add(20 * time.Second)
	for time.Now().Before(spawnUntil) {
		select {
		case err := <-exited:
			return "", fmt.Errorf("spawned core exited immediately: %v", err)
		default:
		}
		data, err := os.ReadFile(filepath.Join(root, "var", "nats-url"))
		if err == nil {
			if u := strings.TrimSpace(string(data)); u != "" && CoreAnswers(u, 500*time.Millisecond) {
				os.Setenv("NIF_NATS_URL", u)
				return u, nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return "", fmt.Errorf("spawned core did not answer within 20s — check %s", root)
}
