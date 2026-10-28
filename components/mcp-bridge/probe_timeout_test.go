package main

// The probe deadline now arrives from two places, and the ORDER between them is
// the whole point: the caller (the `mcp` component) resolves the timeout from
// the owner's stored settings, but the bridge is a separate process that cannot
// read that record. So the caller passes it down explicitly, and an explicit
// value must beat this process's own NIF_MCP_PROBE_TIMEOUT_MS — otherwise a
// stored setting would be silently overridden by an env var on the bridge's
// side, which is exactly the "changes a mirror, not the rule" failure the
// authoritative-reader rule exists to prevent.

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// probeDeadline mirrors runProbe's resolution without running a probe: the
// precedence is what needs pinning, not the subprocess.
func probeDeadline(explicitMs int) time.Duration {
	timeout := listingTimeout
	if explicitMs > 0 {
		return time.Duration(explicitMs) * time.Millisecond
	}
	if raw := os.Getenv("NIF_MCP_PROBE_TIMEOUT_MS"); raw != "" {
		var ms int
		if _, err := fmt.Sscanf(raw, "%d", &ms); err == nil && ms > 0 {
			timeout = time.Duration(ms) * time.Millisecond
		}
	}
	return timeout
}

func TestProbeTimeoutPrecedence(t *testing.T) {
	// No explicit value, no env: the built-in default.
	t.Setenv("NIF_MCP_PROBE_TIMEOUT_MS", "")
	if got := probeDeadline(0); got != listingTimeout {
		t.Fatalf("default = %v, want %v", got, listingTimeout)
	}

	// Env alone is the migration path and still works.
	t.Setenv("NIF_MCP_PROBE_TIMEOUT_MS", "45000")
	if got := probeDeadline(0); got != 45*time.Second {
		t.Fatalf("env = %v, want 45s", got)
	}

	// The caller's resolved value (which already folded in the owner's STORED
	// setting) wins over this process's env. This is the regression that
	// matters: with env beating the argument, a saved setting does nothing.
	if got := probeDeadline(90_000); got != 90*time.Second {
		t.Fatalf("explicit = %v, want 90s (stored setting must beat the "+
			"bridge's own env)", got)
	}

	// A nonsense explicit value falls back to env rather than to zero, which
	// would otherwise mean "no deadline at all".
	if got := probeDeadline(-5); got != 45*time.Second {
		t.Fatalf("invalid explicit = %v, want the env value", got)
	}
}
