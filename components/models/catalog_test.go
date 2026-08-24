package main

import (
	"encoding/json"
	"testing"
)

func TestApplyMergePatch(t *testing.T) {
	target := map[string]any{
		"provider": map[string]any{
			"api": "old",
			"models": map[string]any{
				"keep":   map[string]any{"reasoning": true, "limit": map[string]any{"context": 100}},
				"remove": map[string]any{"id": "remove"},
			},
		},
	}
	patch := map[string]any{
		"provider": map[string]any{
			"api": "new",
			"models": map[string]any{
				"keep":   map[string]any{"reasoning": false, "limit": map[string]any{"output": 20}},
				"remove": nil,
			},
		},
	}
	got := applyMergePatch(cloneObject(target), patch)
	provider := objectValue(got["provider"])
	models := objectValue(provider["models"])
	keep := objectValue(models["keep"])
	limit := objectValue(keep["limit"])
	if provider["api"] != "new" || keep["reasoning"] != false {
		t.Fatalf("patch did not replace scalar values: %#v", got)
	}
	if _, exists := models["remove"]; exists {
		t.Fatalf("patch did not delete null member: %#v", got)
	}
	if limit["context"] != 100 || limit["output"] != 20 {
		t.Fatalf("patch did not merge nested object: %#v", limit)
	}
}

func TestSourcesFromRegistration(t *testing.T) {
	var reg registration
	err := json.Unmarshal([]byte(`{
		"name":"fixture-source",
		"tools":[
			{"name":"fixture_models","schema":{"x-models-source":{"version":1,"priority":250}}},
			{"name":"ignored","schema":{"x-models-source":{"version":2}}}
		]
	}`), &reg)
	if err != nil {
		t.Fatal(err)
	}
	sources := sourcesFromRegistration(reg)
	if len(sources) != 1 {
		t.Fatalf("got %d sources, want 1", len(sources))
	}
	if sources[0].key() != "fixture-source/fixture_models" || sources[0].Priority != 250 {
		t.Fatalf("unexpected source: %#v", sources[0])
	}
}

func TestResolveRejectsAmbiguousBareID(t *testing.T) {
	state := &catalogState{effective: map[string]any{
		"one": map[string]any{"models": map[string]any{"shared": map[string]any{"id": "shared"}}},
		"two": map[string]any{"models": map[string]any{"shared": map[string]any{"id": "shared"}}},
	}}
	result := state.resolve("shared", "")
	if found, _ := result["found"].(bool); found {
		t.Fatalf("ambiguous model unexpectedly resolved: %#v", result)
	}
	matches, _ := result["matches"].([]string)
	if len(matches) != 2 {
		t.Fatalf("got matches %#v, want two", result["matches"])
	}
}

func TestProviderMetadataRedactsSecrets(t *testing.T) {
	metadata := providerMetadata(map[string]any{
		"api":        "https://example.test/v1",
		"apiKey":     "top-secret",
		"privateKey": "top-secret",
		"headers": map[string]any{
			"Authorization":       "Bearer top-secret",
			"Proxy-Authorization": "Bearer top-secret",
			"X-Feature":           "enabled",
		},
		"credentials": map[string]any{"user": "u", "cookie": "sid=top-secret"},
		"oauth":       []any{map[string]any{"access_token": "top-secret", "issuer": "example"}},
		"models":      map[string]any{"model": map[string]any{"id": "model"}},
	})
	if _, exists := metadata["apiKey"]; exists {
		t.Fatalf("apiKey was exposed: %#v", metadata)
	}
	if _, exists := metadata["privateKey"]; exists {
		t.Fatalf("privateKey was exposed: %#v", metadata)
	}
	if _, exists := metadata["credentials"]; exists {
		t.Fatalf("credentials were exposed: %#v", metadata)
	}
	headers := objectValue(metadata["headers"])
	if _, exists := headers["Authorization"]; exists || headers["X-Feature"] != "enabled" {
		t.Fatalf("headers were not selectively redacted: %#v", headers)
	}
	if _, exists := headers["Proxy-Authorization"]; exists {
		t.Fatalf("proxy authorization was exposed: %#v", headers)
	}
	oauth := metadata["oauth"].([]any)[0].(map[string]any)
	if _, exists := oauth["access_token"]; exists || oauth["issuer"] != "example" {
		t.Fatalf("nested credentials were exposed: %#v", oauth)
	}
	if _, exists := metadata["models"]; exists {
		t.Fatalf("models were included in provider metadata: %#v", metadata)
	}
}

func TestModelLevelRedaction(t *testing.T) {
	model := map[string]any{
		"id":       "m",
		"provider": map[string]any{"apiKey": "top-secret", "name": "p"},
	}
	redacted := redactMetadata(model).(map[string]any)
	provider := objectValue(redacted["provider"])
	if _, exists := provider["apiKey"]; exists {
		t.Fatalf("model-level apiKey was exposed: %#v", redacted)
	}
	if provider["name"] != "p" {
		t.Fatalf("non-secret model data was lost: %#v", redacted)
	}
}

func TestDecodeCatalogRejectsNoUsableModels(t *testing.T) {
	for name, body := range map[string]string{
		"empty catalog":      `{}`,
		"empty models":       `{"p": {"models": {}}}`,
		"scalar model entry": `{"p": {"models": {"m": 7}}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeCatalog([]byte(body)); err == nil {
				t.Fatalf("decodeCatalog accepted %s", name)
			}
		})
	}
	good := `{"p": {"models": {"m": {"id": "m"}}}}`
	if _, err := decodeCatalog([]byte(good)); err != nil {
		t.Fatalf("decodeCatalog rejected a valid catalog: %v", err)
	}
}

func TestModelMatchesMissingStatusMeansActive(t *testing.T) {
	model := map[string]any{"id": "m"}
	if !modelMatches("m", model, "", listModelsArgs{Status: "active"}) {
		t.Fatal("missing status did not match active")
	}
	if modelMatches("m", model, "", listModelsArgs{Status: "deprecated"}) {
		t.Fatal("missing status matched deprecated")
	}
	model["status"] = "beta"
	if !modelMatches("m", model, "", listModelsArgs{Status: "beta"}) {
		t.Fatal("explicit beta status did not match")
	}
}

func TestDisplayURLStripsSecrets(t *testing.T) {
	displayed := displayURL("https://user:token@host.example/api.json?key=secret#frag")
	if displayed != "https://host.example/api.json" {
		t.Fatalf("displayURL leaked URL parts: %s", displayed)
	}
}

func TestPathLastSegment(t *testing.T) {
	if got := pathLastSegment("https://h/catalog.json?token=x"); got != "catalog.json" {
		t.Fatalf("pathLastSegment with query: %s", got)
	}
	if got := pathLastSegment("https://h/api/"); got != "api" {
		t.Fatalf("pathLastSegment trailing slash: %s", got)
	}
}
