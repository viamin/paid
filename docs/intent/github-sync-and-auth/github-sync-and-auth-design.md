---
parent: PAID
prefix: GITHUB-SYNC
---

# Low-Level Design: GitHub Sync and Auth

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the shipped GitHub polling, cache, and credential posture
> that grew out of RDR-012 and RDR-030.

## Purpose

Paid's GitHub integration now spans two responsibilities that must stay
coherent:

- repository polling and local issue/PR state refresh for automation
- repository credentials and bot identity for reads, writes, and webhooks

This segment records the current brownfield contract after the App rollout. The
original PAT-only assumptions in RDR-012 were superseded by RDR-030, but PAT
fallback remains a supported path for projects that cannot use the App.

## Shipped behavior

The current implementation is polling-first. Each active project runs a durable
GitHub poll workflow that repeatedly fetches issues, reconciles local state,
and drives downstream automation. Webhooks complement that loop by invalidating
cache entries and updating App-installation lifecycle state, but the product
does not depend on webhooks as the sole source of truth for issue discovery.

Issue and PR state is cached locally at multiple layers:

- issues are synchronized into Paid's `issues` table during polling
- poll progress advances by `last_issue_sync_at` watermarks for incremental sync
- request-time API objects such as issues, pull requests, and repo metadata use
  cache invalidation keyed by GitHub webhook event type

Repository credentials resolve per project. App-backed projects mint
installation tokens and present the App bot identity; PAT-backed projects keep
using their active token. Callers consume an opaque GitHub credential so the
read/write path does not branch on auth mode.

GitHub App installation binding is intentionally conservative. The browser
callback proves user intent only after state verification or an operator-owned
self-hosted setup path. The actual install-to-account association is finalized
only when there is a server-trusted signal such as a `PendingInstallClaim`, an
existing installation row, or a confident account match. Signed installation
webhooks persist lifecycle changes and repository grants, then consume the
claim once the local `GithubInstallation` row becomes authoritative.

Self-hosted deployments configure their own App through the operator-only
manifest flow under `/admin/github_app/setup`. That flow exchanges GitHub's
one-time setup code, persists credentials when possible, and otherwise surfaces
the one-time secret material for manual completion.

## Projects V2 abandonment

RDR-012 originally included a GitHub Projects V2 branch. As of the 2026-07-09
RDR revision, that branch is intentionally abandoned and superseded by Paid's
native issue graph:

- `Issue#parent_issue_id` / `sub_issues`
- `IssueDependency`
- `ChangeIntent`
- local workflow state fields and labels

This segment therefore does **not** carry a `[ ]` gap for Projects V2 field or
item synchronization. Reintroducing a second hierarchy source of truth would
conflict with the local issue graph that already shipped.

## What this is not

- **Not webhook-first issue detection.** Webhooks accelerate freshness and App
  lifecycle reconciliation, but polling remains the durable issue-discovery
  path.
- **Not App-only auth.** PAT remains a supported fallback when a deployment or
  repository cannot use the GitHub App.
- **Not GitHub Projects V2 sync.** That path is deliberately closed rather than
  deferred.
