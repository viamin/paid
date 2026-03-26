# RDR-019: Remote Container Execution

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-03-25
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (scaling initiative)
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md) (Container Isolation), [RDR-006](RDR-006-secrets-proxy.md) (Secrets Proxy)

## Problem Statement

Paid currently runs all agent containers on the same Docker host as the Rails application via `/var/run/docker.sock`. This creates a hard ceiling on concurrent agent runs — bounded by the CPU, memory, and disk of a single machine. As usage grows, the system needs to schedule agent containers across multiple hosts without sacrificing the security guarantees established in RDR-004 (network isolation, secrets proxy, no credential exposure).

Specific limitations of the single-host model:

1. **Resource contention** — Each agent container uses up to 4 GB RAM and 2 CPUs. A 32 GB host can run ~6 concurrent agents before swapping.
2. **No geographic distribution** — All work happens on one machine regardless of where target repos or users are located.
3. **Single point of failure** — Host failure kills all running agent containers with no failover.
4. **Idle waste** — The host must be provisioned for peak load even when idle.

## Context

### Background

The container management layer (`Containers::Provision`, `Containers::GitOperations`, `NetworkPolicy`) uses the `docker-api` Ruby gem, which communicates with the Docker Engine API. Today this targets the local Unix socket, but the Docker Engine API is a REST API that can be exposed over TCP with TLS mutual authentication.

The secrets proxy (`SecretsProxyController`) runs inside the Rails process and is reachable by agent containers via Docker DNS (`paid-proxy:3000` on the `paid_internal` network). Workspace volumes are bind-mounted from a shared local path (`/var/paid/workspaces`).

### Technical Environment

- **Container API**: `docker-api` gem → Docker Engine REST API
- **Networking**: Two Docker bridge networks (`paid_internal`, `paid_agent`) with iptables egress filtering
- **Storage**: Local bind mounts from `/var/paid/workspaces` (bare repos + worktrees)
- **Proxy**: Rails on port 3000, accessible as `paid-proxy` via Docker DNS alias

### Constraints

- Must preserve the security model from RDR-004: no API keys in containers, network egress filtering, capability dropping
- Must not require agents to change how they call the secrets proxy
- Should work for both self-hosted (e.g., NAS, spare server) and cloud deployments
- Should be incrementally adoptable — local Docker must remain a supported backend

## Research Findings

### Investigation Process

1. Analyzed current coupling between `Containers::Provision` and the local Docker socket
2. Evaluated Docker remote API, Docker Swarm, and Kubernetes as execution backends
3. Investigated secrets proxy reachability patterns for cross-host networking
4. Reviewed workspace storage strategies for remote hosts
5. Assessed cloud container services (ECS, Cloud Run, ACI) for fit

### Key Discoveries

**Docker Remote API**

The `docker-api` gem respects the `DOCKER_HOST` environment variable and supports `tcp://host:2376` with TLS client certificates. This means the existing `Containers::Provision` code can target a remote Docker host with minimal code changes — the API calls are identical.

```ruby
# Local (current)
Docker.url = "unix:///var/run/docker.sock"

# Remote (new)
Docker.url = "tcp://worker-1.internal:2376"
Docker.options = {
  client_cert: "/etc/paid/certs/client-cert.pem",
  client_key: "/etc/paid/certs/client-key.pem",
  ssl_ca_file: "/etc/paid/certs/ca.pem"
}
```

**Secrets Proxy Reachability**

On a remote host, Docker DNS (`paid-proxy:3000`) does not resolve. The proxy must be reachable via a routable address. Options:

1. **Direct exposure** — Expose proxy on a real IP/port with mTLS. Agent containers use that address instead of `paid-proxy`.
2. **Sidecar proxy** — Run a lightweight reverse proxy container on each remote host that tunnels back to the Rails proxy (e.g., via WireGuard, SSH tunnel, or Cloudflare Tunnel).
3. **Overlay network** — Docker Swarm overlay networks span hosts and preserve DNS resolution.

**Workspace Storage**

Current model: bare git clone on the host, worktree created per agent run, bind-mounted into container. For remote hosts:

1. **Fresh clone per run** — Clone directly inside the container. Slower (~30-60s for large repos) but eliminates shared storage dependency.
2. **NFS/SMB mount** — Share `/var/paid/workspaces` across hosts. Adds latency and an infrastructure dependency.
3. **Container volume with git init** — Create a Docker volume on the remote host, clone into it from within a setup container, then mount into the agent container.
4. **Object storage cache** — Cache bare repos in S3/MinIO; pull to remote host on demand.

**Docker Swarm**

Swarm mode provides multi-host scheduling, overlay networking, and service discovery with minimal additional tooling. The `docker-api` gem can target a Swarm manager. Key benefits:

- Overlay networks solve cross-host DNS (`paid-proxy` resolves everywhere)
- Built-in scheduling across nodes
- Secret management (though we already have our own proxy pattern)
- No new tooling — just `docker swarm init` and `docker swarm join`

**Kubernetes**

Kubernetes provides the most scalable path but requires replacing `Docker::Container.create` calls with Pod/Job creation via the `kubeclient` gem. Key differences:

- NetworkPolicy objects replace iptables rules
- PersistentVolumeClaims replace bind mounts
- Services/Ingress replace Docker DNS for proxy access
- Managed offerings (EKS, GKE) eliminate node management

## Proposed Solution

### Approach

Introduce a **container backend abstraction** that decouples agent container lifecycle management from the Docker socket. The system ships with three backends:

1. **Local Docker** (current behavior, default)
2. **Remote Docker** (single remote host via TCP API)
3. **Docker Swarm** (multi-host scheduling via Swarm manager)

A future **Kubernetes backend** is out of scope for initial implementation but the abstraction is designed to accommodate it.

### Technical Design

#### Backend Interface

```ruby
# app/services/containers/backends/base.rb
module Containers
  module Backends
    class Base
      def create_container(config) = raise NotImplementedError
      def start_container(container_id) = raise NotImplementedError
      def stop_container(container_id, timeout: 10) = raise NotImplementedError
      def delete_container(container_id) = raise NotImplementedError
      def exec_in_container(container_id, command) = raise NotImplementedError
      def container_stats(container_id) = raise NotImplementedError
      def container_logs(container_id, **opts) = raise NotImplementedError
      def list_containers(filters: {}) = raise NotImplementedError
      def create_network(name, **opts) = raise NotImplementedError
      def prepare_workspace(agent_run) = raise NotImplementedError
      def cleanup_workspace(agent_run) = raise NotImplementedError
    end
  end
end
```

#### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        PAID CONTROL PLANE                               │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────────┐  │
│  │ Rails App    │  │ Secrets Proxy│  │ Container Backend Router     │  │
│  │              │  │ (port 3000)  │  │                              │  │
│  │              │  │              │  │  LocalDocker | RemoteDocker  │  │
│  │              │  │              │  │  | Swarm     | (Kubernetes)  │  │
│  └──────────────┘  └──────┬───────┘  └──────┬───────────────────────┘  │
│                           │                  │                          │
└───────────────────────────┼──────────────────┼──────────────────────────┘
                            │                  │
              ┌─────────────┼──────────────────┼─────────────────────┐
              │             │    DOCKER API (TCP+TLS or Socket)      │
              │             ▼                  ▼                      │
┌─────────────┼──────────────────┐  ┌────────────────────────────────┼──┐
│  LOCAL HOST │                  │  │  REMOTE HOST (NAS / Cloud VM)  │  │
│             │                  │  │                                 │  │
│  ┌──────────┴───┐              │  │  ┌──────────────┐              │  │
│  │ Agent        │              │  │  │ Agent        │              │  │
│  │ Container    │              │  │  │ Container    │              │  │
│  │              │              │  │  │              │              │  │
│  │ proxy:3000 ──┼── loopback   │  │  │ proxy:3000 ──┼── tunnel ───┼──┤
│  └──────────────┘              │  │  └──────────────┘              │  │
│                                │  │                                │  │
│  ┌──────────────┐              │  │  ┌──────────────┐              │  │
│  │ /var/paid/   │              │  │  │ Docker Volume │              │  │
│  │ workspaces   │              │  │  │ (clone per   │              │  │
│  │ (bind mount) │              │  │  │  run)        │              │  │
│  └──────────────┘              │  │  └──────────────┘              │  │
└────────────────────────────────┘  └────────────────────────────────────┘
```

#### Backend Selection

Backends are configured per-account or globally via environment/settings:

```ruby
# config/initializers/container_backend.rb
Rails.application.config.x.container_backend = case ENV.fetch("CONTAINER_BACKEND", "local")
when "local"
  Containers::Backends::LocalDocker.new
when "remote"
  Containers::Backends::RemoteDocker.new(
    host: ENV.fetch("REMOTE_DOCKER_HOST"),
    tls_config: {
      client_cert: ENV.fetch("REMOTE_DOCKER_CERT"),
      client_key: ENV.fetch("REMOTE_DOCKER_KEY"),
      ca_file: ENV.fetch("REMOTE_DOCKER_CA")
    }
  )
when "swarm"
  Containers::Backends::Swarm.new(
    manager_host: ENV.fetch("SWARM_MANAGER_HOST", "unix:///var/run/docker.sock")
  )
end
```

#### Secrets Proxy for Remote Hosts

For remote backends, the secrets proxy must be reachable from the remote network. The recommended approach is a **secure tunnel**:

```ruby
# Remote Docker backend injects the proxy address as a routable URL
# instead of relying on Docker DNS
module Containers
  module Backends
    class RemoteDocker < Base
      def proxy_address
        # Routable address configured by operator
        ENV.fetch("PAID_PROXY_EXTERNAL_URL", "https://paid-proxy.internal:3000")
      end
    end
  end
end
```

Operators choose their tunnel method:

| Method | Complexity | Use Case |
|--------|-----------|----------|
| WireGuard VPN | Low | LAN hosts (NAS, spare server) |
| SSH tunnel | Low | Single remote host |
| Cloudflare Tunnel | Medium | Cloud VMs without public IPs |
| Overlay network (Swarm) | Low | Swarm-managed hosts |
| Load balancer + mTLS | Medium | Cloud with multiple workers |

#### Workspace Provisioning for Remote Hosts

Remote backends use **clone-per-run** instead of bind-mounted bare repos:

```ruby
module Containers
  module Backends
    class RemoteDocker < Base
      def prepare_workspace(agent_run)
        # 1. Create a Docker volume on the remote host
        volume = Docker::Volume.create(
          "Name" => "paid-workspace-#{agent_run.id}",
          "Labels" => { "paid.agent_run_id" => agent_run.id.to_s }
        )

        # 2. Run a setup container that clones the repo into the volume
        setup = Docker::Container.create(
          "Image" => "paid-agent:latest",
          "Cmd" => ["git", "clone", "--branch", agent_run.branch,
                    agent_run.project.clone_url, "/workspace"],
          "HostConfig" => {
            "Binds" => ["#{volume.id}:/workspace:rw"]
          }
        )
        setup.start
        setup.wait(timeout: 300)
        setup.delete

        volume
      end
    end
  end
end
```

#### Network Policy Adaptation

The existing `NetworkPolicy` class applies iptables rules inside containers via `container.exec()`. This works identically on remote Docker hosts — the exec call goes over the Docker API, not the local socket. The only change is resolving the proxy IP:

```ruby
# NetworkPolicy already resolves proxy IP dynamically.
# For remote backends, PAID_PROXY_EXTERNAL_URL provides the address.
def proxy_ip
  if remote_backend?
    Resolv.getaddress(URI.parse(ENV["PAID_PROXY_EXTERNAL_URL"]).host)
  else
    container_ip_for("paid-proxy")
  end
end
```

### Decision Rationale

1. **Backend abstraction** — Decouples scheduling from the Docker socket without rewriting the container management layer. Each backend implements the same interface.
2. **Remote Docker first** — Lowest-effort path to running on a second host. Reuses all existing `docker-api` code. Ideal for self-hosted scenarios (NAS, spare server).
3. **Swarm as scaling tier** — Adds multi-host scheduling without leaving the Docker ecosystem. Overlay networks solve proxy DNS resolution automatically.
4. **Kubernetes deferred** — Highest capability ceiling but requires the most rework. The abstraction makes it addable later without changing calling code.
5. **Clone-per-run for remote storage** — Eliminates shared filesystem dependency. Slower for large repos but operationally simpler than NFS.
6. **Tunnel-based proxy access** — Avoids exposing the secrets proxy to the public internet while keeping configuration flexible.

## Alternatives Considered

### Alternative 1: Kubernetes Only

**Description**: Skip Docker-based scaling entirely and move straight to Kubernetes.

**Pros**:

- Most scalable long-term solution
- Managed offerings eliminate node management
- Native NetworkPolicy, PVC, and secret management
- Industry-standard for container orchestration

**Cons**:

- Requires replacing all `docker-api` calls with `kubeclient` or Kubernetes API
- Significant learning curve for self-hosted operators
- Overkill for small deployments (1-3 hosts)
- Cannot reuse existing iptables-based network policy
- Heavier infrastructure footprint

**Reason for rejection**: Kubernetes is the right end-state for large deployments, but requiring it from day one raises the barrier to entry. The backend abstraction allows adding Kubernetes later. Most Paid users are self-hosted and benefit from Docker-native scaling first.

### Alternative 2: Cloud Container Services (ECS, Cloud Run, ACI)

**Description**: Use managed container services directly instead of managing Docker hosts.

**Pros**:

- No host management
- Auto-scaling built in
- Pay-per-use pricing
- Managed networking and security

**Cons**:

- Vendor lock-in to a specific cloud
- Each service has different APIs (no `docker-api` reuse)
- Secrets proxy must be publicly reachable or use cloud-native service mesh
- Harder to self-host
- Cost can be higher than reserved instances for sustained workloads

**Reason for rejection**: Vendor-specific implementations fragment the codebase. The Docker API is a common denominator — cloud VMs running Docker get the benefits of cloud hosting without lock-in. A Kubernetes backend covers managed cloud scenarios better.

### Alternative 3: Nomad

**Description**: Use HashiCorp Nomad for multi-host container scheduling.

**Pros**:

- Simpler than Kubernetes
- Native Docker driver
- Supports multiple task drivers (exec, Java, QEMU)
- Good for small-to-medium clusters

**Cons**:

- Additional infrastructure component
- Smaller ecosystem than Kubernetes or Swarm
- Different API from Docker (cannot reuse `docker-api` gem)
- HashiCorp licensing changes create uncertainty

**Reason for rejection**: Adds operational complexity without clear advantages over Docker Swarm for the target scale. If operators outgrow Swarm, Kubernetes is a better leap than Nomad.

### Alternative 4: NFS Shared Storage

**Description**: Share `/var/paid/workspaces` across all hosts via NFS instead of clone-per-run.

**Pros**:

- Preserves current bare-repo + worktree model
- No clone latency per run
- Single source of truth for workspace state

**Cons**:

- NFS adds latency to all git and file operations
- Single point of failure (NFS server)
- Git operations over NFS can cause lock contention
- Additional infrastructure to manage and secure
- Performance degrades significantly over WAN

**Reason for rejection**: NFS works on a fast LAN but is fragile and slow at scale. Clone-per-run is self-contained and works identically on LAN and cloud hosts. For large repos, a registry cache (MinIO/S3) can reduce clone times without NFS complexity.

## Trade-offs and Consequences

### Positive Consequences

- **Horizontal scaling** — Agent runs can be distributed across multiple hosts
- **Flexible deployment** — Same codebase works on local Docker, NAS, cloud VMs, or Swarm clusters
- **Incremental adoption** — Existing single-host deployments continue working unchanged
- **Cost efficiency** — Add capacity on demand; use cheaper hardware (NAS, spot instances) for agent runs
- **Fault tolerance** — Swarm backend can reschedule failed containers on healthy nodes

### Negative Consequences

- **Abstraction overhead** — Additional indirection in container management code
- **Clone latency** — Remote backends pay ~30-60s per run for fresh clones (mitigated by caching)
- **Tunnel management** — Operators must configure and maintain proxy tunnels for remote hosts
- **Image distribution** — `paid-agent` image must be available on all hosts (registry required)
- **Increased operational complexity** — More infrastructure to monitor and troubleshoot

### Risks and Mitigations

- **Risk**: TLS misconfiguration exposes Docker API to unauthorized access
  **Mitigation**: Provide setup scripts that generate and rotate certificates. Document mutual TLS as mandatory. Health checks verify TLS is active.

- **Risk**: Clone-per-run is too slow for large monorepos
  **Mitigation**: Implement a bare-repo cache on remote hosts. First run clones; subsequent runs fetch incrementally. Consider `--depth 1` shallow clones for agent runs that don't need full history.

- **Risk**: Proxy tunnel goes down mid-run, breaking LLM API access
  **Mitigation**: Tunnel health monitoring with automatic reconnection. Agent harness retries on transient proxy failures. Swarm overlay networks avoid this entirely.

- **Risk**: Backend abstraction leaks, causing behavioral differences between backends
  **Mitigation**: Integration test suite runs against all backends. Behavioral contract tests verify each backend satisfies the interface.

## Implementation Plan

### Prerequisites

- [ ] RDR-004 fully implemented (container isolation) — **Done**
- [ ] RDR-006 fully implemented (secrets proxy) — **Done**
- [ ] Container image published to a registry (GHCR or self-hosted)
- [ ] TLS certificate generation tooling

### Step-by-Step Implementation

#### Phase 1: Backend Abstraction (Extract)

Refactor `Containers::Provision` to delegate container operations through a backend interface. The `LocalDocker` backend wraps current behavior with no functional changes.

**Files to create:**

- `app/services/containers/backends/base.rb` — Interface definition
- `app/services/containers/backends/local_docker.rb` — Current behavior extracted
- `config/initializers/container_backend.rb` — Backend selection

**Files to modify:**

- `app/services/containers/provision.rb` — Delegate to backend instead of calling `Docker::Container` directly
- `app/services/containers/collect_metrics.rb` — Use backend for stats
- `app/jobs/docker_orphan_cleanup_job.rb` — Use backend for listing/cleanup

#### Phase 2: Remote Docker Backend

Implement `RemoteDocker` backend targeting a single remote host via TCP+TLS.

**Files to create:**

- `app/services/containers/backends/remote_docker.rb` — Remote host implementation
- `lib/tasks/remote_docker.rake` — Setup tasks (generate certs, test connectivity)
- `docs/guides/remote-docker-setup.md` — Operator guide

**New capabilities:**

- Clone-per-run workspace provisioning
- Configurable proxy address (not Docker DNS)
- TLS client certificate authentication

#### Phase 3: Docker Swarm Backend

Implement `Swarm` backend for multi-host scheduling.

**Files to create:**

- `app/services/containers/backends/swarm.rb` — Swarm service/task creation
- `docs/guides/swarm-setup.md` — Operator guide

**New capabilities:**

- Automatic scheduling across Swarm nodes
- Overlay network for proxy DNS resolution
- Node labeling for workload affinity (e.g., GPU nodes)

#### Phase 4: Kubernetes Backend (Future)

Out of scope for initial implementation. The backend interface is designed to accommodate:

- Pod/Job creation via `kubeclient` gem
- NetworkPolicy objects for egress filtering
- PersistentVolumeClaim for workspace storage
- Service/Ingress for proxy access

### Dependencies

- `docker-api` gem (existing) — supports remote Docker hosts
- TLS certificate tooling (OpenSSL or `mkcert` for development)
- Container registry (GHCR, Docker Hub, or self-hosted)
- For Swarm: Docker Engine 24+ in Swarm mode on all nodes

## Validation

### Testing Approach

1. **Unit tests** — Each backend implements the interface contract
2. **Integration tests** — Agent run lifecycle against each backend
3. **Security tests** — Verify isolation guarantees hold on remote hosts
4. **Performance tests** — Measure clone latency, proxy round-trip, container startup

### Test Scenarios

1. **Scenario**: Agent run on remote Docker host completes successfully
   **Expected Result**: Container created on remote host, proxy reachable via tunnel, workspace cloned, PR created on GitHub

2. **Scenario**: Remote Docker host becomes unreachable mid-run
   **Expected Result**: Agent run marked as failed with clear error. Orphan cleanup retries on reconnection.

3. **Scenario**: Two agent runs scheduled on Swarm land on different nodes
   **Expected Result**: Both containers run in parallel with isolated workspaces and independent proxy access

4. **Scenario**: Network egress filtering on remote host
   **Expected Result**: Identical filtering behavior to local Docker — only proxy, GitHub, and DNS allowed

5. **Scenario**: Backend falls back gracefully
   **Expected Result**: If remote host is unavailable, configurable fallback to local Docker (operator opt-in)

### Performance Validation

- Remote container startup < 45 seconds (including image pull from cache)
- Clone-per-run < 60 seconds for repos up to 1 GB
- Proxy round-trip via tunnel < 50ms on LAN, < 200ms on cloud
- No measurable difference in agent execution time (LLM calls dominate)

### Security Validation

- Docker API accessible only via mutual TLS
- Proxy tunnel encrypted in transit
- Agent containers on remote hosts pass same security tests as local
- No API keys present in container environment on any host

## References

### Requirements & Standards

- [RDR-004](RDR-004-container-isolation.md) — Container Isolation Strategy
- [RDR-006](RDR-006-secrets-proxy.md) — Secrets Proxy Architecture
- [SECURITY.md](../SECURITY.md) — Security model
- [AGENT_SYSTEM.md](../AGENT_SYSTEM.md) — Agent execution architecture

### Dependencies

- [Docker Engine API](https://docs.docker.com/engine/api/) — REST API for remote Docker management
- [Docker Swarm](https://docs.docker.com/engine/swarm/) — Native Docker orchestration
- [docker-api gem](https://github.com/swipely/docker-api) — Ruby Docker client
- [WireGuard](https://www.wireguard.com/) — Recommended tunnel for LAN hosts

### Research Resources

- Docker TLS configuration: `dockerd --tlsverify`
- Swarm overlay networking documentation
- Kubernetes operator pattern for future backend

## Notes

- The backend abstraction is the critical first step — it enables all subsequent scaling work with zero risk to existing deployments.
- For the QNAP/NAS use case, Remote Docker + WireGuard tunnel is the recommended path. Container Station exposes the Docker API and WireGuard runs natively on QNAP.
- Clone-per-run latency can be improved with a bare-repo cache on remote hosts — fetch-only after initial clone.
- Consider adding a `worker_id` or `host` field to `AgentRun` to track where each run executed, for debugging and capacity planning.
- Swarm mode can be initialized on a single node first, then scaled out — making it a natural upgrade from Remote Docker.
