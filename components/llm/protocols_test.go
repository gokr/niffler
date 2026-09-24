package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	openai "github.com/sashabaranov/go-openai"
)

func codexTestToken(accountID string) string {
	payload, _ := json.Marshal(map[string]any{
		"https://api.openai.com/auth": map[string]string{"chatgpt_account_id": accountID},
	})
	return "header." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func TestChatCodexUsesOAuthResponsesProtocol(t *testing.T) {
	token := codexTestToken("acct-test")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/codex/responses" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+token {
			t.Errorf("authorization = %q", got)
		}
		if got := r.Header.Get("chatgpt-account-id"); got != "acct-test" {
			t.Errorf("account id = %q", got)
		}
		if r.Header.Get("OpenAI-Beta") != "responses=experimental" || r.Header.Get("originator") != "niffler" {
			t.Errorf("Codex headers = %#v", r.Header)
		}
		if r.Header.Get("session-id") != "session-test" {
			t.Errorf("session-id = %q", r.Header.Get("session-id"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		if body["model"] != "gpt-test" || body["instructions"] != "system prompt" || body["store"] != false {
			t.Errorf("request body = %#v", body)
		}
		tools, _ := body["tools"].([]any)
		if len(tools) != 1 {
			t.Errorf("tools = %#v", body["tools"])
		} else if tool, _ := tools[0].(map[string]any); tool["name"] != "bash" || tool["x-harness"] != nil {
			t.Errorf("Codex tool = %#v", tool)
		}

		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		events := []any{
			map[string]any{"type": "response.reasoning_summary_text.delta", "delta": "Checked"},
			map[string]any{"type": "response.reasoning_summary_text.delta", "delta": "Double-checked", "summary_index": 1},
			map[string]any{"type": "response.output_text.delta", "delta": "Hello"},
			map[string]any{"type": "response.output_item.added", "output_index": 1, "item": map[string]any{
				"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "bash", "arguments": "",
			}},
			map[string]any{"type": "response.function_call_arguments.delta", "output_index": 1, "delta": `{"cmd":"`},
			map[string]any{"type": "response.function_call_arguments.done", "output_index": 1, "arguments": `{"cmd":"pwd"}`},
			map[string]any{"type": "response.output_item.done", "output_index": 1, "item": map[string]any{
				"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "bash", "arguments": `{"cmd":"pwd"}`,
			}},
			map[string]any{"type": "response.completed", "response": map[string]any{
				"status": "completed", "model": "gpt-test-actual",
				"usage": map[string]any{"input_tokens": 11, "output_tokens": 7, "total_tokens": 18},
			}},
		}
		for _, event := range events {
			encoded, _ := json.Marshal(event)
			_, _ = fmt.Fprintf(w, "data: %s\n\n", encoded)
			flusher.Flush()
		}
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
	}))
	defer server.Close()

	toolSchema := map[string]any{
		"type": "object", "properties": map[string]any{"cmd": map[string]any{"type": "string"}},
		"x-harness": map[string]any{"approval": "always"},
	}
	args := chatArgs{
		Messages: []chatMessage{
			{Role: openai.ChatMessageRoleSystem, Content: "system prompt"},
			{Role: openai.ChatMessageRoleUser, Content: "hello"},
		},
		Tools: []openai.Tool{{Type: openai.ToolTypeFunction, Function: &openai.FunctionDefinition{
			Name: "bash", Description: "Run a command", Parameters: toolSchema,
		}}},
		SessionID: "session-test",
	}
	result, err := chatCodex(context.Background(), nil, provider{
		BaseURL: server.URL, APIKey: token, Protocol: protocolCodex, AuthType: authOAuth,
	}, "gpt-test", "codex", args, 400000)
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["content"] != "Hello" || got["reasoning"] != "Checked\nDouble-checked" || got["model"] != "gpt-test-actual" {
		t.Fatalf("result = %#v", got)
	}
	usage := got["usage"].(map[string]any)
	if usage["prompt_tokens"] != 11 || usage["completion_tokens"] != 7 || usage["total_tokens"] != 18 {
		t.Fatalf("usage = %#v", usage)
	}
	calls := got["tool_calls"].([]map[string]any)
	if len(calls) != 1 || calls[0]["id"] != "call_1|fc_1" {
		t.Fatalf("tool calls = %#v", calls)
	}
	function := calls[0]["function"].(map[string]any)
	if function["name"] != "bash" || function["arguments"] != `{"cmd":"pwd"}` {
		t.Fatalf("function = %#v", function)
	}
}

func TestChatAnthropicUsesClaudeOAuthIdentity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/messages" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer sk-ant-oat-test" || r.Header.Get("x-api-key") != "" {
			t.Errorf("Anthropic auth headers = %#v", r.Header)
		}
		if !strings.Contains(r.Header.Get("anthropic-beta"), "oauth-2025-04-20") ||
			r.Header.Get("x-app") != "cli" || !strings.HasPrefix(r.Header.Get("User-Agent"), "claude-cli/") {
			t.Errorf("Anthropic identity headers = %#v", r.Header)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode body: %v", err)
		}
		system, _ := body["system"].([]any)
		if len(system) < 2 || system[0].(map[string]any)["text"] != "You are Claude Code, Anthropic's official CLI for Claude." {
			t.Errorf("system = %#v", system)
		}
		tools, _ := body["tools"].([]any)
		if len(tools) != 1 || tools[0].(map[string]any)["name"] != "Bash" {
			t.Errorf("tools = %#v", tools)
		}

		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		events := []any{
			map[string]any{"type": "message_start", "message": map[string]any{
				"id": "msg_1", "model": "claude-actual",
				"usage": map[string]any{"input_tokens": 10, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 2, "output_tokens": 0},
			}},
			map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "thinking", "thinking": ""}},
			map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "thinking_delta", "thinking": "Considered"}},
			map[string]any{"type": "content_block_start", "index": 1, "content_block": map[string]any{"type": "text", "text": ""}},
			map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "text_delta", "text": "Done"}},
			map[string]any{"type": "content_block_start", "index": 2, "content_block": map[string]any{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": map[string]any{}}},
			map[string]any{"type": "content_block_delta", "index": 2, "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"cmd":"pwd"}`}},
			map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": "tool_use"}, "usage": map[string]any{"output_tokens": 6}},
			map[string]any{"type": "message_stop"},
		}
		for _, event := range events {
			encoded, _ := json.Marshal(event)
			_, _ = fmt.Fprintf(w, "event: message\ndata: %s\n\n", encoded)
			flusher.Flush()
		}
	}))
	defer server.Close()

	args := chatArgs{
		Messages: []chatMessage{
			{Role: openai.ChatMessageRoleSystem, Content: "niffler system"},
			{Role: openai.ChatMessageRoleUser, Content: "do it"},
		},
		Tools: []openai.Tool{{Type: openai.ToolTypeFunction, Function: &openai.FunctionDefinition{
			Name: "bash", Description: "Run command", Parameters: map[string]any{"type": "object"},
		}}},
	}
	result, err := chatAnthropic(context.Background(), nil, provider{
		BaseURL: server.URL, APIKey: "sk-ant-oat-test", Protocol: protocolAnthropic, AuthType: authOAuth,
	}, "claude-test", "claude", args, 200000, 32000)
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["content"] != "Done" || got["reasoning"] != "Considered" || got["model"] != "claude-actual" {
		t.Fatalf("result = %#v", got)
	}
	usage := got["usage"].(map[string]any)
	if usage["prompt_tokens"] != 15 || usage["completion_tokens"] != 6 || usage["total_tokens"] != 21 {
		t.Fatalf("usage = %#v", usage)
	}
	// Cache reads surface in the OpenAI-style breakdown (cache-creation
	// input is a write, not a hit, so only reads map to cached_tokens).
	details := usage["prompt_tokens_details"].(map[string]any)
	if details["cached_tokens"] != 3 {
		t.Fatalf("cached_tokens = %v, want 3", details["cached_tokens"])
	}
	calls := got["tool_calls"].([]map[string]any)
	if len(calls) != 1 || calls[0]["id"] != "toolu_1" {
		t.Fatalf("tool calls = %#v", calls)
	}
	function := calls[0]["function"].(map[string]any)
	if function["name"] != "bash" || function["arguments"] != `{"cmd":"pwd"}` {
		t.Fatalf("function = %#v", function)
	}
}

func TestProtocolURLHelpers(t *testing.T) {
	if got := codexBaseURL("https://chatgpt.com/backend-api/codex/responses"); got != "https://chatgpt.com/backend-api/codex" {
		t.Fatalf("codexBaseURL = %q", got)
	}
	if got := anthropicMessagesURL("https://api.anthropic.com/v1"); got != "https://api.anthropic.com/v1/messages" {
		t.Fatalf("anthropicMessagesURL = %q", got)
	}
	if got := anthropicToolID("call|fc.bad"); got != "call_fc_bad" {
		t.Fatalf("anthropicToolID = %q", got)
	}
}

// --- image attachments across protocols -------------------------------------

const testPNGDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

func multimodalUserMessage() chatMessage {
	return chatMessage(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser,
		MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeText, Text: "what is this?"},
			{Type: openai.ChatMessagePartTypeImageURL,
				ImageURL: &openai.ChatMessageImageURL{URL: testPNGDataURL}},
		},
	})
}

func TestSplitDataURL(t *testing.T) {
	media, payload, ok := splitDataURL(testPNGDataURL)
	if !ok || media != "image/png" || payload == "" {
		t.Fatalf("splitDataURL = %q %q %v", media, payload, ok)
	}
	if _, _, ok := splitDataURL("https://example.test/a.png"); ok {
		t.Fatal("a remote URL is not a data URL")
	}
	if _, _, ok := splitDataURL("data:image/png,plain"); ok {
		t.Fatal("a non-base64 data URL must be refused")
	}
}

func TestAnthropicUserBlocksCarryImagesAsBase64Source(t *testing.T) {
	blocks := anthropicUserBlocks(openai.ChatCompletionMessage(multimodalUserMessage()))
	if len(blocks) != 2 {
		t.Fatalf("blocks = %#v", blocks)
	}
	text, _ := blocks[0].(map[string]any)
	if text["type"] != "text" || text["text"] != "what is this?" {
		t.Fatalf("text block = %#v", blocks[0])
	}
	image, _ := blocks[1].(map[string]any)
	if image["type"] != "image" {
		t.Fatalf("image block = %#v", blocks[1])
	}
	source, _ := image["source"].(map[string]any)
	if source["type"] != "base64" || source["media_type"] != "image/png" ||
		source["data"] == "" {
		t.Fatalf("source = %#v", source)
	}
	// The OpenAI data URL must NOT survive into the Anthropic source: the
	// API takes media_type and data as separate fields and rejects a URL.
	if strings.Contains(source["data"].(string), "data:") {
		t.Fatalf("data still carries the data URL: %q", source["data"])
	}

	// A text-only message produces no blocks at all: the translator keeps
	// the plain-string content form for it (asserted through the whole
	// message list below).
	if blocks := anthropicUserBlocks(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser, Content: "hello"}); blocks != nil {
		t.Fatalf("text-only blocks = %#v", blocks)
	}
	_, plain := anthropicMessages([]chatMessage{chatMessage(
		openai.ChatCompletionMessage{Role: openai.ChatMessageRoleUser,
			Content: "hello"})}, false)
	if len(plain) != 1 {
		t.Fatalf("plain messages = %#v", plain)
	}
	if entry, _ := plain[0].(map[string]any); entry["content"] != "hello" {
		t.Fatalf("a text-only user message must stay a plain string: %#v", plain[0])
	}
	// The multimodal turn, through the same translator, is a block array.
	_, multi := anthropicMessages([]chatMessage{multimodalUserMessage()}, false)
	if len(multi) != 1 {
		t.Fatalf("multi messages = %#v", multi)
	}
	if entry, _ := multi[0].(map[string]any); entry["content"] == nil {
		t.Fatalf("multimodal content missing: %#v", multi[0])
	}

	// A non-data URL (or an elided marker) must not vanish silently.
	odd := anthropicUserBlocks(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser,
		MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeImageURL,
				ImageURL: &openai.ChatMessageImageURL{URL: "https://example.test/a.png"}},
		}})
	if len(odd) != 1 {
		t.Fatalf("odd blocks = %#v", odd)
	}
	if block, _ := odd[0].(map[string]any); block["type"] != "text" {
		t.Fatalf("an unsupported reference must degrade to a note: %#v", odd[0])
	}
}

func TestCodexUserContentCarriesInputImage(t *testing.T) {
	content := codexUserContent(openai.ChatCompletionMessage(multimodalUserMessage()))
	if len(content) != 2 {
		t.Fatalf("content = %#v", content)
	}
	text, _ := content[0].(map[string]any)
	if text["type"] != "input_text" || text["text"] != "what is this?" {
		t.Fatalf("text item = %#v", content[0])
	}
	image, _ := content[1].(map[string]any)
	if image["type"] != "input_image" || image["image_url"] != testPNGDataURL {
		t.Fatalf("image item = %#v", content[1])
	}

	// A text-only message keeps the single input_text item.
	plain := codexUserContent(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser, Content: "hello"})
	if len(plain) != 1 {
		t.Fatalf("plain content = %#v", plain)
	}
}

func TestFitOutputDoesNotBillImagesAsBase64Text(t *testing.T) {
	// 1x1 PNG data URL is tiny, so scale the point up: an image whose data
	// URL is huge must not consume the output budget the way raw text would.
	huge := strings.Repeat("A", 2_000_000)
	args := chatArgs{Messages: []chatMessage{chatMessage(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser,
		MultiContent: []openai.ChatMessagePart{
			{Type: openai.ChatMessagePartTypeText, Text: "look"},
			{Type: openai.ChatMessagePartTypeImageURL,
				ImageURL: &openai.ChatMessageImageURL{
					URL: "data:image/png;base64," + huge}},
		},
	})}}
	got := fitOutput(8192, 128000, args)
	if got != 8192 {
		t.Fatalf("fitOutput clamped an image turn to %d; the base64 was billed as text", got)
	}
	// Sanity: a genuinely oversized TEXT prompt still clamps.
	textArgs := chatArgs{Messages: []chatMessage{chatMessage(openai.ChatCompletionMessage{
		Role: openai.ChatMessageRoleUser, Content: strings.Repeat("word ", 600_000),
	})}}
	if fitOutput(8192, 128000, textArgs) >= 8192 {
		t.Fatal("a huge text prompt did not clamp the output budget")
	}
}
