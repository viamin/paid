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
