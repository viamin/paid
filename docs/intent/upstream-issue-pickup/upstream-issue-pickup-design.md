---
parent: PAID
prefix: UPSTREAM-ISSUE
---

# Low-Level Design: Upstream Issue Pickup

> Companion to the high-level design (`docs/high-level-design.md`). Issue #4079.

## Purpose

An open-source contributor's fork commonly has no independent issue tracker.
When its PR target is configured as upstream, Paid reads work items from that
upstream repository while continuing to execute code changes from the fork.

## Trust boundary

The upstream is public input. Before any row is created or any automation sees
an issue, the poller compares the issue author's login with the project's
trusted GitHub author policy: its trusted GitHub author list or the configured
fork owner. The same policy applies when a persisted issue is later evaluated
for automation and prompt assembly. Untrusted issues are dropped and logged
only with safe identifiers; their titles and bodies are neither persisted nor
logged.
The incremental watermark is nevertheless derived from the complete fetched
page so a capped page of untrusted issues cannot prevent later trusted work
from being reached.

Revoking an author's trust also retires what was previously persisted: every
sync closes locally open upstream records whose creator is no longer trusted.
Without that retirement pass, a revoked author's records would survive the
fetch filter (incremental syncs skip stale closure) and re-enter the pipeline
through the incremental rescan fallback, keeping untrusted content displayed
and queued for LLM pickup.

Changing the issue target repository invalidates repository-scoped polling
state. Paid clears the issue cursors and archives locally open GitHub work
items from the previous target before polling the new target. This prevents a
same-number issue or pull request in a fork from suppressing the corresponding
upstream item during reconciliation.

## Routing and writes

`Project#issue_target_repository` centralizes the repository used for issue
and pull-request reads. In upstream mode it resolves to `upstream_full_name`.
The pull-request activity uses that same target for its upstream PR, so a
source issue's `Closes #N` reference resolves in the correct repository.

Paid does not mutate upstream issues. Poll recovery paths that would add or
remove labels skip the remote operation with an info log. The same centralized
guard applies to feature clarification, enhancement, and no-output outcome
comments and labels. Their durable local state and run output remain available
for the dashboard and pull-request-based degraded path.
