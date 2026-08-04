---
parent: PAID
prefix: SECRETS-PROXY
---

# Low-Level Design: Secrets Proxy

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented secrets-proxy behavior described in
> `docs/rdrs/RDR-006-secrets-proxy.md`.

## Purpose

Paid lets agent containers call provider APIs without receiving raw provider
API keys. The control plane proxies approved outbound calls, injects the real
credential server-side, and records usage against the authenticated run.

## Shipped Behavior

`Api::SecretsProxyController` authenticates agent runs, knowledge runs, and
approved chat-session traffic through container credentials. It then resolves
the effective provider key from the most specific allowed source:

1. run-scoped runner/provider selection when the request names a compatible
   provider entry,
2. knowledge-run direct-outbound configuration where that mode is an
   intentional exception,
3. platform-level configured provider keys.

The proxy forwards only the required request headers plus provider-specific
allowlisted headers, injects the actual auth header server-side, and never
requires the container to hold the real provider secret.

Successful responses feed token-usage accounting, while per-run token limits
fail closed before forwarding once the authenticated run exceeds its hard cap.

## Exceptions Preserved

- **Knowledge direct-outbound compatibility is intentional.** Knowledge runs
  may resolve an OpenAI-compatible upstream from the selected runner rather
  than always using the default OpenAI endpoint.
- **Subscription-auth and other non-proxy auth modes remain separate.** This
  segment documents only the provider-key proxy path, not native CLI auth
  materialization.
