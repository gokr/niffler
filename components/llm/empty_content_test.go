package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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

// A parts message whose only part is an empty text part reached the wire as
// {"type":"text"} — go-openai drops an empty ChatMessagePart.Text (omitempty),
// and a strict provider rejects the part. It is latent rather than live today
// (core/attachments.nim only adds a text part when the text is non-empty), so
// this pins the boundary instead of a user-visible failure.
//
// The fix must stay surgical: only EMPTY text parts are rewritten. A non-empty
// part is content the caller chose, and an image part must pass through
// untouched — rewriting either would corrupt a real request to satisfy a
// validator.
func TestEmptyTextPartIsSpellable(t *testing.T) {
	imageURL := "data:image/png;base64,AA"
	msgs := []chatMessage{
		{Role: "user", MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeText}}},
		{Role: "user", MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeText, Text: "keep me"},
			{Type: openai.ChatMessagePartTypeImageURL,
				ImageURL: &openai.ChatMessageImageURL{URL: imageURL}}}},
		// An image-only message has no text part to rewrite and must not
		// grow one: the sentinel belongs to the no-content path, not here.
		{Role: "user", MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeImageURL,
				ImageURL: &openai.ChatMessageImageURL{URL: imageURL}}}},
	}
	out := openAIMessages(msgs)

	for i, m := range out {
		if len(m.MultiContent) == 0 {
			t.Fatalf("message %d lost its parts: %+v", i, m)
		}
		for _, part := range m.MultiContent {
			if part.Type == openai.ChatMessagePartTypeText && part.Text == "" {
				t.Fatalf("message %d still carries an empty text part", i)
			}
		}
	}
	if out[0].MultiContent[0].Text != " " {
		t.Fatalf("empty text part = %q, want a single space", out[0].MultiContent[0].Text)
	}
	if out[0].Content != "" {
		t.Fatalf("parts message grew a Content string: %q", out[0].Content)
	}
	if out[1].MultiContent[0].Text != "keep me" ||
		out[1].MultiContent[1].ImageURL == nil ||
		out[1].MultiContent[1].ImageURL.URL != imageURL {
		t.Fatalf("non-empty text or image part was rewritten: %+v", out[1].MultiContent)
	}
	if len(out[2].MultiContent) != 1 ||
		out[2].MultiContent[0].Type != openai.ChatMessagePartTypeImageURL {
		t.Fatalf("image-only message was altered: %+v", out[2].MultiContent)
	}
	// Stored history is canonical: normalization is a wire concern only.
	if msgs[0].MultiContent[0].Text != "" {
		t.Fatal("wire normalization mutated stored history")
	}

	// What a strict provider actually receives.
	wire, err := json.Marshal(out[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wire), `"text":" "`) {
		t.Fatalf("wire shape: %s", wire)
	}
}
