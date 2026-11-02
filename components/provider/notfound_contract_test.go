package main

import (
	"encoding/json"
	"niffler.dev/sdk"
	"testing"
)

// The contract the llm component's classifyProviderReply relies on: a
// definitive not-found is a RESULT with code "not-found", never a handler
// error. A handler error becomes a code-"boom" ERROR envelope
// (sdk/go/component.go invokeTool), which a caller cannot distinguish from
// "the component failed" — and reading it as a verdict is what reported a
// live, existing provider as `unknown provider "synthetic"`.
func TestNotFoundIsAResultWithCode(t *testing.T) {
	v := sdk.ErrCode(`provider "x" not found`, "not-found")
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		Ok    bool   `json:"ok"`
		Code  string `json:"code"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Ok || back.Code != "not-found" || back.Error == "" {
		t.Fatalf("not-found payload = %s (want ok:false, code:not-found)", raw)
	}
}
