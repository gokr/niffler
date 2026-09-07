package main

import (
	"strings"
	"testing"
)

func TestExpandEnvRefs(t *testing.T) {
	t.Setenv("MCP_TEST_TOKEN", "s3cret")

	got, err := expandEnvRefs("Bearer ${MCP_TEST_TOKEN}")
	if err != nil || got != "Bearer s3cret" {
		t.Fatalf("expandEnvRefs = %q, %v; want %q", got, err, "Bearer s3cret")
	}

	// A missing variable fails and names the variable.
	_, err = expandEnvRefs("Bearer ${MCP_TEST_MISSING}/suffix")
	if err == nil || !strings.Contains(err.Error(), "MCP_TEST_MISSING") {
		t.Fatalf("missing var error = %v; want it to name MCP_TEST_MISSING", err)
	}

	// All missing variables are named in one error.
	_, err = expandEnvRefs("${MCP_TEST_A_ONE} ${MCP_TEST_B_TWO}")
	if err == nil || !strings.Contains(err.Error(), "MCP_TEST_A_ONE") || !strings.Contains(err.Error(), "MCP_TEST_B_TWO") {
		t.Fatalf("multi-missing error = %v; want both names", err)
	}

	// A bare $ stays literal; $$ stays literal; only ${NAME} expands.
	got, err = expandEnvRefs("$MCP_TEST_TOKEN $$ ${MCP_TEST_TOKEN}")
	if err != nil || got != "$MCP_TEST_TOKEN $$ s3cret" {
		t.Fatalf("literal handling = %q, %v", got, err)
	}

	if got, err := expandEnvRefs(""); err != nil || got != "" {
		t.Fatalf("empty = %q, %v", got, err)
	}
}

func TestExpandEnvMap(t *testing.T) {
	t.Setenv("MCP_TEST_KEY", "v")

	out, err := expandEnvMap(map[string]string{
		"Authorization": "Bearer ${MCP_TEST_KEY}",
		"plain":         "x",
	})
	if err != nil {
		t.Fatalf("expandEnvMap: %v", err)
	}
	if out["Authorization"] != "Bearer v" || out["plain"] != "x" {
		t.Fatalf("expandEnvMap = %v", out)
	}

	// Failures report the offending key and variable.
	_, err = expandEnvMap(map[string]string{"Authorization": "${MCP_TEST_NOPE}"})
	if err == nil || !strings.Contains(err.Error(), "Authorization") || !strings.Contains(err.Error(), "MCP_TEST_NOPE") {
		t.Fatalf("map error = %v; want key + variable name", err)
	}
}
