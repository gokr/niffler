package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	openai "github.com/sashabaranov/go-openai"
	sdk "niffler.dev/sdk"
)

const claudeCodeVersion = "2.1.75"

var claudeCodeToolNames = map[string]string{
	"read": "Read", "write": "Write", "edit": "Edit", "bash": "Bash",
	"grep": "Grep", "glob": "Glob", "askuserquestion": "AskUserQuestion",
	"enterplanmode": "EnterPlanMode", "exitplanmode": "ExitPlanMode",
	"killshell": "KillShell", "notebookedit": "NotebookEdit", "skill": "Skill",
	"task": "Task", "taskoutput": "TaskOutput", "todowrite": "TodoWrite",
	"webfetch": "WebFetch", "websearch": "WebSearch",
}

type anthropicUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
}

type anthropicEvent struct {
	Type    string `json:"type"`
	Index   int    `json:"index"`
	Message struct {
		ID    string         `json:"id"`
		Model string         `json:"model"`
		Usage anthropicUsage `json:"usage"`
	} `json:"message"`
	ContentBlock struct {
		Type      string         `json:"type"`
		Text      string         `json:"text"`
		Thinking  string         `json:"thinking"`
		Signature string         `json:"signature"`
		ID        string         `json:"id"`
		Name      string         `json:"name"`
		Input     map[string]any `json:"input"`
	} `json:"content_block"`
	Delta struct {
		Type        string `json:"type"`
		Text        string `json:"text"`
		Thinking    string `json:"thinking"`
		PartialJSON string `json:"partial_json"`
		Signature   string `json:"signature"`
		StopReason  string `json:"stop_reason"`
	} `json:"delta"`
	Usage anthropicUsage `json:"usage"`
	Error struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

type anthropicToolCall struct {
	ID        string
	Name      string
	Arguments strings.Builder
}

func chatAnthropic(ctx context.Context, c *sdk.Component, p provider, model, providerName string,
	args chatArgs, contextSize, outputSize int) (any, error) {
	isOAuth := p.AuthType == authOAuth || strings.Contains(p.APIKey, "sk-ant-oat")
	body, err := anthropicRequest(model, args, outputSize, isOAuth)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, anthropicMessagesURL(p.BaseURL),
		strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "text/event-stream")
	request.Header.Set("anthropic-version", "2023-06-01")
	if isOAuth {
		request.Header.Set("Authorization", "Bearer "+p.APIKey)
		betas := []string{"claude-code-20250219", "oauth-2025-04-20"}
		if len(args.Tools) > 0 {
			betas = append(betas, "fine-grained-tool-streaming-2025-05-14")
		}
		if args.ReasoningEffort != "" {
			betas = append(betas, "interleaved-thinking-2025-05-14")
		}
		request.Header.Set("anthropic-beta", strings.Join(betas, ","))
		request.Header.Set("User-Agent", "claude-cli/"+claudeCodeVersion)
		request.Header.Set("x-app", "cli")
		request.Header.Set("anthropic-dangerous-direct-browser-access", "true")
	} else {
		request.Header.Set("x-api-key", p.APIKey)
		request.Header.Set("User-Agent", "niffler/0.4")
		if len(args.Tools) > 0 {
			request.Header.Set("anthropic-beta", "fine-grained-tool-streaming-2025-05-14")
		}
	}

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		return nil, fmt.Errorf("Anthropic HTTP %d: %s", response.StatusCode,
			strings.TrimSpace(string(data)))
	}

	var content, reasoning strings.Builder
	toolCalls := make(map[int]*anthropicToolCall)
	usage := anthropicUsage{}
	usedModel := model
	terminal := false
	err = readAnthropicSSE(response.Body, func(event anthropicEvent) error {
		switch event.Type {
		case "message_start":
			if event.Message.Model != "" {
				usedModel = event.Message.Model
			}
			mergeAnthropicUsage(&usage, event.Message.Usage)
		case "content_block_start":
			switch event.ContentBlock.Type {
			case "text":
				content.WriteString(event.ContentBlock.Text)
				emitLLMToken(c, args, event.ContentBlock.Text, "")
			case "thinking":
				reasoning.WriteString(event.ContentBlock.Thinking)
				emitLLMToken(c, args, "", event.ContentBlock.Thinking)
			case "tool_use":
				call := anthropicCallAt(toolCalls, event.Index)
				call.ID = event.ContentBlock.ID
				call.Name = originalToolName(event.ContentBlock.Name, args.Tools)
				if len(event.ContentBlock.Input) > 0 {
					encoded, _ := json.Marshal(event.ContentBlock.Input)
					call.Arguments.Write(encoded)
				}
			}
		case "content_block_delta":
			switch event.Delta.Type {
			case "text_delta":
				content.WriteString(event.Delta.Text)
				emitLLMToken(c, args, event.Delta.Text, "")
			case "thinking_delta":
				reasoning.WriteString(event.Delta.Thinking)
				emitLLMToken(c, args, "", event.Delta.Thinking)
			case "input_json_delta":
				anthropicCallAt(toolCalls, event.Index).Arguments.WriteString(event.Delta.PartialJSON)
			}
		case "message_delta":
			mergeAnthropicUsage(&usage, event.Usage)
		case "message_stop":
			terminal = true
		case "error":
			if event.Error.Message == "" {
				return errors.New("Anthropic stream error")
			}
			return fmt.Errorf("Anthropic: %s", event.Error.Message)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !terminal {
		return nil, errors.New("Anthropic stream ended before message_stop")
	}

	calls := orderedAnthropicCalls(toolCalls)
	openAIUsage := openai.Usage{
		PromptTokens:     usage.InputTokens + usage.CacheReadInputTokens + usage.CacheCreationInputTokens,
		CompletionTokens: usage.OutputTokens,
	}
	openAIUsage.TotalTokens = openAIUsage.PromptTokens + openAIUsage.CompletionTokens
	usageSeen := openAIUsage.PromptTokens > 0 || openAIUsage.CompletionTokens > 0
	return resultJSON(providerName, usedModel, contextSize, content.String(), reasoning.String(),
		calls, openAIUsage, usageSeen)
}

func anthropicRequest(model string, args chatArgs, outputSize int, isOAuth bool) ([]byte, error) {
	if outputSize <= 0 {
		outputSize = defaultOutput
	}
	system, messages := anthropicMessages(args.Messages, isOAuth)
	request := map[string]any{
		"model": model, "messages": messages, "max_tokens": outputSize, "stream": true,
	}
	if len(system) > 0 {
		request["system"] = system
	}
	if len(args.Tools) > 0 {
		tools := make([]any, 0, len(args.Tools))
		for _, tool := range args.Tools {
			if tool.Function == nil {
				continue
			}
			tools = append(tools, map[string]any{
				"name":                  canonicalClaudeToolName(tool.Function.Name, isOAuth),
				"description":           tool.Function.Description,
				"input_schema":          cleanToolSchema(tool.Function.Parameters),
				"eager_input_streaming": true,
			})
		}
		if len(tools) > 0 {
			request["tools"] = tools
		}
	}
	if args.ReasoningEffort != "" {
		request["thinking"] = map[string]any{"type": "adaptive", "display": "summarized"}
		request["output_config"] = map[string]any{"effort": args.ReasoningEffort}
	}
	return json.Marshal(request)
}

func anthropicMessages(messages []chatMessage, isOAuth bool) ([]any, []any) {
	system := make([]any, 0, 2)
	if isOAuth {
		system = append(system, map[string]any{
			"type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude.",
		})
	}
	result := make([]any, 0, len(messages))
	lastWasTool := false
	for _, raw := range messages {
		message := openai.ChatCompletionMessage(raw)
		switch message.Role {
		case openai.ChatMessageRoleSystem, "developer":
			if message.Content != "" {
				system = append(system, map[string]any{"type": "text", "text": message.Content})
			}
			lastWasTool = false
		case openai.ChatMessageRoleUser:
			text := messageText(message)
			if strings.TrimSpace(text) != "" {
				result = append(result, map[string]any{"role": "user", "content": text})
			}
			lastWasTool = false
		case openai.ChatMessageRoleAssistant:
			blocks := make([]any, 0, len(message.ToolCalls)+1)
			if strings.TrimSpace(message.Content) != "" {
				blocks = append(blocks, map[string]any{"type": "text", "text": message.Content})
			}
			for _, call := range message.ToolCalls {
				var input any = map[string]any{}
				arguments := repairToolArgs(call.Function.Arguments)
				_ = json.Unmarshal([]byte(arguments), &input)
				blocks = append(blocks, map[string]any{
					"type": "tool_use", "id": anthropicToolID(call.ID),
					"name":  canonicalClaudeToolName(call.Function.Name, isOAuth),
					"input": input,
				})
			}
			if len(blocks) > 0 {
				result = append(result, map[string]any{"role": "assistant", "content": blocks})
			}
			lastWasTool = false
		case openai.ChatMessageRoleTool:
			block := map[string]any{
				"type": "tool_result", "tool_use_id": anthropicToolID(message.ToolCallID),
				"content":  message.Content,
				"is_error": strings.HasPrefix(message.Content, "ERROR:"),
			}
			if lastWasTool && len(result) > 0 {
				previous := result[len(result)-1].(map[string]any)
				previous["content"] = append(previous["content"].([]any), block)
			} else {
				result = append(result, map[string]any{"role": "user", "content": []any{block}})
			}
			lastWasTool = true
		}
	}
	return system, result
}

func readAnthropicSSE(reader io.Reader, consume func(anthropicEvent) error) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	var data []string
	flush := func() error {
		if len(data) == 0 {
			return nil
		}
		joined := strings.Join(data, "\n")
		data = data[:0]
		if joined == "[DONE]" || strings.TrimSpace(joined) == "" {
			return nil
		}
		var event anthropicEvent
		if err := json.Unmarshal([]byte(joined), &event); err != nil {
			return fmt.Errorf("decode Anthropic SSE event: %w", err)
		}
		return consume(event)
	}
	for scanner.Scan() {
		line := strings.TrimSuffix(scanner.Text(), "\r")
		if line == "" {
			if err := flush(); err != nil {
				return err
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			data = append(data, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return flush()
}

func mergeAnthropicUsage(current *anthropicUsage, update anthropicUsage) {
	if update.InputTokens > 0 {
		current.InputTokens = update.InputTokens
	}
	if update.OutputTokens > 0 {
		current.OutputTokens = update.OutputTokens
	}
	if update.CacheReadInputTokens > 0 {
		current.CacheReadInputTokens = update.CacheReadInputTokens
	}
	if update.CacheCreationInputTokens > 0 {
		current.CacheCreationInputTokens = update.CacheCreationInputTokens
	}
}

func anthropicCallAt(calls map[int]*anthropicToolCall, index int) *anthropicToolCall {
	call := calls[index]
	if call == nil {
		call = &anthropicToolCall{}
		calls[index] = call
	}
	return call
}

func orderedAnthropicCalls(calls map[int]*anthropicToolCall) []openai.ToolCall {
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
		if call == nil || call.Name == "" {
			continue
		}
		result = append(result, openai.ToolCall{
			ID: call.ID, Type: openai.ToolTypeFunction,
			Function: openai.FunctionCall{
				Name: call.Name, Arguments: repairToolArgs(call.Arguments.String()),
			},
		})
	}
	return result
}

func canonicalClaudeToolName(name string, oauth bool) string {
	if !oauth {
		return name
	}
	if canonical := claudeCodeToolNames[strings.ToLower(name)]; canonical != "" {
		return canonical
	}
	return name
}

func originalToolName(name string, tools []openai.Tool) string {
	for _, tool := range tools {
		if tool.Function != nil && strings.EqualFold(tool.Function.Name, name) {
			return tool.Function.Name
		}
	}
	return name
}

func anthropicToolID(value string) string {
	var result strings.Builder
	for _, char := range value {
		if char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' ||
			char >= '0' && char <= '9' || char == '-' || char == '_' {
			result.WriteRune(char)
		} else {
			result.WriteByte('_')
		}
		if result.Len() >= 64 {
			break
		}
	}
	if result.Len() == 0 {
		return "tool_call"
	}
	return result.String()
}

func anthropicMessagesURL(baseURL string) string {
	base := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if base == "" {
		base = "https://api.anthropic.com"
	}
	if strings.HasSuffix(base, "/v1/messages") {
		return base
	}
	if strings.HasSuffix(base, "/v1") {
		return base + "/messages"
	}
	return base + "/v1/messages"
}
