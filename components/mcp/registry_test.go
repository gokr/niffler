package main

import (
	"encoding/json"
	"testing"
)

const realRegistryBody = `{
 "servers": [
  {"server": {
    "name": "com.pulsemcp/remote-filesystem",
    "description": "Remote filesystem operations.",
    "version": "0.1.5",
    "packages": [{
      "registryType": "npm",
      "identifier": "remote-filesystem-mcp-server",
      "version": "0.1.5",
      "transport": {"type": "stdio"},
      "runtimeArguments": [{"value": "-y", "type": "positional"}],
      "environmentVariables": [
        {"description": "Bucket name.", "isRequired": true, "name": "GCS_BUCKET"},
        {"isSecret": true, "name": "GCS_PRIVATE_KEY"}
      ]
    }]
   },
   "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}
  },
  {"server": {
    "name": "io.github/example/remote-only",
    "title": "Remote",
    "version": "2.0.0",
    "remotes": [{"type": "streamable-http", "url": "https://mcp.example.com/mcp",
                 "headers": [{"name": "Authorization", "isRequired": true}]}]
  }},
  {"server": {
    "name": "io.github/example/ready",
    "title": "Ready",
    "version": "3.0.0",
    "packages": [{
      "registryType": "npm",
      "identifier": "ready-server",
      "version": "3.1.0",
      "transport": {"type": "stdio"},
      "environmentVariables": [{"name": "TOKEN", "value": "abc"}, {"name": "OPT", "default": "dv"}]
    }]
  }},
  {"server": {"name": "io.github/example/none", "version": "0.2.0"}}
 ]
}`

func parseBody(t *testing.T) []registryEntry {
	t.Helper()
	var payload struct {
		Servers []struct {
			Server registryServer `json:"server"`
		} `json:"servers"`
	}
	if err := json.Unmarshal([]byte(realRegistryBody), &payload); err != nil {
		t.Fatalf("wrapped registry payload must parse: %v", err)
	}
	out := []registryEntry{}
	for _, wrapped := range payload.Servers {
		out = append(out, registryCandidate(wrapped.Server))
	}
	return out
}

func TestRegistryWrappedShape(t *testing.T) {
	entries := parseBody(t)
	if len(entries) != 4 {
		t.Fatalf("got %d entries, want 4", len(entries))
	}
	first := entries[0]
	if first.Name != "com.pulsemcp/remote-filesystem" || first.Version != "0.1.5" {
		t.Errorf("fields must come from the nested server document: %#v", first)
	}
	if first.Installable {
		t.Errorf("required env without a value must block installation: %#v", first)
	}
	if !contains(first.Requirements, "environment GCS_BUCKET") || !contains(first.Requirements, "environment GCS_PRIVATE_KEY") {
		t.Errorf("unsatisfied required inputs must be listed: %#v", first.Requirements)
	}
	if first.Command != "npx" {
		t.Errorf("npm maps to npx, got %q", first.Command)
	}
	want := []string{"-y", "remote-filesystem-mcp-server@0.1.5"}
	if len(first.Args) != len(want) {
		t.Fatalf("args = %v, want %v", first.Args, want)
	}
	for i, a := range want {
		if first.Args[i] != a {
			t.Errorf("args[%d] = %q, want %q", i, first.Args[i], a)
		}
	}
	if first.Config["name"] != "remote-filesystem" {
		t.Errorf("suggested name from the last path segment: %#v", first.Config)
	}
	if env, _ := first.Config["env"].(map[string]string); len(env) != 0 {
		t.Errorf("unsatisfied env must not be pre-filled into the ready config: %#v", env)
	}
}

func TestRegistryRemoteEntry(t *testing.T) {
	second := parseBody(t)[1]
	if second.Installable || second.Transport != "http" || second.URL != "https://mcp.example.com/mcp" {
		t.Errorf("streamable-http remote must produce an http entry, gated by its required header: %#v", second)
	}
	if headers, _ := second.Config["headers"].(map[string]string); len(headers) != 0 {
		t.Errorf("required header without a value cannot be pre-filled: %#v", headers)
	}
	if !contains(second.Requirements, "header Authorization") {
		t.Errorf("missing required header must be a requirement: %#v", second.Requirements)
	}
}

func TestRegistryUnsupportedEntry(t *testing.T) {
	third := parseBody(t)[3]
	if third.Installable {
		t.Errorf("entry without usable transport must not be installable: %#v", third)
	}
	if third.NotInstallable == "" {
		t.Errorf("non-installable entries must carry a reason")
	}
}

func TestRegistryReadyEntry(t *testing.T) {
	ready := parseBody(t)[2]
	if !ready.Installable || ready.Command != "npx" {
		t.Fatalf("package with satisfied inputs must be installable: %#v", ready)
	}
	env, _ := ready.Config["env"].(map[string]string)
	if env["TOKEN"] != "abc" || env["OPT"] != "dv" {
		t.Errorf("satisfied and defaulted env values belong in the ready config: %#v", env)
	}
	if len(ready.Requirements) != 0 {
		t.Errorf("satisfied inputs must not become requirements: %#v", ready.Requirements)
	}
}

func TestRegistryPinnedVersions(t *testing.T) {
	entries := parseBody(t)
	if entries[0].Args[1] != "remote-filesystem-mcp-server@0.1.5" {
		t.Errorf("npm identifier must be pinned to the package version")
	}
}

func TestRegistrySuggestedName(t *testing.T) {
	for raw, want := range map[string]string{"io.github/user/server-name": "server-name", "plain": "plain"} {
		if got := registrySuggestedName(raw); got != want {
			t.Errorf("registrySuggestedName(%q) = %q, want %q", raw, got, want)
		}
	}
}
