---
parent: PAID
prefix: EXECUTION-AUTHORITY
---

# Low-Level Design: Execution Authority Grants

## Purpose

Paid must make per-run execution authority explicit before provisioning so the
platform, the selected runner, and later audit/provenance tooling can inspect
what credential classes a run may receive without exposing secret values.

## Contract

The provider-neutral contract is `ExecutionRunners::AuthorityGrantSet`. It is a
secret-free value object derived from an `AgentRun` and its
`ExecutionRunners::NetworkingPolicy`.

Each grant entry records:

- `kind` — the authority class
- `delivery` — how the authority reaches the run
- `scope` — whether the authority is run-, runner-, project-, or account-scoped
- `metadata` — secret-free identifiers such as runner keys, env key names, or
  MCP server names

`AgentRun#authority_grants` persists the current grant snapshot so operators
and later activities can inspect the run without reconstructing auth heuristics
from runtime state.

## Shipped Behavior

- Proxy-mode remains the default: proxy-restricted runs receive explicit Paid
  proxy-token and `model_provider_credentials` grants with `delivery:
  "proxy_mode"` unless existing heuristics select subscription-auth or
  direct-outbound execution.
- Subscription-auth runs additionally receive
  `subscription_auth_material`, making them distinguishable from both proxy-mode
  and direct-outbound runs.
- MCP-attached runs receive `mcp_credentials` with secret-free server names.
- Verification/screenshot-capable runs with configured object storage receive
  `object_storage_upload_authority`.
- Runs with service env material receive `service_credentials`.
