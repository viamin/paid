---
parent: PAID
prefix: RUNNER-ZDR
---

# Low-Level Design: Runner Zero Data Retention Declaration

> Companion to [the high-level design](../../high-level-design.md). This
> segment owns the runner-level Zero Data Retention (ZDR) declaration.

## Context

Project data classification remains a project requirement. In particular, a
`restricted` project continues to require the existing OpenRouter routing
controls regardless of a runner's ZDR setting. Model selection policy also
remains independent: selecting Free never implies ZDR and enabling ZDR never
selects a model.

Users additionally need to record that a runner is intended to use zero data
retention. OpenRouter supports a request-time ZDR routing option. Other
providers can be used only on the user's own verified agreement and
configuration; Paid must not claim to have verified them.

## Design

`Runner#zero_data_retention` is an explicit persisted boolean, defaulting to
false. Existing runner rows therefore remain opted out when the column is
introduced.

`Runner#zero_data_retention_provenance` derives the status from the current
runner configuration rather than storing a stale label:

| Declaration | Current provider | Provenance |
| --- | --- | --- |
| off | any | `not_requested` |
| on | OpenRouter | `openrouter_enforced` |
| on | any other or unknown provider | `user_declared` |

The provenance is computed from the resolved direct-outbound provider or the
runner credential's service type. A provider or credential change therefore
immediately changes the displayed provenance. `openrouter_enforced` is only
reported on an OpenRouter request path that receives the declaration in its
request-time routing options. A saved checkbox by itself is never evidence of
runtime enforcement.

The OpenRouter routing builder accepts the runner declaration in addition to
the project classification. It preserves project-derived requirements and adds
`zdr: true` for a declared OpenRouter runner. It must not weaken
`data_collection: "deny"` or project-required ZDR.

Runner create/update forms expose the declaration independently from model
policy. When it is enabled, the form displays: "You are responsible for
verifying this provider's zero data retention agreement and configuration."
Runner list/detail surfaces and the tenant-authorized runner MCP serialization
return both the declaration and provenance. Runner audit events include the
same non-secret configuration facts. Agent-run pattern evidence includes the
declaration and provenance, so operational audits retain the relevant runner
configuration without exposing credentials.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Derive provenance from live provider state | Persist a provenance enum | A persisted enum becomes misleading when provider or credential changes. |
| Permit declarations for all providers | Allow only OpenRouter | Paid cannot verify a customer's provider agreement; the declaration remains useful and accurately labeled. |
| Keep ZDR separate from model policy | Add a ZDR model policy | Retention routing and model choice are independent controls, including the existing Free policy. |
