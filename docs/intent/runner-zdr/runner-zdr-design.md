---
parent: PAID
prefix: RUNNER-ZDR
---

# Low-Level Design: Runner Zero Data Retention Declaration

> Companion to the high-level design (`docs/high-level-design.md`). Owns the
> runner-level zero data retention declaration and provenance introduced by
> GitHub issue #4704.

## Context

Model selection and provider retention are independent concerns. A runner may
use either the specific or free model policy while separately requiring zero
data retention (ZDR). Restricted projects already force OpenRouter ZDR routing;
adding a runner setting must preserve that privacy floor.

Paid can enforce ZDR at request time when the runner routes through OpenRouter.
For other providers, Paid records the user's declaration but cannot verify the
user's external agreement or provider configuration. ZDR concerns inference
routing and provider retention, not retention of run data stored by Paid.

## Design

`runners.zdr_required` is a non-null boolean with a database default of false.
It is independent of `model_policy`, so existing runners retain their current
model behavior and default to no runner-specific ZDR requirement.

`Runner#zdr_provenance` derives, rather than persists, the current provenance:

- `none` when the runner setting is off;
- `openrouter_enforced` when the setting is on, the runner's current
  provider/credential resolves to OpenRouter, and Paid's execution integration
  sends the routing control; and
- `user_declared` when the setting is on for any other provider.

Derivation prevents provider or credential changes from leaving stale claims.
Only `openrouter_enforced` states runtime enforcement. OpenRouter-backed paths
whose execution adapter does not yet consume the routing control remain
`user_declared`, as do non-OpenRouter providers. The setup UI tells users: “You
are responsible for verifying this provider's zero data retention agreement and
configuration.”

The shared OpenRouter routing builder sets `zdr: true` when either the project
is restricted or the runner explicitly requires ZDR. It continues to deny data
collection for confidential and restricted projects. Non-OpenRouter execution
is unchanged; provider-specific execution remains an `agent_harness` concern.

Runner create/update audit events snapshot the boolean and derived provenance.
The authorized runner list UI and MCP runner serialization expose both values;
neither surface expands the existing policy scope or tenant boundary.

## Decisions & Alternatives

| Decision | Alternative | Rationale |
| --- | --- | --- |
| Persist only the declaration and derive provenance | Persist declaration and provenance | Provenance depends on the current provider and would become misleading after configuration changes. |
| Permit declarations for every provider | Restrict ZDR to OpenRouter | Users may have independently verified provider agreements; Paid records that claim without pretending to verify it. |
| Keep restricted-project routing authoritative | Let the runner flag disable ZDR | A runner-level default-off setting must not weaken project privacy requirements. |
| Keep ZDR independent of model policy | Add a ZDR model-selection profile | Provider retention and model selection are separate product concerns, and the existing Free policy must remain intact. |

## Boundaries

- This design does not add Paid run-data retention controls.
- It does not verify non-OpenRouter agreements or configuration.
- It does not claim non-OpenRouter runtime enforcement.
- It does not add or alter a model-selection policy.
