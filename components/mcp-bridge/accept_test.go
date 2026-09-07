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
