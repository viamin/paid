---
parent: PAID
prefix: LIVE-PREVIEW
---

# Low-Level Design: Live Web App Preview

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the shipped preview and verification foundations from RDR-045
> and the still-open end-to-end wiring gaps reconciled on August 4, 2026.

## Purpose

RDR-045 is no longer a pure future design. The repository now ships real
preview/session/browser foundations, but the user-facing preview and
verification flows are still incomplete. This segment records the split between
what already works underneath and what still needs implementation coverage.

## Shipped Foundations

The repo now includes substantial runtime infrastructure:

- `PreviewSession` plus tunnel-reservation and preview-provision state models
- `Previews::Provision`, tunnel management, and cleanup behavior for booting an
  app, its dependencies, and a preview tunnel
- Playwright trace production plus trace-viewer UI components
- verification browser sidecar provisioning and playwright-mcp MCP attachment
  for agent runs that enable verification

These are real execution surfaces, not placeholders.

## Active Gap

The remaining work is end-to-end wiring and lifecycle correctness:

- agent verification still stops at provisioning the browser sidecar instead of
  driving the changed app and persisting a verification outcome

## Trace Artifact Contract

Real agent-run trace viewing is tied to the same durable storage contract used
by screenshot capture publishing:
`screenshots/<org>/<repo>/pr-<number>/<commit>/trace.zip`.
The UI only embeds the viewer after a storage existence check succeeds for that
exact object key, so disabled storage and failed uploads degrade to the
"No trace available" state instead of a broken iframe.

Future live-preview session recording may need its own directly shareable trace
links, but that is a separate deferred contract. This segment does not treat
session-specific trace URLs as interchangeable with the screenshot-comment /
agent-run trace artifact path above.

## What this is not

- **Not the polyglot runtime segment.** Phoenix support here is preview-specific
  foundation work; the shared language/runtime contract lives in
  `polyglot-test-execution`.
- **Not a claim that the current preview buttons expose a real live app.** They
  are precisely one of the still-open gaps this segment records.
- **Not a production-data bridge.** Preview sessions remain intended for local
  or seeded data only.

## Trust Boundary: Upstream Header Allowlist

The preview proxy sits between the Paid browser session and a
repository-controlled app. Repository code is untrusted and must not receive
Paid-origin credentials, so the middleware applies a strict allowlist of
upstream request headers (see `LIVE-PREVIEW-009`). Specifically:

- The browser `Cookie` and `Authorization` headers are dropped on the
  forwarded request. Browsers attach these to every same-origin request
  automatically, so forwarding them would leak the Paid session/Devise
  cookie (and any cached HTTP-auth credential) to repository-controlled code
  purely because the preview shares Paid's origin.
- Any Paid-specific cookie or session header (e.g. the `cable_user_id` cookie
  stamped by `ApplicationController#stamp_cable_auth_cookie`, the Devise
  session cookie) is dropped because it lives inside `Cookie`.
- `X-CSRF-Token` and `X-XSRF-Token` are forwarded, not dropped. Unlike
  Cookie/Authorization, browsers never attach these automatically — they
  only appear when application JS sets them explicitly, so they carry the
  preview app's own CSRF token, not an automatically-leaked Paid credential.
  Dropping them unconditionally broke standard Rails/JS preview apps that
  rely on header-based CSRF protection for POST/fetch requests, violating
  the RDR-045 "forwarded apps require zero changes" contract.
- The proxy continues to rewrite `Host`, `X-Forwarded-*`, and `Origin` itself,
  and it forwards a narrow set of safe-to-pass-through headers (`Accept*`,
  `Cache-Control`, conditional-request headers, `Sec-CH-UA*`, `Sec-Fetch-*`,
  `User-Agent`, `X-CSRF-Token`/`X-XSRF-Token`, and the WebSocket upgrade
  headers when applicable).
- The same allowlist applies to WebSocket upgrades; without it, repository
  code could read browser credentials from the WebSocket handshake request.
