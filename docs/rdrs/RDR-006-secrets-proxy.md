# RDR-006: Secrets Proxy Architecture

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Proxy unit tests, integration tests for API key injection

## Problem Statement

AI agents in Paid need to make authenticated API calls to LLM providers (Anthropic, OpenAI, Google, etc.). However, giving agents direct access to API keys creates security risks:

1. **Exfiltration**: Agent could send API keys to unauthorized destinations
2. **Persistence**: Keys stored in container could survive cleanup
3. **Logging**: Keys might appear in agent logs or output
4. **Manipulation**: Adversarial prompts could trick agents into revealing keys

Requirements:
- Agents must be able to call LLM APIs
- Agents must never see or handle API keys
- All API usage must be logged for cost tracking
- Per-project quotas must be enforceable
- Support multiple LLM providers

## Context

### Background

Traditional approach: Set API keys as environment variables in agent containers. This is insecure because:
- Keys visible via `/proc/*/environ`
- Keys could be logged by agent CLI tools
- Keys could be exfiltrated via allowed network destinations

Paid's approach: Agents make unauthenticated requests to a proxy; the proxy adds authentication headers before forwarding to providers.

### Technical Environment

- Agents run in isolated Docker containers
- Containers have network egress filtering (see RDR-004)
- API keys stored encrypted in Rails credentials
- Multiple LLM providers supported via ruby-llm

## Research Findings

### Investigation Process

1. Analyzed LLM provider API authentication mechanisms
2. Evaluated proxy implementation options
3. Designed request routing and header injection
4. Developed cost tracking integration
5. Tested with Claude Code and other agent CLIs

### Key Discoveries

**Provider Authentication Methods:**

| Provider | Auth Header | Header Name | Format |
|----------|-------------|-------------|--------|
| Anthropic | API Key | `x-api-key` | `sk-ant-...` |
| OpenAI | Bearer | `Authorization` | `Bearer sk-...` |
| Google | API Key | `x-goog-api-key` | `AIza...` |
| Mistral | Bearer | `Authorization` | `Bearer ...` |

**Agent CLI Configuration:**

Most LLM agent CLIs support base URL configuration:

```bash
# Claude Code
export ANTHROPIC_BASE_URL="http://proxy:3001/v1"

# Cursor / OpenAI-compatible
export OPENAI_BASE_URL="http://proxy:3001/openai/v1"

# Direct API calls
curl http://proxy:3001/v1/messages \
  -H "Content-Type: application/json" \
  -H "X-Paid-Project-Id: 123" \
  -d '{"model": "claude-3-5-sonnet", "messages": [...]}'
```

**Proxy Request Flow:**

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Agent     │         │   Proxy     │         │  Provider   │
│ (Container) │         │   (Paid)    │         │   API       │
└──────┬──────┘         └──────┬──────┘         └──────┬──────┘
       │                       │                       │
       │  POST /v1/messages    │                       │
       │  X-Paid-Project-Id: 1 │                       │
       │  (no API key)         │                       │
       │──────────────────────►│                       │
       │                       │                       │
       │                       │  Validate request     │
       │                       │  Look up API key      │
       │                       │  Check quota          │
       │                       │                       │
       │                       │  POST /v1/messages    │
       │                       │  x-api-key: sk-...   │
       │                       │──────────────────────►│
       │                       │                       │
       │                       │◄──────────────────────│
       │                       │  200 OK + usage       │
       │                       │                       │
       │                       │  Log usage, update    │
       │                       │  cost tracking        │
       │                       │                       │
       │◄──────────────────────│                       │
       │  200 OK + usage       │                       │
       │                       │                       │
```

**Rate Limiting Considerations:**

Provider rate limits apply to the API key, not the proxy. The proxy must:
1. Handle 429 responses gracefully
2. Optionally implement internal rate limiting per project
3. Log rate limit events for visibility

**Cost Calculation:**

Token-based cost calculation from response:

```ruby
# Anthropic response
{
  "usage": {
    "input_tokens": 1024,
    "output_tokens": 256
  }
}

# Calculate cost (example rates)
input_cost = 1024 / 1000.0 * 0.003   # $0.003 per 1K input
output_cost = 256 / 1000.0 * 0.015   # $0.015 per 1K output
total_cents = ((input_cost + output_cost) * 100).round
```

## Proposed Solution

### Approach

Implement a **Rack middleware proxy** running as part of Paid infrastructure that:

1. Receives unauthenticated requests from containers
2. Validates request source (container network only)
3. Extracts project context from headers
4. Looks up appropriate API key
5. Checks project quota
6. Injects authentication headers
7. Forwards to provider
8. Logs usage for cost tracking
9. Returns response to agent

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SECRETS PROXY ARCHITECTURE                            │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         PAID INFRASTRUCTURE                              ││
│  │                                                                          ││
│  │  ┌───────────────────────────────────────────────────────────────────┐  ││
│  │  │                      SECRETS PROXY                                 │  ││
│  │  │                                                                    │  ││
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │  ││
│  │  │  │  Request    │  │  Auth       │  │  Provider   │               │  ││
│  │  │  │  Validator  │─►│  Injector   │─►│  Router     │               │  ││
│  │  │  │             │  │             │  │             │               │  ││
│  │  │  │ • Source IP │  │ • Key lookup│  │ • Anthropic │               │  ││
│  │  │  │ • Project   │  │ • Header    │  │ • OpenAI    │               │  ││
│  │  │  │ • Quota     │  │   injection │  │ • Google    │               │  ││
│  │  │  └─────────────┘  └─────────────┘  └──────┬──────┘               │  ││
│  │  │                                           │                       │  ││
│  │  │                    ┌──────────────────────┘                       │  ││
│  │  │                    ▼                                              │  ││
│  │  │  ┌─────────────────────────────────────────────────────────────┐ │  ││
│  │  │  │                   USAGE LOGGER                               │ │  ││
│  │  │  │                                                              │ │  ││
│  │  │  │  • Extract token counts from response                        │ │  ││
│  │  │  │  • Calculate cost based on model pricing                     │ │  ││
│  │  │  │  • Insert into token_usages table                           │ │  ││
│  │  │  │  • Update project cost counters                              │ │  ││
│  │  │  └─────────────────────────────────────────────────────────────┘ │  ││
│  │  │                                                                    │  ││
│  │  └───────────────────────────────────────────────────────────────────┘  ││
│  │                                                                          ││
│  │  API Keys (encrypted):                                                  ││
│  │  Rails.application.credentials.llm.anthropic_api_key                    ││
│  │  Rails.application.credentials.llm.openai_api_key                       ││
│  │  Rails.application.credentials.llm.google_api_key                       ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    ▲                                         │
│                                    │                                         │
│         ───────────────────────────┼─────────────────────────────           │
│         │          CONTAINER NETWORK (172.28.0.0/16)            │           │
│         ───────────────────────────┼─────────────────────────────           │
│                                    │                                         │
│  ┌─────────────────────────────────┴───────────────────────────────────────┐│
│  │                         AGENT CONTAINERS                                 ││
│  │                                                                          ││
│  │  ANTHROPIC_BASE_URL=http://paid-proxy:3001/anthropic                    ││
│  │  OPENAI_BASE_URL=http://paid-proxy:3001/openai                          ││
│  │  (NO API KEYS!)                                                         ││
│  │                                                                          ││
│  └──────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Zero key exposure**: Keys never enter containers
2. **Centralized logging**: All API usage tracked in one place
3. **Quota enforcement**: Proxy can block over-budget requests
4. **Auditability**: Full request/response logging possible
5. **Flexibility**: New providers added by configuration

### Implementation Example

```ruby
# lib/secrets_proxy.rb
class SecretsProxy
  PROVIDERS = {
    "anthropic" => {
      host: "api.anthropic.com",
      auth_type: :api_key,
      auth_header: "x-api-key",
      extra_headers: { "anthropic-version" => "2024-01-01" }
    },
    "openai" => {
      host: "api.openai.com",
      auth_type: :bearer,
      auth_header: "Authorization"
    },
    "google" => {
      host: "generativelanguage.googleapis.com",
      auth_type: :api_key,
      auth_header: "x-goog-api-key"
    }
  }.freeze

  def initialize(app = nil)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)

    # Only handle proxy paths
    return @app.call(env) if @app && !proxy_request?(request)

    # Validate source
    return forbidden("Invalid source") unless valid_source?(request)

    # Parse request
    provider, path = extract_provider_path(request.path)
    return not_found("Unknown provider") unless provider

    # Get project context
    project_id = request.get_header("HTTP_X_PAID_PROJECT_ID")
    return bad_request("Missing project ID") unless project_id

    # Check quota
    if quota_exceeded?(project_id)
      return too_many_requests("Quota exceeded")
    end

    # Forward request with auth
    response = forward_request(
      provider: provider,
      path: path,
      method: request.request_method,
      body: request.body.read,
      headers: safe_headers(request),
      project_id: project_id
    )

    # Log usage
    log_usage(project_id, provider, response) if response.success?

    [response.status, response_headers(response), [response.body]]
  end

  private

  def proxy_request?(request)
    PROVIDERS.keys.any? { |p| request.path.start_with?("/#{p}") }
  end

  def valid_source?(request)
    # Only allow requests from container network
    ip = request.ip
    ip.start_with?("172.28.") || ip == "127.0.0.1"
  end

  def extract_provider_path(path)
    match = path.match(%r{^/(\w+)(/.*)?$})
    return nil unless match && PROVIDERS[match[1]]
    [match[1], match[2] || "/"]
  end

  def quota_exceeded?(project_id)
    budget = CostBudget.find_by(project_id: project_id)
    return false unless budget&.daily_limit_cents
    budget.current_daily_cents >= budget.daily_limit_cents
  end

  def forward_request(provider:, path:, method:, body:, headers:, project_id:)
    config = PROVIDERS[provider]
    api_key = fetch_api_key(provider)

    conn = Faraday.new(url: "https://#{config[:host]}") do |f|
      f.options.timeout = 300  # 5 minute timeout for long requests
      f.options.open_timeout = 10
    end

    auth_headers = case config[:auth_type]
    when :api_key
      { config[:auth_header] => api_key }
    when :bearer
      { config[:auth_header] => "Bearer #{api_key}" }
    end

    all_headers = headers
      .merge(auth_headers)
      .merge(config[:extra_headers] || {})

    conn.run_request(method.downcase.to_sym, path, body, all_headers)
  end

  def fetch_api_key(provider)
    key = Rails.application.credentials.dig(:llm, "#{provider}_api_key".to_sym)
    raise "Missing API key for #{provider}" unless key
    key
  end

  def safe_headers(request)
    # Only forward safe headers
    %w[Content-Type Accept].each_with_object({}) do |header, h|
      value = request.get_header("HTTP_#{header.upcase.tr('-', '_')}")
      h[header] = value if value
    end
  end

  def response_headers(response)
    # Filter response headers
    allowed = %w[content-type x-request-id]
    response.headers.to_h.slice(*allowed)
  end

  def log_usage(project_id, provider, response)
    usage = extract_usage(provider, response)
    return unless usage

    model_id = extract_model(response)
    cost_cents = calculate_cost(provider, model_id, usage)

    TokenUsage.create!(
      project_id: project_id,
      provider: provider,
      model_id: model_id,
      tokens_input: usage[:input],
      tokens_output: usage[:output],
      cost_cents: cost_cents,
      request_type: "agent_run"
    )

    # Update project counters
    update_budget_counters(project_id, cost_cents)
  end

  def extract_usage(provider, response)
    body = JSON.parse(response.body) rescue nil
    return nil unless body

    case provider
    when "anthropic"
      usage = body["usage"]
      { input: usage["input_tokens"], output: usage["output_tokens"] } if usage
    when "openai"
      usage = body["usage"]
      { input: usage["prompt_tokens"], output: usage["completion_tokens"] } if usage
    when "google"
      usage = body.dig("usageMetadata")
      { input: usage["promptTokenCount"], output: usage["candidatesTokenCount"] } if usage
    end
  end

  def extract_model(response)
    body = JSON.parse(response.body) rescue nil
    body&.dig("model")
  end

  def calculate_cost(provider, model_id, usage)
    # Look up pricing from models table or use defaults
    model = Model.find_by(provider: provider, model_id: model_id)
    return 0 unless model

    input_cost = (usage[:input] / 1000.0) * model.input_cost_per_1k
    output_cost = (usage[:output] / 1000.0) * model.output_cost_per_1k
    ((input_cost + output_cost) * 100).round  # Convert to cents
  end

  def update_budget_counters(project_id, cost_cents)
    CostBudget.where(project_id: project_id).update_all(
      "current_daily_cents = current_daily_cents + #{cost_cents},
       current_monthly_cents = current_monthly_cents + #{cost_cents}"
    )
  end

  def forbidden(message)
    [403, { "Content-Type" => "application/json" }, [{ error: message }.to_json]]
  end

  def not_found(message)
    [404, { "Content-Type" => "application/json" }, [{ error: message }.to_json]]
  end

  def bad_request(message)
    [400, { "Content-Type" => "application/json" }, [{ error: message }.to_json]]
  end

  def too_many_requests(message)
    [429, { "Content-Type" => "application/json" }, [{ error: message }.to_json]]
  end
end

# config.ru or config/initializers/proxy.rb
# Run as separate Rack app or mount in Rails
```

## Alternatives Considered

### Alternative 1: Environment Variables in Containers

**Description**: Pass API keys as environment variables to containers

**Pros**:
- Simple implementation
- Standard approach
- No proxy complexity

**Cons**:
- Keys visible in container environment
- Keys could be logged or exfiltrated
- No centralized quota enforcement
- Harder to rotate keys

**Reason for rejection**: Fundamental security risk. Agents could extract and exfiltrate keys via any allowed network destination.

### Alternative 2: Vault/Secret Manager Integration

**Description**: Use HashiCorp Vault or cloud secret managers, with containers fetching keys at runtime

**Pros**:
- Industry-standard secret management
- Key rotation support
- Audit logging

**Cons**:
- Still gives keys to containers
- Additional infrastructure
- Doesn't prevent exfiltration once key is fetched

**Reason for rejection**: Solves key management but not the core problem—containers still get raw keys.

### Alternative 3: mTLS with Per-Request Auth

**Description**: Use mutual TLS with certificates that encode project context

**Pros**:
- Strong authentication
- No API keys in requests

**Cons**:
- Certificate management complexity
- Providers don't support mTLS auth
- Would still need a proxy for translation

**Reason for rejection**: LLM providers use API keys, not mTLS. Would still need proxy for translation.

### Alternative 4: Sidecar Proxy

**Description**: Run proxy as sidecar container in same pod

**Pros**:
- Isolated per-container
- Kubernetes-native pattern

**Cons**:
- More complex deployment
- Requires orchestration (K8s)
- Resource overhead per container

**Reason for rejection**: Overkill for current deployment model. Single shared proxy is simpler and sufficient.

## Trade-offs and Consequences

### Positive Consequences

- **Zero key exposure**: API keys never enter agent containers
- **Centralized logging**: All usage tracked in one place
- **Quota enforcement**: Prevent runaway costs
- **Easy key rotation**: Update once in Rails credentials
- **Provider flexibility**: Add new providers via configuration

### Negative Consequences

- **Single point of failure**: Proxy downtime blocks all agents
- **Latency overhead**: Additional network hop
- **Complexity**: Another service to maintain
- **Throughput limits**: Proxy must handle all API traffic

### Risks and Mitigations

- **Risk**: Proxy becomes bottleneck
  **Mitigation**: Proxy is stateless, can run multiple instances behind load balancer.

- **Risk**: Proxy downtime blocks agents
  **Mitigation**: Health checks, automatic restarts, monitoring. Consider multiple proxy instances.

- **Risk**: Cost tracking database writes slow down requests
  **Mitigation**: Async logging via queue if needed. Initial sync writes are likely fine.

## Implementation Plan

### Prerequisites

- [ ] Rails credentials configured with API keys
- [ ] Docker network allows proxy access
- [ ] Models table populated with pricing data

### Step-by-Step Implementation

#### Step 1: Configure Rails Credentials

```bash
rails credentials:edit
```

```yaml
llm:
  anthropic_api_key: sk-ant-...
  openai_api_key: sk-...
  google_api_key: AIza...
```

#### Step 2: Create Proxy Service

Create `lib/secrets_proxy.rb` as shown in implementation example.

#### Step 3: Mount Proxy in Rails

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # ... other routes

  # Mount proxy for container requests
  mount SecretsProxy.new => "/proxy", constraints: lambda { |request|
    request.ip.start_with?("172.28.") || Rails.env.development?
  }
end
```

Or run as separate Rack app:

```ruby
# proxy/config.ru
require_relative "../config/environment"
run SecretsProxy.new
```

#### Step 4: Configure Container Environment

```ruby
# In ContainerService
env: {
  "ANTHROPIC_BASE_URL" => "http://paid-proxy:3001/anthropic",
  "OPENAI_BASE_URL" => "http://paid-proxy:3001/openai",
  "X_PAID_PROJECT_ID" => project_id.to_s
  # Note: NO API keys!
}
```

#### Step 5: Add Proxy to Docker Compose

```yaml
services:
  paid-proxy:
    build: .
    command: bundle exec rackup proxy/config.ru -p 3001 -o 0.0.0.0
    environment:
      - RAILS_MASTER_KEY=${RAILS_MASTER_KEY}
    networks:
      - paid-agent-network
      - default
```

### Files to Modify

- `config/credentials.yml.enc` - API keys
- `lib/secrets_proxy.rb` - Proxy implementation
- `config/routes.rb` or `proxy/config.ru` - Mount proxy
- `docker-compose.yml` - Proxy service
- `app/services/container_service.rb` - Container environment

### Dependencies

- `faraday` gem for HTTP client
- `rack` for request/response handling

## Validation

### Testing Approach

1. Unit tests for proxy routing and auth injection
2. Integration tests for end-to-end API calls
3. Security tests for source validation
4. Load tests for throughput

### Test Scenarios

1. **Scenario**: Agent makes API call via proxy
   **Expected Result**: Request forwarded with auth, response returned, usage logged

2. **Scenario**: Request from unauthorized source
   **Expected Result**: 403 Forbidden

3. **Scenario**: Request without project ID
   **Expected Result**: 400 Bad Request

4. **Scenario**: Project over quota
   **Expected Result**: 429 Too Many Requests

5. **Scenario**: API key extracted from container environment
   **Expected Result**: Environment variable not present (key never entered container)

### Performance Validation

- Proxy latency < 10ms overhead
- Throughput: 100 requests/second sustained
- No connection pooling exhaustion under load

### Security Validation

- Source IP validation working
- No API keys in proxy logs
- Keys not accessible from container

## References

### Requirements & Standards

- Paid SECURITY.md - Security model
- [OWASP API Security](https://owasp.org/www-project-api-security/)

### Dependencies

- [Faraday](https://github.com/lostisland/faraday) - HTTP client
- [Rack](https://github.com/rack/rack) - Web server interface

### Research Resources

- LLM provider API documentation (Anthropic, OpenAI, Google)
- API gateway patterns
- Zero-trust networking

## Notes

- Consider adding request signing for additional security
- May want to cache model pricing to reduce database lookups
- Future: Add streaming response support for real-time output
- Consider prometheus metrics for proxy performance monitoring
