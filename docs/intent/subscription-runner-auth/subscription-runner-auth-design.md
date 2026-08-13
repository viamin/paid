---
parent: PAID
prefix: SUBSCRIPTION-RUNNER-AUTH
---

# Low-Level Design: Subscription Runner Auth

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented managed subscription-runner auth lifecycle
> described in `docs/rdrs/RDR-041-subscription-runner-auth-lifecycle.md`.

## Purpose

Paid supports subscription-auth CLI runners whose credentials are native OAuth
or session artifacts rather than normal provider API keys. The system must keep
the canonical credential state in Paid, materialize only the runtime form each
CLI expects, and preserve the shipped exceptions around remote safety and
host-forwarded fallback.

## Shipped Behavior

The provider-neutral contract lives in `Runners::SubscriptionAuthProviders` and
`Runners::SubscriptionAuthMaterializers`. Together they classify managed
credentials, describe how each provider materializes runtime auth, and expose
whether that managed materialization is remote-safe.

Claude remains remote-safe through managed env/native-file materialization with
server-side refresh semantics. Codex materializes a managed `auth.json`, uses a
lease-through-run refresh/harvest lifecycle, and intentionally remains
`remote_safe: false` until the broader hardening bar is met. Gemini and
Copilot regenerate minimal native config files from managed credentials and are
remote-safe for the shipped acceptance scope, while their provider-owned login
flows and harvest behavior remain deferred follow-on work.

Provisioning records managed-versus-host-forwarded auth telemetry and preserves
the legacy host-path fallback when managed rollout is disabled or when no
managed credential exists.

## Exceptions Preserved

- **Codex remote placement is still gated off.** The managed materializer is
  shipped, but remote-safe scheduling remains intentionally disabled.
- **Gemini and Copilot refresh/harvest remain deferred.** Their shipped scope
  is managed materialization plus fallback preservation, not full provider-owned
  lifecycle management.
