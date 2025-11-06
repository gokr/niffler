# Model Configuration Guide

This document describes how to configure AI models in Niffler, including API providers, model definitions, and cost tracking.

## Configuration Location

Model configurations are stored in `~/.niffler/config.yaml`:

```yaml
yourName: "User"
config: "default"
models:
  - nickname: "sonnet"
    base_url: "https://api.anthropic.com/v1"
    api_key_env: "ANTHROPIC_API_KEY"
    model: "claude-sonnet-4-5-20250929"
    context: 200000
    inputCostPerMToken: 3000
    outputCostPerMToken: 15000
```

## Model Fields

### Required Fields

- **`nickname`** (string) - Short name for model selection (e.g., `"sonnet"`, `"gpt4"`, `"haiku"`)
- **`base_url`** (string) - OpenAI-compatible API endpoint
- **`api_key_env`** (string) - Environment variable containing API key
- **`model`** (string) - Full model identifier (e.g., `"claude-sonnet-4-5-20250929"`, `"gpt-4o"`)

### Optional Fields

- **`context`** (integer) - Maximum context window in tokens (default: 128000)
- **`inputCostPerMToken`** (integer) - Cost per million input tokens in USD cents
- **`outputCostPerMToken`** (integer) - Cost per million output tokens in USD cents
- **`maxOutputTokens`** (integer) - Maximum output tokens (model-specific limit)

## Supported Providers

Niffler supports any OpenAI-compatible API endpoint. Common providers:

### Anthropic Claude

```yaml
nickname: "sonnet"
base_url: "https://api.anthropic.com/v1"
api_key_env: "ANTHROPIC_API_KEY"
model: "claude-sonnet-4-5-20250929"
context: 200000
inputCostPerMToken: 3000
outputCostPerMToken: 15000
```

**Available Models:**
- `claude-sonnet-4-5-20250929` - Latest Sonnet (200K context)
- `claude-opus-4-20250514` - Most capable (200K context)
- `claude-3-5-haiku-20241022` - Fastest, most affordable (200K context)

**Environment Variable:**
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### OpenAI

```yaml
nickname: "gpt4o"
base_url: "https://api.openai.com/v1"
api_key_env: "OPENAI_API_KEY"
model: "gpt-4o"
context: 128000
inputCostPerMToken: 250
outputCostPerMToken: 1000
```

**Available Models:**
- `gpt-4o` - Multimodal flagship (128K context)
- `gpt-4o-mini` - Fast and affordable (128K context)
- `o1` - Advanced reasoning model (200K context)

**Environment Variable:**
```bash
export OPENAI_API_KEY="sk-proj-..."
```

### OpenRouter

OpenRouter provides access to multiple model providers through a unified API:

```yaml
{
  "nickname": "deepseek",
  "base_url": "https://openrouter.ai/api/v1",
  "api_key_env": "OPENROUTER_API_KEY",
  "model": "deepseek/deepseek-chat",
  "context": 64000,
  "inputCostPerMToken": 14,
  "outputCostPerMToken": 28
}
```

**Environment Variable:**
```bash
export OPENROUTER_API_KEY="sk-or-..."
```

### Local Models (Ollama, LM Studio, etc.)

For local inference servers using OpenAI-compatible APIs:

```yaml
{
  "nickname": "llama",
  "base_url": "http://localhost:11434/v1",
  "api_key_env": "OLLAMA_API_KEY",
  "model": "llama3.3:70b",
  "context": 128000,
  "inputCostPerMToken": 0,
  "outputCostPerMToken": 0
}
```

**Notes:**
- Set `api_key_env` to any value (local servers typically don't require authentication)
- Set costs to `0` for local inference
- Ensure server is running before using Niffler

### Custom Providers

Any OpenAI-compatible endpoint works. Example for GLM-4.6 via Z.AI:

```yaml
{
  "nickname": "glm",
  "base_url": "https://api.z.ai/api/paas/v4",
  "api_key_env": "ZAI_API_KEY",
  "model": "GLM-4.6",
  "context": 200000,
  "inputCostPerMToken": 0,
  "outputCostPerMToken": 0
}
```

## Cost Tracking

### Pricing Format

Costs are specified in **USD cents per million tokens**:

- Input: $3.00 per million tokens = `3000`
- Output: $15.00 per million tokens = `15000`
- Input: $0.25 per million tokens = `25`

### Cost Calculation

Niffler tracks token usage per API call and calculates session costs:

```
Input Cost = (inputTokens / 1,000,000) * inputCostPerMToken / 100
Output Cost = (outputTokens / 1,000,000) * outputCostPerMToken / 100
Total Cost = Input Cost + Output Cost
```

### Viewing Costs

Session costs are displayed in the status line:

```
↑1.2k ↓450 15% of 200k $0.012
```

Where:
- `↑1.2k` - Input tokens
- `↓450` - Output tokens
- `15% of 200k` - Context usage
- `$0.012` - Session cost

### Database Tracking

All token usage and costs are stored in `~/.niffler/niffler.db`:

```sql
SELECT
  created_at,
  model,
  input_tokens,
  output_tokens,
  total_cost
FROM model_token_usage
ORDER BY created_at DESC
LIMIT 10;
```

## Model Selection

### Default Model

The first model in the `models` array is the default:

```yaml
{
  "models": [
    {"nickname": "sonnet", ...},    // Default
    {"nickname": "haiku", ...},     // Alternative
    {"nickname": "opus", ...}       // Alternative
  ]
}
```

### Switching Models

Use the `/model` command to switch models during a session:

```
/model              # List available models
/model haiku        # Switch to haiku
/model sonnet       # Switch back to sonnet
```

Model switches are conversation-scoped and persisted to the database.

## Multiple Models Configuration

Configure multiple models for different use cases:

```yaml
{
  "models": [
    {
      "nickname": "sonnet",
      "base_url": "https://api.anthropic.com/v1",
      "api_key_env": "ANTHROPIC_API_KEY",
      "model": "claude-sonnet-4-5-20250929",
      "context": 200000,
      "inputCostPerMToken": 3000,
      "outputCostPerMToken": 15000
    },
    {
      "nickname": "haiku",
      "base_url": "https://api.anthropic.com/v1",
      "api_key_env": "ANTHROPIC_API_KEY",
      "model": "claude-3-5-haiku-20241022",
      "context": 200000,
      "inputCostPerMToken": 80,
      "outputCostPerMToken": 400
    },
    {
      "nickname": "opus",
      "base_url": "https://api.anthropic.com/v1",
      "api_key_env": "ANTHROPIC_API_KEY",
      "model": "claude-opus-4-20250514",
      "context": 200000,
      "inputCostPerMToken": 15000,
      "outputCostPerMToken": 75000
    },
    {
      "nickname": "gpt4o",
      "base_url": "https://api.openai.com/v1",
      "api_key_env": "OPENAI_API_KEY",
      "model": "gpt-4o",
      "context": 128000,
      "inputCostPerMToken": 250,
      "outputCostPerMToken": 1000
    },
    {
      "nickname": "local",
      "base_url": "http://localhost:11434/v1",
      "api_key_env": "OLLAMA_API_KEY",
      "model": "llama3.3:70b",
      "context": 128000,
      "inputCostPerMToken": 0,
      "outputCostPerMToken": 0
    }
  ]
}
```

**Usage:**
- Start with `sonnet` (default, balanced performance/cost)
- Switch to `haiku` for simple tasks (fast, cheap)
- Switch to `opus` for complex reasoning (powerful, expensive)
- Switch to `gpt4o` for GPT-specific features
- Switch to `local` for offline work (free, slower)

## Environment Variable Management

### Setting API Keys

Create a `.env` file or add to your shell profile:

```bash
# ~/.bashrc or ~/.zshrc
export ANTHROPIC_API_KEY="sk-ant-api03-..."
export OPENAI_API_KEY="sk-proj-..."
export OPENROUTER_API_KEY="sk-or-..."
```

### Verifying Configuration

Check that Niffler can access your API keys:

```bash
echo $ANTHROPIC_API_KEY
```

If empty, the key is not set or not exported.

### Security Best Practices

1. **Never commit API keys to git** - Use environment variables
2. **Use separate keys** - Create project-specific keys when possible
3. **Rotate keys regularly** - Especially after potential exposure
4. **Use key restrictions** - Enable API key restrictions when supported

## Thinking Tokens Configuration

Some models (Claude, OpenAI o1) support thinking tokens for reasoning. Configure budgets:

```yaml
{
  "nickname": "sonnet",
  "model": "claude-sonnet-4-5-20250929",
  ...other fields...,
  "thinkingBudget": 5000,
  "thinkingCostPerMToken": 3000
}
```

**Fields:**
- `thinkingBudget` - Maximum thinking tokens (default: 5000)
- `thinkingCostPerMToken` - Cost for thinking tokens (usually same as input)

See [THINK.md](THINK.md) for more details on thinking tokens.

## Common Configurations

### Budget-Conscious Setup

Prioritize cost efficiency:

```yaml
{
  "models": [
    {"nickname": "haiku", "model": "claude-3-5-haiku-20241022", ...},
    {"nickname": "local", "base_url": "http://localhost:11434/v1", ...}
  ]
}
```

### Performance-First Setup

Prioritize capability:

```yaml
{
  "models": [
    {"nickname": "opus", "model": "claude-opus-4-20250514", ...},
    {"nickname": "sonnet", "model": "claude-sonnet-4-5-20250929", ...}
  ]
}
```

### Multi-Provider Setup

Use best models from each provider:

```yaml
{
  "models": [
    {"nickname": "sonnet", "model": "claude-sonnet-4-5-20250929", ...},
    {"nickname": "gpt4o", "model": "gpt-4o", ...},
    {"nickname": "deepseek", "base_url": "https://openrouter.ai/api/v1", ...}
  ]
}
```

## Troubleshooting

### API Key Not Found

**Error:** `API key environment variable not set`

**Solution:**
1. Verify environment variable is exported: `echo $ANTHROPIC_API_KEY`
2. Restart your shell after setting variables
3. Check for typos in `api_key_env` field

### Invalid API Endpoint

**Error:** `Failed to connect to API endpoint`

**Solution:**
1. Verify `base_url` is correct (include `/v1` suffix for most providers)
2. Check network connectivity
3. For local models, ensure server is running

### Token Limit Exceeded

**Error:** `Request exceeds context window`

**Solution:**
1. Reduce conversation history (fewer messages)
2. Switch to model with larger context window
3. Use `/clear` to start fresh conversation

### Cost Tracking Not Working

**Issue:** Session cost shows `$0` despite usage

**Solution:**
1. Ensure `inputCostPerMToken` and `outputCostPerMToken` are set
2. Check database: `sqlite3 ~/.niffler/niffler.db "SELECT * FROM model_token_usage"`
3. Costs may be very low - check with more decimal places

## Migration from Other Tools

### From Claude Code

Claude Code uses similar model configuration. Copy your model settings to `~/.niffler/config.yaml`:

```yaml
{
  "models": [
    {
      "nickname": "sonnet",
      "base_url": "https://api.anthropic.com/v1",
      "api_key_env": "ANTHROPIC_API_KEY",
      "model": "claude-sonnet-4-5-20250929",
      "context": 200000,
      "inputCostPerMToken": 3000,
      "outputCostPerMToken": 15000
    }
  ]
}
```

### From aider

Convert aider model format to Niffler format. Aider uses:

```yaml
# .aider.conf.yml
model: claude-sonnet-4
```

Niffler equivalent:

```yaml
{
  "models": [{
    "nickname": "sonnet",
    "model": "claude-sonnet-4-5-20250929",
    ...
  }]
}
```

## See Also

- [CONFIG.md](CONFIG.md) - Configuration system overview
- [THINK.md](THINK.md) - Thinking tokens configuration
- [TASK.md](TASK.md) - Agent system and model selection

