package sdk

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config helpers — component configuration comes from the process env
// (docs/MANUAL.md); one helper per SDK keeps parsing uniform instead of
// every component hand-rolling getenv + clamps. Mirrors the config helpers
// in sdk/niffler/sdk.nim 1:1.

// ConfigStr returns the env var's value or the default when unset/empty.
func ConfigStr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

// ConfigBool reads a boolean env var: 1/true/yes/on (case-insensitive) are
// true, 0/false/no/off are false; anything else (including unset) reads as
// the default.
func ConfigBool(name string, def bool) bool {
	switch strings.ToLower(os.Getenv(name)) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

// ConfigInt reads an integer env var. Unparsable or outside [min, max]
// returns an error — a misconfigured component should fail loudly at boot;
// unset reads as the default.
func ConfigInt(name string, def, min, max int) (int, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got '%s'", name, raw)
	}
	if n < min || n > max {
		return 0, fmt.Errorf("%s must be in %d..%d, got %d", name, min, max, n)
	}
	return n, nil
}
