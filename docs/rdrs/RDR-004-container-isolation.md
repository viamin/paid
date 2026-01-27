# RDR-004: Container Isolation Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Container security tests, integration tests for agent execution

## Problem Statement

Paid executes AI agents (Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, Kilocode) that generate and execute code. These agents:

1. Need access to source code repositories
2. Make API calls to LLM providers
3. Run arbitrary code during development/testing phases
4. Should not have access to Paid's secrets or other projects' data
5. Must be isolated from each other to prevent interference

Security requirements:

- Agents must not access API keys directly
- Agents must not access other projects' code
- Agents must not exfiltrate data to unauthorized destinations
- Compromised agents must not be able to attack Paid infrastructure
- Multiple agents must work in parallel without conflicts

## Context

### Background

Paid is inspired by [aidp](https://github.com/viamin/aidp), which uses devcontainers for agent isolation. The key insight is that AI agents are powerful but potentially dangerous—they can write and execute arbitrary code.

The threat model assumes agents could be:

- Manipulated by adversarial prompts
- Exploited via vulnerabilities in generated code
- Tricked into exfiltrating data

### Technical Environment

- Host: Linux server with Docker
- Agents: Claude Code, Cursor, Gemini CLI, GitHub Copilot, Codex, Aider, OpenCode, Kilocode
- Network: Must reach LLM APIs and GitHub
- Storage: Need persistent project clones, ephemeral worktrees

## Research Findings

### Investigation Process

1. Analyzed aidp's devcontainer approach
2. Reviewed Docker security best practices
3. Evaluated container runtime security options (gVisor, Kata)
4. Tested network isolation with iptables
5. Designed secrets proxy pattern for API access

### Key Discoveries

**Docker Security Features:**

1. **Capability Dropping**: Remove unnecessary Linux capabilities

   ```ruby
   container = docker.containers.create(
     cap_drop: ["ALL"],
     cap_add: ["NET_RAW"]  # Only if needed for networking
   )
   ```

2. **Read-Only Root Filesystem**: Prevent modifications to system files

   ```ruby
   container = docker.containers.create(
     read_only: true,
     tmpfs: {
       "/tmp" => "size=1G,mode=1777",
       "/home/agent/.cache" => "size=512M"
     }
   )
   ```

3. **Resource Limits**: Prevent resource exhaustion

   ```ruby
   container = docker.containers.create(
     memory: 4.gigabytes,
     memory_swap: 4.gigabytes,  # No swap
     cpu_quota: 200_000,        # 2 CPUs
     pids_limit: 256
   )
   ```

4. **User Namespaces**: Run as non-root

   ```dockerfile
   FROM ruby:3.4-slim
   RUN useradd -m -u 1000 agent
   USER agent
   ```

5. **Network Isolation**: Dedicated network with egress filtering

   ```bash
   # Create isolated network
   docker network create --internal paid-agent-network

   # Allow only specific egress via firewall rules
   ```

**Network Allowlisting:**

Containers need to reach specific services:

- LLM APIs (via secrets proxy)
- GitHub (for git operations)
- Package registries (npm, RubyGems)

Approach: Default-deny outbound with explicit allowlist.

```bash
# Inside container (setup-firewall.sh)
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT  # DNS
iptables -A OUTPUT -d paid-proxy -j ACCEPT       # Secrets proxy
iptables -A OUTPUT -d github.com -j ACCEPT       # Git
iptables -A OUTPUT -d api.github.com -j ACCEPT   # GitHub API
```

**Secrets Proxy Pattern:**

Agents must not have direct access to API keys. Instead:

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Agent     │ ──────► │   Secrets   │ ──────► │  LLM API    │
│ (Container) │  HTTP   │   Proxy     │  HTTPS  │  Provider   │
│             │  (no    │   (Paid)    │  (with  │             │
│ No API keys │  auth)  │ Adds keys   │  auth)  │             │
└─────────────┘         └─────────────┘         └─────────────┘
```

The proxy:

1. Runs as part of Paid infrastructure (not in container)
2. Receives requests without auth headers
3. Looks up API key based on project context
4. Forwards request with proper authentication
5. Logs usage for cost tracking

**Container Image Strategy:**

Base image with all agent CLIs pre-installed:

```dockerfile
FROM ruby:3.4-slim-bookworm

# Minimal packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates iptables \
    && rm -rf /var/lib/apt/lists/*

# Remove tools that aid attacks
RUN rm -f /usr/bin/wget /usr/bin/nc /usr/bin/ncat

# Install agent CLIs
RUN npm install -g @anthropic/claude-code cursor-cli
RUN pip install openai-codex-cli
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && gh extension install github/gh-copilot

# Non-root user
RUN useradd -m -s /bin/bash -u 1000 agent
USER agent

WORKDIR /workspace
```

## Proposed Solution

### Approach

Use **Docker containers** with defense-in-depth:

1. **Hardened base image**: Minimal packages, non-root user
2. **Capability dropping**: Remove all unnecessary Linux capabilities
3. **Resource limits**: Prevent resource exhaustion attacks
4. **Network isolation**: Default-deny egress with allowlist
5. **Secrets proxy**: API keys never enter containers
6. **Read-only filesystem**: Except for designated writable areas

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CONTAINER SECURITY ARCHITECTURE                         │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         PAID INFRASTRUCTURE                              ││
│  │                                                                          ││
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                 ││
│  │  │ Rails App     │ │ Secrets Proxy │ │ Temporal      │                 ││
│  │  │               │ │               │ │ Workers       │                 ││
│  │  │ (API keys in  │ │ (Adds auth    │ │ (Container    │                 ││
│  │  │  credentials) │ │  to requests) │ │  management)  │                 ││
│  │  └───────────────┘ └───────────────┘ └───────────────┘                 ││
│  │                              │                                          ││
│  └──────────────────────────────┼──────────────────────────────────────────┘│
│                                 │                                            │
│         ────────────────────────┼────────────────────────────────           │
│         │      SECURITY BOUNDARY (paid-agent-network)           │           │
│         ────────────────────────┼────────────────────────────────           │
│                                 │                                            │
│  ┌──────────────────────────────┼──────────────────────────────────────────┐│
│  │                    AGENT CONTAINERS                                      ││
│  │                                                                          ││
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         ││
│  │  │ Container 1     │  │ Container 2     │  │ Container N     │         ││
│  │  │ (Project A)     │  │ (Project B)     │  │ (Project A)     │         ││
│  │  │                 │  │                 │  │                 │         ││
│  │  │ • No API keys   │  │ • No API keys   │  │ • No API keys   │         ││
│  │  │ • Read-only FS  │  │ • Read-only FS  │  │ • Read-only FS  │         ││
│  │  │ • Non-root      │  │ • Non-root      │  │ • Non-root      │         ││
│  │  │ • Caps dropped  │  │ • Caps dropped  │  │ • Caps dropped  │         ││
│  │  │ • Network filter│  │ • Network filter│  │ • Network filter│         ││
│  │  │                 │  │                 │  │                 │         ││
│  │  │ ┌─────────────┐ │  │ ┌─────────────┐ │  │ ┌─────────────┐ │         ││
│  │  │ │ /workspace  │ │  │ │ /workspace  │ │  │ │ /workspace  │ │         ││
│  │  │ │ (volume)    │ │  │ │ (volume)    │ │  │ │ (volume)    │ │         ││
│  │  │ └─────────────┘ │  │ └─────────────┘ │  │ └─────────────┘ │         ││
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘         ││
│  │                                                                          ││
│  └──────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  Network Rules:                                                             │
│  ✓ Container → Secrets Proxy (paid-proxy)                                   │
│  ✓ Container → github.com, api.github.com                                   │
│  ✓ Container → Package registries (npm, RubyGems)                           │
│  ✗ Container → Container (isolated)                                         │
│  ✗ Container → Internet (blocked)                                           │
│  ✗ Container → Paid infrastructure (except proxy)                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Docker**: Industry standard, well-understood security model
2. **Defense-in-depth**: Multiple layers prevent single-point failures
3. **Secrets proxy**: Eliminates credential exposure entirely
4. **Network filtering**: Limits exfiltration vectors
5. **aidp-proven**: Pattern validated in production by aidp

### Implementation Example

```ruby
# app/services/container_service.rb
class ContainerService
  include Servo::Service

  input do
    attribute :project_id, Dry::Types["strict.integer"]
    attribute :agent_type, Dry::Types["strict.string"]
  end

  output do
    attribute :container_id, Dry::Types["strict.string"]
    attribute :status, Dry::Types["strict.string"]
  end

  def call
    container = create_container
    apply_firewall_rules(container)
    container.start

    success(container_id: container.id, status: "running")
  rescue Docker::Error::Error => e
    failure(error: e.message)
  end

  private

  def create_container
    Docker::Container.create(
      "Image" => "paid-agent:latest",
      "name" => "paid-#{project_id}-#{SecureRandom.hex(4)}",
      "User" => "agent",
      "ReadonlyRootfs" => true,
      "CapDrop" => ["ALL"],
      "CapAdd" => ["NET_RAW"],  # For iptables
      "SecurityOpt" => ["no-new-privileges:true"],
      "HostConfig" => {
        "Memory" => 4 * 1024 * 1024 * 1024,  # 4GB
        "MemorySwap" => 4 * 1024 * 1024 * 1024,  # No swap
        "CpuQuota" => 200_000,  # 2 CPUs
        "PidsLimit" => 256,
        "Tmpfs" => {
          "/tmp" => "size=1073741824,mode=1777",  # 1GB
          "/home/agent/.cache" => "size=536870912,mode=0755"  # 512MB
        },
        "Binds" => [
          "#{workspace_path}:/workspace:rw"
        ],
        "NetworkMode" => "paid-agent-network"
      },
      "Env" => [
        "PAID_PROXY_URL=http://paid-proxy:3001",
        "PROJECT_ID=#{project_id}",
        "HOME=/home/agent",
        # Point agent CLIs to proxy
        "ANTHROPIC_BASE_URL=http://paid-proxy:3001/proxy/api.anthropic.com",
        "OPENAI_BASE_URL=http://paid-proxy:3001/proxy/api.openai.com"
        # Note: NO API keys here!
      ]
    )
  end

  def apply_firewall_rules(container)
    container.exec(["/usr/local/bin/setup-firewall.sh"])
  end

  def workspace_path
    project = Project.find(project_id)
    "/var/paid/workspaces/#{project.account_id}/#{project_id}"
  end
end
```

```bash
#!/bin/bash
# scripts/setup-firewall.sh (runs inside container)

# Default deny all outbound
iptables -P OUTPUT DROP

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections (for responses)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# Allow secrets proxy
iptables -A OUTPUT -d paid-proxy -p tcp --dport 3001 -j ACCEPT

# Allow GitHub
iptables -A OUTPUT -d github.com -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -d api.github.com -p tcp --dport 443 -j ACCEPT

# Allow package registries
iptables -A OUTPUT -d registry.npmjs.org -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -d rubygems.org -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -d pypi.org -p tcp --dport 443 -j ACCEPT

# Log dropped packets for debugging
iptables -A OUTPUT -j LOG --log-prefix "PAID_DROPPED: " --log-level 4
```

## Alternatives Considered

### Alternative 1: gVisor (runsc)

**Description**: Use gVisor container runtime for stronger isolation

**Pros**:

- Syscall filtering provides better isolation than standard Docker
- Intercepts dangerous syscalls
- Defense against kernel exploits

**Cons**:

- Performance overhead (10-30% for I/O-heavy workloads)
- Compatibility issues with some applications
- Additional complexity
- Some agent CLIs may not work correctly

**Reason for rejection**: Standard Docker with hardening is sufficient for the threat model. gVisor adds complexity and performance overhead. Can revisit if threat model changes.

### Alternative 2: Kata Containers

**Description**: Use Kata Containers for VM-level isolation

**Pros**:

- VM-level isolation (strongest)
- Each container is a lightweight VM
- Protection against container escapes

**Cons**:

- Significant performance overhead
- Higher resource usage (each container needs VM resources)
- More complex deployment
- Nested virtualization issues in some environments

**Reason for rejection**: Overkill for current threat model. VM isolation makes sense for fully untrusted workloads, but agents are semi-trusted (we control their prompts). Docker isolation is adequate.

### Alternative 3: No Containers (Process Isolation)

**Description**: Run agents as separate processes with Unix user isolation

**Pros**:

- Simpler deployment
- Lower overhead
- Faster startup

**Cons**:

- Weaker isolation than containers
- Shared filesystem (harder to isolate projects)
- No network namespace isolation
- More difficult to manage dependencies

**Reason for rejection**: Containers provide better isolation guarantees with acceptable overhead. Network isolation in particular requires containers.

### Alternative 4: Firecracker microVMs

**Description**: Use Firecracker for lightweight VM isolation

**Pros**:

- VM-level isolation with sub-second startup
- Lower overhead than Kata
- Used by AWS Lambda

**Cons**:

- Requires KVM support
- Limited container tooling integration
- Smaller ecosystem than Docker
- More operational complexity

**Reason for rejection**: While appealing, Firecracker has less ecosystem support and requires more specialized infrastructure. Docker is more accessible for self-hosted deployments.

## Trade-offs and Consequences

### Positive Consequences

- **No credential exposure**: Agents never see API keys
- **Project isolation**: Containers cannot access other projects
- **Network control**: Exfiltration attempts blocked
- **Resource limits**: Runaway agents cannot exhaust host
- **Auditability**: All network attempts logged
- **aidp compatibility**: Similar pattern, proven in production

### Negative Consequences

- **Startup overhead**: Container startup adds 5-30 seconds
- **Image maintenance**: Must update agent CLIs in image
- **Storage usage**: Each project needs workspace volume
- **Complexity**: More moving parts than process isolation

### Risks and Mitigations

- **Risk**: Container escape vulnerability in Docker
  **Mitigation**: Keep Docker updated. Capability dropping and user namespaces reduce attack surface. Defense-in-depth means escape alone isn't catastrophic.

- **Risk**: Agent finds way to exfiltrate data via allowed domains
  **Mitigation**: GitHub requires authentication. Package registries are upload-restricted. Proxy logs all LLM API usage. Behavioral monitoring can detect unusual patterns.

- **Risk**: Container image becomes stale with security vulnerabilities
  **Mitigation**: Automated image rebuilds on schedule. Vulnerability scanning in CI.

## Implementation Plan

### Prerequisites

- [ ] Docker installed on host
- [ ] Docker network created
- [ ] Base image built and pushed
- [ ] Secrets proxy deployed

### Step-by-Step Implementation

#### Step 1: Create Docker Network

```bash
# Create isolated network for agent containers
docker network create \
  --driver bridge \
  --subnet 172.28.0.0/16 \
  --ip-range 172.28.1.0/24 \
  --gateway 172.28.0.1 \
  paid-agent-network
```

#### Step 2: Build Base Image

```dockerfile
# Dockerfile.agent
FROM ruby:3.4-slim-bookworm AS base

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    iptables \
    nodejs \
    npm \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Remove attack tools
RUN rm -f /usr/bin/wget /usr/bin/nc /usr/bin/ncat || true

# Install agent CLIs
RUN npm install -g @anthropic/claude-code cursor-cli
RUN pip3 install --no-cache-dir openai-codex-cli
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && gh extension install github/gh-copilot \
    && rm -rf /var/lib/apt/lists/*

# Firewall script
COPY scripts/setup-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/setup-firewall.sh

# Non-root user
RUN useradd -m -s /bin/bash -u 1000 agent
USER agent

WORKDIR /workspace

# No secrets in environment
ENV PAID_PROXY_URL=http://paid-proxy:3001
```

#### Step 3: Deploy Secrets Proxy

```ruby
# config.ru (separate Rack app or middleware in Rails)
require_relative "lib/secrets_proxy"
run SecretsProxy.new
```

#### Step 4: Configure Container Service

Add ContainerService to Paid application (see implementation example above).

### Files to Modify

- `Dockerfile.agent` - Agent container image
- `scripts/setup-firewall.sh` - Network filtering script
- `docker-compose.yml` - Add agent network and proxy service
- `app/services/container_service.rb` - Container management
- `lib/secrets_proxy.rb` - API key injection proxy

### Dependencies

- Docker Engine 24+
- `docker-api` gem for Ruby Docker client
- Linux with iptables (for container firewall)

## Validation

### Testing Approach

1. Security tests for container isolation
2. Network tests for egress filtering
3. Integration tests for agent execution
4. Penetration testing for escape attempts

### Test Scenarios

1. **Scenario**: Container attempts to access unauthorized URL
   **Expected Result**: Connection blocked, logged as PAID_DROPPED

2. **Scenario**: Container attempts to read API key from environment
   **Expected Result**: Environment variable not present

3. **Scenario**: Container attempts to access another project's workspace
   **Expected Result**: Permission denied (volumes are isolated)

4. **Scenario**: Container uses all available memory
   **Expected Result**: Container killed by OOM, not host

### Performance Validation

- Container startup < 30 seconds
- No significant performance impact on agent execution
- Network latency to proxy < 10ms

### Security Validation

- Vulnerability scan on base image
- No root processes in container
- All capabilities dropped (except NET_RAW if needed)
- Egress filtering verified with tcpdump

## References

### Requirements & Standards

- Paid SECURITY.md - Security model
- Paid AGENT_SYSTEM.md - Agent execution architecture
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)

### Dependencies

- [Docker Engine](https://docs.docker.com/engine/)
- [docker-api gem](https://github.com/swipely/docker-api)
- [iptables](https://linux.die.net/man/8/iptables)

### Research Resources

- aidp devcontainer implementation
- Docker capability documentation
- Container security benchmarks (CIS Docker Benchmark)

## Notes

- Consider gVisor for future enhancement if threat model changes
- Monitor container resource usage for optimization opportunities
- Image rebuilds should be automated in CI/CD
- Firewall rules may need updates as agent CLIs add new endpoints
