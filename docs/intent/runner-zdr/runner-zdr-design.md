---
parent: PAID
prefix: RUNNER-ZDR
---

# Low-Level Design: Runner Zero Data Retention

## Context

Model selection and privacy routing are independent runner concerns. A runner
may require zero data retention (ZDR) while selecting either a specific model
or the existing Free policy. OpenRouter accepts ZDR as request-time routing
metadata; other providers require an agreement and configuration that Paid
cannot verify.

Project data classification remains a separate, stronger input. A restricted
project must continue to send OpenRouter ZDR routing regardless of whether its
runner declaration is enabled.

## Design

`Runner#zdr_enabled` is a persisted boolean with a false, non-null database
default. It is permitted through the existing tenant-scoped runner controller
and is therefore subject to the existing runner policy and policy scope.

`Runner#zdr_configuration` is the serializable runner detail and audit value.
It exposes the enabled flag and derives provenance from the runner's current
provider rather than persisting a provider label:

- `not_requested` when ZDR is disabled;
- `openrouter_enforced` when ZDR is enabled and the runner currently uses the
  OpenRouter request-time integration; and
- `user_declared` when ZDR is enabled for any other provider.

Deriving the label on read prevents a changed provider key or credential from
leaving a stale claim of OpenRouter enforcement. A declaration for a
non-OpenRouter provider is intentionally allowed. The form states: “You are
responsible for verifying this provider's zero data retention agreement and
configuration.”

The shared OpenRouter routing contract receives the runner declaration. It
adds `zdr: true` to supported OpenRouter request metadata when enabled, while
the existing restricted-project requirement remains an independent reason to
add it. Non-OpenRouter declarations are recorded and surfaced, but do not
claim that Paid has verified or configured that provider at runtime.

Runner create and update audit events include the serializable configuration;
the runtime metadata remains the execution-facing serialized configuration.

## Boundaries

ZDR concerns inference-provider retention only. It does not change Paid's own
run-data retention and does not select a model or alter the Free model policy.
Provider-specific execution support outside the existing OpenRouter metadata
contract remains owned by the execution integration.
