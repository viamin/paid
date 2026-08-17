# RDR-058: Execution Authority, Network Policy, and Isolation

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-12
- **Status**: Draft
- **Type**: Security Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md), [RDR-006](RDR-006-secrets-proxy.md), [RDR-010](RDR-010-multi-tenancy-rbac.md), [RDR-024](RDR-024-multi-tenancy-isolation-strategy.md), [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md), [RDR-045](RDR-045-live-web-app-preview-agent-verification.md), [RDR-057](RDR-057-remote-execution-data-contract.md) (credential lane transport), [RDR-061](RDR-061-infrastructure-safety-and-audit.md) (network policy audit)
- **Related Issues**: #3336, #3341 (networking policy), #3343 (services/sidecars), #3356 (runner capabilities)

## Problem Statement

Paid currently has strong Docker-era controls: proxy-mode agents receive no provider API keys, restricted networking is applied with iptables, and subscription-auth/direct-outbound modes are explicit exceptions. Cloud runners need the same intent expressed without Docker network names, host credential mounts, or public endpoints.

This RDR combines three inseparable decisions:

1. What authority an execution environment receives.
2. What network access it is allowed.
3. What isolation boundaries must hold between tenants, projects, and runs.

## Current Implementation

- `Api::ContainerAuthentication` authenticates run-scoped calls with `AgentRun#proxy_token`.
- `Api::SecretsProxyController` injects provider API keys server-side and tracks token usage.
- `Containers::Provision` injects proxy env (`PAID_PROXY_URL`, `GITHUB_API_URL`, `PROXY_TOKEN`, provider base URLs) and seeds subscription credentials when required.
- `RunnerCredential`, `GithubToken`, `IntegrationCredential`, and provider credentials are encrypted Active Record records with revocation/expiry fields.
- `Runners::SubscriptionAuthMaterializers` classifies managed subscription-auth materializers and whether they are remote-safe.
- `NetworkPolicy` currently maps `:proxy`, `:subscription_auth`, and `:direct_outbound` to Docker networks and firewall behavior.
- RDR-045 preview work uses an outbound tunnel and Rails reverse proxy for human ingress instead of making containers publicly reachable.

## Forces and Constraints

- Least privilege is required even for the first single-user cloud deployment.
- Third-party CLIs may require OAuth state or native credential files inside the environment.
- Paid can secure its own proxies and credentials, but cannot make external CLIs non-exfiltrating once they need direct internet plus credential material.
- Runners vary: some can enforce egress policies, some can only choose coarse networking modes.
- Do not design a generic firewall DSL before requirements justify it.

## Options Considered

### Broad per-environment secrets

Give every execution environment cloud credentials, GitHub tokens, and provider keys through env vars.

- **Pros**: Easy for provider CLIs.
- **Cons**: Maximum blast radius; conflicts with RDR-006.
- **Decision**: Reject.

### Proxy-only for every run

Force all model, GitHub, MCP, and artifact traffic through Paid.

- **Pros**: Strongest audit and revocation.
- **Cons**: Some subscription CLIs cannot operate through the proxy; browser/previews and approved MCP endpoints need more nuanced access.
- **Decision**: Default, not universal.

### Capability-scoped authority plus coarse network policies

Grant only the credential classes a run needs and pair them with one of a small set of network policies.

- **Pros**: Least privilege without building a firewall language.
- **Cons**: Runners with weak network enforcement may be ineligible for sensitive workloads.
- **Decision**: Adopt.

## Decision

Paid will model execution authority as a per-run grant set and execution networking as a small, provider-neutral policy.

### Authority Model

Each run receives only the authority required by its `RunSpec`:

- **Run API credential**: run-scoped proxy token for Paid APIs; revocable by ending the run.
- **GitHub authority**: prefer GitHub App installation tokens or proxy-mediated Git credentials; PAT fallback remains control-plane held where possible.
- **Model-provider authority**: proxy credentials by default; runner API-key material only when the selected runner/mode requires it.
- **Subscription-auth state**: materialized from `RunnerCredential` only for the selected runner and run; host-forwarded credentials stay local/host-path-only.
- **MCP credentials**: granted per configured MCP server and endpoint, not as broad account secrets.
- **Object-storage authority**: prefer control-plane upload; if direct runner upload is needed, issue per-run, prefix-scoped, short-lived write authority.
- **Cloud/provider authority**: held by the control plane or runner service, not passed into the agent workload.
- **Service credentials**: execution-scoped defaults for sidecars/services; no production data credentials.

### Network Policy Model

`ExecutionRunners::NetworkingPolicy` should evolve from `:proxy | :subscription_auth | :direct_outbound` into these intent values:

| Policy | Meaning |
|---|---|
| `:none` | No outbound except runner-required control channel, if any. |
| `:paid_proxy` | Paid APIs/proxy only. |
| `:git_and_paid_proxy` | Paid proxy plus Git provider access needed for clone/push. |
| `:approved_services` | Adds execution-scoped services/sidecars and approved MCP/service endpoints. |
| `:model_direct` | Allows selected model provider endpoints for subscription/direct runners. |
| `:internet` | Arbitrary outbound, explicit exception only. |

The policy is intent. Each runner maps it to native controls: Docker networks/iptables, provider egress settings, sidecar proxying, or rejection when unsupported.

### Ingress Policy

Agent execution environments have no public inbound endpoint by default.

Exceptions must be capability-scoped:

- Live previews use the RDR-045 pattern: outbound tunnel from execution environment to Paid, authenticated Rails reverse proxy to the user.
- Browser verification uses execution-scoped browser/service networking, not public ports.
- Debugging endpoints require explicit operator action, expiration, authentication, and audit events.
- Webhook/callback workflows should terminate at Paid and be forwarded through a run-scoped channel when needed.

### Isolation Invariants

Paid should preserve these even before full external-customer multi-tenancy:

- Control plane secrets are not copied into agent workloads except explicitly granted subscription-auth material.
- Different accounts, projects, and simultaneous runs do not share writable workspaces.
- Service/sidecar state is scoped by project/run according to declared sharing rules; production data is never attached.
- Logs and artifacts are tagged by account/project/run and authorized through Paid.
- Runner resources carry stable Paid ownership tags.
- Network policies are per run, not per host.
- A runner that cannot provide required isolation is ineligible for that run.

## Security Implications

- Proxy-mode keeps RDR-006's strongest property: provider API keys remain control-plane held.
- Subscription-auth and direct-outbound runs are security exceptions, not equivalent to proxy mode. They must be visible in UI/logs/audit and eligible only when the runner declares support.
- Per-run tokens must be treated as bearer secrets; ending/canceling a run should make them useless through active-run checks.

## Operational Implications

- Runner capability checks must include network and credential materialization support before provisioning.
- Operators need clear failure messages: "runner cannot enforce requested network policy" is a scheduling failure, not an agent failure.
- Approved MCP/service endpoints should be a small allowlist, not ad hoc internet access.

## Migration and Compatibility

- Existing Docker `paid_agent` restricted mode maps to `:git_and_paid_proxy` plus approved service destinations.
- Existing `paid_internal` subscription/direct mode maps to `:model_direct` or `:internet` depending on the runner's actual needs.
- RDR-045 preview tunnel remains the ingress implementation.
- Host-forwarded subscription credentials stay supported for local Docker only unless a managed remote-safe materializer exists.

## Consequences and Trade-offs

- Some provider experiments may fail capability validation before useful benchmarks; that is cheaper than weakening isolation.
- The policy list is intentionally coarse. If real MCP/service requirements outgrow it, add named destinations before building a firewall DSL.
- Direct internet remains possible, but it is an exception that carries audit and scheduling consequences.

## Open Questions

- Which MCP endpoint approvals are account-level versus project-level?
- Should `:internet` require explicit per-run human approval in all production deployments?
- How should runners report "policy approximated but not perfectly enforceable" without creating a false sense of security?

## Relationship to Existing Work

This RDR extends #3341's networking extraction with authority and isolation decisions. It references, rather than replaces, RDR-006 secrets proxy, RDR-041 subscription auth, RDR-045 previews, and RDR-024 tenant isolation.
