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

// An x-embed-source declaration is metadata, not an implementation: it says
// which models produce vectors, their dimensions and window, so consumers can
// discover and choose. Its patch must never land in the chat catalog (a chat
// request for an embedding model is a 400), and it must show up in the
// embedding view that models_list/models_get/resolve surface.
func TestEmbedSourceFormsASeparateView(t *testing.T) {
	state := &catalogState{
		base: map[string]any{
			"provider": map[string]any{
				"id":     "provider",
				"models": map[string]any{"chat": map[string]any{"id": "chat"}},
			},
			"synthetic": map[string]any{
				"id":         "synthetic",
				"embedModel": "hf:nomic-ai/nomic-embed-text-v1.5",
				"models":     map[string]any{"syn:small:text": map[string]any{"id": "syn:small:text"}},
			},
		},
		sources:  make(map[string]modelSource),
		patches:  make(map[string]map[string]any),
		statuses: make(map[string]sourceStatus),
	}
	source := modelSource{Component: "fixture", Tool: "fixture_embed", Priority: 100, Version: 1, Embed: true}
	state.sources[source.key()] = source
	state.embedPatches = map[string]map[string]any{source.key(): {
		"provider": map[string]any{"available": map[string]any{
			"embed-large": map[string]any{
				"id": "embed-large", "name": "Embed Large",
				"dimensions": 1024, "limit": map[string]any{"context": 8192},
			},
		}},
	}}
	state.rebuildLocked()

	// It never enters the chat catalog proper: the provider's own model map
	// is unchanged, so a chat completion cannot be asked of it by accident.
	if _, inChat := objectValue(state.effective["provider"])["models"].(map[string]any)["embed-large"]; inChat {
		t.Fatal("embed model leaked into the chat model map")
	}
	// Unfiltered listing is one surface for both kinds, flagged — but the
	// chat-only filter must exclude the embed entry.
	list, _ := state.models(listModelsArgs{Provider: "provider", Embed: boolPtr(false)})
	if len(list) != 1 || list[0]["id"] != "chat" {
		t.Fatalf("chat list = %#v", list)
	}
	both, _ := state.models(listModelsArgs{Provider: "provider"})
	if len(both) != 2 {
		t.Fatalf("unfiltered list = %#v", both)
	}

	// But discoverable through the embedding view, marked as such.
	embedList, _ := state.models(listModelsArgs{Embed: boolPtr(true)})
	references := map[string]map[string]any{}
	for _, entry := range embedList {
		references[stringValue(entry["reference"])] = entry
	}
	entry, ok := references["provider/embed-large"]
	if !ok {
		t.Fatalf("embed-model source not listed: %#v", embedList)
	}
	if entry["embedding"] != true || entry["dimensions"] != 1024 {
		t.Fatalf("embed entry = %#v", entry)
	}
	// A provider's configured embedModel is part of the same view even when
	// no source declares it.
	if _, ok := references["synthetic/hf:nomic-ai/nomic-embed-text-v1.5"]; !ok {
		t.Fatalf("configured embedModel not listed: %#v", embedList)
	}
	// The chat-only filter excludes embedding entries entirely.
	chatOnly, _ := state.models(listModelsArgs{Embed: boolPtr(false)})
	for _, entry := range chatOnly {
		if entry["embedding"] == true {
			t.Fatalf("chat-only filter leaked an embedding model: %#v", entry)
		}
	}

	// models_get and resolve reach it, and report the flag.
	get, found := state.get("provider", "embed-large")
	if !found || get["embedding"] != true {
		t.Fatalf("models_get lost the embed entry: %#v found=%v", get, found)
	}
	resolved := state.resolve("provider/embed-large", "")
	if found, _ := resolved["found"].(bool); !found {
		t.Fatalf("resolve lost the embed entry: %#v", resolved)
	}
	bare := state.resolve("embed-large", "")
	if found, _ := bare["found"].(bool); !found {
		t.Fatalf("resolve lost a bare embed id: %#v", bare)
	}

	// Provider metadata names the configured embed model.
	providers := state.providers("", nil)
	for _, provider := range providers {
		if provider["id"] == "synthetic" && provider["embedModel"] != "hf:nomic-ai/nomic-embed-text-v1.5" {
			t.Fatalf("provider embedModel = %#v", provider["embedModel"])
		}
	}
}

func TestSourcesFromRegistrationDiscoversEmbedSources(t *testing.T) {
	var reg registration
	if err := json.Unmarshal([]byte(`{
		"name":"fixture",
		"tools":[
			{"name":"both","schema":{
				"x-models-source":{"version":1,"priority":250},
				"x-embed-source":{"version":1,"priority":120}}},
			{"name":"embed-only","schema":{"x-embed-source":{"version":1}}},
			{"name":"wrong-version","schema":{"x-embed-source":{"version":2}}}
		]
	}`), &reg); err != nil {
		t.Fatal(err)
	}
	sources := sourcesFromRegistration(reg)
	kinds := map[string]modelSource{}
	for _, source := range sources {
		kinds[source.key()] = source
	}
	if len(kinds) != 3 {
		t.Fatalf("got %d sources, want 3: %#v", len(kinds), sources)
	}
	// The two extensions of one tool stay distinct, with their own priority.
	if chat := kinds["fixture/both"]; chat.Embed || chat.Priority != 250 {
		t.Fatalf("chat source = %#v", chat)
	}
	if embed := kinds["fixture/both#embed"]; !embed.Embed || embed.Priority != 120 {
		t.Fatalf("embed source = %#v", embed)
	}
	if embed := kinds["fixture/embed-only#embed"]; !embed.Embed || embed.Priority != defaultSourceOrder {
		t.Fatalf("embed-only source = %#v", embed)
	}
}

func boolPtr(value bool) *bool { return &value }
