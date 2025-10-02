"zai-custom": {
  "npm": "@ai-sdk/openai-compatible",
  "options": {
    "baseURL": "https://api.z.ai/api/paas/v4",
    "apiKey": "api-key-here"
  },
  "models": {
    "GLM-4.6": {
      "name": "GLM 4.6",
      "cost": {
        "input": 0,
        "output": 0,
        "cache_read": 0,
        "cache_write": 0
      },
      "limit": {
        "context": 200000,
        "output": 16384
      }
    },
  }
}