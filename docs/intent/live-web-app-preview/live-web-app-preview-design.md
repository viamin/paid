---
parent: PAID
prefix: LIVE-PREVIEW
---

# Low-Level Design: Live Web App Preview

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the shipped preview and verification capabilities from
> RDR-045, including the August 2026 end-to-end closeout.

## Purpose

RDR-045 is implemented. The repository ships real preview/session/browser
infrastructure together with the user-facing lifecycle and verification-result
flows that consume it.

## Shipped Foundations

The repo now includes substantial runtime infrastructure:

- `PreviewSession` plus tunnel-reservation and preview-provision state models
- `Previews::Provision`, tunnel management, and cleanup behavior for booting an
  app, its dependencies, and a preview tunnel
- Playwright trace production plus trace-viewer UI components
- verification browser sidecar provisioning and playwright-mcp MCP attachment
  for agent runs that enable verification
- asynchronous preview lifecycle handling from queued provisioning through
  ready, failure, stopping, and cleanup
- persisted interactive-verification outcomes, app-log tails, and artifact
  metadata for review flows

These are real execution surfaces, not placeholders.

## Interactive Verification Result Contract

After the agent executes, `AgentRuns::VerificationResultRecorder` reads the
agent-written verification result, normalizes it, and persists the outcome on
the `AgentRun` before commit bookkeeping. It also retains app-log and artifact
metadata so review flows can distinguish what the agent verified from merely
having provisioned a browser sidecar. This runs for both successful and
non-zero runner exits, preserving verification evidence when the run fails.

### Reported outcome versus observed evidence

Interactive JSON is agent-authored reporting, not an execution attestation.
The recorder therefore retains its status, browser steps, and criterion claims
as `reported_*` data while separately recording recorder-owned facts: the
tested commit when one is available, normalized runtime configuration, bounded
app-log retention, artifact provenance, and evidence freshness. A claimed
criterion is `unverified` unless a recorder-owned assertion supports it;
reported failures, skips, and not-run states remain explicit. Screenshots and
app logs are useful artifacts but never prove arbitrary behavior merely by
existing.

Reported artifact paths are only assessed relative to the repository and are
never promoted into trusted object-storage keys. Recorder-created app logs are
retained under the existing project object-storage namespace when available;
missing, inaccessible, oversized, and untrusted artifacts remain visible as
explicit states. Evidence becomes stale when its commit differs from the run's
reviewed commit. This supplements RDR-076's shared evidence contract; it does
not create merge authority or a separate acceptance model.

### Criterion verification references

Every issue implementation run receives the criterion-result schema and may
report a criterion's selected verification kind and structured references to a
test result or other inspectable evidence, even when the project has not
enabled interactive verification. The recorder preserves these as reported
references only: it never promotes them, their names, browser steps, or prose
into verified coverage. Failed, skipped, and not-run criteria remain visibly
contradicted, skipped, or unverified so a skipped ephemeral job or unavailable
browser flow cannot disappear behind a green broad suite. Runtime
configuration, browser claims, and app-log evidence remain conditional on the
project's interactive-verification setting.

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
- **Not a production-data bridge.** Preview sessions remain intended for local
  or seeded data only.
- **Not a host-credential bridge.** Setup and app startup commands executed
  inside the preview container run repo-controlled code, so the environment
  handed to them is built from an explicit non-secret allowlist
  (`Previews::Provision::PREVIEW_ENV_ALLOWLIST`). Host credentials such as
  `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, and `RAILS_TEST_KEY` are not
  forwarded; the only host env vars that cross the trust boundary are
  non-secret runtime selectors (`RAILS_ENV`, `RACK_ENV`).

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
