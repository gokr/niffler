package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAcceptContractEmptyListsNoDrift(t *testing.T) {
	// A stored record with omitted (nil) tool/prompt lists vs a freshly
	// listed non-nil empty contract must NOT count as drift — otherwise
	// servers without prompts drift-restart on every boot.
	b := newBridge(&serverConfig{Name: "t"}, nil, false)
	if err := b.acceptContract([]cachedTool{}, []cachedPrompt{}); err != nil {
		t.Fatalf("empty-vs-nil contract flagged as drift: %v", err)
	}
	if b.retiring {
		t.Fatal("bridge entered retiring without drift")
	}
}

func TestDirectToolThresholdDefersLargeServers(t *testing.T) {
	t.Setenv("NIF_MCP_DIRECT_THRESHOLD", "2")
	cfg := &serverConfig{Name: "large", Expose: "direct", Tools: []cachedTool{
		{Name: "a"}, {Name: "b"}, {Name: "c"},
	}}
	if !deferDirectTools(cfg) {
		t.Fatal("large direct server was not deferred")
	}
	if got := xHarness(cfg, false, true); got["onDemand"] != true {
		t.Fatalf("large server x-harness = %#v, want onDemand", got)
	}
	cfg.Tools = cfg.Tools[:2]
	if deferDirectTools(cfg) {
		t.Fatal("server at threshold was deferred")
	}
	if got := xHarness(cfg, false, false); got["onDemand"] == true {
		t.Fatalf("small direct server x-harness = %#v, want direct", got)
	}
}

func TestAcceptContractRealDriftFailsClosed(t *testing.T) {
	b := newBridge(&serverConfig{
		Name:  "t",
		Tools: []cachedTool{{Name: "a", InputSchema: json.RawMessage(`{"type":"object"}`)}},
	}, nil, false)
	err := b.acceptContract(
		[]cachedTool{
			{Name: "a", InputSchema: json.RawMessage(`{"type":"object"}`)},
			{Name: "b", InputSchema: json.RawMessage(`{"type":"object"}`)},
		},
		[]cachedPrompt{},
	)
	if err == nil || !strings.Contains(err.Error(), "could not be persisted") {
		t.Fatalf("real drift err = %v; want the fail-closed persist error", err)
	}
	if !b.retiring {
		t.Fatal("real drift must fail closed in retiring state")
	}
}
