package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	openai "github.com/sashabaranov/go-openai"
	sdk "niffler.dev/sdk"
)

type codexHeaderTransport struct {
	base      http.RoundTripper
	accountID string
	sessionID string
}

func (t codexHeaderTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	clone := request.Clone(request.Context())
	clone.Header = request.Header.Clone()
	clone.Header.Set("chatgpt-account-id", t.accountID)
	clone.Header.Set("OpenAI-Beta", "responses=experimental")
	clone.Header.Set("originator", "niffler")
	clone.Header.Set("User-Agent", "niffler/0.4")
	if t.sessionID != "" {
		clone.Header.Set("session-id", t.sessionID)
		clone.Header.Set("x-client-request-id", t.sessionID)
	}
	return t.base.RoundTrip(clone)
}

func chatCodex(ctx context.Context, c *sdk.Component, p provider, model, providerName string,
	args chatArgs, contextSize int) (any, error) {
	accountID := p.AccountID
	if accountID == "" {
		accountID = codexAccountID(p.APIKey)
	}
	if accountID == "" {
		return nil, errors.New("OpenAI Codex OAuth token has no ChatGPT account id; sign in again")
	}
	baseTransport := http.DefaultTransport
	httpClient := &http.Client{Transport: codexHeaderTransport{
		base: baseTransport, accountID: accountID, sessionID: args.SessionID,
	}}
	cfg := openai.DefaultConfig(p.APIKey)
	cfg.BaseURL = codexBaseURL(p.BaseURL)
	cfg.HTTPClient = httpClient
	client := openai.NewClientWithConfig(cfg)

	request, err := codexRequest(model, args)
	if err != nil {
		return nil, err
	}
	stream, err := client.CreateResponseStream(ctx, request)
	if err != nil {
		return nil, err
	}
	defer stream.Close()

	var content, reasoning strings.Builder
	// Reasoning summaries stream as one delta per step title with no
	// newline between items (the API leaves item separation to the
	// renderer) — track the item index so items land one per line.
	lastSummaryIndex := -1
	calls := make(map[int]*openai.ToolCall)
	usedModel := model
	var usage openai.Usage
	usageSeen := false
	terminal := false

	for {
		event, recvErr := stream.Recv()
		if errors.Is(recvErr, io.EOF) {
			break
		}
		if recvErr != nil {
			return nil, recvErr
		}
		switch string(event.Type) {
		case "response.output_text.delta":
			content.WriteString(event.Delta)
			emitLLMToken(c, args, event.Delta, "")
		case "response.reasoning_summary_text.delta":
			// One summary item (a bolded step title) per delta; separate
			// items with a newline so the transcript doesn't glue the
			// whole run of headings together.
			sep := ""
			if event.SummaryIndex != lastSummaryIndex && reasoning.Len() > 0 &&
				!strings.HasSuffix(reasoning.String(), "\n") {
				sep = "\n"
			}
			lastSummaryIndex = event.SummaryIndex
			reasoning.WriteString(sep + event.Delta)
			emitLLMToken(c, args, "", sep+event.Delta)
		case "response.reasoning_summary_text.done":
			// Item boundary: backends that keep summary_index constant
			// still get their line break here.
			if reasoning.Len() > 0 && !strings.HasSuffix(reasoning.String(), "\n") {
				reasoning.WriteString("\n")
				emitLLMToken(c, args, "", "\n")
			}
		case "response.reasoning_text.delta":
			// Full chain-of-thought deltas are fragments of one continuous
			// text — append verbatim, no separator.
			reasoning.WriteString(event.Delta)
			emitLLMToken(c, args, "", event.Delta)
		case "response.output_item.added", "response.output_item.done":
			if event.Item != nil {
				consumeCodexItem(event.OutputIndex, *event.Item, &content, calls)
			}
		case "response.function_call_arguments.delta":
			call := codexCallAt(calls, event.OutputIndex)
			call.Function.Arguments += event.Delta
		case "response.function_call_arguments.done":
			call := codexCallAt(calls, event.OutputIndex)
			if event.Arguments != "" {
				call.Function.Arguments = event.Arguments
			}
		case "error":
			message := event.Message
			if event.Error != nil && event.Error.Message != "" {
				message = event.Error.Message
			}
			if message == "" {
				message = "unknown Codex stream error"
			}
			return nil, fmt.Errorf("Codex: %s", message)
		case "response.failed":
			if event.Response != nil && event.Response.Error != nil {
				return nil, fmt.Errorf("Codex: %s", event.Response.Error.Message)
			}
			return nil, errors.New("Codex response failed")
		case "response.completed", "response.done", "response.incomplete":
			terminal = true
			if event.Response != nil {
				if event.Response.Model != "" {
					usedModel = event.Response.Model
				}
				if event.Response.Error != nil {
					return nil, fmt.Errorf("Codex: %s", event.Response.Error.Message)
				}
				if event.Response.Usage != nil {
					usage = responseUsage(*event.Response.Usage)
					usageSeen = true
				}
				for index, raw := range event.Response.Output {
					var item openai.ResponseOutputItem
					encoded, marshalErr := json.Marshal(raw)
					if marshalErr == nil && json.Unmarshal(encoded, &item) == nil {
						consumeCodexItem(index, item, &content, calls)
					}
				}
			}
		}
		if terminal {
			break
		}
	}
	if !terminal {
		return nil, errors.New("Codex stream ended without a terminal response")
	}

	toolCalls := orderedCodexCalls(calls)
	return resultJSON(providerName, usedModel, contextSize, content.String(), reasoning.String(),
		toolCalls, usage, usageSeen)
}

func codexRequest(model string, args chatArgs) (openai.CreateResponseRequest, error) {
	instructions, input := codexInput(args.Messages)
	tools := make([]openai.ResponseTool, 0, len(args.Tools))
	for _, tool := range args.Tools {
		if tool.Function == nil {
			continue
		}
		function := *tool.Function
		function.Parameters = cleanToolSchema(function.Parameters)
		// ChatGPT's Codex endpoint currently expects nullable strict rather than
		// OpenAI's nested Chat Completions tool shape. NewResponseFunctionTool
		// emits the inline Responses API representation.
		function.Strict = false
		tools = append(tools, openai.NewResponseFunctionTool(function))
	}
	store := false
	parallel := true
	request := openai.CreateResponseRequest{
		Model:             model,
		Instructions:      instructions,
		Input:             input,
		Tools:             tools,
		ToolChoice:        "auto",
		ParallelToolCalls: &parallel,
		Store:             &store,
		Include:           []openai.ResponseInclude{openai.ResponseIncludeReasoningEncryptedContent},
		Text:              &openai.ResponseTextConfig{Verbosity: "low"},
		PromptCacheKey:    codexCacheKey(args.SessionID),
	}
	if args.ReasoningEffort != "" {
		request.Reasoning = &openai.ResponseReasoning{
			Effort: args.ReasoningEffort, Summary: "auto",
		}
	}
	return request, nil
}

func codexInput(messages []chatMessage) (string, []any) {
	var system []string
	input := make([]any, 0, len(messages))
	for index, raw := range messages {
		message := openai.ChatCompletionMessage(raw)
		switch message.Role {
		case openai.ChatMessageRoleSystem, "developer":
			if message.Content != "" {
				system = append(system, message.Content)
			}
		case openai.ChatMessageRoleUser:
			input = append(input, map[string]any{
				"role": "user", "content": []any{map[string]any{
					"type": "input_text", "text": messageText(message),
				}},
			})
		case openai.ChatMessageRoleAssistant:
			if message.Content != "" {
				input = append(input, map[string]any{
					"type": "message", "id": fmt.Sprintf("msg_niffler_%d", index),
					"role": "assistant", "status": "completed",
					"content": []any{map[string]any{
						"type": "output_text", "text": message.Content,
						"annotations": []any{},
					}},
				})
			}
			for _, toolCall := range message.ToolCalls {
				callID, itemID := splitCodexToolID(toolCall.ID)
				item := map[string]any{
					"type": "function_call", "call_id": callID,
					"name":      toolCall.Function.Name,
					"arguments": repairToolArgs(toolCall.Function.Arguments),
					"status":    "completed",
				}
				if strings.HasPrefix(itemID, "fc_") {
					item["id"] = itemID
				}
				input = append(input, item)
			}
		case openai.ChatMessageRoleTool:
			callID, _ := splitCodexToolID(message.ToolCallID)
			input = append(input, map[string]any{
				"type": "function_call_output", "call_id": callID,
				"output": message.Content,
			})
		}
	}
	return strings.Join(system, "\n\n"), input
}

func consumeCodexItem(index int, item openai.ResponseOutputItem, content *strings.Builder,
	calls map[int]*openai.ToolCall) {
	switch item.Type {
	case "function_call":
		call := codexCallAt(calls, index)
		if item.CallID != "" {
			call.ID = joinCodexToolID(item.CallID, item.ID)
		}
		if item.Name != "" {
			call.Function.Name = item.Name
		}
		if item.Arguments != "" {
			call.Function.Arguments = item.Arguments
		}
	case "message":
		if content.Len() != 0 {
			return
		}
		for _, part := range item.Content {
			if part.Type == "output_text" {
				content.WriteString(part.Text)
			}
		}
	}
}

func codexCallAt(calls map[int]*openai.ToolCall, index int) *openai.ToolCall {
	call := calls[index]
	if call == nil {
		call = &openai.ToolCall{Type: openai.ToolTypeFunction}
		calls[index] = call
	}
	return call
}

func orderedCodexCalls(calls map[int]*openai.ToolCall) []openai.ToolCall {
	if len(calls) == 0 {
		return nil
	}
	maxIndex := 0
	for index := range calls {
		if index > maxIndex {
			maxIndex = index
		}
	}
	result := make([]openai.ToolCall, 0, len(calls))
	for index := 0; index <= maxIndex; index++ {
		call := calls[index]
		if call == nil || call.Function.Name == "" {
			continue
		}
		call.Function.Arguments = repairToolArgs(call.Function.Arguments)
		result = append(result, *call)
	}
	return result
}

func responseUsage(usage openai.ResponseUsage) openai.Usage {
	return openai.Usage{
		PromptTokens:     usage.InputTokens,
		CompletionTokens: usage.OutputTokens,
		TotalTokens:      usage.TotalTokens,
	}
}

func emitLLMToken(c *sdk.Component, args chatArgs, content, reasoning string) {
	if c == nil || !args.Stream || args.SessionID == "" || content == "" && reasoning == "" {
		return
	}
	_ = c.Emit("ev.llm.token", map[string]any{
		"sessionId": args.SessionID, "content": content, "reasoning": reasoning,
	})
}

func codexBaseURL(baseURL string) string {
	base := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if base == "" {
		base = "https://chatgpt.com/backend-api"
	}
	if strings.HasSuffix(base, "/codex/responses") {
		return strings.TrimSuffix(base, "/responses")
	}
	if strings.HasSuffix(base, "/codex") {
		return base
	}
	return base + "/codex"
}

func codexCacheKey(sessionID string) string {
	if sessionID == "" {
		return ""
	}
	var out strings.Builder
	for _, char := range sessionID {
		if char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' ||
			char >= '0' && char <= '9' || char == '-' || char == '_' {
			out.WriteRune(char)
		} else {
			out.WriteByte('-')
		}
		if out.Len() >= 64 {
			break
		}
	}
	return out.String()
}

func splitCodexToolID(value string) (callID, itemID string) {
	parts := strings.SplitN(value, "|", 2)
	callID = parts[0]
	if len(parts) == 2 {
		itemID = parts[1]
	}
	return callID, itemID
}

func joinCodexToolID(callID, itemID string) string {
	if itemID == "" {
		return callID
	}
	return callID + "|" + itemID
}

func codexAccountID(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		AccountID string `json:"chatgpt_account_id"`
		Auth      struct {
			AccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
		Organizations []struct {
			ID string `json:"id"`
		} `json:"organizations"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	if claims.AccountID != "" {
		return claims.AccountID
	}
	if claims.Auth.AccountID != "" {
		return claims.Auth.AccountID
	}
	if len(claims.Organizations) > 0 {
		return claims.Organizations[0].ID
	}
	return ""
}

func messageText(message openai.ChatCompletionMessage) string {
	if message.Content != "" {
		return message.Content
	}
	var text strings.Builder
	for _, part := range message.MultiContent {
		if part.Type == openai.ChatMessagePartTypeText {
			text.WriteString(part.Text)
		}
	}
	return text.String()
}

// cleanToolSchema strips harness-only metadata before a provider validates a
// function schema. It intentionally keeps ordinary JSON Schema extensions.
func cleanToolSchema(value any) any {
	data, err := json.Marshal(value)
	if err != nil {
		return map[string]any{"type": "object", "properties": map[string]any{}}
	}
	var schema map[string]any
	if json.Unmarshal(data, &schema) != nil || schema == nil {
		return map[string]any{"type": "object", "properties": map[string]any{}}
	}
	delete(schema, "description")
	delete(schema, "x-harness")
	delete(schema, "$schema")
	return schema
}
