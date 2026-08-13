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
│  │ Proxy-mode containers can only reach allowlisted destinations           ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 2: Container Isolation                                            ││
│  │ Each agent runs in isolated container with limited capabilities          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Layer 3: Secrets Proxy (Rails Controller)                                ││
│  │ Api::SecretsProxyController keeps provider keys outside containers        ││
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
| LLM APIs | Via proxy in proxy mode; direct HTTPS in subscription-auth and direct-outbound modes | Proxy mode prevents key exfiltration; direct modes are explicit exceptions for provider CLIs that require native upstream access |
| File system | Worktree + temp only | No access to host |
| Network | Restricted in proxy mode; provider egress allowed in subscription-auth and direct-outbound modes | Keeps the no-default-internet boundary scoped to runs that can use the secrets proxy |
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
FROM ubuntu:24.04

# Ruby 3.4.8 compiled from source (no pre-built Ruby image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    iptables \
    build-essential \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Compile and install Ruby 3.4.8 from source
RUN curl -fsSL https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.8.tar.gz | tar -xzC /tmp \
    && cd /tmp/ruby-3.4.8 \
    && ./configure --disable-install-doc \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/ruby-3.4.8

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
class Containers::Provision
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
      pids_limit: 500,                  # Process limit

      # Writable areas via tmpfs (13 mounts covering all runtime needs)
      tmpfs: {
        "/tmp" => "size=1G,mode=1777",
        "/home/agent" => "size=512M,mode=0755",
        "/home/agent/.cache" => "size=512M,mode=0755",
        "/home/agent/.local" => "size=256M,mode=0755",
        "/home/agent/.config" => "size=64M,mode=0755",
        "/home/agent/.npm" => "size=256M,mode=0755",
        "/home/agent/.yarn" => "size=256M,mode=0755",
        "/home/agent/.node-gyp" => "size=128M,mode=0755",
        "/home/agent/.gem" => "size=128M,mode=0755",
        "/home/agent/.bundle" => "size=128M,mode=0755",
        "/run" => "size=64M,mode=0755",
        "/var/run" => "size=64M,mode=0755",
        "/workspace/.git" => "size=256M,mode=0755"
      },

      # Workspace volume (only area agent can write to)
      volumes: {
        workspace_volume(project_id) => {
          "bind" => "/workspace",
          "mode" => "rw"
        }
      },

      # Network
      network_mode: "paid_agent",

      # Environment (no secrets!)
      env: {
        "PAID_PROXY_URL" => "http://paid-proxy:3001",
        "PROJECT_ID" => project_id.to_s,
        "HOME" => "/home/agent"
      }
    )

    container.start
    NetworkPolicy.apply(container)
    container
  end
end
```

### Network Isolation

Paid chooses the agent Docker network from the provider auth mode:

| Mode | Docker network | Default internet access | Firewall policy |
|------|----------------|-------------------------|-----------------|
| Proxy mode API-key auth | `paid_agent` | No | Apply in-container iptables allowlist for DNS, secrets proxy, GitHub, and service containers |
| Subscription auth | `paid_internal` | Yes | Do not apply the restrictive firewall because the provider CLI must reach upstream provider APIs directly |
| Direct-outbound provider auth | `paid_internal` | Yes | Do not apply the restrictive firewall because the provider runtime intentionally bypasses Paid's secrets proxy |

Service containers are attached to the same Docker network selected for the agent run so database, Redis, or browser endpoints remain reachable in every mode.

Proxy-mode containers use a dedicated network with strict egress rules:

```ruby
# app/services/network_policy.rb
class NetworkPolicy
  GITHUB_IP_RANGES_URI = "https://api.github.com/meta".freeze
  LOG_PREFIX = "PAID_AGENT_BLOCK".freeze

  def apply(container)
    cidrs = fetch_allowed_cidrs
    rules = build_iptables_rules(cidrs)
    container.exec(["sh", "-c", rules])
  end

  private

  def fetch_allowed_cidrs
    response = Faraday.get(GITHUB_IP_RANGES_URI)
    meta = JSON.parse(response.body)

    cidrs = []
    %w[git ssh_keys web hooks api pages importer actions dependabot].each do |key|
      cidrs.concat(meta["#{key}_#{key == 'git' ? 'ssh' : 'ssh_keys' ? 'keys' : key}"]) if meta.key?("#{key}_#{key}")
    end

    cidrs.concat(meta["ssh_keys"] || [])
    cidrs.concat(meta["web"] || [])
    cidrs.concat(meta["api"] || [])
    cidrs.concat(meta["hooks"] || [])
    cidrs.concat(meta["actions"] || [])
    cidrs.concat(meta["dependabot"] || [])

    cidrs.uniq
  rescue StandardError
    []
  end

  def build_iptables_rules(cidrs)
    <<~IPTABLES
      # Default policy: drop all outbound
      iptables -P OUTPUT DROP

      # Allow loopback
      iptables -A OUTPUT -o lo -j ACCEPT

      # Allow established connections
      iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

      # Allow DNS (for resolution)
      iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

      # Allow secrets proxy (Paid host on Docker network)
      iptables -A OUTPUT -d ${PAID_PROXY_HOST:-172.17.0.1} -p tcp --dport 3001 -j ACCEPT

      # Allow GitHub IPs via CIDR ranges
      #{cidrs.map { |cidr| "iptables -A OUTPUT -d #{cidr} -j ACCEPT" }.join("\n      ")}

      # Log dropped packets
      iptables -A OUTPUT -j LOG --log-prefix "#{LOG_PREFIX}: "
    IPTABLES
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

The secrets proxy is the only component that handles raw API keys. Agents authenticate with cryptographic proxy tokens; the controller validates tokens and adds credentials.

### Proxy Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SECRETS PROXY                                      │
│                                                                              │
│  ┌─────────────┐                    ┌──────────────────────┐                │
│  │   Agent     │ ──── HTTP ────────►│   Proxy              │                │
│  │ (Container) │  Proxy token auth  │  (Api::SecretsProxy  │                │
│  └─────────────┘                    │   Controller)        │                │
│                                     └──────┬───────────────┘                │
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
│  • ContainerAuthentication validates proxy tokens                           │
│  • Proxy logs all requests for auditing                                     │
│  • Proxy enforces rate limits and quotas                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Proxy Implementation

The secrets proxy is implemented as a Rails controller (`Api::SecretsProxyController`) with provider-specific routes:

- `/api/proxy/anthropic/*path` — Anthropic API
- `/api/proxy/openai/*path` — OpenAI API
- `/api/proxy/google/*path` — Google AI API

Authentication uses cryptographic proxy tokens validated by `Api::ContainerAuthentication` (not IP allowlisting). Each agent run receives a unique proxy token; the controller verifies the token before forwarding requests.

```ruby
# app/controllers/api/secrets_proxy_controller.rb
class Api::SecretsProxyController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_container!
  before_action :validate_path!

  PROVIDER_ROUTES = {
    "anthropic" => { host: "api.anthropic.com", key_method: :anthropic },
    "openai" => { host: "api.openai.com", key_method: :openai },
    "google" => { host: "generativelanguage.googleapis.com", key_method: :google }
  }.freeze

  def proxy
    provider_config = PROVIDER_ROUTES[params[:provider]]
    return render json: { error: "Unknown provider" }, status: :forbidden unless provider_config

    api_key = resolve_api_key(provider_config[:key_method])
    return render json: { error: "Provider not configured" }, status: :service_unavailable unless api_key

    response = forward_request(
      host: provider_config[:host],
      path: "/#{params[:path]}",
      method: request.method,
      body: request.body.read,
      api_key: api_key,
      provider: provider_config[:key_method]
    )

    log_request(response)
    render status: response.status, json: JSON.parse(response.body)
  end

  private

  def authenticate_container!
    @agent_run = Api::ContainerAuthentication.authenticate!(request)
  rescue Api::ContainerAuthentication::AuthenticationError
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def validate_path!
    return if params[:path].present?
    render json: { error: "Missing path" }, status: :bad_request
  end

  def resolve_api_key(provider)
    # API key chain: ProviderApiKey → Rails credentials → ENV
    ProviderApiKey.for_provider(provider) ||
      Rails.application.credentials.dig(:llm, "#{provider}_api_key".to_sym) ||
      ENV["#{provider.upcase}_API_KEY"]
  end

  def forward_request(host:, path:, method:, body:, api_key:, provider:)
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

    conn.run_request(method.downcase.to_sym, path, body, auth_header)
  end

  def log_request(response)
    usage = extract_usage(response)
    TokenUsage.create!(
      project_id: @agent_run.project_id,
      provider: params[:provider],
      tokens_input: usage[:input],
      tokens_output: usage[:output],
      cost_cents: calculate_cost(params[:provider], usage)
    )
  end
end
```

### Agent Configuration for Proxy

Agents are configured to use the proxy instead of direct API calls:

```ruby
# In container environment
ENV["ANTHROPIC_BASE_URL"] = "http://paid-proxy:3001/api/proxy/anthropic"
ENV["OPENAI_BASE_URL"] = "http://paid-proxy:3001/api/proxy/openai"

# No provider API keys in environment - the proxy adds them.
# Some CLIs require an API-key-shaped value; Paid uses a run-scoped
# proxy credential such as "paid-run:<id>:<token>", not the provider key.
```

Agent-run provider auth modes have the following runtime secret contract:

| Auth mode | Providers | Runtime material | Notes |
| --- | --- | --- | --- |
| Paid-managed proxy key | Claude, Codex, Gemini, Cursor | Run id, proxy token, provider proxy base URL | Provider key stays on the Rails service and is added by the secrets proxy. |
| Stored provider API key | Claude, Codex, Gemini, Cursor | Run-scoped proxy credential plus provider entry id | Provider key stays server-side; the proxy validates the provider belongs to the run owner before forwarding. |
| Subscription auth | Claude, Codex, Gemini, Copilot | CLI login state mounted or copied into the runtime | Explicit exception: the CLI needs native account session files. |
| Direct-outbound API key | OpenCode, KiloCode | Provider API key in runtime env or config | Explicit exception: these entries can target upstream APIs outside the proxy coverage. |

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

### Token Health Monitoring

```ruby
class GithubToken < ApplicationRecord
  scope :health_check_due, -> {
    where("last_validated_at < ? OR last_validated_at IS NULL", 7.days.ago)
  }
end

class GithubTokenHealthCheckJob < ApplicationJob
  def perform
    GithubToken.health_check_due.find_each do |token|
      GithubTokenValidationJob.perform_later(token)
    end
  end
end

class GithubTokenValidationJob < ApplicationJob
  def perform(github_token)
    client = github_token.client
    client.user
    github_token.update!(last_validated_at: Time.current, status: :active)
  rescue Octokit::Unauthorized
    github_token.update!(status: :invalid)
    UserMailer.token_invalid(github_token.user, github_token).deliver_later
  rescue Octokit::Forbidden
    github_token.update!(status: :expired)
    UserMailer.token_expired(github_token.user, github_token).deliver_later
  end
end
```

---

## Human Review Gate

### No Automatic Merges

Agents can create PRs but cannot merge them:

```ruby
class Activities::CreatePullRequestActivity
  def create(project:, worktree:, issue:, result:)
    client = project.github_token.client

    pr_body = generate_pr_body(result, issue)

    pr = client.create_pull_request(
      "#{project.github_owner}/#{project.github_repo}",
      project.github_default_branch,
      worktree.branch_name,
      "#{issue.title} (fixes ##{issue.github_number})",
      pr_body,
      draft: true
    )

    labels = [
      project.generated_label_name,
      project.automation_label_name
    ].compact
    if labels.any?
      client.add_labels_to_an_issue(
        "#{project.github_owner}/#{project.github_repo}",
        pr.number,
        labels
      )
    end

    client.add_comment(
      "#{project.github_owner}/#{project.github_repo}",
      issue.github_number,
      "PR created: ##{pr.number}"
    )

    pr
  end

  private

  def generate_pr_body(result, issue)
    result.llm_generated_body
  end
end
```

All PRs are created as **drafts**, requiring explicit human action to mark ready for review and merge. Labels are configurable per-project via `project.generated_label_name` and `project.automation_label_name`. PR bodies are generated by the LLM agent, not from a fixed template.

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

General-purpose audit logging does not exist in Paid. The only audit-scoped model is `KnowledgeAuditEvent`, which logs events specific to the knowledge base (document uploads, indexing, etc.):

```ruby
class KnowledgeAuditEvent < ApplicationRecord
  self.table_name = "knowledge_audit_events"

  encrypts :details

  enum event_type: {
    document_uploaded: 0,
    document_indexed: 1,
    document_deleted: 2,
    search_performed: 3,
    index_rebuilt: 4
  }

  def self.log(event_type, actor:, knowledge_base:, details: {})
    create!(
      event_type: event_type,
      actor_type: actor.class.name,
      actor_id: actor.id,
      knowledge_base_id: knowledge_base.id,
      details: details.merge(
        timestamp: Time.current.iso8601
      )
    )
  end
end
```

> **Note**: For broader audit needs (agent runs, PRs, proxy requests, token usage), Paid relies on structured Rails logs and database records in their respective tables — not a centralized audit log table.

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
| Service containers as lateral movement vector | Service containers (database, Redis, browser) share the agent Docker network; a compromised agent could probe these endpoints. Mitigated by network segmentation and service authentication requirements |
| Docker socket exposure (Docker-over-Docker) | If the Docker socket is bind-mounted into a container, the agent gains host-level container management access. Paid never mounts the Docker socket into agent containers |
| Subscription auth credential exposure | Subscription-auth mode mounts CLI login state files from the host into the container runtime, creating a credential exposure surface. Mitigated by scoped filesystem mounts and container isolation |

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
- [ ] Token health monitoring configured
- [ ] Cost limits configured per project
- [ ] Admin account uses strong authentication

### Ongoing

- [ ] Review knowledge audit events weekly
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
