package main

// The settings migration path (docs/research/CONFIG-CONTRACT.md): a stored
// value must beat the environment variable, and an absent stored value must
// leave the old behaviour exactly as it was. This is a unit test because the
// precedence rule is the guarantee an operator relies on while the env var is
// being retired — it deserves a deterministic check, not a bus race.

import (
	"os"
	"testing"
	"time"

	sdk "niffler.dev/sdk"
)

func TestStoredSettingBeatsTheEnvironment(t *testing.T) {
	t.Setenv("NIF_MODELS_OFFLINE", "1")
	if got := sdk.SettingBool(map[string]any{"offline": false}, "offline", "NIF_MODELS_OFFLINE", true); got {
		t.Fatal("stored false lost to the environment")
	}
	// Absent stored value: the env var still decides, so an existing
	// deployment keeps working while the migration is in progress.
	if got := sdk.SettingBool(map[string]any{}, "offline", "NIF_MODELS_OFFLINE", false); !got {
		t.Fatal("environment fallback stopped working")
	}
	// Neither present: the default.
	if got := sdk.SettingBool(map[string]any{}, "offline", "NIF_MODELS_UNSET_VAR", true); !got {
		t.Fatal("default ignored")
	}
}

func TestStoredNumberRejectsNonsense(t *testing.T) {
	t.Setenv("NIF_MODELS_CACHE_TTL_SECONDS", "600")
	if got := sdk.SettingFloat(map[string]any{"cacheTtlSeconds": 30.0}, "cacheTtlSeconds", "NIF_MODELS_CACHE_TTL_SECONDS", 300); got != 30 {
		t.Fatalf("stored value ignored: %v", got)
	}
	// A negative stored value must fall back rather than disable the feature
	// silently; the schema refuses it, so this is defence in depth against a
	// hand-edited record.
	if got := sdk.SettingFloat(map[string]any{"cacheTtlSeconds": -5.0}, "cacheTtlSeconds", "NIF_MODELS_CACHE_TTL_SECONDS", 300); got != 600 {
		t.Fatalf("nonsense stored value was not rejected: %v", got)
	}
}

func TestCatalogUsesSettingsPerCall(t *testing.T) {
	// No component (unit context): the boot values stay authoritative, so a
	// catalog built without a bus behaves exactly as before this change.
	state := &catalogState{offline: true, cacheTTL: 90 * time.Second}
	if !state.offlineNow() {
		t.Fatal("boot offline flag lost")
	}
	if got := state.cacheTTLNow(); got != 90*time.Second {
		t.Fatalf("boot TTL lost: %v", got)
	}
	// A stored refresh interval replaces the env/default for the next tick.
	t.Setenv("NIF_MODELS_REFRESH_INTERVAL_SECONDS", "240")
	if got := state.refreshIntervalNow(time.Hour); got != 240*time.Second {
		t.Fatalf("refresh interval precedence: %v", got)
	}
	os.Unsetenv("NIF_MODELS_REFRESH_INTERVAL_SECONDS")
	if got := state.refreshIntervalNow(time.Hour); got != time.Hour {
		t.Fatalf("refresh interval fallback: %v", got)
	}
}
