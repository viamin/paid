# RDR-048: Multi-Host Docker Backend Support

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-16
- **Status**: Draft
- **Type**: Operations + Architecture
- **Priority**: P1
- **Related Issues**: #2944 (tracking), #2945 (backend configuration and registry), #2946 (scheduler and manual placement), #2947 (per-host concurrency), #2948 (multi-host lifecycle operations), #2949 (readiness checks), #2950 (management UI), #2951 (setup guide and automation helpers), #2952 (optional capacity-aware placement), #2953 (implementation audit and RDR closeout)
- **Related RDRs**: RDR-019 (Remote Container Execution), RDR-020 (Service Container Architecture), RDR-033 (Worker Pool Scaling Algorithm), RDR-043 (Zero-Config Docker Capacity Autoscaling)
- **Related Tests**: Docker backend resolver tests, container provisioning tests, process queue admission tests, orphan cleanup tests, container metrics tests, capacity snapshot tests, operations dashboard system tests, host setup wizard tests

## Implementation Status

Not implemented. Paid currently supports selecting exactly one active Docker backend for new paid-agent provisioning:

- `CONTAINER_BACKEND=local` provisions paid-agent containers on local Docker.
- `CONTAINER_BACKEND=remote` provisions paid-agent containers on one configured remote Docker daemon.
- `CONTAINER_BACKEND=swarm` provisions paid-agent containers through the Swarm backend.

The current remote Docker backend has been verified against the QNAP host `elguapo` at `100.113.201.1:2376` using mTLS, with `paid-agent:latest` and the required Docker networks present. In that mode, however, `elguapo` replaces local Docker for new agent containers; it is not additional capacity beside local Docker on `barts-macbook-pro`.

Paid already has several primitives needed for multi-host operation:

- `agent_runs.container_host` persists the host/backend selected for a run.
- `container_pool_entries.container_host` persists the backend used for warm pool entries.
- `Containers::Backends::Resolver` can register named backends.
- `Containers.backend_for(host)` can reconnect to a backend by persisted `container_host`.
- `Containers.all_backends` lets orphan cleanup scan more than the active backend in some modes.
- Metrics collection uses `Containers.backend_for(agent_run.container_host)`.
- Backend interfaces already expose `identifier`, `remote?`, `supports_host_paths?`, `owns_host?`, `all_host_identifiers`, and `container_host_for(container)`.

Paid still assumes one active backend for placement and admission:

- `config/initializers/container_backend.rb` resolves one `Rails.application.config.x.container_backend` from `CONTAINER_BACKEND`.
- Fresh provisioning defaults to `Containers.backend`.
- Warm pool replenishment creates entries with `Containers.backend.identifier`.
- `ProcessRunQueueJob` fetches one Docker capacity policy/snapshot per pass.
- `Capacity::RunAdmission#active_local_agent_reserved_bytes` only accounts for local-style hosts (`nil`, blank, and `local`).
- `ServiceContainerReconciliationJob` checks running service containers through `Containers.backend`.
- Network and proxy readiness are evaluated for the backend passed to provisioning, but no scheduler chooses among several backend candidates.
- The account operations dashboard can already surface capacity state, but there is no UI for adding Docker hosts, setting per-host concurrency limits, checking readiness, or guiding remote-host setup.

## Issue Plan

Implementation is tracked by a dependency-ordered issue chain. No issue in this chain should be labeled higher than `P2`.

| Issue | Priority | Scope | Dependency |
|-------|----------|-------|------------|
| #2944 | P2 | Umbrella tracking issue for RDR-048 | None |
| #2945 | P2 | Multi-host backend configuration and registry | Depends on #2944 |
| #2946 | P2 | Conservative scheduler and manual host placement | Depends on #2945 |
| #2947 | P2 | Independent per-host Docker concurrency limits | Depends on #2946 |
| #2948 | P2 | Multi-host lifecycle operations for cleanup, metrics, warm pools, and service containers | Depends on #2947 |
| #2949 | P2 | Per-host Docker readiness checks | Depends on #2948 |
| #2950 | P2 | Docker Hosts management UI | Depends on #2949 |
| #2951 | P2 | Remote Docker setup guide and automation helpers | Depends on #2950 |
| #2952 | P3 | Optional capacity-aware host placement | Depends on #2951 |
| #2953 | P2 | Final implementation audit, gap filing, and RDR status update | Depends on #2952 |

The final issue (#2953) should update this RDR to `Implemented` only after auditing that the shipped implementation matches the plan. If any acceptance criteria are missing or intentionally deferred, #2953 should create specific follow-up issues and reference them from this RDR instead of marking the RDR implemented prematurely.

## Problem Statement

Paid can target local Docker or one remote Docker host, but it cannot use multiple Docker hosts at once. This is limiting for developers and self-hosted operators who have useful capacity split across machines, such as:

- local Docker on `barts-macbook-pro`;
- a QNAP/NAS Docker daemon such as `elguapo`;
- a remote workstation available over Tailscale or another private network.

Switching `CONTAINER_BACKEND=remote` is operationally useful, but it changes all new paid-agent provisioning to the remote daemon. Operators cannot keep local Docker as the default while manually placing selected runs on a remote host, nor can Paid fall back from one healthy host to another without changing environment configuration and restarting the app.

The current configuration path is also too opaque for self-hosted operators. Adding a remote Docker host requires leaving Paid, generating certificates, copying files, preparing networks, building or loading images, setting environment variables, and then inferring from logs whether the host is ready. Paid should automate the parts it can safely automate, provide copyable host-specific commands for the rest, and make readiness failures visible in the UI.

The first version should not attempt a full cluster scheduler. The core need is to register several Docker backends, manage per-host capacity limits, select one explicitly or conservatively, persist that selection, and make lifecycle operations follow the persisted host.

## Context

### Verified Remote Host Facts

- QNAP `elguapo` Docker is reachable at `100.113.201.1:2376` with mTLS.
- The Paid devcontainer host is `barts-macbook-pro`, Tailscale IP `100.114.20.109`.
- Containers on `elguapo` can call back to Paid at `http://100.114.20.109:3000`.
- `elguapo` has the required Docker networks and `paid-agent:latest`.
- `paid_agent` is the restricted/internal agent network.
- `paid_internal` is the unrestricted infrastructure network.
- The remote backend does not support host bind mounts.

### Current Backend Model

The backend interface is already close to the right abstraction. `LocalDocker`, `RemoteDocker`, and `Swarm` provide a shared set of container, network, volume, stats, image, and host-identity operations. This RDR should extend that model rather than introducing a separate Docker client layer.

The key missing distinction is:

```text
active backend = default backend used by singleton-era callers
configured backends = all Docker hosts available for scheduler placement
selected backend = backend chosen for a specific run/container lifecycle
```

Today those collapse into `Containers.backend` for most provisioning paths.

### Host Identity

The selected backend should continue to be recorded in `agent_runs.container_host`. For local and single remote Docker backends, this is already the backend identifier. For Swarm, it may be a node hostname returned by `container_host_for(container)`.

Multi-host mode should treat host identifiers as operator-facing stable names, not raw URLs, so logs, UI, and retry decisions can say `local` or `elguapo` instead of only `tcp://100.113.201.1:2376`.

## Recommendation

Introduce a multi-host Docker scheduler and management UI that can register several Docker backends, configure independent host capacity limits, and choose one backend for each paid-agent run.

Core decision:

> Keep `local`, `remote`, and `swarm` as backward-compatible single-backend modes. Add an explicit multi-host mode that registers named backends, performs conservative placement, and persists the selected backend through the existing `agent_runs.container_host` field.

V1 should prioritize correctness and operator control:

- explicit preferred host from global/account/project configuration;
- independent per-host concurrency limits;
- optional first-healthy fallback among configured hosts;
- no automatic capacity balancing unless later implementation proves it can reuse existing capacity code safely;
- no implicit activation from existing `REMOTE_DOCKER_*` variables.

The account operations UI should become the primary operator surface for multi-host configuration. Environment variables remain the bootstrap/backward-compatible path, but once multi-host mode is enabled, Paid should let an admin add hosts, validate readiness, view capacity, generate setup assets where safe, and copy exact remaining setup commands.

## Proposed Design

### Backend Registry

Extend backend registration so Paid can distinguish the active singleton backend from all configured schedulable Docker hosts.

In single-backend modes:

- `CONTAINER_BACKEND=local` keeps today’s behavior.
- `CONTAINER_BACKEND=remote` keeps today’s behavior with one remote backend from `REMOTE_DOCKER_*`.
- `CONTAINER_BACKEND=swarm` keeps today’s behavior.
- `Containers.backend` continues to return the selected singleton backend.

In multi-host mode:

- `CONTAINER_BACKEND=multi` enables the scheduler.
- `Containers.backend` may return a compatibility/default backend, but new paid-agent provisioning must ask the scheduler for a selected backend.
- `Containers.backend_for(container_host)` must resolve any configured named backend.
- `Containers.all_backends` must return every configured backend so cleanup and metrics can iterate all hosts.

The scheduler itself can be a small service, tentatively `Containers::BackendScheduler`, with inputs:

```text
agent_run
project/account/global host preference
allowed fallback hosts
required backend capabilities
health/readiness snapshot
```

Output:

```text
selected backend
selection reason
fallback chain considered
```

### Proposed V1 Configuration

Existing environment variables continue to work unchanged for single-backend modes.

For multi-host mode, prefer a structured config payload over unbounded indexed environment variables. This fits better than inventing `REMOTE_DOCKER_HOST_1`, `REMOTE_DOCKER_HOST_2`, `REMOTE_DOCKER_CERT_1`, and so on, and it leaves room for per-host settings.

Example:

```yaml
CONTAINER_BACKEND: multi
CONTAINER_BACKENDS_CONFIG: |
  default_host: local
  fallback: first_healthy
  hosts:
    local:
      type: local
      concurrency:
        mode: manual
        max_concurrent_runs: 2
    elguapo:
      type: remote
      host: tcp://100.113.201.1:2376
      tls:
        ca_file: /workspaces/paid/config/docker/elguapo/ca.pem
        client_cert: /workspaces/paid/config/docker/elguapo/cert.pem
        client_key: /workspaces/paid/config/docker/elguapo/key.pem
      proxy_external_url: http://100.114.20.109:3000
      supports_host_paths: false
      concurrency:
        mode: manual
        max_concurrent_runs: 4
    aws-runner-1:
      type: remote
      host: tcp://10.0.10.25:2376
      tls:
        ca_file: /var/paid/docker-hosts/aws-runner-1/ca.pem
        client_cert: /var/paid/docker-hosts/aws-runner-1/cert.pem
        client_key: /var/paid/docker-hosts/aws-runner-1/key.pem
      proxy_external_url: https://paid.example.com
      supports_host_paths: false
      concurrency:
        mode: manual
        max_concurrent_runs: 8
```

If Rails credentials or another existing structured settings surface becomes the preferred home during implementation, this shape should be mapped there rather than forcing all host definitions into process environment. For operator-managed deployments, prefer persisted host records or a structured tenant setting edited through the UI, with secret material stored through the existing credential/encrypted settings pattern rather than plaintext JSON.

Per-host config should support at least:

- stable host identifier;
- backend type (`local` or `remote` in v1; `swarm` can remain its own singleton mode unless explicitly added later);
- Docker endpoint and TLS settings for remote hosts;
- per-host `PAID_PROXY_EXTERNAL_URL` or equivalent callback URL;
- image name/tag override only if needed;
- whether host bind mounts are supported;
- whether the host is enabled for automatic fallback.
- concurrency mode (`manual` in v1, `auto` later when per-host capacity admission is proven);
- hard per-host max concurrent runs;
- optional per-host project/account overrides or eligibility tags in a later phase;
- setup status and last readiness error.

### Management UI

Add a Docker Hosts area to the account operations/admin interface. It should be designed as an operational control plane, not a marketing page: dense, scannable, and centered on host state, capacity, and setup progress.

The host index should show:

- host name and backend type;
- enabled/disabled state;
- health/readiness state with the failing check named;
- Docker endpoint or local indicator;
- configured proxy callback URL;
- architecture and Docker daemon summary when available;
- image status for `paid-agent:latest`;
- required network status;
- current active paid-agent runs;
- per-host concurrency limit and available slots;
- whether fallback placement may use the host;
- last successful check and last error.

The host detail page should let an admin:

- edit display name, identifier, endpoint, callback URL, image tag, fallback eligibility, and manual concurrency limit;
- run readiness checks on demand;
- view recent runs placed on the host;
- view recent provisioning, cleanup, metrics, and readiness errors scoped to the host;
- copy setup commands for the host;
- disable a host without deleting its historical run ownership;
- delete only hosts with no active containers, or otherwise require an explicit drain path.

The project/account/global placement settings should expose:

- default preferred host;
- fallback behavior (`disabled`, `first_healthy`);
- optional per-project preferred host;
- optional manual run placement override when starting or retrying a run;
- validation that selected hosts are enabled and compatible with the run requirements.

### Setup Guide and Automation

The UI should include a setup guide/wizard for adding a remote Docker host. The guide should be host-specific and preserve progress across steps.

For a QNAP/NAS or Linux remote host, the wizard should cover:

1. Name the host and choose a stable identifier such as `elguapo`.
2. Enter the host/IP and expected Docker TLS port.
3. Generate or upload Docker mTLS client/server certificate material.
4. Show the commands or QNAP UI steps needed to install server certificates and enable the TLS Docker endpoint.
5. Validate that Paid can ping Docker over TLS.
6. Configure the callback/proxy URL reachable from containers on that host.
7. Validate callback reachability from a short-lived test container when possible.
8. Verify or create required Docker networks.
9. Verify `paid-agent:latest` is present and architecture-compatible.
10. Build, pull, load, or copy the image using the best available method.
11. Set the host concurrency limit.
12. Run a dry-run provisioning check that creates and removes a disposable container.

Paid should automate what it can do from the control plane:

- generate a local certificate authority and Docker client certificate/key for a named host;
- generate a server certificate signing request or self-signed server certificate when the operator supplies hostnames/IP SANs;
- store client certificate material securely for the backend connection;
- test TLS connectivity;
- create missing Docker networks on the remote daemon when authorized;
- inspect Docker architecture and daemon resources;
- check image presence and labels/digest;
- run a disposable readiness container;
- generate exact shell commands for remote setup;
- generate `docker save` / `docker load`, registry push/pull, or remote `docker build` instructions for `paid-agent:latest`.

Paid should clearly document what it cannot safely automate from inside the app:

- changing NAS vendor settings that require QNAP admin UI access;
- opening firewall/router ports;
- installing Docker or enabling daemon TLS when SSH/admin access is unavailable;
- copying server certificates to a host unless an explicit remote access mechanism is configured;
- guaranteeing Tailscale or VPN routing outside the container network;
- distributing subscription-auth host credentials to remote Docker hosts without an explicit credential design.

For non-QNAP remote hosts such as AWS instances, the same wizard should provide a generic Linux path. Later implementations may add provider-specific helpers, but v1 should keep the core contract Docker-over-mTLS plus reachable Paid callback URL.

### Placement Policy

V1 placement order:

1. Use an explicit host requested for the run when present and authorized by configuration.
2. Otherwise use project preference.
3. Otherwise use account preference.
4. Otherwise use global/default host.
5. If the preferred host is unavailable and fallback is enabled, choose the first healthy compatible host in configured order.
6. If no compatible host is available, leave the run queued and log a host-specific capacity/readiness reason.

This deliberately avoids automatic load balancing in v1. Capacity-aware placement can come later after the per-host capacity snapshots, admission accounting, and UI/debugging story are proven.

Manual concurrency limits are still enforced in v1. A host with `max_concurrent_runs: 2` may run two paid-agent containers even if another configured host has room; fallback only chooses another compatible host when policy allows it. This lets `local`, `elguapo`, and an AWS runner each have independent ceilings.

The scheduler must filter hosts by hard capability requirements before health fallback:

- worktree bind mounts require `supports_host_paths?`;
- subscription-auth runs that rely on host-backed credentials require a backend that supports the selected auth material;
- restricted proxy-mode runs require a reachable proxy callback URL;
- service-container dependencies require network reachability on the same backend or an explicitly supported cross-host service strategy.

### Health and Readiness

Each configured backend should have a health/readiness check that can be evaluated independently and cached briefly:

- Docker ping succeeds.
- Docker daemon architecture is compatible with `paid-agent:latest`.
- Required networks exist:
  - `paid_agent`;
  - `paid_internal`.
- `paid-agent:latest` exists locally on that Docker host or can be pulled/created according to configured policy.
- Remote containers can reach that host’s configured Paid callback/proxy URL.
- Backend supports the selected run’s mount/auth/network requirements.
- TLS credentials for remote Docker are present and valid enough to connect.

Readiness failure should be host-specific. One unhealthy remote host must not make a healthy local host unusable.

### Operational Behavior

#### Image Distribution

Images are per-host state. Multi-host mode must treat `paid-agent:latest` on `local`, `elguapo`, and any AWS host as separate artifacts. V1 can require operators to pre-build or pre-load the image on every configured host, but the UI should still help:

- detect whether the image exists on each host;
- show architecture compatibility;
- show digest/tag drift when available;
- generate copyable build/load/pull commands;
- optionally trigger an image pull/build where the Docker API and deployment policy allow it.

A later phase may add full reconciliation that builds, pushes, pulls, or verifies digests per host.

#### Network Reconciliation

Networks are per-host state. `NetworkPolicy.ensure_network!` already accepts a backend argument; multi-host mode should call it for the selected backend during provisioning and expose readiness for missing networks. Optional reconciliation can create missing networks on each configured host when policy allows.

#### Proxy and Callback URLs

Remote backends need a URL reachable from containers on that host. The current global `PAID_PROXY_EXTERNAL_URL` is sufficient for one remote host, but multi-host mode needs per-host callback configuration because different hosts may reach Paid through different addresses.

For the verified QNAP setup:

```text
elguapo containers -> http://100.114.20.109:3000
```

Local Docker can continue to use the in-compose proxy host where applicable.

#### Host-Specific Errors and Retry

Provisioning failures should record the backend identifier and failure class. Retry behavior should distinguish:

- selected host transient failure: retry the same host first when the run has an explicit host;
- fallback-enabled preference failure: try the next healthy compatible host;
- capability mismatch: do not retry on incompatible hosts;
- authentication or TLS misconfiguration: surface as operator action, not queue churn.

If a retry chooses a different host after a failed pre-container attempt, `agent_runs.container_host` should be updated only when a container is actually created or successfully selected for lifecycle ownership. Avoid recording a host too early if no resources exist there.

#### Cleanup and Orphan Scanning

`DockerOrphanCleanupJob` already iterates `Containers.all_backends`; multi-host mode should make that method return every configured backend. The existing persisted `container_host` and `backend.all_host_identifiers` strategy should remain the ownership boundary for active-run and warm-pool filtering.

`AgentRunResourceJanitorJob`, `AgentRun#cleanup_orphaned_workspace_volume`, and metrics collection already resolve by `container_host`; these paths should continue to be the model for lifecycle operations.

`ServiceContainerReconciliationJob` currently checks service containers through `Containers.backend`. Multi-host support must either persist service container host identity or keep service containers scoped to one backend until a cross-host service-container design exists.

#### Metrics and Capacity

Metrics collection for a running agent container should continue to use `Containers.backend_for(agent_run.container_host)`.

Capacity snapshots should become per-backend, using the existing `Capacity::DockerSnapshot.cache_key(backend_identifier)` shape. Queue admission currently fetches one snapshot/policy per pass; multi-host mode needs per-host admission.

V1 should support manual per-host concurrency limits:

```text
local: max_concurrent_runs = 2
elguapo: max_concurrent_runs = 4
aws-runner-1: max_concurrent_runs = 8
```

Admission should count only active paid-agent runs on the selected host when applying that host's limit. User/account/project guardrails still apply across all hosts unless a later RDR deliberately changes fairness semantics. In other words, host limits are execution-capacity ceilings, not a bypass for tenant/account/user concurrency policy.

When the selected host has no slots, behavior depends on placement policy:

- explicit host selection: leave the run queued for that host and explain the host limit;
- preferred host with fallback disabled: leave the run queued for the preferred host;
- preferred host with first-healthy fallback: choose the first compatible healthy host that also has an available host slot.

Capacity-aware scheduling should be a later phase unless implementation can safely extend `Capacity::RunAdmission` to account for active/reserved memory per selected backend.

#### Remote Host Bind Mounts and Auth

The remote backend does not support host bind mounts. Multi-host placement must reject remote hosts for runs requiring `worktree_path` bind mounts and should favor named-volume/in-container clone flows for remote execution.

Subscription-auth behavior also differs by backend:

- host-backed credential mounts are natural on local Docker;
- remote Docker cannot mount local credential paths;
- provider proxy mode works on restricted networks if the remote container can reach Paid’s proxy URL;
- subscription-auth/direct-outbound mode requires a deliberate host-specific credential story before remote placement is allowed.

## Consequences

### Benefits

- Operators can use local Docker and remote NAS/workstation capacity at the same time.
- Developers can offload expensive agent runs to QNAP/NAS hardware without losing local Docker as a fallback.
- Operators can set conservative, independent concurrency ceilings per Docker host.
- The UI makes remote host setup observable and repeatable instead of relying on environment variables and logs.
- `agent_runs.container_host` becomes a complete lifecycle routing key for multi-host operations.
- The backend interface remains the central abstraction instead of adding a parallel orchestration system.
- Later capacity-aware placement can build on per-host health, metrics, and readiness snapshots.

### Costs

- Configuration becomes more complex, especially TLS and per-host callback URLs.
- The operations UI must handle secrets, setup progress, validation errors, and destructive actions carefully.
- Operators must manage image and network drift across hosts unless reconciliation is added.
- Debugging requires every log/UI surface to identify the selected host.
- Warm pools and service containers need host-specific behavior.
- Capacity calculations become per-host instead of deployment-global.

### Risks

- A partially healthy host may pass Docker ping but fail at network, image, proxy, architecture, or auth readiness.
- Remote credential differences can cause a run to work locally and fail remotely.
- Cleanup can miss resources if a host identifier changes after containers are created.
- First-healthy fallback can surprise operators if it silently moves work to a remote host with different cost/performance/security properties.
- Capacity-aware scheduling could over-admit if it mixes memory accounting across hosts.
- Certificate generation can create a false sense of completion if server-side installation and firewall changes remain manual.
- Per-host concurrency limits can interact confusingly with existing user/account/project guardrails unless the UI explains which limit is binding.

Mitigations:

- require explicit `CONTAINER_BACKEND=multi`;
- keep v1 placement manual/preference-driven;
- log selected host and selection reason;
- cache and expose per-host readiness;
- show the binding concurrency limit in queue/admission explanations;
- make setup guides explicit about automated vs manual steps;
- preserve single-backend behavior exactly;
- make host identifiers stable and operator-controlled.

## Alternatives Considered

### Alternative 1: Keep Single Backend Only

Continue requiring operators to choose `local`, `remote`, or `swarm` at process start.

Rejected. This preserves simplicity, but it forces remote QNAP to be a replacement for local Docker rather than additional capacity. It also wastes existing `container_host` and backend lookup infrastructure that already points toward multi-host lifecycle support.

### Alternative 2: Use Docker Swarm Only

Tell operators who need multiple hosts to use the existing Swarm backend.

Rejected for v1. Swarm is useful when operators want a Docker-native cluster, but it is a heavier operational commitment than "local Docker plus one QNAP over mTLS." It also changes scheduling, networking, service semantics, and image distribution in ways that are unnecessary for manual local-plus-remote placement.

### Alternative 3: Require Kubernetes or an External Orchestrator

Move multi-host scheduling outside Paid entirely.

Rejected. This may be appropriate for managed platform deployments later, but it is too heavy for the self-hosted/developer use case. The verified `elguapo` setup already works through the Docker backend abstraction.

### Alternative 4: Treat Remote QNAP as Replacement Capacity

Keep the current `CONTAINER_BACKEND=remote` behavior and document that operators can switch the whole deployment to QNAP when needed.

Rejected. This is today’s behavior and does not satisfy simultaneous use, explicit host placement, fallback, or per-host lifecycle visibility.

### Alternative 5: Capacity-Balanced Scheduler in V1

Immediately choose the host with the most available CPU/memory.

Rejected for v1. Paid has Docker capacity primitives from RDR-043, but they are currently oriented around one active backend and local auto capacity. Balancing across hosts before per-host accounting, UI, and fallback semantics are stable would increase risk.

### Alternative 6: Configuration-Only Multi-Host Support

Support multi-host definitions only through environment variables or YAML, without a UI.

Rejected. This would technically enable multiple Docker hosts, but it would keep the hardest parts of the workflow hidden: certificate setup, image readiness, network drift, callback reachability, and per-host concurrency. The target operator needs Paid to make setup and troubleshooting visible.

## Implementation Outline

### Phase 1: Registry, Config, and Manual Placement

- Add structured multi-host config parsing.
- Register named local/remote backends.
- Add `Containers::BackendScheduler`.
- Add explicit global/account/project preferred-host setting or equivalent configuration surface.
- Add manual per-host concurrency limits and enforce them during queue admission.
- Select a backend before provisioning and pass it into `Containers::Provision`.
- Persist selected host through existing `agent_runs.container_host`.
- Keep `CONTAINER_BACKEND=local`, `remote`, and `swarm` behavior unchanged.

### Phase 2: Management UI and Setup Guide

- Add Docker Hosts management under the account operations/admin interface.
- Add host index, host detail, edit form, and disable/drain affordances.
- Add setup wizard for local, QNAP/NAS, and generic remote Linux Docker hosts.
- Add helpers to generate certificate material or setup commands where safe.
- Add image/network/proxy readiness panels with copyable remediation commands.
- Add UI explanations showing host concurrency limits separately from account/user/project guardrails.

### Phase 3: Health Checks and Visibility

- Add per-backend readiness checks and short-lived cache.
- Surface host health, network/image/proxy readiness, and recent errors in admin/status UI.
- Log selection reason and fallback chain.
- Ensure remote proxy callback validation is per host.

### Phase 4: Lifecycle Coverage

- Make `Containers.all_backends` return all configured multi-host backends.
- Ensure cleanup, janitor, metrics, warm pool, and service-container reconciliation use persisted host identity.
- Decide whether service containers remain single-host or gain host persistence.
- Add tests for cleanup and metrics across local plus `elguapo`.

### Phase 5: Capacity-Aware Placement

- Extend `Capacity::DockerSnapshot` and `Capacity::RunAdmission` to operate per backend.
- Account for active and reserved agent memory by selected host.
- Add capacity-aware selection as an opt-in policy after manual placement is stable.
- Preserve first-healthy/manual placement as the conservative fallback.

### Phase 6: Optional Image and Network Reconciliation

- Verify or reconcile required networks on each host.
- Verify image presence and compatible architecture.
- Optionally pull/build/distribute images per host.
- Optionally compare image digests and report drift.

## Acceptance Criteria

- Existing `CONTAINER_BACKEND=local` behavior is unchanged.
- Existing single `CONTAINER_BACKEND=remote` behavior is unchanged.
- Existing `CONTAINER_BACKEND=swarm` behavior is unchanged.
- Multi-host config can register local Docker plus `elguapo`.
- The operations/admin UI can add, edit, disable, and inspect Docker hosts.
- The UI exposes independent manual concurrency limits per host.
- Queue admission enforces host-level concurrency separately from existing user/account/project guardrails.
- A run can be explicitly placed on either `local` or `elguapo`.
- First-healthy fallback can be enabled or disabled by configuration.
- `agent_runs.container_host` records the chosen backend/host for every provisioned run.
- Cleanup scans all configured hosts in multi-host mode.
- Metrics collection reads from the persisted host for each running container.
- Remote hosts are rejected for runs that require unsupported host bind mounts.
- Remote proxy readiness validates that containers can reach the configured Paid callback URL.
- The setup guide can generate or accept certificate material, test Docker TLS connectivity, and show copyable remaining setup commands.
- The setup guide can verify or guide image availability and required networks per host.
- Tests cover backward compatibility, host selection, fallback, host concurrency, persisted host lookup, setup wizard behavior, cleanup, and metrics.
