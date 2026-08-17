# RDR-058: Execution Authority Grants, Network Mode, and Isolation

- Status: Implemented
- Priority: P1
- Date: 2026-08-17
- Related RDRs: RDR-004, RDR-006, RDR-041, RDR-055, RDR-057

## Context

Paid already distinguishes proxy-restricted, subscription-auth, and
direct-outbound execution at provisioning time, but that decision has mostly
been implicit in heuristics spread across container provisioning, runner
selection, and manifest construction. Runners and operators need an explicit,
secret-free statement of which authority classes a run is allowed to receive
before provisioning starts.

## Decision

Each agent run carries a persisted, secret-free `authority_grants` snapshot.
The same grant object is exposed at the runner boundary through
`ExecutionRunners`, so runner implementations can validate support before they
provision an execution environment.

The grant model records authority classes rather than secret payloads:

- Paid API proxy token
- GitHub authority
- Model-provider credentials, with explicit delivery mode
- Subscription-auth material
- MCP credentials
- Object-storage upload authority
- Service credentials

`model_provider_credentials` use explicit delivery modes:

- `proxy_mode`
- `subscription_auth`
- `direct_outbound`

`subscription_auth_material` is emitted only for runs that materially receive
native subscription auth, so proxy-mode and direct-outbound runs remain
distinguishable from subscription-auth runs.

## Consequences

- Provisioning and runner validation can inspect a stable, structured grant
  contract without seeing secrets.
- Persisted run metadata and manifest/audit data remain secret-free by
  construction.
- RDR-006 proxy-mode behavior remains the default because proxy-restricted runs
  still receive proxy-token and proxy-mode model grants unless the existing
  subscription-auth or direct-outbound heuristics explicitly select a different
  mode.
