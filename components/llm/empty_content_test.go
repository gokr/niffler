package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	openai "github.com/sashabaranov/go-openai"
)

// Exercise both real request paths, including a resumed transcript with an
// empty tool result. Checking only key presence missed the malformed text part.
func TestEmptyToolResultOnWire(t *testing.T) {
	for _, streaming := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%v", streaming), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct {
					Messages []map[string]json.RawMessage `json:"messages"`
					Stream   bool                         `json:"stream"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				if len(request.Messages) != 4 {
					t.Errorf("messages = %d, want 4", len(request.Messages))
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				tool := request.Messages[2]
				if string(tool["content"]) != `"[empty message]"` || string(tool["tool_call_id"]) != `"c1"` {
					t.Errorf("invalid tool result on wire: %s", tool)
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				if request.Stream != streaming {
					t.Errorf("stream = %v, want %v", request.Stream, streaming)
				}
				if streaming {
					w.Header().Set("Content-Type", "text/event-stream")
					fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
				} else {
					w.Header().Set("Content-Type", "application/json")
					fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`)
				}
			}))
			defer server.Close()
			cfg := openai.DefaultConfig("test")
			cfg.BaseURL = server.URL
			client := openai.NewClientWithConfig(cfg)
			var args chatArgs
			if err := json.Unmarshal([]byte(`{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","name":"read","content":""},{"role":"user","content":"continue"}]}`), &args); err != nil {
				t.Fatal(err)
			}
			var err error
			if streaming {
				_, err = chatStream(context.Background(), nil, client, "test", "test", args, 8192, 512)
			} else {
				_, err = chatOnce(client, "test", "test", args, 8192, 512)
			}
			if err != nil {
				t.Fatal(err)
			}
			if args.Messages[2].Content != "" {
				t.Fatal("request changed canonical tool result")
			}
		})
	}
}
