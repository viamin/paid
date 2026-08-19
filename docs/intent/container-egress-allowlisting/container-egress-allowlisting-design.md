---
parent: PAID
prefix: EGRESS-POLICY
---

# Low-Level Design: Container Egress Allowlisting

> Companion to the high-level design (`docs/high-level-design.md`) and
> [RDR-055](../../rdrs/RDR-055-agent-container-egress-allowlisting.md).
> Covers the per-run egress policy resolution layer: tenant-managed allowlist
> entries, the required-destination registry, and the per-run policy snapshot.

## Purpose

Paid runs untrusted agent code. The default network posture is deny-by-mode:
proxy-restricted runs reach only Paid endpoints through the secrets proxy,
while subscription-auth and direct-outbound runs reach their provider
directly. RDR-055 adds a controlled extension point so tenants can approve
additional destinations without weakening the baseline, and so every run
records exactly which egress policy applied to it.

## Scope of this segment

This segment covers implementation plan steps 1–3 of RDR-055:

1. the persisted `EgressAllowlistEntry` model (account/project scope),
2. the required-destination code registry, and
3. `AgentRuns::EgressPolicy::Resolve` plus snapshot persistence.

Gateway enforcement (step 5), the `research` egress profile broker (step 6),
and the settings UI (step 7) remain future work tracked by the RDR.

## Allowlist entries

`egress_allowlist_entries` rows are tenant-managed domain rules. A row with a
null `project_id` applies account-wide; a project-scoped row extends the
account set for that project only. Entries carry an optional port and
`http`/`https` scheme, an `enabled` flag, and an audit `reason`.

`host_pattern` accepts exact public hostnames and leading-wildcard subdomains
(`*.packages.example.com`) only. One shared validator
(`AgentRuns::EgressPolicy::HostPattern`) is the single source of truth for
rejection: bare/nested wildcards, wildcard TLDs, URL paths, userinfo, inline
ports, query/fragment, IP literals (including private, loopback, link-local,
and metadata IPs), and localhost names are rejected. Write-time validation and
the resolver's read-time defensive re-validation use the same module, so a
legacy or manually-inserted row can never widen a run's policy.

## Required destinations

Required destinations come from code (`AgentRuns::EgressPolicy::RequiredDestinations`),
never tenant settings:

- **platform** — egress gateway (`egress-gateway:3128`) and the secrets proxy,
  for every agent run. The secrets-proxy host/port is the endpoint as seen
  from the run's container, resolved through `Containers::ProxyUrl` from the
  run's backend and networking policy: `paid-proxy:<port>` for restricted
  runs on a local backend, `web:<port>` for unrestricted local runs, and the
  configured external proxy URL for remote backends;
- **github** — `github.com` and `api.github.com` for repo checkout and PR
  operations, for every agent run;
- **runner provider** — subscription provider hosts (Anthropic, OpenAI,
  Google, GitHub Copilot), the fixed OpenRouter host for the
  `openrouter_free`/`openrouter_pareto` runners, or the configured
  direct-outbound API provider host, only when the run's network mode is
  `subscription_auth` or `direct_outbound`.

## Resolution

`AgentRuns::EgressPolicy::Resolve` merges, in deterministic order:

1. platform-required destinations,
2. GitHub destinations,
3. runner/provider-required destinations (direct-egress modes only),
4. enabled account-wide entries (by id),
5. enabled project entries (by id),
6. run-local service containers and the preview destination.

First occurrence wins on `[host, port]`, so required destinations can never be
shadowed or removed by tenant entries, and an account entry outranks a
duplicate project entry. Every destination carries provenance (`source`,
`entry_id`/`service_container_id`, `reason`) explaining why it was included.

An unsafe persisted entry is excluded from the destination list, recorded in
`denied_reason`, and fails the run closed: `Resolve.resolve_and_persist!`
persists the denied snapshot first (so the rejection is auditable) and then
raises `DeniedPolicyError` before any provisioning runs.

## Snapshot

The resolved `AgentRuns::EgressPolicy::Snapshot` (mode, `egress_profile`
defaulting to `locked`, destinations, required destinations, `denied_reason`,
`resolved_at`) is persisted to `agent_runs.external_metadata["egress_policy"]`
by `ProvisionContainerActivity` before provisioning starts — threading the
planned container host into resolution so the secrets-proxy destination
matches the backend that will actually provision the run — so a failed
provision still leaves the intended policy auditable. Enforcement wiring into
`NetworkingPolicy#allow_destinations` (RDR-055 step 4) will consume this
snapshot.
