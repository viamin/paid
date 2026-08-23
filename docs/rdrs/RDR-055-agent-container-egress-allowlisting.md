# RDR-055: Agent Container Egress Allowlisting

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-14
- **Status**: Partially Implemented
- **Type**: Security + Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md) (Container Isolation), [RDR-006](RDR-006-secrets-proxy.md) (Secrets Proxy), [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution), [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md) (Subscription Runner Managed Auth Lifecycle), [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support), [RDR-054](RDR-054-prompt-assembly-service.md) (Prompt Assembly Service)
- **Related Intent**: `CONTAINER-RUNTIME-017`, `CONTAINER-RUNTIME-020`, `EGRESS-POLICY-001..006`, `docs/intent/container-egress-allowlisting/`
- **Related Issues**: #3434 (account/project allowlist entries and validation), #3435 (required platform and runner destination registry), #3436 (per-run egress policy resolution and snapshot persistence), #3437 (portable runner networking contract propagation), #3438 (production enforcement adapters and fail-closed runtime eligibility), #3439 (brokered research access with secret-extraction guards — open gap), #3440 (settings UI/API and run audit visibility), #3441 (this umbrella issue)
- **Related Tests**: `spec/models/egress_allowlist_entry_spec.rb`, `spec/models/egress_security_event_spec.rb`, `spec/services/agent_runs/egress_policy/host_pattern_spec.rb`, `spec/services/agent_runs/egress_policy/required_destinations_spec.rb`, `spec/services/agent_runs/egress_policy/resolve_spec.rb`, `spec/services/agent_runs/egress_policy/gateway_spec.rb`, `spec/services/agent_runs/egress_policy/gateway_adapters/docker_spec.rb`, `spec/services/agent_runs/egress_policy/gateway_adapters/kubernetes_spec.rb`, `spec/services/agent_runs/egress_policy/gateway_adapters/managed_machine_spec.rb`, `spec/requests/account_egress_allowlist_entries_spec.rb`, `spec/requests/projects/egress_allowlist_entries_spec.rb`, `spec/temporal/activities/provision_container_activity_spec.rb`, `spec/services/execution_runners/contract_runner_spec.rb`, `spec/services/execution_runners/local_docker_runner_spec.rb`, `spec/services/containers/provision_spec.rb`, `spec/migrations/expand_egress_allowlist_entries_for_audit_and_ui_dbless_spec.rb`

## Implementation Status

RDR-055 is **partially implemented** as of 2026-08-23. The tenant-managed
allowlist model, required-destination registry, per-run snapshot resolution and
persistence, portable runner-contract propagation, domain-aware Docker gateway
enforcement with production fail-closed behavior, and settings/run-audit UI are
all shipped.

One acceptance-criteria group remains open:

- brokered research egress with secret-extraction guards

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Tenant-managed account/project allowlist entries with server-side host-pattern validation | Implemented | `EgressAllowlistEntry`; related issue [#3434](https://github.com/viamin/paid/issues/3434) |
| Platform/runner required-destination registry | Implemented | `AgentRuns::EgressPolicy::RequiredDestinations`; related issue [#3435](https://github.com/viamin/paid/issues/3435) |
| Per-run egress snapshot resolution and persistence on `agent_runs.external_metadata["egress_policy"]` | Implemented | `AgentRuns::EgressPolicy::Resolve`, `Snapshot#persist!`; related issue [#3436](https://github.com/viamin/paid/issues/3436) |
| Provider-neutral networking-policy propagation including `egress_profile` | Implemented | `ExecutionRunners::NetworkingPolicy#egress_profile`, `Containers::Provision#networking_policy_with_egress_profile`; related issue [#3437](https://github.com/viamin/paid/issues/3437) |
| Tenant UI/API management and run-detail audit visibility | Implemented | egress allowlist controllers and run-detail audit surface; related issue [#3440](https://github.com/viamin/paid/issues/3440) |
| Domain-aware gateway enforcement with production fail-closed runtime eligibility | Implemented | `AgentRuns::EgressPolicy::Gateway`, `GatewayAdapters::{Docker,Kubernetes,ManagedMachine}`, `ExecutionRunners::{ContractRunner,LocalDockerRunner}`; related issue [#3438](https://github.com/viamin/paid/issues/3438) |
| Brokered research access with secret-extraction guards | **Gap** | Follow-up [#3439](https://github.com/viamin/paid/issues/3439) |

### 2026-08-23 Umbrella Audit

Audit recorded against umbrella issue
[#3441](https://github.com/viamin/paid/issues/3441); no umbrella closure is
claimed here while [#3439](https://github.com/viamin/paid/issues/3439) remains
open.

What is shipped in the repository as of 2026-08-23:

- the `EgressAllowlistEntry` model, migration, controllers, and shared
  `HostPattern` validator (`EGRESS-POLICY-001`, #3434, #3440)
- the `RequiredDestinations` code registry, including runner/provider host
  resolution and the drift-raises contract (`EGRESS-POLICY-002`, #3435)
- the `Resolve` service, `Snapshot` value object, and deterministic
  merge/dedupe/provenance pipeline (`EGRESS-POLICY-003..006`, #3436)
- account inheritance, project extension, required-destination
  shadow-proofing, and pre-provision fail-closed deny snapshots
  (`EGRESS-POLICY-004..006`, #3434, #3436)
- the `egress_profile` enum on `ExecutionRunners::NetworkingPolicy` plus
  `Containers::Provision#networking_policy_with_egress_profile` so the
  profile propagates through the portable runner contract
  (`CONTAINER-RUNTIME-020`, #3437)
- the per-host egress gateway contract and adapters, runner eligibility
  checks, Docker gateway enforcement, denial audit persistence, and
  production fail-closed behavior (`EGRESS-POLICY-007`, #3438)
- the settings UI/API controllers and the run-detail audit surface that
  renders the persisted snapshot plus denied/redacted `EgressSecurityEvent`
  rows (#3440)

What remains open:

- the brokered research fetch/search service, request-budgeting, and
  secret-extraction guards tracked by
  [#3439](https://github.com/viamin/paid/issues/3439)

Because the `research` profile acceptance criteria are still unmet and
issue [#3439](https://github.com/viamin/paid/issues/3439) is still open
as of 2026-08-23, this RDR remains **Partially Implemented**. Moving it
to **Implemented** before the broker exists would overstate the shipped
security boundary.

## Problem Statement

Paid runs untrusted agent code in containers. The current network model already distinguishes proxy-restricted runs from subscription-auth and direct-outbound runs, but the allowlist is mostly fixed: secrets proxy, GitHub, DNS, and service-container destinations. Production tenants need a controlled way to add project/account-specific destinations while preserving the default-deny posture.

The feature must answer three questions:

1. Which destinations are required by Paid and the selected runner?
2. Which additional destinations did the tenant approve?
3. Which exact network policy was applied to a specific agent run?

The policy must prevent accidental broad outbound access from becoming the default for agent containers.

## Context

`NetworkPolicy` owns Docker network selection and in-container firewall rules. `ExecutionRunners::NetworkingPolicy` already carries a provider-neutral `allow_destinations` array on `RunSpec`, and `LocalDockerRunner` translates that array into Docker firewall destinations.

Current modes:

| Mode | Docker network | Firewall | Intended use |
|---|---|---:|---|
| `proxy_restricted` | `paid_agent` | yes | Provider API-key runs through the secrets proxy |
| `subscription_auth` | `paid_internal` | no | CLI login-state runners that must call provider APIs directly |
| `direct_outbound` | `paid_internal` | no | Providers that intentionally bypass the secrets proxy |

That shape is useful, but production egress allowlisting cannot rely on raw iptables host rules alone. Domain allowlists are not the same as IP allowlists: domains move, CDNs share IPs, and HTTPS hides URL paths from the network unless Paid performs TLS interception. TLS interception is out of scope for v1.

## Recommendation

Add an egress-policy layer that resolves one per-run policy snapshot from:

- platform-required destinations;
- runner/provider-required destinations;
- account and project allowlisted domains; and
- run-local destinations such as service containers and preview tunnels.

The snapshot is passed through the existing `ExecutionRunners::NetworkingPolicy#allow_destinations` path. Docker enforcement should use a per-Docker-host egress gateway for domain-aware HTTP(S) filtering, with the existing iptables rules reduced to the smaller job of allowing only the gateway, Paid-local endpoints, and service-container peers.

Core decision:

> Treat user allowlists as host/domain allowlists in v1. Do not promise path-level URL allowlisting unless Paid later owns an explicit application proxy flow for that traffic.

Second core decision:

> Keep egress policy provider-neutral. Docker, Kubernetes, Fly Machines, or another runner may enforce the same snapshot differently, but orchestration code should only see the runner-level policy.

## Proposed Design

### Destination Model

Persist tenant-managed egress rules at account and project scope:

```text
egress_allowlist_entries
- account_id
- project_id nullable
- host_pattern
- port nullable
- scheme nullable
- enabled
- reason
- created_by_id
- timestamps
```

`host_pattern` supports exact hosts and leading-wildcard subdomains:

- `api.example.com`
- `*.packages.example.com`

It does not support arbitrary globbing, raw regexes, URL paths, credentials, IP literals mixed into domain rules, or wildcard TLDs. If CIDR allowlisting is needed for a private deployment, add a separate operator-only `cidr` kind later rather than overloading domain rules.

### Required Destinations

Required destinations come from a small code registry, not tenant settings:

| Source | Examples | Applies when |
|---|---|---|
| Paid control plane | secrets proxy, GitHub proxy, callback URL | every agent run |
| GitHub | `github.com`, `api.github.com`, GitHub git/SSH ranges | repo checkout and PR operations |
| Runner provider | Anthropic, OpenAI, Google, GitHub Copilot, Codex endpoints | subscription-auth or direct-outbound provider runs |
| Service containers | per-container IP/port on the selected Docker network | run requested services |
| Preview tunnel | generated tunnel destination | live preview verification needs it |

For proxy-mode API-key runs, provider APIs are not required container egress; the container calls Paid's secrets proxy. For subscription-auth and direct-outbound runs, provider-required destinations are added explicitly. For example, Claude Code subscription-auth runs get Anthropic's required hosts from the runner registry.

### Policy Resolution

Add a small resolver, tentatively `AgentRuns::EgressPolicy::Resolve`, that returns:

```ruby
EgressPolicy::Snapshot.new(
  mode: "proxy_restricted",
  destinations: [
    { host: "egress-gateway", port: 3128, source: "platform" },
    { host: "api.example.com", port: 443, source: "project_allowlist", entry_id: 123 }
  ],
  required_destinations: [...],
  denied_reason: nil
)
```

The snapshot is stored on `agent_runs.external_metadata["egress_policy"]` before provisioning so audits can see exactly what was intended even if provisioning fails.

Resolution order:

1. Start from the network mode selected by the runner.
2. Add platform-required destinations.
3. Add runner/provider-required destinations only when the mode requires direct provider egress.
4. Add enabled account allowlist entries.
5. Add enabled project allowlist entries.
6. Add run-local service and preview destinations.
7. Reject invalid or unsafe rules before the container starts.

Project entries may narrow or extend account entries, but they may not remove platform-required destinations.

### Runtime Portability

The policy object is not Docker-specific. `ExecutionRunners::NetworkingPolicy` remains the portable contract:

```text
mode
firewall?
allow_destinations
egress_profile
```

Runner implementations translate that contract to their local control plane:

| Runtime | Enforcement translation |
|---|---|
| Local/remote Docker | Docker network + in-container firewall + per-host egress gateway |
| Docker Swarm | Overlay network + same gateway pattern per worker/placement group |
| Kubernetes | `NetworkPolicy`/CNI egress policy + namespace/service-local egress gateway |
| Managed machine runner | Provider firewall/security group + gateway sidecar or platform egress control |

The RDR should not require every future runner to expose iptables, Docker bridge names, or Docker DNS. If a runtime cannot enforce the requested egress profile, it is not eligible for production restricted runs.

### Enforcement

Use the existing Docker runner contract:

- `RunSpec.networking_policy.allow_destinations` carries the resolved snapshot destinations.
- `LocalDockerRunner#apply_firewall!` remains the Docker translation point.
- `NetworkPolicy.apply_firewall_rules` remains the low-level iptables writer.

For domain rules, add a per-Docker-host egress gateway:

- agent containers can reach only the egress gateway for outbound HTTP(S);
- the gateway allows `CONNECT` or HTTP requests only when the target host matches the snapshot;
- the gateway logs denied attempts with `agent_run_id`, host, port, and rule source;
- DNS resolution for outbound domains happens in or beside the gateway, not as broad agent-container DNS freedom.

The existing in-container firewall still allows Paid-local destinations directly:

- secrets proxy / callback URL;
- GitHub proxy if used;
- service-container IP/port peers;
- preview tunnel endpoint when required.

Production behavior stays fail closed: if the gateway or firewall cannot be installed for a restricted run, provisioning fails.

### Research Egress

Some agent runs need limited internet access for documentation and API research. That should be a separate capability, not a hidden side effect of normal allowlists.

Add an `egress_profile` to the policy snapshot:

| Profile | Internet access | Intended use |
|---|---|---|
| `locked` | Required + tenant allowlisted destinations only | Default production agent runs |
| `research` | Brokered web-fetch/search access with budgets and logging | Documentation lookup and issue investigation |
| `open` | Broad outbound access | Operator-only break-glass, disabled for managed production by default |

For `research`, prefer a brokered research service over direct container internet:

- agent asks Paid for a URL fetch or search through a tool/API;
- Paid validates scheme, host, content type, response size, timeout, redirect chain, and robots/operator policy;
- Paid records query/URL, requester, agent run, response metadata, and byte/token budgets;
- returned content is rendered as untrusted evidence, not instructions;
- direct container egress remains locked except to Paid and the egress gateway.

This gives agents useful research ability without granting arbitrary sockets. A later implementation can add direct browser-style research through the same egress gateway, but only with explicit per-run opt-in, strict budgets, denylist/allowlist policy, and audit logs.

#### Secret Extraction Guard

Brokered research also gives Paid a practical place to watch for credential exfiltration. V1 should block high-risk outbound research requests before any network call:

- allow only `GET`/`HEAD` requests for brokered research;
- reject credentials in URLs, headers, query strings, fragments, and request bodies;
- scan requested URLs and search queries with the existing secret-scanning rules where possible;
- add simple high-entropy and known-token-shape checks for common API keys, OAuth tokens, private keys, session cookies, and cloud credentials;
- reject requests that contain exact fingerprints of secrets Paid already knows it issued or proxied;
- log a security event with `agent_run_id`, destination host, matched rule, and redacted evidence when a request is blocked.

The broker should also scan fetched responses before storing or injecting them into prompts. If a response contains credential-looking material, Paid should either redact it or quarantine the fetch result for human review. This is not because public docs should contain secrets, but because agents will fetch arbitrary pages and those pages can contain prompt-injection text, leaked credentials, or bait strings designed to trigger unsafe behavior.

This guard is best-effort DLP, not a proof. It reduces accidental and obvious secret extraction, but it cannot prove arbitrary text is harmless. Direct HTTPS egress through a `CONNECT` gateway cannot inspect full URLs or payloads without TLS interception, so any mode that permits direct browser-style research has weaker secret-extraction visibility than brokered fetch/search.

### UI/API Surface

Add the smallest tenant-facing surface:

- Account settings: manage account-wide allowlisted domains.
- Project settings: manage project-specific allowlisted domains.
- Agent run detail: show the egress policy snapshot and denied destination events.

Validation should be server-side and boring:

- normalize hostnames with Ruby `URI` / `Addrinfo` / IDNA handling already available in the stack where possible;
- reject paths in v1;
- reject userinfo, query strings, fragments, and schemes other than `http`/`https`;
- reject `*`, `*.com`, localhost, link-local, loopback, private IPs, and metadata IPs for tenant-managed public-domain entries.

Operator-only bootstrap config may still allow private infrastructure destinations for self-hosted deployments, but that is not a tenant self-service rule.

## Security Properties

- Default-deny remains the production baseline.
- Provider API keys still never enter containers for proxy-mode runs.
- Tenant allowlists cannot disable Paid-required destinations or switch a run into unrestricted networking.
- Policy decisions are snapshotted per run for incident review.
- Domain matching happens at an HTTP(S) egress gateway, not through stale DNS-to-IP expansion in Rails.
- Path-level URL filtering is explicitly not promised in v1.
- Runtime-specific enforcement stays behind the runner contract so non-Docker production backends can implement equivalent controls.
- Research access is explicit, budgeted, logged, and brokered by default.
- Brokered research blocks obvious credential exfiltration attempts before making outbound requests and redacts or quarantines fetched credential-looking content.

## Alternatives Considered

### Expand iptables with resolved domain IPs

Rejected. It is simple but unsafe for domain allowlisting because DNS changes, CDN sharing, and IP reuse make the rule either too broad or too brittle.

### Require every tool to use `HTTP_PROXY`

Rejected as the only enforcement layer. Environment variables are useful for compatibility, but malicious or buggy code can ignore them unless firewall rules force traffic through the gateway.

### TLS interception for full URL/path allowlisting

Rejected for v1. It requires installing a trusted CA in agent containers, breaks some CLIs, creates sensitive decrypted traffic handling, and is more machinery than Paid needs for the first production control.

### Keep subscription-auth and direct-outbound unrestricted

Rejected for production. These modes exist for real runner compatibility, but they should receive provider-required egress rules rather than unlimited internet access.

### Give agents direct internet for research

Rejected as the default research mechanism. It is convenient, but it makes exfiltration and prompt-injection exposure harder to inspect. Brokered fetch/search through Paid gives enough utility for v1 and keeps direct sockets locked down.

### Build a full DLP classifier first

Rejected for v1. Paid should reuse existing secret-scanning rules, exact known-secret fingerprints, and simple high-entropy checks before adding a new classifier. A complex DLP engine can follow if security events show real misses that the simple scanner cannot cover.

## Implementation Plan

1. Add the persisted allowlist entry model with account/project scope and server-side validation.
2. Add the required-destination registry for Paid, GitHub, and runner/provider endpoints.
3. Add `AgentRuns::EgressPolicy::Resolve` and persist its snapshot on agent runs.
4. Wire the snapshot into `ExecutionRunners::NetworkingPolicy#allow_destinations` and `egress_profile`.
5. Add a minimal per-host egress gateway and make production restricted runs fail closed when it is unavailable.
6. Add brokered research fetch/search as an explicit `research` egress profile, with outbound secret-extraction scanning and response quarantine/redaction.
7. Add settings UI/API for allowlist entries and run-detail visibility for policy snapshots/denials.
8. Close out with tests for validation, policy resolution, runner translation, production fail-closed behavior, research broker budgets, and audit snapshot persistence.

## Acceptance Criteria

- A project admin can add, disable, and delete project allowlisted domains without editing deployment config.
- An account admin can define account-wide domains inherited by projects.
- An agent run records its effective egress policy before provisioning.
- Proxy-mode runs can reach Paid-required endpoints, GitHub, service containers, and approved tenant domains, but not arbitrary public hosts.
- Claude Code subscription-auth runs can reach the required Anthropic hosts without giving all outbound internet access.
- A research-enabled run can fetch approved web evidence through Paid without broad direct container egress.
- A brokered research request containing a secret-looking token is blocked before the outbound call and records a redacted security event.
- A runtime that cannot enforce the selected egress profile is rejected for production restricted runs.
- Invalid tenant rules for paths, broad wildcards, localhost, private IPs, and metadata IPs are rejected.
- Production provisioning fails if the required egress enforcement cannot be applied.

## Open Questions

- Which egress gateway implementation should be used: a small existing proxy image, Envoy, Squid, or a purpose-built minimal service?
- Should package registries such as npm, RubyGems, PyPI, and crates.io be platform-required defaults or project-selected presets?
- Should denied egress events become a first-class incident feed, or are agent-run logs enough for v1?
