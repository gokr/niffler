# Advanced Configuration Guide

This guide covers advanced configuration patterns for production deployments, multi-environment setups, and complex use cases in Niffler.

## Multi-Environment Configuration

### Directory Structure

Organize configurations by environment:

```
~/.niffler/
├── config.yaml                     # Main config (can override per-env)
├── environments/                   # Environment-specific configs
│   ├── development/
│   │   ├── config.yaml
│   │   ├── NIFFLER.md
│   │   └── agents/
│   ├── staging/
│   │   ├── config.yaml
│   │   ├── NIFFLER.md
│   │   └── agents/
│   └── production/
│       ├── config.yaml
│       ├── NIFFLER.md
│       └── agents/
└── shared/                         # Shared resources
    ├── prompts/
    └── tools/
```

### Environment-Specific Configs

#### Development Environment (`environments/development/config.yaml`)

```yaml
yourName: "Developer"
environment: "development"
debug: true

# Fast, local models for development
models:
  - name: "gpt-3.5-turbo"
    nickname: "fast"
    baseURL: "http://localhost:8080/v1"
    apiKey: "${FAST_API_KEY}"

# Local services
nats:
  url: "nats://127.0.0.1:4222"
  timeout: 5000

database:
  host: "127.0.0.1"
  port: 4000
  user: "root"
  password: ""

# Development-specific settings
logging:
  level: "debug"
  console: true
  file: false

masterMode:
  enabled: true
  timeout: 10000
  retryAttempts: 1
```

#### Production Environment (`environments/production/config.yaml`)

```yaml
yourName: "Production Assistant"
environment: "production"
debug: false

# Production-grade models
models:
  - name: "gpt-4-turbo"
    nickname: "primary"
    baseURL: "https://api.openai.com/v1"
    apiKey: "${OPENAI_API_KEY}"
  - name: "claude-3-opus-20240229"
    nickname: "claude"
    baseURL: "https://api.anthropic.com"
    apiKey: "${ANTHROPIC_API_KEY}"

# HA NATS cluster
nats:
  url: "nats://nats-cluster.example.com:4222"
  username: "${NATS_USER}"
  password: "${NATS_PASS}"
  timeout: 30000
  maxReconnects: 10
  reconnectWait: 2000
  tls:
    enabled: true
    ca_file: "/etc/ssl/certs/nats-ca.pem"
    cert_file: "/etc/ssl/certs/nats-client.pem"
    key_file: "/etc/ssl/private/nats-client.key"

# Production database
database:
  host: "tidb-cluster.example.com"
  port: 4000
  user: "niffler"
  password: "${DB_PASSWORD}"
  database: "niffler_prod"
  ssl: true
  maxConnections: 50
  connectionTimeout: 10000

# Production logging
logging:
  level: "info"
  console: false
  file: true
  file_path: "/var/log/niffler/app.log"
  rotate: true
  max_size: "100MB"
  max_files: 10

# Monitoring
monitoring:
  prometheus:
    enabled: true
    port: 9090
  health_check:
    enabled: true
    port: 8080

masterMode:
  enabled: true
  timeout: 60000
  retryAttempts: 3
  autoStart: true
  healthCheckInterval: 10000
```

### Environment Switching

#### Using Environment Variables

```bash
# Set environment
export NIFFLER_ENV="production"

# Niffler will load: ~/.niffler/environments/${NIFFLER_ENV}/config.yaml
niffler
```

#### Using CLI Flag

```bash
# Explicitly specify environment
niffler --env staging

# Override config path
niffler --config ~/.niffler/environments/staging/config.yaml
```

## Dynamic Model Configuration

### Model Selection by Context

Configure models to be selected based on conversation context:

```yaml
models:
  # Default model
  - name: "gpt-4"
    nickname: "default"
    primary: true
    cost_per_token: 0.00003

  # Fast model for simple tasks
  - name: "gpt-3.5-turbo"
    nickname: "fast"
    cost_per_token: 0.000002

  # Code-specific model
  - name: "gpt-4"
    nickname: "coder"
    primary: false
    config: "cc"
    system_prompt_override: "coder"

  # Analysis model
  - name: "claude-3-opus-20240229"
    nickname: "analyst"
    primary: false
    system_prompt_override: "analyst"

# Dynamic model selection
modelSelection:
  # Cost-conscious mode
  cost_mode:
    enabled: true
    daily_limit: 10.00  # $10 per day
    fallback_model: "fast"

  # Context-based selection
  contextual:
    patterns:
      - model: "coder"
        keywords: ["bug", "implement", "refactor", "debug"]
        file_types: ["*.nim", "*.py", "*.js", "*.ts"]
      - model: "analyst"
        keywords: ["analyze", "review", "explain", "research"]
        min_token_count: 1000
      - model: "fast"
        keywords: ["quick", "simple", "basic"]
        max_token_count: 500

  # Time-based selection
  temporal:
    - model: "fast"
      hours: ["09:00-17:00"]  # Business hours
      days: ["mon-fri"]
    - model: "default"
      hours: ["17:00-09:00"]  # After hours
      days: ["sat", "sun"]
```

### Model Failover and Load Balancing

```yaml
# Multiple API endpoints for the same model
models:
  - name: "gpt-4"
    nickname: "gpt4-ha"
    endpoints:
      - baseURL: "https://api.openai.com/v1"
        apiKey: "${OPENAI_API_KEY}"
        weight: 70
        region: "us-east-1"
      - baseURL: "https://api.openai-proxy-1.com/v1"
        apiKey: "${PROXY_API_KEY_1}"
        weight: 20
        region: "eu-west-1"
      - baseURL: "https://api.openai-proxy-2.com/v1"
        apiKey: "${PROXY_API_KEY_2}"
        weight: 10
        region: "ap-southeast-1"

    # Failover configuration
    failover:
      strategy: "circuit_breaker"  # round_robin, weighted, circuit_breaker
      timeout: 30000
      retry_attempts: 3
      circuit_breaker:
        failure_threshold: 5
        recovery_timeout: 60000
        half_open_max_calls: 3
```

## Custom Agent Definitions

### Specialized Agent Types

#### Code Review Agent (`agents/code-review.md`)

```markdown
# Code Review Agent

## Purpose
Specialized agent for code review, analysis, and quality assessment.

## Capabilities
- Security vulnerability detection
- Performance optimization suggestions
- Code style and best practices review
- Architecture assessment
- Test coverage analysis

## Model Configuration
```yaml
model: "claude-3-opus-20240229"
config: "cc"
temperature: 0.1
max_tokens: 4000
```

## System Prompt
```markdown
You are an expert code reviewer with expertise in:
- Security best practices
- Performance optimization
- Code maintainability
- Testing strategies

Focus on:
1. Security vulnerabilities
2. Performance bottlenecks
3. Code clarity and maintainability
4. Test coverage recommendations

Provide specific, actionable feedback with examples.
```

## Tool Access
- read: For examining code
- bash: For running analysis tools
- fetch: For retrieving documentation
```

#### Documentation Agent (`agents/documentation.md`)

```markdown
# Documentation Agent

## Purpose
Specialized agent for generating, updating, and maintaining technical documentation.

## Capabilities
- API documentation generation
- User guide creation
- Code comment extraction and enhancement
- Documentation migration between formats

## Model Configuration
```yaml
model: "gpt-4-turbo"
config: "default"
temperature: 0.3
max_tokens: 8000
```

## Templates
Standard templates for different documentation types are stored in:
- `~/.niffler/templates/api-doc.md`
- `~/.niffler/templates/user-guide.md`
- `~/.niffler/templates/README.md`

## Tool Access
- read: Source code analysis
- write: Documentation generation
- edit: Section updates
- fetch: External reference lookup
```

### Agent Skill Matching

Configure agent skills and automatic routing:

```yaml
# Agent registry
agents:
  - name: "security-auditor"
    type: "code-review"
    skills:
      primary: ["security", "vulnerability", "audit"]
      secondary: ["performance", "compliance"]
    expertise_level: "expert"
    model: "claude-3-opus-20240229"
    config: "cc"

  - name: "performance-optimizer"
    type: "optimization"
    skills:
      primary: ["performance", "optimization", "profiling"]
      secondary: ["architecture", "scalability"]
    expertise_level: "senior"
    model: "gpt-4-turbo"

  - name: "documentation-writer"
    type: "documentation"
    skills:
      primary: ["documentation", "writing", "communication"]
      secondary: ["technical-writing", "api-docs"]
    expertise_level: "senior"
    model: "gpt-4"

# Skill-based routing
skillRouting:
  # Priority-based selection
  priority_weights:
    skill_match: 0.6        # Primary skill matching
    expertise_level: 0.2    # Agent expertise
    availability: 0.2       # Agent availability

  # Load balancing
  load_balancing:
    strategy: "least_loaded"  # round_robin, least_loaded, weighted
    max_queue_size: 10
```

## Configuration Templates

### Parameterized Configs

Use template variables for reusable configurations:

```yaml
# Template: ~/.niffler/templates/team-config.yaml
template:
  name: "team-config"
  version: "1.0"

variables:
  team_name: "{{TEAM_NAME}}"
  shared_dir: "{{SHARED_DIR}}"

models:
  - name: "{{PRIMARY_MODEL}}"
    nickname: "primary"
    apiKey: "{{PRIMARY_API_KEY}}"

nats:
  url: "{{NATS_URL}}"
  username: "{{NATS_USER}}"
  password: "{{NATS_PASS}}"

# Instance configuration
instances:
  team_alpha:
    variables:
      TEAM_NAME: "alpha"
      SHARED_DIR: "/shared/alpha"
      PRIMARY_MODEL: "gpt-4-turbo"
      NATS_URL: "nats://nats-alpha.example.com:4222"

  team_beta:
    variables:
      TEAM_NAME: "beta"
      SHARED_DIR: "/shared/beta"
      PRIMARY_MODEL: "claude-3-opus-20240229"
      NATS_URL: "nats://nats-beta.example.com:4222"
```

### Configuration Composition

```yaml
# Base configuration
base: "production.yaml"

# Override specific sections
overrides:
  models:
    - name: "custom-model"
      nickname: "specialized"
      baseURL: "${CUSTOM_API_URL}"

  nats:
    cluster_name: "specialized-cluster"

# Add additional sections
extensions:
  custom_tools:
    - name: "security-scanner"
      path: "/opt/tools/security-scanner"
    - name: "code-metrics"
      path: "/opt/tools/code-metrics"
```

## Performance Optimization

### Caching Configuration

```yaml
# Response caching
caching:
  enabled: true

  # Cache strategies
  response_cache:
    ttl: 3600              # 1 hour
    max_size: "1GB"
    strategy: "lru"        # lru, lfu, fifo

  # Model-specific caching
  model_cache:
    gpt-4:
      ttl: 7200           # 2 hours
      max_entries: 1000
    gpt-3.5-turbo:
      ttl: 1800           # 30 minutes
      max_entries: 5000

  # Tool result caching
  tool_cache:
    file_read:
      ttl: 300            # 5 minutes
      enabled: true
    bash_commands:
      ttl: 60             # 1 minute
      enabled: false      # Don't cache by default
    web_fetch:
      ttl: 1800           # 30 minutes
      max_size: "500MB"
```

### Connection Pooling

```yaml
# API connection pools
api_pools:
  openai:
    max_connections: 50
    min_connections: 5
    connection_timeout: 30000
    idle_timeout: 300000
    max_lifetime: 3600000

  anthropic:
    max_connections: 20
    min_connections: 2
    connection_timeout: 45000
    retry_delay: 1000

# Database connection pool
database:
  pool:
    max_connections: 100
    min_connections: 10
    acquire_timeout: 10000
    create_timeout: 30000
    destroy_timeout: 5000
    idle_timeout: 60000
    validate_interval: 30000
```

### Request Rate Limiting

```yaml
# Rate limiting per model
rate_limiting:
  enabled: true

  # Global limits
  global:
    requests_per_minute: 1000
    tokens_per_minute: 100000

  # Model-specific limits
  models:
    gpt-4:
      requests_per_minute: 60
      tokens_per_minute: 40000
      burst: 10

    claude-3-opus-20240229:
      requests_per_minute: 50
      tokens_per_minute: 30000
      burst: 5

  # User-based limits
  users:
    default:
      requests_per_hour: 100
      tokens_per_hour: 10000

    premium:
      requests_per_hour: 1000
      tokens_per_hour: 100000
```

## Security Configuration

### API Key Management

```yaml
# Secure API key handling
security:
  # Key rotation
  key_rotation:
    enabled: true
    rotation_interval: 2592000    # 30 days
    warning_days: 7
    auto_rotate: false            # Manual by default

  # Key validation
  validation:
    check_expired: true
    check_permissions: true
    validate_on_startup: true

# Encrypted key storage
encrypted_keys:
  provider: "vault"  # vault, aws_secrets, gcp_secrets
  vault:
    address: "https://vault.example.com:8200"
    path: "secret/niffler"
    auth_method: "token"
    token: "${VAULT_TOKEN}"
```

### Network Security

```yaml
# Allowed endpoints
network:
  # Whitelist API endpoints
  allowed_endpoints:
    - pattern: "https://api.openai.com/*"
      methods: ["POST"]
    - pattern: "https://api.anthropic.com/*"
      methods: ["POST"]
    - pattern: "https://localhost:*/*"
      methods: ["GET", "POST"]

  # Blocked endpoints
  blocked_endpoints:
    - "file:///*"
    - "ftp://*"
    - "telnet://*"

  # TLS configuration
  tls:
    min_version: "1.2"
    cipher_suites:
      - "TLS_AES_256_GCM_SHA384"
      - "TLS_AES_128_GCM_SHA256"

  # Request headers
  security_headers:
    user_agent: "Niffler/1.0 (+https://github.com/your-org/niffler)"
    x_request_id: true
```

### Access Control

```yaml
# Role-based access control
rbac:
  enabled: true

  roles:
    admin:
      models: "*"
      tools: "*"
      agents: ["*"]
      max_tokens_per_day: -1  # Unlimited

    developer:
      models: ["gpt-4", "gpt-3.5-turbo"]
      tools: ["read", "write", "edit", "bash"]
      agents: ["general-purpose", "coder"]
      max_tokens_per_day: 50000

    analyst:
      models: ["gpt-4-turbo", "claude-3-opus"]
      tools: ["read", "fetch"]
      agents: ["general-purpose", "analyst"]
      max_tokens_per_day: 100000

  # User assignments
  users:
    alice@example.com:
      role: "admin"
      teams: ["engineering", "security"]

    bob@example.com:
      role: "developer"
      teams: ["engineering"]

    carol@example.com:
      role: "analyst"
      teams: ["data-science"]
```

## Monitoring and Observability

### Metrics Configuration

```yaml
# Prometheus metrics
metrics:
  enabled: true
  port: 9090
  path: "/metrics"

  # Custom metrics
  custom:
    - name: "niffler_requests_total"
      type: "counter"
      labels: ["model", "user", "status"]

    - name: "niffler_response_time_seconds"
      type: "histogram"
      buckets: [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]

    - name: "niffler_tokens_used"
      type: "counter"
      labels: ["model", "type"]  # type: input/output

    - name: "niffler_active_agents"
      type: "gauge"

# Distributed tracing
tracing:
  enabled: true
  provider: "jaeger"  # jaeger, zipkin, datadog

  jaeger:
    endpoint: "http://jaeger:14268/api/traces"
    service_name: "niffler"
    sample_rate: 0.1
```

### Logging Configuration

```yaml
# Structured logging
logging:
  level: "info"
  format: "json"

  outputs:
    console:
      enabled: true
      format: "text"

    file:
      enabled: true
      path: "/var/log/niffler/app.log"
      rotate: true
      max_size: "100MB"
      max_files: 10

    elasticsearch:
      enabled: false
      hosts: ["http://elasticsearch:9200"]
      index: "niffler-logs"

  # Log filtering
  filters:
    - name: "token_usage"
      condition: "tokens > 1000"
      level: "warn"

    - name: "slow_requests"
      condition: "duration > 5s"
      level: "info"

    - name: "errors"
      condition: "status >= 400"
      level: "error"
```

### Health Checks

```yaml
# Health check endpoints
health:
  enabled: true
  port: 8080
  path: "/health"

  # Check components
  checks:
    database:
      enabled: true
      timeout: 5000
      query: "SELECT 1"

    nats:
      enabled: true
      timeout: 3000
      subject: "health.check"

    api_endpoints:
      enabled: true
      timeout: 10000
      endpoints:
        - "https://api.openai.com/v1/models"
        - "https://api.anthropic.com/v1/messages"

    disk_space:
      enabled: true
      threshold: 90  # %
      paths: ["/var/log", "/tmp"]

    memory:
      enabled: true
      threshold: 80  # %
```

## Multi-Region Configuration

### Geographic Distribution

```yaml
# Region-specific configuration
regions:
  us_east_1:
    models:
      - name: "gpt-4"
        endpoint: "https://api.openai.com/v1"
        latency_priority: 1

    nats:
      servers: ["nats-us-east-1.example.com:4222"]

    database:
      primary: true
      host: "tidb-us-east-1.example.com"

  eu_west_1:
    models:
      - name: "gpt-4"
        endpoint: "https://api.openai.com/v1"
        latency_priority: 2

    nats:
      servers: ["nats-eu-west-1.example.com:4222"]

    database:
      primary: false
      host: "tidb-eu-west-1.example.com"
      read_only: true

# Cross-region replication
replication:
  async: true
  lag_threshold: 5000  # ms
  conflict_resolution: "last_write_wins"
```

### CDN Configuration

```yaml
# Content delivery for static resources
cdn:
  enabled: true
  provider: "cloudflare"  # cloudflare, aws_cloudfront, fastly

  cloudflare:
    zone_id: "${CLOUDFLARE_ZONE}"
    api_token: "${CLOUDFLARE_TOKEN}"

  # Cached content
  cache:
    ttl:
      static_content: 86400      # 24 hours
      api_responses: 300         # 5 minutes
      model_metadata: 3600       # 1 hour

    # Cache invalidation
    invalidation:
      on_update: true
      on_delete: true
      custom_patterns: ["*/config/*", "*/agents/*"]
```

## Configuration Validation

### Schema Validation

```yaml
# Configuration schema
schema:
  version: "1.0"

  required_fields:
    - "models"
    - "database"

  field_validation:
    models:
      type: "array"
      min_items: 1
      items:
        type: "object"
        required: ["name", "baseURL"]

    database:
      type: "object"
      required: ["host", "port", "user", "database"]
      properties:
        port:
          type: "integer"
          minimum: 1
          maximum: 65535

  # Custom validators
  validators:
    - field: "models.baseURL"
      type: "url"
      schemes: ["https", "http"]

    - field: "nats.url"
      type: "url"
      schemes: ["nats", "tls"]

    - field: "database.password"
      type: "password_strength"
      min_length: 12
      require_special: true
```

### Configuration Testing

```yaml
# Test configuration before applying
testing:
  enabled: true

  # Test suites
  suites:
    connectivity:
      - test: "database_connection"
        timeout: 5000

      - test: "nats_connection"
        timeout: 3000

      - test: "api_endpoints"
        endpoints: ["https://api.openai.com/v1/models"]

    functionality:
      - test: "agent_startup"
        agents: ["general-purpose", "coder"]

      - test: "tool_execution"
        tools: ["read", "bash"]

    performance:
      - test: "response_time"
        threshold: 2000  # ms

      - test: "concurrent_users"
        count: 10
        ramp_up: 30  # seconds
```

## Best Practices

1. **Environment Separation**: Always use separate configurations for dev/staging/prod
2. **Secrets Management**: Never store secrets in config files, use environment variables or secret stores
3. **Version Control**: Commit configuration templates, but not secrets or environment-specific values
4. **Validation**: Validate configurations before applying them
5. **Monitoring**: Monitor configuration changes and their impact
6. **Documentation**: Document custom configuration patterns for team knowledge sharing

For basic configuration options, see [CONFIG.md](CONFIG.md).