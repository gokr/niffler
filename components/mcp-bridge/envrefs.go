// ${NAME} interpolation for MCP server configuration. The store keeps the
// placeholder; values resolve from the bridge process environment at
// connect/spawn time, so tokens never sit in the store or in listings.
package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// envRefPattern matches ${NAME} references. A bare $, $$ or ${} stays
// literal — only a valid environment variable name inside braces expands.
var envRefPattern = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// expandEnvRefs resolves ${NAME} references in s from the process
// environment. Unset names fail with an error naming every missing variable,
// so an auth header never silently goes out empty.
func expandEnvRefs(s string) (string, error) {
	var missing []string
	out := envRefPattern.ReplaceAllStringFunc(s, func(ref string) string {
		name := ref[2 : len(ref)-1]
		if v, ok := os.LookupEnv(name); ok {
			return v
		}
		missing = append(missing, name)
		return ref
	})
	if len(missing) > 0 {
		return "", fmt.Errorf("env var(s) not set: %s", strings.Join(missing, ", "))
	}
	return out, nil
}

// expandEnvMap resolves ${NAME} references in every value of m, reporting
// failures with the offending key.
func expandEnvMap(m map[string]string) (map[string]string, error) {
	out := make(map[string]string, len(m))
	for k, v := range m {
		resolved, err := expandEnvRefs(v)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", k, err)
		}
		out[k] = resolved
	}
	return out, nil
}
