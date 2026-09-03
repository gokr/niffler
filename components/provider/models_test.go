package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDecodeModelsEnvelope(t *testing.T) {
	// Standard OpenAI-compatible envelope; duplicate and id-less entries
	// are skipped, extra fields preserved.
	models, err := decodeModelsEnvelope([]byte(`{
		"object": "list",
		"data": [
			{"id": "hf:zai-org/GLM-5.3-Flash", "owned_by": "zai"},
			{"id": "hf:moonshotai/Kimi-K3", "created": 1700000000},
			{"id": "hf:moonshotai/Kimi-K3"},
			{"object": "model"}
		]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 {
		t.Fatalf("models = %#v, want 2 entries", models)
	}
	if models[0].ID != "hf:zai-org/GLM-5.3-Flash" || models[0].Extra["owned_by"] != "zai" {
		t.Fatalf("entry = %#v", models[0])
	}
	if models[1].Extra["created"] == nil {
		t.Fatalf("created field dropped: %#v", models[1])
	}

	// Bare array (some gateways) also decodes.
	models, err = decodeModelsEnvelope([]byte(`[{"id": "glm-5.3"}]`))
	if err != nil || len(models) != 1 || models[0].ID != "glm-5.3" {
		t.Fatalf("bare array = %#v err=%v", models, err)
	}

	// No usable entries is an error, so a malformed response cannot poison
	// the cache.
	if _, err := decodeModelsEnvelope([]byte(`{"data": []}`)); err == nil {
		t.Fatal("empty data accepted")
	}
}

func TestListProviderModelsProbesAndCaches(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path != "/v1/models" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer sk-test" {
			t.Errorf("auth header = %q", r.Header.Get("Authorization"))
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{{"id": "hf:zai-org/GLM-5.3-Flash"}, {"id": "hf:moonshotai/Kimi-K3"}},
		})
	}))
	defer server.Close()

	// Isolate the on-disk cache for this test.
	t.Setenv("NIF_ROOT", t.TempDir())
	p := Provider{Nickname: "synthetic", AuthType: authAPIKey, Protocol: protocolOpenAI,
		BaseURL: server.URL + "/v1", APIKey: "sk-test"}

	models, endpoint, cached, err := listProviderModels(p, false)
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != server.URL+"/v1/models" || cached || len(models) != 2 {
		t.Fatalf("first probe = endpoint:%q cached:%v n:%d", endpoint, cached, len(models))
	}
	if requests != 1 {
		t.Fatalf("requests = %d, want 1", requests)
	}

	// Second call within the TTL is served from cache without a probe.
	if _, _, cached, err = listProviderModels(p, false); err != nil || !cached {
		t.Fatalf("second call cached=%v err=%v", cached, err)
	}
	if requests != 1 {
		t.Fatalf("cache miss: requests = %d", requests)
	}

	// refresh bypasses the cache.
	if _, _, cached, err = listProviderModels(p, true); err != nil || cached {
		t.Fatalf("refresh cached=%v err=%v", cached, err)
	}
	if requests != 2 {
		t.Fatalf("refresh did not probe: requests = %d", requests)
	}

	// A failing endpoint falls back to the last-known-good cache.
	server.Close()
	models, _, cached, err = listProviderModels(p, false)
	if err != nil || !cached || len(models) != 2 {
		t.Fatalf("stale fallback = n:%d cached:%v err:%v", len(models), cached, err)
	}
}

func TestListProviderModelsNoCacheFails(t *testing.T) {
	t.Setenv("NIF_ROOT", t.TempDir())
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"boom"}`, http.StatusInternalServerError)
	}))
	defer server.Close()
	p := Provider{Nickname: "broken", AuthType: authAPIKey, Protocol: protocolOpenAI,
		BaseURL: server.URL + "/v1", APIKey: "sk-test"}
	_, _, cached, err := listProviderModels(p, false)
	if err == nil || cached {
		t.Fatalf("expected failure with no cache available, got cached=%v err=%v", cached, err)
	}
}
