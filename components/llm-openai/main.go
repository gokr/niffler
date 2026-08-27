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
	"strconv"
	"strings"
	"time"

	sdk "niffler.dev/sdk"
)

type chatArgs struct {
	Messages []map[string]any `json:"messages"`
	Tools    []map[string]any `json:"tools"`
	Model    string           `json:"model"`
}

// ---------------------------------------------------------------------------
// Model context window
//
// No model database and no runtime fetch — the only window that matters
// is the configured model's, and that belongs in config: NIF_OPENAI_CONTEXT
// wins, then a tiny table for the models this adapter is pointed at by
// default, else a conservative default. The value rides chat responses as
// `context`; core's context guard (docs/MANUAL.md) consumes it.

const defaultContext = 128000 // conservative fallback for unknown models

// knownContext: model id (lowercase) -> context window (tokens).
var knownContext = map[string]int{
	"deepseek-chat":     1000000,
	"deepseek-reasoner": 1000000,
}

// contextWindow returns the context size for a model: NIF_OPENAI_CONTEXT
// env override → built-in table → conservative default.
func contextWindow(model string) int {
	if v := os.Getenv("NIF_OPENAI_CONTEXT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	if c, ok := knownContext[strings.ToLower(model)]; ok {
		return c
	}
	return defaultContext
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
		model = os.Getenv("NIF_OPENAI_MODEL")
	}
	if model == "" {
		model = "deepseek-chat"
	}
	base := os.Getenv("NIF_OPENAI_BASE_URL")
	if base == "" {
		base = "https://api.openai.com/v1"
	}
	key := os.Getenv("NIF_OPENAI_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("NIF_OPENAI_API_KEY not set")
	}

	body := map[string]any{"model": model, "messages": args.Messages}
	if len(args.Tools) > 0 {
		body["tools"] = args.Tools
	}
	// Ask for a generous output budget explicitly. Without it the provider
	// applies its own server-side cap (often 4K–16K), truncating long
	// answers mid-stream so the TUI appears to stop until nudged.
	body["max_tokens"] = 32768
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
		Model string `json:"model"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
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

	// If the server didn't echo the model, fall back to what we requested.
	usedModel := out.Model
	if usedModel == "" {
		usedModel = model
	}
	ctx := contextWindow(usedModel)

	result := map[string]any{"content": msg.Content}
	// Surface which model answered, token usage, and the approximate context
	// window so the UI can show them without any extra round-trip.
	if usedModel != "" {
		result["model"] = usedModel
		result["context"] = ctx
	}
	usage := map[string]any{
		"prompt_tokens":     out.Usage.PromptTokens,
		"completion_tokens": out.Usage.CompletionTokens,
		"total_tokens":      out.Usage.TotalTokens,
	}
	if out.Usage.TotalTokens > 0 || out.Usage.PromptTokens > 0 || out.Usage.CompletionTokens > 0 {
		result["usage"] = usage
	}
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
