---
parent: PAID
prefix: RUNNER-ZDR
---

# Low-Level Design: Runner Zero Data Retention

## Context

Project data classification continues to set the minimum OpenRouter routing
requirements for each run. A runner also needs an explicit zero data retention
(ZDR) declaration, independent of its model policy, so an operator can state
the retention requirement for a specific credential and provider path.

## Decision

`Runner#zero_data_retention` is a persisted boolean and defaults to `false`.
It is available for every runner and does not select a model policy or alter
the existing Free policy.

The current provider determines the derived provenance at read time:

| Setting | Current provider path | Provenance |
| --- | --- | --- |
| off | any | `not_requested` |
| on | OpenRouter direct-outbound | `openrouter_enforced` |
| on | any other path | `user_declared` |

OpenRouter runtime builders merge `zdr: true` into their provider routing when
the declaration is on. The existing restricted-project routing remains in
force regardless of the runner setting, so no project privacy requirement is
weakened. A non-OpenRouter declaration is not evidence of runtime enforcement:
the operator is responsible for verifying the provider agreement and
configuration. Provenance is derived, not stored, so a credential or provider
change cannot retain an obsolete enforcement claim.

## Interfaces

The runner form presents the opt-in with this guidance: “You are responsible
for verifying this provider's zero data retention agreement and configuration.”
Runner details and `Tools::ListRunners` expose both the boolean and its derived
provenance under normal runner authorization and tenant scoping.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Derive provenance from the live provider path | Prevents stale enforcement claims after credential changes | Persist provenance beside the declaration |
| Keep ZDR independent from model policy | A privacy requirement is not a model-selection profile | Make ZDR a Free-policy option |
| Enforce only through OpenRouter routing | Paid can set its documented request option there | Claim provider verification for direct providers |
