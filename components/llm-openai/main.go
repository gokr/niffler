// llm-openai component — OpenAI-compatible chat completions adapter.
//
// A component like any other: tool "chat" is hidden from the LLM
// (x-harness.hidden) and called by the core conversation loop.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	sdk "niffler.dev/sdk"
)

type chatArgs struct {
	Messages []map[string]any `json:"messages"`
	Tools    []map[string]any `json:"tools"`
	Model    string           `json:"model"`
}

func chatHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	var args chatArgs
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad chat args: %w", err)
	}
	if len(args.Messages) == 0 {
		return nil, fmt.Errorf("messages required")
	}

	model := args.Model
	if model == "" {
		model = os.Getenv("OPENAI_MODEL")
	}
	if model == "" {
		model = "gpt-4o-mini"
	}
	base := os.Getenv("OPENAI_BASE_URL")
	if base == "" {
		base = "https://api.openai.com/v1"
	}
	key := os.Getenv("OPENAI_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("OPENAI_API_KEY not set")
	}

	body := map[string]any{"model": model, "messages": args.Messages}
	if len(args.Tools) > 0 {
		body["tools"] = args.Tools
	}
	reqBody, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)

	client := &http.Client{Timeout: 300 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("llm request: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("llm HTTP %d: %s\nreq: %s", resp.StatusCode,
			tail(string(data), 500), string(reqBody))
	}

	var out struct {
		Choices []struct {
			Message struct {
				Content   *string `json:"content"`
				ToolCalls []struct {
					ID        string `json:"id"`
					Name      string `json:"name"`     // DeepSeek flat variant
					Arguments string `json:"arguments"` // DeepSeek flat variant
					Function  struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	if len(out.Choices) == 0 {
		return nil, fmt.Errorf("no choices in llm response")
	}
	msg := out.Choices[0].Message
	result := map[string]any{"content": msg.Content}
	if len(msg.ToolCalls) > 0 {
		tcs := make([]map[string]any, 0, len(msg.ToolCalls))
		for _, tc := range msg.ToolCalls {
			// Normalize to the OpenAI shape (id + type + function wrapper);
			// DeepSeek may return either nested or flat — pick whichever is set.
			name, arguments := tc.Function.Name, tc.Function.Arguments
			if name == "" {
				name = tc.Name
			}
			if arguments == "" {
				arguments = tc.Arguments
			}
			tcs = append(tcs, map[string]any{
				"id": tc.ID, "type": "function",
				"function": map[string]any{"name": name, "arguments": arguments},
			})
		}
		result["tool_calls"] = tcs
	}
	return result, nil
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}

func main() {
	comp := sdk.New("llm-openai", "0.1.0")
	comp.Tool("chat", map[string]any{
		"type": "object",
		"properties": map[string]any{
			"messages": map[string]any{"type": "array",
				"description": "Chat messages: [{role, content}]"},
			"tools": map[string]any{"type": "array"},
			"model": map[string]any{"type": "string"},
		},
		"required": []string{"messages"},
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 300000},
	}, chatHandler)
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "llm-openai:", err)
		os.Exit(1)
	}
}
