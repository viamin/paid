# EARS Specs: Secrets Proxy

> Testable claims for the implemented provider-key secrets proxy. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a
> grep target across specs, tests, and code (`grep -r SECRETS-PROXY-001`).

- [x] **SECRETS-PROXY-001** — When an authenticated proxy request targets a
  supported provider route, the secrets proxy SHALL inject the real provider
  credential server-side and SHALL forward only the approved request headers
  required by that provider.
  *Tests:* `spec/requests/api/secrets_proxy_spec.rb`.
  *Code:* `Api::SecretsProxyController`.

- [x] **SECRETS-PROXY-002** — When a proxy request names a runner/provider
  selection that is unavailable, incompatible, or revoked, the secrets proxy
  SHALL fail closed instead of silently falling back, while preserving the
  documented knowledge-run direct-outbound exception paths.
  *Tests:* `spec/requests/api/secrets_proxy_spec.rb`.
  *Code:* `Api::SecretsProxyController`.

- [x] **SECRETS-PROXY-003** — When a proxied provider response succeeds, the
  secrets proxy SHALL record token usage against the authenticated run, and
  when the authenticated run exceeds its hard token cap the proxy SHALL reject
  the request before forwarding it upstream.
  *Tests:* `spec/requests/api/secrets_proxy_spec.rb`.
  *Code:* `Api::SecretsProxyController`.
