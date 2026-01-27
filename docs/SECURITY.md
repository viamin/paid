# Paid Security Model

This document describes Paid's security architecture, focusing on container isolation, secrets management, and the principle that **agents should never have direct access to sensitive credentials**.

## Security Principles

### 1. Defense in Depth

Multiple layers of protection ensure that a breach in one layer doesn't compromise the entire system:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SECURITY LAYERS                                     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 1: Network Isolation                                              ││
│  │ Containers can only reach allowlisted domains                           ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 2: Container Isolation                                            ││
│  │ Each agent runs in isolated container with limited capabilities          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 3: Secrets Proxy                                                  ││
│  │ API keys never enter containers; Paid proxies all authenticated calls    ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 4: Human Review Gate                                              ││
│  │ All code changes require human approval before merge                     ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2. Least Privilege

Agents receive only the permissions they need:

| Resource | Agent Access | Rationale |
|----------|--------------|-----------|
| Source code | Read/Write (worktree only) | Needed for implementation |
| GitHub API | Via proxy only | Prevents token exfiltration |
| LLM APIs | Via proxy only | Prevents key exfiltration |
| File system | Worktree + temp only | No access to host |
| Network | Allowlisted domains | Prevents data exfiltration |
| Other containers | None | No lateral movement |

### 3. No Implicit Trust

Agents are treated as potentially compromised:

- Agent output is logged and auditable
- Code changes go through PR review
- Agents cannot self-approve or merge
- Resource usage is monitored and limited

---

## Container Security

### Base Image Hardening

```dockerfile
# Dockerfile.agent
FROM ruby:3.4-slim-bookworm

# Minimal package installation
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    iptables \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Remove unnecessary tools that could aid attacks
RUN rm -rf /usr/bin/wget /usr/bin/nc /usr/bin/ncat

# Non-root user
RUN useradd -m -s /bin/bash -u 1000 agent
USER agent

# No SUID/SGID binaries accessible
WORKDIR /workspace

# Read-only root filesystem (volumes for writable areas)
# Set via docker run: --read-only --tmpfs /tmp
```

### Container Runtime Security

```ruby
class ContainerService
  def provision(project_id)
    container = docker_client.containers.create(
      image: "paid-agent:latest",
      name: "paid-#{project_id}-#{SecureRandom.hex(4)}",

      # Security options
      user: "agent",                    # Non-root
      read_only: true,                  # Read-only root filesystem
      cap_drop: ["ALL"],                # Drop all capabilities
      cap_add: ["NET_RAW"],             # Only for firewall (if needed)
      security_opt: ["no-new-privileges:true"],

      # Resource limits
      memory: 4.gigabytes,
      memory_swap: 4.gigabytes,         # No swap
      cpu_quota: 200_000,               # 2 CPUs max
      pids_limit: 256,                  # Process limit

      # Writable areas via tmpfs
      tmpfs: {
        "/tmp" => "size=1G,mode=1777",
        "/home/agent/.cache" => "size=512M,mode=0755"
      },

      # Workspace volume (only area agent can write to)
      volumes: {
        workspace_volume(project_id) => {
          "bind" => "/workspace",
          "mode" => "rw"
        }
      },

      # Network
      network_mode: "paid-agent-network",

      # Environment (no secrets!)
      env: {
        "PAID_PROXY_URL" => "http://paid-proxy:3001",
        "PROJECT_ID" => project_id.to_s,
        "HOME" => "/home/agent"
      }
    )

    container.start
    apply_firewall_rules(container)
    container
  end
end
```

### Network Isolation

Containers use a dedicated network with strict egress rules:

```ruby
class FirewallService
  ALLOWLIST = [
    # LLM providers (via proxy)
    "paid-proxy",

    # Git operations
    "github.com",
    "api.github.com",

    # Package registries (for agent CLIs)
    "registry.npmjs.org",
    "rubygems.org",

    # Agent-specific endpoints (keep in sync with agent-harness provider firewall_requirements)
    "api.anthropic.com",                 # Claude Code, Aider
    "claude.ai",
    "console.anthropic.com",
    "api.openai.com",                    # Codex, Aider, OpenCode
    "openai.com",
    "api.cursor.sh",                     # Cursor
    "cursor.com",
    "www.cursor.com",
    "downloads.cursor.com",
    "cursor.sh",
    "app.cursor.sh",
    "www.cursor.sh",
    "auth.cursor.sh",
    "auth0.com",
    "generativelanguage.googleapis.com", # Gemini
    "oauth2.googleapis.com",
    "accounts.google.com",
    "www.googleapis.com",
    "api.githubcopilot.com",             # GitHub Copilot
    "copilot-proxy.githubusercontent.com",
    "copilot-completions.githubusercontent.com",
    "copilot-telemetry.githubusercontent.com",
    "default.exp-tas.com"
  ].freeze

  def apply(container)
    rules = <<~IPTABLES
      # Default policy: drop all outbound
      iptables -P OUTPUT DROP

      # Allow loopback
      iptables -A OUTPUT -o lo -j ACCEPT

      # Allow established connections
      iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

      # Allow DNS (for resolution)
      iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

      # Allow specific domains
      #{allowlist_rules}

      # Log dropped packets (for debugging)
      iptables -A OUTPUT -j LOG --log-prefix "PAID_DROPPED: "
    IPTABLES

    container.exec(["sh", "-c", rules])
  end

  private

  def allowlist_rules
    ALLOWLIST.map do |domain|
      "iptables -A OUTPUT -d #{resolve_domain(domain)} -j ACCEPT"
    end.join("\n")
  end

  def resolve_domain(domain)
    # Resolve to IP for iptables
    # In production, use DNS-based rules or maintain IP lists
    Resolv.getaddress(domain)
  rescue Resolv::ResolvError
    domain  # Return as-is if can't resolve
  end
end
```

---

## Secrets Management

### Secret Types

| Secret | Storage | Access |
|--------|---------|--------|
| GitHub PATs | Rails encrypted credentials | Paid only |
| LLM API keys | Rails encrypted credentials | Paid only (proxied to agents) |
| Database credentials | Environment variables | Paid only |
| Temporal credentials | Environment variables | Paid + Workers |

### GitHub Token Storage

```ruby
class GithubToken < ApplicationRecord
  # Encrypted attribute using Rails 8 encryption
  encrypts :token, deterministic: false

  # Validate token on save
  before_save :validate_token_scopes

  def client
    @client ||= Octokit::Client.new(access_token: token)
  end

  private

  def validate_token_scopes
    response = client.user
    # Token is valid if we can fetch user
  rescue Octokit::Unauthorized
    errors.add(:token, "is invalid or expired")
    throw(:abort)
  end
end
```

### LLM API Key Management

```ruby
class LLMCredentials
  # Stored in Rails credentials
  # config/credentials.yml.enc:
  # llm:
  #   anthropic_api_key: sk-...
  #   openai_api_key: sk-...
  #   google_api_key: ...

  def self.for_provider(provider)
    Rails.application.credentials.dig(:llm, "#{provider}_api_key".to_sym)
  end
end
```

---

## Secrets Proxy

The secrets proxy is the only component that handles raw API keys. Agents make unauthenticated requests; the proxy adds credentials.

### Proxy Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SECRETS PROXY                                      │
│                                                                              │
│  ┌─────────────┐                    ┌─────────────┐                         │
│  │   Agent     │ ──── HTTP ────────►│   Proxy     │                         │
│  │ (Container) │   No auth header   │  (Paid)     │                         │
│  └─────────────┘                    └──────┬──────┘                         │
│                                            │                                 │
│                                            │ Add API key                     │
│                                            ▼                                 │
│                                     ┌─────────────┐                         │
│                                     │  LLM API    │                         │
│                                     │  Provider   │                         │
│                                     └─────────────┘                         │
│                                                                              │
│  Security guarantees:                                                       │
│  • Agent never sees API key                                                 │
│  • Proxy validates request format                                           │
│  • Proxy logs all requests for auditing                                     │
│  • Proxy enforces rate limits and quotas                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Proxy Implementation

```ruby
# app/services/secrets_proxy.rb
class SecretsProxy
  PROVIDER_HOSTS = {
    "api.anthropic.com" => :anthropic,
    "api.openai.com" => :openai,
    "generativelanguage.googleapis.com" => :google
  }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)

    # Only handle proxy requests
    return @app.call(env) unless request.path.start_with?("/proxy/")

    # Extract target from path: /proxy/api.anthropic.com/v1/messages
    target_path = request.path.sub("/proxy/", "")
    target_host = target_path.split("/").first
    remaining_path = "/" + target_path.split("/")[1..].join("/")

    provider = PROVIDER_HOSTS[target_host]
    return [403, {}, ["Unknown provider"]] unless provider

    # Verify request comes from container
    return [403, {}, ["Unauthorized"]] unless valid_container_request?(request)

    # Get project context for quota tracking
    project_id = request.get_header("X-Paid-Project-Id")
    return [400, {}, ["Missing project ID"]] unless project_id

    # Check quota
    return [429, {}, ["Quota exceeded"]] if quota_exceeded?(project_id, provider)

    # Forward request with credentials
    response = forward_request(
      provider: provider,
      host: target_host,
      path: remaining_path,
      method: request.request_method,
      body: request.body.read,
      headers: extract_safe_headers(request)
    )

    # Log for auditing and cost tracking
    log_request(project_id, provider, response)

    [response.status, response.headers.to_h, [response.body]]
  end

  private

  def valid_container_request?(request)
    # Verify request comes from container network
    # In production, validate source IP is in container network range
    request.ip.start_with?("172.") || request.ip == "127.0.0.1"
  end

  def quota_exceeded?(project_id, provider)
    budget = CostBudget.find_by(project_id: project_id)
    return false unless budget&.daily_limit_cents

    budget.current_daily_cents >= budget.daily_limit_cents
  end

  def forward_request(provider:, host:, path:, method:, body:, headers:)
    api_key = LLMCredentials.for_provider(provider)

    conn = Faraday.new(url: "https://#{host}") do |f|
      f.request :json
      f.response :json
    end

    auth_header = case provider
    when :anthropic
      { "x-api-key" => api_key, "anthropic-version" => "2024-01-01" }
    when :openai
      { "Authorization" => "Bearer #{api_key}" }
    when :google
      { "x-goog-api-key" => api_key }
    end

    conn.run_request(method.downcase.to_sym, path, body, headers.merge(auth_header))
  end

  def extract_safe_headers(request)
    # Only forward safe headers
    safe_headers = %w[Content-Type Accept]
    safe_headers.each_with_object({}) do |header, hash|
      value = request.get_header("HTTP_#{header.upcase.tr('-', '_')}")
      hash[header] = value if value
    end
  end

  def log_request(project_id, provider, response)
    # Extract token usage from response
    usage = extract_usage(provider, response)

    TokenUsage.create!(
      project_id: project_id,
      provider: provider,
      tokens_input: usage[:input],
      tokens_output: usage[:output],
      cost_cents: calculate_cost(provider, usage)
    )
  end
end
```

### Agent Configuration for Proxy

Agents are configured to use the proxy instead of direct API calls:

```ruby
# In container environment
ENV["ANTHROPIC_BASE_URL"] = "http://paid-proxy:3001/proxy/api.anthropic.com"
ENV["OPENAI_BASE_URL"] = "http://paid-proxy:3001/proxy/api.openai.com"

# No API keys in environment - the proxy adds them
# ENV["ANTHROPIC_API_KEY"] is NOT set
```

---

## GitHub Integration Security

### Token Scope Guidance

The UI guides users to create minimal-scope tokens:

```ruby
class GithubTokenSetupService
  REQUIRED_SCOPES = {
    basic: {
      "repo" => "Full control of private repositories",
      "read:org" => "Read org membership (for org repos)"
    },
    with_projects: {
      "project" => "Full control of projects"
    }
  }.freeze

  def required_scopes(include_projects: true)
    scopes = REQUIRED_SCOPES[:basic].dup
    scopes.merge!(REQUIRED_SCOPES[:with_projects]) if include_projects
    scopes
  end

  def validate_scopes(token)
    client = Octokit::Client.new(access_token: token)
    response = client.get("/user")

    # Check X-OAuth-Scopes header
    granted_scopes = response.headers["x-oauth-scopes"]&.split(", ") || []
    required = required_scopes.keys

    missing = required - granted_scopes
    { valid: missing.empty?, missing: missing, granted: granted_scopes }
  end
end
```

### Token Rotation Reminders

```ruby
class GithubToken < ApplicationRecord
  # Remind users to rotate tokens periodically
  scope :rotation_due, -> {
    where("created_at < ?", 90.days.ago)
      .where(rotation_reminder_sent_at: nil)
  }
end

class TokenRotationReminderJob < ApplicationJob
  def perform
    GithubToken.rotation_due.find_each do |token|
      UserMailer.token_rotation_reminder(token.user, token).deliver_later
      token.update!(rotation_reminder_sent_at: Time.current)
    end
  end
end
```

---

## Human Review Gate

### No Automatic Merges

Agents can create PRs but cannot merge them:

```ruby
class PullRequestService
  def create(project:, worktree:, issue:, result:)
    client = project.github_token.client

    # Create PR
    pr = client.create_pull_request(
      "#{project.github_owner}/#{project.github_repo}",
      project.github_default_branch,
      worktree.branch_name,
      "#{issue.title} (fixes ##{issue.github_number})",
      generate_pr_body(result, issue)
    )

    # Add label indicating AI-generated
    client.add_labels_to_an_issue(
      "#{project.github_owner}/#{project.github_repo}",
      pr.number,
      ["ai-generated", "needs-review"]
    )

    # Link to issue
    client.add_comment(
      "#{project.github_owner}/#{project.github_repo}",
      issue.github_number,
      "PR created: ##{pr.number}"
    )

    pr

    # NOTE: We deliberately do NOT merge the PR
    # Human review is required
  end

  private

  def generate_pr_body(result, issue)
    <<~BODY
      ## Summary
      This PR was generated by Paid to address ##{issue.github_number}.

      ## Changes
      #{result.summary}

      ## Agent Details
      - Agent: #{result.agent_type}
      - Model: #{result.model}
      - Iterations: #{result.iterations}

      ---
      ⚠️ **This PR was AI-generated and requires human review before merging.**
    BODY
  end
end
```

### PR Review Checklist

Generated PRs include a review checklist:

```markdown
## Review Checklist

- [ ] Code logic is correct
- [ ] Tests are adequate
- [ ] No security vulnerabilities introduced
- [ ] Follows project conventions
- [ ] No unnecessary changes
- [ ] Documentation updated if needed
```

---

## Audit Logging

### What's Logged

| Event | Data Logged | Retention |
|-------|-------------|-----------|
| Token created | User, scopes (not token) | Indefinite |
| Agent run started | Project, issue, model | 1 year |
| Agent run completed | Duration, tokens, outcome | 1 year |
| PR created | Project, PR number, issue | Indefinite |
| Proxy request | Project, provider, tokens, cost | 1 year |
| User login | User, IP, timestamp | 90 days |

### Audit Log Implementation

```ruby
class AuditLog < ApplicationRecord
  # Separate table for compliance
  self.table_name = "audit_logs"

  encrypts :details  # Encrypt sensitive details

  enum event_type: {
    token_created: 0,
    token_rotated: 1,
    agent_run_started: 10,
    agent_run_completed: 11,
    pr_created: 20,
    proxy_request: 30,
    user_login: 40,
    permission_change: 50
  }

  def self.log(event_type, actor:, resource:, details: {})
    create!(
      event_type: event_type,
      actor_type: actor.class.name,
      actor_id: actor.id,
      resource_type: resource.class.name,
      resource_id: resource.id,
      details: details.merge(
        ip_address: Current.ip_address,
        user_agent: Current.user_agent,
        timestamp: Time.current.iso8601
      )
    )
  end
end
```

---

## Threat Model

### Threats and Mitigations

| Threat | Mitigation |
|--------|------------|
| Agent exfiltrates secrets | Secrets never in container; proxy adds them |
| Agent exfiltrates code | Network allowlist blocks unauthorized egress |
| Agent installs backdoor | Human review required before merge |
| Malicious PR merged | Separate from agent - human responsibility |
| Container escape | Hardened containers, dropped capabilities |
| Token stolen from DB | Encrypted at rest, access logged |
| Proxy compromised | Defense in depth; tokens still encrypted |
| Infinite loop burns money | Guardrails: iteration, token, cost limits |

### What Paid Does NOT Protect Against

- **Subtle malicious code**: AI-generated code could be subtly wrong; human review is critical
- **Compromised GitHub tokens**: If user's token is stolen outside Paid, we can't prevent misuse
- **Social engineering**: If attacker can convince human reviewer to merge bad code
- **Paid application compromise**: If Paid itself is compromised, secrets are at risk

---

## Security Checklist for Deployment

### Before Going Live

- [ ] All secrets in encrypted Rails credentials
- [ ] Database encrypted at rest
- [ ] HTTPS enforced everywhere
- [ ] Container images scanned for vulnerabilities
- [ ] Firewall rules tested
- [ ] Proxy authentication verified
- [ ] Audit logging enabled
- [ ] Token rotation reminders configured
- [ ] Cost limits configured per project
- [ ] Admin account uses strong authentication

### Ongoing

- [ ] Review audit logs weekly
- [ ] Update container base images monthly
- [ ] Rotate Paid's own API keys quarterly
- [ ] Review token scopes on rotation
- [ ] Monitor for unusual patterns
- [ ] Penetration test annually

---

## Incident Response

### If Agent Container Compromised

1. Immediately terminate container
2. Revoke any tokens that may have been exposed (none should be)
3. Review audit logs for unusual activity
4. Check if agent created any unexpected commits
5. Review open PRs from that agent run

### If Proxy Compromised

1. Rotate all LLM API keys immediately
2. Review proxy logs for unauthorized requests
3. Check for unusual cost spikes
4. Notify affected users

### If Database Compromised

1. Rotate all GitHub tokens (notify users)
2. Rotate database credentials
3. Review access logs
4. Check for data exfiltration
5. Notify users per breach disclosure requirements
