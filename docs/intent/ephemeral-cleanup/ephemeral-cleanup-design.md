---
parent: docs/high-level-design.md
prefix: EPHEMERAL-CLEANUP
---

# LLD: Ephemeral Cleanup

## Problem

The Ephemeral Cleanup GitHub Actions workflow removes accidentally merged
`.ephemeral-tests/*` files through a follow-up pull request. That pull request
must enter Paid's automation pipeline, but it is created by GitHub Actions
rather than an agent run and is therefore outside the PR label-recovery job.

## Design

When stray ephemeral-test files are found, the workflow creates its cleanup PR
with both `paid-automation` and `paid-generated` labels. It grants the
repository `GITHUB_TOKEN` issue-label write permission and requests the labels
as part of `gh pr create`; `set -e` makes a label-application failure fail the
step before the later auto-merge request. The existing no-stray-files branch
remains a no-op.

## Code

`.github/workflows/ephemeral-cleanup.yml`

Test: `spec/config/ephemeral_cleanup_workflow_file_spec.rb`
