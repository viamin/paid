---
parent: PAID
prefix: PR-TARGET
---

# Low-Level Design: Upstream PR Target

> Companion to the high-level design (`docs/high-level-design.md`).
> Issue #4076.

## Purpose

Paid normally opens and automates pull requests in the configured project's
repository. An open-source contributor may instead configure their fork as the
project while contributing changes to an upstream repository. The project must
therefore record where a future agent-created pull request should target,
without treating the upstream repository as trusted for Paid-owned review,
merge, label, or screenshot automation.

## Configuration

`Project#pr_target` is either `own_repo` (the default) or `upstream`.
`upstream_full_name` stores the manually editable `owner/repo` target when
upstream mode is selected. The model requires a well-formed upstream slug in
upstream mode and rejects one that names the project's own repository.

The `pr_target_repository` helper centralizes target resolution for the future
PR-creation flow. This segment only persists and exposes the setting; creating
the cross-repository PR is deliberately outside its scope.

## Settings experience

The project settings form presents the own-repository and upstream choices.
On edit, `Projects::ForkParentPrefill` reads GitHub repository metadata and
uses `parent.full_name` as a non-persisting field prefill when available. A
user may replace it because a contribution target need not be GitHub's literal
fork parent.

When upstream is selected, the existing Stimulus settings controller disables
and grays the repository-hosted automation controls. Switching back restores
their in-browser values. This is an affordance and scope signal, not a security
boundary: server-side enforcement is owned by the follow-up issue.

## Trust and scope

The configured upstream is not assumed to be owned by, or trusted by, the
Paid account. The UI therefore gates PR review, auto-merge/release, reviewer
escalation, draft/continue/conflict automation, PR labels, and screenshots.
This change does not implement upstream PR creation, fork-network preflight,
or server-side automation enforcement; each remains explicit follow-up work.
