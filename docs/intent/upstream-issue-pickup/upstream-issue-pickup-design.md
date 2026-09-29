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
trusted GitHub author list. Untrusted issues are dropped and logged only with
safe identifiers; their titles and bodies are neither persisted nor logged.

## Routing and writes

`Project#issue_target_repository` centralizes the repository used for issue
and pull-request reads. In upstream mode it resolves to `upstream_full_name`.
The pull-request activity uses that same target for its upstream PR, so a
source issue's `Closes #N` reference resolves in the correct repository.

Paid does not mutate upstream issues. Poll recovery paths that would add or
remove labels skip the remote operation with an info log. Enhancement flows
that need a public issue comment are outside this automated path; their
questions must be surfaced in the agent run's pull request instead.
