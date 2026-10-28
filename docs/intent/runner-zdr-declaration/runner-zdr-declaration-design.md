---
parent: PAID
prefix: RUNNER-ZDR
---

# Runner Zero Data Retention Declaration Design

## Context

Project data classification continues to own project-level privacy requirements
and OpenRouter request routing. A runner also needs an independent, explicit
zero-data-retention (ZDR) declaration so an operator can record the retention
posture they require without changing model-selection policy.

## Design

`Runner#zdr` is a persisted boolean that defaults to `false`. It is independent
of `model_policy`, including the existing `free` policy.

`Runner#zdr_configuration` exposes the declaration and a provenance derived
from the runner's current effective API service type. A ZDR declaration is
`user_declared` for non-OpenRouter providers and `openrouter` for OpenRouter.
All declarations report runtime enforcement as `not_verified` until execution
passes the runner declaration to the OpenRouter request. This prevents saved
configuration from being represented as verified enforcement.

Because provenance is derived rather than stored, replacing a provider API key
or changing the effective provider immediately updates the exposed provenance.
The runner form explains that operators are responsible for verifying a
non-OpenRouter provider's ZDR agreement and configuration. Runner details and
the authorized runner-list tool expose this structured configuration without
credentials.

## Constraints

- This setting describes inference routing and provider retention, not Paid's
  own run-data retention.
- Existing `OpenRouterDataRouting` project classification behavior remains
  authoritative for project requirements and is not weakened by this setting.
- Provider-specific request execution remains in `agent-harness`; this change
  does not add a Paid-side execution wrapper.
